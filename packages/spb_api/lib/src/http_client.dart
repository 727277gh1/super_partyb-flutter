import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

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
      //
      // **例外：401 / 403 必须抛。** 否则它们到不了 `onError` 拦截器，
      // 也就无从「刷新凭证后重放请求」；且各 API 方法得各自判状态码
      // （`validateStatus` 放行的 4xx 不会抛，`_unwrap` 才会补判）。
      // 把这两个码排除在外，等于把认证失败收敛到一条链路上。
      validateStatus: (status) =>
          status != null &&
          status < 500 &&
          status != 401 &&
          status != 403,
    ),
  );

  dio.interceptors.addAll(interceptors);

  // 错误映射拦截器放在最后，保证它看到的是其余拦截器处理后的状态。
  //
  // ⚠️ 传入的 interceptors 里若有 `AuthInterceptor`，它已经处理过 401
  // （刷新重放或归一化为 AuthError），这里只兜底 5xx 与网络层失败。
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (e, handler) {
        // 5xx 由 validateStatus 放行到这里（>=500 不通过校验）。
        // 统一转成 SpbError 后以 DioException 的 error 字段向上传递。
        //
        // 若上游拦截器已把 SpbError 放进 `e.error`，不要覆盖它
        // （否则 AuthError 会被降级成 HttpError，上层就分不清
        // 「该重新登录」与「该重试」了）。
        if (e.error is SpbError) {
          handler.next(e);
          return;
        }
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
