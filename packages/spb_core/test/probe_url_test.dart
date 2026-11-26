import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

void main() {
  group('probeUrl：把「服务端下发的绝对 URL」换成可判定的可达性', () {
    test('https 未写端口时探 443，http 探 80', () async {
      final seen = <String>[];
      Future<bool> fake(String host, int port, Duration timeout) async {
        seen.add('$host:$port');
        return true;
      }

      expect(
        await probeUrl(Uri.parse('https://a.example/x'), probe: fake),
        isTrue,
      );
      expect(
        await probeUrl(Uri.parse('http://b.example:9000/y'), probe: fake),
        isTrue,
      );
      expect(seen, ['a.example:443', 'b.example:9000']);
    });

    test('探测返回 false 时透传 false（调用方据此回落）', () async {
      final ok = await probeUrl(
        Uri.parse('https://dever-preview.atjog.com/preview/s/x'),
        probe: (h, p, t) async => false,
      );
      expect(ok, isFalse);
    });

    test('非 http(s) 不探测、直接放行', () async {
      var called = false;
      Future<bool> fake(String h, int p, Duration t) async {
        called = true;
        return false;
      }

      expect(await probeUrl(Uri.parse('mailto:a@b.c'), probe: fake), isTrue);
      expect(
        await probeUrl(Uri.parse('partyb://oidc/callback'), probe: fake),
        isTrue,
      );
      expect(
        await probeUrl(Uri.parse('file:///tmp/x.png'), probe: fake),
        isTrue,
      );
      expect(called, isFalse);
    });

    test('探测函数抛错视为可达（探测是增强不是门禁）', () async {
      final ok = await probeUrl(
        Uri.parse('https://a.example/'),
        probe: (h, p, t) async => throw StateError('boom'),
      );
      expect(ok, isTrue);
    });
  });
}
