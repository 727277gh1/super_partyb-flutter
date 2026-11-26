import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:test/test.dart';

void main() {
  for (final kind in [
    'api',
    'sse',
    'sse-custom',
    'qr-default',
    'qr-custom',
    'oidc-default',
    'oidc-custom',
    'mini-default',
    'mini-custom',
    'magic-default',
    'magic-custom',
  ]) {
    test('$kind 不跟随跳转传播凭据或接受目标响应', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await origin.close(force: true);
        await target.close(force: true);
      });
      final originUrl = 'http://127.0.0.1:${origin.port}';
      final targetUrl = 'http://127.0.0.1:${target.port}/capture';
      final received = <String?>[];
      target.listen((request) async {
        received.add(
          request.headers.value('X-Poll-Secret') ??
              request.headers.value(HttpHeaders.authorizationHeader),
        );
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'access_token': 'test-only-target-token',
            'status': 'confirmed',
            'source': '合成设备',
            'user': {'name': '测试账号'},
          }),
        );
        await request.response.close();
      });
      origin.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(HttpHeaders.locationHeader, targetUrl);
        await request.response.close();
      });
      var rejected = false;
      if (kind == 'api' || kind.startsWith('sse')) {
        final dio = kind == 'sse-custom'
            ? Dio()
            : createDio(
                baseUrl: originUrl,
                interceptors: [
                  AuthInterceptor(
                    tokenProvider: () async => 'test-only-bearer',
                  ),
                ],
              );
        addTearDown(() => dio.close(force: true));
        if (kind == 'api') {
          try {
            await dio.get<dynamic>('/api/auth/me');
          } catch (_) {
            rejected = true;
          }
        } else {
          final client = SseClient(dio: dio, baseUrl: originUrl, maxRetries: 0);
          final subscription = client.frames.listen((_) {}, onError: (_) {});
          addTearDown(() async {
            await subscription.cancel();
            await client.dispose();
          });
          await client.connect(path: '/stream');
          rejected = client.state == SseState.failed;
        }
      } else if (kind.startsWith('mini') || kind.startsWith('magic')) {
        final dio = kind.endsWith('custom')
            ? Dio(
                BaseOptions(followRedirects: true, validateStatus: (_) => true),
              )
            : null;
        addTearDown(() => dio?.close(force: true));
        try {
          if (kind.startsWith('mini')) {
            await MiniProgramLoginClient(
              issuer: Uri.parse('$originUrl/idp'),
              clientId: 'test-client',
              redirectUri: 'partyb://callback',
              dio: dio,
            ).poll('test-scene', pollSecret: 'test-only-poll-secret');
          } else {
            await MagicLinkClient(
              issuer: Uri.parse('$originUrl/idp'),
              clientId: 'test-client',
              redirectUri: 'partyb://callback',
              dio: dio,
            ).poll('test-request');
          }
        } catch (_) {
          rejected = true;
        }
      } else if (kind.startsWith('qr')) {
        final dio = kind.endsWith('custom')
            ? Dio(
                BaseOptions(followRedirects: true, validateStatus: (_) => true),
              )
            : null;
        addTearDown(() => dio?.close(force: true));
        final client = QrLoginClient(
          issuer: Uri.parse('$originUrl/idp'),
          tokenProvider: () async => 'test-only-qr-bearer',
          dio: dio,
        );
        try {
          await client.preview('test-only-scene');
        } catch (_) {
          rejected = true;
        }
      } else {
        final dio = kind.endsWith('custom')
            ? Dio(
                BaseOptions(followRedirects: true, validateStatus: (_) => true),
              )
            : null;
        addTearDown(() => dio?.close(force: true));
        final client = OidcClient(
          config: OidcConfig(
            issuer: '$originUrl/idp',
            clientId: 'test-client',
            redirectUri: 'partyb://callback',
            clientSecret: 'test-only-client-secret',
          ),
          dio: dio,
        );
        try {
          await client.refresh(refreshToken: 'test-only-refresh-token');
        } catch (_) {
          rejected = true;
        }
      }
      expect(received, isEmpty, reason: '不同端口的跳转目标不应收到认证请求');
      expect(rejected, isTrue, reason: '不能把跳转目标的响应当作可信 API 结果');
    });
  }

  test('UFS 条件下载仍把 304 作为缓存命中', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.headers.value(HttpHeaders.ifNoneMatchHeader), 'test-etag');
      request.response.statusCode = HttpStatus.notModified;
      request.response.headers.set(HttpHeaders.etagHeader, 'test-etag');
      await request.response.close();
    });
    final dio = createDio(baseUrl: 'http://127.0.0.1:${server.port}');
    addTearDown(() => dio.close(force: true));
    final download = await UfsApi(dio)
        .download('test-file', ifNoneMatch: 'test-etag');
    expect(download.notModified, isTrue);
    expect(download.bytes, isNull);
    expect(download.etag, 'test-etag');
  });
}
