import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_platform/spb_platform.dart';

import 'desktop_integration.dart';
import 'providers.dart';
import 'router.dart';
import 'tray_tooltip.dart';

/// 应用根组件。
///
/// 路由表由 [createDesktopRouter] 提供；页面本身在 `spb_features`。
/// 本文件只负责「装配」：主题 + 路由 + 标题。
///
/// ## 为什么 router 在 `initState` 里创建（而不是 `build` 里）
///
/// `GoRouter` 持有一个 `Navigator` 与路由栈。若在 `build` 里创建，热重载或
/// 父级 rebuild 会产生**新的** GoRouter 实例，导致导航栈被重置（用户会看到
/// 页面莫名跳回首页）。
///
/// [SpbDesktopApp] 自身几乎不会 rebuild（它是 `runApp` 的根），但
/// [createDesktopRouter] 的调用点应保持唯一且稳定，故用 `StatefulWidget`
/// 在 `initState` 里创建一次。
///
/// ## 为什么是 `ConsumerStatefulWidget`
///
/// 路由需要 `refreshListenable`（认证状态变化时重跑重定向守卫，见
/// `providers.dart` 的 [AuthRefreshNotifier]），而它来自 Riverpod 容器。
class SpbDesktopApp extends ConsumerStatefulWidget {
  const SpbDesktopApp({super.key, this.router});

  /// 可选的外部路由实例（测试用）。
  ///
  /// 测试需要主动导航（如验证 `/overlay` 可达），而 router 若在内部
  /// 创建就无法从外部拿到。提供这个钩子比在测试里靠 `GoRouter.of(context)`
  /// 反查更直接、也更稳定（不依赖 widget 树结构）。
  ///
  /// 生产为 null，由内部创建。
  final GoRouter? router;

  @override
  ConsumerState<SpbDesktopApp> createState() => _SpbDesktopAppState();
}

class _SpbDesktopAppState extends ConsumerState<SpbDesktopApp> {
  late final GoRouter _router =
      widget.router ??
      createDesktopRouter(
        refreshListenable: ref.read(authRefreshListenableProvider),
      );

  /// 外部传入的 router 由传入方负责 dispose（生命周期不属于本组件）。
  late final bool _ownsRouter = widget.router == null;

  /// 桌面能力与路由/托盘的接线。null 表示本平台不支持（移动端/测试环境）。
  ///
  /// ## 为什么不是 `late final` 带条件赋值
  ///
  /// `late final X?` 若某条分支不赋值，**读取时抛 LateInitializationError**
  /// （不是返回 null）——`dispose` 里读它会让「移动端卸载」变成崩溃。
  /// 用普通可空字段，初值就是 null。
  ///
  /// ## 为什么在 `initState` 里 attach（而不是 `build`）
  ///
  /// `attach` 会设置平台回调并推送托盘菜单——这是副作用，每次 rebuild 都做
  /// 会反复重建托盘菜单。`attach` 自身幂等，但放在 `initState` 更明确。
  DesktopIntegration? _integration;

  /// 托盘提示的接线。null 表示本平台不支持（移动端/测试环境）。
  TrayTooltipController? _trayTooltip;

  /// 托盘提示的订阅（同步在途状态变化时重推）。
  ProviderSubscription<bool>? _syncInFlightSub;

  @override
  void initState() {
    super.initState();
    // 离线写队列（issue #30）：**必须在这里预热**。
    //
    // ## 为什么不能等对话页来读
    //
    // `outboxQueueProvider` 的构造里挂了 `ref.listen(currentUserIdProvider...)`
    // ——那是队列「恢复上次未发完的条目」的唯一入口。而 Riverpod 的 provider
    // 是**惰性**的：没人读就永不构造。若只在 `ConversationPage` 里读，则
    // 「断网发一条 → 关掉对话页 → 重启 App」后队列不会恢复，消息要等用户
    // 再次打开某个对话才被重试（甚至永远不重试）。
    //
    // 预热后，重试计时器与 `drain` 从 App 启动起就在跑。
    ref.read(outboxQueueProvider);
    _installNotifications();
    // 移动端的能力是 NoopDesktopCapabilities，attach 会自行跳过。
    // 但移动端连 spb_desktop 都不该走，故这里只在桌面端接线。
    final caps = ref.read(desktopCapabilitiesProvider);
    if (caps.isSupported) {
      _integration = DesktopIntegration(
        capabilities: caps,
        router: _router,
        // ## 为什么都是**读 provider** 而不是捕获当前值
        //
        // 目录与配置都可能随时被改（同步页）。`onSyncNow` 走的
        // `runSyncActionProvider` 本就读最新值；目录同理——每次调用时现读。
        onSyncNow: () => ref.read(runSyncActionProvider)(),
        onOpenSyncDirectory: () async {
          final root = ref.read(syncLocalRootProvider).value;
          if (root == null || root.trim().isEmpty) return;
          await caps.revealPath(root);
        },
        // 托盘菜单推送时取值（见该字段文档：快照会让「先启动后配置」永久禁用）。
        isSyncConfigured: () =>
            ref.read(syncLocalRootProvider).value?.trim().isNotEmpty ?? false,
      )..attach();
      _installTrayTooltip(caps);
    }
  }

