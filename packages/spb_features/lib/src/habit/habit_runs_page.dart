import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 拉取**单条规则**的执行记录（`GET /api/habits/:pattern_id/runs`）。
///
/// 装配层实现即 `HabitApi.listHabitRuns`（与全局历史的 `listAllRuns` 不同端点）。
typedef LoadHabitRuns = Future<List<HabitRun>> Function(String patternId);

/// 按规则查看执行记录。
///
/// ## 为什么需要它（「执行记录」Tab 不够）
///
/// `HabitsPage` 的「执行记录」Tab 走 `GET /api/habits/runs`——**跨规则**的近 N 天
/// 全量历史（服务端 `days` 默认 7、上限 90），且包含没有 pattern 的候选建议记录。
/// 想回答「这条规则到底跑过几次、都做了什么」时：
/// - 列表里混着别的规则与候选记录，要自己按 `topic_key` 过滤；
/// - 只有近 7 天，更早的记录直接看不到。
///
/// 本页走 `GET /api/habits/:pattern_id/runs`（服务端按 `habit_pattern_id` 过滤、
/// 无时间窗、上限 200），是「看某一条规则的完整历史」的正确端点。
///
/// ## 为什么标题用规则自身的 topic_key 而不是对话标题
///
/// 全局历史页需要 group 标题是因为记录横跨多个对话。本页只属于一条规则，
/// 它的 `origin_group_id` 是常量——每行重复同一个对话名是噪音，且需要额外预取
/// `GET /chat/groups/:id`（N+1 请求换一个恒定值）。故本页**不接收**
/// `groupTitleOf`，标题直接用规则自己的 `topic_key`。
class HabitRunsPage extends StatefulWidget {
  const HabitRunsPage({
    super.key,
    required this.habit,
    required this.loadRuns,
    this.onOpenTurn,
  });

  /// 要查看的规则（提供标题与 pattern id）。
  final UserHabit habit;

  /// 拉取该规则的执行记录。调用方已把 patternId 绑好（见 [LoadHabitRuns]）。
  final Future<List<HabitRun>> Function() loadRuns;

  /// 跳到某条执行记录产生的对话。
  final void Function(String groupId, String turnId)? onOpenTurn;

  @override
  State<HabitRunsPage> createState() => _HabitRunsPageState();
}

class _HabitRunsPageState extends State<HabitRunsPage> {
  List<HabitRun>? _runs;
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
      final runs = await widget.loadRuns();
      if (!mounted) return;
      setState(() {
        _runs = runs;
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
        // 规则自身的主题（不是对话标题）。
        title: Text(_topicLabel(widget.habit.topicKey)),
        actions: [
          IconButton(
            key: const ValueKey('habit-runs-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _runs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null && _runs == null) {
      return HabitErrorView(
        error: err,
        onRetry: _load,
        retryKey: const ValueKey('habit-runs-retry'),
      );
    }
    final runs = _runs ?? const <HabitRun>[];
    if (runs.isEmpty) {
      return const HabitEmptyView(
        icon: Icons.history,
        text: '这条规则还没有执行记录。\n可以回到列表点「立即执行」跑一次。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: SpbSpacing.pagePadding,
        itemCount: runs.length,
        separatorBuilder: (_, _) => const Divider(height: SpbSpacing.xl),
        itemBuilder: (context, i) => HabitRunTile(
          run: runs[i],
          // 页面标题已经是这条规则的 topic_key，每行再重复一次是噪音。
          showTopic: false,
          onOpenTurn: widget.onOpenTurn,
        ),
      ),
    );
  }

  /// 与规则列表同策略：topic_key 是机器键，换分隔符展示，不编造中文名。
  static String _topicLabel(String topicKey) {
    if (topicKey.isEmpty) return '未命名习惯';
    return topicKey.replaceAll(RegExp(r'[._-]+'), ' ');
  }
}

/// 一条执行记录。
///
/// 两个页面共用（全局历史 Tab 与单规则历史页）：渲染逻辑一旦分叉，两边对
/// 「投递对话优先于来源对话」「reply_text 只显示 4 行」这类细节就会各自漂移。
class HabitRunTile extends StatelessWidget {
  const HabitRunTile({
    super.key,
    required this.run,
    this.groupTitle = '',
    this.showTopic = true,
    this.onOpenTurn,
  });

  final HabitRun run;

  /// 对话标题（仅全局历史页有——它横跨多个对话，需要上下文）。
  final String groupTitle;

  /// 是否在行首显示主题。单规则页关掉（标题已在 AppBar）。
  final bool showTopic;

  final void Function(String groupId, String turnId)? onOpenTurn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (showTopic)
              Expanded(
                child: Text(
                  run.topicKey.isEmpty ? '未命名' : run.topicKey,
                  style: textTheme.titleSmall,
                ),
              )
            else
              const Spacer(),
            Text(
              _formatTime(run.createdAt),
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: SpbSpacing.xxs),
        Wrap(
          spacing: SpbSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              run.triggerReason.label,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            Text(
              run.outcome.label,
              style: textTheme.bodySmall?.copyWith(
                color: run.outcome == HabitRunOutcome.failed
                    ? scheme.error
                    : scheme.onSurfaceVariant,
              ),
            ),
            if (run.isManual)
              Text(
                '手动',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (run.userFeedback != null)
              Text(
                run.userFeedback!.label,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (groupTitle.isNotEmpty)
              Text(
                groupTitle,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        if (run.replyText.isNotEmpty) ...[
          const SizedBox(height: SpbSpacing.xs),
          Text(
            run.replyText,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodyMedium,
          ),
        ],
        if (onOpenTurn != null && run.hasTurn) ...[
          const SizedBox(height: SpbSpacing.xs),
          TextButton(
            key: ValueKey('habit-run-open-${run.id}'),
            onPressed: () {
              // 与列表展示同一优先级（投递对话 → 来源对话）：点「查看对话」
              // 应落到用户实际能看到那条回复的对话，而不是一个空的来源组。
              final gid = run.deliveryGroupId ?? run.originGroupId;
              if (gid.isEmpty) return;
              onOpenTurn!(gid, run.scheduledTurnId!);
            },
            child: const Text('查看对话'),
          ),
        ],
      ],
    );
  }

  static String _formatTime(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${p2(local.hour)}:${p2(local.minute)}';
  }
}

/// 空态（规则页与单规则历史页共用）。
class HabitEmptyView extends StatelessWidget {
  const HabitEmptyView({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: SpbSpacing.xxxl, color: scheme.onSurfaceVariant),
            const SizedBox(height: SpbSpacing.md),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 错误态（带重试）。
///
/// `retryKey` 由调用方传入：本仓库两份既有测试（规则页 `habits-retry` /
/// 单规则历史页 `habit-runs-retry`）依赖各自的 key 定位按钮。
class HabitErrorView extends StatelessWidget {
  const HabitErrorView({
    super.key,
    required this.error,
    required this.onRetry,
    required this.retryKey,
  });

  final Object error;
  final VoidCallback onRetry;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final msg = error is SpbError ? (error as SpbError).message : '$error';
    final display = msg.isEmpty ? '加载失败' : msg;
    return Center(
      child: Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: SpbSpacing.xxxl,
              color: scheme.error,
            ),
            const SizedBox(height: SpbSpacing.md),
            Text(
              display,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: SpbSpacing.md),
            FilledButton(
              key: retryKey,
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
