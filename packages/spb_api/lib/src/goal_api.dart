import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 结构化目标 / 任务（goal / task）领域 API 客户端。
///
/// 端点全部来自 Go API 真实路由 `internal/server/goal_api.go` 的
/// `registerGoalRoutes`（挂载见 `chat_ext.go:111`，前缀是 **`/chat`**）。
///
/// | 方法 | 路径 |
/// |---|---|
/// | POST | `/chat/groups/:group_id/goals` |
/// | GET | `/chat/groups/:group_id/goals` |
/// | GET | `/chat/groups/:group_id/goals/current` |
/// | PUT | `/chat/groups/:group_id/goals/current` |
/// | PATCH | `/chat/goals/:goal_id` |
/// | GET | `/chat/goals/:goal_id/tasks` |
/// | POST | `/chat/goals/:goal_id/tasks` |
/// | PATCH | `/chat/goals/:goal_id/tasks/:task_id` |
/// | DELETE | `/chat/goals/:goal_id/tasks/:task_id` |
/// | PUT | `/chat/goals/:goal_id/tasks/:task_id/status` |
/// | POST | `/chat/goals/:goal_id/tasks/reorder` |
/// | POST | `/chat/goals/:goal_id/tasks/reset-for-expand` |
///
/// ## ⚠️ 前缀是 `/chat` 不是 `/api`
///
/// 同目录下习惯（habit）走 `/api/habits*`，很容易顺手把 goal 也写成
/// `/api/chat/goals`。那个路径**不存在**，表现为 404（而不是解析错误），
/// 排查时容易被当成鉴权问题。
///
/// ## ⚠️ 路径里的两个 id 来自不同列
///
/// - `:goal_id` → `chat_goals.id`（行 id）
/// - `:task_id` → `chat_goal_tasks.task_id`（`TASK-NNN` 人类可读标识）
///
/// 故本类的方法参数名分别是 `goalId`（行 id）与 `taskId`（`TASK-NNN`），
/// 并且**不接受** `GoalTask.id`。传错会 404 而非报错。
///
/// ## ⚠️ 静态段与参数段同层：`reorder` / `reset-for-expand` vs `:task_id`
///
/// `POST /chat/goals/:goal_id/tasks/reorder` 与
/// `PUT /chat/goals/:goal_id/tasks/:task_id/status` 在 gin 的 radix tree 里
/// 是不同方法，故不冲突；但 `POST .../tasks/reorder` 与
/// `POST .../tasks/reset-for-expand` 与「`POST .../tasks`」同层存在静态段，
/// 客户端路径必须**逐字**对齐服务端注册顺序，任何拼写漂移都会落到
/// 「`reorder` 被当成 task_id」的分支上（表现为 404 task 不存在）。
///
/// ## 为什么单独一个类
///
/// [ChatApi] 的注释把自己限定在 `/chat/*` 与 `/users/:uid/chat/*`，goal 确实
/// 在 `/chat/*` 下——但本类承载**12 个端点 + 5 个 DTO**，塞进 [ChatApi]
/// （已 1000+ 行）会让「目标管理」这个可独立关闭的子系统无法从依赖注入层面
/// 摘掉。同 [HabitApi] 的取舍。
///
/// ## 写操作不重试
///
/// 所有写方法（create/update/delete/status/reorder/reset）都**不做自动重试**：
/// 它们有副作用且非幂等（`reorder` 是整份顺序覆盖、`reset-for-expand` 会删行）。
/// 网络失败时让调用方决定是否重发。
class GoalApi {
  GoalApi(this._dio);

  final Dio _dio;

  // ==================== goal ====================

