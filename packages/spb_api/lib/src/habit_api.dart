import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 习惯（habit）领域 API 客户端。
///
/// 端点全部来自 Go API 真实路由（见 `apps/go-api/internal/server/`）：
/// - `ext_routes.go` → `/api/habits*`（读：list / get / runs）
/// - `habits_full.go` → `/api/habits*`（写：create / patch / trigger / pause / resume / archive）
/// - `misc_extra.go` → `/api/chat/habit-suggestions*`
/// - `habit_insights.go` → `/api/chat/habit-insights/summary`
///
/// ⚠️ 本类只做「调用 + 反序列化」，**不含业务决策**。特别是：
/// - 不自动重试（`pause`/`trigger` 是有副作用的写操作）；
/// - 不替调用方算 `snooze_until`（在 [HabitSnoozeOption.untilIso]）；
/// - 不吞 409（服务端用 409 表达「状态不符」，调用方需要区分它与 500）。
///
/// ## 为什么单独一个类而不是塞进 [ChatApi]
///
/// 虽然 `/api/chat/habit-suggestions` 名字里有 `chat`，但习惯的读路径主体是
/// `/api/habits`（`ChatApi` 的注释明确把自己限定在 `/chat/*` 与
/// `/users/:uid/chat/*`）。混在一起会让「习惯功能整体关闭」时无法从依赖注入
/// 层面摘掉它。
class HabitApi {
  HabitApi(this._dio);

  final Dio _dio;

  // ==================== 规则（patterns）====================

  /// `GET /api/habits?limit=&offset=`
  ///
  /// 服务端 `parseLimit(c.Query("limit"), 50, 200)`：默认 50、上限 200。
  /// 返回 `{items: [...]}`，每项是 sqlc `HabitPattern` 的 **camelCase** 形状
  /// （见 [UserHabit.fromJson] 的双形态说明）。
  Future<List<UserHabit>> listHabits({int limit = 50, int offset = 0}) async {
    final res = await _get(
      '/api/habits',
      query: {'limit': limit, 'offset': offset},
    );
    return unwrapItems(res, UserHabit.fromJson);
  }

  /// `GET /api/habits/:pattern_id`
  Future<UserHabit> getHabit(String patternId) async {
    final res = await _get('/api/habits/$patternId');
    return UserHabit.fromJson(_asMap(res));
  }

  /// `POST /api/habits`
  ///
  /// 服务端只接受 `topic_key` + `acceptance_level`（值域 `auto_run` /
  /// `confirm_required` / `suggest_only`）+ 可选 `trigger_config`。
  ///
  /// ## `trigger_config` 必须传**对象**，不是字符串
  ///
  /// `habits_full.go` 用 `json.RawMessage` 接它，并显式校验
  /// `trigger_config 必须是 JSON 对象`（传数组/标量会 400）。服务端随后跑
  /// `NormalizeTriggerConfig` 归一（复数 `weekdays` → 单数 `weekday`、
  /// 顶层 `hour`/`minute` 镜像 `times[0]`）。
  ///
  /// 返回 201 + `{pattern_id, group_id, topic_id, next_fire_at, ...}`。
  Future<HabitCreateResult> createHabit({
    required String topicKey,
    HabitAcceptanceLevel? acceptanceLevel,
    HabitTriggerConfig? triggerConfig,
    String? preferredAgentId,
    String? deliveryGroupId,
    String? promptContract,
  }) async {
    final res = await _post(
      '/api/habits',
      body: {
        'topic_key': topicKey,
        if (acceptanceLevel != null) 'acceptance_level': acceptanceLevel.wire,
        if (triggerConfig != null) 'trigger_config': triggerConfig.toJson(),
        if (preferredAgentId != null) 'preferred_agent_id': preferredAgentId,
        if (deliveryGroupId != null) 'delivery_group_id': deliveryGroupId,
        if (promptContract != null) 'prompt_contract': promptContract,
      },
    );
    return HabitCreateResult.fromJson(_asMap(res));
  }

