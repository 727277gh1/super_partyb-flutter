import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 侧边栏的一个 tab 定义。
///
/// [content] 在 `IndexedStack` 中**始终被挂载**（不只切到的那个），保证切换
/// 时各 tab 的内部状态（展开的目录、折叠的轮次等）不丢失。
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

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, (widget.tabs.length - 1).clamp(0, 1));
  }

  @override
  void didUpdateWidget(ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // tabs 缩短后保持 index 合法。
    if (_index >= widget.tabs.length) {
      _index = (widget.tabs.length - 1).clamp(0, 1);
    }
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
              onTap: () => setState(() => _index = i),
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

  Widget _tabContent() {
    return IndexedStack(
      key: const ValueKey('sidebar-content'),
      index: _index,
      children: widget.tabs.map((t) => t.content).toList(),
    );
  }
}
