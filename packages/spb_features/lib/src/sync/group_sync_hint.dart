import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 「本对话有交付物未同步到本地」提示条。
///
/// ## 为什么是提示条而不是静默自动同步
///
/// 即使只同步**这个对话**（`SyncSingleGroupScope`），一个活跃对话的产出仍可能
/// 有几百 MB（首次全范围全量生产实测 **5666 条 / 4.7 GB**）。在用户只是「点开
/// 一个对话看看」时静默启动下载，是把一次误判变成一次等待。
///
/// 提示条把决定权交回用户：看得见「有 12 个交付物未同步」，点一下才开始。
///
/// ⚠️ 本组件**不负责**决定同步范围——那是装配层的事（桌面端走
/// `runGroupSyncActionProvider` 的定向同步）。范围与是否静默都不影响提示条
/// 本身的行为。
///
/// ## 与 [GroupSyncNeed] 的分工
///
/// 本组件只负责**展示与上抛意图**，不含任何判定逻辑——判定在 `spb_domain`
/// （纯 Dart，可无头测），触发在装配层。页面不掌握「游标/updated_at」这些
/// 概念，与 `ConversationPage` 不掌握归约逻辑同一取向。
///
/// ## 文案边界（不编造）
///
/// [pendingCount] 为 0（未统计 / 统计被跳过）时只说「有交付物未同步到本地」，
/// **不写「0 个」**——那是把「不知道」说成一个具体数字。
class GroupSyncHint extends StatelessWidget {
  const GroupSyncHint({
    super.key,
    required this.pendingCount,
    this.onSync,
    this.onDismiss,
    this.syncing = false,
  });

  /// 未同步的文件数；0 表示「数量未知」（见类文档的文案边界）。
  final int pendingCount;

  /// 「立即同步」；为 null 时按钮不渲染（不展示点了没反应的入口）。
  final VoidCallback? onSync;

  /// 「忽略」；为 null 时不渲染关闭按钮。
  final VoidCallback? onDismiss;

  /// 同步进行中（按钮换成转圈 + 禁用，防重复点击）。
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      key: const ValueKey('group-sync-hint'),
      // 与对话页其它「临时状态条」（长时间无进展 / 活动指示 / 等待提示）
      // 同用 secondaryContainer：它们是一族，不该各造一套配色。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SpbSpacing.md,
          SpbSpacing.sm,
          SpbSpacing.sm,
          SpbSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_download_outlined,
              size: SpbSpacing.lg,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                _message,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            if (onSync != null) ...[
              const SizedBox(width: SpbSpacing.sm),
              TextButton(
                key: const ValueKey('group-sync-hint-sync'),
                onPressed: syncing ? null : onSync,
                child: syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('立即同步'),
              ),
            ],
            if (onDismiss != null)
              IconButton(
                key: const ValueKey('group-sync-hint-dismiss'),
                onPressed: syncing ? null : onDismiss,
                icon: const Icon(Icons.close, size: SpbSpacing.lg),
                tooltip: '本次忽略',
                color: scheme.onSecondaryContainer,
              ),
          ],
        ),
      ),
    );
  }

  String get _message {
    if (pendingCount <= 0) return '本对话有交付物未同步到本地';
    // 「500+」不写具体值：计数有上限（见 `GroupSyncCheckResult.countCap`），
    // 报一个精确的 500 会让人以为正好 500 个。
    final suffix = pendingCount >= 500 ? '500+' : '$pendingCount';
    return '本对话有 $suffix 个交付物未同步到本地';
  }
}