  /// `PATCH /api/habits/:pattern_id`
  ///
  /// 只发送显式传入的字段（PATCH 语义）。改 `trigger_config` 会让服务端按新
  /// 配置重算 `next_fire_at`（`TestHabitUpdateComputesNextFireAt`）。
  ///
  /// ## 五个字段与服务端 `update` 的对应关系
  ///
  /// | 参数 | 服务端行为 |
  /// |---|---|
  /// | [topicKey] | `TrimSpace` 后非空校验（空串 400 `topic_key 无效`） |
  /// | [acceptanceLevel] | 白名单校验（非法 400 `acceptance_level 无效`） |
  /// | [triggerConfig] | 归一化后重算 `next_fire_at` |
  /// | [preferredAgentId] | 非空 = 设置；空串 = **清除**（见下） |
  /// | [status] | 服务端 `update` **不接受**它（状态只能走 pause/resume/archive） |
  ///
  /// ## [preferredAgentId] 的三态陷阱
  ///
  /// 服务端用 `json.RawMessage` 区分「未传」（`nil`，保留原值）、「清除」
  /// （字面量 `null`）与「设置」（`"x"`）——因为 `*string` 下 `null` 与「未传」
  /// 都是 `nil`，清除会被静默忽略。而服务端随后走 `toNullString(TrimSpace(v))`，
  /// 即**空串与 `null` 等价**（都是清除）。
  ///
  /// ⚠️ 本方法对空串的处理是**原样发送空串**（服务端会当成清除），
  /// 而 `null` 才是「不动」。调用方若只想改别的字段，务必传 `null`。
  ///
  /// ⚠️ 服务端**不校验状态**：对 archived 的 pattern 也能 PATCH 成功，
  /// 只是它不会再被调度。UI 应自己按 [UserHabit.status] 决定是否允许编辑。
  Future<void> patchHabit(
    String patternId, {
    String? topicKey,
    HabitAcceptanceLevel? acceptanceLevel,
    HabitTriggerConfig? triggerConfig,
    String? preferredAgentId,
    String? deliveryGroupId,
    String? status,
  }) async {
    await _patch(
      '/api/habits/$patternId',
      body: {
        if (topicKey != null) 'topic_key': topicKey,
        if (acceptanceLevel != null) 'acceptance_level': acceptanceLevel.wire,
        if (triggerConfig != null) 'trigger_config': triggerConfig.toJson(),
        if (preferredAgentId != null) 'preferred_agent_id': preferredAgentId,
        if (deliveryGroupId != null) 'delivery_group_id': deliveryGroupId,
        if (status != null) 'status': status,
      },
    );
  }

  /// `POST /api/habits/:pattern_id/trigger`
  ///
  /// 手动立即执行一次。服务端要求 pattern 为 `active`，否则 **409**
  /// （`仅 active 状态可触发，当前: <status>`）。
  ///
  /// 返回 `{triggered: true, schedule_id, turn_id}`——`turn_id` 可用于跳转到
  /// 对话查看结果。
  Future<HabitTriggerResult> triggerHabit(String patternId) async {
    final res = await _post('/api/habits/$patternId/trigger');
    return HabitTriggerResult.fromJson(_asMap(res));
  }

  /// `POST /api/habits/:pattern_id/pause`
  ///
  /// 仅 `active` → `paused`，否则 409。
  Future<void> pauseHabit(String patternId) =>
      _post('/api/habits/$patternId/pause');

  /// `POST /api/habits/:pattern_id/resume`
  ///
  /// 仅 `paused` → `active`，否则 409。服务端返回新的 `next_fire_at`。
  Future<DateTime?> resumeHabit(String patternId) async {
    final res = await _post('/api/habits/$patternId/resume');
    return habitNullTime(_asMap(res), 'next_fire_at', 'next_fire_at');
  }

  /// `POST /api/habits/:pattern_id/archive`
  ///
  /// 归档是**终态**（无 unarchive 端点），UI 应加二次确认。
  Future<void> archiveHabit(String patternId) =>
      _post('/api/habits/$patternId/archive');

  // ==================== 执行记录（runs）====================

  /// `GET /api/habits/runs?days=&limit=&trigger_reason=`
  ///
  /// 跨 pattern 的全局执行历史（含候选建议类，`pattern_id` 可能为空）。
  /// 返回 `habitRunsWithReply` 形状（`run_id` / `topic_key` / `reply_text` /
  /// `is_manual`，见 [HabitRun.fromJson]）。
  ///
  /// ⚠️ 本方法**丢弃 `daily_budget`**（`unwrapItems` 只看 `items`）。需要预算
  /// 时用 [listAllRunsWithBudget]。
  Future<List<HabitRun>> listAllRuns({
    int? days,
    int limit = 50,
    String? triggerReason,
  }) async {
    final res = await _get(
      '/api/habits/runs',
      query: _runsQuery(days: days, limit: limit, triggerReason: triggerReason),
    );
    return unwrapItems(res, HabitRun.fromJson);
  }

