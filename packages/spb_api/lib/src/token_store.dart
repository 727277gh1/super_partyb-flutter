import 'dart:async';

import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// 持久化的会话凭证。
///
/// ## 只存「换 token 必需」的字段
///
/// 刻意**不存 user_id**：身份真源是网关（`X-User-ID` 由网关注入），把 user_id
/// 缓存到本地并当成身份使用，等于允许客户端自选身份——这正是
/// `auth_interceptor.dart` 里 `userHeaderOverride` 只在开发态启用的原因。
/// userId 需要时应调 `GET /api/auth/me`。
class StoredTokens {
  const StoredTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.tokenType = 'Bearer',
    this.scope,
  });

  /// 送给网关的 Bearer 凭证。
  ///
  /// ## 名字是历史包袱，语义是「Bearer 凭证」而非 OIDC 的 `access_token`
  ///
  /// 实际存的是 [OidcTokens.bearerToken]——有 `id_token` 时**就是 `id_token`**
  /// （网关只验 RS256 JWT，不认 `ory_at_…` 不透明串）。改名会牵动存储格式与
  /// 全部测试，故保留字段名但在此说明；新代码请用
  /// [StoredTokens.fromOidcTokens] 构造，不要手写映射。
  final String accessToken;

  /// 续期用。为空表示无法刷新（需重新登录）。
  final String? refreshToken;

  /// 绝对过期时刻（UTC）。为 null 表示服务端未给出 `expires_in`。
  ///
  /// 存**绝对时刻**而非「剩余秒数」：后者在应用重启后语义就错了
  /// （写入时的 3600 秒与读取时的「现在」无关）。
  final DateTime? expiresAt;

  final String tokenType;
  final String? scope;

  /// 是否可用 [refreshToken] 续期。
  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// 在 [now] 时刻是否已过期（含 [skew] 余量）。
  ///
  /// [skew] 默认 60 秒：避免「请求发出瞬间刚好过期」这种边界失败。
  /// 无 [expiresAt] 时视为**未过期**（服务端没给信息，不该由客户端猜）。
  bool isExpired({DateTime? now, Duration skew = const Duration(seconds: 60)}) {
    final exp = expiresAt;
    if (exp == null) return false;
    return !(now ?? DateTime.now().toUtc()).add(skew).isBefore(exp);
  }

  /// 从 OIDC token 响应构造要落盘的凭证。
  ///
  /// ## 为什么收成一个工厂
  ///
  /// 这个映射此前在**四处**各写了一遍（两端 `providers.dart` 的登录回调与
  /// 刷新实现），全都写成 `accessToken: tokens.accessToken`——于是
  /// 「登录成功后立刻 401」这个缺陷同时存在于两端两条路径上，改一处漏三处。
  /// 收敛到一处后，`bearerToken` 的取值规则只有一份。
  ///
  /// 注意它**不做**「保留旧 refresh_token」：那是 [SessionManager._doRefresh]
  /// 的职责（它知道旧值），在这里做反而会拿到 null。
  factory StoredTokens.fromOidcTokens(
    OidcTokens tokens, {
    DateTime Function()? now,
  }) {
    final expiresIn = tokens.expiresIn;
    return StoredTokens(
      accessToken: tokens.bearerToken,
      refreshToken: tokens.refreshToken,
      expiresAt: expiresIn == null
          ? null
          : (now ?? () => DateTime.now().toUtc())().add(
              Duration(seconds: expiresIn),
            ),
      tokenType: tokens.tokenType,
      scope: tokens.scope,
    );
  }

  /// 复制并覆盖部分字段（刷新后使用）。
  ///
  /// 若新响应未下发 `refresh_token`，**保留旧的**：多数 IdP 在刷新时
  /// 不重复下发 refresh_token，直接置 null 会导致下次无法续期。
  StoredTokens copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? tokenType,
    String? scope,
    bool clearRefreshToken = false,
  }) => StoredTokens(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: clearRefreshToken
        ? null
        : (refreshToken ?? this.refreshToken),
    expiresAt: expiresAt ?? this.expiresAt,
    tokenType: tokenType ?? this.tokenType,
    scope: scope ?? this.scope,
  );

  /// 诊断用的安全描述（**不含任何 token 值**）。
  @override
  String toString() =>
      'StoredTokens(tokenType: $tokenType, canRefresh: $canRefresh, '
      'expiresAt: $expiresAt)';
}

