import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_features/spb_features.dart';

import 'providers.dart';

/// 路由路径常量。
///
/// WHY 集中定义：`context.go(...)` 与路由表两处必须一致，散落的字符串字面量
/// 一旦有一处拼错，编译器不会报错、运行时才表现为「点了没反应」。
class SpbRoutes {
  const SpbRoutes._();

  static const home = '/';
  static const settings = '/settings';
  static const quickCapture = '/quick-capture';

  /// 对话时间线路径。
  static String chat(String groupId) => '/chat/$groupId';

  static const chatPattern = '/chat/:groupId';
}

/// 桌面端路由表。
///
/// ## 布局形态：不用 StatefulShellRoute
///
/// 桌面端是「列表 + 内容」两栏布局，侧边栏只是**布局**而非独立导航栈。
/// 引入 `StatefulShellRoute` 反而让「点列表项切换对话」多一层 navigator，
/// 且需要处理分支间状态同步。见 `docs/flutter-component-research.md` §1.2
/// 的采纳结论。
///
/// ## 对话页为什么走 path 参数而不是 query
///
/// `/chat/:groupId` 让 URL 可分享、可深链，也让「返回上一个对话」有历史语义。
GoRouter createDesktopRouter() {
  return GoRouter(
    initialLocation: SpbRoutes.home,
    routes: buildDesktopRoutes(),
  );
}

/// 桌面端路由表（不含 `GoRouter` 实例）。
///
/// 独立导出供测试构造自己的 `GoRouter`（测试需要指定 `initialLocation`
/// 并在 pumpWidget 前拿到实例以主动导航）。
List<RouteBase> buildDesktopRoutes() {
  return [
    GoRoute(
      path: SpbRoutes.home,
      builder: (context, state) => const _HomePage(),
      routes: [
        GoRoute(
          path: 'chat/:groupId',
          builder: (context, state) {
            final groupId = state.pathParameters['groupId'] ?? '';
            return _ChatPage(groupId: groupId);
          },
        ),
        GoRoute(
          path: 'settings',
          builder: (context, state) => const _SettingsPage(),
        ),
        GoRoute(
          path: 'quick-capture',
          builder: (context, state) => const _QuickCapturePage(),
        ),
      ],
    ),
  ];
}

/// 首页：对话列表。
class _HomePage extends ConsumerWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    return GroupListPage(
      api: api,
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
    );
  }
}

/// 对话时间线。
///
/// 进入时把控制器聚焦到该 group（`switchGroup` 会回填 timeline）；
/// 退出时 Provider autoDispose 自动断开 SSE。
class _ChatPage extends ConsumerStatefulWidget {
  const _ChatPage({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<_ChatPage> {
  /// 已聚焦的 group，避免重复调用 `switchGroup`（它会清空缓冲重新回填，
  /// 在每次 rebuild 里调用会导致列表反复闪烁）。
  String? _focused;

  @override
  void initState() {
    super.initState();
    // 在首帧后聚焦：`ref.watch` 在 initState 里不可用，
    // 而 `ref.read` 可以在 initState 里用，但此时控制器尚未被 watch 过。
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) _focus();
  }

  Future<void> _focus() async {
    if (!mounted || _focused == widget.groupId) return;
    _focused = widget.groupId;
    await ref.read(chatStreamControllerProvider).start(groupId: widget.groupId);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatStreamControllerProvider);
    final api = ref.watch(chatApiProvider);

    return ConversationPage(
      controller: controller,
      title: '对话',
      onResolveConfirmation: (confirmationId, option) {
        // 动作文案 → 服务端 action。
        //
        // 服务端 `misc.go:resolve` 绑定 `{action, comment}`，且把 action 写进
        // `resolved_action`；status 固定为 `resolved`（见 `chat_confirmations`
        // 的 CHECK 约束：pending|resolved|expired|cancelled）。
        // 故这里必须传**动作**而非 `resolved` 这类状态词。
        api
            .resolveConfirmation(
              confirmationId,
              action: _optionToAction(option),
            )
            .catchError((Object e) {
              // 不重抛：确认失败不应让页面崩，用户可再点一次。
              // 真正的失败提示由 ConversationPage 的 SnackBar 覆盖发送路径，
              // 确认路径此处仅记录。
              debugPrint('确认提交失败: $e');
            });
      },
    );
  }

  /// 选项文案映射为服务端 action。
  ///
  /// 服务端只把 action 存进 `resolved_action`（当前无下游消费者），故映射错误
  /// 不会造成功能异常；但保留正确语义以便将来接入。
  static String _optionToAction(String option) => switch (option) {
    '继续' => 'approve',
    '取消' => 'reject',
    _ => option,
  };
}

/// 设置页（占位）。
class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Center(child: Text('设置项待接入（同步目录 / 范围 / 媒体开关）')),
    );
  }
}

/// 悬浮输入窗页面。
///
/// 生产环境的真实悬浮窗是**独立窗口**（`WindowSpec.quickCapture`）；
/// 此路由用于在无多窗口能力时（或作为主窗口内的调试入口）渲染同一页面。
class _QuickCapturePage extends ConsumerWidget {
  const _QuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureUseCaseProvider);

    return QuickCapturePage(
      submit: (input) => useCase.submit(input: input),
      onQueued: (outcome) {
        // 无归属入口提交成功后导航到服务端判定的对话。
        //
        // 注意**不回显**（不传 echoInto）：本页只是悬浮窗，没有可见的对话；
        // 回显要到目标对话页由 `_focus` 的 timeline 回填完成。
        if (context.mounted) context.go(SpbRoutes.chat(outcome.groupId));
      },
      onCancel: () {
        // 独立窗口下应关窗；主窗口内的调试入口则退回列表。
        if (context.mounted) context.go(SpbRoutes.home);
      },
    );
  }
}
