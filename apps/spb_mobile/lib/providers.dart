import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'auth_deeplink.dart';

/// 移动端没有桌面能力，恒为空实现。
///
/// 保留同名 Provider 使 `spb_features` 里的页面代码无需区分平台——
/// 页面统一读 `desktopCapabilitiesProvider`，由 [isSupported] 决定
/// 是否展示「托盘 / 全局快捷键」等设置项。
final desktopCapabilitiesProvider = Provider<DesktopCapabilities>((ref) {
  return const NoopDesktopCapabilities();
});

/// 本地通知发送能力（issue #21）。
///
/// 默认 [NoopNotificationSink]；生产在 `main.dart` 覆盖为
/// [LocalNotificationSink]（Android 走 `NotificationManager` + 运行时权限，
/// iOS 走 `UNUserNotificationCenter`）。见 [notificationSinkProvider] 的桌面端
/// 同名字段文档（两侧保持同构）。
final notificationSinkProvider = Provider<NotificationSink>((ref) {
  return const NoopNotificationSink();
});

/// 主窗口/应用当前是否聚焦（可写）。
///
/// ## 为什么是 `NotifierProvider` 而不是 `StateProvider`
///
/// Riverpod 3 移除了顶层 `StateProvider` 构造函数（只剩 `NotifierProvider`）。
/// 本文件其余可写状态也都用 `NotifierProvider`（见 [authStateProvider]）。
class WindowFocusedNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  /// 设置聚焦状态（平台事件推送）。
  ///
  /// 相同值时不触发重建（焦点事件可能密集）。
  void set(bool value) {
    if (state == value) return;
    state = value;
  }
}

/// 见 [WindowFocusedNotifier] 的文档。初始 true（保守：启动时不打扰）。
final windowFocusedProvider = NotifierProvider<WindowFocusedNotifier, bool>(
  WindowFocusedNotifier.new,
);

/// 确认卡到达时发 OS 通知（issue #21）。见桌面端同名 provider 的文档。
final confirmationNotifierProvider = Provider<ConfirmationNotifier>((ref) {
  return ConfirmationNotifier(
    sink: ref.watch(notificationSinkProvider),
    isWindowFocused: () => ref.read(windowFocusedProvider),
  );
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
  const v = String.fromEnvironment('SPB_DEV_USER_ID');
  return v.isEmpty ? null : v;
});

/// 是否展示「诊断」面板（工具调用 + gate 决策）。
///
/// ## 当前**无消费方**，仅为两端装配同构而保留
///
/// 移动端没有「诊断」tab：`GroupDebugPanel` 只在桌面端侧边栏装配（桌面端有
/// 侧边栏这个载体，移动端的小屏放不下这类内部视图）。故本端读它也无处可用。
///
/// 仍然定义它的理由：两端 `providers.dart` 刻意保持同构（同一批 provider
/// 同名同义），使「某个 provider 只在一端存在」不会成为下次接线的意外。
/// 若将来移动端加诊断入口，直接 watch 本 provider 即可，不必再补一次定义。
///
/// 判定方式与桌面端一致：包一层 provider 而非直接写 `!SpbEnv.isRelease`，
/// 因为后者是编译期常量，widget test 无法切换（详见桌面端同名 provider 的
/// 文档）。
final showDebugPanelProvider = Provider<bool>((ref) => !SpbEnv.isRelease);

/// 会话凭证提供者（OIDC access token）。
///
/// ## 认证形态（实测依据：`docs/oidc-verification.md`）
///
/// 生产链路由 **api-gateway 托管 OIDC**：会话是网关下发的 HttpOnly Cookie，
/// 客户端不解析 JWT、不申请 API Key。本 Provider 提供的 Bearer token 用于
/// **直连 IdP 换到的 token**（以及本地开发）。两者不冲突：网关同时接受
/// `Authorization: Bearer` 与 Cookie。
///
/// 用回调而非直接返回字符串：[AuthInterceptor] 每次请求都会调用它，
/// 持有快照会用到陈旧 token。
final sessionTokenProvider = Provider<Future<String?> Function()>((ref) {
  final manager = ref.watch(sessionManagerProvider);
  return manager.currentAccessToken;
});

/// 会话凭证存储（Keychain / Keystore）。
final tokenStoreProvider = Provider<TokenStore>((ref) {
  return SecureTokenStore();
});

/// OIDC 配置（编译期注入，见 `SpbEnv.oidcIssuer` 等）。
///
/// ⚠️ `redirectUri` **覆盖**为 [OidcCallbackUri.redirectUri]
/// （`partyb://oidc/callback`），而不是 `SpbEnv.oidcRedirectUri`
/// （默认是网关回调）。理由：网关把 `redirect_uri` 硬编码为自己的地址
/// （实测见 `docs/oidc-verification.md` §1.2），用它的话回调永远落在网关、
/// 客户端拿不到 code。移动端要拿 code 必须声明自己的回调地址。
///
/// `clientSecret` 传 null：生产不在客户端内嵌密钥（这也意味着当前 IdP 的
/// 非 public client 形态下换不到 token，见 `docs/mobile-oidc-deeplink.md`）。
final oidcConfigProvider = Provider<OidcConfig>((ref) {
  return OidcConfig.fromEnv().copyWithRedirectUri(OidcCallbackUri.redirectUri);
});

/// OIDC 客户端（刷新凭证用）。
final oidcClientProvider = Provider<OidcClient>((ref) {
  return OidcClient(config: ref.watch(oidcConfigProvider));
});

/// 会话管理器：负责「拿到可用 token」与「过期前刷新（并发去重）」。
final sessionManagerProvider = Provider<SessionManager>((ref) {
  final store = ref.watch(tokenStoreProvider);
  final oidc = ref.watch(oidcClientProvider);

  return SessionManager(
    store: store,
    refresher: (current) async {
      final refreshToken = current.refreshToken;
      if (refreshToken == null || refreshToken.isEmpty) return null;

      final tokens = await oidc.refresh(refreshToken: refreshToken);
      final expiresIn = tokens.expiresIn;
      return StoredTokens(
        // 必须用 `bearerToken`（有 id_token 时就是它），不能写
        // `tokens.accessToken`——那是 fosite 不透明串，网关验不了。
        // 刷新路径尤其容易漏：fosite 的 OpenIDConnectRefreshHandler 在 scope
        // 含 openid 时会**一并重发新的 id_token**，所以这里同样有值可用。
        accessToken: tokens.bearerToken,
        // 保留旧 refresh_token 由 SessionManager 负责（新响应常不下发）。
        refreshToken: tokens.refreshToken ?? refreshToken,
        expiresAt: expiresIn == null
            ? null
            : DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
        tokenType: tokens.tokenType,
        scope: tokens.scope,
      );
    },
  );
});

/// 每次请求都把基地址重写成「当前生效的端点」（issue #50 运行中降级/升级）。
///
/// ## 为什么不 `ref.watch` 端点状态
///
/// `SpbEndpoints.current` 是 `spb_core` 的静态字段（纯 Dart 包，无 Riverpod）。
/// 让 `dioProvider` 去 watch 它意味着「端点变化 → 重建 Dio」——而 Dio 与
/// SseClient 的身份被 `ChatStreamController` 与页面的 `??=` 订阅持有，重建会
/// 让旧订阅挂在已 dispose 的实例上（时间线静默冻结）。
///
/// 拦截器把「读哪个 host」推迟到**每次请求**，Dio 实例因此可以长命。
/// 详见 `EndpointRewriteInterceptor` 的文档。
///
/// [ufs] 为真时读 `ufsBaseUrl`（文件服务的基地址与前缀都和 API 不同）。
EndpointRewriteInterceptor _endpointRewrite({bool ufs = false}) {
  return EndpointRewriteInterceptor(
    resolveBaseUrl: () =>
        ufs ? SpbEndpoints.current.ufsBaseUrl : SpbEndpoints.current.apiBaseUrl,
  );
}

/// 全局 Dio 实例（单例）。
final dioProvider = Provider<Dio>((ref) {
  final tokenProvider = ref.watch(sessionTokenProvider);
  final override = ref.watch(devUserHeaderOverrideProvider);
  final manager = ref.watch(sessionManagerProvider);

  final auth = AuthInterceptor(
    tokenProvider: tokenProvider,
    // 生产为 null（见 devUserHeaderOverrideProvider 的说明）。
    userHeaderOverride: override,
    // 401 时刷新凭证并重放原请求。用 `refreshWithOutcome` 而非 `refresh`：
    // 刷新失败有**两种含义相反**的情形（见 `TokenRefreshStatus`）——
    // 服务端明确拒绝（`invalid_grant`）才回登录页，网络层失败（休眠唤醒 /
    // 切网）必须**保留登录态**，下次请求再试。
    onUnauthorizedOutcome: manager.refreshWithOutcome,
    onSessionExpired: _sessionExpiredHandler(ref),
  );

  // 基地址读 `SpbEndpoints.current` 而非编译期常量：启动探测可能已把 host
  // 升级到 IPv6 源站域名（见 `packages/spb_core/lib/src/endpoints.dart`）。
  // 未调用 resolve 时两者完全相等，行为零变化。
  final dio = createDio(
    baseUrl: SpbEndpoints.current.apiBaseUrl,
    interceptors: [auth, _endpointRewrite()],
  );
  // 回填重放用的 Dio：必须是同一个实例（否则丢掉连接池与其余拦截器）。
  auth.replayDio = dio;
  return dio;
});

