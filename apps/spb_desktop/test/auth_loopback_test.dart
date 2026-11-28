import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_desktop/auth_loopback.dart';

/// 假 IdP token 端点：记录收到的表单，回一组固定 token。
///
/// 断言「客户端真的发了什么」，而不是只 mock 客户端自身。
class FakeTokenEndpoint {
  FakeTokenEndpoint._(this._server);

  final HttpServer _server;
  final Map<String, String> captured = {};

  int get port => _server.port;

  static Future<FakeTokenEndpoint> start({bool fail = false}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = FakeTokenEndpoint._(server);
    server.listen((req) async {
      final raw = await req.cast<List<int>>().fold<List<int>>(
        <int>[],
        (a, b) => a..addAll(b),
      );
      self.captured.addAll(Uri.splitQueryString(String.fromCharCodes(raw)));

      req.response.headers.contentType = ContentType.json;
      if (fail) {
        req.response.statusCode = 400;
        req.response.write(
          '{"error":"invalid_grant","error_description":"bad code"}',
        );
      } else {
        req.response.statusCode = 200;
        req.response.write(
          '{"access_token":"at-test","id_token":"idt-test",'
          '"refresh_token":"rt-test","token_type":"Bearer","expires_in":3600}',
        );
      }
      await req.response.close();
    });
    return self;
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test('未配置 client_id 直接失败', () async {
    final r = await loopbackSignIn(
      config: const OidcConfig(
        issuer: 'http://127.0.0.1:1/idp',
        clientId: '',
        redirectUri: 'http://127.0.0.1/callback',
      ),
    );
    expect(r.ok, isFalse);
    expect(r.error, contains('client_id'));
  });

  test('配置了 client_secret（机密客户端）直接失败并说明原因', () async {
    final r = await loopbackSignIn(
      config: const OidcConfig(
        issuer: 'http://127.0.0.1:1/idp',
        clientId: 'c1',
        redirectUri: 'http://127.0.0.1/callback',
        clientSecret: 'should-not-be-embedded',
      ),
    );
    expect(r.ok, isFalse);
    expect(r.error, contains('public client'));
  });

  test('浏览器打不开时报可操作错误（含授权 URL）', () async {
    final r = await loopbackSignIn(
      config: _publicConfig(),
      launchInBrowser: (url) => throw const PlatformError('无浏览器'),
    );
    expect(r.ok, isFalse);
    expect(r.error, contains('无法打开浏览器'));
  });

  test('端到端：假浏览器 → 真 loopback 监听 → 假 token 端点', () async {
    final endpoint = await FakeTokenEndpoint.start();
    addTearDown(endpoint.close);

    Uri? launchedUrl;
    final r = await loopbackSignIn(
      config: _publicConfig(issuer: 'http://127.0.0.1:${endpoint.port}/idp'),
      stateGenerator: () => 'fixedstate123',
      pkceGenerator: () => const PkcePair(
        verifier: 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
        challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      ),
      launchInBrowser: (url) async {
        launchedUrl = url;
        // 模拟浏览器完成登录后 302 回 loopback 端口。
        await _hitCallback(url, code: 'goodcode', state: 'fixedstate123');
      },
    );

    expect(r.ok, isTrue, reason: r.error);
    expect(r.tokens!.accessToken, 'at-test');
    expect(r.tokens!.canRefresh, isTrue);

    // 授权 URL 直连 IdP（不是网关），redirect_uri 是本机随机端口的 loopback。
    expect(launchedUrl, isNotNull);
    expect(launchedUrl!.path, contains('oauth2/authorize'));
    final redirectUri = launchedUrl!.queryParameters['redirect_uri']!;
    expect(redirectUri, startsWith('http://127.0.0.1:'));
    expect(redirectUri, endsWith('/callback'));
    expect(launchedUrl!.queryParameters['code_challenge_method'], 'S256');
    expect(launchedUrl!.queryParameters['state'], 'fixedstate123');
    expect(launchedUrl!.queryParameters['code_challenge'], isNotEmpty);

    // token 请求：public client 无 secret；redirect_uri 与授权一致；带 verifier。
    expect(endpoint.captured['grant_type'], 'authorization_code');
    expect(endpoint.captured['code'], 'goodcode');
    expect(
      endpoint.captured['code_verifier'],
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
    );
    expect(endpoint.captured['client_id'], 'c-desktop');
    expect(endpoint.captured.containsKey('client_secret'), isFalse);
    expect(endpoint.captured['redirect_uri'], redirectUri);
  });

  test('回调 state 不匹配报 CSRF 错误且不换 token', () async {
    final endpoint = await FakeTokenEndpoint.start();
    addTearDown(endpoint.close);

    final r = await loopbackSignIn(
      config: _publicConfig(issuer: 'http://127.0.0.1:${endpoint.port}/idp'),
      stateGenerator: () => 'expectedstate1',
      launchInBrowser: (url) =>
          _hitCallback(url, code: 'x', state: 'WRONG-state'),
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('state'));
    // 关键：state 校验失败时**不能**把 code 发去 token 端点。
    expect(endpoint.captured, isEmpty);
  });

  test('用户拒绝授权（error=access_denied）给出可读原因', () async {
    final endpoint = await FakeTokenEndpoint.start();
    addTearDown(endpoint.close);

    final r = await loopbackSignIn(
      config: _publicConfig(issuer: 'http://127.0.0.1:${endpoint.port}/idp'),
      stateGenerator: () => 'st1',
      launchInBrowser: (url) async {
        final cb = Uri.parse(
          '${url.queryParameters['redirect_uri']}'
          '?error=access_denied&error_description=user+said+no&state=st1',
        );
        await _get(cb);
      },
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('access_denied'));
    expect(r.error, contains('user said no'));
  });

  test('token 端点返回错误时映射为可读文案', () async {
    final endpoint = await FakeTokenEndpoint.start(fail: true);
    addTearDown(endpoint.close);

    final r = await loopbackSignIn(
      config: _publicConfig(issuer: 'http://127.0.0.1:${endpoint.port}/idp'),
      stateGenerator: () => 'st1',
      launchInBrowser: (url) => _hitCallback(url, code: 'bad', state: 'st1'),
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('invalid_grant'));
  });

  test('超时未回调时报超时', () async {
    final endpoint = await FakeTokenEndpoint.start();
    addTearDown(endpoint.close);

    final r = await loopbackSignIn(
      config: _publicConfig(issuer: 'http://127.0.0.1:${endpoint.port}/idp'),
      launchInBrowser: (url) async {
        // 什么都不做：模拟用户把浏览器关了。
      },
      callbackTimeout: const Duration(milliseconds: 200),
    );

    expect(r.ok, isFalse);
    expect(r.error, contains('超时'));
  });
}

// ---------- 辅助 ----------

OidcConfig _publicConfig({String issuer = 'http://127.0.0.1:1/idp'}) =>
    OidcConfig(
      issuer: issuer,
      clientId: 'c-desktop',
      redirectUri: 'http://127.0.0.1/callback',
    );

/// 模拟浏览器 302 到 loopback 回调端口。
Future<void> _hitCallback(
  Uri authorizeUrl, {
  required String code,
  required String state,
}) async {
  final cb = Uri.parse(
    '${authorizeUrl.queryParameters['redirect_uri']}?code=$code&state=$state',
  );
  await _get(cb);
}

Future<void> _get(Uri url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close();
  }
}
