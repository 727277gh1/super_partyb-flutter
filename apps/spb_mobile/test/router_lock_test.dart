import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

/// 路由守卫对 `locked` 的处理（issue #94）。
///
/// ## 这个测试防的是什么
///
/// 门禁的**唯一**入口是路由守卫：只要守卫漏掉 `AuthStatus.locked`，内容页就
/// 会在锁屏页被绕过的情况下直接渲染（比如冷启动时 `_bootstrap` 判完锁定，
/// 而守卫把 locked 当成「未认证」，用户看到的是登录页——功能看起来没生效，
/// 却把「去 /lock 验证」这条路彻底堵死了）。
///
/// ## 为什么不用 `pumpApp` 夹具
///
/// 门禁与首页内容无关，而首页首次挂载就会连发数条网络请求与 SSE。这里用只有
/// 三个假站点的 router：断言点是「守卫把位置改到哪」，渲染什么内容不重要。
void main() {
  /// 只含 `/`、`/lock`、`/login` 的假路由表。
  GoRouter buildRouter(ProviderContainer container) {
    return GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const Text('home')),
        GoRoute(path: '/lock', builder: (context, state) => const Text('lock')),
        GoRoute(
          path: '/login',
          builder: (context, state) => const Text('login'),
        ),
      ],
      redirect: buildAuthRedirect(),
      refreshListenable: container.read(authRefreshListenableProvider),
    );
  }

  Future<ProviderContainer> pumpRouter(
    WidgetTester tester, {
    required bool lockEnabled,
    bool hasToken = true,
    FakeGate? gate,
  }) async {
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(
          InMemoryTokenStore(
            hasToken
                ? StoredTokens(
                    accessToken: 'at_test',
                    expiresAt: DateTime.now().toUtc().add(
                      const Duration(days: 1),
                    ),
                  )
                : null,
          ),
        ),
        biometricGateProvider.overrideWithValue(gate ?? FakeGate()),
        biometricLockEnabledProvider.overrideWith((ref) async => lockEnabled),
      ],
    );
    addTearDown(container.dispose);
    final router = buildRouter(container);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // 启动判定是异步的：多泵几帧让 `_bootstrap` 完成并触发守卫重跑。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    return container;
  }

  testWidgets('有凭证 + 门禁开启 → 守卫把人送到 /lock（而不是内容页）', (tester) async {
    await pumpRouter(tester, lockEnabled: true);

    expect(find.text('lock'), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(find.text('login'), findsNothing);
  });

  testWidgets('解锁成功 → 守卫放行回内容页', (tester) async {
    final gate = FakeGate();
    await pumpRouter(tester, lockEnabled: true, gate: gate);
    expect(find.text('lock'), findsOneWidget);
    expect(gate.authCalls, 0, reason: '锁屏页在假站点里没挂，不该自动验证');

    final outcome = await tester.runAsync(
      () => gate.authenticate(reason: '解锁'),
    );
    expect(outcome, BiometricAuthOutcome.success);

    // 直接推进状态，模拟锁屏页解锁成功（真页面见 `auth_lock_test.dart`）。
    final container = tester
        .widget<UncontrolledProviderScope>(
          find.byType(UncontrolledProviderScope),
        )
        .container;
    await tester.runAsync(
      () => container.read(authControllerProvider).unlock(),
    );
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('lock'), findsNothing);
  });

  testWidgets('门禁关闭 → 有凭证直接进内容页', (tester) async {
    await pumpRouter(tester, lockEnabled: false);

    expect(find.text('home'), findsOneWidget);
    expect(find.text('lock'), findsNothing);
  });

  testWidgets('没有凭证 → 去登录页（不是锁屏页）', (tester) async {
    await pumpRouter(tester, lockEnabled: true, hasToken: false);

    expect(find.text('login'), findsOneWidget);
    expect(find.text('lock'), findsNothing);
  });
}

/// 恒通过的假门禁。
class FakeGate implements BiometricGate {
  int authCalls = 0;

  @override
  Future<BiometricAvailability> availability() async =>
      BiometricAvailability.available;

  @override
  Future<BiometricAuthOutcome> authenticate({
    required String reason,
    bool allowDeviceCredential = true,
  }) async {
    authCalls++;
    return BiometricAuthOutcome.success;
  }
}