  /// `GET /api/habits/runs?days=&limit=&trigger_reason=`，**保留 `daily_budget`**。
  ///
  /// 与 [listAllRuns] 打同一个端点、同一套查询参数，区别只在返回类型：
  /// `daily_budget` 是「今日已用 / 上限」，`unwrapItems` 会把它静默丢掉
  /// （见 [HabitDailyBudget] 的类文档）。
  ///
  /// ## 为什么不把 `unwrapItems` 改成通用地返回整包
  ///
  /// `unwrapItems` 是**全部**列表端点共用的工具（chat / agents / habits…），
  /// 绝大多数响应没有附加字段。为了一处需求改它的返回类型，会让所有调用方
  /// 被迫处理一个永远为空的附加字段——那是把局部需求扩散成全局复杂度。
  Future<HabitRunsResult> listAllRunsWithBudget({
    int? days,
    int limit = 50,
    String? triggerReason,
  }) async {
    final res = await _get(
      '/api/habits/runs',
      query: _runsQuery(days: days, limit: limit, triggerReason: triggerReason),
    );
    return HabitRunsResult.fromJson(res);
  }

  /// 执行记录的查询参数（两个端点共用，避免两处漂移）。
  ///
  /// `trigger_reason` 为空串时不发：服务端 `if triggerReason != ""` 才过滤，
  /// 发空串等于「不过滤」但会多一个无意义参数。
  static Map<String, dynamic> _runsQuery({
    int? days,
    int limit = 50,
    String? triggerReason,
  }) => {
    if (days != null) 'days': days,
    'limit': limit,
    if (triggerReason != null && triggerReason.isNotEmpty)
      'trigger_reason': triggerReason,
  };

  /// `GET /api/habits/:pattern_id/runs?limit=&offset=`
  ///
  /// ⚠️ **单规则端点只支持 `limit` / `offset`**（`ext_routes.go` 的 `runs`），
  /// 没有 `days` / `trigger_reason`——那是全局端点 [listAllRuns] 的参数。
  /// 服务端 SQL 是 `ListHabitRuns`（按 `habit_pattern_id` 过滤、无时间窗），
  /// 多传的 query 参数会被**静默忽略**（不报错），故不要在调用方造「按天筛选
  /// 单规则历史」的假象。
  Future<List<HabitRun>> listHabitRuns(
    String patternId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _get(
      '/api/habits/$patternId/runs',
      query: {'limit': limit, 'offset': offset},
    );
    return unwrapItems(res, HabitRun.fromJson);
  }

  // ==================== 候选建议（suggestions）====================

  /// `GET /api/chat/habit-suggestions?status=`
  ///
  /// [status] 只支持 `pending`（默认）与 `dismissed`——服务端 `list` 是
  /// **二分**分支：`status == "dismissed"` 查近 30 天已忽略项，其余一律走
  /// pending 查询。传 `resolved` 不会报错，但会得到 pending 结果（静默误导），
  /// 故这里把它约束成枚举。
  ///
  /// ⚠️ 返回项**不含** `rule_draft`（服务端 `habitRunToMap` 不解析
  /// `trigger_context_json`），故 topic_key 由客户端本地从
  /// `trigger_context_json` 还原（见 [HabitSuggestion.fromListItem]）。
  Future<List<HabitSuggestion>> listSuggestions({
    HabitSuggestionListFilter filter = HabitSuggestionListFilter.pending,
  }) async {
    final res = await _get(
      '/api/chat/habit-suggestions',
      query: {'status': filter.wire},
    );
    return unwrapItems(res, HabitSuggestion.fromListItem);
  }

