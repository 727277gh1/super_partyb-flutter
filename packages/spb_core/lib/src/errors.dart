/// 统一错误类型。
///
/// WHY 不用 `Exception` 直接抛出：跨层传递时无法区分「可重试」与「不可重试」，
/// UI 只能笼统显示「出错了」。这里用 sealed class 让调用方在编译期穷举处理分支。
sealed class SpbError implements Exception {
  const SpbError(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => '$runtimeType: $message';
}

/// 网络层失败（连接超时、DNS、TLS）。
///
/// [retryable] 为 true 时上层可安全重试；SSE 断线重连走此分支。
final class NetworkError extends SpbError {
  const NetworkError(
    super.message, {
    super.cause,
    super.stackTrace,
    this.retryable = true,
  });

  final bool retryable;
}

/// HTTP 响应非 2xx。
final class HttpError extends SpbError {
  const HttpError(
    this.statusCode,
    super.message, {
    this.body,
    super.cause,
    super.stackTrace,
  });

  final int statusCode;
  final String? body;

  /// 401：凭证失效，需重新走 OIDC 登录。
  bool get isUnauthorized => statusCode == 401;

  /// 403：凭证有效但无权限。
  bool get isForbidden => statusCode == 403;

  /// 404：资源不存在（常见于 group / turn 被删除）。
  bool get isNotFound => statusCode == 404;

  /// 409：并发冲突（如重复提交同一 request_id）。
  bool get isConflict => statusCode == 409;

  /// 429：限流，应按 `Retry-After` 退避。
  bool get isRateLimited => statusCode == 429;

  /// 5xx：服务端故障，可重试。
  bool get isServerError => statusCode >= 500;
}

/// 响应体解析失败（JSON 结构不符合预期 / 契约漂移）。
///
/// 与 [NetworkError] 分开的原因：解析失败重试无用，应尽快暴露以便修契约。
final class ParseError extends SpbError {
  const ParseError(super.message, {this.raw, super.cause, super.stackTrace});

  final String? raw;
}

/// 认证失败（本地无凭证 / 凭证过期 / 服务端 401·403）。
///
/// ## 为什么不复用 [HttpError]（它同样带 statusCode）
///
/// 上层对两者的**处置方式不同**：`HttpError(401)` 会被人当成「一个失败的 HTTP 请求」
/// 而重试；而 401 意味着**重试无用**，必须重新登录。用独立类型让 UI 能在编译期
/// 穷举出「弹登录页」这条分支，而不是靠 `statusCode == 401` 的字符串/魔法数字判断。
///
/// [statusCode] 为 null 表示失败发生在**发请求之前**（如本地无凭证、
/// token 端点返回错误体缺 access_token），此时没有 HTTP 状态码可归因。
final class AuthError extends SpbError {
  const AuthError(
    super.message, {
    this.statusCode,
    super.cause,
    super.stackTrace,
  });

  /// 触发该错误的 HTTP 状态码（401 / 403）；null 表示非 HTTP 触发。
  final int? statusCode;

  /// 会话凭证失效（401），需重新走 OIDC 登录。
  bool get isUnauthorized => statusCode == 401;

  /// 凭证有效但无权限（403）。
  bool get isForbidden => statusCode == 403;
}

/// 本地存储失败（drift / 文件系统）。
final class StorageError extends SpbError {
  const StorageError(super.message, {super.cause, super.stackTrace});
}

/// 平台能力不可用（如 Linux 上调用仅 Windows 支持的托盘 API）。
final class PlatformError extends SpbError {
  const PlatformError(super.message, {super.cause, super.stackTrace});
}

/// 输入不满足业务前置条件（本地校验失败，**未发起网络请求**）。
///
/// WHY 需要单独一个类型：它与 [HttpError] 的 4xx 看起来都是「请求不合法」，
/// 但成因完全不同：
///   - [ValidationError]：客户端自己就能判定（如「输入与附件都为空」），
///     重试无意义，应直接引导用户改输入；
///   - [HttpError] 4xx：服务端拒绝了请求，可能是契约漂移，需要看 body 排查。
/// 混为一谈会让「空输入」这种小事在日志里看起来像服务端故障。
final class ValidationError extends SpbError {
  const ValidationError(super.message, {super.cause, super.stackTrace});
}

/// 消息已**排队待发送**，尚未投递（issue #26 切片 C / issue #30）。
///
/// ## 为什么它是一个「错误」（而不是一个成功结果）
///
/// 它从 `ChatStreamController.send` 抛出，而调用方的默认处置是「提示发送
/// 失败」。但**语义上它不是失败**——用户打好的字没丢，联网后会自动发出去。
///
/// 若不给它一个独立类型，UI 只能说「发送失败：网络错误」，用户会以为消息
/// 丢了、然后重打一遍（结果发两条）。有了独立类型，UI 可以准确地说「已排队，
/// 联网后自动发送」。
///
/// ## 为什么必须是 [SpbError] 的子类（以及为什么放在本文件）
///
/// 控制器的 `send` 只能抛 `SpbError`（catch 分支绑在这个类型上）；而
/// `SpbError` 是 **sealed** 的，子类必须与它同库。
///
/// ## 为什么名字不提「队列」（queued 就够了）
///
/// `spb_core` 是分层最底的基础设施，**不应该知道「离线队列」这个上层机制**。
/// 它只知道「这条消息进入了待发送状态」这个事实。将来若换掉队列实现
/// （例如改由服务端排队），本类型仍然成立。
final class MessageQueuedError extends SpbError {
  const MessageQueuedError(super.message, {super.cause, super.stackTrace});
}

/// 消息投递**最终失败**（重试用尽，或遇终态错误），确实没送出去。
///
/// 与 [MessageQueuedError] 相反：这次不会自动重试（重试用尽时用户可手动重试）。
/// UI 应明确提示失败并保留用户输入。
final class MessageDeliveryFailedError extends SpbError {
  const MessageDeliveryFailedError(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}
