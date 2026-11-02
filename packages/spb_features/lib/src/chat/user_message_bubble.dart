import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

/// 用户发出的消息气泡（右对齐）。
///
/// 纯展示组件：无状态、无回调。用户消息在发出后不可编辑，故不需要交互——
/// 唯一的例外是复制（只读操作，不改变消息本身）。
///
/// [pending] 为 true 时（issue #52：请求在飞、服务端 turnId 尚未落地），
/// 正文降为半透明并显示「发送中」指示；转正或服务端权威帧到达后
/// （归约层把 `pending` 置回 false）恢复正常。
class UserMessageBubble extends StatelessWidget {
  const UserMessageBubble({
    super.key,
    required this.text,
    this.pending = false,
  });

  final String text;

  /// 请求在飞：与 [AssistantMessageBubble.isStreaming] 同一取向的短暂状态，
  /// 由归约层 [UserMessageItem.pending] 派生，气泡自身不持有状态。
  final bool pending;

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
                  // 发送中：降为半透明，与助手气泡流式态的取向一致（提示
                  // 「这条还未被服务端确认」）。
                  color: scheme.onPrimaryContainer.withValues(
                    alpha: pending ? 0.6 : 1.0,
                  ),
                ),
              ),
              // 发送中指示：请求落地（转正/权威帧）前显示，与正文间距同
              // 复制按钮（sm）。文字用 bodySmall，与助手气泡的「正在生成…」
              // 占位同一档，避免视觉突兀。
              if (pending)
                Padding(
                  padding: const EdgeInsets.only(top: SpbSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: SpbSpacing.md,
                        height: SpbSpacing.md,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: SpbSpacing.sm),
                      Text(
                        '发送中…',
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
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
              // ## 为什么现在条件可用（原为无条件）
              //
              // pending 期间消息尚未被服务端确认（可能被 outbox 改写或失败
              // 移除），复制入口只对「已定稿」内容有意义；转正后恢复。
              if (!pending)
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