/// 把「会话确定失效」接到认证状态（两端 `dioProvider` / `ufsDioProvider` 共用）。
///
/// ## 为什么必须有这一行（否则「跳登录页」永远不会发生）
///
/// `AuthInterceptor` 只把 401 归一化成 `AuthError` 抛给调用方，而各页面拿到它
/// 只翻成一句 SnackBar 文案（如「登录已过期，请重新登录」），**没有任何一处**
/// 把认证状态推进到未登录。于是会话真的过期后用户卡在当前页面，只能手动进
/// 设置页点「退出登录」。
///
/// 接上之后链路是：401 → `onSessionExpired` → [markUnauthenticated] →
/// [AuthRefreshNotifier] 通知 → 路由守卫重定向到 `/login?from=<当前页>`。
///
/// ## 用 `read` 而非 `watch`
///
/// `dioProvider` 若 watch 认证状态，**每次登录/登出都会重建 Dio**——而 Dio 与
/// SseClient 的身份被 `ChatStreamController` 与页面的 `??=` 订阅持有，重建会让
/// 旧订阅挂在已 dispose 的实例上（时间线静默冻结，见 [sseClientProvider] 的
/// 同一条说明）。回调只在**触发时**读 notifier，不建立依赖。
void Function(String message) _sessionExpiredHandler(Ref ref) {
  return (message) {
    SpbLog.warn('会话失效，回到登录页', {'reason': message});
    ref.read(authStateProvider.notifier).markUnauthenticated(message);
  };
}

/// Chat API 客户端。
final chatApiProvider = Provider<ChatApi>((ref) {
  return ChatApi(ref.watch(dioProvider));
});

/// 目标 / 任务 API 客户端（与 [chatApiProvider] 共用同一个 [dioProvider]）。
///
/// 单独一个 provider 而不是塞进 [chatApiProvider]：`GoalApi` 的 12 个端点
/// 属于「目标管理」这个可独立关闭的子系统（与 `HabitApi` 同一取舍）。
final goalApiProvider = Provider<GoalApi>((ref) {
  return GoalApi(ref.watch(dioProvider));
});

/// 轮次详情加载用例（issue #19）。
///
/// ## 为什么是「用例」provider 而不是在页面里直接拼两次请求
///
/// 上游 `GET /chat/turns/:id` 不返回 events（`super_partyb#56`），故要
/// `getTurn` + `groupTimeline` 过滤两趟——这个组合是**领域规则**（含分页停止
/// 条件与排序），不是渲染细节。放在 `spb_domain` 的 `LoadTurnDetailUseCase`
/// 里可脱离 Flutter 单测；两端只负责把它接到 provider 上。
///
/// ## 为什么不用 `Provider.family`
///
/// 它无参（groupId / turnId 由调用处传入），family 的键会无谓地把用例按
/// group 复制多份——而用例本身无可变状态（`ChatApi` 已由 [dioProvider] 共享）。
final loadTurnDetailProvider = Provider<LoadTurnDetailUseCase>((ref) {
  return LoadTurnDetailUseCase(ref.watch(chatApiProvider));
});

// ==================== 对话管理（改名 / 归档 / 删除）====================

/// 对话管理用例。
final groupManagementUseCaseProvider = Provider<GroupManagementUseCase>((ref) {
  return GroupManagementUseCase(ref.watch(chatApiProvider));
});

/// 群设置（目标 + 三个 CAS 开关）的写用例。
///
/// 每个写操作都是「调专用 PUT 端点 → 回读 group」两步，两个 app 共用本 provider
/// 保证语义一致（详见 `GroupSettingsUseCase` 类文档）。
final groupSettingsUseCaseProvider = Provider<GroupSettingsUseCase>((ref) {
  return GroupSettingsUseCase(ref.watch(chatApiProvider));
});

/// 自动续跑排程（auto-schedules）的读用例。
///
/// 两个 app 共用本 provider 保证语义一致：先取 `activeSession.agentId` 再列出，
/// 并**本地按 group 过滤**（服务端 handler 忽略 `:group_id`，只按 agent 查），
/// 停用后**回读列表**。详见 `AutoSchedulesUseCase` 类文档。
final autoSchedulesUseCaseProvider = Provider<AutoSchedulesUseCase>((ref) {
  return AutoSchedulesUseCase(ref.watch(chatApiProvider));
});

/// 对话管理动作的执行入口（供 `GroupListPage.onGroupAction` 注入）。
///
/// ## 为什么在这里把异常翻译成 [GroupActionRejected]
///
/// `SpbError.message` 是**给开发者看的**（`HttpError` 的消息就是 `"HTTP 403"`），
/// 直接显示给用户等于没说。翻译需要判断错误类型并给出可操作的提示——这属于
/// 「本端如何呈现」的决策，放在 app 装配层，而不是 domain（domain 只负责
/// 「哪个错误算业务拒绝」）。
///
/// 页面仍会接住漏网的 `SpbError`（如翻译函数自己出问题），故这是纵深防御而非
/// 唯一防线。
final groupActionProvider = Provider<GroupActionHandler>((ref) {
  final useCase = ref.watch(groupManagementUseCaseProvider);
  return (group, action) async {
    try {
      return await useCase.execute(group, action);
    } on SpbError catch (e) {
      SpbLog.warn('对话管理动作失败', {
        'groupId': group.id,
        'action': action.runtimeType.toString(),
        'error': e.toString(),
      });
      return GroupActionRejected(_describeGroupActionError(e));
    }
  };
});

/// 把 [SpbError] 翻译成用户能看懂的一句话。
String _describeGroupActionError(SpbError error) {
  // 401 由 AuthInterceptor 归一化成 AuthError（见 spb_api）。
  if (error is AuthError && error.isUnauthorized) {
    return '登录已过期，请重新登录';
  }
  if (error is AuthError && error.isForbidden) {
    return '没有权限修改这个对话';
  }
  if (error is HttpError) {
    if (error.isForbidden) return '没有权限修改这个对话';
    if (error.isRateLimited) return '操作太频繁，请稍后再试';
    if (error.isServerError) return '服务端暂时不可用，请稍后重试';
    if (error.isConflict) return '该对话正在被修改，请刷新后重试';
  }
  if (error is NetworkError) return '网络连接失败，请检查网络后重试';
  if (error is ParseError) return '服务端返回了无法识别的数据';
  return error.message;
}

/// SSE 客户端（单例）。
///
/// ## 不 autoDispose：切 group 不重连
///
/// SSE 是 user 级订阅，若随页面销毁重建，每次进对话都要重新建连 + 回放，
/// 白白多一次往返。
///
/// ## 所有权约定（重要）：本 provider 拥有 [SseClient] 的 dispose
///
/// `ChatStreamController` 是 `autoDispose`（页面退出即释放），但**它不得关闭
/// 这里创建的 SseClient**——那会让「离开一次对话页」变成「永久失去实时流」
/// （关闭后所有帧被静默丢弃）。故：
///
/// - 控制器只在 `dispose()` 里取消自己的订阅（见 `ChatStreamController.dispose`）；
/// - SseClient 的释放**只由本 provider** 在自身销毁时负责（`ref.onDispose`）。
///
/// 新增任何持有长连接的 provider 时照此约定：**谁创建，谁 dispose**。
final sseClientProvider = Provider<SseClient>((ref) {
  final client = SseClient(
    dio: ref.watch(dioProvider),
    baseUrl: SpbEndpoints.current.apiBaseUrl,
  );
  // 端点降级/升级时换 host 重连（issue #50）。
  //
  // ## 为什么是「换 host」而不是「重建 SseClient」
  //
  // SseClient 的身份被 `ChatStreamController` 持有，而页面里的帧订阅是
  // `_itemsSub ??=` 形式（只绑一次）。重建实例会让旧订阅挂在已 dispose 的
  // 控制器上——表现为**时间线静默冻结**（比不降级更难排查）。
  // `switchBaseUrl` 保持实例身份，只换连接。
  //
  // ## 为什么 switchBaseUrl 会清游标
  //
  // 源站与 CDN 可能是不同后端实例，旧 host 的 eventId 不能用于新 host 回放
  // （见 `SseClient.switchBaseUrl` 的说明）。清游标后服务端会当作全新订阅，
  // 由控制器按需整段回填。
  final sub = SpbEndpoints.changes.listen((next) {
    unawaited(client.switchBaseUrl(next.apiBaseUrl));
  });
  ref.onDispose(() {
    unawaited(sub.cancel());
    client.dispose();
  });
  return client;
});

// ==================== 认证 ====================

/// 发起登录的动作。
///
/// 打开系统浏览器走 IdP 授权码流程（自定义 scheme 回跳），实现见
/// `auth_deeplink.dart` 的 [mobileSignIn]。
///
/// ⚠️ **当前无法闭环**：IdP 未注册 `partyb://oidc/callback`
/// （授权端点直接 400），且该 client 非 public client（无 client_secret
/// 换不到 token）。两者都需在 IdP 侧新增一个移动端 public client，属跨仓库
/// 的生产配置变更。本实现已按目标形态写好，服务端就绪后即可工作；
/// 详见 `docs/mobile-oidc-deeplink.md`。
final signInActionProvider = Provider<Future<String?> Function()>((ref) {
  final config = ref.watch(oidcConfigProvider);
  final store = ref.watch(pendingAuthStoreProvider);
  return () => mobileSignIn(
    config: config,
    store: store,
    launch: (url) => launchUrl(url, mode: LaunchMode.externalApplication),
  );
});

