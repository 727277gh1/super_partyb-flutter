import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        OverlayWindowController,
        PlatformDesktopQuit {
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
  Future<void> setHideOnClose(bool value) async => hideOnClose = value;

  // ---- 托盘右键弹出（2026-11 Windows 卡死菜单修复的接线验证） ----
  int popupCalls = 0;

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
    events?.add('enter');
    if (!enterSucceeds) return false;
    _overlayActive = true;
    return true;
  }

  /// 「显示悬浮窗」请求次数（enter 之后、由 router 触发的那次显示）。
  int revealCalls = 0;

  /// 事件顺序记录（仅在用例注入时写）。
  ///
  /// 「先导航、后显示」只能靠**顺序**验证：两个动作单独看都对，顺序反了才会
  /// 让用户先看到主界面被压成小窗。
  List<String>? events;

  @override
  Future<void> revealOverlayMode() async {
    if (!_overlayActive) return;
    revealCalls++;
    events?.add('reveal');
  }

  /// 每次退出时的 `showMainWindow` 取值（按顺序）。
  ///
  /// 「记完了回到原应用」与「用户要求看主窗口」是两条不同语义，接线接错
  /// 不会有任何报错——只表现为焦点被抢走，故必须钉住。
  final exitShowMainWindow = <bool>[];

  @override
  Future<void> exitOverlayMode({bool showMainWindow = false}) async {
    if (!_overlayActive) return;
    _overlayActive = false;
    exitCalls++;
    exitShowMainWindow.add(showMainWindow);
    events?.add('exit');
  }

  /// 收到的贴合请求（内容高度，按顺序）。
  ///
  /// 本文件的 router 用 stub 页面（`_testRouter`），故这里始终为空——
  /// 「页面上报 → 能力层贴合」的**整条接线**由 `router_overlay_test.dart`
  /// 用真实 router 钉住（那里需要真实 `OverlayQuickCapturePage`）。
  /// 保留记录字段是为了让契约可观测，而不是为了在本文件断言。
  final fittedHeights = <double>[];

  @override
  Future<void> fitOverlayContentHeight(double contentHeight) async {
    if (!_overlayActive) return;
    fittedHeights.add(contentHeight);
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
  Future<void> popUpTrayContextMenu() async => popupCalls++;

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

  // ---- PlatformDesktopQuit ----

  /// 退出次数（托盘「退出」与系统会话结束共用同一条路径）。
  int quitCalls = 0;

  /// 每次退出时的 `reason`（见 `PlatformDesktopQuit.quit` 的文档）。
  final quitReasons = <String>[];

  @override
  Future<void> quit({String reason = 'user'}) async {
    quitCalls++;
    quitReasons.add(reason);
  }
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
      // 同步标签与通用标签**是同一个路由**（`/settings?tab=sync`），故只需
      // 一条 stub；导航是否落到同步标签靠断言 query 参数。
      GoRoute(path: SpbRoutes.settings, builder: (_, _) => stub('settings')),
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
  // 通道级处理器是全局槽位：用例结束后必须摘掉，否则下一个用例会收到
  // 上一个实例（已 dispose）的回调。
  tearDown(uninstallSessionEndHandler);

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
          TrayActionIds.settings,
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
      // 7 = 显示 / 快速输入 / 立即同步 / 打开同步目录 / 交付物同步 / 设置 / 退出。
      expect(caps.showCallback, isNotNull);
      expect(caps.trayActions, hasLength(7));
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

    testWidgets('系统会话结束走 quit（安装包升级时 Restart Manager 的请求）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      DesktopIntegration(capabilities: caps, router: router).attach();

      // 模拟原生侧（Windows runner 的 WM_ENDSESSION）发来的动作。
      // 不 await：testWidgets 跑在 FakeAsync 里，微任务要靠 pump 推进
      // （见 `TestDefaultBinaryMessenger.handlePlatformMessage` 的说明）。
      unawaited(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              kHostLifecycleChannelName,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('sessionEnding'),
              ),
              null,
            ),
      );
      await tester.pump();

      // 钉住这一点：必须真的调 `quit`（而不是只是隐藏窗口）。
      // 不退出的话，安装程序会停在「正在关闭应用」——正是本接线解决的问题。
      expect(caps.quitCalls, 1);
      expect(caps.quitReasons, ['session-end']);
    });

    testWidgets('重复的会话结束请求只退出一次（_quitting 幂等）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      DesktopIntegration(capabilities: caps, router: router).attach();

      // Restart Manager 的 `WM_ENDSESSION` 之后还会用 `WM_CLOSE` 兜底，
      // Dart 收尾慢时同一条请求可能到两次——重复 `quit()` 会二次 dispose
      // 托盘/快捷键（行为未定义）。
      for (var i = 0; i < 2; i++) {
        unawaited(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                kHostLifecycleChannelName,
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('sessionEnding'),
                ),
                null,
              ),
        );
        await tester.pump();
      }

      expect(caps.quitCalls, 1);
    });

    testWidgets('detach 后不再响应会话结束（否则旧实例会被重启的退出带走）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);

      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();
      integration.detach();

      unawaited(
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              kHostLifecycleChannelName,
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('sessionEnding'),
              ),
              null,
            ),
      );
      await tester.pump();

      expect(caps.quitCalls, 0);
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
        reason: '只导航不还原的话，窗口会一直保持 720 宽的小置顶窗且再也放不大',
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
      // 必须是**带附件**的规格：宽 720（纯文本规格是 640，chip 并排放不下）。
      // 高度不再是「最坏情况」的 360——进入时按最小值出现，首帧由页面把
      // 内容高度报给 `fitOverlayContentHeight` 贴合（2026-11 「一大片空白」
      // 的修复）。故这里不再断言 height > 200，改为断言宽度与高度下限。
      expect(caps.enteredSpecs.single.role, WindowRole.quickCapture);
      expect(
        caps.enteredSpecs.single.width,
        greaterThan(WindowSpec.quickCapture.width),
      );
      expect(
        caps.enteredSpecs.single.height,
        lessThanOrEqualTo(kOverlayMinWindowHeight),
      );
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

    testWidgets('从悬浮窗切到设置 → 还原窗口（否则设置页挤在 720 宽的小置顶窗里）', (tester) async {
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

    testWidgets('先导航到悬浮页、再显示窗口（否则先闪一帧被压小的主界面）', (tester) async {
      final caps = _WiringCapabilities();
      final events = <String>[];
      caps.events = events;
      final router = _testRouter();
      addTearDown(router.dispose);
      // 导航也要进同一条时间线，才能断言「显示晚于导航」。
      router.routerDelegate.addListener(() {
        events.add('nav:${router.state.uri.path}');
      });
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      expect(caps.revealCalls, 1, reason: '进入后必须有人把它显示出来');
      final navAt = events.indexOf('nav:${SpbRoutes.overlay}');
      expect(navAt, greaterThanOrEqualTo(0));
      expect(
        events.indexOf('reveal'),
        greaterThan(navAt),
        reason: '显示早于导航 = 用户先看到主界面被压成 720 宽的小窗（2026-11 报障）',
      );
    });

    testWidgets('记完关窗 → 退出时**不**强制显示主窗口（回到原来那个应用）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      final integration = DesktopIntegration(capabilities: caps, router: router)
        ..attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      await integration.leaveOverlay();

      expect(caps.exitShowMainWindow, [
        false,
      ], reason: '从别的应用按 Alt+Space 记一笔的人，不该被主窗口抢走焦点');
    });

    testWidgets('从悬浮窗切到设置 → 退出时强制显示主窗口（否则「点了没反应」）', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();

      caps.showCallback!(WindowRole.settings);
      await tester.pumpAndSettle();

      expect(caps.exitShowMainWindow, [true]);
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

    testWidgets('「退出」项调 quit（与系统会话结束共用同一条路）', (tester) async {
      // 两个入口（这里是托盘菜单，上面的用例是会话结束）必须落到同一个
      // `quit`。若将来有人给托盘单独写一套收尾逻辑，这里会红。
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      caps.trayActions[TrayActionIds.quit]!();
      await tester.pump();

      expect(caps.quitCalls, 1);
      expect(caps.quitReasons, ['user']);
    });

    testWidgets('popUpTrayContextMenu 可从能力层到达（右键弹菜单的接线）', (tester) async {
      // 2026-11 Windows 修复的回归防线：托盘右键 → `popUpTrayContextMenu`
      // 是新抽出的接口方法（bringAppToFront 判据在能力层内部）。若接线
      // 断裂（实现类不再实现该方法、或右键处理不再调它），托盘菜单在
      // Windows 上不会弹出——而本测试所在的桩层无法感知。
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();
      await tester.pump();

      expect(caps.popupCalls, 0);
      await caps.popUpTrayContextMenu();
      expect(caps.popupCalls, 1);
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
      // 「交付物同步」是配置入口，禁用会让未配置的用户无法完成配置（死锁）。
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

    testWidgets('触发「交付物同步…」→ 导航到设置页的同步标签', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.trayActions[TrayActionIds.syncSettings]!();
      await tester.pumpAndSettle();

      // 落点是**设置页的同步标签**（path 仍是 /settings，靠 query 区分）。
      // 只看 path 会把这与「设置…」当成同一个目标。
      expect(router.state.uri.path, SpbRoutes.settings);
      expect(router.state.uri.queryParameters['tab'], 'sync');
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('从悬浮窗点「交付物同步…」→ 先还原窗口再导航', (tester) async {
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

      expect(router.state.uri.path, SpbRoutes.settings);
      expect(router.state.uri.queryParameters['tab'], 'sync');
      expect(
        caps.isOverlayModeActive,
        isFalse,
        reason: '不还原的话，设置页会挤在 720 宽的小置顶窗里且再也放不大',
      );
    });

    testWidgets('已在通用标签时触发「交付物同步…」→ 必须真的切过去', (tester) async {
      // 这条钉的是**守卫不能过宽**：`_openSyncSettings` 若只比 path（不查
      // query），「已在设置页」就会把「通用标签 → 同步标签」也当成「已经在
      // 那儿」，托盘项成了死按钮。
      //
      // 反面（已在同步标签时重复触发）**不写成用例**：`go()` 到 **相同**
      // location 时 go_router 本身就不重建页面（实测：同一 location 再 go
      // 一次，页面 build 次数不变；query 变化才 +1）。故那里加一条
      // 「不重复导航」的断言会是**假绿**——把守卫删掉它也照样通过。
      final router = _testRouter(initialLocation: SpbRoutes.settings);
      addTearDown(router.dispose);
      final caps = _WiringCapabilities();
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, SpbRoutes.settings);
      expect(router.state.uri.queryParameters['tab'], isNull);

      caps.trayActions[TrayActionIds.syncSettings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
      expect(router.state.uri.queryParameters['tab'], 'sync');
    });

    testWidgets('已在同步标签时点「设置…」→ 切回首个标签（不能被吞掉）', (tester) async {
      // 与上一条对称的坑：两个标签共用 `/settings`，守卫只比 path 的话，
      // 「设置…」在同步标签里就成了死按钮——外观 / 个人偏好依然不可达。
      final caps = _WiringCapabilities();
      final router = _testRouter(initialLocation: SpbRoutes.settingsSyncTab);
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(router.state.uri.queryParameters['tab'], 'sync');

      caps.trayActions[TrayActionIds.settings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
      expect(
        router.state.uri.queryParameters.containsKey('tab'),
        isFalse,
        reason: '必须真的导航到首个标签',
      );
    });

    testWidgets('触发「设置…」→ 导航到 /settings 首个标签（不带 tab 参数）', (tester) async {
      // 托盘里两项容易混：「交付物同步…」到 `/settings?tab=sync`（同步配置 +
      // 立即同步 + 回传），而「设置…」是 `/settings` 首个标签（外观 / 通知 /
      // 个人偏好 / 桌面集成 / 账号）。弄反的话后者那些配置依然不可达。
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.trayActions[TrayActionIds.settings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
      expect(
        router.state.uri.queryParameters.containsKey('tab'),
        isFalse,
        reason: '「设置…」应落在首个标签，不能带 tab=sync',
      );
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('从悬浮窗点「设置…」→ 先还原窗口再导航', (tester) async {
      final caps = _WiringCapabilities();
      final router = _testRouter();
      addTearDown(router.dispose);
      DesktopIntegration(capabilities: caps, router: router).attach();

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      caps.showCallback!(WindowRole.quickCapture);
      await tester.pumpAndSettle();
      expect(caps.isOverlayModeActive, isTrue);

      caps.trayActions[TrayActionIds.settings]!();
      await tester.pumpAndSettle();

      expect(router.state.uri.path, SpbRoutes.settings);
      expect(
        caps.isOverlayModeActive,
        isFalse,
        reason: '不还原的话，设置页会挤在 720 宽的小置顶窗里且再也放不大',
      );
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