  /// `POST /chat/groups/:group_id/goals` —— 新建目标。
  ///
  /// ## 语义：新建 = 归档旧 active goal
  ///
  /// 服务端会归档同 group 的其它 active goal（保留历史行），再把 group 的
  /// `current_goal_id` 指针切到新行，并重置 goal gate 运行态。
  ///
  /// [goalText] 服务端会 trim 并拒绝空串（400）。[tasksSource] 缺省时服务端取
  /// `manual`；显式传的值必须在 `llm_expand` / `manual` / `imported` 之内，
  /// 否则 400「tasks_source 非法」。
  ///
  /// 返回 201 + `{goal: {...}}`（**包了一层 `goal` 键**，不是裸对象）。
  Future<Goal> createGoal(
    String groupId, {
    required String goalText,
    GoalTasksSource? tasksSource,
    String? sourceMarkdown,
  }) async {
    final res = await _post(
      '/chat/groups/$groupId/goals',
      body: {
        'goal_text': goalText,
        if (tasksSource != null && tasksSource.wire.isNotEmpty)
          'tasks_source': tasksSource.wire,
        if (sourceMarkdown != null) 'source_markdown': sourceMarkdown,
      },
    );
    return Goal.fromJson(_sub(res, 'goal'));
  }

  /// `GET /chat/groups/:group_id/goals` —— 该 group 的历史目标列表。
  ///
  /// 服务端 `parseLimit(c.Query("limit"), 50, 200)`：默认 50、上限 200。
  /// 返回 `{items: [...]}`。
  Future<List<Goal>> listGoals(String groupId, {int limit = 50}) async {
    final res = await _get(
      '/chat/groups/$groupId/goals',
      query: {'limit': limit},
    );
    return unwrapItems(res, Goal.fromJson);
  }

  /// `GET /chat/groups/:group_id/goals/current` —— 当前目标 + 任务 + 进度。
  ///
  /// ## 无 goal 是**正常**结果（200），不是错误
  ///
  /// 服务端回 `{"goal": null, "tasks": [], "progress": null}`。故返回
  /// [GoalSnapshot]（[GoalSnapshot.goal] 可空）而不是 `Goal?`——任务列表与进度
  /// 也在同一个响应里，丢掉了就得再发一次请求。
  ///
  /// ⚠️ 本端点走 `goalToDTO`，**不带** `current_task_id`（只有 group DTO 的
  /// `current_goal` 快照才补该字段，见 `group_goal_snapshot.go`）。
  Future<GoalSnapshot> getCurrentGoal(String groupId) async {
    final res = await _get('/chat/groups/$groupId/goals/current');
    return GoalSnapshot.fromJson(_asMap(res));
  }

  /// `PUT /chat/groups/:group_id/goals/current` —— 切回某个历史目标。
  ///
  /// 只改指针（`chat_groups.current_goal_id`），**不改目标内容**，并重置 goal
  /// gate 运行态。服务端校验目标必须属于同一个 group，否则 400
  /// 「goal 不属于该 group」（防越权把别人的 goal 挂到自己 group 上）。
  ///
  /// 返回 200 + `{goal: {...}}`。
  Future<Goal> switchGoal(String groupId, String goalId) async {
    final res = await _put(
      '/chat/groups/$groupId/goals/current',
      body: {'goal_id': goalId},
    );
    return Goal.fromJson(_sub(res, 'goal'));
  }

  /// `PATCH /chat/goals/:goal_id` —— 改目标状态。
  ///
  /// [status] 必须在 [GoalStatus] 的白名单内（`active` / `completed` /
  /// `paused` / `archived`），否则 400「status 非法」。
  ///
  /// ⚠️ [GoalStatus.unknown] 的 `wire` 是空串，服务端会判 400。故显式拦在
  /// 客户端（比等一个 400 更早暴露调用方 bug）。
  Future<Goal> updateGoalStatus(String goalId, GoalStatus status) async {
    if (status.wire.isEmpty) {
      throw ArgumentError.value(
        status,
        'status',
        '不能写入未知状态（服务端 validGoalStatus 会 400）',
      );
    }
    final res = await _patch(
      '/chat/goals/$goalId',
      body: {'status': status.wire},
    );
    return Goal.fromJson(_sub(res, 'goal'));
  }

  // ==================== task ====================

