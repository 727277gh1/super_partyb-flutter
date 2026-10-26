part of 'habit.dart';

/// 一次习惯执行的结果（`habit_runs.outcome`）。
///
/// 真源：`internal/domain/domain.go` 的 `HabitOutcome*` 常量（SQLite CHECK）。
enum HabitRunOutcome {
  pending('pending', '待处理'),
  suggested('suggested', '已建议'),
  scheduled('scheduled', '已排程'),
  failed('failed', '执行失败'),
  cancelled('cancelled', '已取消'),
  confirmationRequired('confirmation_required', '待确认'),
  completed('completed', '已完成'),
  skippedNoSuggestionService('skipped_no_suggestion_service', '跳过（无建议服务）'),
  skippedPendingExists('skipped_pending_exists', '跳过（已有待处理）'),
  unknown('', '未知');

  const HabitRunOutcome(this.wire, this.label);

  final String wire;
  final String label;

  bool get isTerminal =>
      this == completed || this == failed || this == cancelled;

  static HabitRunOutcome from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 触发原因（`habit_runs.trigger_reason`）。
enum HabitTriggerReason {
  /// 按规则到期触发。
  dueRule('due_rule', '定时触发'),

  /// 候选检测产出建议（无 pattern）。
  candidateDetected('candidate_detected', '候选建议'),

  /// 用户手动触发。
  manual('manual', '手动触发'),

  /// 盯梢检测到变化。
  watch('watch', '盯梢变化'),

  unknown('', '未知');

  const HabitTriggerReason(this.wire, this.label);

  final String wire;
  final String label;

  static HabitTriggerReason from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 用户对建议的反馈（`habit_runs.user_feedback`）。
enum HabitUserFeedback {
  accepted('accepted', '已接受'),
  dismissed('dismissed', '已忽略'),
  snoozed('snoozed', '已延后'),
  unknown('', '未知');

  const HabitUserFeedback(this.wire, this.label);

  final String wire;
  final String label;

  static HabitUserFeedback? from(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return null;
  }
}

/// 一次习惯执行记录。
///
/// ## 两类形状必须都吃
///
/// | 端点 | 生产者 | 主键键名 | 附加字段 |
/// |---|---|---|---|
/// | `/api/habits/runs`、`/api/habits/:id/runs` | `ext_routes.go` `habitRunsWithReply` | **`run_id`** | `topic_key` / `reply_text` / `delivery_group_title` / `is_manual` |
/// | `/api/chat/habit-suggestions` | `misc_extra.go` `habitRunToMap` | **`id`** | `habit_pattern_id` / `user_id` / `scheduled_turn_id` |
///
/// 两者都是 snake_case，但键名集合不同。本类把 `run_id`/`id` 都归一成 [id]，
/// 其余字段缺失即 null/空——调用方不需要知道记录来自哪个端点。
class HabitRun {
  const HabitRun({
    required this.id,
    this.habitPatternId,
    this.userId = '',
    this.originGroupId = '',
    this.deliveryGroupId,
    this.deliveryGroupTitle = '',
    this.topicKey = '',
    required this.triggerReason,
    this.triggerContextJson,
    this.outcome = HabitRunOutcome.unknown,
    this.userFeedback,
    this.feedbackPayloadJson,
    this.feedbackAt,
    this.scheduledTurnId,
    this.createdAt,
    this.executedAt,
    this.replyText = '',
    this.isManual = false,
    this.raw = const {},
  });

  /// run id（归一自 `run_id` 或 `id`）。
  final String id;

  /// 所属规则 id；**候选建议为 null**（`candidate_detected` 还没有 pattern）。
  final String? habitPatternId;

  final String userId;
  final String originGroupId;

  /// 实际投递到的对话（可能 null）。
  final String? deliveryGroupId;

  /// 投递对话标题（仅 runs 列表端点提供，需服务端查 group）。
  final String deliveryGroupTitle;

  /// 主题 key。
  ///
  /// 两条来源：`due_rule` 类取自 `habit_patterns.topic_key`；
  /// `candidate_detected` 类回退 `trigger_context_json.topic_key`
  /// （服务端 `topicKeyFromTriggerContextJSON`，还兼容 `{"candidate":{...}}` 旧形态）。
  final String topicKey;

  final HabitTriggerReason triggerReason;

  /// 触发上下文的原始 JSON 字符串（候选类里有 topic_key 等）。
  final String? triggerContextJson;

  final HabitRunOutcome outcome;

