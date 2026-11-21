import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 待用户确认卡片（`confirmation_required`）。
///
/// ## 为什么用 Card + 按钮而不是 `showModalBottomSheet`
///
/// 桌面端悬浮窗场景下 bottom sheet 的**模态行为**与「置顶小窗」冲突：
/// sheet 会抢占焦点并把内容遮住，而悬浮窗本身就已经很小。故用内联卡片。
/// （见 `docs/flutter-component-research.md` §3.3 的采纳结论。）
///
/// ## resolved 之后不隐藏、只置灰
///
/// 已解决的卡片保留在时间线里（历史记录），但按钮禁用。**不隐藏**的原因：
/// 用户滚动回看时需要看到「当时确认过什么」；隐藏会让上下文缺失，
/// 看起来像 agent 突然开始做某件事。
class ConfirmationCard extends StatelessWidget {
  const ConfirmationCard({
    super.key,
    required this.question,
    required this.options,
    this.resolved = false,
    this.onResolve,
    this.busy = false,
  });

  /// 确认问题正文。
  final String question;

  /// 可选项。服务端 `confirmation_required` 的 payload 可能不给 options
  /// （只有 `recommendation`），此时 [options] 为空，卡片退化为
  /// 「确认 / 取消」两个默认按钮。
  final List<String> options;

  /// 是否已解决（用户已作答或已过期）。true 时按钮禁用。
  final bool resolved;

  /// 用户点选项时的回调。参数是选项文案。
  ///
  /// 为 null 时按钮禁用（只读展示）。
  final void Function(String option)? onResolve;

  /// 请求进行中：按钮显示 loading 并禁用，避免重复点击造成重复 resolve。
  final bool busy;

  /// 服务端未给 options 时的兜底选项。
  ///
  /// 对齐 Go 侧 `chatgate.BuildConfirmationRequiredPayload` 只给
  /// `recommendation.action`（默认 `"continue"`）这一事实——文案与
  /// `misc.go` 的 `confirm`/`reject` 两个端点语义对应。
  static const List<String> defaultOptions = ['继续', '取消'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final effectiveOptions = options.isEmpty ? defaultOptions : options;
    final interactive = !resolved && !busy && onResolve != null;

    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  resolved ? Icons.task_alt : Icons.help_outline,
                  size: SpbSpacing.lg,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Text(
                    resolved ? '已确认' : '需要你的确认',
                    style: textTheme.labelLarge?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.sm),
            SelectableText(
              question,
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: SpbSpacing.md),
            // Wrap 而非 Row：选项文案长度不可控（可能是「修改后继续」这类
            // 长短语），窄窗口下 Row 会溢出。
            Wrap(
              spacing: SpbSpacing.sm,
              runSpacing: SpbSpacing.sm,
              children: [
                for (final option in effectiveOptions)
                  FilledButton.tonal(
                    // 稳定 key：测试与无障碍定位都需要。用选项文案作后缀，
                    // 使同一张卡片的多个按钮可区分。
                    key: ValueKey('confirmation-option-$option'),
                    onPressed: interactive ? () => onResolve!(option) : null,
                    child: Text(option),
                  ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: SpbSpacing.sm),
              Row(
                children: [
                  SizedBox(
                    width: SpbSpacing.md,
                    height: SpbSpacing.md,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: SpbSpacing.sm),
                  Text('提交中…', style: textTheme.bodySmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
