import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'confirmation_card.dart';

/// 待办面板：把需要用户介入的项按轮次聚合。
///
/// ## 它解决什么（与时间线内联卡的边界）
///
/// 确认卡在时间线里已有内联渲染（[ConfirmationCard]）。本面板不是替代，
/// 而是**跨轮次的聚合视图**：时间线里确认卡夹在对话流中，用户向上滚几屏后
/// 就看不到「还有一张卡在等我」。本面板把所有未处理的确认卡按轮次集中呈现，
/// 最新轮次在最上——用户打开侧边栏就能看到「现在有什么在等我」。
///
/// 两者**并存**：删掉时间线内联渲染会丢失「这轮 agent 停下来问我」的上下文
/// （对齐 webapp：确认卡从消息流迁到侧边栏后消息流仍留轻量引导行）。
///
/// ## 移动端也受益
///
/// 移动端没有侧边栏，但它用的是同一个 `ConversationPage`（内联渲染）。
/// 本面板只在桌面端侧边栏装配，移动端不受影响也不受损。
///
/// ## 注入式
///
/// 数据（[turns]）与动作（[onResolve]）全部注入，页面不碰 `spb_api`——
/// 与 `AgentFileCard` / `GroupDeliverablesPanel` 同一约定，可在无头环境
/// 用内存桩完整验证。
class GroupTodosPanel extends StatefulWidget {
  const GroupTodosPanel({
    super.key,
    required this.turns,
    this.onResolveConfirmation,
    this.resolvingIds = const {},
    this.emptyHint = '没有待处理的确认',
    this.showHeader = true,
    this.reloadKey,
  });

  /// 按轮次分组的对话项（由 `groupItemsByTurn` 产出，最新轮次在前）。
  final List<TurnGroup> turns;

  /// 确认卡作答回调。参数为（group id, 卡行 id, 选项文案）。
  ///
  /// 为 null 时按钮禁用（只读展示）。
  final void Function(String groupId, String confirmationId, String option)?
  onResolveConfirmation;

  /// 正在提交的确认卡行 id 集合（防重复点击 + 展示 spinner）。
  final Set<String> resolvingIds;

  final String emptyHint;

  /// 是否渲染自带标题行（tab 内容通常由外层提供标题）。
  final bool showHeader;

  /// 切换对话时重置展开状态（Flutter 会复用本 State）。
  final Object? reloadKey;

  @override
  State<GroupTodosPanel> createState() => _GroupTodosPanelState();
}

class _GroupTodosPanelState extends State<GroupTodosPanel> {
  /// 已折叠的轮次 id。默认全部展开（待办不多，展开能一屏看完）。
  ///
  /// 用「折叠集合」而非「展开集合」：新增的轮次默认展开，不需要显式登记。
  final _collapsed = <String>{};

  @override
  void didUpdateWidget(GroupTodosPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) {
      // 换对话：旧对话的折叠状态没有意义，且 turnId 不会复用。
      _collapsed.clear();
    }
  }

  /// 有待办的轮次（含未解决确认卡的）。
  ///
  /// ## 为什么过滤掉无待办的轮次
  ///
  /// 一个对话可能几十轮，绝大多数没有待确认项。全部渲染会让用户滚很久才
  /// 找到那张卡。只留有内容的轮次（对齐 webapp `ChatWorkbenchSidebar` 的
  /// `if (!hasTodo) return null`）。
  List<TurnGroup> get _turnsWithTodos =>
      widget.turns.where((t) => t.pendingConfirmations.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final turns = _turnsWithTodos;

    if (turns.isEmpty) {
      return Center(
        key: const ValueKey('todos-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.task_alt,
                size: SpbSpacing.xxl,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                widget.emptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      key: const ValueKey('todos-list'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
      itemCount: turns.length + (widget.showHeader ? 1 : 0),
      itemBuilder: (context, index) {
        if (widget.showHeader) {
          if (index == 0) return _header(context, turns.length);
          return _turnCard(context, turns[index - 1]);
        }
        return _turnCard(context, turns[index]);
      },
    );
  }

  Widget _header(BuildContext context, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.md,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(
            Icons.pending_actions,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(child: Text('待处理', style: theme.textTheme.titleSmall)),
          Text(
            '$count 轮',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _turnCard(BuildContext context, TurnGroup turn) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pending = turn.pendingConfirmations;
    final collapsed = _collapsed.contains(turn.turnId);

    return Card(
      key: ValueKey<String>('todo-turn-${turn.turnId}'),
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 轮次头：用户输入摘要 + 待办数 + 折叠开关。
          InkWell(
            key: ValueKey<String>('todo-turn-header-${turn.turnId}'),
            onTap: () => setState(() {
              if (collapsed) {
                _collapsed.remove(turn.turnId);
              } else {
                _collapsed.add(turn.turnId);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.all(SpbSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: SpbSpacing.lg,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: SpbSpacing.xs),
                  Expanded(
                    child: Text(
                      turn.userInput.isEmpty ? '（无输入）' : turn.userInput,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: SpbSpacing.xs),
                  // 待办计数徽标。
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SpbSpacing.xs,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(SpbRadius.pill),
                    ),
                    child: Text(
                      '${pending.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpbSpacing.sm,
                0,
                SpbSpacing.sm,
                SpbSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final c in pending)
                    Padding(
                      padding: const EdgeInsets.only(top: SpbSpacing.xs),
                      child: ConfirmationCard(
                        key: ValueKey<String>('todo-conf-${c.confirmationId}'),
                        question: c.question,
                        options: c.options,
                        resolved: c.resolved,
                        busy: widget.resolvingIds.contains(c.confirmationId),
                        // 面板只展示未解决卡（pendingConfirmations 已过滤），
                        // 但仍走 canResolve 守卫：缺 confirmation_id / group_id
                        // 的异常载荷应禁用按钮，而不是退化用事件 id 去试。
                        onResolve:
                            widget.onResolveConfirmation != null && c.canResolve
                            ? (option) => widget.onResolveConfirmation!(
                                c.groupId,
                                c.confirmationId,
                                option,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
