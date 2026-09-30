import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 「我的最近轮次」列表（对齐 webapp `dashboard/turns`）。
///
/// ## 解决了什么
///
/// 对话列表只按 group 组织，用户看不到「我最近都让 agent 干了什么」。
/// 本页按时间倒序列出跨 group 的最近轮次，点击跳回对应对话。
///
/// ## 为什么不做语义搜索
///
/// 服务端 `/me/turns/semantic-search` **存在但已降级为关键字搜索**
/// （`user_turns.go:217`：embedding 服务未接入 Go API，回退到关键字搜索
/// 并带 `similarity=0` 标记）。做语义搜索 UI 只会给用户「看起来能语义搜、
/// 实际是关键字」的假象，故不做。
///
/// ## 数据来源
///
/// `GET /me/turns`（`user_turns.go` 的 `turnToListItem` 投影）。由调用方注入
/// [fetch]（便于无头单测与 app 层选 provider）。
class MyTurnsPage extends StatefulWidget {
  const MyTurnsPage({
    super.key,
    required this.fetch,
    this.onOpenTurn,
    this.title = '我的最近轮次',
  });

  /// 拉取最近轮次。默认由 app 层注入 `ChatApi.listMyTurns`。
  final Future<List<ChatTurnSummary>> Function() fetch;

  /// 点击某轮次时跳转到对应对话。
  final void Function(String groupId)? onOpenTurn;

  final String title;

  @override
  State<MyTurnsPage> createState() => _MyTurnsPageState();
}

class _MyTurnsPageState extends State<MyTurnsPage> {
  List<ChatTurnSummary>? _items;
  Object? _error;
  bool _loading = true;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            key: const ValueKey('my-turns-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        key: const ValueKey('my-turns-error'),
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
    final items = _items ?? const <ChatTurnSummary>[];
    if (items.isEmpty) {
      return Center(
        key: const ValueKey('my-turns-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_toggle_off,
              size: SpbSpacing.xxxl,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: SpbSpacing.sm),
            const Text('最近没有轮次记录'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        key: const ValueKey('my-turns-list'),
        // 内容不足一屏时也能下拉刷新（对齐 GroupListPage 的先例）。
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => _TurnTile(
          key: ValueKey('my-turn-${items[i].turnId}'),
          turn: items[i],
          onTap: widget.onOpenTurn == null
              ? null
              : () => widget.onOpenTurn!(items[i].groupId),
        ),
      ),
    );
  }
}

/// 单条轮次。
class _TurnTile extends StatelessWidget {
  const _TurnTile({super.key, required this.turn, this.onTap});

  final ChatTurnSummary turn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = turn;

    return ListTile(
      onTap: onTap,
      title: Text(
        // 输入摘要为空（异常载荷）时给出占位，避免空白行。
        t.inputPreview.isEmpty ? '（无输入）' : t.inputPreview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.xxs),
        child: Wrap(
          spacing: SpbSpacing.sm,
          runSpacing: SpbSpacing.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _sourceBadge(scheme, theme.textTheme),
            _statusBadge(scheme, theme.textTheme),
            if (t.groupTitle != null && t.groupTitle!.isNotEmpty)
              Text(
                t.groupTitle!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              _formatTime(t.createdAt),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, size: SpbSpacing.lg),
    );
  }

  Widget _sourceBadge(ColorScheme scheme, TextTheme textTheme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Text(turn.source.label, style: textTheme.labelSmall),
    );
  }

  Widget _statusBadge(ColorScheme scheme, TextTheme textTheme) {
    final (Color bg, String label) = switch (turn.status) {
      'failed' => (scheme.errorContainer, '失败'),
      'canceled' => (scheme.surfaceContainerHighest, '已取消'),
      'running' || 'queued' => (scheme.tertiaryContainer, '进行中'),
      'pending' => (scheme.secondaryContainer, '待确认'),
      _ => (scheme.secondaryContainer, '已完成'),
    };
    // has_error 但 status 未标 failed：仍以失败色提示（服务端 error_count>0）。
    final effectiveBg = turn.hasError && turn.status != 'failed'
        ? scheme.errorContainer
        : bg;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Text(label, style: textTheme.labelSmall),
    );
  }

  /// 相对时间（近 24h 显示小时/分钟，否则显示日期）。
  static String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }
}
