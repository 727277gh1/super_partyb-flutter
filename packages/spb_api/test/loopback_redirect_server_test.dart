import 'dart:async';
import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:test/test.dart';

void main() {
  group('LoopbackRedirectServer', () {
    test('绑定随机端口且只监听 loopback', () async {
      final server = await LoopbackRedirectServer.start();
      addTearDown(server.close);

      expect(server.port, greaterThan(0));
      expect(server.redirectUri(), 'http://127.0.0.1:${server.port}/callback');
    });

    test('收到回调后返回带 code 的 URI 并自动关停', () async {
      final server = await LoopbackRedirectServer.start();
      addTearDown(server.close);

      final waiting = server.wait();

      // 模拟浏览器 302 后的 GET。
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('${server.redirectUri()}?code=abc123&state=st1'),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      // 读干响应体，确保连接正常关闭。
      await resp.drain<void>();
      client.close();

      final callback = await waiting;
      expect(callback.queryParameters['code'], 'abc123');
      expect(callback.queryParameters['state'], 'st1');

      // 一次性：回调后端口应已释放。再连应失败。
      await expectLater(() async {
        final c2 = HttpClient();
        final r2 = await c2.getUrl(Uri.parse(server.redirectUri()));
        await r2.close();
        c2.close();
      }(), throwsA(isA<SocketException>()));
    });

    test('错误回调（error=access_denied）同样被送达', () async {
      final server = await LoopbackRedirectServer.start();
      addTearDown(server.close);

      final waiting = server.wait();
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('${server.redirectUri()}?error=access_denied&state=st2'),
      );
      final resp = await req.close();
      await resp.drain<void>();
      client.close();

      final callback = await waiting;
      expect(callback.queryParameters['error'], 'access_denied');
    });

    test('无关路径不消费监听（404 后仍可收到真实回调）', () async {
      final server = await LoopbackRedirectServer.start();
      addTearDown(server.close);

      final waiting = server.wait();

      // 浏览器预取 favicon：不应结束等待。
      final client = HttpClient();
      final favicon = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/favicon.ico'),
      );
      final faviconResp = await favicon.close();
      expect(faviconResp.statusCode, 404);
      await faviconResp.drain<void>();

      // 真实回调仍能被收到。
      final req = await client.getUrl(
        Uri.parse('${server.redirectUri()}?code=real&state=st3'),
      );
      final resp = await req.close();
      await resp.drain<void>();
      client.close();

      final callback = await waiting;
      expect(callback.queryParameters['code'], 'real');
    });

    test('超时后以 TimeoutException 失败并关停', () async {
      final server = await LoopbackRedirectServer.start(
        timeout: const Duration(milliseconds: 150),
      );
      addTearDown(server.close);

      await expectLater(server.wait(), throwsA(isA<TimeoutException>()));
    });

    test('自定义回调路径', () async {
      final server = await LoopbackRedirectServer.start(path: '/oauth/cb');
      addTearDown(server.close);

      expect(server.redirectUri(path: '/oauth/cb'), contains('/oauth/cb'));

      final waiting = server.wait();
      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('${server.redirectUri(path: '/oauth/cb')}?code=c9'),
      );
      final resp = await req.close();
      await resp.drain<void>();
      client.close();

      expect((await waiting).queryParameters['code'], 'c9');
    });

    test('close 幂等', () async {
      final server = await LoopbackRedirectServer.start();
      await server.close();
      await server.close(); // 不应抛。
    });
  });

  group('LoopbackCallbackUri', () {
    test('注册值不含端口（RFC 8252 §7.3 端口通配）', () {
      expect(
        LoopbackCallbackUri.registeredRedirectUri,
        'http://127.0.0.1/callback',
      );
      // 去掉 scheme 后不应再有冒号（有则说明写了端口）。
      final withoutScheme = LoopbackCallbackUri.registeredRedirectUri
          .replaceFirst('http://', '');
      expect(withoutScheme, isNot(contains(':')));
    });

    test('matches 只认 127.0.0.1 + /callback', () {
      expect(
        LoopbackCallbackUri.matches(
          Uri.parse('http://127.0.0.1:5555/callback'),
        ),
        isTrue,
      );
      // 结尾斜杠容错。
      expect(
        LoopbackCallbackUri.matches(
          Uri.parse('http://127.0.0.1:5555/callback/'),
        ),
        isTrue,
      );
      // localhost 不是注册值（RFC 8252 §7.3 明确不推荐）。
      expect(
        LoopbackCallbackUri.matches(
          Uri.parse('http://localhost:5555/callback'),
        ),
        isFalse,
      );
      // 外网地址必须挡掉（否则 code 会被发去错误的地方）。
      expect(
        LoopbackCallbackUri.matches(Uri.parse('http://evil.com/callback')),
        isFalse,
      );
      expect(
        LoopbackCallbackUri.matches(Uri.parse('https://127.0.0.1/callback')),
        isFalse,
      );
      expect(
        LoopbackCallbackUri.matches(Uri.parse('http://127.0.0.1:5555/other')),
        isFalse,
      );
    });

    test('toString 不泄漏参数', () {
      expect(
        LoopbackCallbackUri.toStringOf(),
        'LoopbackCallbackUri(http://127.0.0.1/callback)',
      );
    });
  });
}
