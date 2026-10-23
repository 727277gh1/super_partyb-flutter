import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'group_gate_panel.dart';

/// 切换任务状态（`PUT /chat/goals/:goal_id/tasks/:task_id/status`）。
///
/// 参数是 `TASK-NNN` 形式的 **task_id**，不是 `chat_goal_tasks.id` 行 id。
/// 装配层实现即 `GoalApi.setTaskStatus` 的薄包装。
typedef SetGoalTaskStatus = Future<void> Function(
  String taskId,
  GoalTaskStatus status,
);

/// 新增任务（`POST /chat/goals/:goal_id/tasks`）。
///
/// 装配层必须显式传 `origin: GoalTaskOrigin.manual`——服务端只在
/// `origin != "llm"` 时把 `tasks_source` 置为 `manual`，否则人工新增的任务
/// 会在下次 LLM 展开时被当作「可覆盖项」删掉（见 `GoalTaskOrigin.removable`）。
typedef CreateGoalTask = Future<void> Function({
  required String title,
  String? description,
});

/// 编辑任务内容（`PATCH /chat/goals/:goal_id/tasks/:task_id`）。
///
/// 参数是 `TASK-NNN` 形式的 **task_id**，不是 `chat_goal_tasks.id` 行 id。
///
/// ## `''` 与 `null` 的区别（服务端语义，调用方必须分清）
///
/// 服务端对这两个字段的语义是**传了就整体替换**：
///
/// - `null` = **不改**这个字段；
/// - `''`   = **清除**它。
///
/// 故「保存」必须显式传当前输入框的值（空串表示清除描述），**不能**用 `null`
/// 表达「清空」——那会变成「不修改」，用户删掉描述再保存会发现描述还在。
/// 本面板的 [_GoalTasksPanelState._edit] 已按此约定构造参数。
typedef UpdateGoalTask = Future<void> Function(
  String taskId, {
  String? title,
  String? description,
});

/// 删除任务（`DELETE /chat/goals/:goal_id/tasks/:task_id`）。
typedef DeleteGoalTask = Future<void> Function(String taskId);

/// 重排任务（`POST /chat/goals/:goal_id/tasks/reorder`）。
///
/// ## 参数必须是**完整**清单，不是「移动了哪一条」
///
/// 服务端只遍历数组里的 id 逐个写 `order_index`（`for i, tid := range
/// body.TaskIDs`），**不校验完整性**。传增量清单会让未列出的任务保持旧
/// `order_index`，与已写的新值撞号，顺序变得不确定。故本面板每次都把整份
/// 顺序算好再下发（见 [_move]）。
typedef ReorderGoalTasks = Future<void> Function(List<String> taskIds);

/// 为 LLM 重新展开清场（`POST /chat/goals/:goal_id/tasks/reset-for-expand`）。
///
/// **破坏性**：删除 `origin='llm'` 且未被人工编辑的任务，不可撤销。
typedef ResetGoalTasksForExpand = Future<void> Function();

/// 重新拉取当前 goal 快照（含任务与进度）。
typedef ReloadGoalTasks = Future<void> Function();

