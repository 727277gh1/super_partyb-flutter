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
        accessToken: tokens.accessToken,
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

/// 全局 Dio 实例（单例）。
final dioProvider = Provider<Dio>((ref) {
  final tokenProvider = ref.watch(sessionTokenProvider);
  final override = ref.watch(devUserHeaderOverrideProvider);
  final manager = ref.watch(sessionManagerProvider);

  final auth = AuthInterceptor(
    tokenProvider: tokenProvider,
    // 生产为 null（见 devUserHeaderOverrideProvider 的说明）。
    userHeaderOverride: override,
    // 401 时刷新凭证并重放原请求；无法刷新则归一化为 AuthError。
    onUnauthorized: () async {
      final refreshed = await manager.refresh();
      return refreshed != null;
    },
  );

  final dio = createDio(baseUrl: SpbEnv.apiBaseUrl, interceptors: [auth]);
  // 回填重放用的 Dio：必须是同一个实例（否则丢掉连接池与其余拦截器）。
  auth.replayDio = dio;
  return dio;
});

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
    baseUrl: SpbEnv.apiBaseUrl,
  );
  ref.onDispose(client.dispose);
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
    onCode: (code, pkce) async {
      try {
        final tokens = await ref
            .read(oidcClientProvider)
            .exchangeCode(code: code, pkce: pkce);
        await ref
            .read(tokenStoreProvider)
            .write(
              StoredTokens(
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken,
                expiresAt: tokens.expiresIn == null
                    ? null
                    : DateTime.now().toUtc().add(
                        Duration(seconds: tokens.expiresIn!),
                      ),
                tokenType: tokens.tokenType,
                scope: tokens.scope,
              ),
            );
        ref.read(authStateProvider.notifier).signedIn();
        return null;
      } on SpbError catch (e) {
        return e.message;
      } catch (e) {
        return '登录失败：$e';
      }
    },
    onError: (message) {
      // 把失败原因显示在登录页（它 watch 的就是 authStateProvider）。
      ref.read(authStateProvider.notifier).markUnauthenticated(message);
    },
  );
  ref.onDispose(receiver.dispose);
  return receiver;
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
    state = AuthState(status: AuthStatus.unknown, message: null);
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
  } on Object catch (_) {
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
    onUnauthorized: () async {
      final refreshed = await manager.refresh();
      return refreshed != null;
    },
  );

  final dio = createDio(baseUrl: SpbEnv.ufsBaseUrl, interceptors: [auth]);
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
const String includeMediaPrefKey = 'sync.include_media';
const String maxFileSizePrefKey = 'sync.max_file_size';

/// 偏好键：同步范围（JSON，见 `SyncScopeConfig.encode`）。
const String scopePrefKey = 'sync.scope';

/// 偏好键：拉取范围（天）。缺省 = 不限历史。
const String sinceDaysPrefKey = 'sync.since_days';

/// 同步过滤配置。
final syncFilterConfigProvider = FutureProvider<SyncFilterConfig>((ref) async {
  final prefs = ref.watch(preferencesStoreProvider);
  return SyncFilterConfig(
    includeMedia: await prefs.getBool(includeMediaPrefKey, defaultValue: false),
    maxFileSize: await prefs.getInt(
      maxFileSizePrefKey,
      defaultValue: defaultMaxFileSize,
    ),
  );
});

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

    ref.invalidate(syncFilterConfigProvider);
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
