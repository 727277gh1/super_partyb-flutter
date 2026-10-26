import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'tool_call_tile.dart';

/// 工具调用面板：把 agent 这一轮调用的工具集中呈现。
///
/// ## 它解决什么（与时间线内联瓦片的边界）
///
/// 工具调用在时间线里已有内联渲染（[ToolCallTile]）。本面板是**跨轮次的
/// 诊断视图**：时间线里工具瓦片夹在对话流中，用户向上滚几屏后才看得全一轮
/// 调了哪些工具。本面板把当前缓冲区里所有工具调用集中列出，最新的在最上
/// ——排障时（「它刚才到底跑了什么」）一屏可见。
///
/// 两者**并存**：删掉时间线内联渲染会让对话流失去过程感（用户看不到 agent
/// 在干活），移动端也没有侧边栏可兜。
///
/// ## 为什么是平铺列表而非按 turn 分组
///
/// 工具调用的诊断诉求是「最近调了啥」，turn 边界在这里不是重要的聚类维度
/// （一轮里可能调十几个工具，跨 turn 看也无妨）。对齐 webapp
/// `WorkbenchToolCallsPanel`：它收到的也是扁平的 `TurnToolCall[]`。
///
/// ## 只读
///
/// 工具调用是**已发生的事实**，没有「撤销/重试」语义（重试由 agent 自己的
/// 重试 gate 决定，见诊断面板）。故本面板只展示，不注入动作回调。
class GroupToolCallsPanel extends StatelessWidget {
  const GroupToolCallsPanel({
    super.key,
    required this.toolCalls,
    this.emptyHint = '这一轮还没有工具调用',
    this.showHeader = true,
  });

  /// 工具调用列表（任意顺序；面板内部按**倒序**展示，最新在上）。
  final List<ToolCallItem> toolCalls;

  final String emptyHint;

  /// 是否渲染自带的标题行。作为 tab 内容时通常由外层提供标题，传 false。
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (toolCalls.isEmpty) {
      return Center(
        key: const ValueKey('toolcalls-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Text(
            emptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    // 最新在最上：排障时用户关心「刚才调了什么」。
    final ordered = toolCalls.reversed.toList(growable: false);

    return ListView.builder(
      key: const ValueKey('toolcalls-list'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
      itemCount: ordered.length + (showHeader ? 1 : 0),
      itemBuilder: (context, index) {
        if (showHeader) {
          if (index == 0) return _header(context, ordered.length);
          return _wrap(ordered[index - 1]);
        }
        return _wrap(ordered[index]);
      },
    );
  }

  /// 给 [ToolCallTile] 套一层与门禁面板一致的外边距。
  ///
  /// [ToolCallTile] 自己用 `Card` 包裹，但没有水平外边距——在时间线里靠
  /// 列表 padding 控制间距，在侧边栏里需要显式边距与其它面板视觉对齐。
  Widget _wrap(ToolCallItem t) => Padding(
    key: ValueKey<String>('tool-${t.id}'),
    padding: const EdgeInsets.symmetric(
      horizontal: SpbSpacing.sm,
      vertical: SpbSpacing.xxs,
    ),
    child: ToolCallTile(
      name: t.name,
      args: t.args,
      output: t.output,
      isComplete: t.isComplete,
    ),
  );

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
            Icons.build_outlined,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(child: Text('工具调用', style: theme.textTheme.titleSmall)),
          Text(
            '$count',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
