import 'oidc_client.dart';

/// 一次进行中的登录请求（`state` + PKCE 参数）。
///
/// 二者必须**一起**保存：`state` 用于回调时校验来源，`code_verifier` 用于换
/// token。分开保存会出现「校验通过但换 token 时找不到 verifier」。
class PendingAuthRequest {
  const PendingAuthRequest({required this.state, required this.pkce});

  final String state;
  final PkcePair pkce;

  /// 诊断用（**不含 verifier 值**）。
  @override
  String toString() => 'PendingAuthRequest(state: $state, pkce: $pkce)';
}

/// 待验证登录请求的存放处。
///
/// ## 为什么需要它
///
/// 授权流程会把用户带到**外部浏览器**，应用可能在此期间被系统回收
/// （Android 低内存时很常见）。回调到达时应用可能已经重启，
/// 若 `state`/`verifier` 只存在内存里就会丢失，表现为「登录后应用毫无反应」。
///
/// ## 为什么方法是异步的
///
/// 生产实现（`spb_data` 的 `SecurePendingAuthStore`）走平台安全存储，
/// 每次读写都是一次平台通道往返，无法同步完成。内存实现只是把同步结果
/// 包进已完成的 Future——调用方（`mobileSignIn` / `AuthDeepLinkReceiver`）
/// 统一按异步处理，不区分后端。
abstract interface class PendingAuthRequestStore {
  /// 记录一次新发起的登录（覆盖旧的）。
  Future<void> put(PendingAuthRequest request);

  /// 取出并**清除**（一次性）。
  ///
  /// 必须一次性：同一个 `state` 若能被重复消费，重放同一个回调链接就能
  /// 反复换 token。
  Future<PendingAuthRequest?> consume();
}

/// 内存实现（测试与开发用）。
///
/// 生产使用 `spb_data` 的 [SecurePendingAuthStore]（加密持久化）——
/// 内存实现在进程被系统回收后丢失，登录回调将因「没有进行中的登录」被拒。
class InMemoryPendingAuthStore implements PendingAuthRequestStore {
  PendingAuthRequest? _pending;

  @override
  Future<void> put(PendingAuthRequest request) async => _pending = request;

  @override
  Future<PendingAuthRequest?> consume() async {
    final p = _pending;
    _pending = null;
    return p;
  }
}