  /// `GET /chat/goals/:goal_id/tasks` —— 任务列表 + 进度。
  ///
  /// 返回 `{items: [...], progress: {...}}`。两段都要，故不返回裸 List
  /// （`unwrapItems` 会把 `progress` 静默丢掉，同 `HabitApi` 的 `daily_budget`）。
  Future<({List<GoalTask> items, GoalProgress? progress})> listTasks(
    String goalId,
  ) async {
    final res = await _get('/chat/goals/$goalId/tasks');
    return (
      items: unwrapItems(res, GoalTask.fromJson),
      progress: _progress(res),
    );
  }

  /// `POST /chat/goals/:goal_id/tasks` —— 新增任务。
  ///
  /// ## 服务端的缺省与派生规则（都会影响返回的 `task_id`）
  ///
  /// - [taskId] 缺省 → 服务端按现有任务最大编号生成 `TASK-NNN`（`nextTaskID`）。
  ///   自定义命名（如 `s1`）不参与编号计算。
  /// - [title] 缺省 → 回退用 [description]；两者都空则 400。
  /// - [origin] 缺省 → 服务端取 `llm`。⚠️ **页面手工新增必须显式传
  ///   [GoalTaskOrigin.manual]**：`origin != "llm"` 时服务端才会把
  ///   `tasks_source` 置为 `manual`，否则人工新增的任务会在下次 LLM 展开时
  ///   被当作可覆盖项删掉。
  /// - [status] 缺省 → `pending`。
  /// - [orderIndex] 缺省 → 追加到末尾（`len(existing)`）。
  /// - [taskId] 显式传入且已存在 → 409（服务端先查重，不把 UNIQUE 冲突当 500）。
  ///
  /// [notBefore] 是全量覆盖语义（不是增量）：传空串即清除。格式见
  /// [formatNotBefore]。
  ///
  /// 返回 201 + `{task: {...}}`。
  Future<GoalTask> createTask(
    String goalId, {
    String? taskId,
    String? title,
    String? description,
    String? phase,
    GoalTaskStatus? status,
    GoalTaskOrigin? origin,
    int? orderIndex,
    String? notBefore,
    String? blockedBy,
    GoalCompletionSemantics? completionSemantics,
  }) async {
    if (status != null && status.wire.isEmpty) {
      throw ArgumentError.value(status, 'status', '不能写入未知状态');
    }
    if (origin != null && origin.wire.isEmpty) {
      throw ArgumentError.value(origin, 'origin', '不能写入未知来源');
    }
    if (completionSemantics != null && completionSemantics.wire.isEmpty) {
      throw ArgumentError.value(
        completionSemantics,
        'completionSemantics',
        '不能写入未知完成语义',
      );
    }
    final res = await _post(
      '/chat/goals/$goalId/tasks',
      body: {
        if (taskId != null && taskId.isNotEmpty) 'task_id': taskId,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (phase != null) 'phase': phase,
        if (status != null) 'status': status.wire,
        if (origin != null) 'origin': origin.wire,
        if (orderIndex != null) 'order_index': orderIndex,
        if (notBefore != null) 'not_before': notBefore,
        if (blockedBy != null) 'blocked_by': blockedBy,
        if (completionSemantics != null)
          'completion_semantics': completionSemantics.wire,
      },
    );
    return GoalTask.fromJson(_sub(res, 'task'));
  }

  /// `PATCH /chat/goals/:goal_id/tasks/:task_id` —— 编辑任务内容。
  ///
  /// [taskId] 是 `TASK-NNN` 标识，**不是** [GoalTask.id]。
  ///
  /// ## 三个字段是「全量覆盖」，与 title 的「缺省=不改」不同
  ///
  /// 服务端对 [notBefore] / [blockedBy] / [completionSemantics] 的语义是
  /// **传了就整体替换**，空串 = 清除（`null` = 立即可开始 / 无依赖 / 一次性）。
  /// 这三个参数为 `null` 表示「不改」，传 `''` 表示「清除」——调用方要区分。
  ///
  /// 内容编辑会让服务端置 `edited_by_user=1`，该任务此后在 LLM 重新展开时
  /// 会被保留（见 [GoalTaskOrigin.removable]）。
  ///
  /// 返回 200 + `{task: {...}}`。
  Future<GoalTask> updateTask(
    String goalId,
    String taskId, {
    String? title,
    String? description,
    String? phase,
    int? orderIndex,
    String? notBefore,
    String? blockedBy,
    String? completionSemantics,
  }) async {
    final res = await _patch(
      '/chat/goals/$goalId/tasks/$taskId',
      body: {
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (phase != null) 'phase': phase,
        if (orderIndex != null) 'order_index': orderIndex,
        if (notBefore != null) 'not_before': notBefore,
        if (blockedBy != null) 'blocked_by': blockedBy,
        if (completionSemantics != null)
          'completion_semantics': completionSemantics,
      },
    );
    return GoalTask.fromJson(_sub(res, 'task'));
  }

