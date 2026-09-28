import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

/// 移动端没有桌面能力，恒为空实现。
///
/// 保留同名 Provider 使 `spb_features` 里的页面代码无需区分平台——
/// 页面统一读 `desktopCapabilitiesProvider`，由 [isSupported] 决定
/// 是否展示「托盘 / 全局快捷键」等设置项。
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
/// 认证尚未接入（OIDC PKCE 是 M1 事项）。移动端走系统浏览器 + 自定义 scheme
/// 回跳，拿到 token 后存 `flutter_secure_storage`；在接入之前这里返回 null，
/// 请求以匿名身份发出，服务端返回 401 由上层处理。
final sessionTokenProvider = Provider<Future<String?> Function()>((ref) {
  return () async => null;
});

/// 全局 Dio 实例（单例）。
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
/// 不 autoDispose：SSE 是 user 级订阅，切换 group 不重连。
final sseClientProvider = Provider<SseClient>((ref) {
  return SseClient(dio: ref.watch(dioProvider), baseUrl: SpbEnv.apiBaseUrl);
});

// ==================== 用户身份 ====================

/// 当前登录用户（`GET /api/auth/me`）。
///
/// `ChatApi` 的 `/users/:user_id/chat/*` 系列都要 userId，而客户端不解析 JWT、
/// 不申请 API Key——本 Provider 是拿到 userId 的**唯一**途径。
/// 用 `FutureProvider` 让 Riverpod 缓存结果，避免每个页面各发一次。
final currentUserProvider = FutureProvider<CurrentUser>((ref) async {
  return ref.watch(chatApiProvider).me();
});

/// 便捷读取 userId。
final currentUserIdProvider = FutureProvider<String>((ref) async {
  final me = await ref.watch(currentUserProvider.future);
  return me.id;
});

// ==================== 对话流 ====================

/// 对话流控制器。
///
/// ## 移动端为何更要 autoDispose
///
/// 它持有长连接 SSE。移动端离开页面后连接仍开着会**持续耗电与流量**
/// （系统可能因此限制后台网络），故页面退出即释放。
///
/// `onDispose` 里必须调 `dispose()`：它负责取消帧订阅、关闭 SSE 与三个
/// StreamController。Riverpod 只丢弃 Provider 实例，不会清理内部资源。
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
final quickCaptureUseCaseProvider = Provider<QuickCaptureUseCase>((ref) {
  return QuickCaptureUseCase(ref.watch(chatApiProvider));
});
