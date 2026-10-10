import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:spb_ui/spb_ui.dart';

/// 全局悬浮输入窗（overlay quick capture）的提交回调。
///
/// ## 为什么参数是「文本 + 附件」而不是一个 Request 对象
///
/// 本页的全部职责就是收集这两样东西。用对象会让「谁负责把 `DroppedFile`
/// 读成字节」这个问题变得含糊——而那个决定有性能后果（大文件不能同步读）。
/// 这里明确：**本页负责读取字节**（它有进度 UI 可以反馈），回调只收结果。
///
/// ## 为什么没有 groupId / agentId
///
/// 与 [QuickCapturePage] 同一约束：这是无归属入口，用类型把「调用方不指定
/// 归属」钉死。见 [QuickCaptureSubmit] 的说明。
typedef OverlaySubmit = Future<QuickCaptureEnqueueResult> Function({
  required String input,
  required List<QuickCaptureAttachment> attachments,
  void Function(int done, int total)? onUploadProgress,
});

/// 单个附件的上限（字节）。
///
/// ## 为什么客户端也要设一个上限
///
/// 服务端（mq-server）有自己的上限（默认 50 MiB，可配）。客户端设这个是
/// **体验**考虑而非安全：让用户立刻知道「这个文件太大了」，而不是上传到
/// 99% 才被 413 拒绝。故取值与服务端默认一致，但**不作为唯一防线**——
/// 服务端返回 413 时仍要正确处理（见 [_OverlayQuickCapturePageState._submit]）。
///
/// 若服务端把上限调小，客户端这个值会偏大：用户仍会看到服务端的 413 提示，
/// 只是晚了一点。这个偏差是可接受的（反过来调大才会造成误导）。
const int kOverlayMaxAttachmentBytes = 50 * 1024 * 1024;

/// 全局悬浮输入窗页面。
///
/// ## 用途
///
/// 一个置顶的紧凑输入框：用户按 `Alt+Space` 唤起，打一句话（可拖入文件），
/// 回车提交。由服务端决定这句话属于哪个对话——与 MQ inbound 同语义
/// （两者都没有对话 UI）。
///
/// ## 与 [QuickCapturePage] 的关系
///
/// [QuickCapturePage] 走 `/me/quick-capture`（同步返回归属，可导航，**无附件**）。
/// 本页走 `/me/quick-capture/enqueue`（异步投递，**支持附件**）。
/// 两者共用同一套键盘约定与提示语义，但本页多了附件管理。
///
/// 选 enqueue 而非 quick-capture 的唯一理由是附件：附件的「落用户级暂存区 →
/// 建 turn 时搬进 workspace」这条链路只存在于 MQ 渠道。纯文本提交用哪个都行，
/// 但为了行为一致（同一入口不应因有无附件而改变返回语义），本页**统一**走 enqueue。
///
/// ## 键盘约定
///
/// | 按键 | 行为 |
/// |---|---|
/// | `Enter` | 提交（Shift+Enter 换行） |
/// | `Esc` | 清空输入；已空时关窗 |
/// | `Ctrl+V` | 粘贴剪贴板中的图片/文件 |
///
/// `Esc` 的两段语义是有意的：悬浮窗最常见的误触是「按 Esc 想清掉刚打的字，
/// 结果窗关了」。空输入时才关窗让这个操作可预期。
///
/// ## 页面不导航
///
/// 投递是异步的（worker 消费后才建 turn），本页拿不到 groupId，故**不导航**。
/// 提交成功后清空输入并关窗（或保留窗口由上层决定），结果由主窗口订阅 SSE 呈现。
class OverlayQuickCapturePage extends StatefulWidget {
  const OverlayQuickCapturePage({
    super.key,
    required this.submit,
    required this.dragDrop,
    this.onClose,
    this.hintText,
    this.autofocus = true,
  });

  /// 提交实现。生产传 `QuickCaptureEnqueueUseCase.submit` 的适配闭包。
  final OverlaySubmit submit;

  /// 拖拽能力（移动端注入 [NoopDragDropCapability]）。
  ///
  /// 本页用 `isSupported` 决定**提示文案**：不支持的平台不说「可拖入文件」。
  /// 这不是纯文案问题——手机上写着「可拖入文件」而实际上没有拖拽，用户会
  /// 试着拖、发现没反应，然后不知道该点哪里。附件功能本身两条路径都可用
  /// （拖拽 / 文件选择按钮），所以只是提示需要跟着能力走。
  final DragDropCapability dragDrop;

