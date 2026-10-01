import 'dart:math';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// OIDC PKCE 客户端的契约与规范测试。
///
/// ## 这个测试防的是什么
///
/// PKCE 的每一处错误都是**静默的**：
/// - `code_challenge` 算错 → 授权阶段照常成功，直到换 token 才 `invalid_grant`；
/// - verifier 长度/字符集不合规 → 某些 IdP 直接 400，某些接受，行为不一致；
/// - `code_challenge_method` 写成 `plain` → 安全强度降级但流程仍能走通。
///
/// 因此这里不只测「能生成字符串」，而是按 **RFC 7636 的规范文本**逐条断言
/// （长度区间、字符集、S256 算法、以及附录 B 的官方测试向量）。
///
/// 实测的 IdP 能力见 `docs/oidc-verification.md`（redirect_uri 精确匹配、
/// PKCE 非强制、token 端点要求 client_secret）。
void main() {
  OidcConfig config({
    String issuer = 'https://app.example.com/idp',
    String clientId = 'client_test',
    String redirectUri = 'https://app.example.com/auth/oidc/callback',
    String? clientSecret,
  }) => OidcConfig(
    issuer: issuer,
    clientId: clientId,
    redirectUri: redirectUri,
    clientSecret: clientSecret,
  );

  group('OIDC PKCE verifier 合规（RFC 7636 §4.1）', () {
    test('长度落在 43–128 之间，且字符集仅含 unreserved 集合', () {
      // RFC 7636 §4.1：
      //   code_verifier = high-entropy cryptographic random STRING
      //                   using unreserved characters [A-Z] / [a-z] / [0-9]
      //                   / "-" / "." / "_" / "~"
      //   with a minimum length of 43 characters and a maximum length of
      //   128 characters.
      for (final len in [43, 64, 128]) {
        final v = OidcPkce.generateVerifier(length: len);
        expect(v.length, len, reason: '请求 $len 长度就必须得到 $len');
        expect(
          OidcPkce.isValidVerifier(v),
          isTrue,
          reason: '生成的 verifier 必须满足 RFC 7636 §4.1',
        );
        expect(
          RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v),
          isTrue,
          reason: 'verifier 只能含 unreserved 字符，实际：$v',
        );
      }
    });

    test('默认长度 64（落在区间中段，避免贴边被某些 IdP 拒）', () {
      final v = OidcPkce.generateVerifier();
      expect(v.length, 64);
      expect(v.length, greaterThan(pkceVerifierMinLength));
      expect(v.length, lessThan(pkceVerifierMaxLength));
    });

    test('拒绝区间外的长度（不让非法 verifier 被静默产出）', () {
      expect(() => OidcPkce.generateVerifier(length: 42), throwsArgumentError);
      expect(() => OidcPkce.generateVerifier(length: 129), throwsArgumentError);
      // 边界值本身是合法的
      expect(OidcPkce.generateVerifier(length: 43).length, 43);
      expect(OidcPkce.generateVerifier(length: 128).length, 128);
    });

    test('isValidVerifier 拒绝过短/过长/含非法字符的串', () {
      expect(OidcPkce.isValidVerifier('a' * 43), isTrue);
      expect(OidcPkce.isValidVerifier('a' * 128), isTrue);
      expect(OidcPkce.isValidVerifier('a' * 42), isFalse, reason: '过短');
      expect(OidcPkce.isValidVerifier('a' * 129), isFalse, reason: '过长');
      expect(OidcPkce.isValidVerifier(''), isFalse);
      // '+' '/' '=' 不在 unreserved 集合里（是 base64 而非 base64url 的字符）
      expect(OidcPkce.isValidVerifier('${'a' * 42}+'), isFalse);
      expect(OidcPkce.isValidVerifier('${'a' * 42}/'), isFalse);
      expect(OidcPkce.isValidVerifier('${'a' * 42}='), isFalse);
      expect(OidcPkce.isValidVerifier('${'a' * 42} '), isFalse, reason: '空格');
    });

    test('两次生成互不相同（用的是密码学随机源）', () {
      final a = OidcPkce.generateVerifier();
      final b = OidcPkce.generateVerifier();
      expect(a, isNot(b));
    });

    test('注入的随机源可复现（测试确定性）', () {
      final a = OidcPkce.generateVerifier(random: Random(42));
      final b = OidcPkce.generateVerifier(random: Random(42));
      expect(a, b);
    });
  });

  group('OIDC PKCE challenge（RFC 7636 §4.2 S256）', () {
    test('附录 B 官方测试向量', () {
      // RFC 7636 Appendix B:
      //   code_verifier  = dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
      //   code_challenge = E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        OidcPkce.challengeFor(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('challenge 是 base64url 且无 padding', () {
      // SHA256 → 32 字节 → base64 后 44 字符（含 1 个 '='），去 padding 后 43。
      final pair = OidcPkce.generatePair();
      expect(pair.challenge.length, 43, reason: '32 字节 base64 去 padding');
      expect(pair.challenge.contains('='), isFalse, reason: '不能带 padding');
      expect(
        RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(pair.challenge),
        isTrue,
        reason: 'base64url 字符集（- 和 _，不是 + 和 /）',
      );
      expect(pair.challenge.contains('+'), isFalse);
      expect(pair.challenge.contains('/'), isFalse);
    });

    test('method 是 S256（不是 plain）', () {
      expect(PkcePair.method, 'S256');
    });

    test('pair 的 challenge 与 verifier 匹配', () {
      final pair = OidcPkce.generatePair();
      expect(pair.challenge, OidcPkce.challengeFor(pair.verifier));
    });

    test('toString 不泄露 verifier', () {
      // verifier 是安全敏感值：一旦进了日志就失去意义。
      final pair = OidcPkce.generatePair();
      expect(pair.toString(), isNot(contains(pair.verifier)));
      expect(pair.toString(), contains('已隐藏'));
    });
  });

  group('OIDC 授权 URL 构造', () {
    test('直连 IdP：含 code_challenge_method=S256 / code_challenge / state / redirect_uri', () {
      final c = config();
      final pkce = OidcPkce.generatePair();
      final url = OidcPkce.buildAuthorizeUrl(
        config: c,
        pkce: pkce,
        state: 'state_abc',
        nonce: 'nonce_xyz',
      );

      expect(url.origin, 'https://app.example.com');
      expect(url.path, '/idp/oauth2/authorize');

      final q = url.queryParameters;
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], pkce.challenge);
      expect(q['state'], 'state_abc');
      expect(q['nonce'], 'nonce_xyz');
      expect(q['redirect_uri'], c.redirectUri);
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'client_test');
      expect(q['scope'], 'openid profile email offline_access');
    });

    test('授权 URL 里不得出现 code_verifier（只提交 challenge）', () {
      final pkce = OidcPkce.generatePair();
      final url = OidcPkce.buildAuthorizeUrl(
        config: config(),
        pkce: pkce,
        state: 's',
        nonce: 'n',
      );
      expect(
        url.toString(),
        isNot(contains(pkce.verifier)),
        reason: 'verifier 泄露到 URL 就等于把 PKCE 降级成 plain',
      );
      expect(url.queryParameters.containsKey('code_verifier'), isFalse);
    });

    test('issuer 末尾斜杠被归一化（不拼出 //oauth2/authorize）', () {
      final c = config(issuer: 'https://app.example.com/idp/');
      expect(c.normalizedIssuer, 'https://app.example.com/idp');
      expect(
        c.authorizeEndpoint,
        'https://app.example.com/idp/oauth2/authorize',
      );
      expect(c.authorizeEndpoint, isNot(contains('//oauth2')));
    });

    test('client_id 为空时抛 AuthError（而不是拼出无效 URL）', () {
      expect(
        () => OidcPkce.buildAuthorizeUrl(
          config: config(clientId: ''),
          pkce: OidcPkce.generatePair(),
          state: 's',
          nonce: 'n',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('extraParams 可附加（如 prompt=consent / login_hint）', () {
      final url = OidcPkce.buildAuthorizeUrl(
        config: config(),
        pkce: OidcPkce.generatePair(),
        state: 's',
        nonce: 'n',
        extraParams: {'prompt': 'consent', 'login_hint': 'a@b.c'},
      );
      expect(url.queryParameters['prompt'], 'consent');
      expect(url.queryParameters['login_hint'], 'a@b.c');
    });
  });

  group('OIDC 网关托管入口（生产主路径）', () {
    test('从 issuer 推导网关根地址并拼 /auth/oidc/authorize', () {
      // 生产实测（docs/oidc-verification.md）：网关忽略调用方传入的
      // redirect_uri，回调固定为网关配置值，故客户端只提供 state 与站内回跳。
      final c = config(issuer: 'https://app.example.com/idp');
      final url = c.authorizeUrl(state: 'st_1');
      expect(
        url.toString(),
        'https://app.example.com/auth/oidc/authorize?state=st_1',
      );
    });

    test('不带 redirect_uri（带了也会被网关忽略，留着会误导）', () {
      final url = config().authorizeUrl(state: 'st_1');
      expect(url.queryParameters.containsKey('redirect_uri'), isFalse);
    });

    test('post_login_redirect 只接受站内绝对路径', () {
      final c = config();
      final url = c.authorizeUrl(
        state: 'st_1',
        postLoginRedirect: '/pbw/zh/workbench/',
      );
      expect(url.queryParameters['post_login_redirect'], '/pbw/zh/workbench/');
      expect(url.queryParameters['state'], 'st_1');
    });

    test('post_login_redirect 为空时不下发该参数', () {
      final url = config().authorizeUrl(state: 'st_1', postLoginRedirect: '');
      expect(url.queryParameters.containsKey('post_login_redirect'), isFalse);
    });

    test('gatewayBaseUrl 可覆盖推导结果', () {
      final url = config().authorizeUrl(
        state: 'st_1',
        gatewayBaseUrl: 'https://api.example.com',
      );
      expect(url.origin, 'https://api.example.com');
      expect(url.path, '/auth/oidc/authorize');
    });

    test('OidcClient.authorizeUrl 与 OidcConfig.authorizeUrl 一致', () {
      final c = config();
      final client = OidcClient(config: c);
      expect(
        client.authorizeUrl(state: 'st_1').toString(),
        c.authorizeUrl(state: 'st_1').toString(),
      );
    });
  });

  group('OIDC 回调解析', () {
    test('取出 code 与 state', () {
      final r = OidcPkce.parseCallback(
        Uri.parse('https://x/cb?code=CODE1&state=st_1'),
        expectedState: 'st_1',
      );
      expect(r.code, 'CODE1');
      expect(r.state, 'st_1');
    });

    test('state 不匹配时抛 AuthError（CSRF 防线）', () {
      expect(
        () => OidcPkce.parseCallback(
          Uri.parse('https://x/cb?code=CODE1&state=attacker'),
          expectedState: 'st_1',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('缺 code 时抛 AuthError', () {
      expect(
        () => OidcPkce.parseCallback(
          Uri.parse('https://x/cb?state=st_1'),
          expectedState: 'st_1',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('带 error 时抛 AuthError 并带上 error_description', () {
      // 「用户点了取消」不该被显示成网络错误。
      try {
        OidcPkce.parseCallback(
          Uri.parse(
            'https://x/cb?error=access_denied&error_description=%E7%94%A8%E6%88%B7%E6%8B%92%E7%BB%9D',
          ),
          expectedState: 'st_1',
        );
        fail('应当抛出 AuthError');
      } on AuthError catch (e) {
        expect(e.message, contains('access_denied'));
        expect(e.message, contains('用户拒绝'));
      }
    });
  });

  group('OIDC token 交换与刷新', () {
    late Dio dio;
    late DioAdapter adapter;

    setUp(() {
      dio = Dio(BaseOptions(responseType: ResponseType.json));
      adapter = DioAdapter(dio: dio);
    });

    Map<String, dynamic> tokenBody({
      String accessToken = 'at_1',
      String? refreshToken,
    }) => {
      'access_token': accessToken,
      'token_type': 'Bearer',
      'expires_in': 3600,
      'id_token': 'header.payload.sig',
      if (refreshToken != null) 'refresh_token': refreshToken,
      'scope': 'openid profile email',
    };

    test('exchangeCode 提交 code_verifier 与 redirect_uri（S256 流程）', () async {
      final captured = <String, dynamic>{};
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (o, h) {
            captured.addAll(
              o.data is Map
                  ? Map<String, dynamic>.from(o.data as Map)
                  : <String, dynamic>{},
            );
            h.next(o);
          },
        ),
      );

      final pkce = OidcPkce.generatePair();
      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(200, tokenBody()),
        data: Matchers.any,
      );

      final client = OidcClient(config: config(), dio: dio);
      final tokens = await client.exchangeCode(code: 'CODE1', pkce: pkce);

      expect(captured['grant_type'], 'authorization_code');
      expect(captured['code'], 'CODE1');
      expect(captured['code_verifier'], pkce.verifier);
      expect(
        captured['redirect_uri'],
        'https://app.example.com/auth/oidc/callback',
        reason: '必须与授权请求时的 redirect_uri 一致，否则 invalid_grant',
      );
      expect(captured['client_id'], 'client_test');
      expect(tokens.accessToken, 'at_1');
      expect(tokens.canRefresh, isFalse, reason: '未下发 refresh_token');
    });

    test('refresh 提交 grant_type=refresh_token', () async {
      final captured = <String, dynamic>{};
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (o, h) {
            captured.addAll(
              o.data is Map
                  ? Map<String, dynamic>.from(o.data as Map)
                  : <String, dynamic>{},
            );
            h.next(o);
          },
        ),
      );

      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(200, tokenBody(refreshToken: 'rt_2')),
        data: Matchers.any,
      );

      final client = OidcClient(config: config(), dio: dio);
      final tokens = await client.refresh(refreshToken: 'rt_1');

      expect(captured['grant_type'], 'refresh_token');
      expect(captured['refresh_token'], 'rt_1');
      expect(tokens.canRefresh, isTrue);
      expect(tokens.refreshToken, 'rt_2');
    });

    test('client_secret 走 client_secret_basic（不进请求体）', () async {
      String? authHeader;
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (o, h) {
            authHeader = o.headers['Authorization']?.toString();
            h.next(o);
          },
        ),
      );

      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(200, tokenBody()),
        data: Matchers.any,
      );

      final client = OidcClient(
        config: config(clientSecret: 'sec_value'),
        dio: dio,
      );
      await client.refresh(refreshToken: 'rt_1');

      expect(authHeader, isNotNull);
      expect(authHeader, startsWith('Basic '));
      // base64("client_test:sec_value")
      expect(authHeader, 'Basic Y2xpZW50X3Rlc3Q6c2VjX3ZhbHVl');
    });

    test('无 client_secret 时不发 Authorization 头', () async {
      var hadAuthHeader = false;
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (o, h) {
            hadAuthHeader = o.headers.containsKey('Authorization');
            h.next(o);
          },
        ),
      );

      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(200, tokenBody()),
        data: Matchers.any,
      );

      await OidcClient(
        config: config(),
        dio: dio,
      ).refresh(refreshToken: 'rt_1');
      expect(hadAuthHeader, isFalse);
    });

    test('400 invalid_grant 映射为 AuthError 并带上服务端描述', () async {
      // 4xx 必须显式处理：不处理的话错误体会被解析成「全空 token 对象」，
      // 表现为「登录成功但后续全部 401」。
      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(400, {
          'error': 'invalid_grant',
          'error_description': 'PKCE verification failed',
        }),
        data: Matchers.any,
      );

      try {
        await OidcClient(
          config: config(),
          dio: dio,
        ).exchangeCode(code: 'bad', pkce: OidcPkce.generatePair());
        fail('应当抛出 AuthError');
      } on AuthError catch (e) {
        expect(e.message, contains('invalid_grant'));
        expect(e.message, contains('PKCE verification failed'));
      }
    });

    test('缺 access_token 的响应抛 AuthError（不静默造空对象）', () async {
      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(200, {'token_type': 'Bearer'}),
        data: Matchers.any,
      );

      expect(
        () => OidcClient(
          config: config(),
          dio: dio,
        ).refresh(refreshToken: 'rt_1'),
        throwsA(isA<AuthError>()),
      );
    });

    test('client_id 未配置时在发请求前就抛 AuthError', () async {
      expect(
        () => OidcClient(
          config: config(clientId: ''),
          dio: dio,
        ).refresh(refreshToken: 'rt_1'),
        throwsA(isA<AuthError>()),
      );
    });

    test('token 端点 5xx 映射为 HttpError（可重试，不当作登录失败）', () async {
      adapter.onPost(
        'https://app.example.com/idp/oauth2/token',
        (s) => s.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      try {
        await OidcClient(
          config: config(),
          dio: dio,
        ).refresh(refreshToken: 'rt_1');
        fail('应当抛出 HttpError');
      } on HttpError catch (e) {
        // 刻意不是 AuthError：服务端 503 不该被显示成「登录失败，请重新登录」，
        // 否则用户会反复重输密码，而问题其实在服务端。
        expect(e.statusCode, 503);
        expect(e.isServerError, isTrue);
      }
    });
  });

  group('OIDC token 模型', () {
    test('fromJson 解析可选字段', () {
      final t = OidcTokens.fromJson({
        'access_token': 'at',
        'token_type': 'Bearer',
        'expires_in': 1800,
        'id_token': 'id',
        'refresh_token': 'rt',
        'scope': 'openid',
      });
      expect(t.accessToken, 'at');
      expect(t.expiresIn, 1800);
      expect(t.idToken, 'id');
      expect(t.canRefresh, isTrue);
      expect(t.scope, 'openid');
    });

    test('空串的可选字段归一化为 null（不当成「有值」）', () {
      final t = OidcTokens.fromJson({
        'access_token': 'at',
        'id_token': '',
        'refresh_token': '',
      });
      expect(t.idToken, isNull);
      expect(t.refreshToken, isNull);
      expect(t.canRefresh, isFalse);
    });

    test('toString 不泄露任何 token 值', () {
      final t = OidcTokens.fromJson({
        'access_token': 'SECRET_ACCESS',
        'id_token': 'SECRET_ID',
        'refresh_token': 'SECRET_REFRESH',
      });
      final s = t.toString();
      expect(s, isNot(contains('SECRET_ACCESS')));
      expect(s, isNot(contains('SECRET_ID')));
      expect(s, isNot(contains('SECRET_REFRESH')));
      expect(s, contains('canRefresh: true'));
    });
  });

  group('OIDC 配置与编译期注入', () {
    test('fromEnv 读取 SpbEnv 常量', () {
      // 测试环境未传 --dart-define，故取默认值；重点是「读的是 SpbEnv」
      // 而不是硬编码，保证发布构建能用 --dart-define 覆盖。
      final c = OidcConfig.fromEnv();
      expect(c.issuer, SpbEnv.oidcIssuer);
      expect(c.clientId, SpbEnv.oidcClientId);
      expect(c.redirectUri, SpbEnv.oidcRedirectUri);
      expect(c.scopes, contains('openid'));
      expect(c.scopes, contains('offline_access'));
    });

    test('fromEnv 可传 clientSecret', () {
      expect(OidcConfig.fromEnv(clientSecret: 's').clientSecret, 's');
    });

    test('toString 不含 clientSecret', () {
      final c = config(clientSecret: 'SECRET_VALUE');
      expect(c.toString(), isNot(contains('SECRET_VALUE')));
    });

    test('默认 redirect_uri 是 loopback 注册形态（RFC 8252 §7.3）', () {
      // 桌面端改用 RFC 8252 §7.3 loopback 流程：编译期默认值是「不含端口的
      // 注册值」（与 IdP 侧 oauth_clients.redirectUris 应注册的值一致）；
      // 运行时由 copyWithRedirectUri 覆盖为带随机端口的实际回调地址。
      // 见 apps/spb_desktop/lib/auth_loopback.dart 与
      // docs/rfc8252-loopback-signin.md。
      final uri = Uri.parse(SpbEnv.oidcRedirectUri);
      expect(uri.scheme, 'http', reason: 'loopback 回调用 http（不出本机）');
      expect(uri.host, '127.0.0.1', reason: 'RFC 8252 §7.3 要求回环 IP 字面量');
      expect(uri.hasPort, isFalse, reason: '注册值不含端口：端口由客户端动态选，fosite 负责通配');
      expect(uri.path, '/callback');
      // 不得回退到被 IdP 拒绝的自定义 scheme。
      expect(uri.scheme, isNot('partyb'));
    });
  });
}
