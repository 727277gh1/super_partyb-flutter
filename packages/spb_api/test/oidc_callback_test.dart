import 'package:test/test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// OIDC 回调地址的**两种形态**都必须被识别，且必须拒绝近似地址。
///
/// ## 为什么这组断言值得存在
///
/// 回调地址判定错了不会报错，只会表现为「登录后应用毫无反应」：链接被系统
/// 交给浏览器、或交进来了但被 `matches` 过滤掉。两种情况的用户感受完全一样，
/// 所以这里把「认什么 / 不认什么」逐条钉死。
void main() {
  const expectedState = 'st-123';
  final issuer = Uri.parse('https://tbcc.atjog.com/idp');

  group('自定义 scheme 形态', () {
    test('标准地址命中', () {
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://oidc/callback')),
        isTrue,
      );
    });

    test('结尾斜杠容错', () {
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://oidc/callback/')),
        isTrue,
      );
    });

    test('带 query 的回调命中（真实回调必然带 code/state）', () {
      expect(
        OidcCallbackUri.matches(
          Uri.parse('partyb://oidc/callback?code=c1&state=st-123'),
        ),
        isTrue,
      );
    });

    test('同 scheme 不同 host/path 一律拒绝', () {
      for (final raw in [
        'partyb://share/evil?code=c1&state=st-123',
        'partyb://oidc/other',
        'partyb://oidc/callbackx',
        'partyb://evil/callback',
      ]) {
        expect(
          OidcCallbackUri.matches(Uri.parse(raw)),
          isFalse,
          reason: '$raw 不应被当成 OIDC 回调',
        );
      }
    });
  });

  group('claimed HTTPS 形态', () {
    test('issuer + /app/callback 命中', () {
      expect(
        OidcCallbackUri.matches(
          Uri.parse(
            'https://tbcc.atjog.com/idp/app/callback?code=c1&state=st-123',
          ),
          issuer: issuer,
        ),
        isTrue,
      );
    });

    test('结尾斜杠容错', () {
      expect(
        OidcCallbackUri.matches(
          Uri.parse('https://tbcc.atjog.com/idp/app/callback/'),
          issuer: issuer,
        ),
        isTrue,
      );
    });

    test('issuer 带结尾斜杠时也一致', () {
      expect(
        OidcCallbackUri.matches(
          Uri.parse('https://tbcc.atjog.com/idp/app/callback'),
          issuer: Uri.parse('https://tbcc.atjog.com/idp/'),
        ),
        isTrue,
      );
    });

    test('换域名（双栈/staging）跟着 issuer 走，不硬编码', () {
      expect(
        OidcCallbackUri.matches(
          Uri.parse('https://tbcc6.atjog.com/idp/app/callback'),
          issuer: Uri.parse('https://tbcc6.atjog.com/idp'),
        ),
        isTrue,
      );
      // 但 issuer 是 tbcc 时，tbcc6 不算命中——回调只会从 issuer 那个域名回来。
      expect(
        OidcCallbackUri.matches(
          Uri.parse('https://tbcc6.atjog.com/idp/app/callback'),
          issuer: issuer,
        ),
        isFalse,
      );
    });

    test('域名不符 / 路径不符 / scheme 不符一律拒绝', () {
      for (final raw in [
        'https://evil.example/idp/app/callback', // 域名不符
        'https://tbcc.atjog.com/idp/other', // 路径不符
        'https://tbcc.atjog.com/app/callback', // 少了 basePath
        'http://tbcc.atjog.com/idp/app/callback', // scheme 不符
        'https://tbcc.atjog.com/idp/app/callbackx',
      ]) {
        expect(
          OidcCallbackUri.matches(Uri.parse(raw), issuer: issuer),
          isFalse,
          reason: '$raw 不应被当成 OIDC 回调',
        );
      }
    });
  });

  group('parse：两种形态都能取出 code/state', () {
    test('自定义 scheme', () {
      final r = OidcCallbackUri.parse(
        Uri.parse('partyb://oidc/callback?code=abc&state=$expectedState'),
        expectedState: expectedState,
      );
      expect(r.code, 'abc');
      expect(r.state, expectedState);
    });

    test('claimed HTTPS', () {
      final r = OidcCallbackUri.parse(
        Uri.parse(
          'https://tbcc.atjog.com/idp/app/callback?code=abc&state=$expectedState',
        ),
        expectedState: expectedState,
        issuer: issuer,
      );
      expect(r.code, 'abc');
      expect(r.state, expectedState);
    });

    test('state 不匹配仍抛错（两种形态同一套校验）', () {
      expect(
        () => OidcCallbackUri.parse(
          Uri.parse(
            'https://tbcc.atjog.com/idp/app/callback?code=abc&state=other',
          ),
          expectedState: expectedState,
          issuer: issuer,
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('非本应用回调抛错，且错误信息不含 code', () {
      try {
        OidcCallbackUri.parse(
          Uri.parse(
            'https://evil.example/idp/app/callback?code=SECRET&state=s',
          ),
          expectedState: 's',
          issuer: issuer,
        );
        fail('应当抛 AuthError');
      } on AuthError catch (e) {
        expect(e.message, contains('不是本应用的 OIDC 回调地址'));
        expect(e.message, isNot(contains('SECRET')));
      }
    });
  });

  test('claimedHttpsRedirectUri 由 issuer 推导', () {
    expect(
      OidcCallbackUri.claimedHttpsRedirectUri(issuer: issuer).toString(),
      'https://tbcc.atjog.com/idp/app/callback',
    );
    // 编译期缺省值同样可推导（默认 issuer 是本地 IdP）。
    expect(
      OidcCallbackUri.claimedHttpsRedirectUri()?.path,
      endsWith(OidcCallbackUri.claimedHttpsPath),
    );
  });
}
