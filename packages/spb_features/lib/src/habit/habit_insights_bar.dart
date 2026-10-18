import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 习惯洞察摘要条（`GET /api/chat/habit-insights/summary`）。
///
/// ## 为什么只呈现「建议」与「规则触发」两组数字
///
/// 服务端响应有三部分：`suggestions` / `due_rules` / `signal_coverage`。
/// 本组件渲染前两组里**有产出点**的计数，理由：
///
/// - `due_rules.recalibration.*` 在 Go 版**恒为 0**——Go 侧没有任何地方产出
///   `habit_pattern_recalibrated` 事件（见 `HabitDueRuleInsights` 的类文档）。
///   渲染成「重校准 0 次」会被用户（和读代码的人）理解成「这套习惯从未被
///   重校准过」，而真相是「这个指标在当前后端根本不工作」。**故整块不渲染**，
///   而不是渲染一个 0。这不是「少显示一个数字」，是避免把一个测量缺失
///   当成一个测量结果。
/// - `signal_coverage` 是「用户消息数 vs 路由选中数」的覆盖率，属于路由调试
///   指标，放在习惯页里会让普通用户以为它与自己的习惯有关。
///
/// ## 采纳率在 0 条建议时不显示
///
/// 服务端 `acceptRate` 在 `len(runs) == 0` 时是 `0.0`——它不是一个「0% 采纳率」
/// 的观测，而是「没有可算的分母」。显示「采纳率 0%」会让刚上手的用户以为
/// 自己的建议全被拒绝了。故 `createdCount == 0` 时整块换成一句空态文案。
class HabitInsightsBar extends StatelessWidget {
  const HabitInsightsBar({super.key, required this.insights});

  final HabitInsightsSummary insights;

  /// 服务端 `window.days` 缺失（`window` 整体缺失）时的兜底。
  ///
  /// 用 30 而不是 0：`days` 为 0 会渲染出「近 0 天」，比缺省值更误导。
  static const int kDefaultDays = 30;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final days = insights.days > 0 ? insights.days : kDefaultDays;
    final s = insights.suggestions;
    final d = insights.dueRules;

    return Card(
      key: const ValueKey('habit-insights-bar'),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.insights,
                  size: SpbSpacing.lg,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Text('近 $days 天的习惯表现', style: textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: SpbSpacing.sm),
            if (s == null || s.createdCount == 0)
              Text(
                '这段时间还没有产生过建议。',
                key: const ValueKey('habit-insights-empty'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              Wrap(
                spacing: SpbSpacing.sm,
                runSpacing: SpbSpacing.xs,
                children: [
                  _Metric(label: '建议', value: '${s.createdCount} 条'),
                  // createdCount > 0 才显示（见类文档）。
                  _Metric(
                    label: '采纳率',
                    value: '${(s.acceptRate.clamp(0.0, 1.0) * 100).round()}%',
                  ),
                  _Metric(label: '采纳', value: '${s.acceptedCount}'),
                  _Metric(label: '忽略', value: '${s.dismissedCount}'),
                  _Metric(label: '延后', value: '${s.snoozedCount}'),
                  _Metric(label: '待处理', value: '${s.pendingCount}'),
                ],
              ),
              if (d != null && d.triggerCount > 0) ...[
                const SizedBox(height: SpbSpacing.sm),
                Text(
                  '规则触发 ${d.triggerCount} 次'
                  '${d.totalRuns > 0 ? '，其中 ${d.continuedRuns} 次你继续追问了' : ''}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 单个数字（标签 + 值）。
class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: SpbRadius.cardAll,
      ),
      // 用两个 Text 而非 RichText：`find.text('50%')` 这类断言要能直接命中。
      // RichText 的 TextSpan 不在语义树里作为独立 Text 存在，测试只能靠
      // `findRichText: true` + 整串匹配，很容易写出「断言通过但实际没渲染」的假绿。
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: SpbSpacing.xs),
          Text(
            value,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
