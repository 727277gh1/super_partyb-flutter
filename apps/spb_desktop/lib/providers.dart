import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

/// 桌面能力 Provider。
///
/// 在 `main.dart` 的 `ProviderScope` 里被 override 为真实实现；
/// 默认值是空实现，使测试无需注入即可运行。
///
/// WHY 定义在独立文件：`main.dart` 会 import `app.dart`，
/// 而 `app.dart` 需要读本 Provider——放一起会形成 import 环。
final desktopCapabilitiesProvider = Provider<DesktopCapabilities>((ref) {
  return const NoopDesktopCapabilities();
});

// ==================== 传输层 ====================

/// 开发态手工指定的 `X-User-ID`。
///
/// ## 为什么默认是 null，且 release 下强制 null
///
/// 这个头**就是身份本身**：网关模式下由 api-gateway 在 OIDC 认证后注入并覆盖
/// 客户端传的值。若客户端自己设了它，等于**允许客户端自选身份**——任何拿到
/// 打包产物的人都能把 `X-User-ID` 改成别人的 id，从而读写他人的对话。
///
/// 故它只在本地开发（直连 Go API、绕过网关、`AUTH_MODE=header`）时有用：
///
/// ```bash
/// flutter run --dart-define=SPB_DEV_USER_ID=usr_xxx
/// ```
///
/// [SpbEnv.isRelease] 时**无条件忽略**该值（即便构建时传了 define），
/// 用「双保险」而非只靠「发布脚本记得别传」——后者是流程约定，会被遗忘。
final devUserHeaderOverrideProvider = Provider<String?>((ref) {
  if (SpbEnv.isRelease) return null;
  final v = const String.fromEnvironment('SPB_DEV_USER_ID');
  return v.isEmpty ? null : v;
});

/// 会话凭证提供者（OIDC access token）。
///
/// ## 当前为何恒为 null
///
/// 认证尚未接入（OIDC PKCE 是 M1 事项，见仓库 AGENTS.md 的 M0/M1 划分）。
/// 网关模式下浏览器/客户端持有的是 HttpOnly session cookie，**不是**
/// 由 Dart 代码管理的 Bearer token，故这里本就应返回 null——
/// 认证由 cookie + 网关完成，客户端不需要也不应该插手。
///
/// M1 接入 OIDC 后，这里改为从 `flutter_secure_storage` 读取 access token
/// 并在过期前刷新。用回调而非直接返回字符串：[AuthInterceptor] 每次请求都
/// 会调用它，持有快照会用到陈旧 token。
final sessionTokenProvider = Provider<Future<String?> Function()>((ref) {
  return () async => null;
});

/// 全局 Dio 实例（单例）。
///
/// 用 `Provider`（非 autoDispose）：Dio 持有连接池，随页面销毁重建会丢掉
/// keep-alive 连接，得不偿失。
final dioProvider = Provider<Dio>((ref) {
  final tokenProvider = ref.watch(sessionTokenProvider);
  final override = ref.watch(devUserHeaderOverrideProvider);

  return createDio(
    baseUrl: SpbEnv.apiBaseUrl,
    interceptors: [
      AuthInterceptor(
        tokenProvider: tokenProvider,
        // 生产为 null（见 devUserHeaderOverrideProvider 的说明）。
        userHeaderOverride: override,
      ),
    ],
  );
});

/// Chat API 客户端。
final chatApiProvider = Provider<ChatApi>((ref) {
  return ChatApi(ref.watch(dioProvider));
});

/// SSE 客户端（单例）。
///
/// 不 autoDispose：SSE 是 user 级订阅，切换 group 只换聚焦目标、
/// **不重连**（见 `ChatStreamController.switchGroup`）。若随页面销毁重建，
/// 每次进对话都要重新建连 + 回放，白白多一次往返。
final sseClientProvider = Provider<SseClient>((ref) {
  return SseClient(dio: ref.watch(dioProvider), baseUrl: SpbEnv.apiBaseUrl);
});

// ==================== 用户身份 ====================

/// 当前登录用户（`GET /api/auth/me`）。
///
/// ## 为什么必须有它
///
/// `ChatApi` 的 `/users/:user_id/chat/*` 系列都要调用方传 userId，而客户端
/// 不解析 JWT、不申请 API Key——本 Provider 是拿到 userId 的**唯一**途径。
///
/// 用 `FutureProvider` 让 Riverpod 缓存这次结果：多处需要 userId 时只发一次请求。
/// **不要在 UI 里手写「先 await 拿 id 再发第二条请求」**——那样每个页面都会
/// 各自发一次 `/api/auth/me`。
final currentUserProvider = FutureProvider<CurrentUser>((ref) async {
  return ref.watch(chatApiProvider).me();
});

/// 便捷读取 userId（依赖 [currentUserProvider]）。
final currentUserIdProvider = FutureProvider<String>((ref) async {
  final me = await ref.watch(currentUserProvider.future);
  return me.id;
});

// ==================== 对话流 ====================

/// 对话流控制器。
///
/// ## 为什么必须 autoDispose + onDispose
///
/// 它持有一条**长连接 SSE**。若用常驻 Provider，用户离开对话页后连接仍开着：
/// 桌面端表现为后台持续收事件（无谓唤醒），移动端表现为持续耗电与流量。
/// 故页面退出即释放。
///
/// `onDispose` 里必须调 `dispose()`：它负责取消帧订阅、关闭 SSE 与三个
/// StreamController。漏掉会留下悬挂订阅（Riverpod 只会丢弃 Provider 实例，
/// 不会替你清理它内部持有的资源）。
final chatStreamControllerProvider = Provider.autoDispose<ChatStreamController>(
  (ref) {
    final controller = ChatStreamController(
      sse: ref.watch(sseClientProvider),
      api: ref.watch(chatApiProvider),
      userId: ref.watch(currentUserIdProvider).value ?? '',
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
);

/// 无归属入口用例（悬浮输入窗用）。
///
/// 不 autoDispose：它无状态，只包一个 `ChatApi`，重建没有意义。
final quickCaptureUseCaseProvider = Provider<QuickCaptureUseCase>((ref) {
  return QuickCaptureUseCase(ref.watch(chatApiProvider));
});
