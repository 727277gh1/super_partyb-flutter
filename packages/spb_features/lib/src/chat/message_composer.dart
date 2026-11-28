import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

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
    this.onNewSession,
    this.onSendAttachments,
    this.voiceRecorder,
    this.onTranscribeAudio,
  });

  final Future<void> Function(ChatAttachmentSubmission submission)?
  onSendAttachments;

  /// 麦克风录音能力。为空时不显示语音输入入口。
  final VoiceRecorder? voiceRecorder;

  /// 将录音发给服务端转写，返回文本后回填到草稿。
  final Future<String> Function(VoiceRecording recording)? onTranscribeAudio;

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

  /// 「清空上下文」回调：装配层调 `POST /chat/groups/:gid/sessions/switch`
  /// （`force_new_session: true`）。
  ///
  /// null = 不显示该入口（未接线时）。
  ///
  /// ## 为什么放在输入栏而不是 AppBar
  ///
  /// webapp 的同一个按钮就在输入栏（`ChatInputArea` 的底行）；而 AppBar 在窄屏
  /// 已经没有余量（issue #31：320dp 下即使收起三个低频入口仍会溢出）。
  ///
  /// ## 为什么本组件自己弹确认框
  ///
  /// 它是本端**唯一**不可撤销的动作（AI 从此不记得之前的对话内容）。确认框是
  /// UI 决策，与动作本身无关——若放在两个 router 里就变成两份实现、两份测试。
  ///
  /// ## 命名：叫「清空上下文」而不是「新对话」
  ///
  /// 它**保留** group（标题、交付物、任务清单、工作区文件全在），只清 pigo 的
  /// session。「新对话」会被读成「新建一个对话」——小程序里的「新建」确实是建
  /// group，用户已经建立了这个预期。详见 docs/design-decisions/chat.md §6.66。
  final Future<void> Function()? onNewSession;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _files = <DroppedFile>[];
  ChatAttachmentSubmission? _attachmentSubmission;
  bool _sendingFiles = false;
  bool _pickingFiles = false;
  String? _attachmentError;
  bool _startingVoice = false;
  bool _recordingVoice = false;
  bool _transcribingVoice = false;
  int _voiceElapsedSeconds = 0;
  String? _voiceError;
  Timer? _voiceTimer;

  static const _maxVoiceDuration = Duration(minutes: 5);

  bool get _canUseVoiceInput =>
      widget.voiceRecorder != null && widget.onTranscribeAudio != null;

  Future<void> _toggleVoiceInput() async {
    if (!_canUseVoiceInput || _startingVoice || _transcribingVoice) return;
    if (_recordingVoice) {
      await _finishVoiceInput();
    } else {
      await _startVoiceInput();
    }
  }

  Future<void> _startVoiceInput() async {
    final recorder = widget.voiceRecorder;
    if (recorder == null) return;
    setState(() {
      _startingVoice = true;
      _voiceError = null;
      _voiceElapsedSeconds = 0;
    });
    try {
      await recorder.start();
      if (!mounted) {
        await recorder.cancel();
        return;
      }
      setState(() {
        _startingVoice = false;
        _recordingVoice = true;
      });
      _voiceTimer?.cancel();
      _voiceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _voiceElapsedSeconds++);
        if (_voiceElapsedSeconds >= _maxVoiceDuration.inSeconds) {
          timer.cancel();
          unawaited(_finishVoiceInput());
        }
      });
    } on VoicePermissionDeniedException {
      if (mounted) {
        setState(() {
          _startingVoice = false;
          _voiceError = '语音输入需要麦克风权限';
        });
        await _showVoicePermissionHelp();
      }
    } catch (error, stackTrace) {
      SpbLog.warn('开始语音录音失败', {'error': '$error', 'stack': '$stackTrace'});
      if (mounted) {
        setState(() {
          _startingVoice = false;
          _voiceError = '无法开始录音，请检查麦克风权限';
        });
      }
    }
  }

  Future<void> _showVoicePermissionHelp() async {
    if (!mounted) return;
    final instructions = voicePermissionSettingsInstructions(
      currentVoicePermissionPlatform(),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('voice-permission-help'),
        title: const Text('需要麦克风权限'),
        content: Text(
          '语音输入需要使用麦克风。请按以下路径在系统设置中启用 PartyB 的麦克风权限，'
          '然后返回并再次点击麦克风：\n\n$instructions\n\n'
          '系统版本不同，设置项名称可能略有差异。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('voice-permission-help-dismiss'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _finishVoiceInput() async {
    if (!_recordingVoice || _transcribingVoice) return;
    final recorder = widget.voiceRecorder;
    final transcribe = widget.onTranscribeAudio;
    if (recorder == null || transcribe == null) return;
    _voiceTimer?.cancel();
    setState(() {
      _recordingVoice = false;
      _transcribingVoice = true;
      _voiceError = null;
    });
    try {
      final recording = await recorder.stop();
      if (!mounted) return;
      final text = (await transcribe(recording)).trim();
      if (!mounted) return;
      if (text.isEmpty) {
        setState(() => _voiceError = '没有识别到语音，请重试');
        return;
      }
      final current = _controller.text;
      final separator = current.isEmpty || current.endsWith('\n') ? '' : '\n';
      final updated = '$current$separator$text';
      _controller.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
    } catch (error, stackTrace) {
      SpbLog.warn('语音转写失败', {'error': '$error', 'stack': '$stackTrace'});
      if (mounted) {
        setState(() => _voiceError = _voiceTranscriptionErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _transcribingVoice = false);
    }
  }

  String _voiceTranscriptionErrorMessage(Object error) {
    if (error is AuthError) {
      return error.isUnauthorized ? '登录已过期，请重新登录' : '没有权限使用语音转写';
    }
    if (error is NetworkError) return '连接语音识别服务失败，请检查网络后重试';
    if (error is ParseError) return '语音识别服务响应异常，请稍后重试';
    if (error is HttpError) {
      final detail = _speechServerErrorDetail(error.body);
      if (detail != null) return detail;
      if (error.statusCode == 404) {
        return '语音识别接口不可用，请联系管理员检查服务端版本';
      }
      if (error.statusCode == 413) {
        return '录音文件超过 12 MiB 限制，请缩短录音后重试';
      }
      if (error.statusCode == 429) return '语音识别请求过于频繁，请稍后再试';
      if (error.isServerError) return '语音识别服务暂时不可用，请稍后重试';
      return '语音转写请求被拒绝（HTTP ${error.statusCode}），请稍后重试';
    }
    return '语音转文字失败，请稍后重试';
  }

  String? _speechServerErrorDetail(String? body) {
    if (body == null || body.isEmpty) return null;
    for (final key in const ['message', 'error']) {
      final jsonValue = RegExp('"$key"\\s*:\\s*"([^"]+)"')
          .firstMatch(body)
          ?.group(1);
      final mapValue = RegExp('(?:^|[{,\\s])$key:\\s*([^,}]+)')
          .firstMatch(body)
          ?.group(1);
      final value = (jsonValue ?? mapValue)?.trim();
      if (value != null && value.isNotEmpty && !_isMachineError(value)) {
        return value;
      }
    }
    return null;
  }

  bool _isMachineError(String value) => RegExp(r'^[a-z0-9_]+$').hasMatch(value);

  Future<void> _cancelVoiceInput() async {
    if (!_recordingVoice) return;
    _voiceTimer?.cancel();
    setState(() {
      _recordingVoice = false;
      _voiceError = null;
    });
    try {
      await widget.voiceRecorder?.cancel();
    } catch (error, stackTrace) {
      SpbLog.warn('取消语音录音失败', {'error': '$error', 'stack': '$stackTrace'});
      if (mounted) setState(() => _voiceError = '取消录音失败');
    }
  }

  String get _voiceElapsedLabel {
    final minutes = (_voiceElapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_voiceElapsedSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _pickFiles() async {
    if (_sendingFiles || _pickingFiles) return;
    setState(() => _pickingFiles = true);
    try {
      final picked = await pickFilesForOverlay();
      if (!mounted) return;
      if (_files.length + picked.length > 10) {
        setState(() => _attachmentError = '一次最多添加 10 个文件');
        return;
      }
      setState(() {
        _files.addAll(picked);
        _attachmentSubmission = null;
        _attachmentError = null;
      });
    } finally {
      if (mounted) setState(() => _pickingFiles = false);
    }
  }

  Future<void> _submitFiles() async {
    final send = widget.onSendAttachments;
    if (send == null || _sendingFiles) return;
    setState(() {
      _sendingFiles = true;
      _attachmentError = null;
    });
    try {
      if (_attachmentSubmission == null) {
        final sources = <QuickCaptureAttachment>[];
        for (final file in _files) {
          if (await file.length() == 0) {
            throw ValidationError('${file.name} 是空文件');
          }
          sources.add(
            QuickCaptureAttachment(
              filename: file.name,
              path: file.path,
              bytes: file.path == null ? await file.readBytes() : null,
            ),
          );
        }
        _attachmentSubmission = ChatAttachmentSubmission(
          input: _controller.text,
          attachments: sources,
        );
      }
      await send(_attachmentSubmission!);
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _files.clear();
        _attachmentSubmission = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(
        () => _attachmentError = e is SpbError ? e.message : '文件读取或发送失败，请重试',
      );
      SpbLog.warn('对话附件发送失败', {'error': '$e'});
    } finally {
      if (mounted) setState(() => _sendingFiles = false);
    }
  }

  /// 「立即发送」是否在途（防重复点 + 禁用按钮）。
  bool _flushing = false;

  /// 「清空上下文」是否在途（同上）。
  bool _startingNewSession = false;

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
    _voiceTimer?.cancel();
    if (_recordingVoice) unawaited(widget.voiceRecorder?.cancel());
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {
    if (!_sendingFiles) _attachmentSubmission = null;
  });

  bool get _canSubmit =>
      widget.enabled &&
      !_sendingFiles &&
      !_pickingFiles &&
      !_recordingVoice &&
      !_transcribingVoice &&
      widget.onSubmit != null &&
      (_controller.text.trim().isNotEmpty || _files.isNotEmpty);

  void _submit() {
    if (!_canSubmit) return;
    if (_files.isNotEmpty) {
      _submitFiles();
      return;
    }
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
      _showActionError('立即发送失败：${e.message}');
    } on Object catch (e, st) {
      SpbLog.warn('立即发送抛非 SpbError 异常', {'error': '$e', 'stack': '$st'});
      _showActionError('立即发送失败');
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
  void _showActionError(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「清空上下文」：确认 → 执行。
  ///
  /// 成功/失败的用户提示**不在这里**：动作本身（`/sessions/switch` 的调用与
  /// 重拉 group）属于装配层，它比本组件更清楚失败原因（例如 group 已归档）。
  /// 本组件只负责两件 UI 事：先问一句、执行期间禁用按钮。
  ///
  /// 但仍要 catch：`onPressed` 会丢弃返回的 Future（它是 `VoidCallback`），
  /// 装配层若漏接某个异常就会变成未捕获的异步异常（§6.24）。
  Future<void> _newSession() async {
    final cb = widget.onNewSession;
    if (cb == null || _startingNewSession) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('new-session-confirm'),
        title: const Text('清空上下文，重新开始？'),
        // 必须写清「什么保留、什么失去」：用户把「新对话」读成「新建 group」
        // 正是因为这个动作保留 group 却不保留记忆。
        content: const Text(
          '本对话的文件、交付物与任务清单都会保留；AI 将不再记得之前的对话内容。'
          '此操作不可撤销。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('new-session-confirm-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('new-session-confirm-ok'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空并重新开始'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _startingNewSession = true);
    try {
      await cb();
    } on SpbError catch (e) {
      // 装配层已经弹过 SnackBar；这里不重复提示，只记日志。
      SpbLog.warn('清空上下文失败', {'error': e.toString()});
    } on Object catch (e, st) {
      SpbLog.warn('清空上下文抛非 SpbError 异常', {'error': '$e', 'stack': '$st'});
      _showActionError('清空上下文失败');
    } finally {
      if (mounted) setState(() => _startingNewSession = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_sendingFiles) return KeyEventResult.handled;

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

    // 宽度门控必须看**本控件自己的可用宽度**，不是窗口宽度（见 [_buildBar]）。
    // LayoutBuilder 放在 Container **外面**：Container 的 padding 会收窄
    // 子树的约束，而这个阈值（[SpbBreakpoints.compact]）表达的是「这一栏够
    // 不够宽」，不是「扣掉内边距后还剩多少」。
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildBar(context, constraints.maxWidth, scheme, textTheme),
    );
  }

  /// 输入区的实际布局体。
  ///
  /// 单独成方法只为把**可用宽度**传进来（`LayoutBuilder` 的约束拿不到窗口
  /// 宽度，而 `MediaQuery` 拿不到「这一栏被侧边栏挤掉多少」）。
  ///
  /// ## 为什么不能用 `MediaQuery.sizeOf(context).width`（2026-11 真实回归）
  ///
  /// 桌面端侧边栏展开时，窗口仍是 1280dp（`isCompact` 判为宽屏），而聊天栏
  /// 只剩 455dp。按窗口宽度放行那句 12px 的快捷键说明，整行溢出 9dp
  /// （`router_workbench_test` 里 13 个用例同时失败，全部是同一个
  /// `RenderFlex overflowed by 9.0 pixels`）。
  ///
  /// 判据换成可用宽度后，窄栏与窄窗得到同一结论：**放不下就不显示**。
  Widget _buildBar(
    BuildContext context,
    double availableWidth,
    ColorScheme scheme,
    TextTheme textTheme,
  ) {
    final hintStyle = SpbType.listMeta(textTheme)!;
    final hintFontSize = hintStyle.fontSize!;
    final hintScale =
        MediaQuery.textScalerOf(context).scale(hintFontSize) / hintFontSize;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.md,
        vertical: SpbSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_files.isNotEmpty)
            Wrap(
              spacing: SpbSpacing.xs,
              children: [
                for (final file in _files)
                  InputChip(
                    label: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: availableWidth * .55,
                      ),
                      child: Text(file.name, overflow: TextOverflow.ellipsis),
                    ),
                    deleteButtonTooltipMessage: '移除附件 ${file.name}',
                    onDeleted: _sendingFiles
                        ? null
                        : () => setState(() {
                            _files.remove(file);
                            _attachmentSubmission = null;
                            _attachmentError = null;
                          }),
                  ),
              ],
            ),
          if (_sendingFiles) const LinearProgressIndicator(),
          if (_attachmentError != null)
            Text(
              _attachmentError!,
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          if (_recordingVoice || _transcribingVoice)
            Padding(
              padding: const EdgeInsets.only(bottom: SpbSpacing.xs),
              child: Row(
                children: [
                  Icon(
                    _recordingVoice ? Icons.mic : Icons.graphic_eq,
                    size: SpbSpacing.md,
                    color: _recordingVoice ? scheme.error : scheme.primary,
                  ),
                  const SizedBox(width: SpbSpacing.xs),
                  Expanded(
                    child: Text(
                      _recordingVoice
                          ? '录音中 $_voiceElapsedLabel · 点停止后转文字'
                          : '正在识别语音…',
                      style: textTheme.bodySmall?.copyWith(
                        color: _recordingVoice ? scheme.error : scheme.primary,
                      ),
                    ),
                  ),
                  if (_recordingVoice)
                    IconButton(
                      key: const ValueKey('composer-voice-cancel'),
                      tooltip: '取消录音',
                      visualDensity: VisualDensity.compact,
                      onPressed: _cancelVoiceInput,
                      icon: const Icon(Icons.close, size: SpbSpacing.md),
                    ),
                ],
              ),
            ),
          if (_voiceError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: SpbSpacing.xs),
              child: Text(
                _voiceError!,
                style: textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.onSendAttachments != null)
                IconButton(
                  key: const ValueKey('composer-attach'),
                  tooltip: '添加文件',
                  onPressed: widget.enabled && !_sendingFiles && !_pickingFiles
                      ? _pickFiles
                      : null,
                  icon: const Icon(Icons.attach_file),
                ),
              // 「清空上下文」：本端唯一不可撤销的动作，故先弹确认。
              //
              // 放在输入栏**左侧**：webapp 同一个按钮也在输入栏；而 AppBar 在窄屏
              // 没有余量（issue #31）。放左侧而不是紧贴发送按钮，是为了不把
              // 「不可撤销」和「发送」放到同一个热区里。
              if (widget.onNewSession != null) ...[
                IconButton(
                  key: const ValueKey('composer-new-session'),
                  onPressed: _startingNewSession || _sendingFiles
                      ? null
                      : _newSession,
                  tooltip: '清空上下文',
                  icon: _startingNewSession
                      ? const SizedBox(
                          width: SpbSpacing.lg,
                          height: SpbSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restart_alt, size: SpbSpacing.lg),
                ),
                const SizedBox(width: SpbSpacing.xs),
              ],
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    enabled:
                        widget.enabled &&
                        widget.onSubmit != null &&
                        !_sendingFiles,
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
              if (_canUseVoiceInput) ...[
                IconButton(
                  key: const ValueKey('composer-voice'),
                  onPressed:
                      _startingVoice ||
                          _transcribingVoice ||
                          _sendingFiles ||
                          !widget.enabled
                      ? null
                      : _toggleVoiceInput,
                  tooltip: _startingVoice
                      ? '正在准备录音'
                      : _transcribingVoice
                      ? '正在识别语音'
                      : _recordingVoice
                      ? '停止录音并转文字'
                      : '语音输入',
                  color: _recordingVoice ? scheme.error : null,
                  icon: _startingVoice || _transcribingVoice
                      ? const SizedBox(
                          width: SpbSpacing.lg,
                          height: SpbSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _recordingVoice ? Icons.stop_circle : Icons.mic,
                          size: SpbSpacing.lg,
                        ),
                ),
                const SizedBox(width: SpbSpacing.xs),
              ],
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
                      : const Icon(
                          Icons.flash_on_outlined,
                          size: SpbSpacing.lg,
                        ),
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
              // 这句文本实测宽 **约 304dp**（12px 令牌，§6.78 由 11px 的
              // `labelSmall` 迁到 `SpbType.listMeta`；11px 时是 287.5dp），且它在
              // `Row` 里不是 `Expanded`/`Flexible`——于是它把整行撑破：320dp
              // 溢出 104px、360dp 64px、390dp 34px（接线「立即发送」时；未接线时
              // 小 52px）。
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
              //
              // `availableWidth` 是**这一栏**的宽度（本控件从 `LayoutBuilder`
              // 拿到的约束），不是窗口宽度：侧边栏展开时窗口 1280 而这一栏 455。
              // 放大字号后也要为输入框保留空间，避免横屏时说明挤出多行输入框。
              if (!SpbBreakpoints.isCompact(availableWidth / hintScale))
                Text(
                  'Enter 发送 · Shift+Enter 换行',
                  style: hintStyle.copyWith(color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
