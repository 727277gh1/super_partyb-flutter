import 'package:flutter_test/flutter_test.dart';
import 'package:spb_mobile/router.dart';

/// 认证守卫的纯决策函数测试（与桌面端同构，理由见其测试文件说明）。
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
    fallbackRoute: SpbRoutes.conversations,
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
        resolve(authenticated: false, matched: '/chat/grp_x'),
        '${SpbRoutes.login}?from=%2Fchat%2Fgrp_x',
      );
    });

    test('已在登录页 → 放行', () {
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

    test('停在登录页且无 from → 回落对话列表', () {
      expect(
        resolve(authenticated: true, matched: SpbRoutes.login),
        SpbRoutes.conversations,
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
        SpbRoutes.conversations,
      );
    });

    test('协议相对 URL //evil.com 被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: '//evil.com',
        ),
        SpbRoutes.conversations,
      );
    });

    test('三斜杠 ///evil.com 也被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: '///evil.com',
        ),
        SpbRoutes.conversations,
      );
    });

    test('相对路径被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: 'settings',
        ),
        SpbRoutes.conversations,
      );
    });

    test('空串被拒绝', () {
      expect(
        resolve(authenticated: true, matched: SpbRoutes.login, from: ''),
        SpbRoutes.conversations,
      );
    });

    test('回跳到登录页自身被拒绝', () {
      expect(
        resolve(
          authenticated: true,
          matched: SpbRoutes.login,
          from: SpbRoutes.login,
        ),
        SpbRoutes.conversations,
      );
    });

    test('合法站内路径原样返回', () {
      for (final path in ['/settings', '/chat/grp_x', '/settings/sync']) {
        expect(
          resolve(authenticated: true, matched: SpbRoutes.login, from: path),
          path,
        );
      }
    });
  });
}
