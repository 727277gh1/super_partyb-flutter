import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

/// 把每个请求的基地址重写成「当前生效的端点」（issue #50 运行中降级/升级）。
///
/// ## 为什么必须是拦截器，而不是「降级时 invalidate 掉 dioProvider」
///
/// 两端的 `dioProvider` / `ufsDioProvider` / `sseClientProvider` 都被
/// `ChatStreamController` 等长命对象持有，而 `_ChatPage` 的帧订阅是
/// `_itemsSub ??=` 形式（只绑一次）。重建 provider 会让旧订阅指向已
/// dispose 的控制器，表现为**时间线静默冻结**——比不降级更难排查。
///
/// 拦截器方案把「读哪个 host」推迟到**每次请求**，于是：
/// - Dio 实例、连接池、拦截器链、SSE 客户端的身份全部不变；
/// - 降级后下一个请求自然打到编译期地址，无需通知任何人。
///
/// ## 为什么不自己换连接池
///
/// `BaseOptions.baseUrl` 只是「拼 URL 的字符串前缀」，keep-alive 池按
/// **实际 URI 的 host** 分桶。改了前缀，新请求自然落到另一个桶；旧桶
/// 的连接会因 `HttpClient` 空闲超时而回收。手动 `close(force: true)` 反而
/// 会把正在跑的请求一起打断。
class EndpointRewriteInterceptor extends Interceptor {
  EndpointRewriteInterceptor({required this.resolveBaseUrl});

  /// 返回「此刻应该用的基地址」。每次请求调一次，不得缓存。
  final String Function() resolveBaseUrl;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // 只重写相对路径的请求。绝对 URL（`options.path` 自带 scheme）由
    // 调用方明确指定了目标，不该被端点策略覆盖。
    if (options.path.startsWith('http://') ||
        options.path.startsWith('https://')) {
      handler.next(options);
      return;
    }
    final next = resolveBaseUrl();
    if (options.baseUrl != next) {
      // 不改 `options.path`：各 API 方法拼的是相对路径，换前缀即可。
      options.baseUrl = next;
    }
    handler.next(options);
  }
}

/// 把 Dio 的失败形态归类成 [EndpointFailureKind]（端点升降级的判据输入）。
///
/// ## 为什么必须分形态，而不是「所有错误都算」
///
/// 降级的含义是「这个 host 连不上，换回编译期地址」。而 `badResponse`（4xx /
/// 5xx）恰恰说明 **host 是通的**——源站回了错误码，只是业务出错。把后者计入
/// 会让「服务端一次 500」把用户从 IPv6 源站踢回 CDN，且永不恢复优化路径。
///
/// 判定依据是 `DioExceptionType`，不是错误消息文本：文本会随 dio 版本与平台
/// 变化，而枚举值是协议层的稳定事实。
EndpointFailureKind classifyDioFailure(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.badCertificate:
      // badCertificate 归为 connectivity：连不上（TLS 握手失败）与「路由不通」
      // 对端点选择是同一件事——换回编译期地址是有意义的下一步。
      return EndpointFailureKind.connectivity;
    case DioExceptionType.cancel:
      return EndpointFailureKind.cancelled;
    case DioExceptionType.badResponse:
    case DioExceptionType.transformTimeout:
    case DioExceptionType.unknown:
      // unknown 分两种：有 response（解析失败，连接是通的）与没有（真正未知）。
      // 只有在**没有** response 时才可能是连接层问题，但那已被
      // `connectionError` 覆盖，故这里保守地归为 server（不计入降级）。
      return EndpointFailureKind.server;
  }
}

/// 端点健康观测拦截器（issue #50）。
///
/// ## 职责：只做「观测 + 上报」，不做任何重试
///
/// 它把每次请求的成败喂给 [EndpointGuard]：
/// - 成功 → `recordSuccess()`（清零连续失败计数）；
/// - 连接层失败 → `recordFailure(connectivity)`（累计到阈值触发降级）；
/// - 其余失败 → 忽略。
///
/// **不在这里重试请求**。降级后基地址会变（`SpbEndpoints.changes` 广播），
/// 装配层只需让 `SseClient` 换 host（见 `SseClient.switchBaseUrl`）；此时重试
/// 一个已经注定失败的请求既浪费又会让「当前请求」的调用方多等一个超时。
/// 重试权属于各调用方与 `OutboxQueue`。
///
/// ## 为什么排在 `AuthInterceptor` **之后**、错误映射之前
///
/// - 在 `AuthInterceptor` 之后：「401 → 刷新 → 重放成功」由它自己处理掉，
///   不会走到这里污染降级判据；
/// - 在错误映射**之前**：dio 的错误链在某个拦截器 `reject()` 后**不再调用
///   下游 `onError`**。若健康拦截器排在错误映射之后，连接层失败就永远不会
///   被计数——降级永不触发（issue #50 的主症状）。
class EndpointHealthInterceptor extends Interceptor {
  EndpointHealthInterceptor({EndpointGuard? guard})
    : _guard = guard ?? EndpointGuard.instance;

  final EndpointGuard _guard;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _guard.recordSuccess();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final kind = classifyDioFailure(err);
    if (kind == EndpointFailureKind.connectivity) {
      // 只在连接层失败时记一条日志（服务端错误由各 API 层记，避免重复）。
      // 不打完整 URL：诊断报告会被贴进公开 issue（AGENTS.md §6.20）。
      SpbLog.debug('端点连接失败，计入降级判据', {
        'type': err.type.name,
        'consecutive': _guard.consecutiveFailures + 1,
      });
      _guard.recordFailure(kind);
    }
    handler.next(err);
  }
}