/// 会话凭证的持久化接口（**纯 Dart，无 Flutter 依赖**）。
///
/// ## 为什么抽象成接口
///
/// 实现（Keychain / Keystore / libsecret）在 `spb_data`，那是个 Flutter 包；
/// 而 `spb_api` 必须是纯 Dart 才能无头单测。把接口放这里，`AuthInterceptor`
/// 只依赖接口，测试注入内存实现即可。
///
/// ⚠️ 实现必须**加密存储**（`flutter_secure_storage`），不得退化成
/// `SharedPreferences`：token 是会话凭证，明文落盘等于把登录态交给任何能读
/// 应用数据目录的进程。
abstract interface class TokenStore {
  /// 读取已存凭证；不存在返回 null。
  Future<StoredTokens?> read();

  /// 覆盖写入。
  Future<void> write(StoredTokens tokens);

  /// 清除（登出 / 刷新失败时调用）。
  Future<void> clear();
}

/// 内存实现（测试与开发用）。
///
/// 生产**不得**使用：重启即丢失，且不加密。
class InMemoryTokenStore implements TokenStore {
  InMemoryTokenStore([this._tokens]);

  StoredTokens? _tokens;

  /// 便于测试断言写入次数/内容。
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<StoredTokens?> read() async => _tokens;

  @override
  Future<void> write(StoredTokens tokens) async {
    _tokens = tokens;
    writeCount++;
  }

  @override
  Future<void> clear() async {
    _tokens = null;
    clearCount++;
  }
}

/// 刷新凭证的回调。
///
/// 返回 null 表示**无法刷新**（无 refresh token / 服务端拒绝），
/// 此时调用方应引导重新登录。
typedef TokenRefresher = Future<StoredTokens?> Function(StoredTokens current);

/// 一次刷新尝试的结论。
///
/// ## 为什么是三态而不是「成功 / 失败」二元
///
/// 「刷新失败」有两种**含义相反**的情形，处置方式也相反：
///
/// | 结论 | 含义 | 处置 |
/// |---|---|---|
/// | [refreshed] | 拿到新凭证 | 继续 |
/// | [rejected] | 服务端**明确**拒绝（`invalid_grant` / `401` / 无 refresh_token） | 凭证确实没了 → 回登录页 |
/// | [transient] | 没能得出结论（断网、超时、IdP 5xx、TLS） | **保留登录态**，下次请求再试 |
///
/// 合并成二元会造出一个真实缺陷（2026-10 用户报障）：笔记本休眠 / 切网后第一个
/// 请求的刷新因**连接层失败**而返回 null，被当成「凭证失效」→ 用户被登出；
/// 而 refresh_token 其实完好，所以「关闭重开又正常了」（新进程的网络栈是干净的）。
///
/// 判据是「这个失败是否携带了关于凭证有效性的信息」：
/// **网络层错误从不携带**，只有服务端明确回 `invalid_grant`/`401` 才算数。
enum TokenRefreshStatus {
  /// 拿到新凭证并已写回存储。
  refreshed,

  /// 服务端明确拒绝：refresh_token 已作废 / 无 refresh_token。
  rejected,

  /// 暂时性失败：无法据此判断凭证是否有效。
  transient,
}

/// 刷新结论（含新凭证或失败原因）。
///
/// 由 [SessionManager.refreshWithOutcome] 产出，`AuthInterceptor` 据此决定
/// 「重放请求」还是「回登录页」还是「什么都不做」。
class TokenRefreshOutcome {
  const TokenRefreshOutcome._(this.status, {this.tokens, this.error});

  /// 成功：新凭证已落盘。
  ///
  /// [tokens] 在**旧布尔回调路径**下为 null（那个回调只回 `bool`，拿不到
  /// 凭证；重放时由 `onRequest` 重新读存储）。新代码（`refreshWithOutcome`）
  /// 恒非 null。
  const TokenRefreshOutcome.refreshed([StoredTokens? tokens])
    : this._(TokenRefreshStatus.refreshed, tokens: tokens);

  /// 服务端明确拒绝（或本地根本没有 refresh_token）。
  const TokenRefreshOutcome.rejected({Object? error})
    : this._(TokenRefreshStatus.rejected, error: error);

  /// 暂时性失败——**不得**据此让用户登出。
  const TokenRefreshOutcome.transient({Object? error})
    : this._(TokenRefreshStatus.transient, error: error);

  final TokenRefreshStatus status;

  /// 刷新后的凭证。仅 [TokenRefreshStatus.refreshed] 时非 null；
  /// 且旧布尔回调路径下也为 null（见 [TokenRefreshOutcome.refreshed]）。
  final StoredTokens? tokens;

  /// 失败原因（诊断用，**不含 token 值**）。
  final Object? error;

  bool get isRefreshed => status == TokenRefreshStatus.refreshed;
  bool get isRejected => status == TokenRefreshStatus.rejected;
  bool get isTransient => status == TokenRefreshStatus.transient;

