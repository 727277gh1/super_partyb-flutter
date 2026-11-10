import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_mobile/router.dart';

/// 外部深链不能被当成站内路由。
///
/// ## 这个文件防的是什么
///
/// 登录回调（`partyb://oidc/callback?code=...`）由 `app_links` 交给
/// `AuthDeepLinkReceiver` 处理，但 Flutter 引擎**同时**把同一个 intent 推给
/// `Router`。没有拦截时 go_router 渲染默认错误页（标题 `Page Not Found` +
/// `GoException: no routes for location: partyb://...`），用户看到的是
/// 「扫码登录完先报错，退回首页才发现其实已登录」。
///
/// 断言面选**渲染出来的页面**而不是「有没有抛异常」：go_router 把匹配失败
/// 转成错误页而不是抛出，只看异常/日志会让这个 bug 静默通过。
void main() {
  Widget app({required AuthState auth, required String initialLocation}) {
    final router = GoRouter(
      initialLocation: initialLocation,
      redirect: buildAuthRedirect(authState: () => auth),
      routes: [
        GoRoute(path: SpbRoutes.login, builder: (_, _) => const Text('LOGIN')),
        GoRoute(
          path: SpbRoutes.conversations,
          builder: (_, _) => const Text('HOME'),
        ),
        GoRoute(
          path: SpbRoutes.settings,
          builder: (_, _) => const Text('SETTINGS'),
        ),
      ],
    );
    addTearDown(router.dispose);
    return MaterialApp.router(routerConfig: router);
  }

  Future<void> pumpApp(WidgetTester tester, Widget widget) async {
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  /// go_router 的默认错误页标题（`MaterialErrorScreen`）。
  const errorPageTitle = 'Page Not Found';

  group('OIDC 回调深链', () {
    testWidgets('冷启动（会话未判定）→ 登录页，不渲染 go_router 错误页', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(),
          initialLocation: 'partyb://oidc/callback?code=c_1&state=s_1',
        ),
      );

      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.text(errorPageTitle), findsNothing);
    });

    testWidgets('未登录 → 登录页（等回调换 token 完成后由守卫送出）', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.unauthenticated),
          initialLocation: 'partyb://oidc/callback?code=c_1&state=s_1',
        ),
      );

      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.text(errorPageTitle), findsNothing);
    });

    testWidgets('已登录（旧回调链接被重复点开）→ 首页，而不是停在登录页', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.authenticated),
          initialLocation: 'partyb://oidc/callback?code=c_1&state=s_1',
        ),
      );

      expect(find.text('HOME'), findsOneWidget);
      expect(find.text(errorPageTitle), findsNothing);
    });

    testWidgets('同 scheme 的其它深链也不进路由表', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.authenticated),
          initialLocation: 'partyb://share/evil?code=c_evil',
        ),
      );

      expect(find.text('HOME'), findsOneWidget);
      expect(find.text(errorPageTitle), findsNothing);
    });
  });

  testWidgets('站内路径不受影响：未登录仍带 from 去登录页', (tester) async {
    await pumpApp(
      tester,
      app(
        auth: const AuthState(status: AuthStatus.unauthenticated),
        initialLocation: SpbRoutes.settings,
      ),
    );

    expect(find.text('LOGIN'), findsOneWidget);
  });
}
