import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 习惯自动执行完成卡（`habit_auto_run_completed`）。
///
/// ## 视觉：绿色「成功」语气，与 [HabitSuggestionCard] 的征询语气区分
///
/// 建议卡是 `secondaryContainer`（中性，等你作答）；本卡是**服务端已经帮你做了**
/// 的正向回执，故用绿色成功色——对齐 webapp 的 `border-success/20 bg-success/5
/// text-success`。两者若同色，用户会以为「又一条要处理的建议」。
///
/// ## 为什么用 `tertiary` 而不是硬编码绿色
///
/// Flutter 的 `ColorScheme` 没有 `success` 角色（Material 3 规范未定义），而
/// `spb_design` 也未引入语义色令牌。直接写 `Colors.green` 会在深色主题下
/// 对比度不足（webapp 的 `globals.css` 专门为暗色把 success 提亮到 55% 亮度）。
/// 本仓库的既有做法是**只用 ColorScheme 角色**（见全仓零 `Colors.green` 命中），
/// 故这里取 `tertiary`——它是 M3 中「与 primary 互补的正向强调色」，且自带
/// 明暗两套值。若将来 `spb_design` 引入语义色，改这一处即可。
///
/// ## 无交互
///
/// 纯通知：没有按钮、没有回调（对齐 webapp 的 reward 分支——它也只渲染
/// 图标 + 标签 + 摘要）。若将来需要跳转「习惯执行历史」，再注入回调；
/// 现在不预留未接线的 API 面。
class HabitAutoRunCard extends StatelessWidget {
  const HabitAutoRunCard({super.key, required this.item});

  final HabitAutoRunItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // 底色用 tertiaryContainer（明暗两套自带），前景取对应的 on 色。
    final bg = scheme.tertiaryContainer;
    final fg = scheme.onTertiaryContainer;

    return Card(
      // 身份键用事件 id：同一事件重放时 Flutter 列表 diff 能认出是同一项。
      key: ValueKey('habit-auto-run-${item.id}'),
      color: bg,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle_outline, size: SpbSpacing.lg, color: fg),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // 标签文案与 webapp 的 `habitTimelineEventLabel` 逐字一致
                    // （「习惯强化」）。刻意**不**用服务端 summary 作标题：
                    // 那是给 IM 渠道的成句，比时间线需要的长得多。
                    '习惯强化',
                    style: textTheme.titleSmall?.copyWith(color: fg),
                  ),
                  const SizedBox(height: SpbSpacing.xs),
                  Text(
                    // 摘要与 webapp 的 `formatHabitAutoRunCompletedSummary`
                    // 同构：`habit 提醒已送达 · <topic>`。
                    'habit 提醒已送达 · ${item.topicLabel}',
                    style: textTheme.bodySmall?.copyWith(color: fg),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
