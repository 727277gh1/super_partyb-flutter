import 'package:spb_models/spb_models.dart';

/// 一条目标变更通知（由 `goal_updated` 归一化而来）。
///
/// ## 为什么是「带快照的通知」而不是纯信号
///
/// 真源是 `chat_goals` / `chat_goal_tasks` 两张表，事件只告诉前端「你手上的目标
/// 快照过期了」。与 `group_updated` 不同，本事件的 payload **携带完整快照**
/// （`{op, goal, tasks, progress}`），且由与 `GET /goals/current` **完全相同**的
/// DTO 函数生成（Go `goalToDTO` / `taskToDTO` / `progressFromTasks`）。
///
/// 服务端这么做是刻意的防漂移设计（`goal_api.go` 的 `emitGoalUpdated` 文件头
/// 注释：「同一个函数生成的结构不可能对不上」）——直接针对 `group_title_updated`
/// 那类「发射端写 `title`、前端读 `new_title`，生产 63 条事件全部白发」的故障。
///
/// 故 [snapshot] 可以直接套进 [ChatGroup.currentGoal]，无需再发一次 HTTP。
///
/// ## 事件没有 turn
///
/// goal/task 的写操作可能由页面按钮、pigo（经 `X-API-Key` 走 `/open` 面）或
/// Goal Gate 触发。除最后一种外都没有 turn，而 `chat_events.turn_id` 是
/// NOT NULL——这正是服务端走纯广播（`broker.Publish`）而不落库的原因。
///
/// ## ⚠️ 服务端漏设 `Transient`（本类的核心风险）
///
/// `emitGoalUpdated` 的注释写着「不落库，仅广播」，但 `chatbus.Event` 的
/// `Transient` 字段留了零值 **false**——对比 `PublishGroupUpdated`
/// （`chat/group_events.go:63`）与 `buildTitleUpdatedEvent`
/// （`chatgate/title_gate.go:258`）都显式设了 `true`。
///
/// 于是它在线上表现为 `transient=false` + **有效 eventId**，而它**确实不在**
/// `chat_events` 表里。后果见 [ChatStreamController.goalUpdates]：控制器必须按
/// 「事件类型」而非「Transient 标志」把它挡在游标推进之外，否则
/// `replayUserEvents` 会因 cursor 未命中而返回 nil，**整个断线回放窗口丢失**。
///
/// 客户端无法修正服务端这个标志位（约束：Go API 一行不改），只能在消费侧
/// 显式分流。
///
/// ## 为什么逐条推送而不累积
///
/// 与 [GroupUpdate] 同：它是**通知语义**，每次变更各是一次独立事件
/// （`task_create` 后 `task_reorder` 与反过来结果不同）。
class GoalUpdate {
  const GoalUpdate({
    required this.op,
    required this.groupId,
    required this.source,
    this.goal,
    this.tasks = const [],
    this.progress,
    this.taskId,
    this.at,
  });

  /// 变更操作（`op`）。
  ///
  /// 值域（`goal_api.go` 的 `emitGoalUpdated` 调用点）：`goal_create` /
  /// `goal_switch` / `goal_status` / `task_create` / `task_update` /
  /// `task_delete` / `task_status` / `task_reorder` / `task_reset_expand`。
  ///
  /// 保持 String 而非 enum：消费方只需知道「快照变了」，服务端新增 op 时
  /// 不该静默走 default 分支丢掉刷新。
  final String op;

  /// 变更的 group id（broker 的 fan-out 路由键，必填）。
  final String groupId;

  /// 变更发起方：`user`（页面按钮 / 登录态接口）或 `agent`（pigo 经
  /// `X-API-Key` 调 `/open` 面）。
  ///
  /// UI 可据此提示「Agent 更新了任务」（服务端注释原话）。
  final String source;

  /// goal 快照（形状同 `goalToDTO`）。
  ///
  /// 异常载荷下可能缺失（服务端在任务列表读失败时仍会发不带 tasks 的信号，
  /// 但 goal 本身始终在）。
  final Map<String, dynamic>? goal;

