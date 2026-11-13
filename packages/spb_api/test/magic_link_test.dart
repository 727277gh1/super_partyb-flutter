import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 邮箱 magic link 客户端的契约测试。
///
/// ## 这个测试防的是什么
///
/// 这些错误都是**静默的**：
/// - 端点路径拼错（漏 basePath）→ 404，用户只看到「登录失败」；
/// - 兑换时 `redirect_uri` 与 client 注册值不一致 → IdP 400，邮件白点；
/// - 把轮询的 `pending` 当成成功 → 兑换必然 409，用户卡在等待态；
/// - 服务端错误码没映射 → 用户看到 `DioException [bad response]`。
///
/// 所以断言的是**发出的请求长什么样**与**错误怎么翻译**，而不只是能跑通。
void main() {
  const issuer = 'https://dever.atjog.com/idp';
  const base = '$issuer/api/v1/auth/magic-link';
  const redirectUri = 'partyb://oidc/callback';
  const clientId = 'client_45f10bfb-0170-4815-b';

  late Dio dio;
  late DioAdapter adapter;
  late MagicLinkClient client;

  setUp(() {
    dio = Dio(BaseOptions(responseType: ResponseType.json));
    adapter = DioAdapter(dio: dio);
    client = MagicLinkClient(
      issuer: Uri.parse(issuer),
      clientId: clientId,
      redirectUri: redirectUri,
      dio: dio,
    );
  });

  group('端点推导', () {
    test('从 issuer 推导，保留 basePath（/idp 前缀不能丢）', () {
      expect(client.endpointBase.toString(), base);
    });

    test('issuer 结尾带斜杠时不产生双斜杠', () {
      final c = MagicLinkClient(
        issuer: Uri.parse('https://dever.atjog.com/idp/'),
        clientId: clientId,
        redirectUri: redirectUri,
      );
      expect(c.endpointBase.toString(), base);
    });

    test('双栈/本地 issuer 同样推导（不硬编码域名）', () {
      final c = MagicLinkClient(
        issuer: Uri.parse('http://127.0.0.1:3000/idp'),
        clientId: clientId,
        redirectUri: redirectUri,
      );
      expect(
        c.endpointBase.toString(),
        'http://127.0.0.1:3000/idp/api/v1/auth/magic-link',
      );
    });
  });

  group('request（受理并发信）', () {
    test('提交邮箱并取回 requestId / expiresAt', () async {
      adapter.onPost(
        base,
        (server) => server.reply(202, {
          'status': 'accepted',
          'requestId': 'req-1',
          'expiresAt': '2026-11-06T12:10:00Z',
          'message': '如果该邮箱已注册，登录链接将在几分钟内送达',
        }),
        data: {'email': 'user@example.com'},
      );

      final req = await client.request('user@example.com');
      expect(req.requestId, 'req-1');
      expect(req.expiresAt, isNotNull);
    });

    test('POST 必须带 Content-Type（网关对无 Content-Type 的 POST 直接 400）', () async {
      // 与小程序 qrcode-session 同一条网关规则，漏了会 400 且原因在网关侧。
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
        base,
        (server) => server.reply(202, {'requestId': 'req-1'}),
        data: Matchers.any,
      );

      await client.request('user@example.com');
      expect(contentType, contains('application/json'));
    });

    test('邮箱不存在时同样返回 requestId（防枚举，客户端不据此判断）', () async {
      adapter.onPost(
        base,
        (server) =>
            server.reply(202, {'status': 'accepted', 'requestId': 'req-ghost'}),
        data: Matchers.any,
      );
      final req = await client.request('ghost@example.com');
      expect(req.requestId, 'req-ghost');
    });

    test('响应缺 requestId 时抛 AuthError 而不是空指针', () async {
      adapter.onPost(
        base,
        (server) => server.reply(202, {'status': 'accepted'}),
        data: Matchers.any,
      );
      expect(
        () => client.request('user@example.com'),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('requestId'),
          ),
        ),
      );
    });

    test('限频（409 conflict）透传服务端文案', () async {
      adapter.onPost(
        base,
        (server) => server.reply(409, {
          'error': 'conflict',
          'message': '登录邮件发送过于频繁，请稍后再试',
        }),
        data: Matchers.any,
      );
      expect(
        () => client.request('user@example.com'),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('过于频繁'),
          ),
        ),
      );
    });

    test('邮箱格式无效（validation_error）透传服务端文案', () async {
      adapter.onPost(
        base,
        (server) => server.reply(400, {
          'error': 'validation_error',
          'message': '邮箱格式无效',
        }),
        data: Matchers.any,
      );
      expect(
        () => client.request('not-an-email'),
        throwsA(isA<AuthError>().having((e) => e.message, 'message', '邮箱格式无效')),
      );
    });

    test('邮件渠道不可用 → 可读的服务端不可用文案', () async {
      adapter.onPost(
        base,
        (server) => server.reply(503, {
          'error': 'service_unavailable',
          'message': '登录邮件暂时无法发送，请稍后重试',
        }),
        data: Matchers.any,
      );
      expect(
        () => client.request('user@example.com'),
        throwsA(
          isA<AuthError>().having((e) => e.message, 'message', contains('邮件')),
        ),
      );
    });
  });

  group('poll（只回答确认状态，不带凭证）', () {
    test('confirmed → confirmed', () async {
      adapter.onGet(
        '$base/check?request_id=req-1',
        (server) => server.reply(200, {'status': 'confirmed'}),
      );
      expect(await client.poll('req-1'), MagicLinkPollState.confirmed);
    });

    test('pending → pending', () async {
      adapter.onGet(
        '$base/check?request_id=req-1',
        (server) => server.reply(200, {'status': 'pending'}),
      );
      expect(await client.poll('req-1'), MagicLinkPollState.pending);
    });

    test('expired → expired', () async {
      adapter.onGet(
        '$base/check?request_id=req-1',
        (server) => server.reply(200, {'status': 'expired'}),
      );
      expect(await client.poll('req-1'), MagicLinkPollState.expired);
    });

    test('未知状态按 expired 处理（不能让用户无限等待）', () async {
      adapter.onGet(
        '$base/check?request_id=req-1',
        (server) => server.reply(200, {'status': 'whatever'}),
      );
      expect(await client.poll('req-1'), MagicLinkPollState.expired);
    });
  });

  group('exchange（换取标准 OIDC 授权码）', () {
    Map<String, dynamic> body({String? challenge}) => {
      'request_id': 'req-1',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'state': 'state-1234567890',
      'code_challenge': challenge ?? 'chal',
      'code_challenge_method': 'S256',
    };

    test('提交 request_id / client_id / redirect_uri / S256 challenge', () async {
      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        '$base/exchange',
        (server) => server.reply(200, {'success': true, 'code': 'ory_ac_x'}),
        data: body(challenge: pkce.challenge),
      );

      final code = await client.exchange(
        requestId: 'req-1',
        pkce: pkce,
        state: 'state-1234567890',
      );
      expect(code, 'ory_ac_x');
    });

    test('响应缺 code 时抛 AuthError', () async {
      adapter.onPost(
        '$base/exchange',
        (server) => server.reply(200, {'success': true}),
        data: Matchers.any,
      );
      expect(
        () => client.exchange(
          requestId: 'req-1',
          pkce: OidcPkce.generatePair(),
          state: 'state-1234567890',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('未确认（409 request_pending）翻成「去邮件里确认」', () async {
      adapter.onPost(
        '$base/exchange',
        (server) => server.reply(409, {
          'success': false,
          'error': 'request_pending',
          'message': '尚未在邮件中确认',
        }),
        data: Matchers.any,
      );
      expect(
        () => client.exchange(
          requestId: 'req-1',
          pkce: OidcPkce.generatePair(),
          state: 'state-1234567890',
        ),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('确认登录'),
          ),
        ),
      );
    });

    test('过期（410 request_expired）翻成「重新发起」', () async {
      adapter.onPost(
        '$base/exchange',
        (server) => server.reply(410, {'error': 'request_expired'}),
        data: Matchers.any,
      );
      expect(
        () => client.exchange(
          requestId: 'req-1',
          pkce: OidcPkce.generatePair(),
          state: 'state-1234567890',
        ),
        throwsA(
          isA<AuthError>().having((e) => e.message, 'message', contains('过期')),
        ),
      );
    });

    test('redirect_uri 与注册值不一致 → 指出是配置问题', () async {
      adapter.onPost(
        '$base/exchange',
        (server) => server.reply(400, {'error': 'invalid_request'}),
        data: Matchers.any,
      );
      expect(
        () => client.exchange(
          requestId: 'req-1',
          pkce: OidcPkce.generatePair(),
          state: 'state-1234567890',
        ),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            contains('IdP 注册'),
          ),
        ),
      );
    });
  });
}
