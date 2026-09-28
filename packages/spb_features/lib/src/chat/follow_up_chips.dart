import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 后续提问建议（`follow_up_suggested`）。
///
/// ## 用 ActionChip 而非按钮
///
/// 建议是「轻量快捷入口」而非「必须做的决定」，chip 的视觉权重更低、
/// 更省纵向空间（可并排多个）。见 `docs/flutter-component-research.md` §3.3。
///
/// ## 点击即发送
///
/// 点 chip 直接把建议文本作为下一条消息发出（与 webapp 一致），
/// 不是「填进输入框让用户再按一次发送」——多一步操作没有价值，
/// 因为建议本身就是完整可发送的语句。
class FollowUpChips extends StatelessWidget {
  const FollowUpChips({super.key, required this.suggestions, this.onTap});

  final List<String> suggestions;

  /// 点击某个建议时的回调。为 null 时 chip 不可点（只读展示）。
  final void Function(String suggestion)? onTap;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: SpbSpacing.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: SpbSpacing.sm,
          runSpacing: SpbSpacing.sm,
          children: [
            for (final s in suggestions)
              ActionChip(
                key: ValueKey('follow-up-$s'),
                avatar: Icon(
                  Icons.arrow_forward,
                  size: SpbSpacing.lg,
                  color: scheme.primary,
                ),
                label: Text(s),
                onPressed: onTap == null ? null : () => onTap!(s),
              ),
          ],
        ),
      ),
    );
  }
}
