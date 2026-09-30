import 'package:flutter_test/flutter_test.dart';
import 'package:spb_desktop/router.dart';

/// 认证守卫的纯决策函数测试。
///
/// ## 为什么不只靠 widget 测试
///
/// 守卫最终表现为「停在哪个路由」，而 go_router 对**匹配不到任何路由**的
/// 跳转目标会**静默回落**。于是「白名单校验失效，把 `https://evil.com` 放
/// 了过去」与「校验生效，回落到首页」在 widget 测试里表现得**完全一样**
/// （实测：删掉校验后集成测试仍然全绿）。
///
/// 开放重定向是安全边界，必须能被精确断言——这正是 [resolveAuthRedirect]
/// 被抽成纯函数的原因。
void main() {
  String? resolve({
    required bool authenticated,
    String matched = '/settings',
    String? from,
  }) => resolveAuthRedirect(
    authenticated: authenticated,
    matchedLocation: matched,
    fromRaw: from,
    loginRoute: SpbRoutes.login,
    fallbackRoute: SpbRoutes.home,
  );

  group('认证守卫：未认证', () {
    test('非登录页 → 重定向到登录页并带上 from', () {
      expect(
        resolve(authenticated: false, matched: SpbRoutes.settings),
        '${SpbRoutes.login}?from=%2Fsettings',
      );
    });

    test('深链路径也要带 from', () {
      expect(
        resolve(authenticated: false, matched: '/chat/grp_1'),
        '${SpbRoutes.login}?from=%2Fchat%2Fgrp_1',
      );
    });

    test('已在登录页 → 放行（否则会无限重定向）', () {
      expect(resolve(authenticated: false, matched: SpbRoutes.login), isNull);
    });
  });

  group('认证守卫：已认证', () {
    test('停在登录页且 from 合法 → 回跳到 from', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: '/settings',
        ),
        SpbRoutes.settings,
      );
    });

    test('停在登录页且无 from → 回落首页', () {
      expect(
        resolve(authenticated: true, matched: SpbRoutes.login),
        SpbRoutes.home,
      );
    });

    test('非登录页 → 放行', () {
      expect(resolve(authenticated: true, matched: SpbRoutes.settings), isNull);
    });
  });

  group('from 校验（开放重定向防护）', () {
    test('绝对 URL 被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: 'https://evil.com',
        ),
        SpbRoutes.home,
        reason: '绝对 URL 会把登录完成后的用户直接送去钓鱼站',
      );
    });

    test('协议相对 URL //evil.com 被拒绝', () {
      // RFC 3986 §4.2：`//evil.com` 解析结果同样是 `https://evil.com`。
      // 只判「以 / 开头」会把它放过去，必须单独挡。
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: '//evil.com',
        ),
        SpbRoutes.home,
      );
    });

    test('三斜杠 ///evil.com 也被拒绝（前两个斜杠已构成协议相对 URL）', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: '///evil.com',
        ),
        SpbRoutes.home,
      );
    });

    test('相对路径（不以 / 开头）被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: 'settings',
        ),
        SpbRoutes.home,
      );
    });

    test('空串被拒绝', () {
      expect(
        resolve(authenticated: true, matched: SpbRoutes.login, from: ''),
        SpbRoutes.home,
      );
    });

    test('回跳到登录页自身被拒绝（否则构成重定向环）', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: SpbRoutes.login,
        ),
        SpbRoutes.home,
      );
    });

    test('合法站内路径原样返回', () {
      for (final path in ['/settings', '/chat/grp_1', '/settings/sync']) {
        expect(
          resolve(authenticated: true, matched: SpbRoutes.login, from: path),
          path,
        );
      }
    });
  });
}
