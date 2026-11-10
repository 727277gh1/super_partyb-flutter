import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 思考过程（可折叠）。
///
/// ## 默认折叠
///
/// 思考内容通常很长且用户多数时候不关心，默认展开会把真正的回复挤到屏幕外。
/// 折叠状态下只显示一行摘要（首行 + 字数）。
///
/// 用 [ExpansionTile] 而非自绘：它自带展开动画、无障碍语义（`expanded` 状态
/// 会被读屏播报）、以及键盘操作。自绘需要重新实现这三样，收益为负。
class ThoughtTile extends StatelessWidget {
  const ThoughtTile({
    super.key,
    required this.text,
    this.isStreaming = false,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool isStreaming;

  /// 是否默认展开。默认折叠（见类文档）。
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 摘要：首行截断。空文本时给占位，避免 ExpansionTile 标题为空白。
    final firstLine = text.isEmpty ? '' : text.split('\n').first;
    final summary = firstLine.length > 60
        ? '${firstLine.substring(0, 60)}…'
        : firstLine;

    return Theme(
      // 去掉 ExpansionTile 的分隔线：它会让「思考」看起来像可交互列表项，
      // 而这里只是一个附属信息块。
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        // 折叠态用紧凑密度，展开后内容自带宽高。
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
        childrenPadding: const EdgeInsets.fromLTRB(
          SpbSpacing.lg,
          0,
          SpbSpacing.lg,
          SpbSpacing.sm,
        ),
        leading: Icon(
          isStreaming ? Icons.psychology : Icons.psychology_outlined,
          size: SpbSpacing.lg,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(
          isStreaming ? '思考中…' : '思考过程',
          style: textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        subtitle: summary.isEmpty
            ? null
            : Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              text,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
