import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 桌面端「无过渡」与远端会话动效降级（issue #110 / §6.96）。
///
/// ## 这组用例防的是什么
///
/// 远程桌面（RDP）里只有 WARP 软件光栅：单帧 20–40ms。而 Windows 默认的
/// `ZoomPageTransitionsBuilder` 让**每一帧**都脏整个窗口（进入/退出页各一次
/// 整页离屏快照 + 每帧全窗缩放/混合），而这条过渡在 Windows 上是 450ms——
/// 用户看到的就是「点一下先顿，然后画面直接跳过去」。
///
/// 这个缺陷**不会让任何既有用例变红**：页面测试自己构造路由，关心不到过渡；
/// 而路由测试只断言「落到了哪个页面」。故这里用两个可断言的量把结论钉住：
///
/// 1. 路由表里**每一条**页面路由都必须是 `pageBuilder`（`builder:` 会拿到
///    默认的 450ms 缩放过渡，实测值）；
/// 2. 真实推入的 `PageRoute.transitionDuration` 必须是 `Duration.zero`
///    （`NoTransitionPage` 的定义就是它）。
///
/// 反向验证：把任意一条路由改回 `builder:`，用例 1 立刻红；把 `desktopPage`
/// 换成 `MaterialPage`，用例 2 拿到 450ms 而红。
void main() {
  group('桌面路由：零时长页面（无全窗过渡）', () {
    /// 递归收集路由树里的所有 [GoRoute]。
    List<GoRoute> collectGoRoutes(List<RouteBase> routes) {
      final out = <GoRoute>[];
      for (final route in routes) {
        if (route is GoRoute) {
          out.add(route);
          out.addAll(collectGoRoutes(route.routes));
        }
      }
      return out;
    }

    test('每一条页面路由都用 pageBuilder，且没有任何 builder', () {
      final routes = collectGoRoutes(buildDesktopRoutes());
      expect(routes, isNotEmpty, reason: '路由表空说明收集逻辑坏了，不是产品结论');

      for (final route in routes) {
        expect(
          route.builder,
          isNull,
          reason:
              '`${route.path}` 用了 `builder:`——go_router 会生成 MaterialPage，'
              '在 Windows 上拿到 ZoomPageTransitionsBuilder（整页快照 + 每帧'
              '整窗缩放混合）。请改用 `pageBuilder: desktopPage(...)`'
              '（issue #110）。',
        );
        // 纯重定向路由（`/settings/sync`）本来就没有页面；其余必须有。
        if (route.pageBuilder == null) {
          expect(
            route.redirect,
            isNotNull,
            reason:
                '`${route.path}` 既没有 pageBuilder 也没有 redirect——这条路由永远渲染不出东西',
          );
        }
      }
    });

    testWidgets('推入的路由 transitionDuration 为 0（真的不播过渡）', (tester) async {
      final spy = _RouteSpy();
      final h = await pumpApp(tester, observer: spy);

      // 首个页面（未登录 → /login 重定向）也必须是零时长：否则应用启动的
      // 第一帧就是一次全窗过渡。
      expect(spy.pushed, isNotEmpty);
      _expectZeroTransition(spy.pushed.first, '首个页面');

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();
      _expectZeroTransition(spy.pushed.last, SpbRoutes.settings);

      // 换对话同样是一次新的 pageKey（go_router 按 location 生成），故这条
      // 也要零时长——侧边栏切对话是最高频的整窗重绘来源。
      h.router.go(SpbRoutes.chat('grp_1'));
      await tester.pumpAndSettle();
      _expectZeroTransition(spy.pushed.last, SpbRoutes.chat('grp_1'));
    });
  });

  group('远端会话（RDP）：关掉常驻动效', () {
    testWidgets('remoteSession=true → 子树 MediaQuery.disableAnimations 为 true', (
      tester,
    ) async {
      await pumpApp(tester, remoteSession: true);

      expect(
        _disableAnimationsAtPage(tester),
        isTrue,
        reason:
            '远端会话下 spinner / 流式光标 / 刻度条过渡都必须停在稳态：'
            'WARP 下每帧都要 CPU 光栅 + 跨设备回读，常驻动画就是「一直有帧要传」',
      );
    });

    testWidgets('remoteSession=false → 不覆盖系统设置（保持关闭）', (tester) async {
      await pumpApp(tester);

      expect(
        _disableAnimationsAtPage(tester),
        isFalse,
        reason: '本地会话不该替用户关掉动画——降级只针对远端会话',
      );
    });

    testWidgets('系统已开启「减少动效」→ 保持 true（不因本地会话而复位）', (tester) async {
      // 引擎会把 Windows「减少动效」/ iOS「减弱动态效果」映射到
      // `disableAnimations`。这条钉住「我们只做加法」：本地会话时不能把它
      // 改回 false。
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      await pumpApp(tester);

      expect(_disableAnimationsAtPage(tester), isTrue);
    });
  });
}

/// 读**路由层**（即 `MaterialApp.builder` 之下、页面之上）的 `disableAnimations`。
///
/// 用页面自身的 context 而不是 `tester` 的根 context：后者在 `builder`
/// **之上**，读到的是引擎注入的原值——那会让「覆写是否生效」永远测不出来。
/// 取 `Navigator` 是因为它的 context 恰好在 builder 与页面之间，且**与当前
/// 落在哪个页面无关**（未登录时落点会随认证状态变化，绑页面会很脆）。
bool _disableAnimationsAtPage(WidgetTester tester) {
  return MediaQuery.disableAnimationsOf(
    tester.element(find.byType(Navigator).first),
  );
}

/// 断言这条路由不播任何过渡。
void _expectZeroTransition(Route<dynamic> route, String label) {
  expect(
    route,
    isA<PageRoute<dynamic>>(),
    reason: '$label 不是 PageRoute——路由表形态变了，这条断言的前提失效',
  );
  final page = route as PageRoute<dynamic>;
  expect(
    page.transitionDuration,
    Duration.zero,
    reason:
        '$label 有 ${page.transitionDuration} 的推入过渡：'
        'RDP 下就是「点一下顿住再跳」（issue #110）',
  );
  expect(
    page.reverseTransitionDuration,
    Duration.zero,
    reason: '$label 有返回过渡（返回上一步同样会整窗重绘）',
  );
}

/// 记录推入过的路由（路由对象由 Navigator 持有，只能从事件里拿）。
class _RouteSpy extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}
