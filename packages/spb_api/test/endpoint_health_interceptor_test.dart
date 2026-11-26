import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 端点健康观测（issue #50）的契约测试。
///
/// ## 这个测试防的是什么
///
/// 拦截器是「降级判据」的唯一输入源，判错的两类后果都只在真实网络变化时
/// 现形（本机无 IPv6 变化，永远复现不到）：
///
///   1. **误报**：把 4xx/5xx 或用户取消计入 → 服务端一次 500 就把用户从
///      源站踢回 CDN，且冷却期后才可能恢复；
///   2. **漏报**：连接层失败不计入 → 切到无 IPv6 的网络后永不降级，用户
///      只能重启 App（issue #50 的主症状）。
///
/// ⚠️ **必须走真实 Dio 链，不能直接调 `interceptor.onError(...)`**：
/// 那样造出的 `ErrorInterceptorHandler` 的 future 无人 await，会变成未捕获的
/// 异步错误而让用例假失败。而用真实链还有个额外收益——它顺带钉住了
/// 「健康拦截器必须在错误映射拦截器**之前**」（见 `createDio` 的注释：
/// 放到后面的话 `reject` 会跳过下游 `onError`，降级永不触发）。
void main() {
  setUp(() {
    SpbEndpoints.resetForTest();
    SpbLog.configure(sink: const NullLogSink());
  });

  tearDown(() {
    EndpointGuard.instance.dispose();
    SpbEndpoints.resetForTest();
  });

  /// 把端点置为「已升级」态（`EndpointGuard` 只在这个态下计数）。
  Future<void> setUpgraded() async {
    final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
    await SpbEndpoints.resolveAndUpdate(
      preferred: <String, String>{compiledHost: 'v6.example.com'},
      probe: (_, _, _) async => true,
      timeout: const Duration(milliseconds: 5),
    );
    expect(
      SpbEndpoints.current.probeOutcome,
      EndpointProbeOutcome.upgraded,
      reason: '前置条件：本组用例都从升级态开始',
    );
  }

  /// 发一个注定失败的请求（把 DioException 吃掉，只看副作用）。
  Future<void> swallow(Future<void> Function() body) async {
    try {
      await body();
    } on Object {
      // 期望失败：这里只关心对 guard 的副作用。
    }
  }

  group('classifyDioFailure', () {
    DioException netError([
      DioExceptionType type = DioExceptionType.connectionError,
    ]) {
      final opts = RequestOptions(path: '/x', baseUrl: 'https://a.example.com');
      return DioException(requestOptions: opts, type: type, message: 'boom');
    }

    DioException httpError(int status) {
      final opts = RequestOptions(path: '/x', baseUrl: 'https://a.example.com');
      return DioException(
        requestOptions: opts,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(requestOptions: opts, statusCode: status),
      );
    }

    test('连接层失败归为 connectivity', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
        DioExceptionType.badCertificate,
      ]) {
        expect(
          classifyDioFailure(netError(type)),
          EndpointFailureKind.connectivity,
          reason: '$type 应计入降级判据',
        );
      }
    });

    test('badResponse 归为 server（不计入）', () {
      expect(classifyDioFailure(httpError(500)), EndpointFailureKind.server);
      expect(classifyDioFailure(httpError(404)), EndpointFailureKind.server);
    });

    test('cancel 归为 cancelled', () {
      expect(
        classifyDioFailure(netError(DioExceptionType.cancel)),
        EndpointFailureKind.cancelled,
      );
    });

    test('transformTimeout / unknown 归为 server', () {
      expect(
        classifyDioFailure(netError(DioExceptionType.transformTimeout)),
        EndpointFailureKind.server,
      );
      expect(
        classifyDioFailure(netError(DioExceptionType.unknown)),
        EndpointFailureKind.server,
      );
    });
  });

  group('通过真实 Dio 链观测', () {
    test('连续连接失败把 guard 推到降级', () async {
      await setUpgraded();
      final dio = createDio(baseUrl: 'https://a.example.com')
        ..httpClientAdapter = _ScriptedAdapter(() => _Failing.connection);

      for (var i = 0; i < 3; i++) {
        await swallow(() => dio.get<dynamic>('/x'));
      }

      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.downgraded,
      );
    });

    test('服务端 5xx 不触发降级', () async {
      await setUpgraded();
      final dio = createDio(baseUrl: 'https://a.example.com')
        ..httpClientAdapter = _ScriptedAdapter(() => _Failing.http500);

      for (var i = 0; i < 10; i++) {
        await swallow(() => dio.get<dynamic>('/x'));
      }
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(EndpointGuard.instance.consecutiveFailures, 0);
    });

    test('成功响应清零计数（失败夹在成功之间不累积到阈值）', () async {
      await setUpgraded();
      var failNext = true;
      final dio = createDio(baseUrl: 'https://a.example.com')
        ..httpClientAdapter = _ScriptedAdapter(
          () => failNext ? _Failing.connection : _Failing.none,
        );

      await swallow(() => dio.get<dynamic>('/x'));
      await swallow(() => dio.get<dynamic>('/x'));
      failNext = false;
      await dio.get<dynamic>('/x'); // 成功 → 清零
      failNext = true;
      await swallow(() => dio.get<dynamic>('/x'));
      await swallow(() => dio.get<dynamic>('/x'));

      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.upgraded,
        reason: '成功清零后重新计数，两次失败不得触发降级',
      );
    });

    test('未配别名表时（skipped 态）失败不产生任何副作用', () async {
      final dio = createDio(baseUrl: 'https://a.example.com')
        ..httpClientAdapter = _ScriptedAdapter(() => _Failing.connection);

      for (var i = 0; i < 10; i++) {
        await swallow(() => dio.get<dynamic>('/x'));
      }
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.skipped);
      expect(EndpointGuard.instance.consecutiveFailures, 0);
    });
  });

  group('EndpointRewriteInterceptor', () {
    // 本组不测升降级，只测「基地址是否每次请求重读」。
    // 但 `EndpointHealthInterceptor`（createDio 自动挂）会在成功时调
    // `recordSuccess` → 触发重探，故必须把探测挡掉：空别名表 → 不碰网络。
    //
    // 放在**组级** setUp：它在外层 setUp（里面 `resetForTest` 会把注入项
    // 恢复成默认）之后、用例之前执行。
    setUp(() {
      EndpointGuard.instance.preferredOverride = const <String, String>{};
      EndpointGuard.instance.probe = (_, _, _) async => false;
    });

    /// 造一个已升级到 v6 的端点态。
    Future<void> setUpgraded() async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      await SpbEndpoints.resolveAndUpdate(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => true,
        timeout: const Duration(milliseconds: 5),
      );
    }

    /// 发一个请求并返回适配器看到的实际 URI。
    Future<String> requestUri(Dio dio) async {
      final adapter = _RecordingAdapter();
      dio.httpClientAdapter = adapter;
      await dio.get<dynamic>('/chat/groups');
      return adapter.lastUri.toString();
    }

    test('升级态下请求打到 preferred host', () async {
      await setUpgraded();
      final dio = createDio(
        baseUrl: SpbEnv.apiBaseUrl,
        interceptors: [
          EndpointRewriteInterceptor(
            resolveBaseUrl: () => SpbEndpoints.current.apiBaseUrl,
          ),
        ],
      );
      expect(await requestUri(dio), contains('v6.example.com'));
    });

    test('降级后**同一个 Dio 实例**的下一个请求就打到编译期地址', () async {
      // 这是本机制的核心契约：不重建 Dio（否则会打断 ChatStreamController
      // 持有的实例与页面里 `??=` 的订阅），只换请求前缀。
      await setUpgraded();
      final dio = createDio(
        baseUrl: SpbEnv.apiBaseUrl,
        interceptors: [
          EndpointRewriteInterceptor(
            resolveBaseUrl: () => SpbEndpoints.current.apiBaseUrl,
          ),
        ],
      );
      final adapter = _RecordingAdapter();
      dio.httpClientAdapter = adapter;

      await dio.get<dynamic>('/chat/groups');
      expect(adapter.lastUri.toString(), contains('v6.example.com'));

      SpbEndpoints.downgrade();

      await dio.get<dynamic>('/chat/groups');
      expect(
        adapter.lastUri.toString(),
        contains(Uri.parse(SpbEnv.apiBaseUrl).host),
        reason: '降级后无需通知任何人，下一个请求自然换 host',
      );
    });

    test('绝对 URL 不被重写（调用方明确指定了目标）', () async {
      await setUpgraded();
      final dio = createDio(
        baseUrl: SpbEnv.apiBaseUrl,
        interceptors: [
          EndpointRewriteInterceptor(
            resolveBaseUrl: () => SpbEndpoints.current.apiBaseUrl,
          ),
        ],
      );
      final adapter = _RecordingAdapter();
      dio.httpClientAdapter = adapter;
      await dio.get<dynamic>('https://elsewhere.test/x');
      expect(adapter.lastUri.toString(), 'https://elsewhere.test/x');
    });

    test('ufs 读 ufsBaseUrl（与 api 前缀不同）', () async {
      await setUpgraded();
      final dio = createDio(
        baseUrl: SpbEnv.ufsBaseUrl,
        interceptors: [
          EndpointRewriteInterceptor(
            resolveBaseUrl: () => SpbEndpoints.current.ufsBaseUrl,
          ),
        ],
      );
      final uri = await requestUri(dio);
      expect(uri, contains('v6.example.com'));
      expect(uri, contains('/ufs'), reason: 'ufs 路径前缀不能被丢掉');
    });
  });

  group('createDio 的拦截器顺序', () {
    test('端点健康拦截器在错误映射之前、在 AuthInterceptor 之后', () {
      final dio = createDio(
        baseUrl: 'https://a.example.com',
        interceptors: [AuthInterceptor(tokenProvider: () async => null)],
      );
      // dio 自己在链首插了一个 `ImplyContentTypeInterceptor`，故不能用绝对下标。
      final list = dio.interceptors;
      final authIdx = list.indexWhere((i) => i is AuthInterceptor);
      final healthIdx = list.indexWhere((i) => i is EndpointHealthInterceptor);

      expect(authIdx, greaterThanOrEqualTo(0));
      expect(
        healthIdx,
        greaterThan(authIdx),
        reason: 'AuthInterceptor 的 401→重放必须在前',
      );
      expect(
        healthIdx,
        lessThan(list.length - 1),
        reason: '健康拦截器若排在错误映射之后，reject 会跳过它 → 降级永不触发',
      );
    });

    test('未显式传拦截器时也挂上端点健康观测', () {
      final dio = createDio(baseUrl: 'https://a.example.com');
      expect(
        dio.interceptors.whereType<EndpointHealthInterceptor>(),
        hasLength(1),
      );
    });
  });
}

/// 记录实际请求 URI 的适配器（返回 200）。
class _RecordingAdapter implements HttpClientAdapter {
  Uri? lastUri;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastUri = options.uri;
    return ResponseBody.fromString(
      '{"items":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 脚本化失败形态。
enum _Failing { none, connection, http500 }

/// 按脚本抛 `DioException` 或返回 200 的适配器。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final _Failing Function() script;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    switch (script()) {
      case _Failing.none:
        return ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      case _Failing.connection:
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'simulated',
        );
      case _Failing.http500:
        return ResponseBody.fromString(
          '{"error":"boom"}',
          500,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
    }
  }

  @override
  void close({bool force = false}) {}
}