/// 待验证登录请求（`state` + PKCE verifier）的存放处。
///
/// 用**加密持久化**实现：授权流程把用户带到外部浏览器，应用可能在此期间被
/// 系统回收（Android 低内存常见）。内存实现在重启后丢失 state/verifier，
/// 回调会因「没有进行中的登录」被拒——表现为「登录成功回到应用但什么也没
/// 发生」。见 `SecurePendingAuthStore` 与 `docs/mobile-oidc-deeplink.md` §3.1。
/// 测试可 override 为 [InMemoryPendingAuthStore]（不触平台通道）。
final pendingAuthStoreProvider = Provider<PendingAuthRequestStore>((ref) {
  return SecurePendingAuthStore();
});

/// OIDC 回调接收器（监听自定义 scheme 回跳并把 code 换成会话）。
///
/// 在 `main.dart` 启动时调 `start()`。它把收到的 code 交给
/// `OidcClient.exchangeCode` 换成 token、写入安全存储，然后把认证状态推进到
/// 已登录。
final authDeepLinkReceiverProvider = Provider<AuthDeepLinkReceiver>((ref) {
  final receiver = AuthDeepLinkReceiver(
    source: ref.watch(deepLinkSourceProvider),
    pendingState: ref.read(pendingAuthStoreProvider).consume,
    onCode: ref.watch(oidcCallbackHandlerProvider),
    onError: (message) {
      // 把失败原因显示在登录页（它 watch 的就是 authStateProvider）。
      ref.read(authStateProvider.notifier).markUnauthenticated(message);
    },
  );
  ref.onDispose(receiver.dispose);
  return receiver;
});

/// 把授权码换成会话的处理函数（**移动端登录的落盘点**）。
///
/// 返回失败原因（null 表示成功）。
typedef OidcCallbackHandler = Future<String?> Function(
  String code,
  PkcePair pkce,
);

/// 登录落盘的处理函数。
///
/// ## 为什么抽成一个 provider
///
/// 它原先内联在 `authDeepLinkReceiverProvider` 的 `onCode` 闭包里，于是
/// 这段代码**只能**从 `main.dart`（调 `receiver.start()`）或 widget 树走
/// 全链路才能触达——而 `main.dart` 不在测试树中，它实际是零覆盖的。
/// 「落盘的 Bearer 取错了字段」这个缺陷就活在那个空档里。
///
/// 抽成 provider 后可以 `container.read(oidcCallbackHandlerProvider)` 直接调，
/// 回归防线见 `test/router_chat_test.dart`。
final oidcCallbackHandlerProvider = Provider<OidcCallbackHandler>((ref) {
  return (code, pkce) async {
    try {
      final tokens = await ref
          .read(oidcClientProvider)
          .exchangeCode(code: code, pkce: pkce);
      // ⚠️ 用 `fromOidcTokens` 而非手写映射：落盘的必须是 **id_token**
      // （网关只验 RS256 JWT，不认 `ory_at_…` 不透明串），见
      // `OidcTokens.bearerToken`。
      await ref
          .read(tokenStoreProvider)
          .write(StoredTokens.fromOidcTokens(tokens));
      ref.read(authStateProvider.notifier).signedIn();
      return null;
    } on SpbError catch (e) {
      return e.message;
    } catch (e) {
      return '登录失败：$e';
    }
  };
});

/// 深链来源（生产为 `app_links` 插件；测试可覆盖）。
final deepLinkSourceProvider = Provider<DeepLinkSource>((ref) {
  return AppLinksDeepLinkSource();
});

/// 认证状态（登录页与路由守卫共享）。
final authStateProvider = NotifierProvider<AuthStateNotifier, AuthState>(
  AuthStateNotifier.new,
);

/// 认证状态控制器（与桌面端同构，见桌面 `providers.dart` 的详细说明）。
class AuthStateNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    unawaited(restore());
    return AuthState.unknown;
  }

  /// 从安全存储恢复登录态。
  Future<void> restore() async {
    final manager = ref.read(sessionManagerProvider);
    try {
      final token = await manager.currentAccessToken();
      if (token == null) {
        final leftover = await ref.read(tokenStoreProvider).read();
        if (leftover != null) await manager.logout();
        state = AuthState.unauthenticated;
        return;
      }
      state = AuthState.authenticated;
    } on SpbError catch (e) {
      SpbLog.warn('恢复登录态失败', {'error': e.toString()});
      state = AuthState.failed(e.message);
    }
  }

  /// 发起登录。返回失败原因（null 表示已成功发起）。
  Future<String?> signIn() async {
    final signIn = ref.read(signInActionProvider);
    String? error;
    try {
      error = await signIn();
    } on SpbError catch (e) {
      error = e.message;
    } catch (e) {
      error = '无法发起登录：$e';
    }

    if (error != null) {
      state = AuthState.failed(error);
      return error;
    }
    // 已发起：清掉旧的错误提示。
    //
    // ## 为什么**不能**无条件写 `unknown`（与桌面端同一条回归防线）
    //
    // 移动端的真实流程是「只发起 → 等深链回调」，返回时确实该是 unknown；
    // 但回调接收器（`authDeepLinkReceiverProvider` 的 `onCode`）可能在
    // 本方法返回**之前**就已完成并调了 [signedIn]。若无条件写 `unknown`，
    // 刚拿到的已登录会被盖掉，而守卫在 unknown 时**不重定向**（那是启动期的
    // 正常态），于是用户永远停在 `/login`。
    //
    // 判据不是「谁先谁后」，而是「**别把已登录改回未判定**」——`unknown`
    // 的语义是「还不知道」，已经知道的事不该被它覆盖。
    if (!state.isAuthenticated) {
      state = const AuthState(status: AuthStatus.unknown, message: null);
    } else if (state.message != null) {
      state = state.copyWith(clearMessage: true);
    }
    return null;
  }

  /// 凭证已落盘（回调收到 token 后调用）。
  void signedIn() => state = AuthState.authenticated;

  /// 粘贴导入已有会话（IdP 未注册 public client 时的降级路径）。
  ///
  /// 与桌面端 `AuthStateNotifier.importSession` 同构：解析 → 落盘 →
  /// 复用 [restore] 验证。为什么必须复用 restore：直接置位会造出「界面已登录、
  /// 请求全 401」的假状态；restore 会真实读回 token（顺带处理过期刷新），
  /// 复用还避免新增状态机分支。
  ///
  /// ## 为什么失败时返回字符串而不是抛异常
  ///
  /// 与 [signIn] 同语义：粘贴错内容是**预期内的用户操作**，不是程序错误。
  /// 返回值直接显示在登录页上。
  Future<String?> importSession(String raw) async {
    final tokens = parseSessionCredential(raw);
    if (tokens == null) {
      const msg = '认不出粘贴的内容，请确认包含 id_token 或 access_token';
      state = AuthState.failed(msg);
      return msg;
    }

    try {
      await ref.read(tokenStoreProvider).write(tokens);
    } on SpbError catch (e) {
      // 安全存储写失败：不能假装成功，否则状态会变成「已登录」而凭证其实没落盘。
      SpbLog.warn('导入会话时写入安全存储失败', {'error': e.toString()});
      state = AuthState.failed(e.message);
      return e.message;
    }

    await restore();
    // restore 已经把失败写进 state（如写入后仍取不到可用 token）。
    return state.isAuthenticated ? null : (state.message ?? '导入的会话不可用');
  }

  /// 登出：清凭证并切到未登录。
  Future<void> signOut() async {
    await ref.read(sessionManagerProvider).logout();
    state = AuthState.unauthenticated;
  }

  /// 标记会话失效（如收到 [AuthError]）。**不清凭证**。
  void markUnauthenticated(String? message) {
    state = message == null
        ? AuthState.unauthenticated
        : AuthState.failed(message);
  }
}

/// 认证动作集合。
final authControllerProvider = Provider<AuthActions>((ref) {
  return AuthActions(
    signIn: () => ref.read(authStateProvider.notifier).signIn(),
    signOut: () => ref.read(authStateProvider.notifier).signOut(),
    importSession: (raw) =>
        ref.read(authStateProvider.notifier).importSession(raw),
  );
});

/// 认证动作集合。
class AuthActions {
  const AuthActions({
    required this.signIn,
    required this.signOut,
    required this.importSession,
  });

  final Future<String?> Function() signIn;
  final Future<void> Function() signOut;

  /// 粘贴导入已有会话，见 [AuthStateNotifier.importSession]。
  final Future<String?> Function(String raw) importSession;
}

/// 把认证状态变化转成 `Listenable`，供 go_router 的 `refreshListenable` 使用。
///
/// 见桌面 `providers.dart` 的详细说明（为什么必须有它）。
class AuthRefreshNotifier extends ChangeNotifier {
  AuthRefreshNotifier(Ref ref) {
    ref.listen(authStateProvider, (previous, next) {
      if (previous?.status != next.status) notifyListeners();
    });
  }
}