  /// `POST /api/chat/habit-suggestions/:suggestion_id/resolve`
  ///
  /// ## 服务端语义（`misc_extra.go` 的 `resolve`）
  ///
  /// | action | 写入 `user_feedback` | 副作用 |
  /// |---|---|---|
  /// | `accept` / `edit_and_accept` | `accept_rule` | **建出 active pattern** |
  /// | `dismiss` | `dismiss` | 写 `cooldown_until = now + HABIT_DISMISS_COOLDOWN_SECONDS` |
  /// | `snooze` | `snoozed` | 写 `snooze_until`（缺省回退同一冷却时长） |
  ///
  /// 用 CAS 更新（`ResolveHabitRunFeedback`），已处理过的建议返回 **409**
  /// （`建议已被处理或状态不符`）——不是 500，调用方应把它当「已被别处处理」，
  /// 刷新列表即可。
  ///
  /// [snoozeUntil] 仅在 `action == snooze` 时有意义，且必须是 UTC RFC3339；
  /// 服务端解析失败会静默回退冷却时长（不报错），故客户端必须传对
  /// （用 [HabitSnoozeOption.untilIso]）。
  ///
  /// ## [patternPatch]：就地编辑的内容（仅 `edit_and_accept` 消费）
  ///
  /// 服务端 `misc_extra.go` 的 `PatternPatch json.RawMessage` 注释写明
  /// 「仅 edit_and_accept 消费」，解析与校验集中在 `applyPatternPatch`。
  /// 故本方法**只在 action == editAndAccept 时下发它**——其余 action 带上
  /// 只会让服务端白跑一次 `applyPatternPatch`，且可能被将来的校验逻辑当成
  /// 异常输入。
  ///
  /// ### 合并语义：出现即覆盖，未出现即保留
  ///
  /// patch 里**出现**的键覆盖候选值，未出现的保留候选值。故 patch 是**增量**
  /// 而非整包替换——只传 `{'topic_key': 'x'}` 不会把触发时间清空。
  ///
  /// ### 键集由服务端白名单决定，客户端不得自行扩大
  ///
  /// 真源是 `workers/habit/timeline_events.go` 的 `SuggestionEditableFields`：
  /// `topic_key` / `trigger_config` / `preferred_agent_id` / `delivery_group_id`，
  /// 随事件 payload 的 `editable_fields` 下发。
  /// `applyPatternPatch` 接受的键（含嵌套 `trigger_config` 内的 `times`）就是
  /// 这份白名单的实现，多带一个未来新增的键只会被忽略——但**不要**据此就把
  /// 客户端字段集写成「什么都能传」（见 `HabitSuggestionItem.editableFields`）。
  ///
  /// ### 两种形状都认
  ///
  /// 扁平 `{'hour': 9, 'weekday': 1}` 与嵌套
  /// `{'trigger_config': {'times': [...], 'weekday': [...]}}` 等价
  /// （见 `applyPatternPatch` 的「为什么两种形状都要认」）。本仓库统一发**嵌套**
  /// 形态（与 `HabitTriggerConfig.toJson` 同形），因为它能原样承载候选值。
  ///
  /// ### patch 不是对象时服务端**忽略而非报错**
  ///
  /// `applyPatternPatch` 对 `len == 0` / `"null"` / 反序列化失败 / `nil` 一律
  /// 返回候选原值，**不返回错误**。即：传了格式错的 patch 会「接受成功但配置
  /// 没变」——静默失效。故调用方不要依赖服务端报错来发现自己的 bug。
  ///
  /// 同理 `agent_id` / `preferred_agent_id` 传 `null` 表示**清除**指定 agent
  /// （不是「不传」），而空数组的 `weekday` 会被当成「无该键」保留候选值
  /// （服务端不让用户把 weekday 清空，那会让引擎算不出下次触发）。
  Future<HabitSuggestionResolveResult> resolveSuggestion(
    String suggestionId, {
    required HabitSuggestionAction action,
    String? comment,
    DateTime? snoozeUntil,
    Map<String, dynamic>? patternPatch,
  }) async {
    final res = await _post(
      '/api/chat/habit-suggestions/$suggestionId/resolve',
      body: {
        'action': action.wire,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        if (snoozeUntil != null) 'snooze_until': _isoUtc(snoozeUntil),
        // 只在 edit_and_accept 时下发：服务端明确只在该 action 消费它。
        if (action == HabitSuggestionAction.editAndAccept &&
            patternPatch != null)
          'pattern_patch': patternPatch,
      },
    );
    return HabitSuggestionResolveResult.fromJson(_asMap(res));
  }

  /// `POST /api/chat/habit-suggestions/:suggestion_id/unresolve`
  ///
  /// 撤销处理（把 run 退回 pending）。服务端同样用 CAS。
  Future<void> unresolveSuggestion(String suggestionId) =>
      _post('/api/chat/habit-suggestions/$suggestionId/unresolve');

  // ==================== 洞察（insights）====================

