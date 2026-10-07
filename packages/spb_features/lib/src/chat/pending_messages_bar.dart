import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

import 'flush_strategy_dialog.dart';

/// 加载某个 group 的待处理收件箱消息。
///
/// 生产实现是 `ChatApi.pendingMessages(userId, groupId: groupId)`。
typedef LoadPendingMessages = Future<List<ChatInboxMessage>> Function();

/// 撤销一条待处理消息。
///
/// 参数是 **`ChatInboxMessage.id`**（`chat_inbox_messages.id`），
/// **不是** `turn_id`——撤销操作的是「还没被 dispatcher 合并成 turn 的那条
/// 收件箱记录」，而 turn 一旦生成就无法撤销。
typedef UndoPendingMessage = Future<void> Function(String messageId);

/// 待处理消息栏（对话页输入区上方）。
///
/// ## 它展示的是什么
///
/// `GET /users/:uid/chat/messages/pending` 返回的是 **`chat_inbox_messages` 行**，
/// 不是 `ChatTurn`（字段是 `input` / `agent_type` / `processed_at`）。这是
/// 「消息先进收件箱、再由 dispatcher 合并成 turn」的两段式模型：
///
/// ```
/// 用户输入 ──► chat_inbox_messages(pending) ──► dispatcher ──► chat_turns
///                        ▲                          │
///                        └── 撤销（本组件）──────────┘ 已 committed 则不可撤
/// ```
///
/// 故本栏只在「消息已入收件箱、尚未合并」这个窗口内有意义。窗口很短（dispatcher
/// 通常很快消费），所以空列表是**常态**而非异常——此时本组件不占任何空间。
///
/// ## 为什么页面不自己调 API
///
/// 与 `SearchPage` / `SyncPage` 同构：渲染与交互在本包，网络实现由 app 注入。
/// 这样本组件可以在 widget test 里完整验证（含 409 分支），不需要 HTTP mock。
class PendingMessagesBar extends StatefulWidget {
  const PendingMessagesBar({
    super.key,
    required this.load,
    required this.undo,
    this.flush,
    this.flushWithStrategy,
    this.reloadKey = '',
    this.title = '待处理消息',
  });

  /// 加载待处理消息。
  final LoadPendingMessages load;

  /// 撤销一条消息。
  final UndoPendingMessage undo;

  /// 「立即发送」（按服务端默认策略）。
  ///
  /// null = 不显示发送入口（未接线时）。
  final FlushPending? flush;

  /// 按用户选定的冲突策略重新提交（[flush] 返回待确认时才用到）。
  final FlushWithStrategy? flushWithStrategy;

  /// 变化时重新加载。
  ///
  /// ## 为什么需要它（而不是只在 `initState` 加载一次）
  ///
  /// 从 `/chat/g1` 切到 `/chat/g2` 时，Flutter 会**复用**本组件的 State
  /// （widget 类型与位置都没变），于是 `initState` 不会重跑，列表会一直显示
  /// 上一个 group 的消息。调用方把 groupId 传进来即可——不依赖调用方记得挂
  /// `ValueKey` 这类容易漏的约定。
  final String reloadKey;

  final String title;

  @override
  State<PendingMessagesBar> createState() => _PendingMessagesBarState();
}

class _PendingMessagesBarState extends State<PendingMessagesBar> {
  List<ChatInboxMessage> _messages = const [];
  bool _loading = false;
  SpbError? _error;

  /// 正在撤销的消息 id（逐条标记，不用全局 busy——撤销一条不该禁用其它条）。
  final _undoing = <String>{};