/// [AuthRefreshNotifier] 的 Provider。
final authRefreshListenableProvider = Provider<Listenable>((ref) {
  return AuthRefreshNotifier(ref);
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

/// userId 的**本地持久化**副本（离线可用）。与桌面端同构，理由见其文档。
///
/// 简述：`currentUserIdProvider` 内部是 `chatApi.me()`（网络请求），而对话列表
/// 缓存要解决的正是**断网冷启动**——那时该请求必然失败，userId 拿不到，缓存就
/// 无法定位自己的行。故把成功拿到的 userId 落进偏好表，读时先本地后网络。
final cachedUserIdProvider = FutureProvider<String?>((ref) async {
  final prefs = ref.watch(preferencesStoreProvider);
  final stored = await prefs.getString(cachedUserIdPrefKey);
  if (stored != null && stored.isNotEmpty) return stored;

  try {
    final id = await ref.watch(currentUserIdProvider.future);
    if (id.isNotEmpty) {
      await prefs.setString(cachedUserIdPrefKey, id);
      return id;
    }
  } catch (e) {
    // 断网 / 未登录：返回 null，调用方据此不启用缓存。
    //
    // 记 debug（issue #45）：离线启动时这是**正常**路径（不是故障），
    // 但它是「为什么这次没有缓存」的唯一线索。
    SpbLog.debug('取不到 userId，本地缓存本次不启用', {'error': e.toString()});
  }
  return null;
});

/// 缓存 userId 的偏好键。
const String cachedUserIdPrefKey = 'auth.cached_user_id';

/// 对话列表缓存（issue #26 切片 A）。
final groupCacheStoreProvider = Provider<GroupCacheStore>((ref) {
  return DriftGroupCacheStore(ref.watch(appDatabaseProvider));
});

/// 对话 timeline 只读缓存（issue #26 切片 B / issue #29）。
///
/// 与 [groupCacheStoreProvider] 同取向：同一个 [AppDatabase]，同一个 Provider
/// 形态，差异只在契约与表。**不随同步状态清空**（`DriftSyncStateStore.resetAll`
/// 只碰同步表，见 `docs/offline-cache-design.md` §6.3）。
final timelineCacheStoreProvider = Provider<TimelineCacheStore>((ref) {
  return DriftTimelineCacheStore(ref.watch(appDatabaseProvider));
});

/// 离线写队列的持久化（issue #26 切片 C / issue #30）。
///
/// 与上面两个 store 的关键差异：**它不是可丢弃数据**。队列装的是用户敲进去、
/// 还没发出去的文本——`DriftOutboxStore` 的读写失败一律抛 `StorageError`
/// 而非静默降级（设计文档 §7bis.9）。故它不参与 `resetAll`（见
/// `DriftSyncStateStore`）：**退出登录不该删掉未发送的消息**。
final outboxStoreProvider = Provider<OutboxStore>((ref) {
  return DriftOutboxStore(ref.watch(appDatabaseProvider));
});

/// 离线写队列（issue #30）。
///
/// ## ⚠️ 不能是 autoDispose
///
/// 队列持有重试计时器，而 `chatStreamControllerProvider` 是
/// `autoDispose.family`（离开对话页即释放）。若队列随页面一起释放，用户
/// 「断网发一条 → 退出对话 → 网络恢复」后消息永远不会被重试。
///
/// ## 加载时机
///
/// 首次读取时 `load` 一次（从库里恢复上次会话未发完的条目）。若用户切换账号，
/// [OutboxQueue.userId] 与当前 userId 不一致，会重新 load 并丢弃旧队列的内存
/// 视图（存储层按 userId 过滤，互不干扰）。
final outboxQueueProvider = Provider<OutboxQueue>((ref) {
  final queue = OutboxQueue(
    store: ref.watch(outboxStoreProvider),
    // 投递实现：`request_id` = `entry.id`，故重试天然幂等（服务端按
    // `(user_id, request_id)` 去重，见 `chat/enqueue.go`）。
    //
    // ⚠️ 这里**不能**复用 `chatStreamControllerProvider` 的 `send`——那条路径
    // 会在失败时再次入队，形成环。队列只调 `ChatApi`，不做任何排队决策。
    send: (entry) => ref
        .read(chatApiProvider)
        .sendMessage(
          entry.userId,
          input: entry.input,
          groupId: entry.groupId,
          agentId: entry.agentId,
          routingMode: entry.routingMode,
          requestId: entry.id,
        ),
  );
  ref.onDispose(queue.dispose);
  // 启动时恢复上次未发完的条目。
  //
  // ## 为什么必须 `.future` 而不是 `.valueOrNull`
  //
  // `currentUserIdProvider` 是 `FutureProvider`，首次读取**必然 pending**
  // （没有 `valueOrNull` 那种「同步就能拿到」的情况）——用它会在冷启动时
  // 永远拿不到 id，队列永不恢复。故这里 await 真实 id。
  //
  // `ref.listen(..., fireImmediately: true)` 覆盖「进程启动时已登录」与
  // 「运行中登录/切换账号」两种情况：后者若换了 id，队列会重新 load（存储层
  // 按 userId 过滤，旧账号的条目留在库里不丢）。
  ref.listen(currentUserIdProvider.future, (_, next) {
    unawaited(
      next
          .then((id) async {
            if (id.isEmpty || queue.userId == id) return;
            await queue.load(id);
          })
          .catchError((Object _) {
            // 用户尚未登录（读 id 失败）：没什么可加载的，等下次登录再试。
          }),
    );
  }, fireImmediately: true);
  return queue;
});

/// 搜索消息内容（供 [SearchPage] 注入）。
///
/// ## 为什么在这里解析 userId
///
/// `ChatApi.search` 需要 userId，而页面不该知道「我是谁」是怎么来的（见
/// `SearchChat` 的说明）。在这里 `await currentUserIdProvider.future` 拿到
/// 真实 id 再发请求——**不做空串兜底**：`/users//chat/search` 会得到一个
/// 语义不明的 404，而报错信息完全指不出原因是「userId 没解析出来」
/// （与 issue #2 同源的陷阱）。
final searchChatProvider = Provider<SearchChat>((ref) {
  return (String query, {int? limit}) async {
    final userId = await ref.read(currentUserIdProvider.future);
    return ref.read(chatApiProvider).search(userId, query: query, limit: limit);
  };
});

/// 「立即发送」：把服务端缓冲区里 pending 的消息立即合并提交。
///
/// 返回 [FlushResult]：服务端在「有多条 pending 且未指定冲突策略」时返回
/// **HTTP 200** 加 `confirmation_required`（**什么都没提交**），调用方需要这个
/// 状态才能继续走「选策略 → 重试」。详见桌面端同名 provider。
final flushMessagesProvider = Provider.family<FlushPending, String>((
  ref,
  groupId,
) {
  return () async {
    final userId = await ref.read(currentUserIdProvider.future);
    final result = await ref
        .read(chatApiProvider)
        .flushMessages(userId, groupId: groupId);
    if (!result.needsConfirmation && !result.committed) {
      throw const ValidationError('没有可立即发送的待处理消息');
    }
    return result;
  };
});

/// 按指定冲突策略提交（`flushMessagesDetailed` 的装配）。
/// 与桌面端同步接线（两端构造点必须一致，否则一端功能缺失而测试仍绿）。
final flushWithStrategyProvider = Provider.family<FlushWithStrategy, String>((
  ref,
  groupId,
) {
  return (String strategy) async {
    final userId = await ref.read(currentUserIdProvider.future);
    return ref
        .read(chatApiProvider)
        .flushMessagesDetailed(
          userId,
          groupId: groupId,
          conflictStrategy: strategy,
        );
  };
});

// ==================== 跨 group 待确认收件箱 ====================

/// 待确认列表（首拉）。
final pendingConfirmationsProvider = FutureProvider<List<ChatConfirmation>>((
  ref,
) async {
  return ref.watch(chatApiProvider).listConfirmationsTyped(status: 'pending');
});

/// 当前待确认数量（供对话列表页角标）。
final pendingConfirmationCountProvider = FutureProvider<int>((ref) async {
  try {
    final items = await ref.watch(pendingConfirmationsProvider.future);
    return items.length;
  } on Object catch (e) {
    // 拉取失败不阻断对话列表渲染：角标静默为 0。
    //
    // 记 debug（issue #45）：角标为 0 与「确实没有待确认」**视觉上无法区分**
    // ——用户会以为没什么要处理的，而实际上是拉取失败了。这条日志是唯一的
    // 区分依据。（与桌面端同型，两端都有此 provider。）
    SpbLog.debug('待确认角标拉取失败，本次按 0 显示', {'error': e.toString()});
    return 0;
  }
});

// ==================== 对话流 ====================

/// 对话流控制器（按 userId 参数化）。
///
/// ## 为什么是 `family` 而不是内部取 userId（issue #2）
///
/// 原先在 provider 内部读 `currentUserIdProvider` 的 `.value` 并以空串兜底——
/// `currentUserIdProvider`
/// `.value` 为 null，于是空串兜底生效，构造出 `userId == ''` 的控制器，
/// SSE 连到 `/users//chat/stream`。
///
/// 用 `family` 把 userId 变成**必填的 String 参数**后，「userId 未就绪」在类型上
/// 无法表达——调用方必须先 `await` 到真实 id 才能拿到 provider（见 router.dart）。
///
/// ## 移动端为何更要 autoDispose
///
/// 它持有长连接 SSE。移动端离开页面后连接仍开着会**持续耗电与流量**
/// （系统可能因此限制后台网络），故页面退出即释放。
///
/// `onDispose` 里必须调 `dispose()`：它负责取消帧订阅并关闭三个
/// StreamController。Riverpod 只丢弃 Provider 实例，不会清理内部资源。
final chatStreamControllerProvider = Provider.autoDispose
    .family<ChatStreamController, String>((ref, userId) {
      final controller = ChatStreamController(
        sse: ref.watch(sseClientProvider),
        api: ref.watch(chatApiProvider),
        userId: userId,
        timelineCache: ref.watch(timelineCacheStoreProvider),
        outbox: ref.watch(outboxQueueProvider),
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// group 变更通知流（对话列表实时增量更新的数据源）。
///
/// 实现与理由见桌面端 `providers.dart` 的同名 provider（两端同构）：
///
/// - 对话列表页自身**没有** SSE 连接（连接由对话页 `start()` 建立），只加一个
///   `listen` 会「看起来做完了，但事件永远不来」；
/// - 用 [ChatStreamController.ensureConnected]：已有连接就不动它，否则以全局
///   模式建连（不回填任何 group 的时间线）；
/// - userId 未就绪时返回空流占位，`/api/auth/me` 返回后由 `ref.watch` 重建；
///   **不得**用空串兜底建连（那会连到 `/users//chat/stream`，见 issue #2）。
/// 返回 [ChatStreamController.groupUpdates]（逐条通知，**不是** AsyncValue）。
///
/// ## 为什么不是 StreamProvider
///
/// 两个原因：
///
/// 1. `StreamProvider` 的 `AsyncValue` 只保留**最后一条**事件，而
///    [GroupUpdate] 是逐条通知——created 后 deleted 与反过来结果不同，
///    只留最后一条会丢事件。（其 `.stream` 逐条转发访问器在 riverpod 3.x
///    已废弃移除。）
/// 2. 页面注入点的类型就是 `Stream<GroupUpdate>?`（便于单测直接塞一条假流），
///    这里返回裸流可以原样传递，不必再拆一层 AsyncValue。
///
/// ## 订阅时机是安全的（不会丢事件）
///
/// `ensureConnected()` 是异步的（要发 HTTP），而本 provider 与页面的
/// `listen` 注册发生在**同一帧内**、中间没有 await 点。故事件到达时
/// 订阅一定已经在了——broadcast 流「无监听者即丢弃」的特性不会咬到这里。
///
/// 若 userId 尚未就绪则返回空流：`/api/auth/me` 返回后 `ref.watch` 会让本
/// provider 与页面一起重建，那时才接上真正的流（页面的 `didUpdateWidget`
/// 会重订阅）。
final groupUpdatesProvider = Provider.autoDispose<Stream<GroupUpdate>>((ref) {
  final userId = ref.watch(currentUserIdProvider).value;
  if (userId == null || userId.isEmpty) {
    return const Stream<GroupUpdate>.empty();
  }

  final controller = ref.watch(chatStreamControllerProvider(userId));
  // 不 await：provider body 必须同步返回。ensureConnected 幂等——已有连接
  // （对话页建的聚焦模式）时是空操作，故不会抢走对话页的聚焦目标。
  unawaited(controller.ensureConnected());
  return controller.groupUpdates;
});

/// 带附件的无归属入口用例（悬浮输入窗用）。
///
/// ## 为什么**只**保留这一条链路
///
/// 服务端有两条无归属入口：
///
/// | 端点 | 返回 | 附件 |
/// |---|---|---|
/// | `/me/quick-capture` | 同步返回归属 group_id | ❌ |
/// | `/me/quick-capture/enqueue` | 异步投递，拿不到 groupId | ✅ |
///
/// 本端曾把两条都接上（各自一个页面、一个 provider、一个路由）。现在只留
/// enqueue：同步那条的**唯一入口早已指向本链路**（对话列表的 FAB），而纯文本
/// 场景下两者行为等价（都落到服务端分类链判定的同一个 group，差别只是
/// 「本页能否立刻导航过去」）。保留功能更弱的那个反而误导用户。
///
/// 桌面端已先做过同一取舍（commit 1866b14），本端此前只删了页面与路由、
/// 遗留了 provider，故一并清掉。共享库里的 `QuickCapturePage` /
/// `QuickCaptureUseCase` **不动**——它们仍被 `spb_features` 自己的测试覆盖，
/// 属共享能力。
///
/// ## 为什么不需要 userId
///
/// 与桌面端一致：`/me/*` 是用户级端点，服务端从网关注入的会话里解析身份，
/// 不接受路径参数。故这里不读 `currentUserIdProvider`——那会平白引入一个
/// 异步依赖（userId 未就绪时本 provider 就无法构造，而它本不依赖 userId）。
final quickCaptureEnqueueUseCaseProvider = Provider<QuickCaptureEnqueueUseCase>(
  (ref) {
    return QuickCaptureEnqueueUseCase(ref.watch(chatApiProvider));
  },
);

/// 文件拖入能力（移动端恒为空实现：触屏没有「拖入」这个交互）。
///
/// ## 为什么移动端也保留这个 provider（而不是在路由里直接传常量）
///
/// [OverlayQuickCapturePage] 要求一个非空的能力对象。移动端注入空实现后，
/// 页面上的「添加文件」按钮**仍然可用**——它走 `pickFilesForOverlay()`
/// （系统文件选择器），与拖拽是两条独立路径（见 `overlay_files.dart`）。
/// 空实现只影响「拖拽区」的存在，不影响附件功能。
///
/// 移动端不覆盖成真实实现：`desktop_drop` 在 Android/iOS 上不支持拖入。
final dragDropCapabilityProvider = Provider<DragDropCapability>((ref) {
  return const NoopDragDropCapability();
});

// ==================== 习惯（habit）====================
//
// 与桌面端逐字同构（两端共享同一组端点，见 `spb_api` 的 [HabitApi]）。
// **不抽到共享包**：`apps/*` 之间不互相依赖（只依赖 `packages/*`），且习惯
// 页面在两端的导航语义不同（移动端 `context.push` 会带底部标签栏）。

/// 习惯 API 客户端（与 [chatApiProvider] 共用同一个 [dioProvider]）。
final habitApiProvider = Provider<HabitApi>((ref) {
  return HabitApi(ref.watch(dioProvider));
});

/// 规则列表首拉（供 [HabitsPage.loadHabits] 注入）。
final habitsProvider = FutureProvider<List<UserHabit>>((ref) async {
  return ref.watch(habitApiProvider).listHabits();
});

/// 执行历史首拉（跨规则，含无 pattern 的候选建议记录）。
final habitRunsProvider = FutureProvider<List<HabitRun>>((ref) async {
  return ref.watch(habitApiProvider).listAllRuns();
});

// ==================== 交付物同步 ====================
//
// 移动端同样具备同步能力（把交付物拉到手机存储），但**没有目录选择器**：
// Android/iOS 的应用沙箱目录由系统分配，用户不选路径。故：
// - 目录固定为应用支持目录下的 `deliverables/`；
// - 同步页的「选择目录」按钮会被隐藏（页面读 `pickDirectory` 返回 null
//   即视为「无目录选择能力」，UI 上仍可用）。
//
// 设置页（含同步范围/媒体开关）在移动端的接入属后续任务；本轮先把 provider
// 与同步页接线补齐，使两端行为一致。

/// UFS API 客户端。
final ufsApiProvider = Provider<UfsApi>((ref) {
  return UfsApi(ref.watch(ufsDioProvider));
});

/// UFS 专用 Dio（baseUrl 与 PartyB API 不同，见桌面端同名 Provider 的说明）。
final ufsDioProvider = Provider<Dio>((ref) {
  final tokenProvider = ref.watch(sessionTokenProvider);
  final override = ref.watch(devUserHeaderOverrideProvider);
  final manager = ref.watch(sessionManagerProvider);

  final auth = AuthInterceptor(
    tokenProvider: tokenProvider,
    userHeaderOverride: override,
    // 与 [dioProvider] 同一取向：三态结论，暂时性失败不登出。
    onUnauthorizedOutcome: manager.refreshWithOutcome,
    // UFS 请求也会 401（同一个网关会话）。必须与 [dioProvider] 接到**同一个**
    // 状态推进点，否则「文件预览失败」不会把人带回登录页。
    onSessionExpired: _sessionExpiredHandler(ref),
  );

  final dio = createDio(
    baseUrl: SpbEndpoints.current.ufsBaseUrl,
    interceptors: [auth, _endpointRewrite(ufs: true)],
  );
  auth.replayDio = dio;
  return dio;
});

/// 本地同步数据库。
///
/// 用 `path_provider` 的应用支持目录（移动端唯一可写的持久位置）：
/// 同步状态必须**跨启动持久**，否则每次启动都退化成全量同步。
///
/// 路径是异步拿到的，故用 `openAppDatabaseLazy`（首次查询时才解析）。
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = openAppDatabaseLazy(() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'sync.db'));
  });
  ref.onDispose(db.close);
  return db;
});

