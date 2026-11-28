import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'goal_tasks_panel.dart';
import 'group_turn_labels.dart';

enum WorkOverviewSection { home, inbox, issues, works, files, more }

enum WorkDetailSection { overview, tasks, files }

typedef OpenWorkDetail = void Function(
  ChatGroup group,
  WorkDetailSection section, {
  GoalTask? task,
});

/// 复用对话列表的已加载窗口，避免两页各自请求和写入同一份缓存。
class WorkOverviewPage extends StatefulWidget {
  const WorkOverviewPage({
    super.key,
    required this.groups,
    required this.loading,
    required this.hasMore,
    required this.fromCache,
    required this.loadFailed,
    required this.confirmations,
    required this.confirmationsUnavailable,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onOpenConversations,
    required this.onOpenConfirmations,
    required this.onOpenWork,
    required this.onQuickCapture,
    this.fileSummaryOf,
    this.moreActions = const {},
    this.turnSummaries,
    this.onOpenTurn,
  });

  final List<ChatGroup> groups;
  final bool loading;
  final bool hasMore;
  final bool fromCache;
  final bool loadFailed;
  final PendingConfirmationSummary? confirmations;
  final bool confirmationsUnavailable;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onOpenConversations;
  final ValueChanged<ChatConfirmation?> onOpenConfirmations;
  final OpenWorkDetail onOpenWork;
  final VoidCallback onQuickCapture;
  final GroupFileSummary? Function(String groupId)? fileSummaryOf;
  final Map<String, VoidCallback> moreActions;
  final Map<String, GroupTurnSummary>? turnSummaries;
  final void Function(String groupId, String turnId)? onOpenTurn;

  @override
  State<WorkOverviewPage> createState() => _WorkOverviewPageState();
}

class _WorkOverviewPageState extends State<WorkOverviewPage> {
  WorkOverviewSection _section = WorkOverviewSection.home;

  void _select(WorkOverviewSection section) =>
      setState(() => _section = section);

