import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 习惯管理页：规则列表 + 启停 + 立即执行 + 执行历史。
///
/// ## 为什么用注入回调而不是收一个 `HabitApi`
///
/// 与 [PendingConfirmationsPage] 同一理由：本页只负责「展示 + 收集意图」，
/// 请求与错误翻译归调用方（app 装配层）。这样：
/// - widget test 里无需 HTTP mock 就能验证「什么条件下可点、点了传什么」；
/// - 「习惯功能整体关闭」时可以只不注入而不动页面代码。
///
/// ## 为什么列表与历史在同一页（两个 Tab）而不是两个页面
///
/// 用户看习惯时的真实问题是「这条规则到底有没有用」——需要**在规则旁边**看到
/// 它的执行记录。分成两个页面后，用户要在两处之间来回跳、还要自己把
/// `pattern_id` 对上号。
///
/// 但历史是**跨规则**的（服务端 `/api/habits/runs` 返回全部，含没有 pattern 的
/// 候选建议记录），故两个 Tab 各自的查询不同：规则 Tab 用 [loadHabits]，
/// 历史 Tab 用 [loadRuns]。
class HabitsPage extends StatefulWidget {
  const HabitsPage({
    super.key,
    required this.loadHabits,
    required this.loadRuns,
    this.onTrigger,
    this.onPause,
    this.onResume,
    this.onArchive,
    this.onCreate,
    this.onOpenTurn,
    required this.groupTitleOf,
  });

  /// 拉取规则列表（`GET /api/habits`）。
  final Future<List<UserHabit>> Function() loadHabits;

  /// 拉取执行历史（`GET /api/habits/runs`）。
  final Future<List<HabitRun>> Function() loadRuns;

  /// 立即执行一次（服务端要求 `active`，否则 409）。
  final Future<void> Function(UserHabit habit)? onTrigger;

  /// 暂停（仅 `active` → `paused`）。
  final Future<void> Function(UserHabit habit)? onPause;

  /// 恢复（仅 `paused` → `active`）。
  final Future<void> Function(UserHabit habit)? onResume;

  /// 归档（**终态**，无撤销端点）。
  final Future<void> Function(UserHabit habit)? onArchive;

  /// 新建规则。返回服务端建出的 pattern id（空串表示服务端未返回）。
  final Future<String> Function(HabitDraft draft)? onCreate;

  /// 跳到某条执行记录产生的对话。
  final void Function(String groupId, String turnId)? onOpenTurn;

  /// 给定 groupId 返回对话标题（历史列表展示上下文用）。
  ///
  /// 必需而非可选：服务端 `/api/habits/runs` 只返回 `delivery_group_id`，
  /// 标题要由调用方从已有的 group 列表里查。不注入的话每条记录只能显示
  /// 一个 id，用户无法判断“这条到底跑在哪”。
  final String? Function(String groupId) groupTitleOf;

  @override
  State<HabitsPage> createState() => _HabitsPageState();
}

class _HabitsPageState extends State<HabitsPage> {
  List<UserHabit>? _habits;
  List<HabitRun>? _runs;
  Object? _error;
  bool _loading = true;

