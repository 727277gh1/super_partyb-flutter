import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';

import 'desktop_integration.dart';
import 'providers.dart';
import 'router.dart';

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
  /// 测试需要主动导航（如验证 `/quick-capture` 可达），而 router 若在内部
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

  @override
  void initState() {
    super.initState();
    // 移动端的能力是 NoopDesktopCapabilities，attach 会自行跳过。
    // 但移动端连 spb_desktop 都不该走，故这里只在桌面端接线。
    final caps = ref.read(desktopCapabilitiesProvider);
    if (caps.isSupported) {
      _integration = DesktopIntegration(capabilities: caps, router: _router)
        ..attach();
    }
  }

  @override
  void dispose() {
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
      routerConfig: _router,
    );
  }
}
