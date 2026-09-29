import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 认证头注入器 + 401/403 归一化 + 刷新后重放。
///
/// ## 认证模型（重要）
///
/// 生产链路是：**客户端 → api-gateway（OIDC 认证）→ 注入 `X-User-ID` → Go API**。
/// 因此客户端**不解析 JWT、不申请 API Key**，只需携带会话凭证（Cookie / OIDC token），
/// 由网关完成认证并注入身份头。
///
/// 本地开发可绕过网关直连 Go API（`AUTH_MODE=header`），此时需要自行提供
/// `X-User-ID`——本类通过 [userHeaderOverride] 支持这种开发态。
///
/// ⚠️ **绝不缓存 user_id 到持久化存储并当作身份真源**：它是网关注入的结果，
/// 客户端侧的值只用于拼 URL 路径（`/users/:user_id/chat/*`）。
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required this.tokenProvider,
    this.userHeaderOverride,
    this.onUnauthorized,
  });

  /// 异步获取当前会话凭证（OIDC access token / session cookie）。
  ///
  /// 用回调而非直接持有 token：token 会过期并刷新，持有快照会用到陈旧值。
  /// 通常由 `SessionManager.currentAccessToken` 实现（内含过期前刷新）。
  final Future<String?> Function() tokenProvider;

  /// 开发态直连 Go API 时手工指定的 `X-User-ID`。
  ///
  /// **生产必须为 null**——若生产也设置，等于允许客户端自选身份，
  /// 会绕过网关的认证。网关模式下这个头由网关覆盖写入。
  final String? userHeaderOverride;

  /// 401 时的刷新回调。返回 true 表示已刷新，可重放原请求。
  ///
  /// 由 `SessionManager.refresh` 实现。为 null 时不做刷新，401 直接归一化为
  /// [AuthError]。
  final Future<bool> Function()? onUnauthorized;

  /// 重放请求用的 Dio。
  ///
  /// ## 为什么是可变字段而非构造参数
  ///
  /// 它必须是**同一个** Dio（否则会丢掉连接池与其余拦截器），而本拦截器又是
  /// 该 Dio 的构造参数之一——直接传参会形成循环。故由 `createDio` 的调用方在
  /// 构造后立即回填（见两端 `providers.dart`）：
  ///
  /// ```dart
  /// final auth = AuthInterceptor(...);
  /// final dio = createDio(interceptors: [auth]);
  /// auth.replayDio = dio;
  /// ```
  ///
  /// 为 null 时（如单测直接构造拦截器）不重放，401 归一化为 [AuthError]。
  Dio? replayDio;

  /// 标记「已重放过一次」，防止刷新后仍 401 造成无限循环。
  static const String _retriedKey = 'spb_auth_retried';

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final token = await tokenProvider();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      final override = userHeaderOverride;
      if (override != null && override.isNotEmpty) {
        options.headers['X-User-ID'] = override;
      }
      handler.next(options);
    } catch (e) {
      // 取 token 失败不应让请求静默消失——放行让服务端返回 401，
      // 上层据此触发重新登录，比在此处吞掉错误更可诊断。
      SpbLog.warn('获取认证凭证失败，请求将以匿名身份发出', {'error': e.toString()});
      handler.next(options);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;

    // 只有 401 值得刷新：403 是「已认证但无权限」，刷新 token 也变不出权限。
    if (status == 401) {
      final refreshed = await _tryRefreshAndReplay(err, handler);
      if (refreshed) return;
      SpbLog.warn('收到 401，会话凭证可能已失效');
      // 不在此处自动跳登录：拦截器不应有导航副作用（可能同时多个请求触发）。
      // 由上层统一监听 AuthError 并跳转登录页。
    }

    handler.next(_normalizeAuthError(err));
  }

  /// 刷新凭证并重放原请求。返回 true 表示已 resolve（调用方不应再继续处理）。
  Future<bool> _tryRefreshAndReplay(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final refresh = onUnauthorized;
    final dio = replayDio;
    if (refresh == null || dio == null) return false;
    if (err.requestOptions.extra[_retriedKey] == true) return false;

    bool refreshed;
    try {
      refreshed = await refresh();
    } catch (e) {
      SpbLog.warn('刷新会话凭证时异常', {'error': e.toString()});
      return false;
    }
    if (!refreshed) return false;

    // 重放：复制原请求并把新 token 交给 onRequest 重新注入。
    // 打上标记避免「刷新成功但服务端仍 401」时无限循环。
    final options = err.requestOptions
      ..extra[_retriedKey] = true
      // 清掉旧 Authorization，否则 onRequest 覆盖前会先带上过期值。
      ..headers.remove('Authorization');

    try {
      final response = await dio.fetch<dynamic>(options);
      SpbLog.debug('401 后刷新凭证并重放成功', {'path': options.path});
      handler.resolve(response);
      return true;
    } on DioException catch (e) {
      // 重放也失败：按重放响应归一化（它带着更准确的状态码）。
      handler.next(_normalizeAuthError(e));
      return true;
    }
  }

  /// 把 401/403 归一化为 [AuthError]。
  ///
  /// ## 为什么不复用 [HttpError]
  ///
  /// 上层对 401 的处置是「跳登录页」而非「重试请求」。若沿用 `HttpError`，
  /// UI 只能靠 `statusCode == 401` 判断；归一化成 [AuthError] 后，
  /// 监听一种类型即可（见 `packages/spb_core/lib/src/errors.dart` 的说明）。
  static DioException _normalizeAuthError(DioException err) {
    final status = err.response?.statusCode;
    if (status != 401 && status != 403) return err;

    final mapped = AuthError(
      status == 401 ? '会话已失效，请重新登录' : '没有权限执行该操作',
      statusCode: status,
      cause: err,
    );
    return DioException(
      requestOptions: err.requestOptions,
      response: err.response,
      type: err.type,
      error: mapped,
      stackTrace: err.stackTrace,
    );
  }
}