  /// `GET /api/chat/habit-insights/summary?days=`
  ///
  /// ⚠️ `recalibration` 部分在 Go 版**恒为 0**（无 `habit_pattern_recalibrated`
  /// 产出点），UI 不应把它当「从未重校准」的证据。见 [HabitInsightsSummary]。
  Future<HabitInsightsSummary> habitInsights({int days = 30}) async {
    final res = await _get(
      '/api/chat/habit-insights/summary',
      query: {'days': days},
    );
    return HabitInsightsSummary.fromJson(_asMap(res));
  }

  // ==================== 传输 ====================

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

  /// 取响应体并**显式检查状态码**。
  ///
  /// `createDio` 的 `validateStatus` 放行 4xx（见 `http_client.dart`），
  /// 故 409/404 不会抛 `DioException`。不在这里补判，`pauseHabit` 这类
  /// `Future<void>` 方法会把「状态不符的 409」当成功——用户点「暂停」后
  /// UI 显示已暂停，而服务端从未改状态。
  Object? _unwrap(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      final body = res.data;
      throw HttpError(
        code,
        _errorMessage(body) ?? 'HTTP $code',
        body: body is String ? body : null,
      );
    }
    return res.data;
  }

  String? _errorMessage(Object? data) {
    if (data is Map) {
      final err = data['error'];
      if (err is String && err.isNotEmpty) return err;
    }
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
  }

  SpbError _toSpbError(DioException e) {
    final inner = e.error;
    if (inner is SpbError) return inner;
    return mapDioError(e);
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }

  static String _isoUtc(DateTime t) {
    final u = t.toUtc();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
        'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
  }
}

/// `GET /api/chat/habit-suggestions?status=` 的取值。
///
/// 只有两个真实分支（服务端 `list` 是二分判断），故用枚举而非裸字符串，
/// 避免调用方传 `resolved` 却静默拿到 pending 结果。
enum HabitSuggestionListFilter {
  pending('pending'),
  dismissed('dismissed');

  const HabitSuggestionListFilter(this.wire);

  final String wire;
}

/// `POST /api/habits/:pattern_id/trigger` 的响应。
class HabitTriggerResult {
  const HabitTriggerResult({
    this.triggered = false,
    this.scheduleId = '',
    this.turnId = '',
    this.raw = const {},
  });

  final bool triggered;

  /// 排程 id（服务端 `schedule_id`）。
  final String scheduleId;

  /// 服务端把 `turn_id` 与 `schedule_id` 写成同一个值（`habits_full.go` 的
  /// `gin.H{"triggered": true, "schedule_id": scheduleID, "turn_id": scheduleID}`）。
  /// 保留两个字段只为如实镜像响应，不暗示它们独立。
  final String turnId;

  final Map<String, dynamic> raw;

  static HabitTriggerResult fromJson(Map<String, dynamic> json) {
    return HabitTriggerResult(
      triggered: habitBool(json, 'triggered', 'triggered') ?? false,
      scheduleId: habitStr(json, 'schedule_id', 'schedule_id') ?? '',
      turnId: habitStr(json, 'turn_id', 'turn_id') ?? '',
      raw: Map.unmodifiable(json),
    );
  }
}

/// `POST /api/chat/habit-suggestions/:id/resolve` 的响应。
///
/// 服务端返回 `{resolved: true, suggestion: {...}, pattern_id: ""}`。
///
/// ⚠️ 键名是 **`pattern_id`**，而 `habit_suggestion_resolved` **事件** payload
/// 里叫 `resolved_pattern_id`——两处不同名，别把事件解析器套到这里。
class HabitSuggestionResolveResult {
  const HabitSuggestionResolveResult({
    this.resolved = false,
    this.suggestion,
    this.patternId = '',
    this.raw = const {},
  });

  final bool resolved;

  /// 更新后的建议（`habitRunToMap` 形状）。
  final HabitSuggestion? suggestion;

  /// accept / edit_and_accept 建出的 pattern id；其余 action 为空串。
  final String patternId;

  final Map<String, dynamic> raw;

  static HabitSuggestionResolveResult fromJson(Map<String, dynamic> json) {
    final sugg = json['suggestion'];
    return HabitSuggestionResolveResult(
      resolved: habitBool(json, 'resolved', 'resolved') ?? false,
      suggestion: sugg is Map
          ? HabitSuggestion.fromListItem(Map<String, dynamic>.from(sugg))
          : null,
      patternId: habitStr(json, 'pattern_id', 'pattern_id') ?? '',
      raw: Map.unmodifiable(json),
    );
  }
}
