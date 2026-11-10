import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

void main() {
  const base = 'https://gateway.example/ufs';
  test('相对站点路径按网关 origin 解析', () {
    expect(
      resolveArchiveSiteUrl(
        '/_staging/ufs_sites/g-a/',
        ufsBaseUrl: base,
      ).toString(),
      'https://gateway.example/_staging/ufs_sites/g-a/',
    );
  });
  test('拒绝服务间地址和非 HTTP scheme', () {
    for (final raw in [
      'http://127.0.0.1:8080/ufs_sites/g-a/',
      'http://10.0.0.1/a',
      'http://172.17.0.1:9000/a',
      'http://192.168.1.2/a',
      'http://localhost/a',
      'http://host.docker.internal/a',
      'http://[::1]/a',
      'http://[fd00::1]/a',
      'http://[::ffff:127.0.0.1]/a',
      'javascript:alert(1)',
      'file:///tmp/a',
      'https://user:pass@example.org/a',
    ]) {
      expect(resolveArchiveSiteUrl(raw, ufsBaseUrl: base), isNull, reason: raw);
    }
  });
  test('支持明确配置的内网部署和公网独立站点', () {
    expect(
      resolveArchiveSiteUrl(
        'http://localhost:8080/a',
        ufsBaseUrl: 'http://localhost:8080/ufs',
      ),
      isNotNull,
    );
    expect(
      resolveArchiveSiteUrl('https://[2606:4700::1]/a', ufsBaseUrl: base),
      isNotNull,
    );
    expect(
      resolveArchiveSiteUrl('https://public.example/a', ufsBaseUrl: base),
      isNotNull,
    );
  });
}
