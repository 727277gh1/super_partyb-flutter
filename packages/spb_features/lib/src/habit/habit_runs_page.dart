import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 拉取**单条规则**的执行记录（`GET /api/habits/:pattern_id/runs`）。
///
/// 装配层实现即 `HabitApi.listHabitRuns`（与全局历史的 `listAllRuns` 不同端点）。
typedef LoadHabitRuns = Future<List<HabitRun>> Function(String patternId);

/// 拉取**跨规则**的执行历史（`GET /api/habits/runs`），含今日预算。
///
/// 返回 [HabitRunsResult]（而非裸列表）是因为该响应带 `daily_budget`——
/// 用 `unwrapItems` 会把预算**静默丢掉**（见 [HabitDailyBudget]）。
typedef LoadHabitRunsHistory = Future<HabitRunsResult> Function(
  HabitRunsFilter filter,
);

/// 执行记录默认时间窗（天）。
///
/// 30 而非服务端默认的 7：全局端点服务端 `days` 默认 7、上限 90。默认 7 天
/// 会让「上周跑的那次」直接消失，用户以为记录丢了。
const int kHabitRunsDefaultDays = 30;

/// 时间窗可选项。
///
/// 上限 90 是服务端硬限制（`allRuns` 里 `if days > 90 { days = 90 }`）：
/// 客户端给出 >90 的选项只会得到被静默截断的结果，展示值与真实窗口不符。
const List<int> kHabitRunsDayOptions = [7, 30, 90];

/// 「不限时间窗」（仅本地筛选可用）。
///
/// 全局端点**不能**用 0：服务端 `if days < 1 { days = 1 }`，传 0 会变成 1 天
/// （得到最窄的结果），与「不限」语义相反。
const int kHabitRunsAllDays = 0;

/// 执行记录的筛选条件。
///
/// ## 两个页面的语义不同（这是刻意的）
///
/// | 页面 | 端点 | 筛选在哪 | 时间窗选项 |
/// |---|---|---|---|
/// | 全局历史 Tab | `GET /api/habits/runs` | **服务端**（`days=` / `trigger_reason=`）| 7 / 30 / 90 |
/// | 单规则历史页 | `GET /api/habits/:id/runs` | **客户端** | 7 / 30 / 90 / 不限 |
///
/// 服务端单规则端点只接受 `limit` / `offset`（SQL `ListHabitRuns` 按
/// `habit_pattern_id` 过滤，无 `created_at` 条件）。故 [HabitRunsPage] 是**本地**
/// 过滤已拉取的记录，而不是重发请求——把它当成服务端筛选会让用户以为
/// 「7 天前真的没跑过」，而真相是「拉回来了但被本地滤掉了」。
///
/// 单规则页多一个「不限」（[kHabitRunsAllDays]）：该页存在的理由就是
/// 「看某一条规则的**完整**历史」（服务端返回上限 200、无时间窗），若只给
/// 7/30/90，更早的记录就永远看不到了。
class HabitRunsFilter {
  const HabitRunsFilter({this.days = kHabitRunsDefaultDays, this.reason});

  /// 时间窗（天）。
  final int days;

  /// 触发原因；null = 不筛。
  final HabitTriggerReason? reason;

  bool get isDefault => days == kHabitRunsDefaultDays && reason == null;

  HabitRunsFilter withDays(int v) => HabitRunsFilter(days: v, reason: reason);

  HabitRunsFilter withReason(HabitTriggerReason? v) =>
      HabitRunsFilter(days: days, reason: v);

  @override
  bool operator ==(Object other) =>
      other is HabitRunsFilter && other.days == days && other.reason == reason;

  @override
  int get hashCode => Object.hash(days, reason);

