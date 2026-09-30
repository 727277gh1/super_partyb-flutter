import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'auth_loopback.dart';
import 'auth_session_import.dart';

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
    // 401 时刷新凭证并重放原请求。返回 false（无法刷新）则归一化为
    // AuthError，由上层跳登录页。
    onUnauthorized: () async {
      final refreshed = await manager.refresh();
      return refreshed != null;
    },
  );

  final dio = createDio(baseUrl: SpbEnv.apiBaseUrl, interceptors: [auth]);
  // 回填重放用的 Dio：必须是同一个实例（否则丢掉连接池与其余拦截器），
  // 而它又是本拦截器的构造参数之一，只能构造后回填。
  auth.replayDio = dio;
  return dio;
});

/// Chat API 客户端。
final chatApiProvider = Provider<ChatApi>((ref) {
  return ChatApi(ref.watch(dioProvider));
});

// ==================== 对话管理（改名 / 归档 / 删除）====================

/// 对话管理用例。
final groupManagementUseCaseProvider = Provider<GroupManagementUseCase>((ref) {
  return GroupManagementUseCase(ref.watch(chatApiProvider));
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
    baseUrl: SpbEnv.apiBaseUrl,
  );
  ref.onDispose(client.dispose);
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
final signInActionProvider = Provider<Future<String?> Function()>((ref) {
  return () async {
    final result = await loopbackSignIn(config: ref.read(oidcConfigProvider));
    final err = result.error;
    if (err != null) return err;

    // 落盘并推进状态（与移动端 onCode 相同的三步）。
    final tokens = result.tokens!;
    try {
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
    // 已发起：清掉旧的错误提示，但状态保持 unknown（等待凭证落盘）。
    state = AuthState(status: AuthStatus.unknown, message: null);
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
  } on Object catch (_) {
    // 拉取失败不阻断对话列表渲染：角标静默为 0。
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
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// 无归属入口用例（悬浮输入窗用，纯文本）。
///
/// 不 autoDispose：它无状态，只包一个 `ChatApi`，重建没有意义。
final quickCaptureUseCaseProvider = Provider<QuickCaptureUseCase>((ref) {
  return QuickCaptureUseCase(ref.watch(chatApiProvider));
});

/// 无归属入口用例（**带附件**，走 mq-server 通用入站渠道）。
///
/// 与 [quickCaptureUseCaseProvider] 的差别：本用例支持附件（上传 → 投递两步），
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
    onUnauthorized: () async {
      final refreshed = await manager.refresh();
      return refreshed != null;
    },
  );

  final dio = createDio(baseUrl: SpbEnv.ufsBaseUrl, interceptors: [auth]);
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

/// 同步过滤配置（媒体开关 / 单文件上限）。
///
/// 默认值对齐 Tauri 端：媒体**关**（生产媒体占体积 94.5%）、上限 10 MB。
/// 表单编辑在设置页任务里补；这里先把持久化读取接通，使「同步」真正可用。
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

/// 偏好键：是否同步媒体。
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
  return () async {
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
    }
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

    // 让同步相关 provider 重新读取（设置已变）。
    ref.invalidate(syncLocalRootProvider);
    ref.invalidate(syncFilterConfigProvider);
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
/// ## 为什么落到应用支持目录而不是弹保存对话框
///
/// 与 `_downloadAgentFile`（时间线内联卡）同一取舍：保存对话框需要额外的
/// 平台插件与权限面，而侧边栏的「打开 / 定位」只需要一个稳定的本地路径。
/// 落盘目录用 `downloads/deliverables/`，与时间线的 `downloads/agent/` 隔离
/// ——后者会被清理计划动，用户手动下载的不能被带上（与同步目录也隔离）。
///
/// ## 文件名防御
///
/// 用 `p.basename` 取最后一段：UFS 的 `name` 是服务端可控输入，若含 `../`
/// 或绝对路径就能写到目标目录之外。这与同步链路的 `groupRelativePath` 防御
/// 同源（那是目录内相对路径，这里是单文件名）。
final downloadDeliverableProvider = Provider<DownloadDeliverable>((ref) {
  return (UfsFileEntry file) async {
    final ufs = ref.read(ufsApiProvider);
    final res = await ufs.download(file.id);
    // 304 或空正文：内容未变/无内容，不覆盖本地（对齐同步链路的语义）。
    if (res.notModified || res.bytes == null || res.bytes!.isEmpty) {
      return '';
    }
    final dir = await getApplicationSupportDirectory();
    final target = Directory(p.join(dir.path, 'downloads', 'deliverables'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    final rawName = file.name.isNotEmpty ? file.name : file.path;
    final safeName = p.basename(rawName);
    final out = p.join(target.path, safeName.isEmpty ? file.id : safeName);
    await File(out).writeAsBytes(res.bytes!, flush: true);
    return out;
  };
});

/// 用系统默认程序打开已下载的交付物。
final openDeliverableProvider = Provider<OpenLocalDeliverable>((ref) {
  return (String path) => ref.read(desktopCapabilitiesProvider).openFile(path);
});

/// 在系统文件管理器中定位已下载的交付物。
final revealDeliverableProvider = Provider<RevealLocalDeliverable>((ref) {
  return (String path) =>
      ref.read(desktopCapabilitiesProvider).revealPath(path);
});