/// 目标任务清单面板：查看 / 勾选 / 新增 / 删除 / 重排 / 重新展开。
///
/// ## 它解决什么（与既有组件的边界）
///
/// - [GroupSettingsPanel] 只管**目标文本**与群级开关，看不到任务；
/// - [GroupGatePanel] 是**只读诊断**（gate 为什么续跑/停下），刻意不提供操作
///   ——那是已发生的事实，没有「撤销/重做」语义；
/// - 本面板是**任务的可操作视图**：结构化表 `chat_goal_tasks` 的增删改查。
///
/// 三者并存。特别是**没有**把写操作塞进 [GroupGatePanel]（会破坏它「诊断而非
/// 操作」的定位），而是新开一个 tab。本面板通过 `decisions` 参数**复用**
/// [GroupGatePanel] 渲染 gate 诊断——复用的是组件本身，不是它的定位。
///
/// ## 为什么数据靠注入、面板自己不碰 HTTP
///
/// 与 [GroupDeliverablesPanel] / [GroupSettingsPanel] 同一约定：面板只渲染 +
/// 收集意图，HTTP 由 app 装配层注入。故可在无头环境用内存桩完整验证。
///
/// ## 数据是**外部传入**的（面板不持有副本）
///
/// [snapshot] 由父层给出（通常来自 `ChatGroup.currentGoal`，而它又由
/// `goal_updated` SSE 事件实时刷新）。面板不缓存副本，避免「SSE 推来新快照、
/// 面板还显示旧副本」的双真源漂移。写操作完成后由父层负责重新对齐
/// （与 [GroupSettingsPanel] 的 write→re-read 一致）。
///
/// ## 「未注入回调 = 只读」
///
/// 每个写回调都是可空。为 null 时**对应的操作入口整个不渲染**（不是禁用）：
/// 禁用按钮会让用户以为「本端支持但暂时不可用」，而真相是这一端没装配该能力。
/// 全部为 null 时本面板退化为只读清单——与 [GroupGatePanel] 的只读定位一致，
/// 但由调用方按能力决定，而不是写死。
///
/// ## 为什么勾选只发 `completed` / `pending`
///
/// 复选框只有两态，而服务端状态有六种（`pending` / `in_progress` /
/// `completed` / `skipped` / `error_stopped` / `blocked`）。勾选 = 完成，
/// 取消勾选 = 回到待开始。其余四种状态走行尾的状态菜单——不把六态硬塞进
/// 一个 checkbox（那会让「阻塞」与「待开始」在界面上无法区分）。
class GoalTasksPanel extends StatefulWidget {
  const GoalTasksPanel({
    super.key,
    required this.snapshot,
    this.onSetStatus,
    this.onCreate,
    this.onUpdateTask,
    this.onDelete,
    this.onReorder,
    this.onResetForExpand,
    this.onReload,
    this.decisions = const [],
    this.busy = false,
    this.showHeader = true,
    this.emptyHint = '这个对话还没有目标',
    this.noTasksHint = '还没有任务',
    this.reloadToken,
  });

  /// 当前目标快照（含任务与进度）。由父层给出，面板不缓存副本。
  final GoalSnapshot snapshot;

  /// 以下六个为 null 时对应的操作入口不渲染（见类文档「未注入回调 = 只读」）。
  final SetGoalTaskStatus? onSetStatus;
  final CreateGoalTask? onCreate;

  /// 编辑任务标题与描述。为 null 时行尾不渲染「编辑」入口。
  final UpdateGoalTask? onUpdateTask;

  final DeleteGoalTask? onDelete;
  final ReorderGoalTasks? onReorder;
  final ResetGoalTasksForExpand? onResetForExpand;

  /// 头部刷新按钮。为 null 时不渲染该按钮。
  final ReloadGoalTasks? onReload;

  /// Gate 决策（**只读**诊断，转交给 [GroupGatePanel] 渲染）。
  ///
  /// 为空时不渲染该区块——没有决策时放一个空面板只是噪音。
  final List<GateDecision> decisions;

  /// 是否有写操作在途。为 true 时全部控件禁用（防并发提交互相覆盖）。
  final bool busy;

  /// 是否渲染自带标题行（tab 内容通常由 tab 标签承担标题）。
  final bool showHeader;

  /// 无 goal 时的提示。
  final String emptyHint;

  /// 有 goal 但任务清单为空时的提示。
  final String noTasksHint;

  /// 切换对话/目标时重置草稿（Flutter 会复用本 State）。
  final Object? reloadToken;

  @override
  State<GoalTasksPanel> createState() => _GoalTasksPanelState();
}

class _GoalTasksPanelState extends State<GoalTasksPanel> {
  /// 新增任务的标题草稿。
  final _title = TextEditingController();