  /// `DELETE /chat/goals/:goal_id/tasks/:task_id` —— 删除任务。
  ///
  /// 服务端用影响行数判存在性，删了 0 行回 404「task 不存在」。
  ///
  /// 返回值用不上，但状态码**必须**检查：`createDio` 的 `validateStatus`
  /// 放行 4xx（见 `http_client.dart`），不补判会把「删除失败」当成功。
  Future<void> deleteTask(String goalId, String taskId) async {
    await _delete('/chat/goals/$goalId/tasks/$taskId');
  }

  /// `PUT /chat/goals/:goal_id/tasks/:task_id/status` —— 改任务状态。
  ///
  /// ## 这是推进任务的主要入口
  ///
  /// 服务端用**无状态守卫**的 `SetChatGoalTaskStatus`：显式调用方（人或 agent
  /// 的明确指令）允许把任务从任意状态迁移到任意状态。守卫只用于防 LLM
  /// 「顺手误改」。
  ///
  /// ## 服务端会自动算时间戳与错误原因
  ///
  /// - 置 `in_progress` 且此前没有 `started_at` → 记开始时间；
  /// - 置 `completed` / `skipped` → 记完成时间；
  /// - [errorReason] **只在** `error_stopped` / `blocked` 时落库，其余状态
  ///   服务端会清空（避免任务恢复后仍挂着过期说明）。故切到「已完成」时
  ///   传 `errorReason` 是无效的。
  ///
  /// 返回 200 + `{task: {...}, progress: {...}}`——**带更新后的进度**，
  /// 调用方无需再拉一次列表。
  Future<({GoalTask task, GoalProgress? progress})> setTaskStatus(
    String goalId,
    String taskId,
    GoalTaskStatus status, {
    String? errorReason,
  }) async {
    if (status.wire.isEmpty) {
      throw ArgumentError.value(status, 'status', '不能写入未知状态');
    }
    final res = await _put(
      '/chat/goals/$goalId/tasks/$taskId/status',
      body: {
        'status': status.wire,
        if (errorReason != null) 'error_reason': errorReason,
      },
    );
    return (
      task: GoalTask.fromJson(_sub(res, 'task')),
      progress: _progress(res),
    );
  }

  /// `POST /chat/goals/:goal_id/tasks/reorder` —— 按数组顺序重排。
  ///
  /// [taskIds] 是 `TASK-NNN` 标识列表，服务端按下标写 `order_index` 并把
  /// 涉及的任务全部标记 `edited_by_user`。
  ///
  /// ## ⚠️ 这是**整份顺序覆盖**，不是增量移动
  ///
  /// 服务端只遍历数组里的 id（`for i, tid := range body.TaskIDs`），**不校验
  /// 完整性**。漏传的 id 保持旧 `order_index` 不动——于是「把 A 移到最前」
  /// 这种增量写法会让 A 与漏传的 B 撞上同一个 index，顺序变得不确定。
  /// 故本方法要求传**完整清单**，并在客户端先拦一道空列表
  /// （服务端 `binding:"required"` 对空数组是通过的，会变成一个无害但
  /// 无意义的请求）。
  ///
  /// 返回 200 + `{items: [...]}`（重排后的完整列表）。
  Future<List<GoalTask>> reorderTasks(
    String goalId,
    List<String> taskIds,
  ) async {
    if (taskIds.isEmpty) {
      throw ArgumentError.value(taskIds, 'taskIds', '重排必须传完整任务清单（空列表会发出无意义请求）');
    }
    final res = await _post(
      '/chat/goals/$goalId/tasks/reorder',
      body: {'task_ids': taskIds},
    );
    return unwrapItems(res, GoalTask.fromJson);
  }