/// 同步状态存储（具体类型，理由见桌面端同名 Provider）。
final syncStateStoreProvider = Provider<DriftSyncStateStore>((ref) {
  return DriftSyncStateStore(ref.watch(appDatabaseProvider));
});

/// 本地偏好存储。
final preferencesStoreProvider = Provider<PreferencesStore>((ref) {
  return PreferencesStore(ref.watch(appDatabaseProvider));
});

/// 同步目录：移动端**固定**为应用支持目录下的 `deliverables/`。
///
/// ## 为什么不用数据库里的绑定值
///
/// 那个绑定是给「用户可选目录」的桌面端用的。移动端没有目录选择器，
/// 用户选不了，故目录恒定；若去读绑定表反而会出现「表为空 → 未选目录 →
/// 同步报错」的假故障。
final syncLocalRootProvider = FutureProvider<String?>((ref) async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'deliverables');
});

/// 目录选择器：移动端**没有**该能力，恒返回 null（用户取消）。
///
/// 返回 null 而非抛异常：同步页把 null 当「用户取消」处理，于是按钮点了
/// 没有副作用——比抛异常后弹一个用户无法解决的错误要好。
final pickDirectoryProvider = Provider<PickSyncDirectory>((ref) {
  return ({String? title}) async => null;
});

/// 偏好键（与桌面端保持一致，便于将来跨端迁移偏好）。
///
/// ## 为什么没有对应的「过滤配置」provider
///
/// 本文件曾有一个「同步过滤配置」provider（读这两个键拼成
/// `SyncFilterConfig`），但它**没有任何 watch 点**——只有
/// `saveSyncSettingsProvider` 里一句 `ref.invalidate`，而 invalidate 一个无人
/// 订阅的 provider 是空操作。真正同步走 [runSyncActionProvider]，它直接读
/// `loadSyncSettingsProvider` 的 `settings.filter`。
///
/// 过滤配置的真源就是 **`SyncSettings.filter`**。
const String includeMediaPrefKey = 'sync.include_media';
const String maxFileSizePrefKey = 'sync.max_file_size';