  /// 接线托盘提示：把「同步状态」反映到托盘上。
  ///
  /// ## 为什么订阅「同步在途」而不是「同步结果」
  ///
  /// 提示文本要反映**当下**状态（同步中 / 空闲）。同步结束后必须回到
  /// 「空闲」——一个永久显示「同步中…」的托盘提示比没有提示更糟（用户会
  /// 以为卡住了）。`syncInFlightProvider` 在 `finally` 里复位，正好覆盖
  /// 成功与失败两条路径。
  ///
  /// ## 为什么在 `initState` 里订阅而不是在 `build` 里 `ref.listen`
  ///
  /// `ref.listen` 只能在 `build` 阶段调用（Riverpod 的约束）。本组件的
  /// `build` 在 `initState` 之后才跑，但订阅若放 `build` 里会**每次 rebuild
  /// 重复注册**（虽然 Riverpod 会去重，但语义上「订阅生命周期 = 组件生命
  /// 周期」用 `listenManual` 表达更准确，且能显式 dispose）。
  void _installTrayTooltip(DesktopCapabilities caps) {
    final controller = TrayTooltipController(
      capabilities: caps,
      // 目录来自 provider（可能在设置页被改），故每次读最新值而不是快照。
      syncConfigured: () =>
          ref.read(syncLocalRootProvider).value?.trim().isNotEmpty ?? false,
      syncing: () => ref.read(syncInFlightProvider),
    );
    _trayTooltip = controller;

    // 先推一次当前状态：否则托盘会一直显示托盘库的默认值，直到用户第一次
    // 同步——而「未配置同步目录」这个信息恰恰在用户还没同步时最有用。
    controller.push();

    _syncInFlightSub = ref.listenManual<bool>(syncInFlightProvider, (_, _) {
      controller.push();
    });
  }

  /// 接线本地通知（issue #21）。
  ///
  /// ## 三件事
  ///
  /// 1. **初始化插件**（Android 需 Activity 已就绪、iOS 需在 runApp 之后设置
  ///    delegate，故不能更早）；
  /// 2. **接上点击导航**：点通知跳到该对话（payload 是 `/chat/{groupId}`）；
  /// 3. **订阅窗口焦点**：通知判定要「窗口在后台才发」。
  ///
  /// ## 为什么在 `initState` 里而不是 `main`
  ///
  /// 导航需要 `_router`，而它在 `initState` 才创建（见类文档：不能放 `build`
  /// 里，否则热重载会重置导航栈）。
  void _installNotifications() {
    final sink = ref.read(notificationSinkProvider);
    final notifier = ref.read(confirmationNotifierProvider);

    // 插件初始化是异步的（平台通道）；失败时内部已静默降级（见
    // `LocalNotificationSink.initialize`），故不需要 await 后再判断。
    if (sink is LocalNotificationSink) {
      unawaited(sink.initialize());
    }

    // 点击通知 → 跳到该对话。用 `go`（不是 `push`）：用户点通知的意图是
    // 「去那里」，而不是「在当前栈上再压一层」。
    //
    // ## 为什么用 `context.go` 而不是 `_router.go`
    //
    // 两者等价（本组件是 `MaterialApp.router` 的根，`context` 就在路由树下）。
    // 用 `_router` 更直接，但需要把 `initState` 里的接线推迟到首帧后
    // （`_router` 此时已存在，故其实可以）——选择 `_router` 是为了不依赖
    // `context` 在 `initState` 阶段的可用性（`GoRouter.of(context)` 在
    // `initState` 里拿不到 InheritedWidget）。
    notifier.attach(onNavigate: (payload) => _router.go(payload));

    // 窗口焦点 → 通知判定。真实实现会推送；Noop/测试桩不推（保持初始 true）。
    final caps = ref.read(desktopCapabilitiesProvider);
    if (caps is WindowFocusTarget) {
      // 先提升成局部变量：Dart 的类型提升不穿透 `is` 检查到后续的 cascade
      // （与 `desktop_integration.dart` 里 `WindowDisplayTarget` 同一原因）。
      final focus = caps as WindowFocusTarget;
      focus.onFocus = () => ref.read(windowFocusedProvider.notifier).set(true);
      focus.onBlur = () => ref.read(windowFocusedProvider.notifier).set(false);
      _focusTarget = focus;
    }
  }

  /// 焦点接线点（dispose 时摘除）。
  WindowFocusTarget? _focusTarget;

  @override
  void dispose() {
    // 先摘焦点接线（它引用 `ref`，容器可能先于组件销毁）。
    final focus = _focusTarget;
    if (focus != null) {
      focus
        ..onFocus = null
        ..onBlur = null;
    }
    _syncInFlightSub?.close();
    _trayTooltip?.dispose();
    _integration?.detach();
    if (_ownsRouter) _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Super PartyB',
      debugShowCheckedModeBanner: false,
      theme: SpbTheme.light(),
      darkTheme: SpbTheme.dark(),
      // 用户选择的主题模式（跟随系统 / 浅色 / 深色），持久化在
      // `ui.theme_mode`。默认 system = 跟随系统，与改动前行为一致。
      themeMode: ref.watch(themeModeProvider),
      routerConfig: _router,
    );
  }
}
