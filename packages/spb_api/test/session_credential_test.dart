import 'package:test/test.dart';

import 'package:spb_api/spb_api.dart';

/// `parseSessionCredential` 的纯函数测试。
///
/// ## 这个测试防的是什么
///
/// SSO 在系统浏览器完成，Flutter 进程读不到浏览器 Cookie，
/// **粘贴导入是唯一的登录闭环入口**。解析失败的表现是「粘贴了但没反应」，
/// 用户无从判断是自己贴错了还是程序坏了——故每种输入形态都要有明确断言。
///
/// ## 凭证是假值
///
/// 这里用的 token 都是 `test-*` 字面量。真实凭证绝不出现在测试里
/// （测试文件会进版本库）。
void main() {
  group('导入会话：接受的输入形态', () {
    test('完整 Cookie 头（DevTools「复制为 Cookie」的形态）', () {
      final t = parseSessionCredential(
        'Cookie: id_token=test-id-token; refresh_token=test-refresh-token',
      );

      expect(t, isNotNull);
      expect(t!.accessToken, 'test-id-token');
      expect(t.refreshToken, 'test-refresh-token');
    });

    test('裸键值对（无 Cookie: 前缀）', () {
      final t = parseSessionCredential(
        'id_token=test-id-token; refresh_token=test-refresh-token',
      );

      expect(t!.accessToken, 'test-id-token');
      expect(t.refreshToken, 'test-refresh-token');
    });

    test('Authorization 头（Bearer 前缀被剥掉）', () {
      final t = parseSessionCredential('Authorization: Bearer test-id-token');

      expect(t, isNotNull);
      expect(
        t!.accessToken,
        'test-id-token',
        reason: 'Bearer 前缀必须被剥掉，否则会拼出 "Bearer Bearer …"',
      );
    });

    test('裸 token（用户从别处手抄）', () {
      final t = parseSessionCredential('test-bare-token');

      expect(t!.accessToken, 'test-bare-token');
    });

    test('只给 access_token 也可用（网关同时接受 id/access token）', () {
      final t = parseSessionCredential('access_token=test-access-token');

      expect(t!.accessToken, 'test-access-token');
      expect(t.refreshToken, isNull);
    });

    test('多行（DevTools 多行 cookie 视图）', () {
      final t = parseSessionCredential(
        'id_token=test-id-token\nrefresh_token=test-refresh-token\n',
      );

      expect(t!.accessToken, 'test-id-token');
      expect(t.refreshToken, 'test-refresh-token');
    });

    test('带引号的 cookie 值', () {
      final t = parseSessionCredential('id_token="test-id-token"');

      expect(t!.accessToken, 'test-id-token');
    });

    test('百分号编码的值被解码', () {
      final t = parseSessionCredential('id_token=test%2Did%2Dtoken');

      expect(t!.accessToken, 'test-id-token');
    });

    test('Set-Cookie 前缀也被剥离', () {
      final t = parseSessionCredential(
        'Set-Cookie: id_token=test-id-token; Path=/; HttpOnly',
      );

      expect(t!.accessToken, 'test-id-token');
      expect(t.refreshToken, isNull, reason: 'Path/HttpOnly 不是凭证字段');
    });
  });

  group('导入会话：拒绝的输入', () {
    test('空串', () {
      expect(parseSessionCredential(''), isNull);
      expect(parseSessionCredential('   \n  '), isNull);
    });

    test('只有无关键（无 id_token / access_token）', () {
      expect(
        parseSessionCredential('session_id=abc; csrf=def'),
        isNull,
        reason: '没有可用 token 时必须报「认不出」，不能造一个空凭证',
      );
    });

    test('键存在但值为空', () {
      expect(parseSessionCredential('id_token=; refresh_token='), isNull);
    });

    test('只有 refresh_token（无法用它直接认证）', () {
      expect(
        parseSessionCredential('refresh_token=test-refresh-token'),
        isNull,
        reason: 'refresh_token 不能当 Bearer 用，必须报错而不是落盘一个无效凭证',
      );
    });
  });

  group('导入会话：字段语义', () {
    test('id_token 与 access_token 同时存在时优先 id_token', () {
      // 网关的 OIDC 认证器验证的是 ID Token，Cookie 注入路径读的也是
      // id_token cookie，故两者都在时以 id_token 为准。
      final t = parseSessionCredential(
        'access_token=test-access-token; id_token=test-id-token',
      );

      expect(t!.accessToken, 'test-id-token');
    });

    test('expiresAt 为 null（不猜过期时间，交给服务端 401 驱动刷新）', () {
      final t = parseSessionCredential('id_token=test-id-token');

      expect(t!.expiresAt, isNull);
      expect(t.isExpired(), isFalse, reason: '无 expiresAt 时视为未过期，凭证必须被真正使用');
    });

    test('键名大小写不敏感', () {
      final t = parseSessionCredential('ID_TOKEN=test-id-token');

      expect(t!.accessToken, 'test-id-token');
    });

    test('同名键重复时取第一个（旧域残留 cookie 不该覆盖当前会话）', () {
      final t = parseSessionCredential(
        'id_token=test-first; id_token=test-second',
      );

      expect(t!.accessToken, 'test-first');
    });

    test('token 值里的点号与连字符不被切坏（base64url 字符集）', () {
      const jwtLike = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c3JfMSJ9.sig-part';
      final t = parseSessionCredential('id_token=$jwtLike');

      expect(t!.accessToken, jwtLike);
    });
  });
}
