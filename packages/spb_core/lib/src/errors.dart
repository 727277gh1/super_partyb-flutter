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

/// 认证失败（本地无凭证 / 凭证过期）。
final class AuthError extends SpbError {
  const AuthError(super.message, {super.cause, super.stackTrace});
}

/// 本地存储失败（drift / 文件系统）。
final class StorageError extends SpbError {
  const StorageError(super.message, {super.cause, super.stackTrace});
}

/// 平台能力不可用（如 Linux 上调用仅 Windows 支持的托盘 API）。
final class PlatformError extends SpbError {
  const PlatformError(super.message, {super.cause, super.stackTrace});
}
