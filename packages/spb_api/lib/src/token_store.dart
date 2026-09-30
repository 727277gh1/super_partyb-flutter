import 'dart:async';

import 'package:spb_core/spb_core.dart';

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

  Future<StoredTokens?>? _inflight;

  DateTime _now() => (clock ?? () => DateTime.now().toUtc())();

  /// 取一个**可用**的 access token；无凭证或无法续期时返回 null。
  ///
  /// 返回 null 的语义是「当前无有效凭证」，调用方（[AuthInterceptor]）应放行
  /// 请求，由服务端返回 401 → 上层跳登录。**不在此处抛异常**：拦截器抛异常会
  /// 让请求以异常形式失败，错误信息远不如服务端 401 清晰。
  Future<String?> currentAccessToken() async {
    final tokens = await store.read();
    if (tokens == null || tokens.accessToken.isEmpty) return null;

    if (!tokens.isExpired(now: _now(), skew: skew)) {
      return tokens.accessToken;
    }

    // 已过期：尝试刷新。刷新失败（含无 refresh_token）返回 null。
    final refreshed = await refresh();
    return refreshed?.accessToken;
  }

  /// 强制刷新（合并并发调用）。
  ///
  /// 成功则写回并返回新凭证；失败返回 null 并**保留**旧凭证
  /// （不 clear：临时网络故障不该让用户登出，由 401 决定是否真要重登）。
  Future<StoredTokens?> refresh() {
    final existing = _inflight;
    if (existing != null) return existing;

    final future = _doRefresh();
    _inflight = future;
    return future.whenComplete(() => _inflight = null);
  }

  Future<StoredTokens?> _doRefresh() async {
    final current = await store.read();
    if (current == null || !current.canRefresh) return null;

    StoredTokens? next;
    try {
      next = await refresher(current);
    } catch (e) {
      // 刷新失败的原因很多（网络、服务端 5xx、refresh_token 被作废）。
      // 这里只记日志并返回 null——具体处置由「下一次请求是否 401」决定，
      // 避免把一次抖动升级成强制登出。
      SpbLog.warn('刷新会话凭证失败', {'error': e.toString()});
      return null;
    }
    if (next == null) return null;

    // 新响应没带 refresh_token 时保留旧的（见 copyWith 说明）。
    final merged = next.copyWith(
      refreshToken: next.refreshToken ?? current.refreshToken,
    );
    await store.write(merged);
    return merged;
  }

  /// 登出：清除本地凭证。
  Future<void> logout() => store.clear();
}
