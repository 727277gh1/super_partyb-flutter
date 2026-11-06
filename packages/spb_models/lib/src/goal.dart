/// 结构化目标（goal）与任务（task）契约 —— 迁移 0022 的 `chat_goals` /
/// `chat_goal_tasks` 两张表。
///
/// ## 端点来源（逐条核实，非推测）
///
/// 全部来自 `super_partyb/apps/go-api/internal/server/goal_api.go` 的
/// `registerGoalRoutes`（挂载点见 `chat_ext.go:111`，前缀是 **`/chat`**
/// 而不是 `/api`）：
///
/// | 方法 | 路径 | 处理器 |
/// |---|---|---|
/// | POST | `/chat/groups/:group_id/goals` | `createGoal` |
/// | GET | `/chat/groups/:group_id/goals` | `listGoals` |
/// | GET | `/chat/groups/:group_id/goals/current` | `getCurrentGoal` |
/// | PUT | `/chat/groups/:group_id/goals/current` | `switchGoal` |
/// | PATCH | `/chat/goals/:goal_id` | `updateGoalStatus` |
/// | GET | `/chat/goals/:goal_id/tasks` | `listTasks` |
/// | POST | `/chat/goals/:goal_id/tasks` | `createTask` |
/// | PATCH | `/chat/goals/:goal_id/tasks/:task_id` | `updateTask` |
/// | DELETE | `/chat/goals/:goal_id/tasks/:task_id` | `deleteTask` |
/// | PUT | `/chat/goals/:goal_id/tasks/:task_id/status` | `setTaskStatus` |
/// | POST | `/chat/goals/:goal_id/tasks/reorder` | `reorderTasks` |
/// | POST | `/chat/goals/:goal_id/tasks/reset-for-expand` | `resetForExpand` |
///
/// ## 两个 id 不是同一个东西（最易踩的坑）
///
/// - `:goal_id` 是 `chat_goals.id`（`chat.NewID()` 产出的行 id）；
/// - `:task_id` 是 `chat_goal_tasks.task_id`，即 **`TASK-NNN` 形式的人类可读
///   标识**，不是 `chat_goal_tasks.id`。
///
/// `goal_api.go` 的 `setTaskStatus` / `updateTask` 都按
/// `GetChatGoalTaskByTaskIDParams{GoalID: goal.ID, TaskID: c.Param("task_id")}`
/// 查询，故路径里的两个 id 来自**不同列**。把行 id 当 `task_id` 传会 404。
/// 故 [GoalTask] 同时保留 [GoalTask.id]（行 id）与 [GoalTask.taskId]（`TASK-NNN`）。
///
/// ## 命名：全 snake_case
///
/// 服务端用 `goalToDTO` / `taskToDTO` 手写 `gin.H`，键名 snake_case
/// （`goal_text` / `tasks_source` / `order_index` / `edited_by_user` …），
/// 与 `ChatGroup` 同一约定，与 `ChatEvent` 的 camelCase 不同。
/// 客户端做映射，**不试图统一**。
///
/// ## `progress` 的口径
///
/// `completed` 与 `skipped` **合并计入完成**（`chat_goals.sql` 的
/// `CountChatGoalTasks`：`COUNT(CASE WHEN status IN ('completed','skipped') ...)`），
/// `blocked` / `error_stopped` 不计。`pending` 是派生值
/// （`total - completed - inProgress - blocked - errorStopped`），服务端也算，
/// 这里同样算一遍以容忍缺字段。
library;

/// 目标状态（`chat_goals.status`）。
///
/// 白名单见 Go `validGoalStatus`：`active` / `completed` / `paused` / `archived`。
enum GoalStatus {
  active('active', '进行中'),
  completed('completed', '已完成'),
  paused('paused', '已暂停'),
  archived('archived', '已归档'),

  /// 认不出的服务端值（向前兼容，不抛）。
  unknown('', '未知');