/// 偏好键：同步范围（JSON，见 `SyncScopeConfig.encode`）。
const String scopePrefKey = 'sync.scope';

/// 偏好键：拉取范围（天）。缺省 = 不限历史。
const String sinceDaysPrefKey = 'sync.since_days';

/// 偏好键：自动同步（JSON，见 `AutoSyncConfig.encode`）。
///
/// ## 移动端为什么也读写它
///
/// 移动端**不装配排程器**（后台定时器在 Android/iOS 上不可靠，系统会冻结
/// 或杀掉进程），设置页也不渲染该区块（`SettingsPage.showAutoSync` 为
/// false）。但仍然原样读写这个键：同一份 `SyncSettings` 会在两端之间被
/// 传递（例如用户先在桌面端开过自动同步），若这里把字段丢掉，一次移动端
/// 保存就会**静默清掉**桌面端的配置——而用户完全不知道发生了什么。
///
/// 即：移动端「不实现」不等于「可以破坏」。
const String autoSyncPrefKey = 'sync.auto';

/// 触发一轮同步。
final runSyncActionProvider = Provider<RunSyncAction>((ref) {
  return () async {
    // 每次都重新读设置（同桌面端：用户可能刚改了范围/过滤）。
    final settings = await ref.read(loadSyncSettingsProvider)();

    final root = settings.localRoot;
    if (root == null || root.trim().isEmpty) {
      throw const PlatformError('未找到可用的同步目录');
    }

    final scope = settings.scope.toScope();
    final ufs = ref.read(ufsApiProvider);
    final useCase = DeliverableSyncUseCase(
      ufs: ufs,
      stateStore: ref.read(syncStateStoreProvider),
      sink: LocalFileSink(root),
      downloader: UfsFileDownloader(ufs),
    );

    return useCase.run(
      scope: scope,
      filter: settings.filter,
      sinceDays: settings.sinceDays,
    );
  };
});

/// 保存同步目录。
///
/// 移动端目录是系统分配的，用户改不了，故这是**空操作**（返回 false =
/// 未发生重置）。保留同名 Provider 是为了让同步页的 `onLocalRootChanged`
/// 回调在两端都能无条件接线，不必在页面里判平台。
final saveLocalRootActionProvider = Provider<Future<bool> Function(String?)>((
  ref,
) {
  return (String? root) async => false;
});

// ==================== 交付物浏览 ====================
//
// 与桌面端同名同构（`apps/spb_desktop/lib/providers.dart` 的「交付物侧边栏」
// 一节），装配理由见那里的类文档。
//
// ## 为什么移动端也需要这两个 Provider（此前只有桌面端有）
//
// 移动端此前只有**同步页**（把 workspace 全量拉到沙箱目录），没有「按对话
// 浏览本次产出」的入口。两者用途不同：同步页回答「本地有哪些文件」，本组
// Provider 回答「这个对话产出了什么」——后者是手机上最常问的问题，且不必先
// 跑一轮全量同步。

/// 拉取当前 group 的 workspace 交付物清单（UFS `/api/files` 分页汇总）。
///
/// ## 为什么分页拉全量而不是只拉一页
///
/// 面板要展示完整的目录树与准确的计数。只拉第一页会让「reports 目录 12 个
/// 文件」变成「只看到 20 条里的那部分」，且目录聚合数会偏小——一个**看起来
/// 正常但错误**的结果。
///
/// ## 为什么按 `path_prefix` 而不是按 group 过滤
///
/// UFS 的 `path_prefix` 让服务端只返回该子树下的条目（对齐 webapp
/// `listGroupWorkspaceFiles`）。客户端过滤需要先拉全量（生产 workspace 实测
/// 5666 条），流量与延迟都不可接受——移动端尤其如此。
///
/// ## 为什么是 autoDispose
///
/// 弹层只在一个对话页可见。`autoDispose` 让离开该 group 后释放缓存，避免长
/// 时间挂着每个打开过的 group 的清单（移动端内存比桌面端更紧张）。
final groupDeliverablesProvider = FutureProvider.autoDispose
    .family<List<UfsFileEntry>, String>((ref, groupId) async {
      if (groupId.isEmpty) return const [];
      final ufs = ref.watch(ufsApiProvider);

      const pageSize = 100;
      final all = <UfsFileEntry>[];
      var page = 1;
      // 上限防御：即使服务端 total 异常（例如恒大于已拉数），也不会无限循环。
      // 单 group 的交付物远超 100 页（1 万条）在现实中不存在，触顶即停并记日志。
      const maxPages = 100;
      while (page <= maxPages) {
        final res = await ufs.listFiles(
          pathPrefix: '$workspaceGroupsPrefix$groupId',
          page: page,
          pageSize: pageSize,
        );
        all.addAll(res.items);
        if (!res.hasMore(page: page, pageSize: pageSize)) break;
        page++;
      }
      if (page > maxPages) {
        SpbLog.warn('交付物分页达到上限，可能未拉全', {
          'group': groupId,
          'pages': maxPages,
          'count': all.length,
        });
      }
      return all;
    });

/// 下载一个交付物到本地，返回**用户可见的落地路径**。
///
/// ## 为什么落到应用支持目录而不是弹保存对话框
///
/// 下载一个交付物到本地，返回**用户可见的落地路径**。
///
/// 与桌面端同名 provider **同构**（布局、穿越防御、退化规则逐条一致）：
/// `downloads/deliverables/{groupId}/<group 内相对路径>`。
/// 移动端虽不能「定位到文件管理器」，但按 group 分目录仍然必要——否则
/// 不同对话的同名交付物会互相覆盖，而且用户在系统「文件」应用里分不清
/// 哪个文件属于哪个对话。
///
/// 与 `_downloadAgentFile`（时间线内联卡）同一取舍：保存对话框需要额外的
/// 平台插件与权限面，而「下载」本身只需要一个稳定的本地路径。落盘目录用
/// `downloads/deliverables/`，与时间线的 `downloads/agent/` 隔离——后者会被
/// 清理计划动，用户手动下载的不能被带上（与同步目录也隔离）。
final downloadDeliverableProvider = Provider<DownloadDeliverable>((ref) {
  return (UfsFileEntry file) async {
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(file.id);
    // 304 或空正文：内容未变/无内容，不覆盖本地（对齐同步链路的语义）。
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) {
      return '';
    }
    final dir = await getApplicationSupportDirectory();
    final root = Directory(p.join(dir.path, 'downloads', 'deliverables'));
    final rel = deliverableDownloadRelPath(file);
    final target = Directory(p.join(root.path, p.dirname(rel)));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final out = p.join(root.path, rel);
    await File(out).writeAsBytes(res.bytes!, flush: true);
    return out;
  };
});

// ==================== 交付物回传 ====================
//
// 与桌面端同名同构（装配逻辑见桌面端 providers.dart 的说明）：把 ChatApi/UfsApi
// 适配成回传用例的四个窄接口（适配器在 domain 共用）。差异只在目录来源——
// 移动端是固定的沙箱路径，没有「用户重选目录」的问题。
// 语义与设计决策见 docs/deliverable-upload-and-conflict.md。

/// 上传发送器（ufs-upload）。
final uploadSenderProvider = Provider<UploadSender>((ref) {
  return ChatApiUploadSender(ref.watch(chatApiProvider));
});

/// quick-capture 附件链发送器（413 兜底）。
final uploadQuickCaptureSenderProvider = Provider<QuickCaptureSender>((ref) {
  return ChatApiQuickCaptureSender(ref.watch(chatApiProvider));
});

/// 远端 workspace 清单 + 下载（etag 预检与冲突物化用）。
final uploadRemoteWorkspaceProvider = Provider<RemoteWorkspace>((ref) {
  return UfsRemoteWorkspace(ref.watch(ufsApiProvider));
});

/// 通知器工厂（把当前用户 id 绑进去，见桌面端同名 Provider 的说明）。
final uploadNotifierFactoryProvider = Provider<UploadNotifier Function(String)>(
  (ref) {
    final api = ref.watch(chatApiProvider);
    return (String userId) => ChatApiUploadNotifier(api, userId);
  },
);

/// 本地文件读取器工厂（与桌面端同名；移动端目录恒定，但保留工厂形态
/// 让两端动作 provider 逐字一致，差异只留在目录来源）。
final uploadFileReaderFactoryProvider =
    Provider<LocalFileReader Function(String)>((ref) {
      return (String localRoot) => LocalFileSink(localRoot);
    });

/// 回传是否在途（与桌面端同名同构；移动端无托盘，但保留状态供 UI 禁用按钮）。
final uploadInFlightProvider = NotifierProvider<UploadInFlightNotifier, bool>(
  UploadInFlightNotifier.new,
);

/// 回传在途状态（与桌面端同名同构）。
class UploadInFlightNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state == value) return;
    state = value;
  }
}

/// 扫描本地改动（回传第一步）。
final scanDirtyFilesActionProvider = Provider<ScanDirtyFilesAction>((ref) {
  return () async {
    final settings = await ref.read(loadSyncSettingsProvider)();
    final root = settings.localRoot;
    if (root == null || root.trim().isEmpty) {
      throw const PlatformError('未找到可用的同步目录');
    }

    final stateKey = syncStateKeyFor(settings.scope.toScope());
    final state = await ref.read(syncStateStoreProvider).load(stateKey);

    return scanLocalDirtyFiles(
      reader: ref.read(uploadFileReaderFactoryProvider)(root),
      state: state,
      filter: settings.filter,
      stateKey: stateKey,
    );
  };
});