  @override
  String toString() =>
      'TokenRefreshOutcome(${status.name}'
      '${error == null ? '' : ', error: $error'})';
}

/// 会话凭证管理器：负责「拿到可用 token」与「过期前刷新」。
///
/// ## 职责边界
///
/// - **负责**：读缓存、判断过期、刷新、写回、去重并发刷新；
/// - **不负责**：发 HTTP 请求（由 `AuthInterceptor` 调用）、导航到登录页
///   （由上层监听 [AuthError]）。
///
/// ## 并发刷新去重（重要）
///
/// 页面初始化时常有多个请求同时发出，若每个都发现 token 过期并各自刷新，
/// 会：① 产生 N 次刷新请求；② 若 IdP 轮换 refresh_token，只有最后一个成功，
/// 其余会因用了已被作废的 refresh_token 而**永久失效**。
///
/// 故用 [_inflight] 把并发刷新合并成一次，所有调用方等同一个 Future。
class SessionManager {
  SessionManager({
    required this.store,
    required this.refresher,
    this.skew = const Duration(seconds: 60),
    this.clock,
  });

  final TokenStore store;

  /// 刷新实现（通常包一层 [OidcClient.refresh]）。
  final TokenRefresher refresher;

  /// 提前刷新余量，见 [StoredTokens.isExpired]。
  final Duration skew;

  /// 可注入的时钟（测试用）。
  final DateTime Function()? clock;

  Future<TokenRefreshOutcome>? _inflight;

  DateTime _now() => (clock ?? () => DateTime.now().toUtc())();

  /// 取一个**可用**的 access token；无凭证或无法续期时返回 null。
  ///
  /// 返回 null 的语义是「当前无有效凭证」，调用方（[AuthInterceptor]）应放行
  /// 请求，由服务端返回 401 → 上层跳登录。**不在此处抛异常**：拦截器抛异常会
  /// 让请求以异常形式失败，错误信息远不如服务端 401 清晰。
  ///
  /// ## 为什么刷新失败时返回「旧 token」而不是 null
  ///
  /// 见 [TokenRefreshStatus.transient]：网络层失败**不携带**任何关于凭证有效性
  /// 的信息。此时把请求降级成匿名（`Authorization` 都不带）等于替服务端提前判了
  /// 「已失效」——换回来的必然是 401，而那个 401 又被当成「会话失效」把人登出。
  /// 正确做法是拿旧 token 再试一次，让**服务端**（唯一有权限判定的角色）回答：
  ///
  /// - 服务端接受（clock skew / 服务端宽限）→ 用户完全无感；
  /// - 服务端回 401 → `AuthInterceptor` 会再刷一次，仍 transient 就放行给页面，
  ///   由页面提示「网络异常」，而不是静默登出。
  ///
  /// 只有服务端**明确拒绝**（`rejected`）时旧 token 才真的没用。
  Future<String?> currentAccessToken() async {
    final tokens = await store.read();
    if (tokens == null || tokens.accessToken.isEmpty) return null;

    if (!tokens.isExpired(now: _now(), skew: skew)) {
      return tokens.accessToken;
    }

    // 已过期：尝试刷新。
    final outcome = await refreshWithOutcome();
    if (outcome.isRefreshed) return outcome.tokens!.accessToken;

    // 暂时性失败（断网 / 超时 / IdP 5xx）：旧 token 可能仍被服务端接受，
    // 交给服务端判定，而不是在这里直接放弃。
    if (outcome.isTransient) {
      SpbLog.debug('凭证刷新暂时失败，先用旧凭证请求，由服务端判定', {
        'error': outcome.error.toString(),
      });
      return tokens.accessToken;
    }

    // 明确被拒（含无 refresh_token）：确实需要重新登录。
    return null;
  }

  /// 强制刷新（合并并发调用），只返回结果凭证。
  ///
  /// 成功则写回并返回新凭证；失败返回 null 并**保留**旧凭证
  /// （不 clear：临时网络故障不该让用户登出，由 401 决定是否真要重登）。
  ///
  /// 调用方若需要区分「暂时性失败」与「明确拒绝」，用 [refreshWithOutcome]。
  Future<StoredTokens?> refresh() async {
    final outcome = await refreshWithOutcome();
    return outcome.tokens;
  }

  /// 强制刷新并返回**三态结论**（合并并发调用）。
  ///
  /// 与 [refresh] 的唯一差别是保留失败的性质——这正是「一次断网就把用户登出」
  /// 那个缺陷的修法所在（见 [TokenRefreshStatus] 的说明）。
  Future<TokenRefreshOutcome> refreshWithOutcome() {
    final existing = _inflight;
    if (existing != null) return existing;

    final future = _doRefresh();
    _inflight = future;
    return future.whenComplete(() => _inflight = null);
  }

