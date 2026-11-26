import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_mobile/router.dart';

/// 未登录时在登录页扫码：**先登录、再自动回到确认页**。
///
/// ## 这个测试防的是什么
///
/// 确认端点要 `Authorization: Bearer`，所以「未登录就扫」本来必然 401。
/// 这条链路的可用性完全依赖路由守卫把 `/qr-login?scene=…` 改写成
/// `/login?from=<确认页>`、登录成功后再回跳——三个环节任何一处断了，用户
/// 看到的就是「扫了码，页面没反应」：
///
/// 1. `onQrScanned` 没接到 `go(qrLoginFor(scene))` → 停在登录页且没有 `from`，
///    登录后回首页，那次扫码白扫（浏览器那边一直等到过期）；
/// 2. `from` 丢了 `scene`（比如用 `matchedLocation` 而不是完整目标）→ 登录后
///    到了确认页但不知道要确认哪一次；
/// 3. 提示丢失（登录页被守卫重建、State 被丢弃）→ 用户以为扫失败再扫一次。
///
/// ## 为什么用假 mini router 而不是整套夹具
///
/// 本测试只关心「守卫把位置改到哪、页面还剩什么」，与内容页无关；整套夹具
/// 会连带首屏的网络请求与 SSE。故只挂两个站点：真实 [LoginPage] 与一个
/// 渲染 `QR:<scene>` 的假确认页——断言点依旧是**渲染出来的结果**。
void main() {
  /// 可变的认证状态：`ValueNotifier` 同时充当 `refreshListenable`，
  /// 改值就等于「登录完成」，守卫会重跑。
  AuthState Function() authStateOf(ValueNotifier<AuthState> auth) =>
      () => auth.value;

  GoRouter buildRouter(ValueNotifier<AuthState> auth, FakeQrScanner scanner) {
    return GoRouter(
      initialLocation: SpbRoutes.login,
      redirect: buildAuthRedirect(authState: authStateOf(auth)),
      refreshListenable: auth,
      routes: [
        GoRoute(
          path: SpbRoutes.login,
          builder: (context, state) => LoginPage(
            key: const ValueKey('test-login'),
            state: auth.value,
            onSignIn: () async => null,
            // 扫码与宿主导航都按真实接线来：登录页只回调 scene，
            // 导航由装配层（这里是 mini router）做。
            onScanQr: () => scanner.scan(context),
            onQrScanned: (scene) => context.go(SpbRoutes.qrLoginFor(scene)),
          ),
        ),
        GoRoute(
          path: SpbRoutes.qrLogin,
          builder: (context, state) =>
              Text('QR:${state.uri.queryParameters['scene']}'),
        ),
      ],
    );
  }

  /// 打开登录页并展开「其他登录方式」（扫一扫按钮在那里）。
  Future<void> pumpLogin(WidgetTester tester, GoRouter router) async {
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('login-other-methods')),
    );
    await tester.tap(find.byKey(const ValueKey('login-other-methods')));
    await tester.pumpAndSettle();
  }

  testWidgets('扫到登录码 → 停在登录页并给出「登录后自动确认」提示', (tester) async {
    final auth = ValueNotifier<AuthState>(
      const AuthState(status: AuthStatus.unauthenticated),
    );
    addTearDown(auth.dispose);
    final router = buildRouter(
      auth,
      FakeQrScanner('https://dever.atjog.com/idp/qr/abc123'),
    );
    await pumpLogin(tester, router);

    await tester.tap(find.byKey(const ValueKey('login-scan-button')));
    await tester.pumpAndSettle();

    // 未登录时不能直接进确认页（进去了也只会 401），守卫会把人留在登录页。
    expect(find.text('QR:abc123'), findsNothing);
    // 但必须让用户知道刚才那一下生效了——否则他会以为扫失败又去扫一遍。
    expect(find.byKey(const ValueKey('login-scan-hint')), findsOneWidget);
    expect(find.text('已读到登录码，登录后会自动回到确认页'), findsOneWidget);
    // `from` 必须带着**完整**的确认页地址（含 scene），否则登录回来不知道
    // 要确认哪一次登录。
    expect(router.routeInformationProvider.value.uri.query, contains('from='));
    expect(
      Uri.decodeQueryComponent(
        router.routeInformationProvider.value.uri.queryParameters['from']!,
      ),
      contains('scene=abc123'),
    );
  });

  testWidgets('登录完成后自动回到确认页（scene 未丢）', (tester) async {
    final auth = ValueNotifier<AuthState>(
      const AuthState(status: AuthStatus.unauthenticated),
    );
    addTearDown(auth.dispose);
    final router = buildRouter(
      auth,
      FakeQrScanner('partyb://qrlogin?scene=abc123'),
    );
    await pumpLogin(tester, router);

    await tester.tap(find.byKey(const ValueKey('login-scan-button')));
    await tester.pumpAndSettle();

    // 模拟登录完成（SSO / 微信一键 / 密码任一）：守卫由 refreshListenable 重跑。
    auth.value = const AuthState(status: AuthStatus.authenticated);
    await tester.pumpAndSettle();

    expect(find.text('QR:abc123'), findsOneWidget);
  });

  testWidgets('扫到的不是登录码 → 报错而不是「已读到」', (tester) async {
    final auth = ValueNotifier<AuthState>(
      const AuthState(status: AuthStatus.unauthenticated),
    );
    addTearDown(auth.dispose);
    final router = buildRouter(auth, FakeQrScanner('https://example.com/x'));
    await pumpLogin(tester, router);

    await tester.tap(find.byKey(const ValueKey('login-scan-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-scan-hint')), findsNothing);
  });
}

/// 假相机：`scan` 直接回一段固定文本（null = 用户取消）。
class FakeQrScanner implements QrScanner {
  FakeQrScanner(this.text);

  final String? text;

  @override
  bool get isSupported => true;

  @override
  String? get problem => null;

  @override
  Future<String?> scan(BuildContext context) async => text;
}
