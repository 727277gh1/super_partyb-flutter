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

  group('StoredTokens.fromOidcTokens（落盘凭证的取值口径）', () {
    test('落盘的是 id_token，不是 fosite 的 ory_at_… 不透明串', () {
      // 回归防线（真实缺陷：Windows 客户端登录后立刻提示「会话已失效」）。
      //
      // 两端 `providers.dart` 曾各自手写映射为 `accessToken: tokens.accessToken`，
      // 于是把 IdP 的不透明 access_token 当 Bearer 发给 api-gateway。网关只验
      // RS256 JWT（`pkg/auth/jwt_authenticate.go` 的 JWKS 验签 + go-oidc 的
      // compact JWS），对 `ory_at_…` 报「token contains an invalid number of
      // segments」，于是登录刚成功就 401 → 判定会话失效 → 踢回登录页。
      final tokens = OidcTokens.fromJson({
        'access_token': 'ory_at_2Xk9opaque',
        'id_token': 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c3JfMSJ9.sig',
        'refresh_token': 'ory_rt_abc',
        'expires_in': 3600,
        'token_type': 'Bearer',
        'scope': 'openid profile email',
      });

      final stored = StoredTokens.fromOidcTokens(
        tokens,
        now: () => DateTime.utc(2026, 1, 1),
      );

      expect(
        stored.accessToken,
        tokens.idToken,
        reason: '必须是 id_token；换成 ory_at_… 会让网关 401',
      );
      expect(stored.accessToken, isNot(startsWith('ory_at_')));
      expect(stored.refreshToken, 'ory_rt_abc');
      expect(
        stored.expiresAt,
        DateTime.utc(2026, 1, 1).add(const Duration(seconds: 3600)),
        reason: 'expires_in 必须换算成绝对时刻（重启后才有意义）',
      );
      expect(stored.tokenType, 'Bearer');
      expect(stored.scope, 'openid profile email');
    });

    test('服务端未给 expires_in 时 expiresAt 为 null（不猜）', () {
      final stored = StoredTokens.fromOidcTokens(
        OidcTokens.fromJson({'access_token': 'at', 'id_token': 'a.b.c'}),
      );
      expect(stored.expiresAt, isNull);
      expect(
        stored.isExpired(now: DateTime.utc(2999, 1, 1)),
        isFalse,
        reason: '无 expiresAt 时不应判定过期',
      );
    });
  });

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

  group('刷新失败的三态分类（「放置一段时间后被登出」的回归防线）', () {
    // ## 这个 group 防的是什么
    //
    // 2026-10 用户报障：应用放置一段时间后弹「会话已失效」并跳登录页，但
    // **关闭重开就正常**。根因是一条把「网络抖动」当成「凭证失效」的判定链：
    //
    // ```
    // currentAccessToken → 刷新失败（其实是休眠唤醒后的断网）→ 返回 null
    //   → 请求不带 Authorization → 401 → 又刷一次 → 又失败
    //   → onSessionExpired → 回登录页
    // ```
    //
    // 而 refresh_token 完好（所以重启就好了）。下面逐条钉住分类边界。

    Future<TokenRefreshStatus> classify(Object error) async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async => throw error,
      );
      return (await m.refreshWithOutcome()).status;
    }

    test('NetworkError → transient（断网不能把人登出）', () async {
      expect(
        await classify(const NetworkError('断网')),
        TokenRefreshStatus.transient,
      );
    });

    test('HttpError(503) → transient（IdP 自己挂了）', () async {
      expect(
        await classify(const HttpError(503, 'HTTP 503')),
        TokenRefreshStatus.transient,
      );
    });

    test('HttpError(400) → rejected（请求被拒，重试无用）', () async {
      expect(
        await classify(const HttpError(400, 'HTTP 400')),
        TokenRefreshStatus.rejected,
      );
    });

    test('AuthError(cause: HttpError(500)) → transient', () async {
      // ⚠️ 这是**真实链路**的形态：`OidcClient._tokenRequest` 对任何非 2xx 都抛
      // `AuthError(message, cause: HttpError(status))`。只看最外层类型会把
      // 「IdP 回了 503」也当成「凭证作废」——同一缺陷的另一条路径。
      expect(
        await classify(
          const AuthError('token 端点失败', cause: HttpError(503, 'HTTP 503')),
        ),
        TokenRefreshStatus.transient,
      );
    });

    test('AuthError(cause: HttpError(400)) → rejected', () async {
      // invalid_grant / invalid_client 的真实形态。
      expect(
        await classify(
          const AuthError('invalid_grant', cause: HttpError(400, 'HTTP 400')),
        ),
        TokenRefreshStatus.rejected,
      );
    });

    test('AuthError 无 cause → rejected（登录流程本身的拒绝）', () async {
      expect(
        await classify(const AuthError('state 不匹配')),
        TokenRefreshStatus.rejected,
      );
    });

    test('ParseError → transient（契约漂移不该把人登出）', () async {
      expect(
        await classify(const ParseError('响应不是 JSON')),
        TokenRefreshStatus.transient,
      );
    });

    test('非 SpbError 的异常 → transient（无法归因时保守）', () async {
      expect(await classify(StateError('boom')), TokenRefreshStatus.transient);
    });

    test('刷新实现返回 null → rejected（它明确表示无可用结果）', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async => null,
      );
      expect(
        (await m.refreshWithOutcome()).status,
        TokenRefreshStatus.rejected,
      );
    });

    test('本地无 refresh_token → rejected（确定的无法续期）', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired(refresh: null)),
        refresher: (_) async => fresh(),
      );
      expect(
        (await m.refreshWithOutcome()).status,
        TokenRefreshStatus.rejected,
      );
    });

    test('刷新成功 → refreshed 且带新凭证', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async => fresh(access: 'at_ok'),
      );
      final outcome = await m.refreshWithOutcome();
      expect(outcome.status, TokenRefreshStatus.refreshed);
      expect(outcome.tokens!.accessToken, 'at_ok');
    });

    test('并发调用只刷新一次（refreshWithOutcome 同样去重）', () async {
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

      final futures = List.generate(3, (_) => m.refreshWithOutcome());
      gate.complete();
      await Future.wait(futures);
      expect(refreshes, 1);
    });
  });

  group('currentAccessToken 在刷新失败时的取信策略', () {
    test('暂时性失败时返回**旧** token（交给服务端判定，而非匿名请求）', () async {
      // ## 这是整个修复的核心
      //
      // 返回 null 会让 `AuthInterceptor` 发出**匿名**请求（连 Authorization 头
      // 都不带）——那必然 401，而那个 401 又被当成「会话失效」把人登出。
      // 旧 token 可能仍被服务端接受（时钟偏移 / 服务端宽限），就算不接受，
      // 也让服务端而不是客户端来做这个判断。
      final m = SessionManager(
        store: InMemoryTokenStore(expired(access: 'at_stale')),
        refresher: (_) async => throw const NetworkError('断网'),
      );

      expect(
        await m.currentAccessToken(),
        'at_stale',
        reason: '断网时不能降级成匿名请求——那必然 401 并导致误登出',
      );
    });

    test('明确被拒时返回 null（确实需要重新登录）', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async =>
            throw const AuthError('invalid_grant', cause: HttpError(400, 'x')),
      );

      expect(await m.currentAccessToken(), isNull);
    });

    test('刷新成功时返回新 token', () async {
      final m = SessionManager(
        store: InMemoryTokenStore(expired()),
        refresher: (_) async => fresh(access: 'at_new'),
      );

      expect(await m.currentAccessToken(), 'at_new');
    });

    test('未过期时直接用缓存的 token（不触发刷新）', () async {
      var refreshes = 0;
      final m = SessionManager(
        store: InMemoryTokenStore(fresh(access: 'at_cached')),
        refresher: (_) async {
          refreshes++;
          return fresh();
        },
      );

      expect(await m.currentAccessToken(), 'at_cached');
      expect(refreshes, 0);
    });

    test('临时失败后旧凭证仍在存储里（不 clear）', () async {
      final store = InMemoryTokenStore(expired());
      final m = SessionManager(
        store: store,
        refresher: (_) async => throw const NetworkError('断网'),
      );

      await m.currentAccessToken();
      expect(await store.read(), isNotNull);
      expect(store.clearCount, 0);
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

  group('AuthInterceptor onSessionExpired（会话失效 → 回登录页的触发点）', () {
    // ## 这个 group 防的是什么
    //
    // 修复前，401 只被归一化成 `AuthError` 抛给调用方，而各页面拿到它只翻成
    // 一句 SnackBar 文案，**没有任何一处**把认证状态推进到未登录。于是会话
    // 真的过期后用户卡在当前页，只能手动进设置页点「退出登录」。
    //
    // 这三条分别钉住「该触发时触发」「不该触发时绝不触发」两个相反方向
    // ——后者同样重要：误触发会把人从正常的无权限操作里踢出登录。

    test('401 且刷新失败 → 回调被调用一次', () async {
      final scripted = _Always401Adapter();
      final messages = <String>[];
      final auth = AuthInterceptor(
        tokenProvider: () async => 'stale',
        onUnauthorized: () async => false,
        onSessionExpired: messages.add,
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
      }

      expect(messages, ['会话已失效，请重新登录']);
    });

    test('刷新成功且重放成功 → 回调不触发（静默续期，不该踢人）', () async {
      final scripted = _ScriptedAdapter();
      var expired = 0;
      var token = 'stale';
      final auth = AuthInterceptor(
        tokenProvider: () async => token,
        onUnauthorized: () async {
          token = 'fresh';
          return true;
        },
        onSessionExpired: (_) => expired++,
      );
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = scripted;
      auth.replayDio = client;

      final res = await client.get<dynamic>('/x');

      expect(res.statusCode, 200);
      expect(expired, 0, reason: '续期成功就不该让用户重新登录');
    });

    test('403 → 回调绝不触发（已认证但无权限，不是会话失效）', () async {
      // 若 403 也当登出，用户「点了一个没权限的按钮」就会被直接踢出登录。
      final forbidden = _StatusAdapter(403);
      var expired = 0;
      final auth = AuthInterceptor(
        tokenProvider: () async => 't',
        onUnauthorized: () async => true,
        onSessionExpired: (_) => expired++,
      );
      final client = createDio(
        baseUrl: 'https://api.test/pba',
        interceptors: [auth],
      );
      client.httpClientAdapter = forbidden;
      auth.replayDio = client;

      try {
        await client.get<dynamic>('/x');
        fail('403 应抛出');
      } on DioException catch (e) {
        expect(e.error, isA<AuthError>());
        expect((e.error! as AuthError).isForbidden, isTrue);
      }

      expect(expired, 0, reason: '403 不是会话失效');
    });

    test('刷新成功但重放仍 401 → 回调触发（新凭证也被拒）', () async {
      // 账号被禁 / 会话被服务端撤销：刷新能拿到新 token，但它同样无效。
      // 这条路径不触发的话，用户会停在旧页面上而没有任何提示。
      final always401 = _Always401Adapter();
      final messages = <String>[];
      final auth = AuthInterceptor(
        tokenProvider: () async => 't',
        onUnauthorized: () async => true,
        onSessionExpired: messages.add,
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

      expect(messages, hasLength(1), reason: '只通知一次，不随重放次数叠加');
    });

    test('未配置回调时行为不变（不崩、仍抛 AuthError）', () async {
      final scripted = _Always401Adapter();
      final auth = AuthInterceptor(
        tokenProvider: () async => 't',
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
      }
    });
  });

  group('AuthInterceptor：刷新暂时性失败时**不得**登出', () {
    // ## 这个 group 防的是什么
    //
    // `onSessionExpired` 是「回登录页」的唯一触发点。一旦它把网络抖动也当成
    // 会话失效，用户就会「放置一段时间后被踢出去，而关闭重开又正常」。
    //
    // 两条用例分别钉住相反方向：transient 不能登出（否则复发）、
    // rejected 必须登出（否则真失效时用户卡在页面上）。

    test('401 且刷新为 transient → 不调 onSessionExpired、不重放', () async {
      final scripted = _Always401Adapter();
      final messages = <String>[];
      var refreshes = 0;
      final auth = AuthInterceptor(
        tokenProvider: () async => 'stale',
        onUnauthorizedOutcome: () async {
          refreshes++;
          return const TokenRefreshOutcome.transient(error: NetworkError('断网'));
        },
        onSessionExpired: messages.add,
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
        // 仍归一化为 AuthError（上层能识别这是凭证问题），但不触发登出。
        expect(e.error, isA<AuthError>());
      }

      expect(messages, isEmpty, reason: '断网不是会话失效，不能把人踢回登录页');
      expect(refreshes, 1, reason: '只尝试刷新一次');
      expect(scripted.calls, 1, reason: '暂时性失败不重放（重放也必然失败）');
    });

    test('401 且刷新为 rejected → 调 onSessionExpired 一次', () async {
      final scripted = _Always401Adapter();
      final messages = <String>[];
      final auth = AuthInterceptor(
        tokenProvider: () async => 'stale',
        onUnauthorizedOutcome: () async => const TokenRefreshOutcome.rejected(
          error: AuthError('invalid_grant'),
        ),
        onSessionExpired: messages.add,
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
      }

      expect(messages, ['会话已失效，请重新登录']);
    });

    test('onUnauthorizedOutcome 刷新成功 → 重放并带新 token', () async {
      final scripted = _ScriptedAdapter();
      var token = 'stale';
      final auth = AuthInterceptor(
        tokenProvider: () async => token,
        onUnauthorizedOutcome: () async {
          token = 'fresh';
          return TokenRefreshOutcome.refreshed(
            StoredTokens(
              accessToken: 'fresh',
              expiresAt: DateTime.utc(2999, 1, 1),
            ),
          );
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
      expect(scripted.calls, 2);
      expect(scripted.seenAuth, ['Bearer stale', 'Bearer fresh']);
    });

    test('onUnauthorizedOutcome 优先级高于旧的布尔回调', () async {
      // 两个都配时只认新的——否则升级到一半的接线会拿到错的三态。
      final scripted = _Always401Adapter();
      final messages = <String>[];
      var legacyCalled = 0;
      final auth = AuthInterceptor(
        tokenProvider: () async => 'stale',
        onUnauthorized: () async {
          legacyCalled++;
          return true;
        },
        onUnauthorizedOutcome: () async =>
            const TokenRefreshOutcome.transient(error: NetworkError('断网')),
        onSessionExpired: messages.add,
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
      } on DioException {
        // 预期
      }

      expect(legacyCalled, 0, reason: '新回调优先，旧回调不应被调用');
      expect(messages, isEmpty);
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

/// 固定状态码的适配器（用于验证 403 之类的分支）。
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);

  final int status;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{"error":"x"}',
      status,
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
