import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_ui/spb_ui.dart';

/// 悬浮输入窗的提交回调。
///
/// ## 为什么参数只有 `input`（而不是也收 groupId）
///
/// 这是**用类型把「无归属」这件事钉死**，而不是靠 code review 或注释约束：
/// 本端点的整个意义就是「调用方不指定归属，由服务端分类链判定」。若回调签名里
/// 留一个 `groupId` 参数，将来总会有人图省事传上「上次落点」——那就绕过了分类链，
/// 把消息塞进了一个未经判定的对话。
///
/// 服务端同样刻意不接受 `group_id`/`agent_id`/`user_id`（见
/// `chat_quick_capture.go` 文件头的安全性说明），故这里在客户端也把口子关掉。
///
/// 生产代码传 `QuickCaptureUseCase.submit`（注意其可选参数 `echoInto` 在此
/// **不应**使用：悬浮窗没有可见的对话，回显无处可显示）。
typedef QuickCaptureSubmit = Future<QuickCaptureOutcome> Function(String input);

/// 悬浮输入窗页面（quick capture）。
///
/// ## 用途
///
/// 一个 640×132 的单行输入框：用户按 `Alt+Space` 唤起，打一句话回车，
/// 由平台决定这句话属于哪个对话（与 MQ inbound 同语义——两者都没有对话 UI）。
/// 尺寸与置顶配置见 `spb_platform` 的 `WindowSpec.quickCapture`。
///
/// ## 键盘约定
///
/// | 按键 | 行为 |
/// |---|---|
/// | `Enter` | 提交 |
/// | `Esc` | 取消（关窗，不提交） |
///
/// ## 页面不导航
///
/// 归属判定结果（`queued` 时的 groupId）通过 [onQueued] **交给上层**，本页
/// 不做路由跳转。理由有二：
///
/// 1. **可测**：页面自身不依赖路由/导航器，widget test 只需断言回调收到什么；
/// 2. **职责**：悬浮窗是一个独立窗口，导航要发生在主窗口（切到该对话并聚焦），
///    这需要跨窗口协调——那是 app 装配层的事，不是本页的事。
///
/// ## 与确认卡（`confirmation_required`）无关
///
/// 本页只在「提交」这一刻存在，不渲染对话内容，故不涉及确认卡。
class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({
    super.key,
    required this.submit,
    this.onQueued,
    this.onCancel,
    this.hintText = '说点什么…',
    this.autofocus = true,
  });

  /// 提交实现。生产传 `QuickCaptureUseCase.submit`。
  final QuickCaptureSubmit submit;

  /// 成功入队后的回调。参数是服务端判定的归属结果。
  ///
  /// 上层据此把**主窗口**导航到 `outcome.groupId`。
  /// 为 null 时仍会成功提交，只是无人处理导航（如嵌入式使用）。
  final void Function(QuickCaptureQueued outcome)? onQueued;

  /// 用户按 Esc 或点取消时的回调（通常关闭本窗口）。
  final VoidCallback? onCancel;

  final String hintText;

  /// 是否自动聚焦。悬浮窗应自动聚焦（唤起即可打字）。
  final bool autofocus;

  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

class _QuickCapturePageState extends State<QuickCapturePage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  bool _busy = false;

  /// 一次性提示（提交结果）。null 表示无提示。
  ///
  /// 用内联提示而非 SnackBar：本窗口只有 132px 高，SnackBar 会盖住输入框，
  /// 且它带自动消失计时（widget test 里需要 pumpAndSettle 等待，容易引入
  /// 时序脆弱性）。内联提示是确定性的。
  Hint? _hint;

  @override
  void initState() {
    super.initState();
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

  bool get _canSubmit => !_busy && _controller.text.trim().isNotEmpty;

  Future<void> _handleSubmit() async {
    if (!_canSubmit) return;
    final text = _controller.text.trim();

    setState(() {
      _busy = true;
      _hint = null;
    });

    try {
      final outcome = await widget.submit(text);
      if (!mounted) return;

      switch (outcome) {
        case QuickCaptureQueued():
          // 成功：清空输入并交出导航目标。
          _controller.clear();
          setState(() {
            _busy = false;
            _hint = null;
          });
          widget.onQueued?.call(outcome);

        case QuickCaptureFeedbackRecorded():
          // 终态：已记为归属反馈，**不导航**、**不等待回答**（服务端没建 turn）。
          // 清空输入让用户可以直接打下一句。
          _controller.clear();
          setState(() {
            _busy = false;
            _hint = const Hint('已记录归属反馈', HintKind.info);
          });

        case QuickCaptureUnknown(:final status):
          // 服务端新增了状态而客户端未适配。不导航（避免停到错误对话），
          // 提示用户「已提交但结果未知」，同时把原始 status 露出便于排查。
          _controller.clear();
          setState(() {
            _busy = false;
            _hint = Hint('已提交（未识别的状态：$status）', HintKind.warn);
          });
      }
    } on SpbError catch (e) {
      if (!mounted) return;
      // 失败时**保留输入**：用户多半想重试同一句话，清空会让他重打一遍。
      setState(() {
        _busy = false;
        _hint = Hint('提交失败：${e.message}', HintKind.error);
      });
    }
  }

  void _handleCancel() {
    // 提交中不允许取消：请求已发出，关窗不会撤销它，反而让用户以为没提交。
    if (_busy) return;
    widget.onCancel?.call();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleCancel();
      return KeyEventResult.handled;
    }

    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    // 单行输入框：不需要 Shift+Enter 换行（换行在此语义下无意义）。
    // 任何 Enter 都提交。
    _handleSubmit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(SpbSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                enabled: !_busy,
                // 单行：WindowSpec.quickCapture 的高度（132）只够一行输入 +
                // 提示行。多行输入会把提示挤出去。
                maxLines: 1,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  prefixIcon: const Icon(Icons.bolt_outlined),
                  suffixIcon: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(SpbSpacing.md),
                          child: SizedBox(
                            width: SpbSpacing.lg,
                            height: SpbSpacing.lg,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            Expanded(child: _buildFooter(scheme)),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Expanded(
          child: _hint == null
              ? Text(
                  'Enter 提交 · Esc 取消',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : HintLine(hint: _hint!),
        ),
        const SizedBox(width: SpbSpacing.sm),
        TextButton(
          key: const ValueKey('quick-capture-cancel'),
          onPressed: _busy ? null : _handleCancel,
          child: const Text('取消'),
        ),
        const SizedBox(width: SpbSpacing.xs),
        FilledButton(
          key: const ValueKey('quick-capture-submit'),
          onPressed: _canSubmit ? _handleSubmit : null,
          child: const Text('发送'),
        ),
      ],
    );
  }
}
