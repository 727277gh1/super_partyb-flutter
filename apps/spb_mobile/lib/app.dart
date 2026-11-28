import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart' show AuthState, NoticeBanner;
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
        initialLocation: ref.read(externalQuickCaptureProvider) == null
            ? SpbRoutes.workOverview
            : SpbRoutes.overlay,
        externalQuickCapture: ref.read(externalQuickCaptureProvider) != null,
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
  _LifecycleFocusObserver? _lifecycleObserver;
  NotificationForegroundBridge? _foregroundBridge;
  ProviderSubscription<AuthState>? _notificationAuthSubscription;
  ProviderSubscription<int>? _notificationSessionSubscription;
  Future<void> _notificationPolling = Future<void>.value();

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
    // 临时 engine 只承接当前分享，不启动第二份离线重发和通知，也不让通知跳转抢走草稿。
    if (ref.read(externalQuickCaptureProvider) == null) {
      ref.read(outboxQueueProvider);
      _installNotifications();
    }
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
      unawaited(
        notifier.ensurePermission().then((_) => _reconcileNotifications()),
      );
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
      onResumed: _resyncOnResume,
    );
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    if (ref.read(notificationPollingSchedulerProvider).supported) {
      _foregroundBridge = NotificationForegroundBridge()
        ..attach(() => ref.read(windowFocusedProvider));
      _notificationAuthSubscription = ref.listenManual(
        authStateProvider,
        (_, _) => _reconcileNotifications(),
      );
      _notificationSessionSubscription = ref.listenManual(
        sessionRevisionProvider,
        (_, _) => _reconcileNotifications(),
      );
      _reconcileNotifications();
    }
  }

  void _reconcileNotifications() {
    _notificationPolling = _notificationPolling
        .then((_) async {
          if (!mounted) return;
          await ref.read(reconcileNotificationPollingProvider)();
        })
        .catchError((Object error) {
          SpbLog.warn('后台通知调度失败，下次回前台重试', {'error': error.toString()});
        });
  }

  /// 回到前台时对一次账（issue #88 方案 C 的客户端部分）。
  ///
  /// ## 为什么需要它
  ///
  /// 移动端切后台一阵后，系统会冻结甚至杀掉进程：SSE 断掉、`ConfirmationNotifier`
  /// 收不到那批 `confirmation_required` 事件。回到前台时若什么都不做，用户会
  /// 看到一份**陈旧**的待确认列表，直到自己去点刷新——而确认卡恰恰是有
  /// 时效的（服务端 10 分钟 TTL 就把它清成 expired）。
  ///
  /// ## 两件事，两种代价
  ///
  /// 1. **待确认收件箱重拉**：provider 是 `autoDispose`，无人监听时
  ///  invalidate 只丢快照、不发请求；列表页正在看时立刻重拉。
  /// 2. **SSE 连接自救**：只在控制器**本来就活着**时才动它。凭空 `ref.read`
  ///  会新建一个随即被 autoDispose 丢弃的实例，白开一条连接再断掉。
  ///
  /// 没有做「重拉当前对话的 timeline」：重连带的 cursor 会触发服务端回放，
  /// 回放被截断时已有缺口探测兜底（见 `ChatStreamController.recoverIfStalled`）
  /// ——两套回填语义并存必然漂移。
  void _resyncOnResume() {
    _reconcileNotifications();
    unawaited(ref.read(noticeCenterProvider)?.refresh());
    ref.invalidate(pendingConfirmationsProvider);

    final userId = ref.read(currentUserIdProvider).value;
    if (userId == null || userId.isEmpty) return;
    final controllerProvider = chatStreamControllerProvider(userId);
    if (!ref.exists(controllerProvider)) return;
    unawaited(ref.read(controllerProvider).recoverIfStalled());
  }

  @override
  void dispose() {
    _notificationAuthSubscription?.close();
    _notificationSessionSubscription?.close();
    _foregroundBridge?.dispose();
    final observer = _lifecycleObserver;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
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
    // 应用级常驻，切离对话页也持续接收所有通知类型。
    final notices = ref.watch(externalQuickCaptureProvider) == null
        ? ref.watch(noticeCenterProvider)
        : null;
    final focused = ref.watch(windowFocusedProvider);
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
      builder: (context, child) => NoticeBanner(
        center: notices,
        focused: focused,
        onOpen: _router.go,
        child: child ?? const SizedBox.shrink(),
      ),
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
///
/// ## 第二个职责：「真的从后台回来」
///
/// 同一份生命周期事件还是「进程被冻结过」的唯一本地信号。移动端挂起会让
/// SSE 变僵尸、待确认列表变陈旧（issue #88 方案 C）。故「见过 `paused`/`hidden`
/// 之后又回到 `resumed`」额外触发一次对账（[onResumed]）；`inactive → resumed`
/// 不触发——那是没离开过应用的往返。
class _LifecycleFocusObserver with WidgetsBindingObserver {
  _LifecycleFocusObserver({required this.onChanged, this.onResumed});

  final void Function(bool focused) onChanged;

  /// 从后台**真正回到前台**时调用一次（见 [didChangeAppLifecycleState]）。
  final VoidCallback? onResumed;

  /// 本次可见期内是否**真的离开过**（见过 `paused`/`hidden`/`detached`）。
  ///
  /// ## 为什么不能只看「上一跳是不是 paused」
  ///
  /// 回前台不是 `paused → resumed` 一跳，而是
  /// `paused → hidden → inactive → resumed`——进入 [didChangeAppLifecycleState]
  /// 时 [resumed] 的**上一层永远是 `inactive`**。用「上一层」做判据会让真机
  /// 永远不触发（测试用完整序列才看得出来）。故记「离开过」这个事实。
  bool _leftForeground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onChanged(state == AppLifecycleState.resumed);

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _leftForeground = true;
      case AppLifecycleState.resumed:
        // 只有「离开过」才是对账时机。`inactive → resumed` 是没离开过应用的
        // 往返（下拉通知中心、划一下控制中心、切到应用切换器又回来）：进程
        // 没被冻结、连接没断过，重拉一次是纯浪费（还可能在弱网下把列表刷成
        // 加载态）。
        //
        // 冷启动时 `_leftForeground` 为 false，不触发——冷启动本就有自己的
        // 回填与建连路径。
        if (!_leftForeground) return;
        _leftForeground = false;
        onResumed?.call();
      case AppLifecycleState.inactive:
        break;
    }
  }
}
