import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `SessionManager` 的凭证获取与并发刷新去重测试。
///
/// ## 这个测试防的是什么
///
/// 页面初始化时多个请求并发发出。若每个请求各自发现 token 过期并各自刷新：
/// ① 产生 N 次刷新往返；② 若 IdP **轮换** refresh_token（用一次即作废），
/// 只有最后一个刷新能成功，其余拿到 `invalid_grant`，会话被**永久**打断——
/// 表现为「打开应用后随机要求重新登录」。
///
/// 故这里断言「N 个并发调用只触发 1 次刷新」，把去重钉成回归。
void main() {
  StoredTokens expired({String access = 'at_old', String? refresh = 'rt_1'}) =>
      StoredTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.utc(2020, 1, 1),
      );

  StoredTokens fresh({String access = 'at_new', String? refresh}) =>
      StoredTokens(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.utc(2999, 1, 1),
      );

  group('SessionManager 取可用凭证', () {
    test('无凭证时返回 null（不抛异常，让服务端 401 决定后续）', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(),
        refresher: (_) async => null,
      );
      expect(await m.currentAccessToken(), isNull);
    });

    test('未过期时直接返回，不触发刷新', () async {
      var refreshes = 0;
      final m = SessionManager(
        store: InMemoryTokenStore(fresh(access: 'at_ok')),
        refresher: (_) async {
          refreshes++;
          return null;
        },
      );

      expect(await m.currentAccessToken(), 'at_ok');
      expect(refreshes, 0, reason: '有效 token 不该触发刷新');
    });

    test('已过期时先刷新再返回新 token', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (current) async => fresh(access: 'at_refreshed'),
      );

      expect(await m.currentAccessToken(), 'at_refreshed');
    });

    test('已过期且无 refresh_token 时返回 null（需重新登录）', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired(refresh: null)),
        refresher: (_) async => fresh(),
      );
      expect(await m.currentAccessToken(), isNull);
    });

    test('过期余量（skew）内的 token 视为已过期并提前刷新', () async {
      // 距过期只剩 30 秒，小于默认 60 秒余量 → 应提前刷新，
      // 避免「请求发出瞬间刚好过期」。
      final m = SessionManager(
        store: InMemoryTokenStore(
          StoredTokens(
            accessToken: 'at_almost',
            refreshToken: 'rt_1',
            expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 30)),
          ),
        ),
        refresher: (_) async => fresh(access: 'at_pre'),
      );
      expect(await m.currentAccessToken(), 'at_pre');
    });

    test('无 expiresAt 时视为未过期（服务端未给信息，不猜）', () async {
      var refreshes = 0;
      final m = SessionManager(
        store: InMemoryTokenStore(
          const StoredTokens(accessToken: 'at_unknown', refreshToken: 'rt_1'),
        ),
        refresher: (_) async {
          refreshes++;
          return null;
        },
      );
      expect(await m.currentAccessToken(), 'at_unknown');
      expect(refreshes, 0);
    });
  });

  group('SessionManager 并发刷新去重', () {
    test('N 个并发 currentAccessToken 只触发 1 次刷新', () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (current) async {
          refreshes++;
          await gate.future; // 挂住，制造并发窗口
          return fresh(access: 'at_shared');
        },
      );

      final futures = List.generate(5, (_) => m.currentAccessToken());
      gate.complete();
      final results = await Future.wait(futures);

      expect(refreshes, 1, reason: '并发刷新必须合并成一次');
      expect(results, everyElement('at_shared'));
    });

    test('并发 refresh() 也只触发 1 次', () async {
      var refreshes = 0;
      final gate = Completer<void>();
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async {
          refreshes++;
          await gate.future;
          return fresh();
        },
      );

      final futures = List.generate(3, (_) => m.refresh());
      gate.complete();
      await Future.wait(futures);
      expect(refreshes, 1);
    });

    test('刷新完成后新的调用可再次刷新（去重窗口不粘住）', () async {
      var refreshes = 0;
      final store = InMemoryTokenStore(expired());
      final m = SessionManager(
        store: store,
        refresher: (_) async {
          refreshes++;
          return expired(access: 'at_$refreshes');
        },
      );

      await m.refresh();
      await m.refresh();
      expect(refreshes, 2, reason: '去重只作用于并发窗口内，不是永久缓存');
    });
  });

  group('SessionManager 刷新结果处理', () {
    test('刷新后写回存储', () async {
      final store = InMemoryTokenStore(expired());
      final m = SessionManager(
        store: store,
        refresher: (_) async => fresh(access: 'at_written', refresh: 'rt_2'),
      );

      await m.refresh();
      final persisted = await store.read();
      expect(persisted!.accessToken, 'at_written');
      expect(persisted.refreshToken, 'rt_2');
      expect(store.writeCount, 1);
    });

    test('新响应未带 refresh_token 时保留旧的（否则下次无法续期）', () async {
      // 多数 IdP 刷新时不重复下发 refresh_token；直接置 null 会让
      // 「第一次刷新成功、第二次再也刷不了」。
      final store = InMemoryTokenStore(expired(refresh: 'rt_original'));
      final m = SessionManager(
        store: store,
        refresher: (_) async => StoredTokens(
          accessToken: 'at_new',
          expiresAt: DateTime.utc(2999, 1, 1),
        ),
      );

      await m.refresh();
      final persisted = await store.read();
      expect(persisted!.refreshToken, 'rt_original');
      expect(persisted.canRefresh, isTrue);
    });

    test('刷新抛异常时返回 null 且保留旧凭证（不强制登出）', () async {
      // 一次网络抖动不该升级成「强制重新登录」。
      final store = InMemoryTokenStore(expired());
      final m = SessionManager(
        store: store,
        refresher: (_) async => throw const NetworkError('断网'),
      );

      expect(await m.refresh(), isNull);
      expect(await store.read(), isNotNull, reason: '旧凭证应保留');
      expect(store.clearCount, 0);
    });

    test('刷新返回 null 时不写存储', () async {
      final store = InMemoryTokenStore(expired());
      final m = SessionManager(store: store, refresher: (_) async => null);

      expect(await m.refresh(), isNull);
      expect(store.writeCount, 0);
    });

    test('logout 清除凭证', () async {
      final store = InMemoryTokenStore(fresh());
      final m = SessionManager(store: store, refresher: (_) async => null);

      await m.logout();
      expect(await store.read(), isNull);
      expect(store.clearCount, 1);
    });
  });

  group('AuthInterceptor 凭证注入', () {
    late Dio dio;
    late DioAdapter adapter;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: 'https://api.test/pba'));
      adapter = DioAdapter(dio: dio);
    });

    test('有 token 时注入 Authorization: Bearer', () async {
      String? auth;
      dio.interceptors.add(
        AuthInterceptor(
          tokenProvider: () async => 'at_123',
          onUnauthorized: null,
        ),
      );
      // 注意：拦截器按注册顺序执行 onRequest，故“抓取”必须注册在
      // AuthInterceptor **之后**（insert(0) 会跑到它前面，抓到 null）。
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            auth = o.headers['Authorization']?.toString();
            h.next(o);
          },
        ),
      );

      adapter.onGet('/x', (s) => s.reply(200, <String, dynamic>{}));
      await dio.get<dynamic>('/x');

      expect(auth, 'Bearer at_123');
    });

    test('token 为 null 时不注入 Authorization（匿名请求）', () async {
      var had = false;
      dio.interceptors.add(AuthInterceptor(tokenProvider: () async => null));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            had = o.headers.containsKey('Authorization');
            h.next(o);
          },
        ),
      );

      adapter.onGet('/x', (s) => s.reply(200, <String, dynamic>{}));
      await dio.get<dynamic>('/x');

      expect(had, isFalse);
    });

    test('tokenProvider 抛异常时请求仍发出（不静默消失）', () async {
      var called = false;
      dio.interceptors.add(
        AuthInterceptor(tokenProvider: () async => throw StateError('boom')),
      );

      adapter.onGet('/x', (s) => s.reply(200, <String, dynamic>{}));
      await dio.get<dynamic>('/x');
      called = true;

      expect(called, isTrue, reason: '取 token 失败应放行让服务端返回 401');
    });

    test('userHeaderOverride 注入 X-User-ID（仅开发态）', () async {
      String? uid;
      dio.interceptors.add(
        AuthInterceptor(
          tokenProvider: () async => null,
          userHeaderOverride: 'usr_dev',
        ),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            uid = o.headers['X-User-ID']?.toString();
            h.next(o);
          },
        ),
      );

      adapter.onGet('/x', (s) => s.reply(200, <String, dynamic>{}));
      await dio.get<dynamic>('/x');
      expect(uid, 'usr_dev');
    });
  });

  group('AuthInterceptor 401 → 刷新 → 重放', () {
    test('401 后刷新成功则重放原请求并返回成功响应', () async {
      // ## 这个测试防的是什么
      //
      // token 过期的正确行为是「静默续期后把用户原本的请求补上」，而不是让
      // 用户看到一次莫名的失败。若只做「刷新」不重放，用户会看到列表空白，
      // 得手动刷新页面。
      final scripted = _ScriptedAdapter();
      var refreshes = 0;
      var token = 'stale';
      final auth = AuthInterceptor(
        tokenProvider: () async => token,
        onUnauthorized: () async {
          refreshes++;
          token = 'fresh'; // 模拟刷新后存储里已是新值
          return true;
        },
      );
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = scripted;
      auth.replayDio = client;

      final res = await client.get<dynamic>('/x');

      expect(res.statusCode, 200);
      expect(scripted.calls, 2, reason: '原请求 + 一次重放');
      expect(refreshes, 1, reason: '只刷新一次');
      expect(scripted.seenAuth, [
        'Bearer stale',
        'Bearer fresh',
      ], reason: '重放必须带上刷新后的 token，而不是旧的');
    });

    test('刷新失败时归一化为 AuthError（不重放）', () async {
      final scripted = _ScriptedAdapter();
      final auth = AuthInterceptor(
        tokenProvider: () async => 'stale',
        onUnauthorized: () async => false,
      );
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = scripted;
      auth.replayDio = client;

      try {
        await client.get<dynamic>('/x');
        fail('应当抛出 DioException');
      } on DioException catch (e) {
        expect(e.error, isA<AuthError>());
        expect((e.error! as AuthError).isUnauthorized, isTrue);
        expect(scripted.calls, 1, reason: '刷新失败不应重放');
      }
    });

    test('未配置 onUnauthorized 时 401 直接归一化为 AuthError', () async {
      final scripted = _ScriptedAdapter();
      final auth = AuthInterceptor(tokenProvider: () async => 'stale');
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = scripted;

      try {
        await client.get<dynamic>('/x');
        fail('应当抛出 DioException');
      } on DioException catch (e) {
        expect(e.error, isA<AuthError>());
        expect(scripted.calls, 1);
      }
    });

    test('刷新后仍 401 时不无限重放（只重放一次）', () async {
      // 若服务端因其他原因持续 401（如账号被禁），无限制重放会变成死循环。
      final always401 = _Always401Adapter();
      var refreshes = 0;
      final auth = AuthInterceptor(
        tokenProvider: () async => 't',
        onUnauthorized: () async {
          refreshes++;
          return true;
        },
      );
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = always401;
      auth.replayDio = client;

      try {
        await client.get<dynamic>('/x');
        fail('应当抛出 DioException');
      } on DioException catch (e) {
        expect(e.error, isA<AuthError>());
      }
      expect(refreshes, 1, reason: '只允许刷新一次，避免无限循环');
      expect(always401.calls, 2, reason: '原请求 + 一次重放');
    });
  });
}

/// 确定性适配器：第 1 次 401，之后 200（用于验证「重放」真的发生）。
class _ScriptedAdapter implements HttpClientAdapter {
  final List<String?> seenAuth = [];
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    seenAuth.add(options.headers['Authorization']?.toString());
    if (calls == 1) {
      return ResponseBody.fromString(
        '{"error":"unauthorized"}',
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 永远 401（用于验证重放次数上限）。
class _Always401Adapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{"error":"unauthorized"}',
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
