import 'package:flutter/material.dart';
import 'package:spb_core/spb_core.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 跨 group 的待确认收件箱（对齐 webapp `dashboard/pending-confirmations`）。
///
/// ## 解决了什么
///
/// `confirmation_required` 事件只会在**已打开的对话**里显示。若某轮需要确认
/// 而用户没打开那个对话，确认会一直 pending（甚至过期）——agent 被卡死。
/// 本页汇总当前用户所有未过期的待确认项，用户点击即跳回该对话处理。
///
/// ## 数据来源
///
/// `GET /chat/confirmations?status=pending`（服务端默认排除已过期）。
/// 由调用方注入 [fetch]（便于无头单测与 app 层选 provider）。
///
/// ## 过期时间的展示
///
/// 服务端 `status=pending` 已排除 `expires_at <= now`，但**接近过期**的项仍会
/// 出现。剩余时间短的用警告色提示（≤10 分钟）。`expires_at` 为 null 表示不限时。
class PendingConfirmationsPage extends StatefulWidget {
  const PendingConfirmationsPage({
    super.key,
    required this.fetch,
    required this.groupTitleOf,
    this.onOpenGroup,
    this.onResolve,
  });

  /// 拉取待确认列表。返回的是 pending 项（服务端已排除已过期）。
  final Future<List<ChatConfirmation>> Function() fetch;

  /// 给定 groupId 返回对话标题（用于在卡片上展示上下文）。
  /// 找不到时返回 null，卡片展示「未知对话」。
  final String? Function(String groupId) groupTitleOf;

  /// 点击某条确认时跳转到对应对话（groupId, turnId）。
  final void Function(String groupId, String turnId)? onOpenGroup;

  /// 解决确认（复用既有 `resolveConfirmation`）。参数（confirmation, action）。
  /// 为 null 时不展示解决按钮（只读/导航用途）。
  final Future<void> Function(ChatConfirmation confirmation, String action)?
  onResolve;

  @override
  State<PendingConfirmationsPage> createState() =>
      _PendingConfirmationsPageState();
}

class _PendingConfirmationsPageState extends State<PendingConfirmationsPage> {
  List<ChatConfirmation>? _items;
  Object? _error;
  bool _loading = true;
  // 正在解决的 confirmation id → 防重复点击。
  final _resolving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.fetch();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _handleResolve(ChatConfirmation c, String action) async {
    if (_resolving.contains(c.id)) return;
    final cb = widget.onResolve;
    if (cb == null) return;
    setState(() => _resolving.add(c.id));
    try {
      await cb(c, action);
      if (!mounted) return;
      // 解决成功：从列表移除（不再 pending）。
      setState(() {
        _items?.removeWhere((e) => e.id == c.id);
        _resolving.remove(c.id);
      });
    } on Object catch (e, st) {
      // 非 SpbError（契约外的意外）。SnackBar 只说「操作失败，请重试」——
      // 底层原因完全不可见，故必须留痕（issue #45）。
      SpbLog.error(
        '解决确认请求失败',
        error: e,
        stackTrace: st,
        fields: {'confirmation_id': c.id, 'action': action},
      );
      if (!mounted) return;
      setState(() => _resolving.remove(c.id));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const title = Text('待确认');
    final refreshBtn = IconButton(
      key: const ValueKey('pending-confirmations-refresh'),
      icon: const Icon(Icons.refresh),
      tooltip: '刷新',
      onPressed: _loading ? null : _load,
    );

    return Scaffold(
      appBar: AppBar(title: title, actions: [refreshBtn]),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        key: const ValueKey('pending-confirmations-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: SpbSpacing.xxl),
            const SizedBox(height: SpbSpacing.sm),
            Padding(
              padding: SpbSpacing.pagePadding,
              child: Text(
                '$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final items = _items ?? const <ChatConfirmation>[];
    if (items.isEmpty) {
      return Center(
        key: const ValueKey('pending-confirmations-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: SpbSpacing.xxxl,
              color: Theme.of(context).colorScheme.tertiary,
            ),
            const SizedBox(height: SpbSpacing.sm),
            const Text('没有待确认的事项'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        key: const ValueKey('pending-confirmations-list'),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _ConfirmationTile(
          key: ValueKey('pending-confirmation-${items[i].id}'),
          confirmation: items[i],
          groupTitle: widget.groupTitleOf(items[i].groupId),
          resolving: _resolving.contains(items[i].id),
          onOpenGroup: widget.onOpenGroup == null
              ? null
              : () => widget.onOpenGroup!(items[i].groupId, items[i].turnId),
          onResolve: widget.onResolve == null
              ? null
              : (action) => _handleResolve(items[i], action),
        ),
      ),
    );
  }
}

/// 单条待确认项。
class _ConfirmationTile extends StatelessWidget {
  const _ConfirmationTile({
    super.key,
    required this.confirmation,
    required this.groupTitle,
    required this.resolving,
    this.onOpenGroup,
    this.onResolve,
  });

  final ChatConfirmation confirmation;
  final String? groupTitle;
  final bool resolving;
  final VoidCallback? onOpenGroup;
  final void Function(String action)? onResolve;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = confirmation;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 对话标题（上下文）：点击跳回该对话。
            if (onOpenGroup != null)
              InkWell(
                onTap: onOpenGroup,
                child: Row(
                  children: [
                    Icon(
                      Icons.forum_outlined,
                      size: SpbSpacing.lg,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: SpbSpacing.xs),
                    Expanded(
                      child: Text(
                        groupTitle ?? '未知对话',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: SpbSpacing.lg),
                  ],
                ),
              )
            else
              Text(
                groupTitle ?? '未知对话',
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            const SizedBox(height: SpbSpacing.xs),
            // 问题正文。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.help_outline,
                  size: SpbSpacing.lg,
                  color: scheme.secondary,
                ),
                const SizedBox(width: SpbSpacing.xs),
                Expanded(
                  child: Text(
                    c.reason,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            // 过期时间提示（显著）。
            _expiryHint(context),
            const SizedBox(height: SpbSpacing.sm),
            // 解决按钮。
            if (onResolve != null)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonal(
                      key: const ValueKey('pending-confirmation-approve'),
                      onPressed: resolving ? null : () => onResolve!('approve'),
                      child: const Text('继续'),
                    ),
                  ),
                  const SizedBox(width: SpbSpacing.sm),
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('pending-confirmation-reject'),
                      onPressed: resolving ? null : () => onResolve!('reject'),
                      child: const Text('取消'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 过期时间提示。剩余时间短用警告色；无时限不显示。
  Widget _expiryHint(BuildContext context) {
    final exp = confirmation.expiresAt;
    if (exp == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final remaining = exp.difference(DateTime.now());
    final mins = remaining.inMinutes;
    String label;
    Color color;
    IconData icon;
    if (!remaining.isNegative && mins <= 10) {
      label = '即将过期（$mins分钟后）';
      color = scheme.error;
      icon = Icons.warning_amber_outlined;
    } else if (remaining.isNegative) {
      // 理论上不会出现（服务端排除过期项），但防御性展示。
      label = '已过期';
      color = scheme.outline;
      icon = Icons.schedule_outlined;
    } else if (mins <= 60) {
      label = '$mins分钟后过期';
      color = scheme.tertiary;
      icon = Icons.schedule_outlined;
    } else {
      final hours = (mins / 60).floor();
      label = '$hours小时后过期';
      color = scheme.onSurfaceVariant;
      icon = Icons.schedule_outlined;
    }
    return Row(
      children: [
        Icon(icon, size: SpbSpacing.lg, color: color),
        const SizedBox(width: SpbSpacing.xxs),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}
