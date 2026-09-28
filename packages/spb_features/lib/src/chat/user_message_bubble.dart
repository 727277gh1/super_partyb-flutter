import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 用户发出的消息气泡（右对齐）。
///
/// 纯展示组件：无状态、无回调。用户消息在发出后不可编辑，故不需要交互。
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        // 气泡最宽 80%：单行短消息不拉伸成整行，长消息保留右侧留白以区分
        // 用户与助手（助手消息左对齐、占满宽度）。
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.8,
        ),
        child: Container(
          padding: SpbSpacing.bubblePadding,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: SpbRadius.bubbleAll,
          ),
          child: SelectableText(
            text,
            style: textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
