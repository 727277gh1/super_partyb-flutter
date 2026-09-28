import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_design/spb_design.dart';

/// 消息输入框。
///
/// ## 键盘约定
///
/// | 按键 | 行为 |
/// |---|---|
/// | `Enter` | 发送 |
/// | `Shift+Enter` | 换行 |
/// | `Esc` | 清空输入 |
///
/// ## 为什么用 `Focus(onKeyEvent:)` 而不是 `Shortcuts`
///
/// `Shortcuts` 走的是「焦点链上最近的 Shortcuts 祖先」——而 `TextField` 内部
/// **自带**一个更近的 `Shortcuts`（`EditableText` 的
/// `_defaultTextEditingShortcuts`），它会先截获 Enter。把自己的 `Shortcuts`
/// 包在外层会被内层抢先，必须靠 `Actions` 重映射才行，那需要知道 Flutter 内部
/// 的 intent 名（跨版本易碎）。
///
/// `Focus.onKeyEvent` 走的是**祖先链冒泡**：EditableText 的 Focus 对 Enter
/// 返回 `ignored`（它靠平台文本输入通道插入换行，而非消费键事件），于是事件
/// 冒泡到本节点的 `onKeyEvent`，在这里处理即可。
///
/// 这条路径由 `message_composer_test.dart` 的按键测试保证——不靠推理。
///
/// ## 为什么不给输入框传 `border`
///
/// `spb_design` 的主题已配好 `inputDecorationTheme`（`isDense` +
/// `SpbRadius.inputAll`）。组件里再传 `border` 会覆盖主题，造成风格漂移。
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.onSubmit,
    this.enabled = true,
    this.hintText = '输入消息…',
    this.autofocus = false,
  });

  /// 提交回调。参数是去除首尾空白后的文本。
  ///
  /// 仅在文本非空时调用（空输入不发送）。为 null 或 [enabled] 为 false 时
  /// 输入框禁用。
  final void Function(String text)? onSubmit;

  final bool enabled;
  final String hintText;
  final bool autofocus;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 输入框的「发送」按钮启用态依赖文本内容，故需监听变化重建。
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  bool get _canSubmit =>
      widget.enabled &&
      widget.onSubmit != null &&
      _controller.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSubmit) return;
    final text = _controller.text.trim();
    // 先清空再回调：回调是异步的（会走网络），若等它完成再清空，
    // 用户在等待期间会看到输入框里还留着刚发出去的内容，容易误以为没发出去
    // 而再按一次 Enter（重复发送）。
    _controller.clear();
    widget.onSubmit!(text);
    // 发送后保持焦点：连续对话时不必每次重新点击输入框。
    _focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Esc 清空：比逐字删除快，且与大多数 IM 一致。
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_controller.text.isEmpty) return KeyEventResult.ignored;
      _controller.clear();
      return KeyEventResult.handled;
    }

    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) {
      // Shift+Enter 换行：返回 ignored 让 EditableText 走默认行为。
      return KeyEventResult.ignored;
    }

    _submit();
    // 无论是否真的发出（空文本时 _canSubmit 为 false），都要消费掉 Enter，
    // 否则空输入按 Enter 会在多行输入框里插入一个换行。
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.md,
        vertical: SpbSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled && widget.onSubmit != null,
                autofocus: widget.autofocus,
                // 多行 + 限高：输入长内容时输入框最多长到 6 行，之后内部滚动，
                // 避免输入框把整个时间线挤没。
                minLines: 1,
                maxLines: 6,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(hintText: widget.hintText),
              ),
            ),
          ),
          const SizedBox(width: SpbSpacing.sm),
          // 用 IconButton + tooltip 而非纯图标：桌面端 tooltip 能提示快捷键。
          IconButton.filled(
            key: const ValueKey('composer-send'),
            onPressed: _canSubmit ? _submit : null,
            tooltip: '发送（Enter）',
            icon: const Icon(Icons.send, size: SpbSpacing.lg),
          ),
          const SizedBox(width: SpbSpacing.xs),
          Text(
            'Enter 发送 · Shift+Enter 换行',
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
