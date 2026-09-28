import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_design/spb_design.dart';

import 'router.dart';

/// 应用根组件。
///
/// 路由表由 [createDesktopRouter] 提供；页面本身在 `spb_features`。
/// 本文件只负责「装配」：主题 + 路由 + 标题。
///
/// ## 为什么 router 在 build 里创建（而不是 `late final` 字段）
///
/// `GoRouter` 持有一个 `Navigator` 与路由栈。若在 `StatelessWidget` 的字段里
/// 创建，热重载或父级 rebuild 会产生**新的** GoRouter 实例，导致导航栈被重置
/// （用户会看到页面莫名跳回首页）。
///
/// [SpbDesktopApp] 自身几乎不会 rebuild（它是 `runApp` 的根），但
/// [createDesktopRouter] 的调用点应保持唯一且稳定，故用 `StatefulWidget`
/// 在 `initState` 里创建一次。
class SpbDesktopApp extends StatefulWidget {
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
  State<SpbDesktopApp> createState() => _SpbDesktopAppState();
}

class _SpbDesktopAppState extends State<SpbDesktopApp> {
  late final GoRouter _router = widget.router ?? createDesktopRouter();

  /// 外部传入的 router 由传入方负责 dispose（生命周期不属于本组件）。
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
