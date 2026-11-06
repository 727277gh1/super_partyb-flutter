import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 侧边栏的一个 tab 定义。
///
/// [content] 在 `IndexedStack` 中**被激活后始终挂载**（不只切到的那个），保证
/// 切换时各 tab 的内部状态（展开的目录、折叠的轮次等）不丢失。
///
/// ⚠️ 未被切到过的 tab **不构建**（见 [ChatSidebar] 的惰性加载说明，issue #16）：
/// 故依赖 `initState` 发请求的面板不会在侧边栏一打开时就跑。
@immutable
class ChatSidebarTab {
  const ChatSidebarTab({
    required this.label,
    required this.icon,
    required this.content,
    this.badge = 0,
  });

  final String label;
  final IconData icon;

  /// tab 对应的面板 widget。
  final Widget content;

  /// 徽标计数。<= 0 时不显示徽标。
  ///
  /// 用于「待办」这类有未处理数量的 tab——用户一眼能看到「有东西在等我」。
  final int badge;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatSidebarTab && label == other.label && badge == other.badge;

  @override
  int get hashCode => Object.hash(label, badge);
}

/// 对话侧边栏的 tab 容器。
///
/// 把交付物 / 待办 / Gate 决策 / 工具调用等面板组织成可切换的 tab。
///
/// ## 为什么用自定义 tab 行而不是 Material TabBar
///
/// TabBar 需要嵌在 AppBar 里（Scaffold），而侧边栏本身就是 Scaffold body
/// 的一部分，再嵌一层 Scaffold/AppBar 会导致双 AppBar。自定义行只是一个
/// 可滚动按钮组，没有多余的 chrome。
///
/// ## 为什么用 IndexedStack
///
/// Flutter 默认的 TabBarView 用懒加载，切换 tab 时前一个被销毁。对于侧边栏
/// 这种场景，用户可能在「文件」展开了一个目录树，切到「待办」处理一张卡，
/// 再切回来——这时目录树的展开状态应保留。`IndexedStack` 保持所有子项挂载。
///
/// ## 但挂载 ≠ 立即构建（issue #16）
///
/// `IndexedStack` 会把**所有**子项挂载进树，于是每个面板的 `initState` 都会在
/// 侧边栏一打开时就跑——`GroupDeliverablesPanel` / `GoalHistoryPanel` /
/// `AutoSchedulesPanel` 各自发请求，用户还没点过任何一个 tab 就已经付了 3 个
/// HTTP 往返（加上当前 tab 自己那个，共 4 个）。
///
/// 故未激活过的 tab 先放一个 [SizedBox.shrink] 占位，**首次切到时**才换成真实
/// 面板。既保留了「切回来状态不丢」（已挂载的不会被卸载），又不再为从没看过的
/// tab 付构建与取数成本。
class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.tabs,
    this.initialIndex = 0,
    this.onClose,
    this.showHeader = true,
  });

  /// tab 列表。空列表时回退到「无内容」占位（防止白屏）。
  final List<ChatSidebarTab> tabs;

  final int initialIndex;

  /// 关闭回调。提供时在头部渲染关闭按钮。
  final VoidCallback? onClose;

  /// 是否渲染自带头部（含标题 + 关闭按钮）。
  ///
  /// 默认 true。如果外层容器已提供头部，传 false 避免重复。
  final bool showHeader;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  late int _index;

  /// 已被激活过（被切到过）的 tab 下标。
  ///
  /// ## 为什么不能靠 `initState` 判可见性
  ///
  /// `IndexedStack` 的不可见子项**仍在树里**，它们的 `initState` 照样会跑。
  /// 所以「是否可见」这件事必须由**父层**显式记录——这就是本集合的职责。
  ///
  /// 一旦下标进来就永不移除：已激活的 tab 要保持挂载（滚动位置、展开的
  /// 目录树、折叠的轮次），这正是选 `IndexedStack` 而非 `TabBarView` 的理由。
  final Set<int> _visited = <int>{};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, (widget.tabs.length - 1).clamp(0, 1));
    // 初始 tab 当然算已激活——不记的话首屏会渲染成空占位。
    _visited.add(_index);
  }

  @override
  void didUpdateWidget(ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tabs 缩短后保持 index 合法。
    if (_index >= widget.tabs.length) {
      _index = (widget.tabs.length - 1).clamp(0, 1);
    }
    // 钳制可能把当前下标换成一个从没访问过的值（如 tabs 从 2 个缩到 1 个时
    // 从 1 变 0）。当前 tab **必须**是已激活的，否则首屏变成空占位。
    _visited.add(_index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (widget.tabs.isEmpty) {
      return Material(
        color: scheme.surfaceContainerLowest,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: const Center(child: Text('侧边栏无内容')),
        ),
      );
    }

    return Material(
      // 侧边栏视觉边界：左侧分隔线（与 GroupDeliverablesPanel 同一约定）。
      color: scheme.surfaceContainerLowest,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader) ...[
              _header(context),
              const Divider(height: 1),
            ],
            _tabBar(context),
            const Divider(height: 1),
            Expanded(child: _tabContent()),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.md,
        SpbSpacing.sm,
        SpbSpacing.sm,
        SpbSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.view_sidebar_outlined,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(child: Text('侧边栏', style: theme.textTheme.titleSmall)),
          if (widget.onClose != null)
            IconButton(
              key: const ValueKey('sidebar-close'),
              icon: const Icon(Icons.chevron_right, size: SpbSpacing.xl),
              tooltip: '收起侧边栏',
              onPressed: widget.onClose,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _tabBar(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = theme.colorScheme.primary;

    return SizedBox(
      height: 44,
      child: ListView.builder(
        key: const ValueKey('sidebar-tabbar'),
        scrollDirection: Axis.horizontal,
        itemCount: widget.tabs.length,
        itemBuilder: (context, i) {
          final tab = widget.tabs[i];
          final selected = i == _index;
          final showBadge = tab.badge > 0;

          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SpbSpacing.xxs,
              vertical: SpbSpacing.xs,
            ),
            child: InkWell(
              key: ValueKey<String>('sidebar-tab-${tab.label}'),
              borderRadius: BorderRadius.circular(SpbRadius.sm),
              onTap: () => setState(() {
                _index = i;
                _visited.add(i);
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SpbSpacing.sm,
                  vertical: SpbSpacing.xxs,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? active.withValues(alpha: 0.1)
                      : Colors.transparent,
                  border: selected
                      ? Border.all(color: active.withValues(alpha: 0.2))
                      : null,
                  borderRadius: BorderRadius.circular(SpbRadius.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tab.icon,
                      size: SpbSpacing.md + 2,
                      color: selected ? active : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: SpbSpacing.xs),
                    Text(
                      tab.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selected ? active : scheme.onSurfaceVariant,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                    if (showBadge) ...[
                      const SizedBox(width: SpbSpacing.xs),
                      _badge(tab.badge, scheme),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _badge(int count, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(SpbRadius.pill),
      ),
      constraints: const BoxConstraints(minWidth: SpbSpacing.lg),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer, fontSize: 10),
      ),
    );
  }

  /// tab 内容区。
  ///
  /// 未激活过的下标用 [SizedBox.shrink] 占位（不构建面板 = 不发请求）；
  /// 激活过的渲染真实面板并**一直保留**（见 [_visited] 的说明）。
  Widget _tabContent() {
    return IndexedStack(
      key: const ValueKey('sidebar-content'),
      index: _index,
      children: [
        for (var i = 0; i < widget.tabs.length; i++)
          if (_visited.contains(i))
            widget.tabs[i].content
          else
            const SizedBox.shrink(),
      ],
    );
  }
}
