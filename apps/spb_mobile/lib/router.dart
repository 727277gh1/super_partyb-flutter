import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:spb_features/spb_features.dart';

import 'providers.dart';

/// 路由路径常量（集中定义，避免 `context.go` 与路由表两处字面量不一致）。
class SpbRoutes {
  const SpbRoutes._();

  static const conversations = '/';
  static const settings = '/settings';
  static const quickCapture = '/quick-capture';

  static String chat(String groupId) => '/chat/$groupId';
}

/// 移动端路由表。
///
/// ## 为什么这里用 `StatefulShellRoute.indexedStack`
///
/// 移动端是**底部标签栏**（对话 / 设置），每个标签有**独立的导航栈**：
/// 在「对话」标签里进入某个对话后切到「设置」再切回来，应回到那个对话而非列表。
/// 这正是 shell route 的用途（见 `docs/flutter-component-research.md` §1.2）。
///
/// 桌面端**不用**它：那边是「列表 + 内容」两栏布局，侧边栏只是布局而非导航栈。
///
/// 用 `indexedStack` 而非 `pageBuilder` 版本：它保留各分支的 widget 状态
/// （滚动位置、输入框内容），符合标签栏的预期行为。
GoRouter createMobileRouter() {
  return GoRouter(
    initialLocation: SpbRoutes.conversations,
    routes: buildMobileRoutes(),
  );
}

/// 移动端路由表（不含 `GoRouter` 实例）。
///
/// 独立导出供测试构造自己的 `GoRouter`（测试需指定 `initialLocation`
/// 并在 pumpWidget 前拿到实例以主动导航）。
List<RouteBase> buildMobileRoutes() {
  return [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          _AppShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: SpbRoutes.conversations,
              builder: (context, state) => const _ConversationsTab(),
              routes: [
                GoRoute(
                  path: 'chat/:groupId',
                  builder: (context, state) =>
                      _ChatPage(groupId: state.pathParameters['groupId'] ?? ''),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: SpbRoutes.settings,
              builder: (context, state) => const _SettingsTab(),
            ),
          ],
        ),
      ],
    ),
    // 悬浮输入窗在 shell **之外**：它是一个整屏的临时页面，不应带标签栏，
    // 也不应占据某个标签的导航栈。
    GoRoute(
      path: SpbRoutes.quickCapture,
      builder: (context, state) => const _QuickCapturePage(),
    ),
  ];
}

/// 底部标签栏外壳。
class _AppShell extends StatelessWidget {
  const _AppShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        // goBranch 会切到对应分支并恢复它的导航栈。
        onDestinationSelected: navigationShell.goBranch,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '对话',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 「对话」标签：对话列表。
class _ConversationsTab extends ConsumerWidget {
  const _ConversationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(chatApiProvider);
    return GroupListPage(
      api: api,
      onOpenGroup: (group) => context.go(SpbRoutes.chat(group.id)),
    );
  }
}

/// 「设置」标签（占位）。
class _SettingsTab extends StatelessWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Center(child: Text('设置项待接入（同步目录 / 范围 / 媒体开关）')),
    );
  }
}

/// 对话时间线。
class _ChatPage extends ConsumerStatefulWidget {
  const _ChatPage({required this.groupId});

  final String groupId;

  @override
  ConsumerState<_ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<_ChatPage> {
  String? _focused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus());
  }

  @override
  void didUpdateWidget(_ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) _focus();
  }

  /// 聚焦到当前 group。
  ///
  /// 用 `_focused` 去重：`switchGroup` 会清空缓冲并重新回填 timeline，
  /// 若每次 rebuild 都调用会导致列表反复闪烁。
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
        // 服务端 `misc.go:resolve` 绑定 `{action, comment}`，把 action 写进
        // `resolved_action`，status 固定 `resolved`（受 CHECK 约束：
        // pending|resolved|expired|cancelled）。故必须传**动作**而非状态词。
        api
            .resolveConfirmation(
              confirmationId,
              action: _optionToAction(option),
            )
            .catchError((Object e) => debugPrint('确认提交失败: $e'));
      },
    );
  }

  static String _optionToAction(String option) => switch (option) {
    '继续' => 'approve',
    '取消' => 'reject',
    _ => option,
  };
}

/// 悬浮输入窗页面。
class _QuickCapturePage extends ConsumerWidget {
  const _QuickCapturePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useCase = ref.watch(quickCaptureUseCaseProvider);

    return QuickCapturePage(
      submit: (input) => useCase.submit(input: input),
      onQueued: (outcome) {
        // 提交成功后导航到服务端判定的对话。不回显（不传 echoInto）：
        // 本页没有可见的对话，回显由目标对话页的 timeline 回填完成。
        if (context.mounted) context.go(SpbRoutes.chat(outcome.groupId));
      },
      onCancel: () {
        if (context.mounted) context.go(SpbRoutes.conversations);
      },
    );
  }
}
