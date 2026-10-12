import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_desktop/desktop_integration.dart';
import 'package:spb_desktop/router.dart';
import 'package:spb_platform/spb_platform.dart';

/// 接线桩：同时实现能力接口与两个接线接口。
///
/// ## 为什么不用 `NoopDesktopCapabilities`
///
/// Noop 不实现 [WindowDisplayTarget]/[TrayActionTarget]（它没有事件可抛），
/// 故 `attach` 会跳过。本桩存在的意义正是验证「实现了接线接口时会发生什么」。
class _WiringCapabilities
    implements
        DesktopCapabilities,
        WindowDisplayTarget,
        TrayActionTarget,
        OverlayWindowController {
  @override
  bool get isSupported => true;

  void Function(WindowRole role)? showCallback;
  void Function(WindowRole role)? hideCallback;

  @override
  set onShowWindow(void Function(WindowRole role)? callback) =>
      showCallback = callback;

  @override
  set onHideWindow(void Function(WindowRole role)? callback) =>
      hideCallback = callback;

  // ---- TrayActionTarget ----
  List<TrayMenuItem>? trayMenu;
  final trayActions = <String, void Function()>{};

  @override
  bool trayAvailable = true;

  bool? hideOnClose;

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async => trayMenu = items;

  @override
  void registerTrayAction(String id, void Function() action) =>
      trayActions[id] = action;

  @override
  void setHideOnClose(bool value) => hideOnClose = value;

  // ---- OverlayWindowController ----
  final enteredSpecs = <WindowSpec>[];
  int exitCalls = 0;

  /// 手动指定「进入是否成功」。
  bool enterSucceeds = true;

  bool _overlayActive = false;

  @override
  bool get isOverlayModeActive => _overlayActive;

  @override
  Future<bool> enterOverlayMode(WindowSpec spec) async {
    if (_overlayActive) return true;
    enteredSpecs.add(spec);
    if (!enterSucceeds) return false;
    _overlayActive = true;
    return true;
  }

  @override
  Future<void> exitOverlayMode() async {
    if (!_overlayActive) return;
    _overlayActive = false;
    exitCalls++;
  }

  // ---- 被托盘菜单触发的动作 ----
  final shown = <WindowRole>[];

  @override
  Future<void> showWindow(WindowRole role) async => shown.add(role);

  // ---- 其余能力（本测试不关心） ----
  @override
  Future<void> initialize() async {}
  @override
  Future<void> hideWindow(WindowRole role) async {}
  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async => true;
  @override
  Future<void> unregisterHotkey(String id) async {}
  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;
  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}
  @override
  Future<void> setTrayTooltip(String tooltip) async {}
  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<bool> revealPath(String path) async => false;
  @override
  Future<bool> openFile(String path) async => false;
  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async => DiagnosticsExportOutcome.unsupported;
  @override
  Future<void> dispose() async {}
}

/// 只实现能力接口的桩（模拟 Noop：无可接线点）。
class _PlainCapabilities implements DesktopCapabilities {
  @override
  bool get isSupported => false;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> showWindow(WindowRole role) async {}
  @override
  Future<void> hideWindow(WindowRole role) async {}
  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async => false;
  @override
  Future<void> unregisterHotkey(String id) async {}
  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;
  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}
  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}
  @override
  Future<void> setTrayTooltip(String tooltip) async {}
  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<bool> revealPath(String path) async => false;
  @override
  Future<bool> openFile(String path) async => false;
  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async => DiagnosticsExportOutcome.unsupported;
  @override
  Future<void> dispose() async {}
}

/// 构造一个只含「空壳页面」的 router。
///
/// ## 为什么不用 `createDesktopRouter`
///
/// 真实 router 的页面会发网络请求、读 Provider，把「导航是否发生」这件事
/// 埋在无关的失败里。用空壳页面后，断言可以纯粹针对**路径**。
GoRouter _testRouter({String initialLocation = SpbRoutes.home}) {
  Widget stub(String label) => Scaffold(body: Center(child: Text(label)));

  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: SpbRoutes.home, builder: (_, _) => stub('home')),
      GoRoute(path: SpbRoutes.settings, builder: (_, _) => stub('settings')),
      GoRoute(path: SpbRoutes.sync, builder: (_, _) => stub('sync')),
      GoRoute(path: SpbRoutes.overlay, builder: (_, _) => stub('overlay')),
    ],
  );
}

