import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'auth_loopback.dart';

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

/// 本地通知发送能力（issue #21）。
///
/// 默认是 [NoopNotificationSink]：`flutter test` 里没有平台通道，
/// 真实实现会在 `initialize()` 时抛 `MissingPluginException`（已捕获并降级，
/// 但默认 Noop 更明确）。生产在 `main.dart` 覆盖为 [LocalNotificationSink]。
///
/// ## 为什么非 autoDispose
///
/// 它持有平台插件的实例与「权限是否已请求」的缓存——随页面重建会重复请求权限。
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

/// 确认卡到达时发 OS 通知（issue #21）。
///
/// 判定逻辑（判重 / 前台不打扰 / 权限幂等）在 `spb_domain` 的
/// [ConfirmationNotifier]，此处只做装配：注入 sink 与聚焦状态、接上点击导航。
///
/// ## 为什么非 autoDispose（判重集合必须跨页面重建存活）
///
/// 判重集合若随对话页重建而丢失，SSE 重连回放会让同一张确认卡重复弹通知。
/// 故本 provider 的生命周期与 app 一致。
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

/// 是否展示「诊断」侧边栏 tab（工具调用 + gate 决策）。
///
/// ## 为什么是 provider 而不是直接写 `if (!SpbEnv.isRelease)`
///
/// [SpbEnv.isRelease] 是 `bool.fromEnvironment('dart.vm.product')`——**编译期
/// 常量**。若在 `router.dart` 里直接判定，widget test 无法切换它（测试跑在
/// JIT 下，`isRelease` 恒为 false），于是「发布包里诊断 tab 真的消失了吗」
/// 这个行为**无法被任何测试验证**。
///
/// 包一层 provider 后，测试可以 `showDebugPanelProvider.overrideWithValue(false)`
/// 断言 tab 消失、其余 tab 仍在，同时生产路径仍读同一个 `isRelease`。
///
/// ## 为什么要门控它
///
/// 该面板展示**工具调用入参与 gate 决策明细**（含 prompt 片段、路由判定
/// 理由）。它是开发/排查用的内部视图，不应出现在发布包里——普通用户既
/// 看不懂，其中内容也不适合随包分发。
///
/// ## 为什么默认值就是 `!SpbEnv.isRelease`（而非默认 true）
///
/// 默认值即生产行为：忘改/新增调用点时不会意外把诊断入口带到发布包。
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

/// 会话凭证存储（Keychain / Keystore / libsecret）。
///
/// 由 [SecureTokenStore] 实现，非 autoDispose：它无状态，重建无意义。
final tokenStoreProvider = Provider<TokenStore>((ref) {
  return SecureTokenStore();
});

/// OIDC 配置（编译期注入，见 `SpbEnv.oidcIssuer` 等）。
///
/// `clientSecret` 传 null：生产不在客户端内嵌密钥（IdP 的 token 端点要求
/// `client_secret_basic`/`post`，而客户端无法安全保存）——生产走网关托管流程。
final oidcConfigProvider = Provider<OidcConfig>((ref) {
  return OidcConfig.fromEnv();
});

/// OIDC 客户端（刷新凭证用）。
final oidcClientProvider = Provider<OidcClient>((ref) {
  return OidcClient(config: ref.watch(oidcConfigProvider));
});

