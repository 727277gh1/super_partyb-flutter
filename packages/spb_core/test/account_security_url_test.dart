import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// IdP「账号安全」页 URL 的拼接规则。
///
/// ## 这个测试防的是什么
///
/// 两端设置页都靠这个 getter 拼 URL，拼错的失败形态全是**静默**的：多一个
/// 斜杠得到 `//dashboard`、少 basePath 得到 `https://host/dashboard`（404）、
/// 相对地址被 `url_launcher` 直接拒绝（点了没反应）。故这里把 issuer 的各种
/// 现实形态都钉住。
void main() {
  group('SpbEnv.accountSecurityUrlFrom', () {
    test('生产 issuer（带 basePath）：保留 /idp 并追加 dashboard/security', () {
      final url = SpbEnv.accountSecurityUrlFrom('https://dever.atjog.com/idp');
      expect(url.toString(), 'https://dever.atjog.com/idp/dashboard/security');
      // 必须是绝对地址：相对地址会被移动端 launchUrl 拒绝。
      expect(url!.hasScheme, isTrue);
      expect(url.host, 'dever.atjog.com');
    });

    test('结尾多余斜杠被吃掉（不会拼出 //dashboard）', () {
      final url = SpbEnv.accountSecurityUrlFrom('https://dever.atjog.com/idp/');
      expect(url.toString(), 'https://dever.atjog.com/idp/dashboard/security');
      expect(url.toString(), isNot(contains('//dashboard')));
    });

    test('多个结尾斜杠同样被吃掉', () {
      final url = SpbEnv.accountSecurityUrlFrom(
        'https://dever.atjog.com/idp///',
      );
      expect(url.toString(), 'https://dever.atjog.com/idp/dashboard/security');
    });

    test('本地开发 issuer（含端口）可用', () {
      expect(
        SpbEnv.accountSecurityUrlFrom('http://127.0.0.1:3000/idp').toString(),
        'http://127.0.0.1:3000/idp/dashboard/security',
      );
    });

    test('空 / 全空白 issuer → null（调用方据此不展示入口）', () {
      expect(SpbEnv.accountSecurityUrlFrom(''), isNull);
      expect(SpbEnv.accountSecurityUrlFrom('   '), isNull);
    });

    test('相对地址 → null（不拼出半截路径让人以为入口坏了）', () {
      expect(SpbEnv.accountSecurityUrlFrom('/idp'), isNull);
      expect(SpbEnv.accountSecurityUrlFrom('idp'), isNull);
    });

    test('编译期默认值（未注入时）也拼得出来', () {
      expect(SpbEnv.accountSecurityUrl, isNotNull);
    });
  });
}
