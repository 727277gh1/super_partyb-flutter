import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';

import 'flush_strategy_dialog.dart';

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
/// ## 「立即发送」是什么（与「发送」的区别）
///
/// 「发送」提交的是**输入框里这句话**（`onSubmit`）；「立即发送」请求服务端把
/// **缓冲区里已 pending 的收件箱消息**立即合并成一个 turn（[onFlush]）。
///
/// 两者不是同一件事：平台的两段式模型是「消息先进 `chat_inbox_messages`
/// （pending）→ dispatcher 合并成 turn」。正常情况下 dispatcher 很快消费，
/// 用户感知不到；但当它因任何原因还没跑（或平台刻意攒批）时，用户会看到
/// 「我发出去了但没反应」。「立即发送」就是那条把等待时间归零的入口。
///
/// 故它**不消费输入框内容**，也不因输入框为空而禁用——它的语义是「推一下
/// 已经排队的那些」，与「再发一条新的」无关。
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
    this.draft,
    this.onFlush,
    this.onFlushWithStrategy,
  });

  /// 提交回调。参数是去除首尾空白后的文本。
  ///
  /// 仅在文本非空时调用（空输入不发送）。为 null 或 [enabled] 为 false 时
  /// 输入框禁用。
  final void Function(String text)? onSubmit;

  final bool enabled;
  final String hintText;
  final bool autofocus;

  /// 外部追加文本到输入框的通道（copy_text 动作的「回填输入框」路径）。
  ///
  /// ## 为什么用 ValueNotifier 而不是 TextEditingController 上提
  ///
  /// controller 上提后，发送清空、监听重建这些状态机细节就暴露给外部了，
  /// 调用方很容易直接 setText 破坏「发送后清空」的约定。ValueNotifier 只开一个
  /// 单向口子：外部追加，内部合并（追加到现有草稿尾部，不覆盖用户已输入的内容），
  /// 消费后自动清空（同一文本不会被追加两次）。
  final ValueNotifier<String>? draft;

  /// 「立即发送」回调：请求服务端把 pending 收件箱消息立即合并成 turn。
  ///
  /// null = 不显示该入口（如移动端或未接线时）。
  ///
  /// ## 为什么不是 `VoidCallback`
  ///
  /// 它要等一个网络往返，期间按钮必须禁用（防重复点）并向用户反馈结果
  /// （服务端可能返回「多条待确认，请选策略」——那不是成功）。这些都需要
  /// 一个可 await 的返回值，页面自己管理在途状态。
  ///
  /// ## 为什么返回 [FlushResult] 而不是 `void`
  ///
  /// 服务端在「有**多条** pending 且未指定 `conflict_strategy`」时返回
  /// **HTTP 200** 加 `confirmation_required`——**什么都没提交**，要求调用方
  /// 选一个策略后重试。返回 `void` 会把这种「待确认」当成成功，用户点完以为
  /// 发好了（这正是修复前的功能性死锁）。
  ///
  /// 选策略与重试由本组件自己完成（见 [onFlushWithStrategy] 与
  /// `runFlushFlow`），故调用方只需实现「发一次请求」。
  final FlushPending? onFlush;

  /// 按用户选定的冲突策略重新提交（[onFlush] 返回待确认时才会用到）。
  ///
  /// null = 不提供选策略能力，此时待确认会作为错误上报（用户至少知道
  /// 「一条都没发出去」）。
  final FlushWithStrategy? onFlushWithStrategy;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// 「立即发送」是否在途（防重复点 + 禁用按钮）。
  bool _flushing = false;

  @override
  void initState() {
    super.initState();
    // 输入框的「发送」按钮启用态依赖文本内容，故需监听变化重建。
    _controller.addListener(_onTextChanged);
    // 外部追加草稿（copy_text → 回填输入框）：追加到现有内容尾部，
    // 不覆盖用户已输入的内容；消费后清空 notifier，避免重复追加。
    widget.draft?.addListener(_onDraftAppend);
  }

  void _onDraftAppend() {
    final text = widget.draft?.value ?? '';
    if (text.isEmpty) return;
    widget.draft!.value = '';
    final existing = _controller.text;
    _controller.text = existing.isEmpty ? text : '$existing\n$text';
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    _focusNode.requestFocus();
  }

  @override
  void didUpdateWidget(covariant MessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.draft != oldWidget.draft) {
      oldWidget.draft?.removeListener(_onDraftAppend);
      widget.draft?.addListener(_onDraftAppend);
    }
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

  /// 「立即发送」：请服务端把 pending 消息立即合并成 turn。
  ///
  /// ## 为什么不禁用「输入框为空」的情况
  ///
  /// 本动作操作的是**已排队的收件箱消息**，与输入框里有没有新草稿无关。
  /// 若按输入框内容禁用，用户在「已经发出去但平台没反应」时反而找不到这个
  /// 按钮——而那正是它唯一的用途。
  ///
  /// ## 为什么错误必须在这里处理（不能上抛）
  ///
  /// `onPressed: _flush` 会**丢弃**返回的 Future（Flutter 的 onPressed 是
  /// `VoidCallback`，不接受 Future）。若这里不 catch，一次网络失败就会变成
  /// **未处理的异步异常**（测试里报 uncaught error，生产里进 zone 的全局
  /// 错误处理），而上层**根本无从捕获**——它没有任何地方 await 这个 Future。
  ///
  /// 故失败反馈的责任在本组件（与 `ConversationPage._handleSubmit` 同一
  /// 做法：catch `SpbError` → SnackBar）。
  ///
  /// 非 `SpbError` 的异常（编程错误）也一并 catch：它们是**意外**，但不该让
  /// 用户点了按钮后什么都没有发生。记日志（供排查）+ 给一句通用提示。
  Future<void> _flush() async {
    final cb = widget.onFlush;
    if (cb == null || _flushing) return;
    setState(() => _flushing = true);
    try {
      // 完整流程（含「待确认 → 选策略 → 重试」）在共享函数里，因为
      // `PendingMessagesBar` 有第二个入口，两者行为必须一致。
      await runFlushFlow(
        context,
        flush: cb,
        flushWithStrategy: widget.onFlushWithStrategy,
      );
    } on SpbError catch (e) {
      _showFlushError('立即发送失败：${e.message}');
    } on Object catch (e, st) {
      SpbLog.warn('立即发送抛非 SpbError 异常', {'error': '$e', 'stack': '$st'});
      _showFlushError('立即发送失败');
    } finally {
      // 无论成功失败都要复位：不复位会让按钮永久禁用。
      if (mounted) setState(() => _flushing = false);
    }
  }

  /// 展示「立即发送」的错误。
  ///
  /// ## 为什么用 SnackBar 而不是内联提示
  ///
  /// 输入区没有可容纳提示行的位置（它已经排了输入框 + 发送按钮 + 快捷键
  /// 说明，再加一行会把输入框挤窄）。`ConversationPage._handleSubmit` 的发送
  /// 失败提示也用 SnackBar，保持一致。
  ///
  /// 无 Scaffold 时（组件被孤立测试）静默降级，不抛异常。
  void _showFlushError(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
          // 「立即发送」入口（仅接线时出现）。
          //
          // 用 tooltip 说明它与「发送」的区别：两个按钮相邻且图标都是发送类，
          // 不解释的话用户会以为重复了。
          if (widget.onFlush != null) ...[
            IconButton(
              key: const ValueKey('composer-flush'),
              onPressed: _flushing ? null : _flush,
              tooltip: '立即发送（把已排队的消息马上合并提交）',
              icon: _flushing
                  ? const SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.flash_on_outlined, size: SpbSpacing.lg),
            ),
            const SizedBox(width: SpbSpacing.xs),
          ],
          // 用 IconButton + tooltip 而非纯图标：桌面端 tooltip 能提示快捷键。
          IconButton.filled(
            key: const ValueKey('composer-send'),
            onPressed: _canSubmit ? _submit : null,
            tooltip: '发送（Enter）',
            icon: const Icon(Icons.send, size: SpbSpacing.lg),
          ),
          const SizedBox(width: SpbSpacing.xs),
          // 快捷键说明：窄屏**隐藏**，宽屏保留。
          //
          // ## 为什么必须处理（它是一个真实的窄屏溢出源）
          //
          // 这句文本实测宽 **287.5dp**，且它在 `Row` 里不是 `Expanded`/
          // `Flexible`——于是它把整行撑破：320dp 溢出 104px、360dp 64px、
          // 390dp 34px（接线「立即发送」时；未接线时小 52px）。
          //
          // ## 为什么按宽度隐藏而不是 `Flexible` + 省略号
          //
          // 截断后剩下的会是「Enter 发送 · Shift+En…」——一个比不显示更让人
          // 困惑的半句。而这句话的价值本就只在**桌面端**（有物理键盘、需要知道
          // Enter 与 Shift+Enter 的区别）；手机是软键盘，回车键行为由
          // `textInputAction` 决定，这行说明对移动端用户无意义。
          //
          // 阈值用 `SpbBreakpoints.compact`（720dp）而不是「刚好够放下」的
          // 实测值：说明文本的出现与否不该随「几个像素」抖动，且 720 以下
          // 一律是单栏窄屏，正是它的适用场景分界。
          if (!SpbBreakpoints.isCompact(MediaQuery.sizeOf(context).width))
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
