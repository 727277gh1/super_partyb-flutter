import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 认证头注入器。
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
  AuthInterceptor({required this.tokenProvider, this.userHeaderOverride});

  /// 异步获取当前会话凭证（OIDC access token / session cookie）。
  ///
  /// 用回调而非直接持有 token：token 会过期并刷新，持有快照会用到陈旧值。
  final Future<String?> Function() tokenProvider;

  /// 开发态直连 Go API 时手工指定的 `X-User-ID`。
  ///
  /// **生产必须为 null**——若生产也设置，等于允许客户端自选身份，
  /// 会绕过网关的认证。网关模式下这个头由网关覆盖写入。
  final String? userHeaderOverride;

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
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    if (status == 401) {
      SpbLog.warn('收到 401，会话凭证可能已失效');
      // 不在此处自动刷新/跳登录：拦截器不应有导航副作用（可能同时多个请求触发）。
      // 由上层统一监听 AuthError 并跳转登录页。
    }
    handler.next(err);
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
