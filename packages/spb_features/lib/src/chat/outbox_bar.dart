import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 离线写队列的「待发送」条（issue #26 切片 C / issue #30）。
///
/// ## 它展示的是什么
///
/// **客户端自己**排队的消息（`OutboxQueue`），即「断网时用户发了、还没送出去」
/// 的那些。与 `PendingMessagesBar` **不是**同一件事：
///
/// | | `PendingMessagesBar` | `OutboxBar`（本组件） |
/// |---|---|---|
/// | 队列在哪 | **服务端**（`chat_inbox_messages`） | **客户端**（`outbox_entries`） |
/// | 出现在何时 | 消息已到服务端、等 dispatcher 合并 | 消息**还没到**服务端 |
/// | 用户能做什么 | 撤销 / 立即发送（合并成 turn） | 取消 / 手动重试 / 丢弃 |
/// | 语义 | 「平台还在攒批」 | 「我这边没网，先攒着」 |
///
/// 两者可以**同时**出现（断网时先入客户端队列；联网后投递成功、服务端才开始
/// 攒批），故是两个独立的条，不合并。
///
/// ## 为什么离线消息进这里而不进时间线
///
/// 入队时还没有 `turnId`，而 `EventReducer` **按 turnId 去重**——无 turnId 的
/// 本地项在服务端 `user_message` 到达后会渲染成**两个气泡**。故离线消息进
/// 「待发送」条；投递成功后由控制器用**服务端返回的 turnId** 注入回显，那时
/// 才会进时间线（设计文档 §7bis.6）。
///
/// ## 为什么用内联条而不是 SnackBar
///
/// 与 `_OfflineTimelineNotice` / `_CacheNotice` 同一理由：`SnackBar` 会自动
/// 消失，而「这几条还没发出去」是一个**持续成立**的事实，不是一次性通知。
class OutboxBar extends StatelessWidget {
  const OutboxBar({
    super.key,
    required this.entries,
    this.onCancel,
    this.onRetry,
    this.onRemove,
    this.title = '待发送',
  });

  /// 当前队列快照（调用方订阅 `OutboxQueue.entries` 后传入）。
  final List<OutboxEntry> entries;

  /// 取消一条（撤回未投递的消息）。
  ///
  /// null = 不提供取消入口。返回值 false 表示拒绝（条目正在投递中，见
  /// `OutboxQueue.cancel`）——此时 UI 应保持该条目，不做任何乐观移除。
  final Future<bool> Function(String id)? onCancel;

  /// 手动重试一条（主要针对 [OutboxStatus.failed]）。
  final Future<bool> Function(String id)? onRetry;

  /// 丢弃一条（删除，不再投递）。
  final Future<void> Function(String id)? onRemove;

  final String title;

  @override
  Widget build(BuildContext context) {
    // 空队列不占空间（与 `PendingMessagesBar` 同取向：首帧撑出一块空白再
    // 收起会造成布局跳动）。
    if (entries.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 有条目彻底失败时整条换成警示色：用户必须知道「这几条不会自己发出去了」。
    final hasFailed = entries.any((e) => e.status == OutboxStatus.failed);

    return Material(
      key: const ValueKey('outbox-bar'),
      color: hasFailed ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  hasFailed
                      ? Icons.error_outline
                      : Icons.schedule_send_outlined,
                  size: SpbSpacing.md,
                  color: hasFailed
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Text(
                    _headerText(),
                    key: const ValueKey('outbox-title'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: hasFailed
                          ? scheme.onErrorContainer
                          : scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            // 最多展示 3 条：这是输入区上方的**窄条**，不是列表页。条目多时
            // 用「还有 N 条」收尾——把几十条都渲染出来会把输入框挤出屏幕。
            for (final e in entries.take(3))
              _OutboxRow(
                entry: e,
                onCancel: onCancel,
                onRetry: onRetry,
                onRemove: onRemove,
              ),
            if (entries.length > 3)
              Padding(
                padding: const EdgeInsets.only(top: SpbSpacing.xs),
                child: Text(
                  '还有 ${entries.length - 3} 条…',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 文案不编造时间（与 `_OfflineTimelineNotice` 同一原则）：
  ///
  /// - 不说「正在发送」——重试可能在退避等待中，并没在发；
  /// - 不说「已失败」除非真有 `failed`（那才是有证据的）；
  /// - 不承诺具体时刻——退避有 ±20% 抖动，说「30 秒后重试」是不准确的。
  String _headerText() {
    final failed = entries.where((e) => e.status == OutboxStatus.failed).length;
    final base = '$title（${entries.length}）';
    if (failed > 0) return '$base · $failed 条需手动重试';
    return '$base · 联网后自动发送';
  }
}

class _OutboxRow extends StatelessWidget {
  const _OutboxRow({
    required this.entry,
    this.onCancel,
    this.onRetry,
    this.onRemove,
  });

  final OutboxEntry entry;
  final Future<bool> Function(String id)? onCancel;
  final Future<bool> Function(String id)? onRetry;
  final Future<void> Function(String id)? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = entry.status == OutboxStatus.failed;

    return Padding(
      padding: const EdgeInsets.only(top: SpbSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  entry.input,
                  key: ValueKey('outbox-input-${entry.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                if (failed && entry.lastError != null)
                  Text(
                    // 失败原因直接展示：用户需要知道是「网络」还是「请求本身
                    // 有问题」，后者重试多少次都没用。
                    entry.lastError!,
                    key: ValueKey('outbox-error-${entry.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
              ],
            ),
          ),
          // 失败时优先给「重试」（那是用户最想做的），否则给「取消」。
          //
          // ## 为什么不是两个都显示
          //
          // 这是窄条，一行里塞两个文字按钮会把输入文本挤成几个字。失败态的
          // 主操作是重试；非失败态（会自动重试）的主操作是取消。
          if (failed && onRetry != null)
            TextButton(
              key: ValueKey('outbox-retry-${entry.id}'),
              onPressed: () => onRetry!(entry.id),
              child: const Text('重试'),
            )
          else if (!failed && onCancel != null)
            TextButton(
              key: ValueKey('outbox-cancel-${entry.id}'),
              onPressed: () => onCancel!(entry.id),
              child: const Text('取消'),
            ),
          // 丢弃入口始终可用：用户可能既不想重试也不想留着了。
          if (onRemove != null)
            IconButton(
              key: ValueKey('outbox-remove-${entry.id}'),
              icon: const Icon(Icons.close, size: SpbSpacing.md),
              tooltip: '丢弃',
              visualDensity: VisualDensity.compact,
              onPressed: () => onRemove!(entry.id),
            ),
        ],
      ),
    );
  }
}