  @override
  String toString() => 'HabitRunsFilter(days: $days, reason: ${reason?.wire})';
}

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

  /// 本地筛选条件（见 [HabitRunsFilter] 的「两个页面语义不同」）。
  HabitRunsFilter _filter = const HabitRunsFilter();

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
    final all = _runs ?? const <HabitRun>[];
    if (all.isEmpty) {
      return const HabitEmptyView(
        icon: Icons.history,
        text: '这条规则还没有执行记录。\n可以回到列表点「立即执行」跑一次。',
      );
    }
    final visible = applyHabitRunsFilter(all, _filter);
    return Column(
      children: [
        HabitRunsFilterBar(
          filter: _filter,
          onChanged: (f) => setState(() => _filter = f),
          // 本页是本地筛选，可提供「不限」（完整历史）。
          allowUnlimited: true,
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? const HabitEmptyView(
                  icon: Icons.filter_alt_off,
                  text: '当前筛选条件下没有记录。\n可以放宽时间窗或选择「全部原因」。',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: SpbSpacing.pagePadding,
                    itemCount: visible.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: SpbSpacing.xl),
                    itemBuilder: (context, i) => HabitRunTile(
                      run: visible[i],
                      // 页面标题已经是这条规则的 topic_key，每行再重复一次是噪音。
                      showTopic: false,
                      onOpenTurn: widget.onOpenTurn,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 与规则列表同策略：topic_key 是机器键，换分隔符展示，不编造中文名。
  static String _topicLabel(String topicKey) {
    if (topicKey.isEmpty) return '未命名习惯';
    return topicKey.replaceAll(RegExp(r'[._-]+'), ' ');
  }
}

/// 按筛选条件过滤记录（**本地**）。
///
/// 单规则端点无时间窗/原因参数，故过滤在客户端做。时间窗按 `createdAt`
/// （服务端返回的创建时刻）而非 `executedAt`：`executedAt` 可为空（待处理/已
/// 取消），拿它算会让这些记录无理由地消失。
///
/// `days == 0`（[kHabitRunsAllDays]）表示不限时间窗。
///
/// `createdAt` 为 null 的记录**保留**（不因缺字段而丢掉）——服务端理论上都会
/// 给，真缺了也应该显示出来让用户看到异常，而不是静默隐掉。
List<HabitRun> applyHabitRunsFilter(
  List<HabitRun> runs,
  HabitRunsFilter filter,
) {
  final reason = filter.reason;
  final cutoff = filter.days <= 0
      ? null
      : DateTime.now().toUtc().subtract(Duration(days: filter.days));
  return runs.where((r) {
    if (reason != null && r.triggerReason != reason) return false;
    if (cutoff == null) return true;
    final t = r.createdAt;
    if (t == null) return true;
    return !t.toUtc().isBefore(cutoff);
  }).toList();
}

/// 执行记录筛选条（时间窗 + 触发原因）。
///
/// 全局历史 Tab（服务端筛选）与单规则历史页（本地筛选）共用同一套控件，
/// 避免两处的选项集/文案各自漂移。
class HabitRunsFilterBar extends StatelessWidget {
  const HabitRunsFilterBar({
    super.key,
    required this.filter,
    required this.onChanged,
    this.allowUnlimited = false,
  });

  final HabitRunsFilter filter;
  final ValueChanged<HabitRunsFilter> onChanged;

  /// 是否提供「不限」选项。
  ///
  /// 只有**本地**筛选的页面（[HabitRunsPage]）能开：全局端点的 `days=0`
  /// 会被服务端归一成 1 天（`if days < 1 { days = 1 }`），语义完全相反。
  final bool allowUnlimited;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.sm,
        SpbSpacing.lg,
        SpbSpacing.sm,
      ),
      child: Row(
        children: [
          Text('时间窗', style: textTheme.labelMedium),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Wrap(
              spacing: SpbSpacing.xs,
              children: [
                for (final d in kHabitRunsDayOptions)
                  ChoiceChip(
                    key: ValueKey('habit-runs-days-$d'),
                    label: Text('$d 天'),
                    selected: filter.days == d,
                    onSelected: (_) => onChanged(filter.withDays(d)),
                  ),
                if (allowUnlimited)
                  ChoiceChip(
                    key: const ValueKey('habit-runs-days-all'),
                    label: const Text('不限'),
                    selected: filter.days == kHabitRunsAllDays,
                    onSelected: (_) =>
                        onChanged(filter.withDays(kHabitRunsAllDays)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: SpbSpacing.sm),
          // 原因筛选用下拉而不是一排 Chip：选项是枚举（含「全部」共 5 项），
          // 窄屏上 Chip 会折成两行把列表挤下去。
          DropdownButton<HabitTriggerReason?>(
            key: const ValueKey('habit-runs-reason'),
            value: filter.reason,
            underline: const SizedBox.shrink(),
            hint: const Text('全部原因'),
            items: [
              const DropdownMenuItem<HabitTriggerReason?>(
                value: null,
                child: Text('全部原因'),
              ),
              for (final r in HabitTriggerReason.values)
                if (r != HabitTriggerReason.unknown)
                  DropdownMenuItem<HabitTriggerReason?>(
                    value: r,
                    child: Text(r.label),
                  ),
            ],
            onChanged: (v) => onChanged(filter.withReason(v)),
          ),
        ],
      ),
    );
  }
}

/// 今日 `due_rule` 触发预算条（`daily_budget`）。
///
/// ## 为什么必须显示「已用 / 上限」而不只是一个进度条
///
/// 用户真正要回答的问题是「今天还能不能手动跑」。进度条只能看比例，
/// 「已用 3 / 20」直接回答。额度耗尽时额外给出文案——服务端这时会回 409，
/// 不提前说明的话用户会以为是功能坏了。
class HabitDailyBudgetBar extends StatelessWidget {
  const HabitDailyBudgetBar({super.key, required this.budget});

  final HabitDailyBudget budget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // limit <= 0 = 服务端没给出可用上限：不画进度条（见 [HabitDailyBudget]）。
    if (!budget.hasLimit) return const SizedBox.shrink();

    final exhausted = budget.exhausted;
    final color = exhausted ? scheme.error : scheme.primary;
    return Padding(
      key: const ValueKey('habit-daily-budget'),
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.lg,
        SpbSpacing.sm,
        SpbSpacing.lg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, size: SpbSpacing.lg, color: color),
              const SizedBox(width: SpbSpacing.sm),
              Expanded(
                child: Text(
                  '今日自动触发已用 ${budget.usedToday} / ${budget.limit}',
                  style: textTheme.bodySmall,
                ),
              ),
              Text(
                exhausted ? '额度已用尽' : '剩余 ${budget.remaining} 次',
                style: textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: SpbSpacing.xs),
          ClipRRect(
            borderRadius: SpbRadius.inputAll,
            child: LinearProgressIndicator(
              value: (budget.usedToday / budget.limit).clamp(0.0, 1.0),
              minHeight: 4,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          if (exhausted) ...[
            const SizedBox(height: SpbSpacing.xxs),
            Text(
              '今天不会再自动触发；手动「立即执行」也会被服务端拒绝',
              key: const ValueKey('habit-daily-budget-exhausted'),
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
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
