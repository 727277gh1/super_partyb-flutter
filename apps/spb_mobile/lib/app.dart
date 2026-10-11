import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_platform/spb_platform.dart';

import 'providers.dart';
import 'router.dart';

/// 移动端应用根组件。
///
/// 路由表由 [createMobileRouter] 提供（底部标签栏 + 各标签独立导航栈）。
///
/// ## 为什么用 `StatefulWidget` 在 `initState` 里创建 router
///
/// `GoRouter` 持有 `Navigator` 与路由栈。若在 `build` 里创建，父级 rebuild
/// 会换成新实例、导航栈被重置（用户会看到页面莫名跳回列表）。本组件是
/// `runApp` 的根、几乎不 rebuild，但把创建点固定一次仍是必要的。
///
/// ## 为什么是 `ConsumerStatefulWidget`
///
/// 路由需要 `refreshListenable`（认证状态变化时重跑重定向守卫），而它来自
/// Riverpod 容器。
class SpbMobileApp extends ConsumerStatefulWidget {
  const SpbMobileApp({super.key, this.router});

  /// 可选的外部路由实例（测试用）。
  ///
  /// 测试需要主动导航（如验证 `/quick-capture` 可达），而 router 若在内部
  /// 创建就无法从外部拿到。生产为 null，由内部创建。
  final GoRouter? router;

  @override
  ConsumerState<SpbMobileApp> createState() => _SpbMobileAppState();
}

class _SpbMobileAppState extends ConsumerState<SpbMobileApp> {
  late final GoRouter _router =
      widget.router ??
      createMobileRouter(
        refreshListenable: ref.read(authRefreshListenableProvider),
      );

  /// 外部传入的 router 由传入方负责 dispose。
  late final bool _ownsRouter = widget.router == null;

  /// 生命周期观察者（把 `AppLifecycleState` 归一到「是否该打扰用户」）。
  ///
  /// ## 为什么用 `WidgetsBindingObserver` 而不是 `AppLifecycleListener`
  ///
  /// 两者都能拿到生命周期。选 `WidgetsBindingObserver` 是因为它同时给出
  /// `didChangeAppLifecycleState`（resumed/inactive/paused），而
  /// `AppLifecycleListener` 的回调按平台分得更细（`onResume`/`onInactive`/
  /// `onHide`/`onShow`…），我们需要的是「是否在前台」这一个布尔，粗粒度即可。
  late final _LifecycleFocusObserver _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    // 离线写队列（issue #30）：与桌面端同构的预热（见 `apps/spb_desktop/lib/app.dart`
    // 同一行的说明）。
    //
    // 移动端尤其需要：用户在地铁里断网发一条 → 杀掉 App → 出站后重新打开，
    // 若队列未预热则这条消息永远不会被重试。
    ref.read(outboxQueueProvider);
    _installNotifications();
  }

  /// 接线本地通知（issue #21）。与桌面端 `_installNotifications` 同构。
  ///
  /// 差异只在「前台判定」的来源：桌面端是窗口焦点事件，移动端是
  /// `AppLifecycleState`。两者都归一到 [windowFocusedProvider]。
  void _installNotifications() {
    final sink = ref.read(notificationSinkProvider);
    final notifier = ref.read(confirmationNotifierProvider);

    if (sink is LocalNotificationSink) {
      unawaited(sink.initialize());
    }

    // 点击通知 → 跳到该对话（payload 是 `/chat/{groupId}`）。
    //
    // ## 为什么用 `go` 而不是 `push`
    //
    // 用户点通知的意图是「去那里」。`push` 会在当前栈上再压一层，返回键要按
    // 好几次才回到用户原来的位置——而用户根本没在这个应用里。
    notifier.attach(onNavigate: (payload) => _router.go(payload));

    _lifecycleObserver = _LifecycleFocusObserver(
      onChanged: (focused) =>
          ref.read(windowFocusedProvider.notifier).set(focused),
    );
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
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

/// 把 `AppLifecycleState` 归一到「应用是否在前台」。
///
/// ## 判定为什么是「只认 resumed」
///
/// `inactive` 是一个**过渡态**：iOS 上拉下通知中心、切到应用切换器、甚至
/// 收到来电，都会先经过它。把它当作「在前台」会让这些场景下不弹通知——
/// 而那时用户恰恰看不到应用内容。
///
/// 反之把它当「在后台」会让「用户只是滑了一下控制中心」也弹通知。两者都不对，
/// 但**多弹一条**比**漏弹**更烦人，且本应用的通知是「有事等你处理」（可容忍
/// 一次多余提示），故选择「只认 resumed」= 保守地多发。
///
/// 桌面端同理（`window_manager` 的 blur 也包含「被其他窗口遮挡」）。
class _LifecycleFocusObserver with WidgetsBindingObserver {
  _LifecycleFocusObserver({required this.onChanged});

  final void Function(bool focused) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChanged(state == AppLifecycleState.resumed);
  }
}
