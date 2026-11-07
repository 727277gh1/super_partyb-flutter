import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 小节标题：卡片/分组上方的一行小字。
///
/// ## 为什么带 [highlight] 而不是收一个 TextStyle
///
/// 上提前本仓库有两份私有实现，**并不是同一件事**：
///
///   - `settings_page.dart` 用 `labelLarge` + `colorScheme.primary`（带主色，
///     因为设置页里每个标题下面跟着一张卡，需要与卡片内容拉开层次）；
///   - `work_detail_page.dart` 用 `titleSmall`（无色，工作详情页的标题本身就
///     是内容的一部分，染成主色会与状态色打架）。
///
/// 直接把两份合并成「一种样式」会改变其中一个页面的视觉，而这不是重构该做
/// 的事。故保留为开关：默认无色，设置页传 `highlight: true`。
///
/// ## 为什么是 bool 而不是 `TextStyle?`
///
/// 收 `TextStyle` 会把「哪个主题字段 + 哪个颜色角色」这个决定推给每个调用点，
/// 于是 6 处调用点各写一遍 `Theme.of(context).textTheme.labelLarge?.copyWith(
/// color: Theme.of(context).colorScheme.primary)`——重复从「组件」转移到了
/// 「调用点」，还让换样式需要改多处。让组件库持有这两个变体更合适：它本来就
/// 是「无业务语义的展示约定」该待的地方。
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.highlight = false});

  final String text;

  /// true = 主色 + `labelLarge`（设置页那种「标题下挂卡片」的用法）。
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = highlight
        ? theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)
        : theme.textTheme.titleSmall;

    return Padding(
      padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
      child: Text(text, style: style),
    );
  }
}
