import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
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
    this.routingReason,
    this.routingSwitched = false,
  });

  final String text;

  /// 请求在飞：与 [AssistantMessageBubble.isStreaming] 同一取向的短暂状态，
  /// 由归约层 [UserMessageItem.pending] 派生，气泡自身不持有状态。
  final bool pending;

  /// 归属判定原因（[UserMessageItem.routingReason] 的透传）。null = 无归属
  /// 信息（多数情况）。
  final String? routingReason;

  /// 静默切换标记（[UserMessageItem.routingSwitched]）：消息被送进了另一个
  /// 对话。多数用户意识不到这件事，徽标是唯一的可见信号。
  final bool routingSwitched;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final notice = routingAttributionNotice(
      reason: routingReason,
      switched: routingSwitched,
    );

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
                style: SpbType.body(textTheme)?.copyWith(
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
              // 归属徽标：仅在有信息量时渲染（新建对话 / 静默切换 / 未知原因），
              // 复用当前对话的常规归属不占任何空间。徽标与复制按钮同行：
              // 复制按钮恒在（非 pending），徽标偶发，共享一行不增加纵向高度；
              // 有无徽标只改这一行的宽度（右对齐，视觉上仍归属气泡内部）。
              if (!pending && notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: SpbSpacing.xs),
                  child: _RoutingAttributionChip(notice: notice),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 气泡内的归属徽标：短标签 + Tooltip（桌面悬停 / 移动端长按）。
///
/// ## 为什么短标签是主要信息、Tooltip 只是辅助
///
/// Tooltip 的触达方式在移动端不可发现（长按属于隐藏手势），且无障碍朗读不会
/// 读 Tooltip——故短标签本身必须可读（「已新建对话」/「已切换对话」），
/// Tooltip 只承载完整解释 + 原始 reason code（排障用），不是唯一的信息通路。
class _RoutingAttributionChip extends StatelessWidget {
  const _RoutingAttributionChip({required this.notice});

  final RoutingAttributionNotice notice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = switch (notice.tone) {
      // 切换/新建：用 tertiary 强调（与主体 primaryContainer 区分开，能被扫到）；
      // 未知原因：中性（不制造虚假的紧迫感）。
      RoutingAttributionTone.switched ||
      RoutingAttributionTone.newGroup => scheme.tertiary,
      RoutingAttributionTone.info => scheme.onPrimaryContainer,
    };
    final message = notice.tooltip;
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          switch (notice.tone) {
            RoutingAttributionTone.switched => Icons.swap_horiz_rounded,
            RoutingAttributionTone.newGroup => Icons.fiber_new_outlined,
            RoutingAttributionTone.info => Icons.alt_route_outlined,
          },
          size: 13,
          color: color,
        ),
        const SizedBox(width: SpbSpacing.xxs),
        Text(
          notice.label,
          style: SpbType.listMeta(textTheme)?.copyWith(color: color),
        ),
      ],
    );
    if (message == null || message.isEmpty) return chip;
    return Tooltip(message: message, child: chip);
  }
}
