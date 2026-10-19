/// 认证状态（登录页与路由守卫共享的词汇）。
///
/// 放在 `spb_features` 而非 `spb_core`：它是**界面层**的概念（决定显示登录页
/// 还是主界面），而不是传输层/领域层的概念。`spb_api` 只认「有没有可用凭证」
/// （`SessionManager.currentAccessToken`），不关心 UI 该显示什么。
library;

/// 认证状态。
enum AuthStatus {
  /// 尚未判定（启动后首次读取凭证，或正在校验）。
  ///
  /// ## 为什么需要这个「中间态」
  ///
  /// 读取凭证是**异步**的（安全存储要走平台通道）。若把「还没读到」当成
  /// 「未登录」，应用启动瞬间会先闪一下登录页再跳回主界面；反之若当成
  /// 「已登录」，未登录用户会先看到主界面再被踢走。故单列一个状态，
  /// 路由守卫在 [unknown] 时**不做任何重定向**（保持当前页，等判定结果）。
  unknown,

  /// 有可用凭证。
  authenticated,

  /// 无可用凭证（或凭证已失效）。
  unauthenticated,
}

/// 认证状态快照。
class AuthState {
  const AuthState({this.status = AuthStatus.unknown, this.message});

  final AuthStatus status;

  /// 最近一次认证失败的说明（登录页据此显示错误）。
  ///
  /// 为 null 表示没有待展示的错误（不是「空字符串错误」）。
  final String? message;

  static const unknown = AuthState();
  static const authenticated = AuthState(status: AuthStatus.authenticated);
  static const unauthenticated = AuthState(status: AuthStatus.unauthenticated);

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isUnauthenticated => status == AuthStatus.unauthenticated;

  /// 带错误消息的未认证状态。
  factory AuthState.failed(String message) =>
      AuthState(status: AuthStatus.unauthenticated, message: message);

  AuthState copyWith({
    AuthStatus? status,
    String? message,
    bool clearMessage = false,
  }) => AuthState(
    status: status ?? this.status,
    message: clearMessage ? null : (message ?? this.message),
  );

  @override
  String toString() =>
      'AuthState(status: ${status.name}'
      '${message == null ? '' : ', message: $message'})';
}