  Future<TokenRefreshOutcome> _doRefresh() async {
    final current = await store.read();
    // 本地就没有 refresh_token：这是**确定**的「无法续期」，不是网络问题。
    if (current == null || !current.canRefresh) {
      return const TokenRefreshOutcome.rejected();
    }

    StoredTokens? next;
    try {
      next = await refresher(current);
    } on SpbError catch (e) {
      return _classify(e);
    } catch (e) {
      // 非 SpbError 的异常（解析 / 平台通道等）：无法归因，按暂时性处理。
      // 保守方向很重要——把未知错误当成「凭证失效」会随机把人登出。
      SpbLog.warn('刷新会话凭证时发生未知异常', {'error': e.toString()});
      return TokenRefreshOutcome.transient(error: e);
    }

    // 刷新实现返回 null：它**明确**表示「无可用结果」（见 [TokenRefresher]）。
    if (next == null) return const TokenRefreshOutcome.rejected();

    // 新响应没带 refresh_token 时保留旧的（见 copyWith 说明）。
    final merged = next.copyWith(
      refreshToken: next.refreshToken ?? current.refreshToken,
    );
    await store.write(merged);
    return TokenRefreshOutcome.refreshed(merged);
  }

  /// 把一个刷新失败归到「明确拒绝」或「暂时性失败」。
  ///
  /// ## 判定表（改之前先看这张表）
  ///
  /// | 错误 | 结论 | 理由 |
  /// |---|---|---|
  /// | [NetworkError] | transient | 请求可能根本没到服务端 |
  /// | [ParseError] | transient | 响应解析失败：可能只是契约漂移，不该把人登出 |
  /// | [AuthError] 无 cause | rejected | token 端点回了 4xx（`invalid_grant` / `invalid_client`） |
  /// | [AuthError] + [HttpError] 5xx | **transient** | IdP 自己挂了，与凭证无关 |
  /// | [AuthError] + [HttpError] 4xx | rejected | 请求被拒（参数/客户端配置错，重试无用） |
  /// | [HttpError] 5xx | transient | 同上 |
  /// | [HttpError] 4xx | rejected | 同上 |
  /// | 其他 | transient | 无法归因时**保守**保留登录态 |
  ///
  /// ## ⚠️ 为什么必须看嵌套的 `cause`
  ///
  /// `OidcClient._tokenRequest` 对**任何**非 2xx 都抛
  /// `AuthError(message, cause: HttpError(status, ...))`——即最外层永远是
  /// `AuthError`，`statusCode` 字段是 null（它只描述「登录失败」）。真正的状态
  /// 码在 `cause` 里。
  ///
  /// 只按最外层类型判的话，`AuthError → rejected` 会把「IdP 回了 503」也当成
  /// 「凭证被作废」——那是同一个缺陷的另一条路径（IdP 重启期间所有用户被登出）。
  TokenRefreshOutcome _classify(SpbError error) {
    final status = _statusOf(error);

    if (status != TokenRefreshStatus.transient) {
      SpbLog.warn('刷新会话凭证被服务端拒绝（需重新登录）', {'error': error.toString()});
      return TokenRefreshOutcome.rejected(error: error);
    }

    // 用 warn 而非 error：这是**预期内**的可恢复情形（休眠唤醒 / 切网），
    // 但它是「为什么这次请求慢了一下」的唯一线索，不能降成 debug。
    SpbLog.warn('刷新会话凭证暂时失败（保留登录态，下次请求重试）', {'error': error.toString()});
    return TokenRefreshOutcome.transient(error: error);
  }

  /// 把一个错误映射成三态结论（只做分类，不记日志）。
  TokenRefreshStatus _statusOf(SpbError error) => switch (error) {
    NetworkError() => TokenRefreshStatus.transient,
    ParseError() => TokenRefreshStatus.transient,
    HttpError(:final statusCode) =>
      statusCode >= 500
          ? TokenRefreshStatus.transient
          : TokenRefreshStatus.rejected,
    // AuthError 自己不代表「凭证被拒」：token 端点的 5xx 也被包成它
    // （见 `OidcClient._tokenRequest`）。故要下探 cause。
    AuthError(:final cause) => switch (cause) {
      HttpError(:final statusCode) when statusCode >= 500 =>
        TokenRefreshStatus.transient,
      NetworkError() => TokenRefreshStatus.transient,
      ParseError() => TokenRefreshStatus.transient,
      _ => TokenRefreshStatus.rejected,
    },
    // 未知类型：保守保留登录态（把未知错误当「凭证失效」会随机把人登出）。
    _ => TokenRefreshStatus.transient,
  };

  /// 登出：清除本地凭证。
  Future<void> logout() => store.clear();
}