/// 把 dio 异常统一转成 [SpbError]，使上层只处理一种错误类型。
SpbError mapDioError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return NetworkError(
        '网络请求失败：${e.message ?? e.type.name}',
        cause: e,
        retryable: true,
      );
    case DioExceptionType.cancel:
      return NetworkError('请求已取消', cause: e, retryable: false);
    case DioExceptionType.badCertificate:
      return NetworkError('TLS 证书校验失败', cause: e, retryable: false);
    case DioExceptionType.transformTimeout:
      // 响应体转换超时：本地处理慢，重试通常无用但无害。
      return NetworkError('响应处理超时', cause: e, retryable: false);
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode ?? 0;
      // 401/403 是「凭证问题」而非「请求问题」：归为 AuthError 让上层能区分
      // 「该重新登录」与「该重试」。否则 UI 会把会话过期显示成「HTTP 401」。
      if (status == 401) {
        return AuthError('会话已失效，请重新登录', statusCode: 401, cause: e);
      }
      if (status == 403) {
        return AuthError('没有权限执行该操作', statusCode: 403, cause: e);
      }
      return HttpError(
        status,
        'HTTP $status',
        body: _bodyPreview(e.response?.data),
        cause: e,
      );
    case DioExceptionType.unknown:
      // 响应已到达但解析失败时会落到这里，归类为解析错误。
      if (e.response != null) {
        return ParseError('响应解析失败', cause: e);
      }
      return NetworkError('未知网络错误：${e.message}', cause: e);
  }
}

String? _bodyPreview(Object? data) {
  if (data == null) return null;
  final s = data is String ? data : data.toString();
  // 截断避免把整页 HTML 错误塞进日志/UI。
  return s.length > 500 ? '${s.substring(0, 500)}…' : s;
}

/// 便捷方法：从响应体里取 `items` 数组（Go API 的裸 JSON 约定）。
///
/// 前端（webapp）用 `requestJson` + `unwrapItems` 适配，此处等价。
/// 见 super_partyb AGENTS.md「API 响应结构」：Go API 返回裸 JSON
/// （如 `{items:[...]}`），不再用 Python 的 `{success,data,error}` 包装。
List<T> unwrapItems<T>(
  Object? json,
  T Function(Map<String, dynamic>) fromItem,
) => ListResponse<T>.fromJson(json, fromItem).items;
