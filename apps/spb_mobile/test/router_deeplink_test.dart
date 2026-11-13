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
        // 扫码登录确认页：用 hint 文本渲染，便于断言「重定向到了确认页」。
        GoRoute(
          path: SpbRoutes.qrLogin,
          builder: (_, state) =>
              Text('QR:${state.uri.queryParameters['scene']}'),
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

  group('扫码登录深链', () {
    testWidgets('已登录 → 直接落到确认页（不能被「外部入口」分支送去首页）', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.authenticated),
          initialLocation: 'partyb://qrlogin?scene=abc-123',
        ),
      );

      // WHY 断言 scene 而不是只断言页面：丢了 scene 就等于「用户点了链接但
      // 确认页不知道要确认哪一次登录」，界面上是一句话说不清的失败。
      expect(find.text('QR:abc-123'), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(find.text(errorPageTitle), findsNothing);
    });

    testWidgets('claimed HTTPS 形态同样落到确认页', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.authenticated),
          initialLocation: 'https://dever.atjog.com/idp/qr/scene_https',
        ),
      );

      expect(find.text('QR:scene_https'), findsOneWidget);
    });

    testWidgets('未登录 → 先去登录页，并记住确认页作为回跳目标', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: const AuthState(status: AuthStatus.unauthenticated),
          initialLocation: 'partyb://qrlogin?scene=abc-123',
        ),
      );

      expect(find.text('LOGIN'), findsOneWidget);
      // from 必须带上 scene：登录完成后才能回到同一个确认页（否则登录完
      // 用户回到对话列表，浏览器的二维码已经过期）。
      final location = GoRouter.of(tester.element(find.text('LOGIN'))).state.uri
          .toString();
      expect(location, contains('from='));
      expect(Uri.decodeComponent(location), contains('scene=abc-123'));
    });

    testWidgets('已锁定 → 先过门禁（深链不能绕过锁屏）', (tester) async {
      await pumpApp(
        tester,
        app(
          auth: AuthState.locked,
          initialLocation: 'partyb://qrlogin?scene=abc-123',
        ),
      );

      expect(find.text('QR:abc-123'), findsNothing);
    });
  });

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