  /// 正在执行写操作的 pattern id（防重复点击）。
  final _busy = <String>{};

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
      // 两个查询互不依赖，并发发出（历史页首屏也需要它）。
      final results = await Future.wait([
        widget.loadHabits(),
        widget.loadRuns(),
      ]);
      if (!mounted) return;
      setState(() {
        _habits = results[0] as List<UserHabit>;
        _runs = results[1] as List<HabitRun>;
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

  /// 执行一个针对某条规则的写操作，统一处理在途标记与失败提示。
  ///
  /// ## 为什么失败要弹提示而不是静默
  ///
  /// 这些操作都可能因**状态不符**失败（服务端 409：`仅 active 状态可触发`）。
  /// 静默失败会让用户看到「点了没反应」，然后反复点——而真正的原因是列表已经
  /// 过期（另一端改了状态）。弹提示 + 重新拉取才能让用户看到真实状态。
  Future<void> _runAction(
    UserHabit habit,
    Future<void> Function(UserHabit) action,
  ) async {
    if (_busy.contains(habit.id)) return;
    setState(() => _busy.add(habit.id));
    try {
      await action(habit);
      if (!mounted) return;
      await _load();
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(habit.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_actionErrorText(e))));
      // 失败后刷新：多半是状态已变（另一端操作过），刷新能让用户看到真实状态。
      await _load();
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _busy.remove(habit.id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    } finally {
      if (mounted) setState(() => _busy.remove(habit.id));
    }
  }

  /// 把服务端错误翻成用户能理解的话。
  ///
  /// 409 是**预期内**的失败（状态不符），文案必须说明原因，否则用户会以为
  /// 客户端坏了。其余错误保留服务端原文（`HttpError.message` 已是 `{error}` 字段）。
  static String _actionErrorText(SpbError e) {
    if (e is HttpError) {
      // `SpbError.message` 是**非空** String（见 errors.dart），服务端 `{error}`
      // 字段在解析时已落进它，故无需再写 `?? 兜底`（那是死代码）。
      if (e.isConflict) return e.message.isEmpty ? '规则状态已变化，请刷新后重试' : e.message;
      if (e.isNotFound) return '规则已不存在';
      return e.message.isEmpty ? '操作失败（HTTP ${e.statusCode}）' : e.message;
    }
    return e.message.isEmpty ? '操作失败，请重试' : e.message;
  }

  Future<void> _handleCreate() async {
    final cb = widget.onCreate;
    if (cb == null) return;
    final draft = await showDialog<HabitDraft>(
      context: context,
      builder: (ctx) => const HabitEditorDialog(),
    );
    if (draft == null || !mounted) return;

    setState(() => _loading = true);
    try {
      await cb(draft);
      if (!mounted) return;
      await _load();
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_actionErrorText(e))));
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('创建失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('习惯'),
          actions: [
            if (widget.onCreate != null)
              IconButton(
                key: const ValueKey('habits-create'),
                icon: const Icon(Icons.add),
                tooltip: '新建习惯',
                onPressed: _loading ? null : _handleCreate,
              ),
            IconButton(
              key: const ValueKey('habits-refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '规则'),
              Tab(text: '执行记录'),
            ],
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _habits == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null && _habits == null) {
      return _ErrorView(error: err, onRetry: _load);
    }
    return TabBarView(children: [_buildHabits(), _buildRuns()]);
  }

  Widget _buildHabits() {
    final habits = _habits ?? const <UserHabit>[];
    if (habits.isEmpty) {
      return const _EmptyView(
        icon: Icons.repeat,
        text: '还没有习惯。\nAgent 发现你的规律后会在这里（以及对话里）给出建议。',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: SpbSpacing.pagePadding,
        itemCount: habits.length,
        separatorBuilder: (_, _) => const SizedBox(height: SpbSpacing.sm),
        itemBuilder: (context, i) => _HabitTile(
          habit: habits[i],
          busy: _busy.contains(habits[i].id),
          onTrigger: widget.onTrigger == null
              ? null
              : (h) => _runAction(h, widget.onTrigger!),
          onPause: widget.onPause == null
              ? null
              : (h) => _runAction(h, widget.onPause!),
          onResume: widget.onResume == null
              ? null
              : (h) => _runAction(h, widget.onResume!),
          onArchive: widget.onArchive == null
              ? null
              : (h) => _confirmArchive(h),
        ),
      ),
    );
  }

  /// 归档前二次确认。
  ///
  /// 归档是**终态**——服务端没有 unarchive 端点（`habits_full.go` 只有
  /// archive），误点后只能重新建一条。故必须确认。
  Future<void> _confirmArchive(UserHabit habit) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('归档这个习惯？'),
        content: Text('「${habit.topicKey}」归档后不再触发，且无法恢复（服务端不提供撤销）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('habit-archive-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _runAction(habit, widget.onArchive!);
  }

  Widget _buildRuns() {
    final runs = _runs ?? const <HabitRun>[];
    if (runs.isEmpty) {
      return const _EmptyView(icon: Icons.history, text: '还没有执行记录。');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: SpbSpacing.pagePadding,
        itemCount: runs.length,
        separatorBuilder: (_, _) => const Divider(height: SpbSpacing.xl),
        itemBuilder: (context, i) => _RunTile(
          run: runs[i],
          // 优先投递对话（实际执行处），回退来源对话。
          //
          // 两者在 due_rule 类里通常相同；但 `delivery_group_id` 为空而
          // `origin_group_id` 有值时（候选类记录），只看前者会丢掉上下文。
          groupTitle: _groupTitleFor(runs[i]),
          onOpenTurn: widget.onOpenTurn,
        ),
      ),
    );
  }