/// 回传**选中的**本地改动（第二步）。
///
/// `finally` 复位在途状态（异常路径也复位，同桌面端）。
final uploadChangesActionProvider = Provider<UploadChangesAction>((ref) {
  return (Set<String> only) async {
    ref.read(uploadInFlightProvider.notifier).set(true);
    try {
      final settings = await ref.read(loadSyncSettingsProvider)();
      final root = settings.localRoot;
      if (root == null || root.trim().isEmpty) {
        throw const PlatformError('未找到可用的同步目录');
      }

      // 通知消息要 userId；解析失败（未登录/网络）就直接失败，不做空串兜底。
      final userId = await ref.read(currentUserIdProvider.future);

      final useCase = DeliverableUploadUseCase(
        reader: ref.read(uploadFileReaderFactoryProvider)(root),
        stateStore: ref.read(syncStateStoreProvider),
        remote: ref.read(uploadRemoteWorkspaceProvider),
        uploader: ref.read(uploadSenderProvider),
        quickCapture: ref.read(uploadQuickCaptureSenderProvider),
        notifier: ref.read(uploadNotifierFactoryProvider)(userId),
        userId: userId,
      );

      return await useCase.run(
        scope: settings.scope.toScope(),
        filter: settings.filter,
        only: only,
      );
    } finally {
      ref.read(uploadInFlightProvider.notifier).set(false);
    }
  };
});

// ==================== 设置页 ====================

/// 读取完整的同步设置（表单的初值）。
///
/// 与桌面端的差异：目录**不是**从数据库绑定读，而是恒定的沙箱路径
/// （移动端没有目录选择器）。见 [syncLocalRootProvider]。
final loadSyncSettingsProvider = Provider<LoadSyncSettings>((ref) {
  return () async {
    final prefs = ref.read(preferencesStoreProvider);
    final root = await ref.read(syncLocalRootProvider.future);

    return SyncSettings(
      localRoot: root,
      scope: SyncScopeConfig.decode(await prefs.getString(scopePrefKey)),
      filter: SyncFilterConfig(
        includeMedia: await prefs.getBool(
          includeMediaPrefKey,
          defaultValue: false,
        ),
        maxFileSize: await prefs.getInt(
          maxFileSizePrefKey,
          defaultValue: defaultMaxFileSize,
        ),
      ),
      sinceDays: await _readSinceDays(prefs),
      auto: AutoSyncConfig.decode(await prefs.getString(autoSyncPrefKey)),
    );
  };
});

/// 保存同步设置（**整份提交**）。
///
/// 移动端**不写目录**：目录是系统分配的，写了也不会生效（下次读仍从
/// `path_provider` 取）。其余字段正常落盘。
final saveSyncSettingsProvider = Provider<SaveSyncSettings>((ref) {
  return (SyncSettings settings) async {
    final prefs = ref.read(preferencesStoreProvider);

    await prefs.setString(scopePrefKey, settings.scope.encode());
    await prefs.setBool(
      includeMediaPrefKey,
      value: settings.filter.includeMedia,
    );
    await prefs.setInt(maxFileSizePrefKey, value: settings.filter.maxFileSize);

    final days = settings.sinceDays;
    if (days == null || days <= 0) {
      await prefs.remove(sinceDaysPrefKey);
    } else {
      await prefs.setInt(sinceDaysPrefKey, value: days);
    }

    // 原样写回（本端不消费它，但**不能丢**，见 [autoSyncPrefKey] 的说明）。
    await prefs.setString(autoSyncPrefKey, settings.auto.encode());

    // 无需 invalidate：过滤/范围/天数的真源是 `SyncSettings`，而
    // `loadSyncSettingsProvider` 是个普通 `Provider`（不是 FutureProvider），
    // 每次调用都现读偏好表。
    //
    // 尤其**不要** invalidate `syncLocalRootProvider`：移动端目录由系统分配
    // （`getApplicationSupportDirectory`），本方法从不写目录，invalidate 它
    // 只会白跑一次 IO。
  };
});

/// 读取可勾选的对话列表（同步范围用）。
final loadSyncGroupsProvider = Provider<LoadSyncGroups>((ref) {
  return () async {
    final api = ref.read(chatApiProvider);
    return api.listGroups(limit: 200);
  };
});

/// 扫描本地同步目录（清理与统计用）。
final scanLocalGroupsProvider = Provider<ScanLocalGroups>((ref) {
  return () async {
    final root = await ref.read(syncLocalRootProvider.future);
    if (root == null || root.trim().isEmpty) return const [];
    return scanLocalGroups(root);
  };
});

/// 执行清理计划。
final executePruneProvider = Provider<ExecutePrune>((ref) {
  return (PrunePlan plan) async {
    final root = await ref.read(syncLocalRootProvider.future);
    if (root == null || root.trim().isEmpty) {
      throw const PlatformError('未找到可用的同步目录');
    }
    return executePrunePlan(localRoot: root, plan: plan);
  };
});

// ==================== 小程序工作台（miniapp BFF）====================
//
// 与桌面端不同：**只有移动端**接这组端点（它是为小程序/移动端做的投影层）。
//
// 页面全部依赖注入（见 `miniapp.dart` 的说明），故这里只做「把 MiniappApi
// 的方法绑成页面要的回调」，不含业务规则。

/// 小程序 BFF 客户端。
///
/// 与 [chatApiProvider] 共用同一个 [dioProvider]（同一 baseUrl + 同一认证
/// 拦截器），只是端点前缀不同（`/chat/miniapp/*` 也在 PartyB API 下）。
final miniappApiProvider = Provider<MiniappApi>((ref) {
  return MiniappApi(ref.watch(dioProvider));
});

/// 工作列表（供 [WorksPage] 注入）。
final loadMiniappWorksProvider = Provider<LoadMiniappWorks>((ref) {
  final api = ref.watch(miniappApiProvider);
  return ({String status = 'active', int? cursor}) =>
      api.listWorks(status: status, cursor: cursor);
});

/// 新建工作（供 [WorksPage] 注入）。
///
/// ## 为什么不传 templateId / goal
///
/// 服务端两者都是可选的（`internal/server/miniapp.go` 的 `createWork`：`goal`
/// 留空写 NULL，`template_id` 直接进 metadata，均无 `binding:"required"`）。
/// Taro 参考实现也是 `client.createWork({})`。传空参即建一个空工作，标题由
/// 服务端置占位符「新会话」，首轮后 Title Gate 生成语义标题。
///
/// 返回值是 `workId`（= group id），供调用方导航到详情。
final createMiniappWorkProvider = Provider<CreateMiniappWork>((ref) {
  final api = ref.watch(miniappApiProvider);
  return () async {
    final result = await api.createWork();
    return result.workId;
  };
});

/// 上传附件到指定工作（供 [WorkDetailPage] 注入）。
///
/// 用 `family` 把 workId 变成必填参数：与其余 miniapp 注入点同一约定，避免
/// 出现 `/works//files` 这种语义不明的 404。
///
/// ## 为什么丢弃返回的 artifact
///
/// 页面在上传后统一 `_reload()`（见 `UploadWorkFile` 的说明）：服务端重新
/// 投影的产物列表才是权威口径，本地拼一个可能与事件投影的 id 口径不一致。
final uploadMiniappFileProvider = Provider.family<UploadWorkFile, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return ({required String filename, required List<int> bytes}) async {
    await api.uploadFile(workId, bytes: bytes, filename: filename);
  };
});

/// 工作详情（供 [WorkDetailPage] 注入）。
///
/// 用 `family` 把 workId 变成必填参数——workId 未就绪在类型上无法表达，
/// 避免出现 `/works//` 这种语义不明的 404（与 issue #2 同源的陷阱）。
final loadMiniappWorkDetailProvider = Provider.family<LoadWorkDetail, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return () => api.getWork(workId);
});

/// 工作事件。
///
/// ⚠️ 返回的是 `MiniappWorkEvent`（数据库原始行），**不是** `ChatEvent`——
/// 用 `ChatEvent.fromJson` 解析会抛 `FormatException`（键名是 `id` 不是
/// `eventId`）。详见该类文档。
final loadMiniappWorkEventsProvider = Provider.family<LoadWorkEvents, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return () => api.workEvents(workId);
});

/// 产物列表。
final loadMiniappArtifactsProvider = Provider.family<LoadWorkArtifacts, String>(
  (ref, workId) {
    final api = ref.watch(miniappApiProvider);
    return () => api.listArtifacts(workId);
  },
);

/// 下载产物字节。
final downloadMiniappArtifactProvider =
    Provider.family<DownloadArtifact, String>((ref, workId) {
      final api = ref.watch(miniappApiProvider);
      return (artifactId) => api.downloadArtifact(workId, artifactId);
    });

/// 保存下载到的字节到应用沙箱，返回落地路径。
///
/// ## 为什么写入 `deliverables/miniapp/`
///
/// 与交付物同步的目录（`syncLocalRootProvider` 的 `deliverables/`）分开：
/// 同步目录的内容由同步游标管理（会被清理计划删除），而这里是用户**主动**
/// 下载的产物——混在一起会让清理把用户手动下载的文件也删掉。
final saveMiniappArtifactProvider = Provider<SaveArtifactBytes>((ref) {
  return (String filename, List<int> bytes) async {
    final dir = await getApplicationSupportDirectory();
    final target = Directory(p.join(dir.path, 'deliverables', 'miniapp'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    // 只取 basename：服务端的 name 可能是路径（事件投影取的是 basename，
    // 但上传来源的 entry.Name 不保证），拼进来会造成路径穿越。
    final safeName = p.basename(filename.isEmpty ? 'artifact' : filename);
    final file = File(p.join(target.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  };
});

/// 发送工作消息。
final sendMiniappMessageProvider = Provider.family<SendWorkMessage, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return (input) => api.sendMessage(workId, input: input);
});

/// 完成工作。
final completeMiniappWorkProvider = Provider.family<CompleteWork, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return () => api.completeWork(workId);
});