  /// 「立即发送」是否在途（防重复点）。
  bool _flushing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(PendingMessagesBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadKey != widget.reloadKey) {
      // 切换 group：先清空，避免短暂显示上一个 group 的消息（那些 id 在
      // 新 group 里不存在，点撤销会得到 404）。
      setState(() {
        _messages = const [];
        _error = null;
      });
      _reload();
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.load();
      if (!mounted) return;
      setState(() {
        _messages = items;
        _loading = false;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _undo(ChatInboxMessage message) async {
    if (_undoing.contains(message.id)) return;
    setState(() => _undoing.add(message.id));

    try {
      await widget.undo(message.id);
      if (!mounted) return;
      _remove(message.id);
    } on HttpError catch (e) {
      if (!mounted) return;
      if (e.isConflict || e.isNotFound) {
        // ## 409 / 404 是**预期内的业务结果**，不是错误
        //
        // 服务端 `WithdrawChatInboxMessage` 的 WHERE 限定 `status = 'pending'`，
        // 影响行数为 0 时返回 409（已 committed/superseded/withdrawn）或 404
        // （消息不存在）。
        //
        // 这两种情况下**目标状态已经达成**——用户想让它别被执行，而它要么
        // 已经被处理、要么根本不存在。故：
        //
        // 1. 从列表移除（它确实不再是 pending 了；留着只会让用户再点一次、
        //    再失败一次）；
        // 2. 提示原因，而不是显示「撤销失败」（那会让用户以为它还会被执行）。
        //
        // 服务端 409 的错误体是「消息当前状态为 committed，无法撤销」，但
        // `HttpError.message` 只有 `HTTP 409`，故这里给一句用户能看懂的话。
        _remove(message.id);
        _showMessage(e.isConflict ? '已处理，无法撤销' : '消息已不存在');
      } else {
        // 其它 HTTP 错误（403 / 500）：操作**可能没生效**，保留条目让用户重试。
        _showMessage('撤销失败：${e.message}');
      }
    } on SpbError catch (e) {
      if (!mounted) return;
      // 网络失败同样保留条目（重试可能成功）。
      _showMessage('撤销失败：${e.message}');
    } finally {
      if (mounted) setState(() => _undoing.remove(message.id));
    }
  }

  void _remove(String messageId) {
    setState(() {
      _messages = _messages.where((m) => m.id != messageId).toList();
    });
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  /// 「立即发送」：与 `MessageComposer` 的闪电按钮走**同一条**流程
  /// （见 `runFlushFlow` 的说明——两者行为必须一致，否则会出现「一个入口
  /// 能选策略、另一个入口死锁」的形态）。
  ///
  /// 成功后重新加载：提交会把消息标为 committed，本栏的列表必须跟着变，
  /// 否则用户会看到已提交的消息还挂在「待处理」里。
  Future<void> _flush() async {
    final cb = widget.flush;
    if (cb == null || _flushing) return;
    setState(() => _flushing = true);
    try {
      final result = await runFlushFlow(
        context,
        flush: cb,
        flushWithStrategy: widget.flushWithStrategy,
      );
      // result == null = 用户取消了策略选择，什么都没提交，不动列表。
      if (result != null && mounted) await _reload();
    } on SpbError catch (e) {
      _showMessage('立即发送失败：${e.message}');
    } on Object catch (e, st) {
      SpbLog.warn('立即发送抛非 SpbError 异常', {'error': '$e', 'stack': '$st'});
      _showMessage('立即发送失败');
    } finally {
      if (mounted) setState(() => _flushing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 加载失败且没有任何可展示内容：给一条可重试的窄条。
    // 不能静默吞掉——用户会以为「没有待处理消息」，而实际是请求失败了。
    if (_error != null && _messages.isEmpty) {
      return _Bar(
        color: scheme.errorContainer,
        child: Row(
          children: [
            Icon(Icons.error_outline, size: SpbSpacing.md, color: scheme.error),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                '待处理消息加载失败：${_error!.message}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: const ValueKey('pending-retry'),
              onPressed: _loading ? null : _reload,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 空列表是常态（dispatcher 通常很快消费完）：不占空间。
    // 加载中也返回空——首帧就撑出一块空白再收起会造成布局跳动。
    if (_messages.isEmpty) return const SizedBox.shrink();

    return _Bar(
      color: scheme.secondaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.hourglass_top_outlined,
                size: SpbSpacing.md,
                color: scheme.onSecondaryContainer,
              ),
              const SizedBox(width: SpbSpacing.sm),
              Text(
                '${widget.title}（${_messages.length}）',
                key: const ValueKey('pending-messages-title'),
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
              const Spacer(),
              // 「立即发送」：把本栏这几条 pending 立即提交。
              //
              // ## 为什么放在本栏而不是只靠输入框的闪电按钮
              //
              // 本栏展示的正是「将要被提交的那几条」，在这里点发送的意图最
              // 明确；而且多条 pending 时本栏是用户唯一能看见「要合并什么」的
              // 地方——策略选择（合并全部 / 在新会话中发送）需要这个上下文。
              if (widget.flush != null) ...[
                if (_flushing)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
                    child: SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  TextButton(
                    key: const ValueKey('pending-flush'),
                    onPressed: _flush,
                    child: const Text('立即发送'),
                  ),
              ],
              // 刷新入口：dispatcher 消费后本栏不会自动感知，给用户一个手动的。
              IconButton(
                key: const ValueKey('pending-refresh'),
                iconSize: SpbSpacing.lg,
                visualDensity: VisualDensity.compact,
                tooltip: '刷新',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _reload,
              ),
            ],
          ),
          for (final message in _messages)
            _PendingRow(
              key: ValueKey('pending-message-${message.id}'),
              message: message,
              busy: _undoing.contains(message.id),
              onUndo: () => _undo(message),
            ),
        ],
      ),
    );
  }
}

/// 一条待处理消息。
class _PendingRow extends StatelessWidget {
  const _PendingRow({
    super.key,
    required this.message,
    required this.busy,
    required this.onUndo,
  });

  final ChatInboxMessage message;
  final bool busy;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(top: SpbSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.input,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall,
                ),
                if (message.agentType.isNotEmpty)
                  Text(
                    message.agentType,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: SpbSpacing.sm),
          if (busy)
            const SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              key: ValueKey('pending-undo-${message.id}'),
              onPressed: onUndo,
              child: const Text('撤销'),
            ),
        ],
      ),
    );
  }
}

/// 栏容器（统一内边距与背景）。
class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('pending-messages-bar'),
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: child,
      ),
    );
  }
}