  String _groupTitleFor(HabitRun run) {
    final gid = run.deliveryGroupId ?? run.originGroupId;
    if (gid.isEmpty) return '';
    return widget.groupTitleOf(gid) ?? '';
  }
}

/// 一条规则卡片。
class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.habit,
    required this.busy,
    this.onTrigger,
    this.onPause,
    this.onResume,
    this.onArchive,
  });

  final UserHabit habit;
  final bool busy;
  final void Function(UserHabit)? onTrigger;
  final void Function(UserHabit)? onPause;
  final void Function(UserHabit)? onResume;
  final void Function(UserHabit)? onArchive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      key: ValueKey('habit-${habit.id}'),
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _topicLabel(habit.topicKey),
                    style: textTheme.titleSmall,
                  ),
                ),
                _StatusChip(status: habit.status),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text(
              habit.triggerConfig.summary,
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SpbSpacing.xxs),
            Text(
              _metaLine(habit),
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            Wrap(
              spacing: SpbSpacing.sm,
              runSpacing: SpbSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 每个按钮的存在条件由模型决定（`canTrigger` / `canPause` /
                // `canResume`），与页面的服务端状态机知识保持单一来源。
                if (onTrigger != null && habit.canTrigger)
                  TextButton.icon(
                    key: ValueKey('habit-trigger-${habit.id}'),
                    onPressed: busy ? null : () => onTrigger!(habit),
                    icon: const Icon(Icons.play_arrow, size: SpbSpacing.lg),
                    label: const Text('立即执行'),
                  ),
                if (onPause != null && habit.canPause)
                  TextButton.icon(
                    key: ValueKey('habit-pause-${habit.id}'),
                    onPressed: busy ? null : () => onPause!(habit),
                    icon: const Icon(Icons.pause, size: SpbSpacing.lg),
                    label: const Text('暂停'),
                  ),
                if (onResume != null && habit.canResume)
                  TextButton.icon(
                    key: ValueKey('habit-resume-${habit.id}'),
                    onPressed: busy ? null : () => onResume!(habit),
                    icon: const Icon(Icons.play_circle, size: SpbSpacing.lg),
                    label: const Text('恢复'),
                  ),
                if (onArchive != null && habit.canArchive)
                  TextButton(
                    key: ValueKey('habit-archive-${habit.id}'),
                    onPressed: busy ? null : () => onArchive!(habit),
                    child: const Text('归档'),
                  ),
                if (busy)
                  const SizedBox(
                    width: SpbSpacing.lg,
                    height: SpbSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 与建议卡同策略：topic_key 是机器键，换分隔符展示，不编造中文名。
  static String _topicLabel(String topicKey) {
    if (topicKey.isEmpty) return '未命名习惯';
    return topicKey.replaceAll(RegExp(r'[._-]+'), ' ');
  }

  /// 副行：接受级别 · 来源 · 已执行次数 · 下次触发。
  static String _metaLine(UserHabit h) {
    final parts = <String>[
      h.acceptanceLevel.label,
      if (h.sourceType != HabitSourceType.unknown) h.sourceType.label,
      '已执行 ${h.triggerCount} 次',
    ];
    final next = h.nextFireAt;
    if (next != null && h.isActive) {
      parts.add('下次 ${_formatTime(next)}');
    }
    return parts.join(' · ');
  }

  static String _formatTime(DateTime t) {
    final local = t.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${p2(local.hour)}:${p2(local.minute)}';
  }
}

/// 状态徽标。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final HabitPatternStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      HabitPatternStatus.active => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      HabitPatternStatus.paused => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      HabitPatternStatus.archived => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      _ => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(color: bg, borderRadius: SpbRadius.cardAll),
      child: Text(
        status.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// 一条执行记录。
class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.run,
    required this.groupTitle,
    this.onOpenTurn,
  });

  final HabitRun run;
  final String groupTitle;
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
            Expanded(
              child: Text(
                run.topicKey.isEmpty ? '未命名' : run.topicKey,
                style: textTheme.titleSmall,
              ),
            ),
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

/// 空态。
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.icon, required this.text});

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
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

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
              key: const ValueKey('habits-retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建习惯的草稿（对话框产物）。
///
/// ## 为什么只暴露这两个字段
///
/// `POST /api/habits` 的必填项只有 `topic_key`；`acceptance_level` 有服务端默认
/// 值但语义关键（决定「自动跑」还是「只建议」），故必须让用户选。其余字段
/// （preferred_agent_id / delivery_group_id / prompt_contract）要么需要额外的
/// 列表数据，要么是高级用法——留空由服务端按默认处理，比让用户面对一堆
/// 不知道填什么的输入框更好。
class HabitDraft {
  const HabitDraft({
    required this.topicKey,
    required this.acceptanceLevel,
    this.triggerConfig,
  });

  final String topicKey;
  final HabitAcceptanceLevel acceptanceLevel;

  /// 触发条件。null = 不配时间（服务端回退 now+60min 兜底）。
  final HabitTriggerConfig? triggerConfig;
}

/// 新建习惯对话框。
class HabitEditorDialog extends StatefulWidget {
  const HabitEditorDialog({super.key});

  @override
  State<HabitEditorDialog> createState() => _HabitEditorDialogState();
}

class _HabitEditorDialogState extends State<HabitEditorDialog> {
  final _topicController = TextEditingController();
  HabitAcceptanceLevel _level = HabitAcceptanceLevel.suggestOnly;

  /// 小时/分钟。默认 9:00（与 webapp HabitPatternEditor 的默认一致）。
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);

  /// 星期（1=周一 … 7=周日）。空 = 每天。
  final _weekdays = <int>{};

  @override
  void dispose() {
    _topicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final valid = _topicController.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('新建习惯'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('habit-editor-topic'),
              controller: _topicController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '主题',
                helperText: '如 weekly-report、preference.coffee',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: SpbSpacing.lg),
            Text('执行方式', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: SpbSpacing.xs),
            // RadioListTile.groupValue / onChanged 在 Flutter 3.32 起已弃用，
            // 改由祖先 RadioGroup 统一持有选中值与回调（与 settings_page 一致）。
            RadioGroup<HabitAcceptanceLevel>(
              groupValue: _level,
              onChanged: (v) => setState(() => _level = v ?? _level),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in HabitAcceptanceLevel.values)
                    if (l != HabitAcceptanceLevel.unknown)
                      RadioListTile<HabitAcceptanceLevel>(
                        key: ValueKey('habit-editor-level-${l.wire}'),
                        value: l,
                        title: Text(l.label),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                ],
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '触发时间',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                TextButton(
                  key: const ValueKey('habit-editor-time'),
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: _time,
                    );
                    if (picked != null && mounted) {
                      setState(() => _time = picked);
                    }
                  },
                  child: Text(_time.format(context)),
                ),
              ],
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text('重复（不选 = 每天）', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: SpbSpacing.xs),
            Wrap(
              spacing: SpbSpacing.xs,
              children: [
                for (var d = 1; d <= 7; d++)
                  FilterChip(
                    key: ValueKey('habit-editor-weekday-$d'),
                    label: Text(
                      const ['一', '二', '三', '四', '五', '六', '日'][d - 1],
                    ),
                    selected: _weekdays.contains(d),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _weekdays.add(d);
                      } else {
                        _weekdays.remove(d);
                      }
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('habit-editor-save'),
          onPressed: valid
              ? () => Navigator.of(context).pop(
                  HabitDraft(
                    topicKey: _topicController.text.trim(),
                    acceptanceLevel: _level,
                    triggerConfig: HabitTriggerConfig(
                      triggerType: HabitTriggerType.timeBased,
                      time: HabitTimeTriggerConfig(
                        // 只填 times（服务端会据它同步顶层 hour/minute 影子字段）。
                        times: [
                          HabitTimeOfDay(
                            hour: _time.hour,
                            minute: _time.minute,
                          ),
                        ],
                        weekdays: _weekdays.toList()..sort(),
                      ),
                    ),
                  ),
                )
              : null,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
