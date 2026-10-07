import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 加载某个 group 的历史目标列表。
///
/// 装配层实现即 `GoalApi.listGoals(groupId)` 的薄包装。
typedef LoadGoalHistory = Future<List<Goal>> Function();

/// 切回某个历史目标（`PUT /chat/groups/:group_id/goals/current`）。
typedef SwitchGoal = Future<void> Function(String goalId);

/// 改目标状态（`PATCH /chat/goals/:goal_id`）。
///
/// 本面板只用 [GoalStatus.completed] 与 [GoalStatus.archived] 两个取值。
typedef SetGoalStatus = Future<void> Function(String goalId, GoalStatus status);

/// 目标版本历史面板：查看历史目标 / 切回 / 标记完成 / 归档。
///
/// ## 它解决什么（为什么必须有这个面板）
///
/// 服务端的设计是「goal 变更 = 新建而非覆盖」：每次改目标都建新行、把旧行
/// 归档，历史行及其任务**全部保留**。但 `listGoals` / `switchGoal` /
/// `updateGoalStatus` 三个端点在客户端**零调用方**——历史只写不读。于是那条
/// 「不擦除历史」的设计承诺在 UI 上完全不可见：用户看不到旧版本，也没法切回。
/// 本面板把这条链路补完。
///
/// ## 三个动作的语义（**不要混用「恢复」这个词**）
///
/// | 动作 | 端点 | 改什么 |
/// |---|---|---|
/// | 切回 | `switchGoal` | **只改指针** `chat_groups.current_goal_id`，不改任何 goal 内容 |
/// | 标记完成 | `updateGoalStatus(completed)` | 目标达成，影响 Goal Gate 的续跑判定 |
/// | 归档 | `updateGoalStatus(archived)` | 从当前指针上摘下来，同样不删内容 |
///
/// 「切回」是**指针切换**而非「恢复」：旧目标的内容从未被修改过，所以可以
/// 反复来回切。文案若写成「恢复」会暗示「内容被还原了」，那是错的。
///
/// ## 为什么不做删除（与 webapp 一致）
///
/// 删除会让「不擦除历史」的承诺失效，且任务行有外键依赖。归档已足以表达
/// 「不再使用」——这正是服务端把 `archived` 设计成软状态的原因。
///
/// ## 与 [GoalTasksPanel] 的分工
///
/// [GoalTasksPanel] 操作的是**当前**目标的**任务**（增删改查 + 重排）；
/// 本面板操作的是**目标本身**的版本与状态。两者是不同维度，故各自成 tab。
/// 本面板不渲染任务，也不提供「切回后自动跳转」——切换只改指针，任务列表
/// 会由 `goal_updated` SSE 事件驱动刷新（见 [GoalTasksPanel] 的类文档）。
///
/// ## 为什么数据靠注入、面板自己不碰 HTTP
///
/// 与 [GoalTasksPanel] / [GroupDeliverablesPanel] 同一约定：面板只渲染 + 收集
/// 意图，HTTP 由 app 装配层注入。故可在无头环境用内存桩完整验证。
///
/// ## 「未注入回调 = 只读」
///
/// [onSwitch] / [onSetStatus] 为 null 时**对应的操作入口整个不渲染**（不是
/// 禁用）：禁用按钮会让用户以为「本端支持但暂时不可用」，而真相是这一端没
/// 装配该能力。两者都为 null 时本面板退化为只读历史清单。
class GoalHistoryPanel extends StatefulWidget {
  const GoalHistoryPanel({
    super.key,
    required this.load,
    this.onSwitch,
    this.onSetStatus,
    this.currentGoalId,
    this.busy = false,
    this.showHeader = true,
    this.emptyHint = '还没有历史目标',
    this.reloadToken,
  });

  /// 加载历史目标列表。
  final LoadGoalHistory load;

  /// 切回某个历史目标。null 时不渲染「切回」入口。
  final SwitchGoal? onSwitch;

  /// 改目标状态。null 时不渲染「完成」/「归档」入口。
  final SetGoalStatus? onSetStatus;

  /// 当前目标的行 id，用于高亮与禁用「切回」。
  ///
  /// 为 null / 空串时（如权威快照尚未就绪）**没有任何条目被判为当前**：
  /// 宁可所有条目都可切，也不误标一个错的为当前——误标会让用户以为
  /// 「切回」是多余的，从而放弃切回真正想要的那个。
  final String? currentGoalId;

  /// 是否有写操作在途。为 true 时全部控件禁用（防并发提交互相覆盖）。
  ///
  /// 由父层持有（桌面端是 `_settingsBusy`、移动端同），因为写操作会回读
  /// group 快照，与设置面板共享同一 busy 位。
  final bool busy;