  /// 用户反馈（null = 未反馈）。
  final HabitUserFeedback? userFeedback;

  /// 反馈负载的原始 JSON 字符串（`{action, resolved_at, snooze_until?|cooldown_until?, comment?}`）。
  final String? feedbackPayloadJson;

  final DateTime? feedbackAt;

  /// 排程出的 turn id（可用来跳转到对话）。
  final String? scheduledTurnId;

  final DateTime? createdAt;
  final DateTime? executedAt;

  /// 执行产生的回复全文（拼接同 turn 全部 `message` 权威帧）。
  ///
  /// 仅 `/api/habits/runs` 系列提供——`/api/chat/habit-suggestions` 不返回它。
  final String replyText;

  /// 是否手动触发（`trigger_context_json.is_manual`）。
  final bool isManual;

  final Map<String, dynamic> raw;

  bool get isPendingSuggestion =>
      outcome == HabitRunOutcome.suggested && userFeedback == null;

  /// 是否有可跳转的 turn。
  bool get hasTurn => (scheduledTurnId ?? '').isNotEmpty;

  static HabitRun fromJson(Map<String, dynamic> json) {
    return HabitRun(
      id:
          habitStr(json, 'run_id', 'run_id') ??
          habitStr(json, 'id', 'id') ??
          '',
      habitPatternId:
          habitNullString2(json, 'habit_pattern_id', 'habit_pattern_id') ??
          habitNullString2(json, 'pattern_id', 'pattern_id'),
      userId: habitStr(json, 'user_id', 'user_id') ?? '',
      originGroupId: habitStr(json, 'origin_group_id', 'origin_group_id') ?? '',
      deliveryGroupId: habitNullString2(
        json,
        'delivery_group_id',
        'delivery_group_id',
      ),
      deliveryGroupTitle:
          habitStr(json, 'delivery_group_title', 'delivery_group_title') ?? '',
      topicKey: habitStr(json, 'topic_key', 'topic_key') ?? '',
      triggerReason: HabitTriggerReason.from(
        habitStr(json, 'trigger_reason', 'trigger_reason'),
      ),
      triggerContextJson: habitJsonString(json, 'trigger_context'),
      outcome: HabitRunOutcome.from(habitStr(json, 'outcome', 'outcome')),
      userFeedback: HabitUserFeedback.from(
        habitStr(json, 'user_feedback', 'user_feedback'),
      ),
      feedbackPayloadJson: habitJsonString(json, 'feedback_payload'),
      feedbackAt: habitDate(json, 'feedback_at', 'feedback_at'),
      scheduledTurnId:
          habitNullString2(json, 'scheduled_turn_id', 'scheduled_turn_id') ??
          habitNullString2(json, 'turn_id', 'turn_id'),
      createdAt: habitDate(json, 'created_at', 'created_at'),
      executedAt: habitDate(json, 'executed_at', 'executed_at'),
      replyText: habitStr(json, 'reply_text', 'reply_text') ?? '',
      isManual: habitBool(json, 'is_manual', 'is_manual') ?? false,
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'HabitRun($id, ${outcome.wire}, $topicKey)';
}

/// 今日 `due_rule` 触发预算（`GET /api/habits/runs` 的 `daily_budget`）。
///
/// 真源：`ext_routes.go` 的 `allRuns`——
/// `gin.H{"limit": h.maxDueTriggersPerDay, "used_today": usedToday}`。
///
/// ## 为什么必须单独解析而不是只取 `items`
///
/// `unwrapItems` 只看 `items` 字段，会把 `daily_budget` **静默丢掉**。而预算
/// 是「今天还能跑几次」的唯一展示来源：`limit` 与引擎里 `DueRule` 的每日上限
/// **同源**（见服务端注释），展示值偏小会让用户误以为还有额度、偏大则以为
/// 已耗尽。丢掉的后果是「额度用完了但页面上看不到」，用户只能反复点「立即执行」
/// 收 409。
///
/// ## `used_today` 是 **UTC 日**口径
///
/// 服务端 `CountHabitRunsSince` 用 `datetime('now', '-0 days')`（SQLite 的 UTC
/// 零点），**不是**本地零点。故这里不做任何时区换算，也不拿它和本地时间比较。
class HabitDailyBudget {
  const HabitDailyBudget({this.limit = 0, this.usedToday = 0});

  /// 每日上限（来自服务端配置 `HabitMaxDueTriggersPerDay`）。
  final int limit;

  /// 今日（UTC）已用次数。
  final int usedToday;

  /// `limit <= 0` 表示服务端没给出可用上限（字段缺失 / 配置为 0）。
  ///
  /// 此时**不渲染进度条**：画一条恒满或恒空的条比不画更误导。
  bool get hasLimit => limit > 0;

  /// 剩余次数（不足计 0，不出现负数）。
  int get remaining {
    if (!hasLimit) return 0;
    final r = limit - usedToday;
    return r < 0 ? 0 : r;
  }

  /// 今日额度是否已用尽。
  bool get exhausted => hasLimit && usedToday >= limit;

  /// `limit` / `used_today` 缺失或类型不对时返回 null（不造一个假的 0/0）。
  static HabitDailyBudget? fromJson(Object? v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    return HabitDailyBudget(
      limit: habitInt(m, 'limit', 'limit') ?? 0,
      usedToday: habitInt(m, 'used_today', 'used_today') ?? 0,
    );
  }

  @override
  String toString() => 'HabitDailyBudget($usedToday/$limit)';
}

/// `GET /api/habits/runs` 的**完整**响应：记录列表 + 今日预算。
///
/// 与 `listAllRuns`（只返回 `List<HabitRun>`）的区别就是那个 `daily_budget`。
/// 保留旧方法是为了不破坏只关心列表的调用方（也保留了它的既有测试）。
class HabitRunsResult {
  const HabitRunsResult({this.items = const [], this.dailyBudget});

  final List<HabitRun> items;

  /// 服务端未下发 `daily_budget` 时为 null（旧版服务端 / 端点变更）。
  final HabitDailyBudget? dailyBudget;

  static HabitRunsResult fromJson(Object? json) {
    // 兼容两种形态：`{items: [...]}` 与裸 `[...]`（与 `unwrapItems` 同口径）。
    final meta = json is Map
        ? Map<String, dynamic>.from(json)
        : const <String, dynamic>{};
    final raw = json is List ? json : meta['items'];
    return HabitRunsResult(
      items: _listOf<HabitRun>(raw, HabitRun.fromJson),
      dailyBudget: HabitDailyBudget.fromJson(meta['daily_budget']),
    );
  }
}

/// `GET /api/chat/habit-insights/summary` 的响应。
///
/// 真源：`habit_insights.go` 的 `habitInsightsHandlers.summary`。形状是
/// **snake_case 的嵌套 gin.H**（非 sqlc struct），故本类全部按 snake_case 读。
///
/// ⚠️ 该端点依赖 `habit_pattern_recalibrated` 事件计数，而 Go 侧**当前不产出**
/// 该事件（见 `projector.go` 注释）——`recalibration.total_count` 在 Go 版会恒为 0。
/// UI 不应把 0 渲染成「从未重校准」这类确定性结论。
class HabitInsightsSummary {
  const HabitInsightsSummary({
    this.days = 0,
    this.startAt,
    this.endAt,
    this.suggestions,
    this.dueRules,
    this.signalCoverage,
    this.raw = const {},
  });

  final int days;
  final DateTime? startAt;
  final DateTime? endAt;
  final HabitSuggestionInsights? suggestions;
  final HabitDueRuleInsights? dueRules;
  final HabitSignalCoverage? signalCoverage;
  final Map<String, dynamic> raw;

  static HabitInsightsSummary fromJson(Map<String, dynamic> json) {
    final window = habitMap(json, 'window', 'window');
    return HabitInsightsSummary(
      days: habitInt(window, 'days', 'days') ?? 0,
      startAt: habitDate(window, 'start_at', 'start_at'),
      endAt: habitDate(window, 'end_at', 'end_at'),
      suggestions: json['suggestions'] is Map
          ? HabitSuggestionInsights.fromJson(
              Map<String, dynamic>.from(json['suggestions'] as Map),
            )
          : null,
      dueRules: json['due_rules'] is Map
          ? HabitDueRuleInsights.fromJson(
              Map<String, dynamic>.from(json['due_rules'] as Map),
            )
          : null,
      signalCoverage: json['signal_coverage'] is Map
          ? HabitSignalCoverage.fromJson(
              Map<String, dynamic>.from(json['signal_coverage'] as Map),
            )
          : null,
      raw: Map.unmodifiable(json),
    );
  }
}

/// 建议类指标（`buildSuggestionSummary`）。
class HabitSuggestionInsights {
  const HabitSuggestionInsights({
    this.createdCount = 0,
    this.acceptRate = 0,
    this.acceptedCount = 0,
    this.dismissedCount = 0,
    this.snoozedCount = 0,
    this.pendingCount = 0,
    this.byTopic = const [],
    this.byHour = const [],
    this.byWeekday = const [],
  });

  final int createdCount;
  final double acceptRate;

  /// `feedback_counts` 的展开。
  final int acceptedCount;
  final int dismissedCount;
  final int snoozedCount;
  final int pendingCount;

  final List<HabitTopicMetrics> byTopic;
  final List<HabitCountBucket> byHour;

  /// ⚠️ 服务端用 Go 的 `time.Weekday()`（**0=周日**），不是 1=周一。
  final List<HabitCountBucket> byWeekday;

  static HabitSuggestionInsights fromJson(Map<String, dynamic> json) {
    final counts = habitMap(json, 'feedback_counts', 'feedback_counts');
    return HabitSuggestionInsights(
      createdCount: habitInt(json, 'created_count', 'created_count') ?? 0,
      acceptRate: habitDouble(json, 'accept_rate', 'accept_rate') ?? 0,
      acceptedCount: habitInt(counts, 'accepted', 'accepted') ?? 0,
      dismissedCount: habitInt(counts, 'dismissed', 'dismissed') ?? 0,
      snoozedCount: habitInt(counts, 'snoozed', 'snoozed') ?? 0,
      pendingCount: habitInt(counts, 'pending', 'pending') ?? 0,
      byTopic: _listOf(json['by_topic'], HabitTopicMetrics.fromJson),
      byHour: _listOf(json['by_hour'], HabitCountBucket.fromJson),
      byWeekday: _listOf(json['by_weekday'], HabitCountBucket.fromJson),
    );
  }
}

/// 按 topic 聚合的建议指标。
class HabitTopicMetrics {
  const HabitTopicMetrics({
    required this.topicKey,
    this.createdCount = 0,
    this.acceptedCount = 0,
    this.dismissedCount = 0,
    this.snoozedCount = 0,
    this.pendingCount = 0,
    this.blockingFeedbackCount = 0,
    this.blockingFeedbackRate = 0,
  });

  final String topicKey;
  final int createdCount;
  final int acceptedCount;
  final int dismissedCount;
  final int snoozedCount;
  final int pendingCount;

  /// 被忽略或被延后的次数（两者都算「负反馈」）。
  final int blockingFeedbackCount;
  final double blockingFeedbackRate;

  static HabitTopicMetrics fromJson(Map<String, dynamic> json) {
    return HabitTopicMetrics(
      topicKey: habitStr(json, 'topic_key', 'topic_key') ?? 'unknown',
      createdCount: habitInt(json, 'created_count', 'created_count') ?? 0,
      acceptedCount: habitInt(json, 'accepted_count', 'accepted_count') ?? 0,
      dismissedCount: habitInt(json, 'dismissed_count', 'dismissed_count') ?? 0,
      snoozedCount: habitInt(json, 'snoozed_count', 'snoozed_count') ?? 0,
      pendingCount: habitInt(json, 'pending_count', 'pending_count') ?? 0,
      blockingFeedbackCount:
          habitInt(
            json,
            'blocking_feedback_count',
            'blocking_feedback_count',
          ) ??
          0,
      blockingFeedbackRate:
          habitDouble(
            json,
            'blocking_feedback_rate',
            'blocking_feedback_rate',
          ) ??
          0,
    );
  }
}

/// `{hour|weekday: n, created_count: m}` 分桶。
class HabitCountBucket {
  const HabitCountBucket({this.key = 0, this.count = 0});

  /// `hour`（0-23）或 `weekday`（0=周日）。
  final int key;
  final int count;

  static HabitCountBucket fromJson(Map<String, dynamic> json) {
    return HabitCountBucket(
      key:
          habitInt(json, 'hour', 'hour') ??
          habitInt(json, 'weekday', 'weekday') ??
          0,
      count: habitInt(json, 'created_count', 'created_count') ?? 0,
    );
  }
}

/// 定时规则指标（`buildDueRuleSummary`）。
class HabitDueRuleInsights {
  const HabitDueRuleInsights({
    this.triggerCount = 0,
    this.rewardCount = 0,
    this.totalRuns = 0,
    this.continuedRuns = 0,
    this.continuedRate = 0,
    this.recalibrationTotal = 0,
    this.recalibrationAcceptanceFeedback = 0,
    this.recalibrationBlockingFeedback = 0,
    this.byUserDay = const [],
    this.byGroupDay = const [],
  });

  final int triggerCount;
  final int rewardCount;

  /// `continued_interaction` 的展开：触发后用户是否主动跟进。
  final int totalRuns;
  final int continuedRuns;
  final double continuedRate;

  /// ⚠️ Go 侧当前不产出 `habit_pattern_recalibrated` 事件 → 恒为 0。
  final int recalibrationTotal;
  final int recalibrationAcceptanceFeedback;
  final int recalibrationBlockingFeedback;

  final List<HabitDayCount> byUserDay;
  final List<HabitGroupDayCount> byGroupDay;

  static HabitDueRuleInsights fromJson(Map<String, dynamic> json) {
    final cont = habitMap(
      json,
      'continued_interaction',
      'continued_interaction',
    );
    final recal = habitMap(json, 'recalibration', 'recalibration');
    final reasons = habitMap(recal, 'reason_counts', 'reason_counts');
    return HabitDueRuleInsights(
      triggerCount: habitInt(json, 'trigger_count', 'trigger_count') ?? 0,
      rewardCount: habitInt(json, 'reward_count', 'reward_count') ?? 0,
      totalRuns: habitInt(cont, 'total_runs', 'total_runs') ?? 0,
      continuedRuns: habitInt(cont, 'continued_runs', 'continued_runs') ?? 0,
      continuedRate: habitDouble(cont, 'continued_rate', 'continued_rate') ?? 0,
      recalibrationTotal: habitInt(recal, 'total_count', 'total_count') ?? 0,
      recalibrationAcceptanceFeedback:
          habitInt(reasons, 'acceptance_feedback', 'acceptance_feedback') ?? 0,
      recalibrationBlockingFeedback:
          habitInt(reasons, 'blocking_feedback', 'blocking_feedback') ?? 0,
      byUserDay: _listOf(json['by_user_day'], HabitDayCount.fromJson),
      byGroupDay: _listOf(json['by_group_day'], HabitGroupDayCount.fromJson),
    );
  }
}

/// `{user_id, date, trigger_count}`。
class HabitDayCount {
  const HabitDayCount({
    this.userId = '',
    this.date = '',
    this.triggerCount = 0,
  });

  final String userId;

  /// `YYYY-MM-DD`（服务端按 UTC 格式化，未做时区转换）。
  final String date;
  final int triggerCount;

  static HabitDayCount fromJson(Map<String, dynamic> json) => HabitDayCount(
    userId: habitStr(json, 'user_id', 'user_id') ?? '',
    date: habitStr(json, 'date', 'date') ?? '',
    triggerCount: habitInt(json, 'trigger_count', 'trigger_count') ?? 0,
  );
}

/// `{group_id, date, trigger_count}`。
class HabitGroupDayCount {
  const HabitGroupDayCount({
    this.groupId = '',
    this.date = '',
    this.triggerCount = 0,
  });

  final String groupId;
  final String date;
  final int triggerCount;

  static HabitGroupDayCount fromJson(Map<String, dynamic> json) =>
      HabitGroupDayCount(
        groupId: habitStr(json, 'group_id', 'group_id') ?? '',
        date: habitStr(json, 'date', 'date') ?? '',
        triggerCount: habitInt(json, 'trigger_count', 'trigger_count') ?? 0,
      );
}

/// 路由信号覆盖率（`buildSignalCoverage`）。
class HabitSignalCoverage {
  const HabitSignalCoverage({
    this.userMessageCount = 0,
    this.routingSelectedCount = 0,
    this.coverageRate = 0,
  });

  final int userMessageCount;
  final int routingSelectedCount;
  final double coverageRate;

  static HabitSignalCoverage fromJson(
    Map<String, dynamic> json,
  ) => HabitSignalCoverage(
    userMessageCount:
        habitInt(json, 'user_message_count', 'user_message_count') ?? 0,
    routingSelectedCount:
        habitInt(json, 'routing_selected_count', 'routing_selected_count') ?? 0,
    coverageRate: habitDouble(json, 'coverage_rate', 'coverage_rate') ?? 0,
  );
}

List<T> _listOf<T>(Object? v, T Function(Map<String, dynamic>) from) {
  if (v is! List) return const [];
  final out = <T>[];
  for (final e in v) {
    if (e is Map) out.add(from(Map<String, dynamic>.from(e)));
  }
  return out;
}
