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
    // 冷启动场景：把应用拉起的那个深链在 `main.dart` 里就被处理过
    // （`receiver.start()` 是 await 的），所以 `ref.listen` 观察不到这次变化，
    // 必须显式读一次初值。
    final initialScene = ref.read(qrLoginSceneProvider);
    if (initialScene != null && initialScene.isNotEmpty) {
      _openQrLogin(initialScene);
    }
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
      // 启动就请求一次权限（幂等）。等「确认卡在后台到达」才请求的话，Android
      // 会在后台弹框（用户回到应用才看得到），而那条通知已经因未授权被丢弃——
      // 详见桌面端 `_installNotifications` 同一处的注释。
      unawaited(notifier.ensurePermission());
    }

    // 点击通知 → 跳到该对话（payload 是 `/chat/{groupId}`）。
    //
    // ## 为什么用 `go` 而不是 `push`
    //
    // 用户点通知的意图是「去那里」。`push` 会在当前栈上再压一层，返回键要按
    // 好几次才回到用户原来的位置——而用户根本没在这个应用里。
    notifier.attach(onNavigate: (payload) => _router.go(payload));

    // 冷启动的启动详情（issue #86）：App 被杀后点通知，payload 不走 onSelect
    // （那只覆盖进程存活时的点击），要单独读一次 launch details。与 onSelect
    // 覆盖互斥的两个生命周期阶段（启动点击发生在插件初始化之前），读一次即
    // 消费，不重复导航。
    if (sink is LocalNotificationSink) {
      unawaited(
        sink.launchDetails().then((details) {
          final payload = details?.notificationResponse?.payload;
          if (details?.didNotificationLaunchApp != true ||
              payload == null ||
              payload.isEmpty) {
            return; // 普通启动 / 空 payload → 打开主窗口（默认路由）。
          }
          // 首帧后再导航：initState 阶段路由栈尚未完全就绪。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _router.go(payload);
          });
        }),
      );
    }

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

  /// 打开扫码登录确认页。
  ///
  /// - 用 `go` 而不是 `push`：确认页来自外部、是一次性动作，`push` 会在用户
  ///   原来的页面上再压一层，完成后按返回又回到确认页；
  /// - 推迟到 post-frame：`initState` 期间路由栈尚未就绪，build 期间更不能改它；
  /// - 导航后立刻 `consume()`：让同一条深链被点第二次时仍能再次触发。
  void _openQrLogin(String scene) {
    final target = SpbRoutes.qrLoginFor(scene);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _router.go(target);
      ref.read(qrLoginSceneProvider.notifier).consume();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 扫码登录深链 → 导航到确认页。
    //
    // ## 为什么导航只在这一个地方
    //
    // 深链由 `AuthDeepLinkReceiver` 在 `main.dart` 收到（那时 `GoRouter` 还不
    // 存在），它只把 scene 投进 `qrLoginSceneProvider`。这里既是冷启动的入口
    // （`initState` 里读初值），也是运行中的入口（`ref.listen`），两条路径
    // 走同一个 [_openQrLogin]。
    ref.listen<String?>(qrLoginSceneProvider, (previous, next) {
      if (next == null || next.isEmpty) return;
      _openQrLogin(next);
    });

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
