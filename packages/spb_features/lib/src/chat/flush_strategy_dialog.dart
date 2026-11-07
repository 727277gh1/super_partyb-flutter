import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 按服务端默认策略提交 pending 消息。
///
/// ## 为什么无参数
///
/// 「提交哪个 group 的 pending」由装配层在闭包里绑定（app 层才知道 groupId，
/// 页面刻意不知道）。与 `ConversationPage.onSend` 同一约定。
///
/// 可能返回「需要选冲突策略」（[FlushResult.needsConfirmation]）——**那不是
/// 错误**，是服务端要求调用方在「多条 pending」时明确选一个合并方式。
typedef FlushPending = Future<FlushResult> Function();

/// 按用户选定的冲突策略重新提交。
///
/// 参数是**策略**（`latest_only` / `merge_all` / `new_group`），取值来自
/// [FlushResult.options]——**不得**在 UI 里硬编码三项（服务端的 `new_group`
/// 仅在最新一条已归属 group 时才出现）。
typedef FlushWithStrategy = Future<FlushResult> Function(String strategy);

/// 冲突策略的中文文案。
///
/// ## 为什么照抄 webapp 而不是自己措辞
///
/// 同一个策略在 web / 桌面 / 移动端必须显示**同一句话**：用户在三端之间切换时
/// 看到的选项若措辞不同，会怀疑是不是两套不同的功能。故逐条对齐
/// `apps/webapp/messages/zh.json` 的 `outboxStrategy*`。
///
/// ## 为什么 [latest_only] 在 webapp 里没有对应键
///
/// webapp 的「发送」按钮本身就是 `latest_only`（不传策略时服务端默认取它），
/// 所以它没有独立的菜单项文案。本端仍把它显式列出：服务端的 `options` 里确实
/// 有它，用户需要看到「只发最新一条」这个选项——否则 `options` 有一项无法渲染。
String flushStrategyLabel(String strategy) => switch (strategy) {
  'merge_all' => '合并全部为一条',
  'new_group' => '在新会话中发送',
  'latest_only' => '只发最新一条',
  // 服务端新增策略时不隐藏选项：原样显示原文，用户至少能选。
  _ => strategy,
};

/// 冲突策略的后果说明（帮助用户判断，而不是只看名字猜）。
String flushStrategyHint(String strategy) => switch (strategy) {
  'merge_all' => '按时间顺序合并成一条消息',
  'new_group' => '只发最新一条，并新建一个对话',
  'latest_only' => '只发最新一条，其余几条作废',
  _ => '',
};

/// 让用户从服务端返回的 [FlushResult.options] 里选一个冲突策略。
///
/// ## 为什么选项来自返回值而不是硬编码三项
///
/// 服务端的 `options` 是**动态**的（见 `apps/go-api/internal/server/chat_inbox.go`
/// 的 `flush`）：`new_group` **仅当**最新一条 pending 已归属某个 group 时才追加，
/// 因为「在新会话中发送」对没有 group 的消息没有意义。硬编码三项会让用户看到
/// 一个必然失败（400）的选项。
///
/// 返回值：用户所选策略；取消（点遮罩 / 返回键）时返回 `null`。
Future<String?> showFlushStrategyDialog(
  BuildContext context,
  FlushResult result,
) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('有多条待处理消息'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            '请选择发送方式：',
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
        ),
        for (final strategy in result.options)
          SimpleDialogOption(
            key: ValueKey('flush-strategy-$strategy'),
            onPressed: () => Navigator.of(dialogContext).pop(strategy),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(flushStrategyLabel(strategy)),
                if (flushStrategyHint(strategy).isNotEmpty)
                  Text(
                    flushStrategyHint(strategy),
                    style: Theme.of(dialogContext).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 「立即发送」的完整流程：先按默认策略提交，若服务端要求确认则弹策略选择
/// 并用所选策略重试。
///
/// ## 为什么必须是一个共享函数（而不是各组件各写一遍）
///
/// 这条流程有两个入口（[MessageComposer] 的闪电按钮、[PendingMessagesBar] 的
/// 发送方式入口），且**必须行为一致**：漏掉「选完策略再提交」这一步，就会退回
/// 到修复前的功能性死锁——用户永远走不到提交成功那条路。
///
/// ## 返回 `null` 的语义
///
/// 用户主动取消了策略选择（不是失败）。调用方应静默返回，不提示错误。
///
/// ## 为什么需要确认却没有策略回调时抛 [ValidationError]
///
/// 那不是「什么都没发生」：服务端**一条都没提交**。此时必须让用户知道原因
/// （而不是假装成功）。抛 [SpbError] 让调用方走既有的错误提示路径。
Future<FlushResult?> runFlushFlow(
  BuildContext context, {
  required FlushPending flush,
  FlushWithStrategy? flushWithStrategy,
}) async {
  final first = await flush();
  if (!first.needsConfirmation) return first;

  final withStrategy = flushWithStrategy;
  if (withStrategy == null) {
    throw ValidationError('有多条待处理消息，需要先选择合并方式（${first.options.join(' / ')}）');
  }

  // 弹窗需要一个仍挂载的 context（前面的网络往返可能已经把页面销毁）。
  if (!context.mounted) return null;
  final chosen = await showFlushStrategyDialog(context, first);
  if (chosen == null) return null;

  return withStrategy(chosen);
}
