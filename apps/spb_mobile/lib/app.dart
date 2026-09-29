import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';

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

  @override
  void dispose() {
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