  /// 关闭窗口的回调（Esc 空输入、提交成功后）。
  final VoidCallback? onClose;

  /// 输入框提示语。null 表示按平台能力自动选（支持拖拽时提到拖入）。
  final String? hintText;

  /// 是否自动聚焦。悬浮窗应自动聚焦（唤起即可打字）。
  final bool autofocus;

  @override
  State<OverlayQuickCapturePage> createState() =>
      _OverlayQuickCapturePageState();
}

/// 待提交的附件（UI 层形态：名称 + 大小 + 惰性读取器）。
///
/// ## 为什么不直接用 [DroppedFile]
///
/// [DroppedFile] 的 `length()` 是异步且可能抛（文件在拖入后被删除）。
/// UI 需要在**加入列表时**就把大小拿到（显示「12.3 MB」并做上限预检），
/// 而不是等到提交。故这里在加入时读一次大小，之后列表渲染是纯同步的。
class _PendingAttachment {
  const _PendingAttachment({required this.file, required this.size});

  final DroppedFile file;

  /// 已知字节数。-1 表示读取失败（文件已不可用）。
  final int size;

  String get displayName => file.name;

  String get displaySize {
    if (size < 0) return '大小未知';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get tooLarge => size > kOverlayMaxAttachmentBytes;
}

class _OverlayQuickCapturePageState extends State<OverlayQuickCapturePage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  final _attachments = <_PendingAttachment>[];

  bool _busy = false;
  bool _dragging = false;

  /// 一次性提示（提交结果）。null 表示无提示。
  ///
  /// 用内联提示而非 SnackBar：本窗口很矮，SnackBar 会盖住输入框，且它带自动
  /// 消失计时（widget test 里需要 pumpAndSettle 等待，容易引入时序脆弱性）。
  Hint? _hint;

  /// 上传进度（已完成数 / 总数）。null 表示当前不在上传阶段。
  (int, int)? _uploadProgress;

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

  /// 输入框提示语（未显式指定时按平台能力选）。
  ///
  /// 「可拖入文件」只在真的支持拖拽时才出现：手机上写着这句而实际没有
  /// 拖拽，用户会试着拖、发现没反应。
  String get _hintText =>
      widget.hintText ??
      (widget.dragDrop.isSupported ? '说点什么…（可拖入文件）' : '说点什么…');

  bool get _canSubmit =>
      !_busy && (_controller.text.trim().isNotEmpty || _attachments.isNotEmpty);

  /// 是否有附件超限（超限时禁止提交并给出明确提示）。
  bool get _hasOversizedAttachment =>
      _attachments.any((a) => a.tooLarge || a.size < 0);

