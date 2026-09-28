import 'package:dio/dio.dart';

// mapDioError 与 AuthInterceptor 同文件（auth_interceptor.dart）。
import 'auth_interceptor.dart';

/// Dio 工厂：统一 baseUrl、超时、拦截器与错误映射。
///
/// ## 端点前缀说明（易踩坑）
///
/// Go API 的路由分两套前缀（见 super_partyb AGENTS.md「路由结构」）：
/// - `/api/*`：CRUD（agents / habits / api-keys / skills ...）
/// - `/chat/*`：聊天（groups / turns / confirmations ...）
/// - `/users/:user_id/chat/*`：用户消息流与 SSE
/// - `/me/*`：跨 group 的用户级端点
///
/// **不是** `/api/chat`。`baseUrl` 只到服务根（网关下为 `.../pba`），
/// 具体路径由各 API 方法拼接。
Dio createDio({
  required String baseUrl,
  List<Interceptor> interceptors = const [],
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 60),
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      // 普通请求 60s：聊天 POST 是异步入队（立即返回 turn），不占长连接；
      // 真正的长连接是 SSE，在 SseClient 里单独关掉超时。
      receiveTimeout: receiveTimeout,
      // Go API 返回裸 JSON，不包 {success,data,error}。
      responseType: ResponseType.json,
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      // 不让 dio 对 4xx/5xx 抛异常——统一在拦截器里转成 SpbError，
      // 使调用方只需 catch 一种类型。
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  dio.interceptors.addAll(interceptors);

  // 错误映射拦截器放在最后，保证它看到的是其余拦截器处理后的状态。
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (e, handler) {
        // 5xx 由 validateStatus 放行到这里（>=500 不通过校验）。
        // 统一转成 SpbError 后以 DioException 的 error 字段向上传递。
        final mapped = mapDioError(e);
        handler.reject(
          DioException(
            requestOptions: e.requestOptions,
            response: e.response,
            type: e.type,
            error: mapped,
            stackTrace: e.stackTrace,
          ),
        );
      },
    ),
  );

  return dio;
}