  /// 是否渲染自带标题行（tab 内容通常由 tab 标签承担标题）。
  final bool showHeader;

  /// 空列表时的提示。
  final String emptyHint;

  /// 切换对话时重新加载（Flutter 会复用本 State）。
  final Object? reloadToken;

  @override
  State<GoalHistoryPanel> createState() => _GoalHistoryPanelState();
}

class _GoalHistoryPanelState extends State<GoalHistoryPanel> {
  List<Goal> _goals = const [];
  bool _loading = false;
  String? _error;

  /// 正在提交的那条 goal id（展示 spinner；禁用由 [GoalHistoryPanel.busy]
  /// 统一负责，故这里只用于定位）。
  String? _actingId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(GoalHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      // 换对话：先清空，避免短暂显示上一个 group 的历史（那些 goal id 在
      // 新 group 里不存在，点「切回」会得到 400「goal 不属于该 group」）。
      setState(() {
        _goals = const [];
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
        _goals = items;
        _loading = false;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 执行一个写操作，成功后重新拉取历史。
  ///
  /// ## 为什么写完必须 `_reload()`
  ///
  /// 三个动作都会改变列表的呈现：`switchGoal` 换高亮项、`updateGoalStatus`
  /// 换状态徽标、归档会隐藏「归档」按钮。不回读就会留下一个与真相不符的
  /// 列表（最典型的是「切回后两个条目同时高亮」——旧高亮没有被清掉）。
  ///
  /// 父层的 write→re-read（`_runGoalWrite`）刷新的是 **group 快照**
  /// （`current_goal_id` / 任务 / 进度），本面板的历史列表是**另一个端点**，
  /// 必须各自回读。
  ///
  /// 失败由注入的回调自行上报（它们内部已有 `_describeGoalError` + SnackBar），
  /// 故这里只负责复位 `_actingId`。
  Future<void> _run(String goalId, Future<void> Function() action) async {
    if (widget.busy) return;
    setState(() => _actingId = goalId);
    try {
      await action();
      await _reload();
    } finally {
      if (mounted) setState(() => _actingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 加载失败：给一条可重试的窄条，不静默成「没有历史目标」。
    if (_error != null) {
      return Center(
        key: const ValueKey('goal-history-error'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: SpbSpacing.xxl,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                '历史目标加载失败：$_error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: SpbSpacing.sm),
              TextButton(
                key: const ValueKey('goal-history-retry'),
                onPressed: _loading ? null : _reload,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 首帧加载中：转圈而非空占位（空占位会被误读为「确实没有历史」）。
    if (_loading && _goals.isEmpty) {
      return Center(
        key: const ValueKey('goal-history-loading'),
        child: const Padding(
          padding: SpbSpacing.pagePadding,
          child: SizedBox(
            width: SpbSpacing.xl,
            height: SpbSpacing.xl,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_goals.isEmpty) {
      return Center(
        key: const ValueKey('goal-history-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history,
                size: SpbSpacing.xxl,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                widget.emptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      key: const ValueKey('goal-history-list'),
      padding: SpbSpacing.pagePadding,
      itemCount: _goals.length + (widget.showHeader ? 1 : 0),
      itemBuilder: (context, index) {
        if (widget.showHeader && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
            child: Text(
              '历史目标（${_goals.length}）',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final goal = _goals[widget.showHeader ? index - 1 : index];
        return _GoalHistoryRow(
          goal: goal,
          isCurrent: _isCurrent(goal),
          busy: widget.busy,
          acting: _actingId == goal.id,
          onSwitch: widget.onSwitch == null
              ? null
              : () => _run(goal.id, () => widget.onSwitch!(goal.id)),
          onSetStatus: widget.onSetStatus == null
              ? null
              : (status) =>
                    _run(goal.id, () => widget.onSetStatus!(goal.id, status)),
        );
      },
    );
  }

  /// 该条是否即当前目标。
  ///
  /// [GoalHistoryPanel.currentGoalId] 为空时**一律返回 false**（见其文档：
  /// 宁可全部可切，也不误标）。
  bool _isCurrent(Goal goal) {
    final current = widget.currentGoalId;
    if (current == null || current.isEmpty) return false;
    return goal.id == current;
  }
}

/// 一条历史目标。
class _GoalHistoryRow extends StatelessWidget {
  const _GoalHistoryRow({
    required this.goal,
    required this.isCurrent,
    required this.busy,
    required this.acting,
    required this.onSwitch,
    required this.onSetStatus,
  });

  final Goal goal;
  final bool isCurrent;
  final bool busy;
  final bool acting;
  final VoidCallback? onSwitch;
  final void Function(GoalStatus status)? onSetStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    // 任一写操作在途时全部禁用：并发提交会互相覆盖（且都会回读 group）。
    final disabled = busy || acting;

    return Card(
      key: ValueKey('goal-history-${goal.id}'),
      margin: const EdgeInsets.only(bottom: SpbSpacing.sm),
      // 当前项用主色描边高亮：用户在长列表里要能一眼找到「我现在在哪」。
      shape: RoundedRectangleBorder(
        borderRadius: SpbRadius.cardAll,
        side: BorderSide(
          color: isCurrent ? scheme.primary : scheme.outlineVariant,
          width: isCurrent ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(goal.goalText, style: textTheme.bodyMedium),
            const SizedBox(height: SpbSpacing.xs),
            Wrap(
              spacing: SpbSpacing.xs,
              runSpacing: SpbSpacing.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _Chip(
                  key: ValueKey('goal-status-${goal.id}'),
                  label: goal.status.label,
                  color: _statusColor(scheme, goal.status),
                ),
                if (isCurrent)
                  _Chip(
                    key: ValueKey('goal-current-${goal.id}'),
                    label: '当前',
                    color: scheme.primary,
                  ),
                // tasks_source 用 wire 值而非中文标签：它与 `reset-for-expand`
                // 的可覆盖判定直接对应，运维/排查时要能对上服务端的字面值。
                _Meta(text: goal.tasksSource.wire),
                _Meta(text: _formatTimestamp(goal.createdAt)),
                // git_commit 只显示前 8 位（完整 sha 会把这一行撑爆）。
                // 不足 8 位时原样显示（异常载荷不能把渲染搞崩）。
                if ((goal.gitCommit ?? '').isNotEmpty)
                  _Meta(text: _shortCommit(goal.gitCommit!)),
              ],
            ),
            const SizedBox(height: SpbSpacing.sm),
            Row(
              children: [
                // 「切回」：当前项不渲染（它已经是当前，点了是空操作）。
                if (!isCurrent && onSwitch != null)
                  TextButton(
                    key: ValueKey('goal-switch-${goal.id}'),
                    onPressed: disabled ? null : onSwitch,
                    child: acting
                        ? const SizedBox(
                            width: SpbSpacing.lg,
                            height: SpbSpacing.lg,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('切回'),
                  ),
                // 「标记完成」只对 active 显示：已完成/已归档的目标再标一次
                // 是空操作，显示出来只会让用户以为漏了什么。
                if (goal.status == GoalStatus.active && onSetStatus != null)
                  TextButton(
                    key: ValueKey('goal-complete-${goal.id}'),
                    onPressed: disabled
                        ? null
                        : () => onSetStatus!(GoalStatus.completed),
                    child: const Text('标记完成'),
                  ),
                // 「归档」对当前项不显示：先切走再归档才符合「指针仍在有效
                // 目标上」的直觉（否则当前指针会指向一个已归档目标）。
                if (goal.status != GoalStatus.archived &&
                    !isCurrent &&
                    onSetStatus != null)
                  TextButton(
                    key: ValueKey('goal-archive-${goal.id}'),
                    onPressed: disabled
                        ? null
                        : () => onSetStatus!(GoalStatus.archived),
                    child: Text(
                      '归档',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 状态徽标配色（archived / paused 用中性色，表示非活跃）。
  ///
  /// 与 webapp `goalStatusClassName` 同一取舍：`active` 是「正在推进」的
  /// 强信号（主色），`completed` 是达成（次强调色），其余降为中性。
  static Color _statusColor(ColorScheme scheme, GoalStatus status) =>
      switch (status) {
        GoalStatus.active => scheme.primary,
        GoalStatus.completed => scheme.tertiary,
        _ => scheme.onSurfaceVariant,
      };

  /// commit sha 截断为前 8 位。
  static String _shortCommit(String sha) =>
      sha.length > 8 ? sha.substring(0, 8) : sha;

  /// `createdAt` → `YYYY-MM-DD HH:MM`（本地时区）。
  ///
  /// 不引 `intl`：本面板只需要一种固定格式，而 `intl` 会为一次格式化引入
  /// 一整套 locale 数据（体积 + 初始化开销）。`Goal.fromJson` 已把时间
  /// 转成本地时区，故这里直接读字段。
  static String _formatTimestamp(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p2(t.month)}-${p2(t.day)} '
        '${p2(t.hour)}:${p2(t.minute)}';
  }
}

/// 状态徽标。
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: SpbRadius.cardAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 行内的次要元信息（tasks_source / 时间 / commit）。
class _Meta extends StatelessWidget {
  const _Meta({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