  Future<void> _handleSubmit() async {
    if (!_canSubmit) return;
    if (_hasOversizedAttachment) {
      setState(() {
        _hint = const Hint('有附件超过 50 MB 或已不可读，请先移除', HintKind.warn);
      });
      return;
    }

    final text = _controller.text.trim();
    // 先快照再清空：提交是异步的（网络往返），若等它完成再清空，用户在等待
    // 期间会看到输入框里还留着刚发出去的内容，容易误以为没发出去而再按一次
    // Enter（重复投递）。
    final files = _attachments.map((a) => a.file).toList();

    setState(() {
      _busy = true;
      _hint = null;
      _uploadProgress = null;
    });

    try {
      // 附件直接带**路径**交给上传层（不在这里读字节）。
      //
      // ## 为什么不再预先 readBytes
      //
      // 早期实现把每个文件先读成字节再上传，于是 50 MiB 的附件在内存里存两份
      // （本层的 List<int> + 传输层的 multipart 缓冲），而上传发生在用户等待的
      // 同步路径上；多附件时还要同时持有全部字节。带路径后由 Dio 从磁盘流式
      // 读取，内存占用降到定长缓冲区。
      //
      // 剪贴板粘贴是唯一没有路径的来源（字节本就在内存里），回退到 bytes。
      final attachments = <QuickCaptureAttachment>[];
      for (final f in files) {
        final path = f.path;
        if (path != null) {
          attachments.add(QuickCaptureAttachment(path: path, filename: f.name));
          continue;
        }
        try {
          final bytes = await f.readBytes();
          attachments.add(
            QuickCaptureAttachment(bytes: bytes, filename: f.name),
          );
        } on Object catch (e) {
          // 单个文件读失败不阻断整批：与 use case 的「部分失败不阻断」一致。
          // 这里不单独提示（use case 会汇总），只记日志。
          SpbLog.warn('读取附件失败', {'name': f.name, 'error': '$e'});
        }
      }

      final result = await widget.submit(
        input: text,
        attachments: attachments,
        onUploadProgress: (done, total) {
          if (!mounted) return;
          setState(() => _uploadProgress = (done, total));
        },
      );

      if (!mounted) return;

      if (result.delivered) {
        // 成功：清空输入与附件。
        _controller.clear();
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _attachments.clear();
          // 部分附件失败时**不关窗**：让用户看到哪几个没发成功，
          // 否则消息发出去了但少带文件，用户完全无从察觉。
          _hint = result.hasFailedUploads
              ? Hint(
                  '已发送，但 ${result.failedUploads.length} 个附件失败：'
                  '${result.failedUploads.map((f) => f.filename).join('、')}',
                  HintKind.warn,
                )
              : null;
        });
        if (!result.hasFailedUploads) {
          widget.onClose?.call();
        }
      } else {
        // 未投递：**保留输入与附件**（用户多半想重试同一句话，清空会让他重打）。
        setState(() {
          _busy = false;
          _uploadProgress = null;
          _hint = Hint(result.error?.message ?? '提交失败', HintKind.error);
        });
      }
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _uploadProgress = null;
        _hint = Hint('提交失败：${e.message}', HintKind.error);
      });
    }
  }

  void _handleCancel() {
    // 提交中不允许取消：请求已发出，关窗不会撤销它，反而让用户以为没提交。
    if (_busy) return;
    // 两段语义：有内容先清内容，空了才关窗（见类文档）。
    if (_controller.text.isNotEmpty || _attachments.isNotEmpty) {
      setState(() {
        _controller.clear();
        _attachments.clear();
        _hint = null;
      });
      return;
    }
    widget.onClose?.call();
  }

  Future<void> _addFiles(List<DroppedFile> files) async {
    if (_busy) return;
    final added = <_PendingAttachment>[];
    for (final f in files) {
      var size = -1;
      try {
        size = await f.length();
      } on Object catch (e) {
        // 读不到大小（文件已删除/无权限）：仍加入列表并标记 -1，
        // 让用户在列表里看到它并自行移除，而不是静默丢弃。
        SpbLog.warn('读取附件大小失败', {'name': f.name, 'error': '$e'});
      }
      added.add(_PendingAttachment(file: f, size: size));
    }
    if (!mounted) return;
    setState(() {
      _attachments.addAll(added);
      _hint = null;
    });
    // 加入附件后保持焦点：用户下一步多半是打字。
    _focusNode.requestFocus();
  }

  Future<void> _pickFiles() async {
    // 桌面端用 file_selector 的文件选择器（与拖拽互补：有些用户不习惯拖）。
    // 走 spb_platform 的能力接口，移动端会静默返回空。
    final files = await pickFilesForOverlay();
    if (files.isEmpty) return;
    await _addFiles(files);
  }

  Future<void> _pasteFromClipboard() async {
    final files = await readClipboardFiles();
    if (files.isEmpty) return;
    await _addFiles(files);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleCancel();
      return KeyEventResult.handled;
    }

    // Ctrl+V：先尝试作为文件粘贴，失败则交给默认行为（文本粘贴）。
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed) {
      _pasteFromClipboard();
      // 返回 ignored：不阻断文本粘贴（两者可能同时存在）。
      return KeyEventResult.ignored;
    }

    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    // Shift+Enter 换行（多行输入需要）。
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }

    _handleSubmit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent(context);
    // 不支持拖拽的平台原样返回 child（不产生额外 widget 层级）。
    return widget.dragDrop.buildDropZone(
      onFiles: _addFiles,
      onHoverChanged: (hovering) {
        if (!mounted || _dragging == hovering) return;
        setState(() => _dragging = hovering);
      },
      child: content,
    );
  }

  Widget _buildContent(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        // 拖拽悬停时整窗高亮：让用户确认「松手就会加进来」。
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border.all(
            color: _dragging ? scheme.primary : scheme.outlineVariant,
            width: _dragging ? 2 : 1,
          ),
          borderRadius: SpbRadius.bubbleAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(SpbSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_attachments.isNotEmpty) _buildAttachmentList(scheme),
              Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  key: const ValueKey('overlay-input'),
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: widget.autofocus,
                  enabled: !_busy,
                  // 多行 + 限高：输入长内容时最多长到 4 行，之后内部滚动。
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _hintText,
                    prefixIcon: const Icon(Icons.bolt_outlined),
                    suffixIcon: _buildSuffixIcon(),
                  ),
                ),
              ),
              const SizedBox(height: SpbSpacing.sm),
              Expanded(child: _buildFooter(scheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuffixIcon() {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(SpbSpacing.md),
        child: SizedBox(
          width: SpbSpacing.lg,
          height: SpbSpacing.lg,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      key: const ValueKey('overlay-attach'),
      // 不支持拖拽的平台不提「拖入」（见 [_hintText]）。
      tooltip: widget.dragDrop.isSupported ? '添加文件（也可直接拖入）' : '添加文件',
      onPressed: _canSubmit || !_busy ? _pickFiles : null,
      icon: const Icon(Icons.attach_file, size: SpbSpacing.lg),
    );
  }

  Widget _buildAttachmentList(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
      child: Wrap(
        spacing: SpbSpacing.sm,
        runSpacing: SpbSpacing.xs,
        children: [
          for (var i = 0; i < _attachments.length; i++)
            _AttachmentChip(
              key: ValueKey('overlay-attachment-$i'),
              name: _attachments[i].displayName,
              size: _attachments[i].displaySize,
              invalid: _attachments[i].tooLarge || _attachments[i].size < 0,
              onRemove: _busy
                  ? null
                  : () => setState(() => _attachments.removeAt(i)),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Expanded(child: _buildStatusLine(scheme, textTheme)),
        const SizedBox(width: SpbSpacing.sm),
        TextButton(
          key: const ValueKey('overlay-cancel'),
          onPressed: _busy ? null : _handleCancel,
          child: const Text('取消'),
        ),
        const SizedBox(width: SpbSpacing.xs),
        FilledButton(
          key: const ValueKey('overlay-submit'),
          onPressed: _canSubmit && !_hasOversizedAttachment
              ? _handleSubmit
              : null,
          child: const Text('发送'),
        ),
      ],
    );
  }

  Widget _buildStatusLine(ColorScheme scheme, TextTheme textTheme) {
    if (_hint != null) return HintLine(hint: _hint!);

    final progress = _uploadProgress;
    if (progress != null && progress.$2 > 0 && progress.$1 < progress.$2) {
      return Text(
        '正在上传附件 ${progress.$1}/${progress.$2}…',
        style: textTheme.labelSmall?.copyWith(color: scheme.primary),
      );
    }

    if (_dragging) {
      return Text(
        '松开即可添加文件',
        style: textTheme.labelSmall?.copyWith(color: scheme.primary),
      );
    }

    return Text(
      'Enter 提交 · Shift+Enter 换行 · Esc 清空',
      style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}

/// 附件 chip（名称 + 大小 + 移除）。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    super.key,
    required this.name,
    required this.size,
    required this.onRemove,
    this.invalid = false,
  });

  final String name;
  final String size;
  final VoidCallback? onRemove;

  /// 超限或不可读：用错误色标出，提示用户移除。
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = invalid ? scheme.error : scheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: SpbRadius.inputAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            invalid ? Icons.error_outline : Icons.insert_drive_file_outlined,
            size: SpbSpacing.md,
            color: color,
          ),
          const SizedBox(width: SpbSpacing.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: SpbSpacing.xs),
          Text(
            size,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: SpbSpacing.xs),
            // ## 为什么必须包 Semantics（issue #24）
            //
            // 这个按钮**没有任何可见文本**（只是一个 ✕ 图标），屏幕阅读器
            // 在它上面只会念出「按钮」——用户不知道移除的是哪个附件。
            //
            // `label` 带上文件名：一个 chip 一个节点，逐个念出来才分得清。
            // 不能用 `tooltip` 代替——那个 ✕ 只有 `SpbSpacing.md`（16px），
            // 悬浮提示的触控目标太小，且移动端没有悬停。
            Semantics(
              button: true,
              label: '移除附件 $name',
              child: InkWell(
                onTap: onRemove,
                child: Icon(Icons.close, size: SpbSpacing.md, color: color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