/// 停止工作。
final stopMiniappWorkProvider = Provider.family<StopWork, String>((
  ref,
  workId,
) {
  final api = ref.watch(miniappApiProvider);
  return () => api.stopWork(workId);
});

/// 解决确认卡（**不带** group_id 的路径，与 webapp 那套不同）。
final resolveMiniappConfirmationProvider = Provider<ResolveMiniappConfirmation>(
  (ref) {
    final api = ref.watch(miniappApiProvider);
    return (confirmationId, action) =>
        api.resolveConfirmation(confirmationId, action: action);
  },
);

// ==================== 通知订阅额度 ====================

/// 读取通知订阅额度（供设置页注入）。
///
/// ## 503 由页面处理，provider 不吞
///
/// 数据库不可用时服务端返回 503，`MiniappApi` 会抛 `HttpError(503)`。这里
/// **不**把它转成空列表：空列表会被页面渲染成「四个模板都未开启」，而实际是
/// 「读不到」。页面据此显示「暂时不可用 + 重试」。
final loadNotificationSubscriptionsProvider =
    Provider<LoadNotificationSubscriptions>((ref) {
      final api = ref.watch(miniappApiProvider);
      return api.listNotificationSubscriptions;
    });

/// 保存通知订阅额度（供设置页注入）。
///
/// `n > 0` 累加额度（服务端 `AddQuota`）、`n == 0` 归零并禁用（`ResetQuota`）。
/// 页面只会传 [MiniappNotificationTemplates.all] 里的 key——未知 key 服务端
/// 整体 400（不是忽略该项）。
final saveNotificationSubscriptionsProvider =
    Provider<SaveNotificationSubscriptions>((ref) {
      final api = ref.watch(miniappApiProvider);
      return api.saveNotificationSubscriptions;
    });

// ==================== 主题模式 ====================

/// 主题模式控制器。
///
/// ## 为什么 `build()` 里同步返回 system 再异步纠正
///
/// `Notifier.build()` 必须**同步**返回一个值，而偏好读的是数据库（异步）。
/// 故先返回 `ThemeMode.system`（与「从未设置过」的默认行为一致），随后
/// `unawaited(restore())` 把真实值补上。这与 [AuthStateNotifier] 用
/// `AuthState.unknown` 占位是同一手法。
///
/// 代价是启动瞬间可能用 system 渲染一帧再切到用户设的模式（如果用户设的是
/// 深色而系统是浅色，会闪一下）。可接受：读取是本机数据库的一次查询，
/// 通常在同一帧内完成；若要彻底消除，得把偏好读取提到 `runApp` 之前
/// ——那会让启动多一次 await，代价更大。
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    unawaited(restore());
    return ThemeMode.system;
  }

  /// 从偏好存储恢复。
  Future<void> restore() async {
    try {
      final prefs = ref.read(preferencesStoreProvider);
      final raw = await prefs.getString(SpbThemeMode.prefKey);
      state = SpbThemeMode.decode(raw);
    } catch (e) {
      // 读不到就保持 system：偏好是配置，不该让应用起不来。
      SpbLog.warn('恢复主题模式失败', {'error': e.toString()});
    }
  }

  /// 设置并持久化。
  ///
  /// 先改 `state` 再落盘：主题要即时生效，落盘失败也不该让界面停在上一个
  /// 模式（下次启动会回到旧值，用户能看出「没存住」并重试）。
  Future<void> setMode(ThemeMode mode) async {
    if (state == mode) return;
    state = mode;
    try {
      final prefs = ref.read(preferencesStoreProvider);
      await prefs.setString(SpbThemeMode.prefKey, SpbThemeMode.encode(mode));
    } catch (e) {
      SpbLog.warn('保存主题模式失败', {'error': e.toString()});
    }
  }
}

/// 当前主题模式。
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  ThemeModeNotifier.new,
);

/// 读取主题模式（供设置页注入）。
final loadThemeModeProvider = Provider<LoadThemeMode>((ref) {
  return () async {
    final prefs = ref.read(preferencesStoreProvider);
    return SpbThemeMode.decode(await prefs.getString(SpbThemeMode.prefKey));
  };
});

/// 保存主题模式（供设置页注入）。
///
/// 走 `themeModeProvider` 而不是直接写库：这样设置页的改动会立刻反映到
/// `MaterialApp.router` 的 `themeMode` 上（两者读的是同一个 provider）。
final saveThemeModeProvider = Provider<SaveThemeMode>((ref) {
  return (mode) => ref.read(themeModeProvider.notifier).setMode(mode);
});

// ==================== 用户偏好 ====================

/// 读取用户偏好（供设置页注入）。
///
/// 失败**不吞**：设置页需要区分「读到空偏好」与「读不到」——后者应显示重试
/// 入口，而不是渲染一个看起来像「你的偏好是空的」的空表单（用户可能就此
/// 覆盖掉真实值）。
final loadUserPreferencesProvider = Provider<LoadUserPreferences>((ref) {
  final api = ref.watch(chatApiProvider);
  return api.getPreferences;
});

/// 保存用户偏好（供设置页注入）。
///
/// ## 空值参数是「不改」而非「清空」
///
/// 直接转发给 `ChatApi.updatePreferences`：它只把**非 null** 的键拼进 body
/// （服务端是部分更新语义）。清空某项要显式传空串。
///
/// ## 不做本地缓存
///
/// 返回的是服务端**回读的生效值**，页面直接用它替换本地状态。在本层再存一份
/// 只会制造第二个真源（另一台设备改了之后本层不知道）。
final saveUserPreferencesProvider = Provider<SaveUserPreferences>((ref) {
  final api = ref.watch(chatApiProvider);
  return api.updatePreferences;
});

// ==================== Agent 目录与会话切换 ====================

/// Agent API 客户端。
///
/// 单独一个 provider（而非复用 `chatApiProvider`）：`/api/agents` 与
/// `/chat/*` 是两套命名空间，分开便于将来按需替换/禁用。
final agentsApiProvider = Provider<AgentsApi>((ref) {
  return AgentsApi(ref.watch(dioProvider));
});

/// 读取可选 agent 列表（供对话页的切换入口注入）。
///
/// ## 失败不吞成空列表
///
/// 空列表会让入口**隐藏**——与「真的没有 agent」表现相同。而入口自身已把
/// 「加载失败」处理为「隐藏 + 记日志」（见 `AgentSwitcher` 的类文档），故这里
/// 直接抛出即可，不必转成空列表（转了就丢失了「失败」这一信息）。
final loadAgentsProvider = Provider<LoadAgents>((ref) {
  final api = ref.watch(agentsApiProvider);
  return api.listAgents;
});

/// 设置页「默认 Agent」下拉的候选项。
///
/// ## 为什么要单独包一层 FutureProvider
///
/// [loadAgentsProvider] 是同步 `Provider<LoadAgents>`（返回 `Future`），而
/// `SettingsPage` 是 StatefulWidget、收的是**已解析**的
/// `List<PreferenceAgentOption>`——不能直接喂 `AsyncValue`。这里做两件事：
/// 把 Future 解析掉，并把 `Agent` 映射成卡片要求的最小类型
/// （`PreferenceAgentOption(id, name)`，理由见 `user_preferences_card.dart`
/// 的类文档：卡片不需要 provider / skills / status 这些字段）。
///
/// ## 调用点用 `.value ?? const []`，不因列表晚到而重建表单
///
/// 若改成把 `AsyncValue` 整体喂给页面（loading 时换成一个转圈占位），
/// `UserPreferencesCard` 的 `State` 会被销毁重建，**用户已填的草稿全部丢失**
/// ——这与设置页已确立的「草稿 vs 权威值」约定（改动不即时落盘、只有点保存
/// 才提交）直接冲突。
///
/// 用 `.value ?? const []` 则**整棵树形状不变**：agent 列表晚到时只是下拉的
/// `items` 多出几项，`State` 一直存活，草稿不受影响。代价是列表未就绪/加载
/// 失败时下拉只有「自动」一项（与「本端确实没接」表现相同）——不谎报失败，
/// 也不因一个可选下拉而阻塞整个表单。
///
/// ## 服务端只返回 active
///
/// `AgentsApi.listAgents` 走 `GET /api/agents`，服务端 `ListAgents` 已按
/// `filterActive` 过滤。已归档/已删除的 agent 不在列表里，故若用户曾把它设为
/// 默认值，卡片会用「（已失效）」那一项兜住（见 `_buildDefaultAgent`）。
final preferenceAgentOptionsProvider =
    FutureProvider<List<PreferenceAgentOption>>((ref) async {
      final agents = await ref.watch(loadAgentsProvider)();
      return [
        for (final a in agents) PreferenceAgentOption(id: a.id, name: a.name),
      ];
    });

/// 读取 `since_days`：缺失、非法、`<= 0` 都视为「不限」。
Future<int?> _readSinceDays(PreferencesStore prefs) async {
  final raw = await prefs.getString(sinceDaysPrefKey);
  if (raw == null) return null;
  final parsed = int.tryParse(raw);
  if (parsed == null) {
    SpbLog.warn('since_days 偏好不是合法整数，按「不限」处理', {'value': raw});
    return null;
  }
  return parsed > 0 ? parsed : null;
}