/// 记录 build 次数的页面（用于验证「没有发生重复导航」）。
class _CountingPage extends StatefulWidget {
  const _CountingPage({required this.onBuild});

  final VoidCallback onBuild;

  @override
  State<_CountingPage> createState() => _CountingPageState();
}

class _CountingPageState extends State<_CountingPage> {
  @override
  void initState() {
    super.initState();
    widget.onBuild();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('overlay')));
}

void main() {
  group('attach', () {
    testWidgets('实现接线接口时接上回调并推送托盘菜单', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();

      expect(integration.isAttached, isTrue);
      expect(caps.showCallback, isNotNull);
      expect(caps.hideCallback, isNotNull);

      // 托盘菜单必须含全部动作项 + 分隔线。
      await tester.pump();
      expect(caps.trayMenu, isNotNull);
      expect(
        caps.trayMenu!.map((e) => e.id).where((id) => !id.startsWith('__')),
        containsAll(<String>[
          TrayActionIds.show,
          TrayActionIds.quickCapture,
          TrayActionIds.syncNow,
          TrayActionIds.openSyncDir,
          TrayActionIds.syncSettings,
          TrayActionIds.quit,
        ]),
      );
      // 分隔线没有回调（它的 id 是哨兵值），故只断言**可点击项**都注册了回调。
      final actionable = caps.trayMenu!
          .where((e) => e.type != TrayMenuItemType.separator)
          .map((e) => e.id);
      expect(caps.trayActions.keys, containsAll(actionable));
    });

    testWidgets('能力不支持接线接口时跳过（不抛异常）', (tester) async {
      final caps = _PlainCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();

      expect(integration.isAttached, isFalse);
    });

    testWidgets('attach 幂等（重复调用只生效一次）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      DesktopIntegration(capabilities: caps, router: router)
        ..attach()
        ..attach()
        ..attach();

      await tester.pump();
      // 回调被覆盖三次仍是同一个（无重复注册的副作用）。
      // 6 = 显示 / 快速输入 / 立即同步 / 打开同步目录 / 同步设置 / 退出。
      expect(caps.showCallback, isNotNull);
      expect(caps.trayActions, hasLength(6));
    });

    testWidgets('detach 摘除回调', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();
      expect(caps.showCallback, isNotNull);

      integration.detach();
      expect(caps.showCallback, isNull);
      expect(caps.hideCallback, isNull);
    });
  });

  group('窗口角色 → 路由映射', () {
    testWidgets('quickCapture → /overlay', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.overlay);
      expect(find.text('overlay'), findsOneWidget);
    });

    testWidgets('settings → /settings', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.settings);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
    });

    testWidgets('main → /', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.overlay);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.main);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.home);
    });

    testWidgets('已在目标路由时不重复导航（避免清掉输入草稿）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.overlay);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      // 用一个**有状态**的桩页面记录它被创建的次数。
      //
      // ## 为什么用「重建次数」而不是 router 监听器
      //
      // `GoRouter` 不是 `Listenable`（没有 addListener），无法直接观察导航。
      // 而「同路径重复 go 会重建页面」正是本测试要防的**后果**——故直接测后果：
      // 页面 State 被重新 initState 的次数。若真的重复导航，计数会 > 1。
      var builds = 0;
      final countingRouter = GoRouter(
        initialLocation: SpbRoutes.overlay,
        routes: [
          GoRoute(
            path: SpbRoutes.overlay,
            builder: (_, _) => _CountingPage(onBuild: () => builds++),
          ),
          GoRoute(
            path: SpbRoutes.home,
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
        ],
      );
      addTearDown(countingRouter.dispose);

      final countingCaps = _WiringCapabilities();
      DesktopIntegration(
        capabilities: countingCaps,
        router: countingRouter,
      ).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: countingRouter));
      await tester.pumpAndSettle();
      final buildsAfterFirstFrame = builds;

      // 已在 /overlay，再请求显示悬浮窗应**不**导航。
      countingCaps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(countingRouter.state.uri.path, SpbRoutes.overlay);
      expect(builds, buildsAfterFirstFrame, reason: '同路径重复 go 会重建页面并清空输入草稿');
    });

    testWidgets('hideWindow(main) 不导航（主窗口不该被隐藏）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.settings);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.hideCallback!(WindowRole.main);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
    });

    testWidgets('hideWindow(quickCapture) 会还原窗口（否则主界面挤在小置顶窗里）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      expect(caps.isOverlayModeActive, isTrue);

      caps.hideCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.home);
      expect(
        caps.isOverlayModeActive,
        isFalse,
        reason: '只导航不还原的话，窗口会一直保持 720x360 置顶且再也放不大',
      );
    });

    testWidgets('hideWindow(quickCapture) 回到主界面', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.overlay);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.hideCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.home);
    });
  });

  group('悬浮窗形态切换', () {
    testWidgets('显示悬浮窗 → 进入悬浮形态（用带附件的规格）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(caps.enteredSpecs, hasLength(1));
      // 必须是**带附件**的规格：纯文本规格只有 132px 高，装不下附件 chip。
      expect(caps.enteredSpecs.single.role, WindowRole.quickCapture);
      expect(caps.enteredSpecs.single.height, greaterThan(200));
      expect(caps.isOverlayModeActive, isTrue);
    });

    testWidgets('重复显示悬浮窗 → 只进入一次（不重复保存窗口快照）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      // 第二次：已在该路由，导航会跳过；窗口形态也不该重复进入。
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(
        caps.enteredSpecs,
        hasLength(1),
        reason: '重复进入会把悬浮态本身当成「原状态」，退出时还原成小窗口',
      );
    });

    testWidgets('从悬浮窗切到设置 → 还原窗口（否则设置页挤在 720x360）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      expect(caps.isOverlayModeActive, isTrue);

      caps.showCallback!(WindowRole.settings);
      await tester.pumpAndSettle();

      expect(caps.isOverlayModeActive, isFalse);
      expect(caps.exitCalls, 1);
      expect(router.state.uri.path, SpbRoutes.settings);
    });

    testWidgets('从悬浮窗切到主界面 → 也还原窗口', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      caps.showCallback!(WindowRole.main);
      await tester.pumpAndSettle();

      expect(caps.isOverlayModeActive, isFalse);
      expect(router.state.uri.path, SpbRoutes.home);
    });

    testWidgets('进入悬浮形态失败 → 仍导航，但记警告', (tester) async {
      final caps = _WiringCapabilities()..enterSucceeds = false;
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      // 窗口没切成，但页面必须显示（否则用户按 Alt+Space 毫无反应）。
      expect(router.state.uri.path, SpbRoutes.overlay);
    });

    testWidgets('leaveOverlay 在未进入时是空操作（Esc 与提交都会调）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();

      // 从未进入悬浮模式就调用（如用户直接访问 /overlay 调试入口）。
      await integration.leaveOverlay();
      expect(caps.exitCalls, 0);
    });

    testWidgets('leaveOverlay 能还原（供悬浮窗页面提交/Esc 时调用）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      expect(caps.isOverlayModeActive, isTrue);

      await integration.leaveOverlay();

      expect(caps.isOverlayModeActive, isFalse);
      expect(caps.exitCalls, 1);
    });
  });

  group('托盘菜单回调', () {
    testWidgets('「快速输入」项触发 showWindow(quickCapture)', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      caps.trayActions[TrayActionIds.quickCapture]!();
      expect(caps.shown, [WindowRole.quickCapture]);
    });

    testWidgets('「显示主窗口」项触发 showWindow(main)', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      caps.trayActions[TrayActionIds.show]!();
      expect(caps.shown, [WindowRole.main]);
    });
  });

  group('托盘同步三项', () {
    testWidgets('菜单含三个新 id', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      final ids = caps.trayMenu!
          .where((e) => e.type != TrayMenuItemType.separator)
          .map((e) => e.id);
      expect(
        ids,
        containsAll(<String>[
          TrayActionIds.syncNow,
          TrayActionIds.openSyncDir,
          TrayActionIds.syncSettings,
        ]),
      );
    });

    testWidgets('未注入回调时三项置灰（不是「点了没反应」）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      TrayMenuItem item(String id) =>
          caps.trayMenu!.firstWhere((e) => e.id == id);

      expect(item(TrayActionIds.syncNow).enabled, isFalse);
      expect(item(TrayActionIds.openSyncDir).enabled, isFalse);
      // 「同步设置」是配置入口，禁用会让未配置的用户无法完成配置（死锁）。
      expect(
        item(TrayActionIds.syncSettings).enabled,
        isTrue,
        reason: '配置入口不能依赖「已配置」',
      );
    });

    testWidgets('isSyncConfigured 返回 false 时「打开同步目录」置灰', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(
        capabilities: caps,
        router: router,
        onOpenSyncDirectory: () async {},
        // 目录未配置。此时 revealPath 拿到空串会打开用户主目录，看起来像坏了。
        isSyncConfigured: () => false,
      ).attach();
      await tester.pump();

      final openDir = caps.trayMenu!.firstWhere(
        (e) => e.id == TrayActionIds.openSyncDir,
      );
      expect(openDir.enabled, isFalse);
    });

    testWidgets('已配置目录时「打开同步目录」可用', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(
        capabilities: caps,
        router: router,
        onOpenSyncDirectory: () async {},
        isSyncConfigured: () => true,
      ).attach();
      await tester.pump();

      final openDir = caps.trayMenu!.firstWhere(
        (e) => e.id == TrayActionIds.openSyncDir,
      );
      expect(openDir.enabled, isTrue);
    });

    testWidgets('触发「立即同步交付物」→ 注入的动作被调用一次', (tester) async {
      var calls = 0;
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(
        capabilities: caps,
        router: router,
        onSyncNow: () async => calls++,
      ).attach();
      await tester.pump();

      caps.trayActions[TrayActionIds.syncNow]!();
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('触发「打开同步目录」→ 注入的动作被调用一次', (tester) async {
      var calls = 0;
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(
        capabilities: caps,
        router: router,
        onOpenSyncDirectory: () async => calls++,
        isSyncConfigured: () => true,
      ).attach();
      await tester.pump();

      caps.trayActions[TrayActionIds.openSyncDir]!();
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('触发「同步设置…」→ 导航到 SpbRoutes.sync', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.trayActions[TrayActionIds.syncSettings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.sync);
      expect(find.text('sync'), findsOneWidget);
    });

    testWidgets('从悬浮窗点「同步设置…」→ 先还原窗口再导航', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      expect(caps.isOverlayModeActive, isTrue);

      caps.trayActions[TrayActionIds.syncSettings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.sync);
      expect(
        caps.isOverlayModeActive,
        isFalse,
        reason: '不还原的话，设置页会挤在 720x360 置顶窗里且再也放不大',
      );
    });

    testWidgets('已在同步设置页时重复触发 → 不重复导航（避免清掉草稿）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.sync);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      var builds = 0;
      final countingRouter = GoRouter(
        initialLocation: SpbRoutes.sync,
        routes: [
          GoRoute(
            path: SpbRoutes.sync,
            builder: (_, _) => _CountingPage(onBuild: () => builds++),
          ),
        ],
      );
      addTearDown(countingRouter.dispose);

      final countingCaps = _WiringCapabilities();
      DesktopIntegration(
        capabilities: countingCaps,
        router: countingRouter,
      ).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: countingRouter));
      await tester.pumpAndSettle();
      final before = builds;

      countingCaps.trayActions[TrayActionIds.syncSettings]!();
      await tester.pumpAndSettle();

      expect(countingRouter.state.uri.path, SpbRoutes.sync);
      expect(builds, before, reason: '同路径重复 go 会重建页面并清空表单草稿');
    });
  });

  group('关窗即隐藏的前提', () {
    testWidgets('托盘可用 → 启用隐藏到托盘', (tester) async {
      final caps = _WiringCapabilities()..trayAvailable = true;
      final router = _testRouter();
      addTearDown(router.dispose);

      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      expect(caps.hideOnClose, isTrue);
    });

    testWidgets('托盘不可用 → 不启用（否则用户无法唤回应用）', (tester) async {
      final caps = _WiringCapabilities()..trayAvailable = false;
      final router = _testRouter();
      addTearDown(router.dispose);

      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      expect(caps.hideOnClose, isFalse);
    });
  });
}
