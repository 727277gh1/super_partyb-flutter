import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// Agent 回复气泡（左对齐）。
///
/// ## 流式光标
///
/// [isStreaming] 为 true 时在文本末尾显示一个闪烁光标。归约层保证
/// `AssistantMessageItem.isStreaming` 只在「该段仍在接收增量」时为 true，
/// 权威帧到达后置 false。
///
/// 光标用 [SelectableText] 无法内联（无法在文本流中间插 widget），故此处用
/// `Text.rich` + 一个 `WidgetSpan` 承载光标。这带来一个取舍：**流式中的文本
/// 不可选择**，而完成后的文本可选择。这是刻意的——流式文本每几十毫秒变一次，
/// 允许选择只会让用户抓到一半就失效。
class AssistantMessageBubble extends StatelessWidget {
  const AssistantMessageBubble({
    super.key,
    required this.text,
    this.isStreaming = false,
  });

  final String text;
  final bool isStreaming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 空文本 + 流式中：显示「思考中」占位，避免出现一个 0 高度气泡
    // （用户会以为卡住）。
    if (text.isEmpty && isStreaming) {
      return Padding(
        padding: SpbSpacing.bubblePadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: SpbSpacing.md,
              height: SpbSpacing.md,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Text('正在生成…', style: textTheme.bodySmall),
          ],
        ),
      );
    }

    final body = Text(
      text,
      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: SpbSpacing.bubblePadding,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: SpbRadius.bubbleAll,
        ),
        child: isStreaming
            ? Text.rich(
                TextSpan(
                  text: text,
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: _StreamingCursor(
                        // 稳定 key：测试与无障碍定位用。
                        key: const ValueKey('assistant-streaming-cursor'),
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
              )
            : body,
      ),
    );
  }
}

/// 流式光标：一个缓慢淡入淡出的方块。
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor({super.key, required this.color});

  final Color color;

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 800ms 一个完整循环（淡入 + 淡出），比 SpbDuration 系列慢——
    // 光标是「背景呼吸」而非交互反馈，太快会抢注意力。
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: SpbSpacing.sm,
        height: SpbSpacing.lg,
        margin: const EdgeInsets.only(left: SpbSpacing.xxs),
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: const BorderRadius.all(Radius.circular(SpbRadius.xs)),
        ),
      ),
    );
  }
}
