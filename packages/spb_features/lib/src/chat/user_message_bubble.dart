import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

/// 用户发出的消息气泡（右对齐）。
///
/// 纯展示组件：无状态、无回调。用户消息在发出后不可编辑，故不需要交互——
/// 唯一的例外是复制（只读操作，不改变消息本身）。
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SelectableText(
                text,
                style: textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
              // 整条正文的复制入口。
              //
              // ## 为什么放在气泡**内**而不是下方
              //
              // 用户气泡是右对齐的窄条，气泡下方是页面的留白。把按钮放在气泡外
              // 会让它看起来像下一条消息的一部分；放在气泡内、右对齐，视觉上
              // 归属于这条消息。
              //
              // ## 为什么无条件是可用（不判流式）
              //
              // 用户消息发出即定稿，没有「还在变」的窗口。
              Align(
                alignment: Alignment.centerRight,
                child: CopyIconButton(text: text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