  @override
  Widget build(BuildContext context) {
    final home = _section == WorkOverviewSection.home;
    final width = MediaQuery.sizeOf(context).width;
    final compact = SpbBreakpoints.isCompact(width);
    final works = [
      for (final group in widget.groups)
        _WorkSummary(
          group,
          GoalSnapshot.fromJson(group.currentGoal ?? const {}),
        ),
    ];
    final current = works.where((work) => !work.group.isArchived).toList();
    final groupTitles = {
      for (final group in widget.groups) group.id: group.title,
    };
    final issues = works
        .where((work) => work.summary.needsAttention && !work.group.isArchived)
        .toList();
    final failedTurns = [
      for (final work in current)
        if (widget.turnSummaries?[work.group.id] case final summary?
            when summary.isVerified)
          if (summary.latestFinished case final turn?
              when turn.status == GroupTurnStatus.failed)
            (group: work.group, turnId: turn.id),
    ];
    final confirmItems = widget.confirmations?.items ?? const [];
    final confirmation = confirmItems.firstOrNull;
    final confirmationGroup = widget.groups
        .where((group) => group.id == confirmation?.groupId)
        .firstOrNull;
    final currentPreview = Column(
      children: [
        _SectionHeading(
          '当前工作',
          onMore: () => _select(WorkOverviewSection.works),
        ),
        if (current.isEmpty && !widget.loading && !widget.loadFailed)
          const _OverviewNotice('已加载范围内暂无当前工作'),
        for (final work in current.take(3))
          _workRow(work, WorkDetailSection.overview),
      ],
    );
    final filePreview = Column(
      children: [
        _SectionHeading(
          '交付物',
          onMore: () => _select(WorkOverviewSection.files),
        ),
        for (final work in works.take(2))
          _workRow(work, WorkDetailSection.files),
      ],
    );
    return PopScope(
      canPop: home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !home) _select(WorkOverviewSection.home);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: home
              ? null
              : BackButton(onPressed: () => _select(WorkOverviewSection.home)),
          title: Text(
            switch (_section) {
              WorkOverviewSection.home => '工作概览',
              WorkOverviewSection.inbox => '待你处理',
              WorkOverviewSection.issues => '异常任务',
              WorkOverviewSection.works => '当前工作',
              WorkOverviewSection.files => '交付物',
              WorkOverviewSection.more => '更多',
            },
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (home && compact)
              IconButton(
                tooltip: '对话',
                icon: const Icon(Icons.forum_outlined),
                onPressed: widget.onOpenConversations,
              ),
            if (home && !compact)
              TextButton.icon(
                onPressed: widget.onOpenConversations,
                icon: const Icon(Icons.forum_outlined),
                label: const Text('对话'),
              ),
            if (_section != WorkOverviewSection.more)
              IconButton(
                tooltip: '刷新',
                onPressed: widget.loading ? null : widget.onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            if (home && widget.moreActions.isNotEmpty)
              IconButton(
                tooltip: '更多',
                icon: const Icon(Icons.more_horiz),
                onPressed: () => _select(WorkOverviewSection.more),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: _section == WorkOverviewSection.more
              ? ListView(
                  padding: SpbSpacing.pagePadding,
                  children: [
                    for (final action in widget.moreActions.entries)
                      ListTile(
                        title: Text(action.key),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: action.value,
                      ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: CustomScrollView(
                    key: PageStorageKey(_section),
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: ((width - SpbBreakpoints.medium) / 2)
                              .clamp(SpbSpacing.lg, double.infinity),
                          vertical: SpbSpacing.lg,
                        ),
                        sliver: SliverList.list(
                          children: [
                            if (home) ...[
                              Wrap(
                                spacing: SpbSpacing.sm,
                                runSpacing: SpbSpacing.xs,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: widget.onQuickCapture,
                                    icon: const Icon(
                                      Icons.add_comment_outlined,
                                    ),
                                    label: const Text('快速对话'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        widget.onOpenConfirmations(null),
                                    icon: const Icon(
                                      Icons.pending_actions_outlined,
                                    ),
                                    label: const Text('待确认'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _select(WorkOverviewSection.works),
                                    icon: const Icon(Icons.flag_outlined),
                                    label: const Text('当前工作'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        _select(WorkOverviewSection.files),
                                    icon: const Icon(Icons.folder_outlined),
                                    label: const Text('交付物'),
                                  ),
                                ],
                              ),
                              _SectionHeading(
                                '待你处理',
                                moreLabel: '查看全部待处理',
                                onMore: () =>
                                    _select(WorkOverviewSection.inbox),
                              ),
                              _OverviewRow(
                                icon: Icons.pending_actions_outlined,
                                title: _confirmationLabel,
                                detail: confirmation == null
                                    ? null
                                    : [
                                        if (confirmationGroup != null)
                                          confirmationGroup.title,
                                        confirmation.reason,
                                      ].join(' · '),
                                onTap: () => widget.onOpenConfirmations(
                                  confirmItems.firstOrNull,
                                ),
                              ),
                              _OverviewRow(
                                icon: Icons.error_outline,
                                title: '失败与阻塞',
                                detail: failedTurns.isNotEmpty
                                    ? '${failedTurns.first.group.title} · 最近一轮失败'
                                    : issues.isEmpty
                                    ? _issuesStatus
                                    : '${issues.first.group.title} · ${issues.first.issueLabel}',
                                onTap: () =>
                                    _select(WorkOverviewSection.issues),
                              ),
                            ],
                            if (widget.fromCache)
                              const _OverviewNotice('离线 · 显示已缓存的工作'),
                            if (widget.loadFailed)
                              const _OverviewNotice('工作列表读取失败，可刷新重试'),
                            if (widget.loading) const LinearProgressIndicator(),
                            if (home)
                              if (width >= SpbBreakpoints.medium)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: currentPreview),
                                    const SizedBox(width: SpbSpacing.xl),
                                    Expanded(child: filePreview),
                                  ],
                                )
                              else ...[
                                currentPreview,
                                filePreview,
                              ],
                            if (_section == WorkOverviewSection.works) ...[
                              if (current.isEmpty &&
                                  !widget.loading &&
                                  !widget.loadFailed)
                                _OverviewNotice(
                                  widget.hasMore ? '已加载范围内暂无当前工作' : '暂无当前工作',
                                ),
                              for (final work in current)
                                _workRow(work, WorkDetailSection.overview),
                            ],
                            if (_section == WorkOverviewSection.inbox) ...[
                              _SectionHeading(
                                _confirmationLabel,
                                moreLabel: '打开确认列表',
                                onMore: confirmItems.isEmpty
                                    ? null
                                    : () => widget.onOpenConfirmations(null),
                              ),
                              for (final item in confirmItems)
                                _OverviewRow(
                                  icon: Icons.pending_actions_outlined,
                                  title: item.reason,
                                  detail: groupTitles[item.groupId],
                                  onTap: () => widget.onOpenConfirmations(item),
                                ),
                              const _SectionHeading('失败与阻塞'),
                            ],
                            if (_section == WorkOverviewSection.issues ||
                                _section == WorkOverviewSection.inbox) ...[
                              if (issues.isEmpty && failedTurns.isEmpty)
                                _OverviewNotice(_issuesStatus),
                              for (final failure in failedTurns)
                                _OverviewRow(
                                  icon: Icons.error_outline,
                                  title: failure.group.title,
                                  detail: '最近一轮失败 · 查看对话',
                                  onTap: () => widget.onOpenTurn?.call(
                                    failure.group.id,
                                    failure.turnId,
                                  ),
                                ),
                              for (final work in issues)
                                _workRow(work, WorkDetailSection.tasks),
                            ],
                            if (_section == WorkOverviewSection.files) ...[
                              if (works.isEmpty &&
                                  !widget.loading &&
                                  !widget.loadFailed)
                                const _OverviewNotice('暂无可浏览的工作'),
                              for (final work in works)
                                _workRow(work, WorkDetailSection.files),
                            ],
                            if (!home && widget.hasMore && !widget.loading)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: widget.onLoadMore,
                                  child: const Text('加载更多工作'),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  String get _confirmationLabel {
    final summary = widget.confirmations;
    if (summary == null) {
      return widget.confirmationsUnavailable ? '待确认暂无法核实' : '正在读取待确认';
    }
    if (summary.isTruncated) return '至少 ${summary.total} 项待确认';
    return summary.total == 0 ? '暂无待确认事项' : '${summary.total} 项待确认';
  }

  String get _issuesStatus {
    if (widget.loading && widget.groups.isEmpty) return '正在读取工作';
    if (widget.loadFailed && widget.groups.isEmpty) return '异常状态暂无法核实';
    if (widget.turnSummaries case final turns?) {
      if (widget.groups.any(
        (group) => !group.isArchived && turns[group.id]?.isVerified != true,
      )) {
        return '已核实范围内未发现失败或阻塞';
      }
    }
    return '已加载工作中未发现失败或阻塞';
  }

  String? _workProgress(_WorkSummary work) {
    final turns = widget.turnSummaries;
    final hasConfirmation =
        (widget.confirmations?.byGroup[work.group.id] ?? 0) > 0;
    final summary = turns?[work.group.id];
    final label = hasConfirmation
        ? '待你确认'
        : turns == null
        ? null
        : groupTurnLabel(
            summary,
            archived: work.group.isArchived,
            hasConfirmation: hasConfirmation,
          );
    final parts = [
      ?label,
      if (summary?.isVerified == true &&
          summary?.latestFinished?.status == GroupTurnStatus.failed &&
          label != '最近一轮失败')
        '最近一轮失败',
      ?work.progressLabel,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _workRow(_WorkSummary work, WorkDetailSection section) => _OverviewRow(
    icon: switch (section) {
      WorkDetailSection.overview => Icons.flag_outlined,
      WorkDetailSection.tasks => Icons.error_outline,
      WorkDetailSection.files => Icons.folder_outlined,
    },
    title: work.group.title,
    detail: switch (section) {
      WorkDetailSection.overview => _workProgress(work),
      WorkDetailSection.tasks => work.issueLabel,
      WorkDetailSection.files => switch (widget.fileSummaryOf?.call(
        work.group.id,
      )) {
        final summary? => '本地同步记录 · ${summary.fileCount} 个文件',
        null => widget.fileSummaryOf == null ? '本地同步记录暂不可用' : '本地暂无同步记录',
      },
    },
    onTap: () => widget.onOpenWork(
      work.group,
      section,
      task: section == WorkDetailSection.tasks
          ? work.summary.problemTask
          : null,
    ),
  );
}

/// 同一工作的只读摘要与任务使用同一份目标快照。
class WorkOverviewDetailPage extends StatefulWidget {
  const WorkOverviewDetailPage({
    super.key,
    required this.group,
    required this.initialSection,
    required this.onOpenConversation,
    required this.deliverablesBuilder,
    this.taskId,
    this.goalId,
    this.onReload,
    this.confirmations,
    this.confirmationsUnavailable = false,
    this.onOpenConfirmations,
    this.localFiles,
    this.loadLatestTurn,
    this.onOpenTurn,
  });

  final ChatGroup group;
  final WorkDetailSection initialSection;
  final VoidCallback onOpenConversation;
  final WidgetBuilder deliverablesBuilder;
  final String? taskId;
  final String? goalId;
  final Future<void> Function()? onReload;
  final PendingConfirmationSummary? confirmations;
  final bool confirmationsUnavailable;
  final VoidCallback? onOpenConfirmations;
  final GroupFileSummary? localFiles;
  final Future<ChatTurn?> Function()? loadLatestTurn;
  final ValueChanged<String>? onOpenTurn;

  @override
  State<WorkOverviewDetailPage> createState() => _WorkOverviewDetailPageState();
}

class _WorkOverviewDetailPageState extends State<WorkOverviewDetailPage> {
  late WorkDetailSection _section = widget.initialSection;
  Future<ChatTurn?>? _latestTurn;

  @override
  void initState() {
    super.initState();
    if (_section == WorkDetailSection.overview) {
      _latestTurn = widget.loadLatestTurn?.call();
    }
  }

  @override
  void didUpdateWidget(WorkOverviewDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.id != widget.group.id ||
        oldWidget.initialSection != widget.initialSection ||
        oldWidget.taskId != widget.taskId) {
      _section = widget.initialSection;
      if (oldWidget.group.id != widget.group.id) _latestTurn = null;
      if (_section == WorkDetailSection.overview) {
        _latestTurn ??= widget.loadLatestTurn?.call();
      }
    }
  }

  void _selectSection(WorkDetailSection section) => setState(() {
    _section = section;
    if (section == WorkDetailSection.overview) {
      _latestTurn ??= widget.loadLatestTurn?.call();
    }
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = GoalSnapshot.fromJson(
      widget.group.currentGoal ?? const {},
    );
    final work = _WorkSummary(widget.group, snapshot);
    final confirmations = widget.confirmations;
    final count = confirmations?.byGroup[widget.group.id] ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.group.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: SpbBreakpoints.medium),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: SpbSpacing.pagePadding,
                  child: Wrap(
                    spacing: SpbSpacing.sm,
                    children: [
                      for (final (section, label) in const [
                        (WorkDetailSection.overview, '概览'),
                        (WorkDetailSection.tasks, '任务'),
                        (WorkDetailSection.files, '交付物'),
                      ])
                        ChoiceChip(
                          label: Text(label),
                          selected: _section == section,
                          onSelected: (_) => _selectSection(section),
                        ),
                      TextButton(
                        onPressed: widget.onOpenConversation,
                        child: const Text('对话'),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: switch (_section) {
                    WorkDetailSection.overview => ListView(
                      padding: SpbSpacing.pagePadding,
                      children: [
                        if ((snapshot.goal?.goalText ?? widget.group.goal ?? '')
                            .trim()
                            .isNotEmpty)
                          Text(
                            snapshot.goal?.goalText ?? widget.group.goal ?? '',
                          ),
                        if (_latestTurn case final latest?)
                          _LatestWorkTurn(
                            latest: latest,
                            onOpenTurn: widget.onOpenTurn,
                            onRetry: () => setState(
                              () => _latestTurn = widget.loadLatestTurn?.call(),
                            ),
                          ),
                        _OverviewRow(
                          icon: Icons.flag_outlined,
                          title: '任务清单',
                          detail: work.progressLabel,
                          onTap: () => _selectSection(WorkDetailSection.tasks),
                        ),
                        if (widget.onOpenConfirmations case final open?)
                          _OverviewRow(
                            icon: Icons.pending_actions_outlined,
                            title: '本工作待确认',
                            detail: switch (confirmations) {
                              null when widget.confirmationsUnavailable =>
                                '待确认状态暂无法核实',
                              null => '正在读取待确认',
                              _ when count == 0 && confirmations.isTruncated =>
                                '当前查询内暂无匹配事项',
                              _ when count == 0 => '暂无待确认事项',
                              _ =>
                                '${confirmations.isTruncated ? '至少 ' : ''}$count 项待确认',
                            },
                            onTap: open,
                          ),
                        _OverviewRow(
                          icon: Icons.folder_outlined,
                          title: '查看工作文件',
                          detail: widget.localFiles == null
                              ? null
                              : '本地同步记录 · ${widget.localFiles!.fileCount} 个文件',
                          onTap: () => _selectSection(WorkDetailSection.files),
                        ),
                      ],
                    ),
                    WorkDetailSection.tasks => GoalTasksPanel(
                      snapshot: snapshot,
                      onReload: widget.onReload,
                      onOpenProblemConversation: widget.onOpenConversation,
                      focusTaskId: widget.goalId == snapshot.goal?.id
                          ? widget.taskId
                          : null,
                    ),
                    WorkDetailSection.files => Builder(
                      builder: widget.deliverablesBuilder,
                    ),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LatestWorkTurn extends StatelessWidget {
  const _LatestWorkTurn({
    required this.latest,
    required this.onOpenTurn,
    required this.onRetry,
  });

  final Future<ChatTurn?> latest;
  final ValueChanged<String>? onOpenTurn;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => FutureBuilder<ChatTurn?>(
    future: latest,
    builder: (context, snapshot) {
      final turn = snapshot.data;
      final status = GroupTurnStatus.parse(turn?.status);
      final label = switch (status) {
        GroupTurnStatus.running => '执行中',
        GroupTurnStatus.queued => '排队中',
        GroupTurnStatus.pending => '待处理',
        GroupTurnStatus.completed => '已完成',
        GroupTurnStatus.failed => '失败',
        GroupTurnStatus.cancelled => '已取消',
        null when snapshot.connectionState != ConnectionState.done => '正在核实',
        null when snapshot.hasError || turn != null => '状态未核实',
        null => '暂无轮次',
      };
      return ListTile(
        leading: const Icon(Icons.forum_outlined),
        title: Text('最近一轮 · $label'),
        onTap: switch (turn) {
          final item? when item.id.isNotEmpty && onOpenTurn != null =>
            () => onOpenTurn!(item.id),
          _ => null,
        },
        trailing: snapshot.hasError
            ? IconButton(
                tooltip: '重试核实轮次',
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              )
            : null,
      );
    },
  );
}

class _WorkSummary {
  _WorkSummary(this.group, GoalSnapshot snapshot)
    : summary = GroupGoalSummary(snapshot);

  final ChatGroup group;
  final GroupGoalSummary summary;

  String? get progressLabel {
    final progress = summary.progress;
    final parts = [
      if (summary.currentTaskLabel case final task?) task,
      if (progress != null && progress.total > 0)
        '${progress.completed}/${progress.total} 项已完成',
      if (summary.needsAttention) issueLabel,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String get issueLabel {
    final parts = [
      if (summary.errorCount > 0) '${summary.errorCount} 项失败',
      if (summary.blockedCount > 0) '${summary.blockedCount} 项阻塞',
      if (summary.problemTask case final task?)
        task.title.trim().isEmpty ? task.taskId : task.title,
    ];
    return parts.join(' · ');
  }
}

class _OverviewRow extends StatelessWidget {
  const _OverviewRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(SpbRadius.sm)),
    ),
    leading: Icon(icon),
    title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: detail == null
        ? null
        : Text(detail!, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _OverviewNotice extends StatelessWidget {
  const _OverviewNotice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: SpbSpacing.sm),
    child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label, {this.onMore, this.moreLabel = '查看全部'});

  final String label;
  final VoidCallback? onMore;
  final String moreLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: SpbSpacing.lg),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(label, style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        if (onMore != null)
          TextButton(
            onPressed: onMore,
            child: Text(label == '交付物' ? '按工作浏览' : moreLabel),
          ),
      ],
    ),
  );
}