  /// `POST /chat/goals/:goal_id/tasks/reset-for-expand` —— 为 LLM 重新展开清场。
  ///
  /// 删除「可被覆盖」的任务（`origin='llm'` 且 `edited_by_user=0`），保留人工
  /// 任务与已编辑任务，并把 `tasks_source` 置为 `llm_expand`。返回被删除与
  /// 被保留的 id，供调用方了解合并结果。
  ///
  /// ## 破坏性：会删行，且**不可撤销**
  ///
  /// 调用方（UI）必须先给用户确认，或明确说明这是「重新生成任务清单」。
  Future<GoalResetForExpandResult> resetForExpand(String goalId) async {
    final res = await _post('/chat/goals/$goalId/tasks/reset-for-expand');
    return GoalResetForExpandResult.fromJson(_asMap(res));
  }

  // ==================== 传输 ====================

  /// 把 `not_before` 的 [DateTime] 转成服务端接受的字符串（UTC RFC3339）。
  ///
  /// 服务端 `parseNotBefore` 接受两种格式：RFC3339 与 `2006-01-02 15:04:05`
  /// （无时区按 UTC 解释）。本方法统一发前者，避免时区歧义。
  ///
  /// 传 `''` 表示清除时间锚点（服务端把空串转 NULL）。
  static String formatNotBefore(DateTime t) {
    final u = t.toUtc();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
        'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
  }

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _post(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.post<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _patch(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.patch<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `PUT` 请求。
  ///
  /// `switchGoal` 与 `setTaskStatus` 在服务端注册的都是 PUT（不是 PATCH），
  /// 用 PATCH 会 404。
  Future<Object?> _put(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.put<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<void> _delete(String path) async {
    try {
      final res = await _dio.delete<dynamic>(path);
      // 返回值用不上，但状态码必须检查：4xx 不会抛 DioException
      // （见 http_client.dart 的 validateStatus），不检查会让删除失败静默成功。
      _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// 取响应体并**显式检查状态码**。
  ///
  /// `createDio` 的 `validateStatus` 放行 <500 的状态码，故 400/404/409 不会
  /// 抛 `DioException`。不补判会把 `409 task_id 已存在` 当成创建成功——UI
  /// 显示新增成功而服务端从未落库。
  Object? _unwrap(Response<dynamic> res) {
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(
        status,
        _errorMessage(res.data) ?? 'HTTP $status',
        body: _bodyPreview(res.data),
      );
    }
    return res.data;
  }

  /// 取服务端 `{"error": "..."}` 里的原因（有则用作错误消息）。
  static String? _errorMessage(Object? data) {
    if (data is Map) {
      final err = data['error'];
      if (err is String && err.isNotEmpty) return err;
    }
    return null;
  }

  /// 响应体预览（截断，避免把整页 HTML 塞进错误对象与日志）。
  static String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
  }

  SpbError _toSpbError(DioException e) {
    final inner = e.error;
    if (inner is SpbError) return inner;
    return mapDioError(e);
  }

  /// 取响应里嵌套的一层 map（`{"goal": {...}}` → `{...}`）。
  static Map<String, dynamic> _sub(Object? v, String key) {
    final m = _asMap(v);
    final sub = m[key];
    return sub is Map ? Map<String, dynamic>.from(sub) : const {};
  }

  /// 取响应里的 `progress`（缺失/形状不对时为 null）。
  static GoalProgress? _progress(Object? v) {
    final p = _asMap(v)['progress'];
    return p is Map
        ? GoalProgress.fromJson(Map<String, dynamic>.from(p))
        : null;
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }
}