  @override
  void didUpdateWidget(GoalTasksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      // 换目标：旧目标的半截草稿对新目标没有意义。
      _title.clear();
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  /// 任一控件是否应禁用。
  bool get _locked => widget.busy;

  Future<void> _toggle(GoalTask task) async {
    final cb = widget.onSetStatus;
    if (cb == null) return;
    // 勾选 = 完成；取消 = 回到待开始。
    //
    // `skipped` 也算「已勾选」（服务端把两者并入 completed 计数），故取消一个
    // 被跳过的任务会把它变成 `pending` 而不是还原成 `skipped`——没有「上次
    // 是什么」的记录，且用户明确表达了「这条要重做」。
    await _guard(
      () => cb(
        task.taskId,
        task.isCompleted ? GoalTaskStatus.pending : GoalTaskStatus.completed,
      ),
    );
  }

  /// 把任务上/下移一位，并把**整份**新顺序下发。
  ///
  /// 服务端不校验清单完整性（见 [ReorderGoalTasks] 的文档），故这里必须传
  /// 全量。顺序以 [GoalSnapshot.tasks] 为准（服务端按
  /// `ORDER BY order_index ASC, task_id ASC` 返回，已是展示顺序）。
  Future<void> _move(GoalTask task, int delta) async {
    final cb = widget.onReorder;
    if (cb == null) return;
    final ids = widget.snapshot.tasks.map((t) => t.taskId).toList();
    final from = ids.indexOf(task.taskId);
    if (from < 0) return;
    final to = from + delta;
    if (to < 0 || to >= ids.length) return;
    ids.removeAt(from);
    ids.insert(to, task.taskId);
    await _guard(() => cb(ids));
  }

  Future<void> _create() async {
    final cb = widget.onCreate;
    if (cb == null) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      _message('请先填写任务标题');
      return;
    }
    final ok = await _guard(() => cb(title: title));
    if (ok && mounted) _title.clear();
  }

  Future<void> _delete(GoalTask task) async {
    final cb = widget.onDelete;
    if (cb == null) return;
    // 删除不可撤销，先确认。
    final yes = await _confirm(
      title: '删除任务',
      message: '确定删除「${task.title}」？此操作不可撤销。',
      confirmLabel: '删除',
    );
    if (!yes) return;
    await _guard(() => cb(task.taskId));
  }

  /// 编辑任务的标题与描述。
  ///
  /// ## 为什么用对话框而不是行内编辑
  ///
  /// 行内编辑需要把「标题 + 描述」两个字段的草稿塞进行布局，而行已经被
  /// task_id / 状态 / 来源 / 时间锚点等多个徽标占满（见 [_taskTile]）。
  /// 对话框是**同一个面板里已验证的模式**（[_confirm] / 新增行都用它），
  /// 且能容纳多行描述。
  ///
  /// ## 只做标题 + 描述
  ///
  /// `phase` / `notBefore` / `blockedBy` / `completionSemantics` 的语义复杂
  /// （时间锚点涉及时区、依赖不校验引用存在、完成语义是枚举），照 webapp 的
  /// `GoalTaskEditor` 取舍：它的人工编辑也只提交 `title`。这四个字段目前由
  /// agent / LLM 展开产出，暂不开放人工入口。
  ///
  /// ## 描述的清空语义
  ///
  /// 保存时**显式传输入框的值**（包括空串）——服务端 `''` = 清除、`null` =
  /// 不改。若这里传 `null` 表达「用户清空了描述」，服务端会当成「不修改」，
  /// 用户会发现描述还在（见 [UpdateGoalTask] 的文档）。
  Future<void> _edit(GoalTask task) async {
    final cb = widget.onUpdateTask;
    if (cb == null) return;

    final result = await showDialog<({String title, String description})>(
      context: context,
      builder: (ctx) => _GoalTaskEditDialog(task: task),
    );
    if (result == null) return;

    await _guard(
      () =>
          cb(task.taskId, title: result.title, description: result.description),
    );
  }

  Future<void> _resetForExpand() async {
    final cb = widget.onResetForExpand;
    if (cb == null) return;
    // 会删行，且是「重新生成」语义，先确认。
    final yes = await _confirm(
      title: '重新展开任务',
      message:
          '将删除自动生成且未人工编辑的任务，再由 agent 重新展开。'
          '人工新增或编辑过的任务会保留。此操作不可撤销。',
      confirmLabel: '重新展开',
    );
    if (!yes) return;
    await _guard(cb);
  }

