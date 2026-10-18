import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// Gate 决策诊断面板。
///
/// ## 它解决什么
///
/// 展示「agent 为什么自己又跑了一轮 / 为什么停下来」：`adaptive_decision`
/// （Fast Path 规则 / LLM Gate / 重试 Gate 的续跑决策）与 `goal_gate_decision`
/// （任务表驱动的目标判定）。
///
/// ## 为什么默认折叠且是「诊断」定位
///
/// 这些决策是**控制流内部信息**：正常使用对话时用户不需要看它（agent 自己
/// 续跑是预期行为）。但一旦出现「它怎么又跑了」「它为什么停了」这类疑问，
/// 它就是唯一的解释来源。故本面板：
/// - 放在侧边栏的「诊断」tab，不默认展开；
/// - 每条默认折叠，只显示决策徽标 + 来源 + 理由摘要。
///
/// ## 为什么只展示不操作
///
/// Gate 决策是**已发生的事实**，没有「撤销/重做」语义。用户可以做的操作
/// （停止生成、处理确认卡）在别处有专门入口。故本面板是只读的。
class GroupGatePanel extends StatelessWidget {
  const GroupGatePanel({
    super.key,
    required this.decisions,
    this.emptyHint = '这一轮还没有 gate 决策',
    this.showHeader = true,
  });

  /// Gate 决策（按时间正序；本面板内部按**倒序**展示，最新在上）。
  final List<GateDecision> decisions;

  final String emptyHint;

  /// 是否渲染自带的标题行。作为 tab 内容时通常由外层容器提供标题，
  /// 传 false 避免重复。
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (decisions.isEmpty) {
      return Center(
        key: const ValueKey('gate-empty'),
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

    // 最新决策在最上：排障时用户关心「刚刚发生了什么」。
    final ordered = decisions.reversed.toList(growable: false);

    return ListView.builder(
      key: const ValueKey('gate-list'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
      itemCount: ordered.length + (showHeader ? 1 : 0),
      itemBuilder: (context, index) {
        if (showHeader) {
          if (index == 0) return _header(context, ordered.length);
          return _tile(context, ordered[index - 1]);
        }
        return _tile(context, ordered[index]);
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
            Icons.alt_route,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(child: Text('Gate 决策', style: theme.textTheme.titleSmall)),
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

  Widget _tile(BuildContext context, GateDecision d) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = _visual(d, scheme);

    return Card(
      key: ValueKey<String>('gate-${d.id}'),
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
        childrenPadding: const EdgeInsets.fromLTRB(
          SpbSpacing.lg,
          0,
          SpbSpacing.lg,
          SpbSpacing.sm,
        ),
        leading: Icon(icon, size: SpbSpacing.lg, color: color),
        title: Row(
          children: [
            Expanded(
              child: Text(
                d.kind.label,
                style: theme.textTheme.labelLarge?.copyWith(color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SpbSpacing.xs),
            _sourceBadge(context, d),
          ],
        ),
        subtitle: d.reason == null || d.reason!.isEmpty
            ? null
            : Text(
                d.reason!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        children: [
          _detailRow(context, '来源', d.rawSource.isEmpty ? '未知' : d.rawSource),
          if (d.confidence != null)
            _detailRow(
              context,
              '置信度',
              '${(d.confidence! * 100).toStringAsFixed(0)}%',
            ),
          if (d.stopReason != null && d.stopReason!.isNotEmpty)
            _detailRow(context, '停止原因', d.stopReason!),
          if (d.turnId.isNotEmpty) _detailRow(context, '轮次', d.turnId),
          if (d.nextInputPreview != null && d.nextInputPreview!.isNotEmpty) ...[
            const SizedBox(height: SpbSpacing.xs),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('下一步输入预览', style: theme.textTheme.labelSmall),
            ),
            const SizedBox(height: SpbSpacing.xxs),
            Container(
              width: double.infinity,
              padding: SpbSpacing.cardPadding,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: SpbRadius.cardAll,
              ),
              child: SelectableText(
                d.nextInputPreview!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sourceBadge(BuildContext context, GateDecision d) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(SpbRadius.xs),
      ),
      child: Text(
        d.source.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SpbSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  /// 决策 → 图标 + 颜色。
  ///
  /// 用 `switch` 穷举枚举（编译期保证不漏分支）：服务端新增决策类型时，
  /// [GateDecisionKind.unknown] 兜底（已由归约层保证不抛异常）。
  (IconData, Color) _visual(GateDecision d, ColorScheme scheme) {
    return switch (d.kind) {
      GateDecisionKind.autoContinue => (Icons.play_arrow, scheme.primary),
      GateDecisionKind.autoRepeat => (Icons.replay, scheme.primary),
      GateDecisionKind.needConfirmation => (
        Icons.help_outline,
        scheme.tertiary,
      ),
      GateDecisionKind.stop => (Icons.pause_circle_outline, scheme.outline),
      GateDecisionKind.goalCompleted => (Icons.flag, scheme.tertiary),
      GateDecisionKind.goalFailed => (Icons.flag_outlined, scheme.error),
      GateDecisionKind.unknown => (Icons.help_outline, scheme.outline),
    };
  }
}
