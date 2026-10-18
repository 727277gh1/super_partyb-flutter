import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 归属反馈卡（`routing_feedback_request`）。
///
/// 问用户「这条消息归到这个对话，准确吗」，从 payload 的 `options[].label`
/// 渲染按钮——**语义真源在 options，不在 spec**（Go `feedbackRequestPayload`
/// 注释明示：Options 是语义真源，Spec 只是其中一种呈现；客户端不解析 spec
/// 是设计内路径）。
///
/// ## 视觉与 [ConfirmationCard] 对齐
///
/// 同为「要用户作答的卡」：`Card + secondaryContainer` 底、左侧状态图标、
/// Wrap 按钮区、busy 行。差异化只在标题与图标（反馈是征询而非流程阻塞），
/// 让用户能一眼区分「Agent 在等我说继续/取消」与「系统在问归属对不对」。
///
/// ## resolved 之后不隐藏、只置灰
///
/// 与 [ConfirmationCard] 同理由：历史回看需要看到「当时问过什么、答没答」；
/// 隐藏会让上下文缺失。
class FeedbackRequestCard extends StatelessWidget {
  const FeedbackRequestCard({
    super.key,
    required this.question,
    required this.options,
    required this.onResolve,
    this.busy = false,
    this.resolved = false,
  });

  /// 问句（来自 payload 的 `question`，如「这条消息我归到了《X》，准确吗？」）。
  final String question;

  /// 选项的展示文字（来自 payload 的 `options[].label`，服务端只给准确/不准确）。
  final List<String> options;

  /// 用户点选项时的回调。参数是该选项是否表示「准确」。
  ///
  /// 由 app 层把 label 映射成 bool（对齐服务端仅有的两类回执）后调
  /// `ChatApi.resolveFeedback`。为 null 时按钮禁用（只读展示）。
  final void Function(bool correct)? onResolve;

  /// 请求进行中：按钮禁用，避免重复提交。
  final bool busy;

  /// 是否已作答（`routing_feedback` 已到达，或本地提交成功）。true 时按钮禁用。
  final bool resolved;

  /// 服务端未给 options 时的兜底选项。
  ///
  /// 正常数据不会走到这里（Go 侧 BuildClassifyFeedbackRequest 只发
  /// 准确/不准确两项）；保留兜底是为了异常载荷下卡片仍可读、可答。
  static const List<String> defaultOptions = ['准确', '不准确'];

  /// 判断选项文案是否表示「准确」。
  ///
  /// 与 webapp `ChatClassifyFeedbackCard` 的肯定词表同源（子集）：服务端
  /// 只发「准确 / 不准确」两项，这里只需区分这两类文案。
  static bool isCorrectOption(String label) {
    const positive = {'准确', '正确', '对', '是'};
    return positive.contains(label.trim());
  }

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
                  resolved ? Icons.task_alt : Icons.rule,
                  size: SpbSpacing.lg,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Text(
                    resolved ? '已反馈' : '这次归属准确吗？',
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
            // Wrap 而非 Row：与 ConfirmationCard 同理，窄窗口下防溢出。
            Wrap(
              spacing: SpbSpacing.sm,
              runSpacing: SpbSpacing.sm,
              children: [
                for (final option in effectiveOptions)
                  FilledButton.tonal(
                    key: ValueKey('feedback-option-$option'),
                    onPressed: interactive
                        ? () => onResolve!(isCorrectOption(option))
                        : null,
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
                  Text('正在记录…', style: textTheme.bodySmall),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