  /// 任务列表快照（每项形状同 `taskToDTO`）。
  final List<Map<String, dynamic>> tasks;

  /// 进度快照（形状同 `progressFromTasks`）：
  /// `{total, completed, in_progress, blocked, error_stopped, pending}`。
  final Map<String, dynamic>? progress;

  /// 本次操作涉及的任务 id；非任务级操作时为 null。
  final String? taskId;

  /// 事件到达时间。
  final DateTime? at;

  /// 是否由 agent（pigo）发起。
  bool get fromAgent => source == 'agent';

  /// 目标文本（`goal.goal_text`）；无快照时 null。
  String? get goalText {
    final text = goal?['goal_text'];
    return text is String && text.isNotEmpty ? text : null;
  }

  /// 目标状态（`goal.status`）：`active` / `completed` / `archived` 等。
  String? get goalStatus {
    final status = goal?['status'];
    return status is String && status.isNotEmpty ? status : null;
  }

  /// 组装成 [ChatGroup.currentGoal] 的形状（`{goal, tasks, progress}`）。
  ///
  /// 与 `GET /goals/current` 及 group DTO 里的 `current_goal` 逐字同构，
  /// 故可直接 `group.withCurrentGoal(update.snapshot)`。
  ///
  /// ## 为什么补 `current_task_id`
  ///
  /// 服务端的 `goalSnapshotDTO`（group DTO 路径）会补 `current_task_id`
  /// 指向「第一个 in_progress，否则第一个 pending」，但 `emitGoalUpdated`
  /// 走的是 `goalToDTO` 直出、**不带**该字段。若此处不补，同一份快照经事件
  /// 刷新与经 HTTP 重取会得到两个形状——任务清单 UI 的「当前任务」高亮会
  /// 在事件到达后消失。故按服务端同一规则补上（见 `goalSnapshotDTO` 注释：
  /// 留空会让乱序完成时指错任务）。
  ///
  /// goal 缺失时返回 null（**不**用空快照覆盖现有值）。
  Map<String, dynamic>? get snapshot {
    final g = goal;
    if (g == null) return null;
    final goalDto = Map<String, dynamic>.from(g);
    final currentTaskId = _currentTaskId();
    if (currentTaskId != null) goalDto['current_task_id'] = currentTaskId;
    return {
      'goal': goalDto,
      'tasks': tasks,
      if (progress != null) 'progress': progress,
    };
  }

  /// 第一个 `in_progress` 任务的 id，没有则退到第一个 `pending`。
  ///
  /// 与 Go `goalSnapshotDTO` 的 `currentTaskID` 选取规则一致。
  String? _currentTaskId() {
    for (final t in tasks) {
      if (t['status'] == 'in_progress') return t['task_id'] as String?;
    }
    for (final t in tasks) {
      if (t['status'] == 'pending') return t['task_id'] as String?;
    }
    return null;
  }

  /// 从事件构造；非 `goal_updated` 或缺少 groupId 时返回 null。
  ///
  /// `groupId` 为空的事件无法定位要刷新哪个对话，丢弃（服务端不变量是
  /// 「发布即有 group id」）。
  static GoalUpdate? fromEvent(ChatEvent ev) {
    if (ev.eventType != EventTypes.goalUpdated) return null;
    if (ev.groupId.isEmpty) return null;
    return GoalUpdate(
      op: ev.goalUpdateOp ?? '',
      groupId: ev.groupId,
      source: ev.source,
      goal: ev.goalUpdateGoal,
      tasks: ev.goalUpdateTasks,
      progress: ev.goalUpdateProgress,
      taskId: ev.goalUpdateTaskId,
      at: ev.createdAt,
    );
  }

  @override
  String toString() =>
      'GoalUpdate($op, group=$groupId, source=$source'
      '${goalText != null ? ', goal=$goalText' : ''}'
      '${tasks.isNotEmpty ? ', tasks=${tasks.length}' : ''})';
}
