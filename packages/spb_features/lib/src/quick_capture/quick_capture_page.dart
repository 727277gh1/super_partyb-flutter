import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_api/spb_api.dart';
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

/// 「预览会用哪个 agent」的查询回调（路由预览）。
///
/// ## ⚠️ 它**不**预览归属 group
///
/// 服务端 `POST /users/:uid/chat/routing-preview` 的响应里没有 `group_id`
/// （见 `ChatApi.routingPreview` 的说明）。它只回答「这句话会用哪个 agent」，
/// 且当前只走**兜底默认 agent**（embedding 级联已下线）。
///
/// 故 UI 文案不得写成「将发送到某对话」——那是编造服务端没给的信息。
/// 返回 null 表示未能取得结果（调用方负责展示错误）。
typedef PreviewRouting = Future<RoutingPreview?> Function(String input);

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
/// ## 页面不导航，但**展示**归属判定结果
///
/// 归属判定结果（`queued` 时的 groupId）通过 [onQueued] **交给上层**，本页
/// 不做路由跳转。理由有二：
///
/// 1. **可测**：页面自身不依赖路由/导航器，widget test 只需断言回调收到什么；
/// 2. **职责**：悬浮窗是一个独立窗口，导航要发生在主窗口（切到该对话并聚焦），
///    这需要跨窗口协调——那是 app 装配层的事，不是本页的事。
///
/// 但「交给上层导航」不等于「用户看不到判定结果」：服务端响应里的
/// `matched_title` / `created_group` 正是本次归属的产出（调用方没给 group_id，
/// 归属完全由服务端分类链判定），不展示的话用户会不知道消息去了哪。故本页在
/// 状态行里给一条内联提示，见 [_QuickCapturePageState._queuedNotice]。
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
    this.previewRouting,
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

  /// 路由预览回调。null = 不显示「预览」入口。
  ///
  /// 见 [PreviewRouting]：它预览的是 **agent**，不是归属 group。
  final PreviewRouting? previewRouting;

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

  /// 路由预览是否在途。
  bool _previewing = false;

  /// 最近一次预览结果。null = 尚未预览或已失效。
  ///
  /// ## 为什么在输入变化时清掉
  ///
  /// 预览是对**特定一段文字**的回答。用户改了文字后，旧结果已经不对应了；
  /// 留着它会让人以为「现在也是这个 agent」。
  RoutingPreview? _preview;

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

  void _onTextChanged() => setState(() {
    // 输入一变，之前的预览结果就失效了（见 [_preview] 的说明）。
    // 在 setState 内直接清，避免多一次重建。
    _preview = null;
  });

  /// 预览「这句话会用哪个 agent」。
  ///
  /// ## 为什么不在每次输入时自动预览
  ///
  /// 那会把每一次击键变成一个网络请求（且悬浮窗是全局快捷键唤起的，很可能
  /// 在用户根本没打算发送时触发）。故做成显式动作。
  Future<void> _previewRoute() async {
    final cb = widget.previewRouting;
    if (cb == null || _previewing) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _hint = const Hint('先输入内容再预览', HintKind.warn));
      return;
    }
    setState(() {
      _previewing = true;
      _hint = null;
    });
    try {
      final result = await cb(text);
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _preview = result;
        if (result == null) {
          _hint = const Hint('预览失败', HintKind.error);
        }
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _hint = Hint('预览失败：${e.message}', HintKind.error);
      });
    }
  }

  bool get _canSubmit => !_busy && _controller.text.trim().isNotEmpty;

  /// 把服务端的归属判定结果转成一行提示文案。null = 无可展示的信息。
  ///
  /// ## 为什么必须展示它
  ///
  /// `POST /me/quick-capture` 的**核心产出**就是「这句话属于哪个对话」——
  /// 调用方没给 group_id，归属由服务端分类链判定（与 MQ inbound 同一条链，
  /// 见 AGENTS.md §5.5）。此前这两个字段只被用来拼导航目标，用户看不到
  /// 「判到了哪」或「是不是新建了对话」——静默切组时用户会找不到自己的消息。
  ///
  /// ## 文案对齐 webapp
  ///
  /// webapp 的对应提示是 `ChatPage.groupSwitchNotice.switched`（「消息已发送到
  /// 更匹配的对话：{title}」）与 `.created`（「已开启新对话并发送消息」）。
  /// 本处是同一信息的**更短**版本：悬浮窗只有一行状态区（见 [_buildStatusLine]），
  /// 长文案会被 ellipsis 截掉后半句。
  ///
  /// ## 两个字段都可能缺失
  ///
  /// - `matched_title` 是服务端 `omitempty` 字段，只在切到**别的既有**对话时
  ///   填充（见 Go `pipeline_classify.go` 的 `target.MatchedTitle = chosen.Title`）；
  /// - `created_group` 为 true 表示服务端**新建**了对话。
  ///
  /// 两者皆无（落到既有对话且服务端没回标题）时返回 null——渲染一个只有图标
  /// 没有信息的空壳会让用户以为出了错。此时状态行回到快捷键说明。
  static String? _queuedNotice(QuickCaptureQueued outcome) {
    final title = outcome.matchedTitle;
    final parts = <String>[
      if (title != null && title.isNotEmpty) '已归入「$title」',
      if (outcome.createdGroup) '已新建对话',
    ];
    return parts.isEmpty ? null : parts.join('，');
  }

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
          // 成功：清空输入、交出导航目标，并在状态行留下归属判定结果。
          //
          // 提示用内联文案而非 SnackBar：本窗口只有 132px 高，SnackBar 会盖住
          // 输入框（与 [_hint] 的既有说明同一理由）。
          _controller.clear();
          final notice = _queuedNotice(outcome);
          setState(() {
            _busy = false;
            _hint = notice == null ? null : Hint(notice, HintKind.info);
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
        Expanded(child: _buildStatusLine(scheme, textTheme)),
        const SizedBox(width: SpbSpacing.sm),
        // 预览入口（仅接线时出现）。
        //
        // ## 为什么不另起一行展示结果
        //
        // 本窗口固定 132px 高（见 `WindowSpec.quickCapture`），只够「一行输入
        // + 一行状态」。另起一行会把输入框挤出可视区，而预览结果恰好与提示语
        // 互斥（预览成功清提示、失败写提示），共用这一行不损失信息。
        if (widget.previewRouting != null)
          TextButton(
            key: const ValueKey('quick-capture-preview'),
            onPressed: _busy || _previewing ? null : _previewRoute,
            child: const Text('预览'),
          ),
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

  /// 状态行：优先展示预览结果，其次提示，最后是快捷键说明。
  Widget _buildStatusLine(ColorScheme scheme, TextTheme textTheme) {
    if (_preview != null) return _previewLine(scheme, textTheme);
    if (_hint != null) return HintLine(hint: _hint!);
    return Text(
      'Enter 提交 · Esc 取消',
      style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }

  /// 预览结果行。
  ///
  /// ## 文案必须如实
  ///
  /// 服务端当前只走**兜底默认 agent**（embedding 级联已下线），且响应里
  /// **没有 group_id**。故这里只能说「将使用 agent X」，不能说「将发送到
  /// 某对话」——后者是服务端没给的信息。
  ///
  /// 当 [RoutingPreview.isFallback] 为真时额外标注「兜底」，让用户知道这不是
  /// 「根据内容智能选出」的结果（否则会高估它的智能程度）。
  Widget _previewLine(ColorScheme scheme, TextTheme textTheme) {
    final p = _preview!;
    final name = p.resolvedAgentName;
    final label =
        name ?? (p.resolvedAgentId.isEmpty ? '（未指定）' : p.resolvedAgentId);
    final suffix = p.isFallback ? '（兜底默认）' : '';
    return Row(
      key: const ValueKey('quick-capture-preview-result'),
      children: [
        Icon(Icons.route_outlined, size: SpbSpacing.md, color: scheme.primary),
        const SizedBox(width: SpbSpacing.xs),
        Expanded(
          child: Text(
            '将使用 agent：$label$suffix',
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: scheme.primary),
          ),
        ),
      ],
    );
  }
}