  /// 统一处理「写操作 + 失败提示」，返回是否成功。
  Future<bool> _guard(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object catch (e) {
      _message('操作失败：$e');
      return false;
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            key: const ValueKey('goal-tasks-confirm-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('goal-tasks-confirm-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  void _message(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = widget.snapshot.goal;

    // 无 goal：不能建任务（服务端任务挂在 goal 下），只给提示。
    if (goal == null) {
      return Center(
        key: const ValueKey('goal-tasks-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.flag_outlined,
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

    final tasks = widget.snapshot.tasks;

    return ListView(
      key: const ValueKey('goal-tasks-list'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
      children: [
        if (widget.showHeader) _header(theme, goal),
        if (tasks.isEmpty && widget.onCreate == null)
          Padding(
            padding: const EdgeInsets.all(SpbSpacing.md),
            child: Text(
              widget.noTasksHint,
              key: const ValueKey('goal-tasks-no-tasks'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (var i = 0; i < tasks.length; i++)
          _taskTile(theme, tasks[i], i, tasks.length),
        if (widget.onCreate != null) _addRow(theme),
        if (widget.onResetForExpand != null) _resetRow(theme),
        if (widget.decisions.isNotEmpty) _decisionsSection(theme),
        const SizedBox(height: SpbSpacing.sm),
      ],
    );
  }

  Widget _header(ThemeData theme, Goal goal) {
    final progress = widget.snapshot.progress;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.md,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  goal.goalText,
                  key: const ValueKey('goal-tasks-goal-text'),
                  style: theme.textTheme.titleSmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onReload != null)
                IconButton(
                  key: const ValueKey('goal-tasks-reload'),
                  icon: const Icon(Icons.refresh, size: SpbSpacing.lg),
                  tooltip: '刷新任务',
                  visualDensity: VisualDensity.compact,
                  onPressed: _locked ? null : () => _guard(widget.onReload!),
                ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: SpbSpacing.xs),
            Text(
              // 口径：completed 已含 skipped（服务端 CountChatGoalTasks）。
              '已完成 ${progress.completed}/${progress.total}'
              '（${progress.percent}%）',
              key: const ValueKey('goal-tasks-progress-text'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: SpbSpacing.xs),
            // `semanticsLabel` 给出「这是什么进度」——进度条自身无可读文本。
            // 上面的「已完成 3/5（60%）」是**另一个**文本节点，屏幕阅读器
            // 不会自动把它和进度条关联起来（两个并列节点）。
            LinearProgressIndicator(
              key: const ValueKey('goal-tasks-progress-bar'),
              value: progress.ratio,
              minHeight: SpbSpacing.xs,
              semanticsLabel: '目标任务完成进度',
            ),
            if (progress.needsAttention) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                // 阻塞/出错不会自己好，需要人介入——显式说出来，否则用户会
                // 一直等一个永远不会推进的清单。
                '有 ${progress.blocked + progress.errorStopped} 个任务需要人工处理'
                '（阻塞 ${progress.blocked} · 出错 ${progress.errorStopped}）',
                key: const ValueKey('goal-tasks-attention'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _taskTile(ThemeData theme, GoalTask task, int index, int total) {
    final scheme = theme.colorScheme;
    final done = task.isCompleted;

    return ListTile(
      key: ValueKey('goal-task-${task.taskId}'),
      dense: true,
      // 勾选框只在装配了状态回调时出现（见类文档「未注入回调 = 只读」）。
      leading: widget.onSetStatus == null
          ? null
          : Checkbox(
              key: ValueKey('goal-task-check-${task.taskId}'),
              value: done,
              onChanged: _locked ? null : (_) => _toggle(task),
            ),
      title: Text(
        task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: done
            ? theme.textTheme.bodyMedium?.copyWith(
                decoration: TextDecoration.lineThrough,
                color: scheme.onSurfaceVariant,
              )
            : theme.textTheme.bodyMedium,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.xxs),
        child: Wrap(
          spacing: SpbSpacing.xs,
          runSpacing: SpbSpacing.xxs,
          children: [
            // task_id 是路径里要用的标识，显示出来便于与 API 日志对上。
            _chip(theme, task.taskId),
            _chip(theme, task.status.label, tone: _statusTone(scheme, task)),
            // 来源决定重新展开时能否被覆盖，值得显示。
            _chip(theme, task.origin.label),
            if (task.editedByUser) _chip(theme, '已编辑'),
            if (task.isScheduledAfter(DateTime.now()))
              _chip(theme, '定时 ${_shortTime(task.notBefore!)}'),
            if (task.errorReason != null)
              _chip(theme, task.errorReason!, tone: scheme.error),
          ],
        ),
      ),
      trailing: _rowActions(task, index, total),
    );
  }

  Widget? _rowActions(GoalTask task, int index, int total) {
    final canMove = widget.onReorder != null;
    final canDelete = widget.onDelete != null;
    final canEdit = widget.onUpdateTask != null;
    if (!canMove && !canDelete && !canEdit && widget.onSetStatus == null) {
      return null;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 编辑：与删除/重排同排（都是行级动作）。未注入时整个不渲染。
        if (canEdit)
          IconButton(
            key: ValueKey('goal-task-edit-${task.taskId}'),
            icon: const Icon(Icons.edit_outlined, size: SpbSpacing.lg),
            tooltip: '编辑',
            visualDensity: VisualDensity.compact,
            onPressed: _locked ? null : () => _edit(task),
          ),
        // 状态菜单：复选框只有两态，其余四种状态在这里（见类文档）。
        if (widget.onSetStatus != null)
          PopupMenuButton<GoalTaskStatus>(
            key: ValueKey('goal-task-status-menu-${task.taskId}'),
            tooltip: '设置状态',
            enabled: !_locked,
            icon: const Icon(Icons.more_horiz, size: SpbSpacing.lg),
            onSelected: (s) =>
                _guard(() => widget.onSetStatus!(task.taskId, s)),
            itemBuilder: (ctx) => [
              for (final s in GoalTaskStatus.values)
                if (s != GoalTaskStatus.unknown)
                  PopupMenuItem(
                    key: ValueKey('goal-task-status-${task.taskId}-${s.wire}'),
                    value: s,
                    enabled: s != task.status,
                    child: Text(s == task.status ? '${s.label}（当前）' : s.label),
                  ),
            ],
          ),
        if (canMove) ...[
          IconButton(
            key: ValueKey('goal-task-up-${task.taskId}'),
            icon: const Icon(Icons.arrow_upward, size: SpbSpacing.lg),
            tooltip: '上移',
            visualDensity: VisualDensity.compact,
            // 首位不能再上移：置灰而不是隐藏（位置稳定，列表不会跳动）。
            onPressed: _locked || index == 0 ? null : () => _move(task, -1),
          ),
          IconButton(
            key: ValueKey('goal-task-down-${task.taskId}'),
            icon: const Icon(Icons.arrow_downward, size: SpbSpacing.lg),
            tooltip: '下移',
            visualDensity: VisualDensity.compact,
            onPressed: _locked || index == total - 1
                ? null
                : () => _move(task, 1),
          ),
        ],
        if (canDelete)
          IconButton(
            key: ValueKey('goal-task-delete-${task.taskId}'),
            icon: const Icon(Icons.delete_outline, size: SpbSpacing.lg),
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: _locked ? null : () => _delete(task),
          ),
      ],
    );
  }

  Widget _addRow(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(
      SpbSpacing.md,
      SpbSpacing.sm,
      SpbSpacing.md,
      SpbSpacing.xs,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('goal-task-add-field'),
            controller: _title,
            enabled: !_locked,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '新增任务标题',
              border: OutlineInputBorder(borderRadius: SpbRadius.inputAll),
            ),
            textInputAction: TextInputAction.done,
            // 回车即提交：这是单行输入，用户预期回车生效。
            onSubmitted: (_) => _create(),
          ),
        ),
        const SizedBox(width: SpbSpacing.xs),
        IconButton(
          key: const ValueKey('goal-task-add-button'),
          icon: const Icon(Icons.add),
          tooltip: '新增任务',
          onPressed: _locked ? null : _create,
        ),
      ],
    ),
  );

  Widget _resetRow(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('goal-tasks-reset'),
        icon: const Icon(Icons.auto_awesome, size: SpbSpacing.lg),
        label: const Text('重新展开任务'),
        // 破坏性操作，用 onSurfaceVariant 而非主色，视觉上不鼓励误点。
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
        ),
        onPressed: _locked ? null : _resetForExpand,
      ),
    ),
  );

  /// 复用 [GroupGatePanel] 渲染 gate 决策（**只读**）。
  ///
  /// 折叠起来：任务是主线，gate 决策是排障时才看的信息。没有改
  /// [GroupGatePanel] 本身——它仍是只读的，写操作全在本面板。
  Widget _decisionsSection(ThemeData theme) => Theme(
    // ExpansionTile 默认会画上下分隔线，这里嵌在列表里会显得脏。
    data: theme.copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      key: const ValueKey('goal-tasks-decisions'),
      tilePadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
      title: Text(
        '执行决策（${widget.decisions.length}）',
        style: theme.textTheme.labelLarge,
      ),
      children: [
        SizedBox(
          // 面板内部是 ListView，嵌在 ExpansionTile 里必须给定高度，
          // 否则无界高度约束会抛异常。
          height: 260,
          child: GroupGatePanel(
            decisions: widget.decisions,
            emptyHint: '还没有执行决策',
            showHeader: false,
          ),
        ),
      ],
    ),
  );

  /// 状态徽标配色：完成=主色，需人工介入=错误色，进行中=次色，其余中性。
  Color _statusTone(ColorScheme scheme, GoalTask task) {
    if (task.isCompleted) return scheme.primary;
    if (task.hasError) return scheme.error;
    if (task.isBlocked) return scheme.tertiary;
    if (task.status == GoalTaskStatus.inProgress) return scheme.secondary;
    return scheme.onSurfaceVariant;
  }

  Widget _chip(ThemeData theme, String text, {Color? tone}) {
    final color = tone ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xs,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: SpbRadius.cardAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  static String _shortTime(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.month}/${t.day} ${p2(t.hour)}:${p2(t.minute)}';
  }
}

/// 任务编辑对话框：只含标题与描述两个字段。
///
/// ## 为什么是独立的 StatefulWidget 而不是在调用点内联
///
/// 内联需要两个 `TextEditingController`，而它们在 `showDialog` 的 builder 里
/// 无法可靠释放（builder 可能被多次调用，`dispose` 却只在对话框真正关闭时发生）
/// ——泄漏的 controller 会一直挂在 `TextEditingController` 的静态监听链上。
/// 独立 State 的生命周期由 Flutter 管理，`dispose` 时机确定。
///
/// ## 为什么确定按钮在标题为空时禁用
///
/// 服务端 `updateTask` 的 `title` 走的是「传了就整体替换」，空标题会落库成
/// 空串——任务在列表里变成一个没有文字的条目。而服务端**不校验**它（与
/// `createTask` 的「title 与 description 都空则 400」不同）。故拦在客户端。
///
/// 描述允许为空（= 清除）。
class _GoalTaskEditDialog extends StatefulWidget {
  const _GoalTaskEditDialog({required this.task});

  final GoalTask task;

  @override
  State<_GoalTaskEditDialog> createState() => _GoalTaskEditDialogState();
}

class _GoalTaskEditDialogState extends State<_GoalTaskEditDialog> {
  late final TextEditingController _title;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    // 描述与标题相同时预填为空：服务端 `createTask` 在 title 缺省时回退用
    // description，故列表里的 `description` 常常只是 title 的副本（webapp 也
    // 专门过滤了这种情况，见 `task.description !== task.title`）。把它预填进
    // 描述框会让用户以为「描述本来就有一份内容」，从而不敢清空。
    final d = widget.task.description;
    _title = TextEditingController(text: widget.task.title);
    _description = TextEditingController(text: d == widget.task.title ? '' : d);
    // 标题变化时刷新确定按钮的启用态。
    _title.addListener(_onTitleChanged);
  }

  @override
  void dispose() {
    _title
      ..removeListener(_onTitleChanged)
      ..dispose();
    _description.dispose();
    super.dispose();
  }

  void _onTitleChanged() => setState(() {});

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.of(context).pop((
      title: title,
      // 不 trim 描述？——trim 掉首尾空白（用户从别处粘贴常带缩进），但保留
      // 内部换行。空串在这里有明确含义（清除），故必须原样传下去。
      description: _description.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _title.text.trim().isNotEmpty;

    return AlertDialog(
      key: const ValueKey('goal-task-edit-dialog'),
      title: Text('编辑任务 ${widget.task.taskId}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('goal-task-edit-title'),
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '标题',
              isDense: true,
              border: OutlineInputBorder(borderRadius: SpbRadius.inputAll),
            ),
          ),
          const SizedBox(height: SpbSpacing.sm),
          TextField(
            key: const ValueKey('goal-task-edit-description'),
            controller: _description,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '描述（留空即清除）',
              isDense: true,
              border: OutlineInputBorder(borderRadius: SpbRadius.inputAll),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('goal-task-edit-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('goal-task-edit-save'),
          onPressed: canSave ? _save : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