/// 会话管理器：负责「拿到可用 token」与「过期前刷新（并发去重）」。
///
/// 刷新实现把 [OidcTokens] 适配成 [StoredTokens]。
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
///
/// 用 `Provider`（非 autoDispose）：Dio 持有连接池，随页面销毁重建会丢掉
/// keep-alive 连接，得不偿失。
final dioProvider = Provider<Dio>((ref) {
  final tokenProvider = ref.watch(sessionTokenProvider);
  final override = ref.watch(devUserHeaderOverrideProvider);
  final manager = ref.watch(sessionManagerProvider);

  final auth = AuthInterceptor(
    tokenProvider: tokenProvider,
    // 生产为 null（见 devUserHeaderOverrideProvider 的说明）。
    userHeaderOverride: override,
    // 401 时刷新凭证并重放原请求。用 `refreshWithOutcome` 而非 `refresh`：
    //
    // 刷新失败有**两种含义相反**的情形（见 `TokenRefreshStatus`）：
    // - 服务端明确拒绝（`invalid_grant`）→ 确实该回登录页；
    // - 网络层失败（休眠唤醒 / 切网）→ **保留登录态**，下次请求再试。
    //
    // 用旧的布尔回调会把后者也当成「无法刷新」，于是「放置一段时间就被登出、
    // 关闭重开又正常」（2026-10 用户报障）。
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
  // 回填重放用的 Dio：必须是同一个实例（否则丢掉连接池与其余拦截器），
  // 而它又是本拦截器的构造参数之一，只能构造后回填。
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
/// ## 不 autoDispose：切 group 只换聚焦目标、**不重连**
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

/// 发起登录的动作（桌面端：RFC 8252 §7.3 loopback 授权码流程）。
///
/// ## 流程与返回值语义（与旧的「网关托管 + 粘贴导入」的区别）
///
/// `loopbackSignIn` 会**同步等到 token**：起本地监听 → 开系统浏览器 → 收回调
/// → 换 token。所以这里的动作不只是「发起」，还要把 token 落盘并把状态推进到
/// 已登录——这与移动端深链接收器的职责相同（见移动端 `onCode` 回调）。
///
/// 返回 null 表示登录完成；字符串是用户可见的失败原因。
/// 抽成 Provider 而非直接调用，使测试能注入假实现。
///
/// ## 为什么直连 IdP 而不是网关
///
/// 网关把 redirect_uri 硬编码为自己的回调，客户端拿不到 code（见
/// `auth_loopback.dart` 的说明）。要求 IdP 存在 public client
/// （`token_endpoint_auth_method=none` + `http://127.0.0.1/callback` 注册），
/// 见 `docs/rfc8252-loopback-signin.md`。未配置时登录页会显示导入会话入口，
/// 粘贴导入仍是可用的降级路径。
/// loopback 登录的实现（可注入，供测试替换真实的网络/浏览器流程）。
///
/// ## 为什么抽成 provider
///
/// `signInActionProvider` 里除了「跑流程」还有一步**落盘**（把 [OidcTokens]
/// 转成 [StoredTokens] 写入安全存储）。那一步正是「登录成功后立刻 401」的
/// 缺陷所在（曾写 `accessToken: tokens.accessToken`，而网关只验 RS256 JWT）。
/// 真实 `loopbackSignIn` 要开浏览器 + 监听本地端口，测试里不可能跑，于是
/// 那段代码只能靠 `StoredTokens.fromOidcTokens` 的单测间接覆盖——
/// **接线本身**没人钉住。注入后可以喂一份「真实形态」的 token 响应，
/// 断言落盘的是 `id_token`（见 `test/router_chat_test.dart`）。
typedef LoopbackSignIn = Future<LoopbackSignInResult> Function({
  required OidcConfig config,
});

final loopbackSignInProvider = Provider<LoopbackSignIn>((ref) {
  return ({required OidcConfig config}) => loopbackSignIn(config: config);
});

final signInActionProvider = Provider<Future<String?> Function()>((ref) {
  return () async {
    final result = await ref.read(loopbackSignInProvider)(
      config: ref.read(oidcConfigProvider),
    );
    final err = result.error;
    if (err != null) return err;

    // 落盘并推进状态（与移动端 onCode 相同的三步）。
    //
    // ⚠️ 用 `fromOidcTokens`，**不要**手写映射：这里曾写成
    // `accessToken: tokens.accessToken`，把 fosite 的不透明 `ory_at_…` 当
    // Bearer 发给网关，导致「登录刚成功就提示会话已失效」（网关只验 RS256
    // JWT，见 `OidcTokens.bearerToken` 的说明）。
    final tokens = result.tokens!;
    try {
      await ref
          .read(tokenStoreProvider)
          .write(StoredTokens.fromOidcTokens(tokens));
    } on SpbError catch (e) {
      SpbLog.warn('loopback 登录后写入安全存储失败', {'error': e.toString()});
      return e.message;
    }
    ref.read(authStateProvider.notifier).signedIn();
    return null;
  };
});

/// 认证状态（登录页与路由守卫共享）。
///
/// ## 为什么是 `NotifierProvider` 而不是 `StateProvider`
///
/// Riverpod 3 已把 `StateProvider` 移入 `legacy.dart`（不鼓励新代码使用），
/// 且它无法表达「带方法的控制器」。用 `Notifier` 让状态变更集中在一个类里
/// （`restore` / `signIn` / `signedIn` / `signOut`），避免散落的
/// `ref.read(...notifier).state = ...`。
final authStateProvider = NotifierProvider<AuthStateNotifier, AuthState>(
  AuthStateNotifier.new,
);

/// 认证状态控制器。
///
/// ## 职责边界
///
/// - **负责**：把「有无可用凭证」翻译成 [AuthState]，并在启动时恢复；
/// - **不负责**：凭证的读写与刷新（那是 `SessionManager` / `TokenStore`），
///   也不负责打开浏览器（那是 [signInActionProvider]）。
class AuthStateNotifier extends Notifier<AuthState> {
  @override
  AuthState build() {
    // build 必须同步返回。启动恢复是异步的，故先给 unknown，
    // 由 [restore] 在首帧后推进——路由守卫在 unknown 时不重定向。
    unawaited(restore());
    return AuthState.unknown;
  }

  /// 从安全存储恢复登录态。
  ///
  /// 启动时调用一次。凭证已过期且无法刷新时（`currentAccessToken` 返回 null）
  /// 判定为未登录，并**清除**残留凭证，避免下次启动又白跑一次刷新。
  Future<void> restore() async {
    final manager = ref.read(sessionManagerProvider);
    try {
      final token = await manager.currentAccessToken();
      if (token == null) {
        // 有残留但不可用 → 清掉（可能是 refresh_token 已被 IdP 作废）。
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

  /// 发起登录（用户点「使用 SSO 登录」）。
  ///
  /// 返回失败原因（null 表示已成功发起）。**不在此处把状态改成已登录**：
  /// 授权在浏览器里完成，本进程此刻还不知道结果。真正的状态变更发生在
  /// 凭证落盘之后（由 [signedIn] 或下一次 [restore] 触发）。
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
    // ## 为什么**不能**无条件写 `unknown`（曾因此「登录成功却停在登录页」）
    //
    // 桌面端 `signInAction` 是**同步等到 token** 的（loopback 流程）：它在内部
    // 落盘凭证并调 [signedIn]，返回时状态已是 `authenticated`。若无条件写
    // `unknown`，刚拿到的已登录会被盖掉，而守卫在 unknown 时**不重定向**
    // （那是启动期的正常态），于是用户永远停在 `/login`。
    //
    // 移动端的真实流程是「只发起 → 等深链回调」，返回时确实该是 unknown；
    // 但回调可能先于本方法返回（同轮完成），故判据不是「谁先谁后」，而是
    // 「**别把已登录改回未判定**」——`unknown` 的语义是「还不知道」，
    // 已经知道的事不该被它覆盖。
    if (!state.isAuthenticated) {
      state = const AuthState(status: AuthStatus.unknown, message: null);
    } else if (state.message != null) {
      state = state.copyWith(clearMessage: true);
    }
    return null;
  }

  /// 凭证已落盘（回调收到 token 后调用）。
  void signedIn() => state = AuthState.authenticated;

  /// 粘贴导入已有会话（桌面端登录闭环的入口）。
  ///
  /// ## 为什么走「落盘 + restore()」而不是直接 `state = authenticated`
  ///
  /// 状态必须反映**存储里真的有一份可用凭证**，而不是「用户说他粘贴了」。
  /// `restore()` 会调 `SessionManager.currentAccessToken()`，它顺带处理了
  /// 「token 已过期但有 refresh_token」的情形（自动刷新）。
  ///
  /// 直接置位会造出一个**假状态**：界面显示已登录，但每个请求都 401，
  /// 用户完全看不出问题出在哪。复用 restore 还避免了新增状态机分支——
  /// 「凭证可用性」的判定只有一处。
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
      // 安全存储写失败（如 Linux 上 keyring 不可用）：不能假装成功，
      // 否则状态会变成「已登录」而凭证其实没落盘。
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

  /// 标记会话失效（如收到 [AuthError]）。**不清凭证**：
  /// 401 可能是网关侧临时问题，清掉会让用户丢失 refresh_token。
  void markUnauthenticated(String? message) {
    state = message == null
        ? AuthState.unauthenticated
        : AuthState.failed(message);
  }
}

/// 认证动作集合（供 UI 调 signIn / signOut，不订阅状态）。
///
/// UI 应 `watch` [authStateProvider] 拿状态，`read` 本 Provider 拿动作——
/// 这样按钮不会因为状态变化而重建。
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
/// ## 为什么需要它
///
/// go_router 只在**导航发生时**执行 `redirect`。启动时状态是
/// [AuthStatus.unknown]（守卫放行），凭证恢复完成变成
/// [AuthStatus.unauthenticated] 后**没有导航**，守卫不会重跑——用户会停在
/// 主界面上，直到他手动点某个链接。`refreshListenable` 就是让 go_router
/// 在状态变化时重新评估当前路由的钩子。
class AuthRefreshNotifier extends ChangeNotifier {
  AuthRefreshNotifier(Ref ref) {
    ref.listen(authStateProvider, (previous, next) {
      // 只在**状态**变化时通知：message 变化（如登录失败文案）不需要重跑守卫。
      if (previous?.status != next.status) notifyListeners();
    });
  }
}

/// [AuthRefreshNotifier] 的 Provider。
///
/// 非 autoDispose：router 在 app 生命周期内一直持有它。
final authRefreshListenableProvider = Provider<Listenable>((ref) {
  return AuthRefreshNotifier(ref);
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

/// userId 的**本地持久化**副本（离线可用）。
///
/// ## 为什么不能只用 [currentUserIdProvider]（issue #26 切片 A）
///
/// 它内部是 `chatApi.me()` ——一次 `GET /api/auth/me` **网络请求**。而对话列表
/// 缓存要解决的正是在**断网冷启动**时展示列表，那时这个请求必然失败 →
/// userId 拿不到 → 缓存无法定位自己的行 → 回落失效。
///
/// 于是把成功拿到的 userId 落进偏好表，读时**先本地后网络**：
///
/// | 场景 | 结果 |
/// |---|---|
/// | 在线 | 本地命中，零额外请求（仍会后台刷新写入，见下） |
/// | 断网冷启动 | 本地命中 → 缓存可用 ✅ |
/// | 首次启动（本地无值）且断网 | 返回 null → 不回落（无行可查，无法更优） |
///
/// ⚠️ **不在这里发网络请求**：它会在启动路径上引入一次往返（列表页首帧就要等
/// 它），而 [currentUserIdProvider] 的调用方本来就会各自去拿。本 Provider 只
/// 做「读本地 + 把已知值写回」，故是同步可得的 `FutureProvider`。
///
/// ## 为什么用 userId 而不是 session id 作缓存行归属
///
/// 服务端 `chat_groups.user_id` 就是 userId，且 `GET /api/auth/me` 返回它。
/// 用 session id 会让「同一用户重新登录」被当成换人，缓存白丢。
final cachedUserIdProvider = FutureProvider<String?>((ref) async {
  final prefs = ref.watch(preferencesStoreProvider);
  final stored = await prefs.getString(cachedUserIdPrefKey);
  if (stored != null && stored.isNotEmpty) return stored;

  // 本地没有：尝试从网络拿一次并落盘。失败返回 null（不抛——缓存是可选能力）。
  try {
    final id = await ref.watch(currentUserIdProvider.future);
    if (id.isNotEmpty) {
      await prefs.setString(cachedUserIdPrefKey, id);
      return id;
    }
  } catch (e) {
    // 断网 / 未登录：返回 null，调用方（列表页）据此不启用缓存。
    //
    // 记 debug（issue #45）：离线启动时这是**正常**路径（不是故障），
    // 但它是「为什么这次没有缓存」的唯一线索，排查时少了它只能猜。
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
/// **HTTP 200** 加 `confirmation_required`（**什么都没提交**），必须让调用方
/// 拿到这个状态才能继续走「选策略 → 重试」。
///
/// ## 为什么不再把「待确认」抛成错误
///
/// 原实现 `throw ValidationError`，而注入点签名是 `Future<void>`——**用户永远
/// 走不到提交成功那条路**（功能性死锁）：服务端说「请选策略」，客户端把这句话
/// 当失败上报，没有任何入口能选策略，于是每次点「立即发送」都失败。
///
/// 现在策略选择由 `MessageComposer` / `PendingMessagesBar` 的
/// `runFlushFlow` 完成（弹窗选项按服务端返回的 `options` 动态渲染）。
///
/// 唯一的例外：`!committed` 且 `!needsConfirmation`（既无 turn_id 也无待确认）
/// 确实是异常响应，仍抛 [ValidationError]——否则调用方会以为提交成功了。
/// ## 为什么是 `family`（而不是在闭包里收 groupId）
///
/// `FlushPending` 是无参的（页面不知道 groupId，与 `onSend` 同一约定），
/// 故 groupId 在**装配层**（router）通过 family 参数绑定。
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
///
/// `message_ids` 透传服务端在待确认响应里回的那批 id（`result.message_ids`
/// 未被 [FlushResult] 建模，但重试时可不带——服务端会重新枚举当前 pending，
/// 而这段时间内待处理集合并未变化）。
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
//
// `GET /chat/confirmations` 身份来自网关注入的 `X-User-ID`（不需客户端传
// userId）。用 FutureProvider 缓存首拉结果，并提供一个刷新入口。

/// 待确认列表（首拉）。页面注入 `fetch` 时读它，刷新时调 `refresh`。
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
    // 区分依据。
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
/// ## 为什么必须 autoDispose + onDispose
///
/// 它持有一条**长连接 SSE**。若用常驻 Provider，用户离开对话页后连接仍开着：
/// 桌面端表现为后台持续收事件（无谓唤醒），移动端表现为持续耗电与流量。
/// 故页面退出即释放。
///
/// `onDispose` 里必须调 `dispose()`：它负责取消帧订阅并关闭三个
/// StreamController。漏掉会留下悬挂订阅（Riverpod 只会丢弃 Provider 实例，
/// 不会替你清理它内部持有的资源）。
///
/// ⚠️ 不传 `ref.watch(sseClientProvider)` 的 `autoDispose` 参数：SSE 客户端是
/// **跨对话共享**的单例，切 group 不重连，见 [sseClientProvider]。
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
/// ## 为什么需要它（而不是让页面自己订阅 controller）
///
/// 对话列表页当前**没有任何 SSE 连接**：连接是由对话页调
/// `ChatStreamController.start()` 建立的。只给页面加一个 `listen` 会「看起来
/// 做完了，但事件永远不来」——列表页必须自己确保连接在。
///
/// ## 为什么不直接复用对话页的聚焦模式
///
/// 列表页挂载时对话页往往并不存在（用户在首页）。本 provider 用
/// [ChatStreamController.ensureConnected]：已有连接（对话页建的聚焦模式）就
/// 不动它，否则以**全局模式**建连。全局模式不回填任何 group 的时间线，故不会
/// 白拉一页历史。
///
/// ## autoDispose
///
/// 与 [chatStreamControllerProvider] 同取向：它间接持有长连接，页面退出即释放。
/// （移动端尤其重要：常驻连接会持续耗电与流量。）
///
/// ## userId 未就绪时返回空流
///
/// 空流不是错误状态，而是一个**占位**：`ref.watch(currentUserIdProvider)` 在
/// `/api/auth/me` 返回后会重建本 provider，那时才返回真正的流。故不需要在这里
/// 写重试逻辑（也**不得**用空串兜底去建连——那会连到
/// `/users//chat/stream`，即 issue #2 那个静默故障）。
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

/// 无归属入口用例（**带附件**，走 mq-server 通用入站渠道）。
///
/// 与 [quickCaptureEnqueueUseCaseProvider] 的差别：本用例支持附件（上传 → 投递两步），
/// 但投递是异步的，拿不到 groupId。见 `QuickCaptureEnqueueUseCase` 的文档。
final quickCaptureEnqueueUseCaseProvider = Provider<QuickCaptureEnqueueUseCase>(
  (ref) {
    return QuickCaptureEnqueueUseCase(ref.watch(chatApiProvider));
  },
);

/// 文件拖入能力（桌面端为真实实现，移动端注入空实现）。
///
/// 由 `main.dart` 的 bootstrap 覆盖：这里给默认值让测试与「忘记覆盖」的
/// 场景退化为「不支持拖拽」而不是崩溃。
final dragDropCapabilityProvider = Provider<DragDropCapability>((ref) {
  return const NoopDragDropCapability();
});

// ==================== 习惯（habit）====================
//
// 端点真源见 `spb_api` 的 [HabitApi] 类文档。
//
// 两个 app 都需要这组 provider（桌面端与移动端都支持习惯），但**各自复制**
// 而非共享：`apps/*` 之间不互相依赖（只依赖 `packages/*`），且两端的错误翻译
// 文案（snackbar）本来就不同。

/// 习惯 API 客户端（与 [chatApiProvider] 共用同一个 [dioProvider]）。
final habitApiProvider = Provider<HabitApi>((ref) {
  return HabitApi(ref.watch(dioProvider));
});

/// 规则列表首拉（供 [HabitsPage.loadHabits] 注入）。
///
/// 用 FutureProvider 缓存首拉，刷新走 `ref.invalidate`。
final habitsProvider = FutureProvider<List<UserHabit>>((ref) async {
  return ref.watch(habitApiProvider).listHabits();
});

/// 执行历史首拉（跨规则，含无 pattern 的候选建议记录）。
final habitRunsProvider = FutureProvider<List<HabitRun>>((ref) async {
  return ref.watch(habitApiProvider).listAllRuns();
});

// ==================== 交付物同步 ====================

/// UFS API 客户端（独立 baseUrl，与 PartyB API 不同服务）。
final ufsApiProvider = Provider<UfsApi>((ref) {
  return UfsApi(ref.watch(ufsDioProvider));
});

/// UFS 专用 Dio。
///
/// ## 为什么不能复用 [dioProvider]
///
/// 两者的 `baseUrl` 不同（`/pba` vs `/ufs`），而 Dio 的 baseUrl 是构造期固定的。
/// 复用同一个实例会让 UFS 请求打到 `/pba/api/files`——404，且错误信息完全
/// 指不到根因。用独立实例更直白（代价是两条连接池，可接受）。
///
/// 认证拦截器**共享同一个** [SessionManager]：token 是同一份，刷新去重也必须
/// 是同一处（否则两个 Dio 会并发刷新，IdP 侧可能作废先到的那个 refresh_token）。
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

/// 本地同步数据库（同步状态 + 偏好 + 目录绑定）。
///
/// ## 为什么用 `LazyDatabase` 而不是直接 `NativeDatabase`
///
/// 开库是 IO（建目录 + 打开文件）。用 `LazyDatabase` 把这一步推迟到**首次
/// 真正查询**时，构造 Provider 不会阻塞 UI 线程；同时 `NativeDatabase` 默认
/// 在**后台 isolate** 里执行查询，避免同步大批量写入卡住界面。
///
/// 非 autoDispose：drift 持有文件句柄，随页面重建会反复开库。
/// `ref.onDispose` 保证应用退出时关闭（否则测试里会留下未关闭的库）。
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  // 懒开 + 后台 isolate 执行查询：见 spb_data 的 openAppDatabaseAt 说明。
  final db = openAppDatabaseAt(_dbFile());
  ref.onDispose(db.close);
  return db;
});

/// 数据库文件位置。
///
/// 用应用数据目录：同步状态必须**跨启动持久**，放在临时目录里会让每次启动
/// 都退化成全量同步。
///
/// 这里手写路径而不用 `path_provider`：后者需要平台通道，在 `flutter test`
/// 里会抛 `MissingPluginException`——而 provider 一旦在测试里被读到就会炸。
/// `XDG_DATA_HOME` / `$HOME` 在桌面端一定可用，且与 path_provider 在 Linux
/// 上的结果一致。
File _dbFile() {
  final env = Platform.environment;
  final base =
      env['XDG_DATA_HOME'] ??
      (env['HOME'] != null ? '${env['HOME']}/.local/share' : null);
  if (base == null) {
    // 极端环境（无 HOME）：退回临时目录。同步状态会不跨启动，但功能可用。
    SpbLog.warn('未找到 XDG_DATA_HOME 与 HOME，同步状态将不持久');
    return File('${Directory.systemTemp.path}/super_partyb-sync.db');
  }
  final dir = Directory('$base/super_partyb');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return File('${dir.path}/sync.db');
}

/// 同步状态存储（具体类型 [DriftSyncStateStore]）。
///
/// ## 为什么暴露具体类型而不是 [SyncStateStore] 接口
///
/// 「换目录必须重置同步状态」需要 `bindLocalRoot`——它把「写入目录绑定」与
/// 「清空状态」放在**同一事务**里，这是 [SyncStateStore] 接口没表达的能力
/// （接口只有 `resetAll`，单独调它会留下「目录已改但状态清空失败」的窗口）。
/// 让本 Provider 返回具体实现，使装配层能用到这个事务化方法，而不必为了
/// 一个方法去改 domain 的契约。
final syncStateStoreProvider = Provider<DriftSyncStateStore>((ref) {
  return DriftSyncStateStore(ref.watch(appDatabaseProvider));
});

/// 本地偏好存储。
final preferencesStoreProvider = Provider<PreferencesStore>((ref) {
  return PreferencesStore(ref.watch(appDatabaseProvider));
});

/// 当前同步目录（从数据库绑定读取）。
///
/// ## 为什么目录绑定要单独读（而不是放偏好表）
///
/// 「换目录必须重置同步状态」这条规则要求**目录写入与状态清空在同一事务**里
/// 完成（见 `DriftSyncStateStore.bindLocalRoot`）。若目录存在偏好表、状态存在
/// 状态表，就会出现「目录已改、状态没清」的中间态——表现为「换目录后同步
/// 显示成功，但新目录是空的」。
final syncLocalRootProvider = FutureProvider<String?>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  return DriftSyncStateStore(db).boundLocalRoot();
});

/// 目录选择器（平台能力）。
///
/// 包装成 `PickSyncDirectory`（可选 title 参数）供同步页注入——页面不直接
/// 依赖 `spb_platform`。
final pickDirectoryProvider = Provider<PickSyncDirectory>((ref) {
  final caps = ref.watch(desktopCapabilitiesProvider);
  return ({String? title}) => caps.pickDirectory(title: title);
});

/// 偏好键：是否同步媒体。
///
/// ## 为什么没有对应的「过滤配置」provider
///
/// 本文件曾有一个「同步过滤配置」provider（读本键 + [maxFileSizePrefKey]
/// 拼成 `SyncFilterConfig`），但它**没有任何 watch 点**——只有
/// `saveSyncSettingsProvider` 里一句 `ref.invalidate`，而 invalidate 一个无人
/// 订阅的 provider 是空操作。真正同步走 [_runSync]，它直接读
/// `loadSyncSettingsProvider` 的 `settings.filter`。
///
/// 过滤配置的真源就是 **`SyncSettings.filter`**（经 `saveSyncSettingsProvider`
/// 落盘到下面这两个键）。
const String includeMediaPrefKey = 'sync.include_media';

/// 偏好键：单文件体积上限（字节）。
const String maxFileSizePrefKey = 'sync.max_file_size';

/// 偏好键：同步范围（JSON）。
///
/// ## 为什么范围要序列化成 JSON 存一个键
///
/// 范围是「是否全部 + 勾选哪些」的复合值，两者必须**一起**变（`allGroups`
/// 与 `groupIds` 分开存会出现「全部=true 且勾了三个」这种无法解释的组合）。
/// 存一个键天然保证原子性。
const String scopePrefKey = 'sync.scope';

/// 偏好键：拉取范围（天）。缺省 = 不限历史。
const String sinceDaysPrefKey = 'sync.since_days';

/// 偏好键：自动同步（JSON，见 [AutoSyncConfig.encode]）。
///
/// 与 [scopePrefKey] 同一理由存成单个 JSON 键：`onLaunch` 与
/// `intervalMinutes` 是一个意图的两个维度，分开存会留下「写了一半」的中间态。
const String autoSyncPrefKey = 'sync.auto';

/// 触发一轮同步的动作（供同步页注入）。
///
/// ## 为什么每次读最新的目录与配置
///
/// 用户可能刚在同步页选了新目录就点同步。若闭包里捕获了构造时的旧目录，
/// 同步会写到**上一个**目录，而 UI 显示的是新目录——用户会以为同步没生效。
///
/// 同理，落盘器按**当前**目录新建（`LocalFileSink(root)`），而不是复用一个
/// 绑定旧目录的实例。
final runSyncActionProvider = Provider<RunSyncAction>((ref) {
  // 单飞（single-flight）：同一时刻只允许一轮同步。
  //
  // ## 为什么必须有它（自动同步引入后）
  //
  // 现在有三个入口能触发同步：托盘「立即同步交付物」、同步页按钮、自动同步
  // 调度器。前两者靠用户手动，天然不会同时点；但自动 tick 与手动触发**可以
  // 重叠**——而 `DeliverableSyncUseCase` 会按 stateKey 读写同一份游标，
  // 两轮并发推进同一游标不安全（可能互相覆盖，导致已下载的文件被重复下载、
  // 或未下载的区间被跳过）。
  //
  // 语义选择「**复用同一个 Future**」而不是「直接跳过」：手动触发若被静默
  // 跳过，用户会看到按钮点了没反应、也没有任何进度；复用则让等待方拿到同一
  // 份结果，UI 的 busy 态自然一致。
  //
  // ## 为什么用闭包变量而不是一个 provider
  //
  // 它是「正在进行中的调用」这一**瞬态**，不需要被 watch，也不该在重建时
  // 丢失。放 provider 里反而要处理 dispose/重建的语义（重建会让在途状态
  // 凭空消失，于是单飞失效）。
  Future<SyncReport>? inFlight;

  return () {
    final existing = inFlight;
    if (existing != null) {
      SpbLog.debug('同步已在途，复用同一轮结果');
      return existing;
    }
    final future = () async {
      // 标记「同步在途」，供托盘提示显示「同步中…」。
      //
      // ## 为什么状态放在 Provider 里而不是页面的 State 里
      //
      // 托盘提示是**应用级**的，它看不到同步页的 State；而同步可能由设置页、
      // 同步页或将来其他入口发起。把「在途」放在一处，所有入口自动生效。
      //
      // `finally` 保证异常路径也会复位：否则一次失败会让托盘永远显示
      // 「同步中…」，用户会以为同步卡死。
      ref.read(syncInFlightProvider.notifier).set(true);
      try {
        return await _runSync(ref);
      } finally {
        ref.read(syncInFlightProvider.notifier).set(false);
        inFlight = null;
      }
    }();
    inFlight = future;
    return future;
  };
});

/// 同步是否在途。
///
/// 用 `NotifierProvider<bool>` 而非 `StateProvider`：后者在 Riverpod 3 已
/// 移入 `legacy.dart`（见 [authStateProvider] 的说明）。
final syncInFlightProvider = NotifierProvider<SyncInFlightNotifier, bool>(
  SyncInFlightNotifier.new,
);

/// 同步在途状态。
class SyncInFlightNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 设置在途状态。
  ///
  /// 同值提前返回是**可读性冗余，不是独立防线**：Riverpod 的默认
  /// `updateShouldNotify` 就是 `previous != next`，对 `bool` 而言同值本来
  /// 就不通知订阅者（实测：连续三次 `set(false)` 零次通知）。保留它只是让
  /// 「同值不通知」这个意图在调用点可见，删掉也不会坏功能。
  void set(bool value) {
    if (state == value) return;
    state = value;
  }
}

/// 自动同步调度器（应用级单例）。
///
/// ## 为什么在装配层持有，而不是放进 `SyncSettings` 的读写里
///
/// 「什么时候该同步」是**进程生命周期**的事：它跨越设置页的打开与关闭，也
/// 必须在用户从未打开过设置页时照常工作（配置从偏好读）。放 provider 里由
/// `ProviderScope` 持有，与 `outboxQueueProvider` 同一取向。
///
/// ## 三个触发源，一个调度器
///
/// 1. 启动（`app.dart` 预热，见 `_installAutoSync`）；
/// 2. 登录态变化（登出 → `pause`，登录 → 按配置重新武装）；
/// 3. 保存设置（新配置立即生效）。
///
/// 调度器自身按 `apply` 的配置相等做幂等，故三个源反复喂同一份配置是安全的。
///
/// ## 为什么 `onDispose` 必须 dispose
///
/// 一次性 `Timer` 持有回调闭包，而闭包又持有 `ref`。不取消的话，测试里
/// `ProviderContainer.dispose()` 之后计时器仍会在到期时执行——那是
/// 「测试之间互相污染」的经典来源。
final autoSyncSchedulerProvider = Provider<AutoSyncScheduler>((ref) {
  final scheduler = AutoSyncScheduler(
    run: () async {
      // 自动轮次**不得**把错误抛给调度器之外：调度器已记日志，但这里也
      // 需要把「没有目录 / 范围配置不通」这类**配置问题**降级成 debug——
      // 它们每 15 分钟就会复现一次，用 error 级会淹没真正的故障。
      try {
        await ref.read(runSyncActionProvider)();
      } on PlatformError catch (e) {
        SpbLog.debug('自动同步跳过：配置尚不完整', {'error': e.message});
      }
    },
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

/// 把当前设置同步到调度器（幂等）。
///
/// ## 为什么包成 `Provider<Future<void> Function()>` 而不是一个顶层函数
///
/// 调用方有**两种 `ref`**：`app.dart` 里是 `WidgetRef`（组件的 ref），
/// 设置页的保存闭包里也是 `WidgetRef`，而本文件里是 `Ref`。Riverpod 3 的
/// 这两个类型**不互相赋值**（`WidgetRef` 不是 `Ref` 的子类型）。收成一个
/// 无参闭包后，两边都只需 `ref.read(reconcileAutoSyncProvider)()`——不必为
/// 两种 ref 各写一份实现（两份必然漂移）。
///
/// ## 为什么读 `loadSyncSettingsProvider` 而不是 watch 某个 provider
///
/// 设置的真源是**偏好 + 目录绑定**（两张表），没有单一 provider 承载它。
/// 每次现读是既有取向（`_runSync` 也这么做），且这里的调用点都在「明确的
/// 事件之后」（启动、登录、保存），不是高频路径。
///
/// ## 认证未就绪时不武装
///
/// `AuthStatus.unknown` 期间（启动读凭证的那一瞬间）发起同步会拿不到
/// token，白跑一轮并留下一条 401 日志。故只在 `authenticated` 时武装；
/// 其余状态 `pause`。
final reconcileAutoSyncProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final scheduler = ref.read(autoSyncSchedulerProvider);
    final auth = ref.read(authStateProvider);
    if (!auth.isAuthenticated) {
      scheduler.pause();
      return;
    }
    final settings = await ref.read(loadSyncSettingsProvider)();
    // 没目录就不排程：`_runSync` 会抛「请先选择同步目录」，每轮一次纯噪音。
    if (!settings.canSync) {
      scheduler.pause();
      return;
    }
    await scheduler.apply(settings.auto);
  };
});

/// 进入对话时的同步冷却闸（每 group 独立计时）。
///
/// 语义见 [GroupSyncThrottle]（`spb_domain`）。这里只负责持有实例。
///
/// **非** autoDispose：它记的是「刚才试过」，而用户会在多个对话之间来回切；
/// 每次切对话重建实例等于没有冷却。
final groupSyncThrottleProvider = Provider<GroupSyncThrottle>((ref) {
  return GroupSyncThrottle();
});

/// 一次「进入对话时判定是否需要同步」的结果，供页面决定是否显示提示条。
///
/// [groupId] 同时作为身份：页面据此判断「这条结果说的是不是我当前这个对话」
/// ——异步判定返回时用户可能已经切走了。
class GroupSyncCheckResult {
  const GroupSyncCheckResult({
    required this.groupId,
    required this.need,
    this.pendingCount = 0,
  });

  final String groupId;
  final GroupSyncNeed need;

  /// 该 group 在远端有、但本地还没有（或版本更旧）的文件数（用于提示文案）。
  ///
  /// 判定用 `page_size=1` 只拉一条就够**触发**，但要给用户一句可读的话
  /// （「有 12 个交付物未同步」）就得知道规模。故判定命中后再花一次分页
  /// 统计——只在**命中时**付这个成本，绝大多数打开是未命中。
  ///
  /// 超过 [GroupSyncCheckResult.countCap] 时被截断（只显示「至少 N 个」），
  /// 避免为一个提示条拉几百页。
  final int pendingCount;

  /// 计数上限：5 页 × 100 条。
  ///
  /// 500 以上对用户已是「很多」，精确值没有意义，而拉更多页只为凑数字
  /// 不值得（首次同步可能 5666 条）。
  static const int countCap = 500;

  bool get isStale => need == GroupSyncNeed.stale;
}

/// 「进入对话时判定是否需要同步」的注入点签名。
///
/// 抽成 typedef 是为了让测试 harness 能替换它——真实实现要读设置 + 打 UFS
/// 列表端点，而绝大多数对话页用例关心的是别的东西。
typedef GroupSyncCheck = Future<GroupSyncCheckResult> Function(String groupId);

/// 进入对话时判定该 group 是否需要同步（**只判定，不触发**）。
///
/// ## 为什么判定与触发分开
///
/// 判定要发一次 HTTP（可能再发几次统计）。若判定完就直接同步，用户会看到
/// 「点进对话 → 突然开始下载」而没有任何解释，且无法拒绝。分成两步后，
/// 页面可以先问用户（提示条 + 「立即同步」按钮），也可以按配置直接触发
/// ——那是**调用方的**决定，不是判定的。
///
/// ## 为什么用 `page_size=1` 判定
///
/// 列表按 `updated_at` 倒序，第一条即最晚的那份。取它的 `updated_at` 与本
/// group 的已同步水位比较即可（判据见 `groupSyncNeed`）。拉一页 100 条只为
/// 读一个字段是浪费。
///
/// ## 命中的是「这个 group」而不是全范围
///
/// 定向同步（[SyncSingleGroupScope]）只列该 group 子树、且**不推进**共享
/// 游标，故不会让游标越过其它 group 里未同步的文件。
///
/// ⚠️ 水位必须从**本 group 的文件记录**里取（[groupSyncWatermark]），
/// 不能拿 workspace 游标比：定向同步不动游标，拿它比会永远判 stale。
final checkGroupSyncNeedProvider =
    Provider<Future<GroupSyncCheckResult> Function(String)>((ref) {
      return (String groupId) async {
        final settings = await ref.read(loadSyncSettingsProvider)();
        if (!settings.canSync) {
          return GroupSyncCheckResult(
            groupId: groupId,
            need: GroupSyncNeed.unknown,
          );
        }
        // 该 group 根本没有交付物时不必再问水位：`page_size=1` 空页即结论。
        final ufs = ref.read(ufsApiProvider);
        final page = await ufs.listFiles(
          pathPrefix: '$workspaceGroupsPrefix$groupId',
          page: 1,
          pageSize: 1,
        );
        final latest = latestUpdatedAtOf(page.items.map((e) => e.updatedAtRaw));
        if (latest == null) {
          return GroupSyncCheckResult(
            groupId: groupId,
            need: GroupSyncNeed.unknown,
          );
        }

        final store = ref.read(syncStateStoreProvider);
        // 状态键固定用 [workspaceStateKey]——因为提示条上的「立即同步」跑的是
        // [SyncSingleGroupScope]，它按 workspace 布局落盘（`{gid}/` 前缀）
        // 且写这个键。读另一个键会比不到东西，于是永远判 stale。
        const stateKey = workspaceStateKey;
        final state = await store.load(stateKey);
        final watermark = groupSyncWatermark(
          state: state,
          stateKey: stateKey,
          groupId: groupId,
        );
        final need = groupSyncNeed(
          remoteLatestUpdatedAt: latest,
          local: watermark,
        );
        if (need != GroupSyncNeed.stale) {
          return GroupSyncCheckResult(groupId: groupId, need: need);
        }

        // 命中后才统计规模（只在命中路径付这个成本）。
        var count = 0;
        var pageNo = 1;
        const pageSize = 100;
        while (count < GroupSyncCheckResult.countCap) {
          final res = await ufs.listFiles(
            pathPrefix: '$workspaceGroupsPrefix$groupId',
            page: pageNo,
            pageSize: pageSize,
          );
          for (final entry in res.items) {
            final at = entry.updatedAtRaw?.trim();
            if (at == null || at.isEmpty) continue;
            // 与判定同一口径：晚于本 group 水位才算「未同步」。
            final mine = watermark.latestUpdatedAt;
            if (mine == null || at.compareTo(mine) > 0) count++;
          }
          if (!res.hasMore(page: pageNo, pageSize: pageSize)) break;
          pageNo++;
          if (pageNo > 100) break;
        }

        return GroupSyncCheckResult(
          groupId: groupId,
          need: need,
          pendingCount: count,
        );
      };
    });

/// 一轮同步的实际执行（不含在途状态管理）。
Future<SyncReport> _runSync(Ref ref) async {
  // 每次都重新读设置：用户可能刚在设置页改了目录/范围/过滤就点同步。
  // 捕获构造时的旧值会让同步按旧配置跑，而 UI 显示的是新配置。
  final settings = await ref.read(loadSyncSettingsProvider)();

  final root = settings.localRoot;
  if (root == null || root.trim().isEmpty) {
    throw const PlatformError('请先选择同步目录');
  }

  // 范围由用户配置决定（全部 / 勾选若干 / 单 group）。
  //
  // 单 group 模式没有 groupId（设置页不产出该配置），toScope 会抛可操作的
  // 错误——**不退化成「全部」**，否则用户明明关掉了「全部」却会多下整个
  // workspace（生产实测 5666 条 / 4.7 GB）。
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
}

/// 定向同步**一个 group**（进入对话时的「立即同步」走这里）。
///
/// ## 与 [_runSync] 的区别（两处，缺一不可）
///
/// | | [_runSync]（全范围） | 本方法 |
/// |---|---|---|
/// | 列举前缀 | 用户配置范围的全前缀 | 仅 `{gid}` 子树 |
/// | 游标 | 推进 | **不推进**（[SyncSingleGroupScope.advancesCursor]）|
///
/// ## 为什么不能直接复用用户配置的 scope
///
/// 用户可能配的是「勾选若干」或「全部」。拿那个 scope 跑就是全范围同步
/// （首次 4.7 GB），而用户只是点开了一个对话。
///
/// ## 为什么目录/过滤仍跟着用户配置
///
/// 同步到**哪里**、**哪些文件不要**（媒体/体积/`reports/tts`）是用户设定
/// 的策略，与本轮只看一个 group 无关。混用两套过滤规则会让本地目录里
/// 出现「手动同步时不会有的文件」。
Future<SyncReport> _runSyncSingleGroup(Ref ref, String groupId) async {
  final settings = await ref.read(loadSyncSettingsProvider)();

  final root = settings.localRoot;
  if (root == null || root.trim().isEmpty) {
    throw const PlatformError('请先选择同步目录');
  }

  final ufs = ref.read(ufsApiProvider);
  final useCase = DeliverableSyncUseCase(
    ufs: ufs,
    stateStore: ref.read(syncStateStoreProvider),
    sink: LocalFileSink(root),
    downloader: UfsFileDownloader(ufs),
  );

  return useCase.run(
    scope: SyncSingleGroupScope(groupId),
    filter: settings.filter,
    sinceDays: settings.sinceDays,
  );
}

/// 「立即同步本对话的交付物」（进入对话提示条上的按钮）。
///
/// 返回注入点形态（收 groupId），便于测试替掉整个动作而不碰 UFS。
typedef GroupSyncRun = Future<SyncReport> Function(String groupId);

final runGroupSyncActionProvider = Provider<GroupSyncRun>((ref) {
  return (String groupId) => _runSyncSingleGroup(ref, groupId);
});

/// 保存同步目录（换目录时**在同一事务里**清空同步状态）。
///
/// 返回是否发生了状态重置（true = 目录变更）。
final saveLocalRootActionProvider = Provider<Future<bool> Function(String?)>((
  ref,
) {
  return (String? root) async {
    final store = ref.read(syncStateStoreProvider);
    // bindLocalRoot：目录变了 → 清空全部状态（**同一事务**）。
    final reset = await store.bindLocalRoot(root);
    // 让依赖它的 provider 重新读取（目录已变）。
    ref.invalidate(syncLocalRootProvider);
    return reset;
  };
});

// ==================== 交付物回传 ====================
//
// 自动同步永远是 UFS → 本地单向；回传是**显式**的本地 → agent 通道。
// 编排在 DeliverableUploadUseCase（domain），这里只接线：把 ChatApi/UfsApi
// 适配成四个窄接口（适配器在 domain 共用，见 deliverable_upload_adapters.dart）。
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

/// 通知器工厂：把当前用户 id 绑进去（`/users/:uid/chat/messages` 要它）。
///
/// 用工厂而不是直接 Provider：userId 是**异步**解析的（`GET /api/auth/me`），
/// 而 Riverpod 的 Provider 构建是同步的。用工厂把「等 userId」留在动作里，
/// 失败时错误信息就是认证错误本身（可诊断），而不是一个「userId 为空」的
/// 二手错误（与 issue #2 同源的陷阱）。
final uploadNotifierFactoryProvider = Provider<UploadNotifier Function(String)>(
  (ref) {
    final api = ref.watch(chatApiProvider);
    return (String userId) => ChatApiUploadNotifier(api, userId);
  },
);

/// 本地文件读取器工厂（回传脏检测与上传都要读用户改过的文件）。
///
/// ## 为什么是工厂而不是直接给一个 `LocalFileSink`
///
/// 本地根可能变（用户重选目录）。若在这里捕获一次，回传会把改动传到
/// **上一个**目录（同 [runSyncActionProvider] 的说明）。工厂让调用方在
/// 读完最新设置后再构造，根总是新鲜的。
final uploadFileReaderFactoryProvider =
    Provider<LocalFileReader Function(String)>((ref) {
      return (String localRoot) => LocalFileSink(localRoot);
    });

/// 回传是否在途。
///
/// 与 [syncInFlightProvider] 分开：两者语义不同（上行 / 下行），合并会让
/// 「回传中」错误地显示成「同步中」（托盘提示读的是后者）。
final uploadInFlightProvider = NotifierProvider<UploadInFlightNotifier, bool>(
  UploadInFlightNotifier.new,
);

/// 回传在途状态（与 [SyncInFlightNotifier] 同构）。
class UploadInFlightNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) {
    if (state == value) return;
    state = value;
  }
}

/// 扫描本地改动（回传第一步：只读，不改任何东西）。
///
/// ## 为什么扫描没有在途状态
///
/// 纯本地只读（逐文件读字节 + 算 hash），无副作用、无网络。真正需要防重入的
/// 是**提交**（[uploadChangesActionProvider]）——它会覆盖远端。
final scanDirtyFilesActionProvider = Provider<ScanDirtyFilesAction>((ref) {
  return () async {
    // 每次都重新读设置：用户可能刚在设置页改了目录/范围/过滤。
    final settings = await ref.read(loadSyncSettingsProvider)();
    final root = settings.localRoot;
    if (root == null || root.trim().isEmpty) {
      throw const PlatformError('请先选择同步目录');
    }

    // 状态键与范围绑定：范围决定本地布局（workspace 有 `{gid}/` 前缀），
    // 传错会把单 group 的文件按 workspace 解析（见 uploadTargetFor）。
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

/// 回传**选中的**本地改动（第二步：覆盖远端 + 通知 agent）。
///
/// `finally` 复位在途状态：异常路径也复位（同 [runSyncActionProvider]），
/// 否则一次失败会让按钮永久停在「回传中…」。
final uploadChangesActionProvider = Provider<UploadChangesAction>((ref) {
  return (Set<String> only) async {
    ref.read(uploadInFlightProvider.notifier).set(true);
    try {
      final settings = await ref.read(loadSyncSettingsProvider)();
      final root = settings.localRoot;
      if (root == null || root.trim().isEmpty) {
        throw const PlatformError('请先选择同步目录');
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
/// ## 为什么目录来自状态库、其余来自偏好表
///
/// 目录必须与「清空同步状态」同事务，故存在 `sync_bindings` 表（见
/// [syncStateStoreProvider]）；其余字段无此约束，存偏好表更直白。
final loadSyncSettingsProvider = Provider<LoadSyncSettings>((ref) {
  return () async {
    final store = ref.read(syncStateStoreProvider);
    final prefs = ref.read(preferencesStoreProvider);

    return SyncSettings(
      localRoot: await store.boundLocalRoot(),
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

/// 保存同步设置（**整份提交**，一次性落盘）。
///
/// ## 顺序是有语义的：先写目录（含状态重置事务），再写其余偏好
///
/// 目录写入会清空同步状态，而偏好写入与它无关。若先写偏好再写目录，中途失败
/// 会留下「新偏好 + 旧目录」——那还算安全（目录没变，状态没清）。反过来
/// 「新目录 + 旧偏好」也不致命。真正致命的是**目录已改但状态没清**，而那由
/// `bindLocalRoot` 的事务保证，故只要走它就安全。
final saveSyncSettingsProvider = Provider<SaveSyncSettings>((ref) {
  return (SyncSettings settings) async {
    final store = ref.read(syncStateStoreProvider);
    final prefs = ref.read(preferencesStoreProvider);

    // 目录：绑定 + 必要时清空同步状态（同一事务）。
    await store.bindLocalRoot(settings.localRoot);

    await prefs.setString(scopePrefKey, settings.scope.encode());
    await prefs.setBool(
      includeMediaPrefKey,
      value: settings.filter.includeMedia,
    );
    await prefs.setInt(maxFileSizePrefKey, value: settings.filter.maxFileSize);

    final days = settings.sinceDays;
    if (days == null || days <= 0) {
      // 显式删除而不是写 "0"：读侧把「缺失」与「0」都当不限，但存 "0" 会让
      // 配置文件里出现一个需要解释的字段。
      await prefs.remove(sinceDaysPrefKey);
    } else {
      await prefs.setInt(sinceDaysPrefKey, value: days);
    }

    await prefs.setString(autoSyncPrefKey, settings.auto.encode());

    // 让同步相关 provider 重新读取（设置已变）。
    //
    // 只 invalidate 目录：过滤配置没有独立 provider，它的真源是
    // `SyncSettings.filter`（[loadSyncSettingsProvider] 每次现读），故无需
    // 在此额外通知。
    ref.invalidate(syncLocalRootProvider);

    // 换目录 = 每个 group 都该重新判定（新目录下什么都没有）。
    //
    // ## 为什么必须显式清，而不是等冷却期过去
    //
    // 冷却闸记的是「这个 group 刚才试过」。换了目录之后，用户打开对话时
    // 目录里**确实**没有那些文件——但闸还挡着，于是提示条不出现、用户以为
    // 「同步坏了」。这与 `bindLocalRoot` 里「换目录必须重置同步状态」是
    // 同一个道理：目录变了，所有「相对该目录」的判断都失效。
    ref.read(groupSyncThrottleProvider).reset();
  };
});

/// 读取可勾选的对话列表（同步范围用）。
///
/// 取一页（上限 200）而非全部分页：设置页是勾选界面，超出这个量级用户也
/// 不会手工勾选；而全量分页会让打开设置页变慢。
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
///
/// 用**当前**目录而非闭包捕获的目录：用户可能刚在设置页改了目录就点清理，
/// 捕获旧目录会去清理上一个目录（而 UI 显示的是新目录）。
final executePruneProvider = Provider<ExecutePrune>((ref) {
  return (PrunePlan plan) async {
    final root = await ref.read(syncLocalRootProvider.future);
    if (root == null || root.trim().isEmpty) {
      throw const PlatformError('请先选择同步目录');
    }
    return executePrunePlan(localRoot: root, plan: plan);
  };
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

// ==================== 交付物侧边栏 ====================

/// 拉取当前 group 的 workspace 交付物清单（UFS `/api/files` 分页汇总）。
///
/// ## 为什么分页拉全量而不是只拉一页
///
/// 侧边栏要展示完整的目录树与准确的计数。只拉第一页会让「reports 目录 12 个
/// 文件」变成「只看到 20 条里的那部分」，且目录聚合数会偏小——一个**看起来
/// 正常但错误**的结果。
///
/// ## 为什么按 `path_prefix` 而不是按 group 过滤
///
/// UFS 的 `path_prefix` 让服务端只返回该子树下的条目（对齐 webapp
/// `listGroupWorkspaceFiles`）。客户端过滤需要先拉全量（生产 workspace 实测
/// 5666 条），流量与延迟都不可接受。
///
/// ## 为什么是 autoDispose
///
/// 侧边栏只在一个对话页可见。`autoDispose` 让离开该 group 后释放缓存，
/// 避免长时间挂着每个打开过的 group 的清单。
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
/// ## 落地布局：`downloads/deliverables/{groupId}/<group 内相对路径>`
///
/// ⚠️ **不是平铺**。修复前所有 group 的文件都写到同一个
/// `downloads/deliverables/` 目录下，于是：
///
/// 1. 不同 group 的同名文件（每个 group 都有自己的 `README.md` /
///    `reports/a.md`）**互相覆盖**——用户看到的是「下载完内容变了」；
/// 2. 下载到 `reports/a.md` 时会被压成 `a.md`，丢失目录结构，而交付物面板
///    里显示的是树形路径；
/// 3. 下载完用户去文件管理器里根本分不清哪个文件属于哪个对话。
///
/// 现在保留两段：`{groupId}/` + group 内相对路径，与同步链路的 workspace
/// 布局（`{gid}/reports/a.md`）**形状一致**——同一个文件无论走同步还是走
/// 手动下载，相对位置相同，用户只需记一种布局。
///
/// ## 为什么落到应用支持目录而不是弹保存对话框
///
/// 与 `_ensureAgentFileLocal`（时间线内联卡）同一取舍：保存对话框需要额外的
/// 平台插件与权限面，而侧边栏的「打开 / 定位」只需要一个稳定的本地路径。
/// 落盘目录用 `downloads/deliverables/`，与时间线的 `downloads/agent/` 隔离
/// ——后者会被清理计划动，用户手动下载的不能被带上（与同步目录也隔离）。
///
/// ## 路径穿越防御
///
/// UFS 的 `path` 是**服务端可控输入**。相对路径由 `groupRelativePath` /
/// `workspaceRelativePath` 生成（`spb_domain`，含段级校验：空段 / `.` / `..` /
/// `\` / NUL 一律拒绝），并再 `p.join` 一次确保没有逃出目标目录。
/// 生成不了安全相对路径时**退化为单文件名**（`p.basename`），而不是报错
/// ——文件还是能拿到，只是没有目录结构。
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
    // 相对路径的口径在领域层（`spb_domain`，与移动端逐条同构、可无头单测）。
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

/// 用系统默认程序打开已下载的交付物。
///
/// 入参是**绝对路径**（由 [resolveLocalDeliverableProvider] 或面板的下载记录
/// 产出），本 Provider 只负责把它交给平台层。
final openDeliverableProvider = Provider<OpenLocalDeliverable>((ref) {
  return (String path) => ref.read(desktopCapabilitiesProvider).openFile(path);
});

/// 在系统文件管理器中定位已下载的交付物。
final revealDeliverableProvider = Provider<RevealLocalDeliverable>((ref) {
  return (String path) =>
      ref.read(desktopCapabilitiesProvider).revealPath(path);
});

/// 交付物同步的本地索引快照（打开 / 定位用）。
///
/// ## 为什么同时装 workspace 与单 group 两种状态
///
/// 用户选过的同步范围决定了本地落盘布局（见 `DeliverableSyncLayout`）：
///
/// | 范围 | 状态键 | 相对路径 |
/// |---|---|---|
/// | 全部 / 选中若干 | `__workspace__` | `{gid}/reports/a.md` |
/// | 单个 group | `groupId` | `reports/a.md` |
///
/// 两种都是合法配置（后者只能程序化产出，见 `SyncScopeConfig.toScope`），
/// 而**查询时无法从库里反推**用户当时用的是哪种。故两种都查：命中哪个用哪个。
/// 两者都查不到 → 该文件确实没同步过。
///
/// ## 为什么把 root 与状态装在一起
///
/// 它们是同一个问题的两半（「文件在哪」+「本地有哪些文件」）。分开两个
/// provider 会让调用方必须同时等两者就绪，且容易出现「用新状态配旧目录」的
/// 错配（那会指向一个不存在的位置）。
class DeliverableLocalIndex {
  const DeliverableLocalIndex({
    required this.localRoot,
    required this.workspace,
    required this.singleGroup,
  });

  /// 用户选的同步目录；null/空 = 尚未选过，此时不可能有已同步文件。
  final String? localRoot;

  /// `__workspace__` 状态键下的状态。
  final SyncState workspace;

  /// `groupId` 状态键下的状态（单 group 范围）。
  final SyncState singleGroup;

  bool get hasRoot => localRoot != null && localRoot!.trim().isNotEmpty;

  /// 「尚未配置同步目录」的空索引。
  static const none = DeliverableLocalIndex(
    localRoot: null,
    workspace: SyncState.empty,
    singleGroup: SyncState.empty,
  );

  /// 该 UFS 路径在同步目录内的**相对**路径；未同步返回 null。
  ///
  /// 先试 workspace 布局再试单 group 布局（见类文档）。两种布局的相对路径
  /// 形态不同（一个带 `{gid}/`、一个不带），不会互相误命中。
  String? relativePathOf(String groupId, String ufsPath) =>
      resolveLocalDeliverablePath(workspace, groupId, ufsPath) ??
      resolveLocalDeliverablePath(
        singleGroup,
        groupId,
        ufsPath,
        layout: DeliverableSyncLayout.singleGroup,
      );
}

/// 读取交付物同步索引（供 [resolveLocalDeliverableProvider] 与页面 watch）。
///
/// `autoDispose.family(groupId)`：只有打开侧边栏的对话页会读它，且只需当前
/// group 的状态。离开该 group 后释放，不把每个访问过的 group 的状态挂在内存。
final deliverableLocalIndexProvider = FutureProvider.autoDispose
    .family<DeliverableLocalIndex, String>((ref, groupId) async {
      final store = ref.watch(syncStateStoreProvider);
      final root = await store.boundLocalRoot();
      if (root == null || root.trim().isEmpty) {
        return DeliverableLocalIndex.none;
      }
      // 两个键各查一次。不合并成一次全表扫描：DriftSyncStateStore 的公开
      // 接口只有按 key 读，且这里最多两次查询（状态表按 state_key 有索引）。
      final workspace = await store.load(workspaceStateKey);
      final single = await store.load(groupId);
      return DeliverableLocalIndex(
        localRoot: root,
        workspace: workspace,
        singleGroup: single,
      );
    });

/// 查询某个交付物在**同步目录**里的本地绝对路径（未同步返回 null）。
///
/// 装配给 `GroupDeliverablesPanel.resolveLocalPath`。
///
/// ## 为什么是同步回调（不返回 Future）
///
/// 面板在 `build` 期间对每个可见文件调用它，以决定「打开 / 定位」是否可用。
/// 若它返回 Future，面板就得为每一行维护一个「正在查询」的中间态（或先全部
/// 渲染成不可用再逐行点亮），徒增复杂度与闪烁。故这里用 `ref.watch` 读**已
/// 加载好**的快照：状态变化时页面自然重建（见 [_ChatPage] 对 index 的 watch）。
///
/// ## 为什么要校验文件真的在磁盘上
///
/// 索引记录的是「**曾经**同步过」。用户可能手动删掉了同步目录里的文件（或
/// 换了目录后状态未清）。若不做校验，面板会把「打开」置为可用，点下去却报
/// 「无法打开文件」——比一开始就禁用更让人困惑。
///
/// `existsSync` 只对可见行执行（几十个），代价可忽略；换来的是「能点就一定能
/// 打开」这条确定性。
///
/// 索引**未加载完**（`value` 为 null）时一律返回 null（视为未同步）：宁可先
/// 显示为不可用，也不要短暂指向一个可能不存在的路径。加载完成后页面重建，
/// 可用状态自然出现。
final resolveLocalDeliverableProvider = Provider.autoDispose
    .family<ResolveLocalDeliverable, String>((ref, groupId) {
      final index = ref.watch(deliverableLocalIndexProvider(groupId)).value;
      if (index == null || !index.hasRoot) {
        return (UfsFileEntry file) => null;
      }
      final root = index.localRoot!;
      return (UfsFileEntry file) {
        final rel = index.relativePathOf(groupId, file.path);
        if (rel == null) return null;
        // 拼接用 path 包的 join：Windows 上才会得到反斜杠分隔的路径。
        final abs = p.join(root, rel);
        return File(abs).existsSync() ? abs : null;
      };
    });

// ==================== 小程序工作台（miniapp BFF）====================
//
// 两端共用同一组端点（`/chat/miniapp/*` 是 PartyB API 的投影层，见
// `internal/server/miniapp.go`），故装配与移动端同构——实现细节与理由见
// 移动端 `providers.dart` 的同名 provider。
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
