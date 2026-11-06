import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 小程序登录 API 客户端的契约测试。
///
/// ## 这个测试防的是什么
///
/// 这些错误都是**静默的**：
/// - 端点路径拼错（漏 basePath、多一个斜杠）→ 404，用户只看到「登录失败」；
/// - 兑换时 `redirect_uri` 与 client 注册值不一致 → IdP 400，扫码白扫；
/// - 把轮询返回的 `token` 当授权码用 → 拿不到 refresh，一小时后被踢；
/// - 服务端错误码没映射 → 用户看到 `DioException [bad response]`。
///
/// 所以这里断言的是**发出的请求长什么样**与**错误怎么翻译**，而不只是能跑通。
void main() {
  const issuer = 'https://app.example.com/idp';
  const redirectUri = 'partyb://oidc/callback';
  const clientId = 'client_45f10bfb-0170-4815-b';

  late Dio dio;
  late DioAdapter adapter;
  late MiniProgramLoginClient client;

  setUp(() {
    dio = Dio(BaseOptions(responseType: ResponseType.json));
    adapter = DioAdapter(dio: dio);
    client = MiniProgramLoginClient(
      issuer: Uri.parse(issuer),
      clientId: clientId,
      redirectUri: redirectUri,
      dio: dio,
    );
  });

  group('端点推导', () {
    test('从 issuer 推导，保留 basePath（/idp 前缀不能丢）', () {
      expect(
        client.endpointBase.toString(),
        'https://app.example.com/idp/api/v1/bindings/mini-program',
      );
    });

    test('issuer 结尾带斜杠时不产生双斜杠', () {
      final c = MiniProgramLoginClient(
        issuer: Uri.parse('https://app.example.com/idp/'),
        clientId: clientId,
        redirectUri: redirectUri,
      );
      expect(
        c.endpointBase.toString(),
        'https://app.example.com/idp/api/v1/bindings/mini-program',
      );
    });

    test('双栈/本地 issuer 同样推导（不硬编码域名）', () {
      final c = MiniProgramLoginClient(
        issuer: Uri.parse('http://127.0.0.1:3000/idp'),
        clientId: clientId,
        redirectUri: redirectUri,
      );
      expect(
        c.endpointBase.toString(),
        'http://127.0.0.1:3000/idp/api/v1/bindings/mini-program',
      );
    });
  });

  group('createSession', () {
    test('默认带 ?scheme=1（App 内要能直接唤起微信）', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?scheme=1',
        (server) => server.reply(200, {
          'success': true,
          'scene': 'abc123',
          'qrCodeUrl': 'data:image/png;base64,AAA',
          'schemeUrl': 'weixin://dl/business/?t=xyz',
          'expiresAt': '2026-11-06T12:00:00Z',
        }),
      );

      final session = await client.createSession();
      expect(session.scene, 'abc123');
      expect(session.canLaunchWeChat, isTrue);
      expect(session.schemeUrl, 'weixin://dl/business/?t=xyz');
      expect(session.expiresAt, isNotNull);
    });

    test('scheme 生成失败时带出 schemeError，且 canLaunchWeChat=false', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?scheme=1',
        (server) => server.reply(200, {
          'success': true,
          'scene': 'abc123',
          'qrCodeUrl': 'data:image/png;base64,AAA',
          'schemeError': '暂时无法直接唤起微信，请改用其他登录方式',
        }),
      );

      final session = await client.createSession();
      expect(session.canLaunchWeChat, isFalse);
      expect(session.schemeError, contains('无法直接唤起微信'));
    });

    test('withScheme=false 时不请求 scheme（省微信 API 配额）', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session',
        (server) => server.reply(200, {
          'success': true,
          'scene': 'abc123',
          'qrCodeUrl': 'data:image/png;base64,AAA',
        }),
      );

      final session = await client.createSession(withScheme: false);
      expect(session.scene, 'abc123');
      expect(session.canLaunchWeChat, isFalse);
    });

    test('POST 必须带 Content-Type（网关对无 Content-Type 的 POST 直接 400）', () async {
      // 回归：实测线上 `POST .../qrcode-session` 不带 Content-Type 时，
      // 网关返回 400 `Content-Type header is required for POST requests`，
      // 前端只能看到「小程序登录失败」，很难追到网关头上。
      String? contentType;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            contentType = options.headers['Content-Type']?.toString();
            handler.next(options);
          },
        ),
      );
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?scheme=1',
        (server) => server.reply(200, {
          'scene': 'abc123',
          'qrCodeUrl': 'data:image/png;base64,AAA',
        }),
      );

      await client.createSession();
      expect(contentType, contains('application/json'));
    });

    test('响应不含 qrCodeUrl（App 路径）时仍可创建会话并唤起', () async {
      // 服务端对 ?scheme=1 不再生成小程序码（同机扫不了自己的屏幕，且小程序码
      // 的账号权限不该连坐 App 登录），所以 App 路径的响应里**没有** qrCodeUrl。
      // 客户端不能因此把它当成「响应不完整」。
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?scheme=1',
        (server) => server.reply(200, {
          'success': true,
          'scene': 'abc123',
          'expiresAt': '2026-11-06T13:20:00Z',
          'schemeUrl': 'weixin://dl/business/?t=xyz',
        }),
      );

      final session = await client.createSession();
      expect(session.scene, 'abc123');
      expect(session.qrCodeUrl, isEmpty);
      expect(session.canLaunchWeChat, isTrue);
    });

    test('响应缺 scene 时抛 AuthError 而不是空指针', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?scheme=1',
        (server) => server.reply(200, {'success': true}),
      );

      expect(
        () => client.createSession(),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('scene'),
          ),
        ),
      );
    });
  });

  group('createShortCodeSession', () {
    test('请求 ?code=1 并解析 displayCode/剩余秒数', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?code=1',
        (server) => server.reply(200, {
          'success': true,
          'scene': 'A3F9K2',
          'userCode': 'A3F9K2',
          'displayCode': 'A3F-9K2',
          'expiresInSeconds': 300,
          'expiresAt': '2026-11-06T12:00:00Z',
        }),
      );

      final session = await client.createShortCodeSession();
      expect(session.scene, 'A3F9K2');
      expect(session.isShortCode, isTrue);
      expect(session.shortCode!.displayCode, 'A3F-9K2');
      expect(session.shortCode!.ttl, const Duration(seconds: 300));
      // 短码路径不产出小程序码：留空而不是占位串，避免 UI 误当成可展示的图
      expect(session.qrCodeUrl, isEmpty);
      expect(session.canLaunchWeChat, isFalse);
    });

    test('displayCode 缺失时退回 userCode，再退回 scene（不展示空码）', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?code=1',
        (server) => server.reply(200, {'success': true, 'scene': 'A3F9K2'}),
      );

      final session = await client.createShortCodeSession();
      expect(session.shortCode!.displayCode, 'A3F9K2');
      // 服务端没给 TTL 时按 5 分钟兜底：宁可早一点提示过期，也不要显示负数
      expect(session.shortCode!.expiresInSeconds, 300);
    });

    test('缺 scene 视为失败（不能拿空串去轮询/兑换）', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?code=1',
        (server) => server.reply(200, {'success': true}),
      );

      await expectLater(
        client.createShortCodeSession(),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('登录码创建失败'),
          ),
        ),
      );
    });

    test('限流 429 翻译成「稍后再试」（而不是 DioException 原文）', () async {
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/qrcode-session?code=1',
        (server) => server.reply(429, {
          'success': false,
          'error': 'rate_limited',
          'message': '尝试次数过多，请稍后再试',
        }),
      );

      await expectLater(
        client.createShortCodeSession(),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('尝试次数过多'),
          ),
        ),
      );
    });
  });

  group('poll', () {
    test('bound=true → done', () async {
      adapter.onGet(
        '$issuer/api/v1/bindings/mini-program/check/abc123',
        (server) => server.reply(200, {
          'success': true,
          'bound': true,
          'expired': false,
          'tokens': {'accessToken': 'at', 'expiresIn': 900},
        }),
      );
      expect(await client.poll('abc123'), MiniProgramPollState.done);
    });

    test('expired=true → expired', () async {
      adapter.onGet(
        '$issuer/api/v1/bindings/mini-program/check/abc123',
        (server) => server.reply(200, {
          'success': true,
          'bound': false,
          'expired': true,
        }),
      );
      expect(await client.poll('abc123'), MiniProgramPollState.expired);
    });

    test('都没置位 → pending', () async {
      adapter.onGet(
        '$issuer/api/v1/bindings/mini-program/check/abc123',
        (server) => server.reply(200, {
          'success': true,
          'bound': false,
          'expired': false,
        }),
      );
      expect(await client.poll('abc123'), MiniProgramPollState.pending);
    });
  });

  group('redeemHandoffCode（反向登录码）', () {
    test('请求 /handoff/redeem，字段名与正向 exchange 一致，取出授权码', () async {
      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/handoff/redeem',
        (server) => server.reply(200, {
          'success': true,
          'code': 'ory_ac_handoff',
          'state': 'st',
        }),
        data: {
          // 服务端复用正向 exchange 的请求结构：`scene` 语义上是「用户输的码」。
          'scene': 'AB2C-3D4E',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': 'st',
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      );

      final code = await client.redeemHandoffCode(
        code: 'AB2C-3D4E',
        pkce: pkce,
        state: 'st',
      );
      expect(code, 'ory_ac_handoff');
    });

    test('缺 code 时抛 AuthError（而不是把 null 当授权码交给下游）', () async {
      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/handoff/redeem',
        (server) => server.reply(200, {'success': true}),
        data: {
          'scene': 'AB2C-3D4E',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': 'st',
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      );

      await expectLater(
        client.redeemHandoffCode(code: 'AB2C-3D4E', pkce: pkce, state: 'st'),
        throwsA(isA<AuthError>()),
      );
    });

    // 反向码的错误语义与正向**不同**：码是持有即授权的凭据，「无效」的出路是
    // 「核对」或「回小程序重新出码」，不是「重新发起 App 侧会话」。
    for (final c in const [
      ('not_found', '核对'),
      ('expired', '重新生成'),
      ('too_many_attempts', '作废'),
      ('rate_limited', '稍后再试'),
      ('bad_request', '参数'),
    ]) {
      test('服务端 ${c.$1} → 可读原因（含「${c.$2}」）', () async {
        final pkce = OidcPkce.generatePair();
        adapter.onPost(
          '$issuer/api/v1/bindings/mini-program/handoff/redeem',
          (server) => server.reply(400, {'success': false, 'error': c.$1}),
          data: {
            'scene': 'AB2C-3D4E',
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'state': 'st',
            'code_challenge': pkce.challenge,
            'code_challenge_method': 'S256',
          },
        );

        await expectLater(
          client.redeemHandoffCode(code: 'AB2C-3D4E', pkce: pkce, state: 'st'),
          throwsA(
            isA<AuthError>().having(
              (e) => e.message,
              'message',
              contains(c.$2),
            ),
          ),
        );
      });
    }
  });

  group('exchange', () {
    test('提交 scene/client_id/redirect_uri/state/PKCE，并取出 code', () async {
      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/exchange',
        (server) => server.reply(200, {
          'success': true,
          'code': 'ory_ac_x',
          'state': 'st',
        }),
        data: {
          'scene': 'abc123',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': 'st',
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      );

      final code = await client.exchange(
        scene: 'abc123',
        pkce: pkce,
        state: 'st',
      );
      expect(code, 'ory_ac_x');
    });

    for (final c in const [
      ('scene_pending', '还没确认'),
      ('scene_expired', '已过期'),
      ('scene_not_found', '已失效'),
      ('invalid_request', '参数校验失败'),
      ('unavailable', '未启用'),
    ]) {
      test('服务端 ${c.$1} → 可读原因（含「${c.$2}」）', () async {
        final pkce = OidcPkce.generatePair();
        adapter.onPost(
          '$issuer/api/v1/bindings/mini-program/exchange',
          (server) => server.reply(409, {'success': false, 'error': c.$1}),
          data: {
            'scene': 'abc123',
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'state': 'st',
            'code_challenge': pkce.challenge,
            'code_challenge_method': 'S256',
          },
        );

        await expectLater(
          client.exchange(scene: 'abc123', pkce: pkce, state: 'st'),
          throwsA(
            isA<AuthError>().having(
              (e) => e.message,
              'message',
              contains(c.$2),
            ),
          ),
        );
      });
    }

    test('网络不通时提示检查网络（而不是 DioException 原文）', () async {
      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        '$issuer/api/v1/bindings/mini-program/exchange',
        (server) => server.throws(
          0,
          DioException(
            requestOptions: RequestOptions(path: '/'),
            type: DioExceptionType.connectionError,
            message: 'connection refused',
          ),
        ),
        data: {
          'scene': 'abc123',
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'state': 'st',
          'code_challenge': pkce.challenge,
          'code_challenge_method': 'S256',
        },
      );

      await expectLater(
        client.exchange(scene: 'abc123', pkce: pkce, state: 'st'),
        throwsA(
          isA<AuthError>().having((e) => e.message, 'message', contains('网络')),
        ),
      );
    });
  });
}