  const GoalStatus(this.wire, this.label);

  /// 服务端取值（写请求用）。
  final String wire;

  /// 中文标签（列表徽标展示）。
  final String label;

  static GoalStatus fromServer(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 任务列表来源（`chat_goals.tasks_source`）。
///
/// 白名单见 Go `validTasksSource`。它不是「谁创建了这条任务」——那个是
/// [GoalTaskOrigin]。它描述**整份任务清单**是谁生成的，决定重新展开时能否覆盖。
enum GoalTasksSource {
  /// LLM 展开产出（`reset-for-expand` 置此值）。
  llmExpand('llm_expand', '自动展开'),

  /// 人工创建/编辑过。
  manual('manual', '手动'),

  /// 从实施计划导入。
  imported('imported', '导入'),

  unknown('', '未知');

  const GoalTasksSource(this.wire, this.label);

  final String wire;
  final String label;

  static GoalTasksSource fromServer(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 任务状态（`chat_goal_tasks.status`）。
///
/// 白名单见 Go `validTaskStatus`（也是 `PUT .../status` 的入参校验）。
///
/// ⚠️ 与轮次状态（[ChatTurnSummary.status]）**不是同一套值域**：那边是
/// `queued`/`running`/`cancelled`，这边是 `pending`/`in_progress`/`blocked`。
/// 两处都有「已完成」，但拼写与集合都不同，混用会静默筛选出空结果。
enum GoalTaskStatus {
  pending('pending', '待开始'),
  inProgress('in_progress', '进行中'),
  completed('completed', '已完成'),

  /// 主动跳过（`progress` 里与 `completed` 合并计入完成）。
  skipped('skipped', '已跳过'),

  /// 出错停止（不计入完成，需人工介入）。
  errorStopped('error_stopped', '错误停止'),

  /// 被依赖阻塞（不计入完成）。
  blocked('blocked', '阻塞'),

  unknown('', '未知');

  const GoalTaskStatus(this.wire, this.label);

  final String wire;
  final String label;

  static GoalTaskStatus fromServer(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }

  /// 是否计入 [GoalProgress.completed]（`completed` + `skipped`，服务端口径）。
  bool get countsAsCompleted =>
      this == GoalTaskStatus.completed || this == GoalTaskStatus.skipped;

  /// 是否仍需推进（未完成且未跳过）。
  bool get isOpen => !countsAsCompleted;
}

/// 任务来源（`chat_goal_tasks.origin`）。
///
/// 白名单见 Go `validTaskOrigin`。配合 [GoalTask.editedByUser] 决定重新展开时
/// 能否被覆盖：**可覆盖 = `llm` 且未被人工编辑**，其余一律保留。
enum GoalTaskOrigin {
  llm('llm', '自动'),
  manual('manual', '手动'),
  imported('imported', '导入'),

  unknown('', '未知');

  const GoalTaskOrigin(this.wire, this.label);

  final String wire;
  final String label;

  static GoalTaskOrigin fromServer(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }

  /// 是否可在重新展开时被删除（服务端 `resetForExpand` 的 removable 判定）。
  bool removable({required bool editedByUser}) =>
      this == GoalTaskOrigin.llm && !editedByUser;
}

/// 完成语义（`chat_goal_tasks.completion_semantics`）。
///
/// 白名单见 Go `validCompletionSemantics`：`one_shot` / `ongoing`。
/// `ongoing`（维持型）不会被一次完成销账，如「保持 CI 绿」。
enum GoalCompletionSemantics {
  oneShot('one_shot', '一次性'),
  ongoing('ongoing', '维持型'),

  unknown('', '未知');

  const GoalCompletionSemantics(this.wire, this.label);

  final String wire;
  final String label;

  static GoalCompletionSemantics fromServer(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 一个结构化目标（`goalToDTO`）。
class Goal {
  const Goal({
    required this.id,
    required this.groupId,
    required this.goalText,
    required this.status,
    required this.tasksSource,
    required this.createdAt,
    required this.updatedAt,
    this.currentTaskId,
    this.sourceMarkdown,
    this.gitCommit,
    this.gitCommitAt,
    this.expandedAt,
    this.completedAt,
    this.archivedAt,
  });

  /// 行 id（`chat_goals.id`）。路径里的 `:goal_id` 用的是**它**。
  final String id;

  final String groupId;

  /// 目标文本。服务端 `createGoal` 会 trim 并拒绝空串。
  final String goalText;

  final GoalStatus status;

  final GoalTasksSource tasksSource;

  /// 当前任务 id（`TASK-NNN`）。
  ///
  /// ⚠️ **只有 group DTO 的 `current_goal` 快照会下发它**
  /// （`group_goal_snapshot.go` 的 `goalSnapshotDTO` 补的），
  /// `GET /goals/current` 走的 `goalToDTO` **不带**该字段。故本字段在
  /// [GoalApi.getCurrentGoal] 的返回里通常为 null。事件路径由
  /// `GoalUpdate.snapshot` 按同一规则补上。
  final String? currentTaskId;

  /// 原始 markdown（若目标是从计划文本解析来的）。
  final String? sourceMarkdown;

  /// 创建时的 group 工作区 git HEAD（工作区未初始化时缺省）。
  final String? gitCommit;
  final DateTime? gitCommitAt;

  /// 最近一次 LLM 展开时间。
  final DateTime? expandedAt;
  final DateTime? completedAt;
  final DateTime? archivedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 是否仍可被 goal gate 接管（只有 `active` 才推进）。
  bool get isActive => status == GoalStatus.active;

  factory Goal.fromJson(Map<String, dynamic> json) => Goal(
    id: (json['id'] as String?) ?? '',
    groupId: (json['group_id'] as String?) ?? '',
    goalText: (json['goal_text'] as String?) ?? '',
    status: GoalStatus.fromServer(json['status'] as String?),
    tasksSource: GoalTasksSource.fromServer(json['tasks_source'] as String?),
    currentTaskId: _nonEmpty(json['current_task_id']),
    sourceMarkdown: _nonEmpty(json['source_markdown']),
    gitCommit: _nonEmpty(json['git_commit']),
    gitCommitAt: _date(json['git_commit_at']),
    expandedAt: _date(json['expanded_at']),
    completedAt: _date(json['completed_at']),
    archivedAt: _date(json['archived_at']),
    createdAt: _date(json['created_at']) ?? DateTime.now(),
    updatedAt: _date(json['updated_at']) ?? DateTime.now(),
  );

  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    return v.isEmpty ? null : v;
  }

  static DateTime? _date(Object? v) =>
      DateTime.tryParse((v as String?) ?? '')?.toLocal();
}

/// 一条任务（`taskToDTO`）。
class GoalTask {
  const GoalTask({
    required this.id,
    required this.goalId,
    required this.taskId,
    required this.orderIndex,
    required this.title,
    required this.description,
    required this.status,
    required this.origin,
    required this.createdAt,
    required this.updatedAt,
    this.editedByUser = false,
    this.phase,
    this.blockedBy,
    this.notBefore,
    this.completionSemantics,
    this.acceptanceJson,
    this.startedAt,
    this.completedAt,
    this.errorReason,
  });

  /// 行 id（`chat_goal_tasks.id`）。**不是**路径里的 `:task_id`。
  final String id;

  /// 所属 goal 的行 id。
  final String goalId;

  /// `TASK-NNN` 形式的稳定标识。**路径里的 `:task_id` 用的是它**。
  ///
  /// 页面重排/改名都不会变（`order_index` 才是可变的顺序）。
  final String taskId;

  final int orderIndex;
  final String title;
  final String description;

  final GoalTaskStatus status;
  final GoalTaskOrigin origin;

  /// 是否被人工编辑过（`edited_by_user != 0`）。
  ///
  /// 置 1 后该任务在 LLM 重新展开时**会被保留**（见
  /// [GoalTaskOrigin.removable]）。服务端在 `updateTask` 里自动置位。
  final bool editedByUser;

  final String? phase;

  /// 依赖的任务 id（`TASK-NNN`）。服务端**不校验引用是否存在**（判定侧
  /// fail-open），故可能指向已删除的任务。
  final String? blockedBy;

  /// 时间锚点：早于此时间不启动。null = 立即可开始。
  final DateTime? notBefore;

  /// 完成语义；null = 一次性（服务端 `NULL`）。
  final GoalCompletionSemantics? completionSemantics;

  /// 验收标准（JSON 字符串，原样透传）。
  final String? acceptanceJson;

  final DateTime? startedAt;
  final DateTime? completedAt;

  /// 出错/阻塞原因。服务端只在 `error_stopped` / `blocked` 时保留它，
  /// 其余状态会清空（避免恢复后仍挂着过期说明）。
  final String? errorReason;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isCompleted => status.countsAsCompleted;
  bool get isBlocked => status == GoalTaskStatus.blocked;
  bool get hasError => status == GoalTaskStatus.errorStopped;

  /// 是否被时间锚点推迟（`notBefore` 在未来）。
  bool isScheduledAfter(DateTime now) {
    final at = notBefore;
    return at != null && at.isAfter(now);
  }

  factory GoalTask.fromJson(Map<String, dynamic> json) => GoalTask(
    id: (json['id'] as String?) ?? '',
    goalId: (json['goal_id'] as String?) ?? '',
    taskId: (json['task_id'] as String?) ?? '',
    orderIndex: _int(json['order_index']),
    title: (json['title'] as String?) ?? '',
    description: (json['description'] as String?) ?? '',
    status: GoalTaskStatus.fromServer(json['status'] as String?),
    origin: GoalTaskOrigin.fromServer(json['origin'] as String?),
    editedByUser: json['edited_by_user'] == true,
    phase: _nonEmpty(json['phase']),
    blockedBy: _nonEmpty(json['blocked_by']),
    notBefore: _date(json['not_before']),
    completionSemantics: json['completion_semantics'] == null
        ? null
        : GoalCompletionSemantics.fromServer(
            json['completion_semantics'] as String?,
          ),
    acceptanceJson: _nonEmpty(json['acceptance_json']),
    startedAt: _date(json['started_at']),
    completedAt: _date(json['completed_at']),
    errorReason: _nonEmpty(json['error_reason']),
    createdAt: _date(json['created_at']) ?? DateTime.now(),
    updatedAt: _date(json['updated_at']) ?? DateTime.now(),
  );

  static String? _nonEmpty(Object? v) {
    if (v is! String) return null;
    return v.isEmpty ? null : v;
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _date(Object? v) =>
      DateTime.tryParse((v as String?) ?? '')?.toLocal();
}

/// 任务进度汇总（`progressDTO` / `progressFromTasks`，两条路径同口径）。
class GoalProgress {
  const GoalProgress({
    required this.total,
    required this.completed,
    required this.inProgress,
    required this.blocked,
    required this.errorStopped,
    required this.pending,
    required this.percent,
  });

  final int total;

  /// `completed` + `skipped`（服务端把 skipped 并入完成）。
  final int completed;
  final int inProgress;
  final int blocked;
  final int errorStopped;

  /// 尚未开始（派生值）。
  final int pending;

  /// 完成百分比（0–100，服务端 `int` 截断）。
  final int percent;

  static const GoalProgress empty = GoalProgress(
    total: 0,
    completed: 0,
    inProgress: 0,
    blocked: 0,
    errorStopped: 0,
    pending: 0,
    percent: 0,
  );

  bool get isEmpty => total == 0;

  /// 完成比例（0.0–1.0），用于进度条。`total == 0` 时为 0。
  double get ratio => total == 0 ? 0 : completed / total;

  /// 是否存在需要人工介入的任务（阻塞或出错停止）。
  bool get needsAttention => blocked > 0 || errorStopped > 0;

  factory GoalProgress.fromJson(Map<String, dynamic> json) {
    final total = _int(json['total']);
    final completed = _int(json['completed']);
    final inProgress = _int(json['in_progress']);
    final blocked = _int(json['blocked']);
    final errorStopped = _int(json['error_stopped']);
    // pending 服务端会算，但缺字段时自行派生（口径与 CountChatGoalTasks 一致）。
    final pending = json['pending'] == null
        ? total - completed - inProgress - blocked - errorStopped
        : _int(json['pending']);
    return GoalProgress(
      total: total,
      completed: completed,
      inProgress: inProgress,
      blocked: blocked,
      errorStopped: errorStopped,
      pending: pending,
      percent: _int(json['percent']),
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// `GET /chat/groups/:group_id/goals/current` 的完整响应。
///
/// 与 group DTO 里的 `current_goal`、以及 `goal_updated` 事件载荷**逐字同构**
/// （服务端刻意用同一套 DTO 函数生成，见 `emitGoalUpdated` 的注释），
/// 故三种来源可以共用 [fromJson]。
///
/// ## 无 goal 是正常状态，不是错误
///
/// 服务端在没有 current goal 时回 `{"goal": null, "tasks": [], "progress": null}`
/// 且状态码 200。故 [goal] 可空，调用方**不得**用 `goal != null` 判定请求成功。
class GoalSnapshot {
  const GoalSnapshot({this.goal, this.tasks = const [], this.progress});

  /// 当前目标；无 goal 时为 null。
  final Goal? goal;

  /// 任务列表（无 goal 时为空）。
  final List<GoalTask> tasks;

  /// 进度汇总；无 goal 时为 null。
  final GoalProgress? progress;

  static const GoalSnapshot empty = GoalSnapshot();

  bool get hasGoal => goal != null;

  /// 任务清单是否为空（有 goal 但还没展开任务时也是 true）。
  bool get hasNoTasks => tasks.isEmpty;

  factory GoalSnapshot.fromJson(Map<String, dynamic> json) {
    final rawGoal = json['goal'];
    final rawTasks = json['tasks'];
    final rawProgress = json['progress'];
    return GoalSnapshot(
      goal: rawGoal is Map
          ? Goal.fromJson(Map<String, dynamic>.from(rawGoal))
          : null,
      tasks: rawTasks is List
          ? [
              for (final e in rawTasks)
                if (e is Map) GoalTask.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      progress: rawProgress is Map
          ? GoalProgress.fromJson(Map<String, dynamic>.from(rawProgress))
          : null,
    );
  }
}

/// `POST /chat/goals/:goal_id/tasks/reset-for-expand` 的响应。
///
/// 为 LLM 重新展开做准备：删除「可被覆盖」的任务（`origin='llm'` 且未被人工
/// 编辑），保留人工任务与已编辑任务。两份清单都是 `TASK-NNN` 形式的 id。
class GoalResetForExpandResult {
  const GoalResetForExpandResult({
    this.removed = const [],
    this.preserved = const [],
    this.note,
  });

  /// 被删除的任务 id。
  final List<String> removed;

  /// 被保留的任务 id（人工编辑过的任务不可被 LLM 覆盖）。
  final List<String> preserved;

  /// 服务端附带的说明文案。
  final String? note;

  factory GoalResetForExpandResult.fromJson(Map<String, dynamic> json) =>
      GoalResetForExpandResult(
        removed: _strList(json['removed']),
        preserved: _strList(json['preserved']),
        note: json['note'] as String?,
      );

  static List<String> _strList(Object? v) => v is List
      ? [
          for (final e in v)
            if (e is String) e,
        ]
      : const [];
}
