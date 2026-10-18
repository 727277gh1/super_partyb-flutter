part of 'habit.dart';

/// 建议的可用动作（`POST .../resolve` 的 `action` 字段）。
///
/// 真源：`misc_extra.go` 的 `mapFeedbackValue`（accept|dismiss|snooze|edit_and_accept）。
enum HabitSuggestionAction {
  accept('accept', 'accepted', '接受'),

  /// 与 [accept] 的区别：服务端同样建 pattern，但语义上表示用户改过草稿。
  ///
  /// ## 必须与 [patternPatch] 一起用（否则等于 [accept]）
  ///
  /// 服务端只在 `action == edit_and_accept` 时消费 `pattern_patch`
  /// （`misc_extra.go` 的 `PatternPatch` 字段注释 + `applyPatternPatch`）。
  /// 不发 patch 时服务端走 `accept_rule` 建出**候选原值**的规则——用户以为
  /// 改过了，实际没改。
  ///
  /// 可编辑的字段由服务端白名单 `SuggestionEditableFields`
  /// （`topic_key` / `trigger_config` / `preferred_agent_id` / `delivery_group_id`）
  /// 经事件 payload 的 `editable_fields` 下发，见
  /// [HabitSuggestionItem.editableFields]。
  editAndAccept('edit_and_accept', 'accepted', '编辑并接受'),

  dismiss('dismiss', 'dismissed', '忽略'),
  snooze('snooze', 'snoozed', '稍后提醒');

  const HabitSuggestionAction(this.wire, this.feedback, this.label);

  /// 请求体 `action` 的值。
  final String wire;

  /// 服务端写入 `habit_runs.user_feedback` 的值（`mapFeedbackValue` 的结果）。
  ///
  /// ⚠️ 与 [wire] **三个都不相同**：`accept`/`edit_and_accept` → `accepted`、
  /// `dismiss` → `dismissed`、`snooze` → `snoozed`（`misc_extra.go:553` 的
  /// `mapFeedbackValue`）。事件 payload 的 `user_feedback` 与列表端点的
  /// `user_feedback` 都是这个值，不能拿 [wire] 去匹配。
  ///
  /// 注意别把 `accept_rule` 当成它：那是 `recommendation.action`
  /// （建议卡上展示的推荐动作），与用户反馈无关。
  final String feedback;

  final String label;

  /// 是否会在服务端建出 active pattern。
  bool get createsPattern => this == accept || this == editAndAccept;

  static HabitSuggestionAction? from(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final v in values) {
      if (v.wire == raw || v.feedback == raw) return v;
    }
    return null;
  }
}

/// 稍后提醒的预设时长（对齐 webapp `SNOOZE_OPTIONS`）。
enum HabitSnoozeOption {
  oneHour('1h', '1 小时后'),
  fourHours('4h', '4 小时后'),
  oneDay('24h', '24 小时后'),
  tomorrow('tomorrow', '明天');

  const HabitSnoozeOption(this.wire, this.label);

  final String wire;
  final String label;

  /// 计算 `snooze_until`（**UTC** ISO8601）。
  ///
  /// 照抄 webapp `computeSnoozeUntil`（`group-chat.ts:661`）：服务端按 UTC
  /// 处理该值（`domain.ParseISO` + `domain.ISO`），故这里必须产 UTC 串。
  /// `tomorrow` 是「UTC 次日 00:00」——与 webapp 逐字一致，不按本地时区算，
  /// 否则与 webapp 用户看到的抑制窗口不一致。
  DateTime until(DateTime now) {
    final utc = now.toUtc();
    switch (this) {
      case HabitSnoozeOption.tomorrow:
        return DateTime.utc(utc.year, utc.month, utc.day + 1);
      case HabitSnoozeOption.oneHour:
        return utc.add(const Duration(hours: 1));
      case HabitSnoozeOption.fourHours:
        return utc.add(const Duration(hours: 4));
      case HabitSnoozeOption.oneDay:
        return utc.add(const Duration(hours: 24));
    }
  }

  /// 请求体用的 RFC3339 UTC 串（`2026-10-04T09:00:00Z`）。
  ///
  /// 手写格式而非 `toIso8601String()`：后者对 UTC 产出
  /// `2026-10-04T09:00:00.000Z`（带毫秒），服务端 `domain.ParseISO`
  /// 能解析，但 webapp 产的是无毫秒形态——两边保持一致便于排查。
  String untilIso(DateTime now) {
    final t = until(now);
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}-${p2(t.month)}-${p2(t.day)}'
        'T${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}Z';
  }
}

/// 一条习惯建议（`habit_runs` 中 `outcome=suggested` 的行 + 事件里的草稿）。
///
/// ## 两条数据来源，字段互补
///
/// | 来源 | 有 | 无 |
/// |---|---|---|
/// | `habit_suggestion_created` 事件 payload | `rule_draft`（topic_key / trigger_config / preferred_agent_id / target_acceptance_level）、`recommendation`（confidence / reasons）、`evidence`、`editable_fields` | run 的 `created_at` 等 |
/// | `GET /api/chat/habit-suggestions` 列表 | run 全字段（`habitRunToMap` 形状） | `rule_draft` —— **topic_key 只在 `trigger_context_json` 里**，服务端列表端点不解析它 |
///
/// ⚠️ 所以「列表页显示的 topic_key」与「时间线卡片显示的 topic_key」来自
/// **不同字段**（前者 `trigger_context_json.topic_key`，后者
/// `rule_draft.topic_key`）。本类两者都收：事件构造时填 [topicKey]（来自
/// rule_draft），列表构造时回退解析 `trigger_context_json`。
class HabitSuggestion {
  const HabitSuggestion({
    required this.id,
    this.habitPatternId,
    this.userId = '',
    this.originGroupId = '',
    this.deliveryGroupId,
    this.status = 'pending',
    this.triggerType = HabitTriggerType.timeBased,
    this.topicKey = '',
    this.triggerConfig,
    this.preferredAgentId,
    this.targetAcceptanceLevel,
    this.confidence,
    this.reasons = const [],
    this.evidence = const {},
    this.editableFields = const [],
    this.userFeedback,
    this.feedbackPayload,
    this.feedbackAt,
    this.createdAt,
    this.executedAt,
    this.triggerReason = HabitTriggerReason.candidateDetected,
    this.raw = const {},
  });

  /// 建议 id（= `habit_runs.id`）。
  final String id;

  /// 关联的 pattern；候选建议为 null。
  final String? habitPatternId;

  final String userId;
  final String originGroupId;
  final String? deliveryGroupId;

  /// `pending` / `resolved`。
  final String status;

  final HabitTriggerType triggerType;

  /// 主题 key（见类文档：两条来源）。
  final String topicKey;

  /// 建议的触发配置（`rule_draft.trigger_config`）。
  final HabitTriggerConfig? triggerConfig;

  final String? preferredAgentId;

  /// 建议采纳后的接受级别（`rule_draft.target_acceptance_level`）。
  final HabitAcceptanceLevel? targetAcceptanceLevel;

  /// 推荐置信度（0-1）。
  final double? confidence;

  /// 推荐理由（面向用户展示）。
  final List<String> reasons;

  /// 证据（如命中次数、样例事件）。
  final Map<String, dynamic> evidence;

  /// 允许用户就地编辑的字段名（服务端 `SuggestionEditableFields`）。
  ///
  /// 真源：`workers/habit/timeline_events.go:52`
  /// ```go
  /// var SuggestionEditableFields = []string{"topic_key", "trigger_config",
  ///   "preferred_agent_id", "delivery_group_id"}
  /// ```
  /// 随 `habit_suggestion_created` 事件的 payload 下发。
  ///
  /// ## 为什么是「下发」而不是客户端写死
  ///
  /// 服务端新增/收窄可编辑面时不应要求客户端改代码；且客户端自行扩大字段集
  /// 会让用户编辑出一个服务端**不接受**的 patch——`applyPatternPatch` 对不认识
  /// 的键静默忽略，表现为「保存成功但配置没变」。故 UI 必须只渲染这里出现的键。
  final List<String> editableFields;

  /// 用户反馈（null = 未处理）。
  final HabitUserFeedback? userFeedback;

  /// 反馈负载（`{action, resolved_at, snooze_until?|cooldown_until?, comment?}`）。
  final Map<String, dynamic>? feedbackPayload;

  final DateTime? feedbackAt;
  final DateTime? createdAt;
  final DateTime? executedAt;

  final HabitTriggerReason triggerReason;
  final Map<String, dynamic> raw;

  /// 是否仍待用户处理。
  ///
  /// 判定用 [userFeedback] 而非 [status]：服务端 resolve 后 `status` 仍是
  /// run 的状态字段，真正表示「已处理」的是 `user_feedback` 非空。
  bool get isPending => userFeedback == null;

  /// 是否可编辑（服务端允许的字段非空）。
  bool get canEdit => editableFields.isNotEmpty;

  /// 已处理时的动作。
  HabitSuggestionAction? get resolvedAction =>
      HabitSuggestionAction.from(userFeedback?.wire);

  /// 该建议是否已建出 pattern（accept / edit_and_accept）。
  bool get hasResolvedPattern {
    final v = feedbackPayload?['resolved_pattern_id'];
    return v is String && v.isNotEmpty;
  }

  HabitSuggestion copyWith({
    String? topicKey,
    HabitTriggerConfig? triggerConfig,
    String? preferredAgentId,
    HabitUserFeedback? userFeedback,
    Map<String, dynamic>? feedbackPayload,
    DateTime? feedbackAt,
  }) {
    return HabitSuggestion(
      id: id,
      habitPatternId: habitPatternId,
      userId: userId,
      originGroupId: originGroupId,
      deliveryGroupId: deliveryGroupId,
      status: status,
      triggerType: triggerType,
      topicKey: topicKey ?? this.topicKey,
      triggerConfig: triggerConfig ?? this.triggerConfig,
      preferredAgentId: preferredAgentId ?? this.preferredAgentId,
      targetAcceptanceLevel: targetAcceptanceLevel,
      confidence: confidence,
      reasons: reasons,
      evidence: evidence,
      editableFields: editableFields,
      userFeedback: userFeedback ?? this.userFeedback,
      feedbackPayload: feedbackPayload ?? this.feedbackPayload,
      feedbackAt: feedbackAt ?? this.feedbackAt,
      createdAt: createdAt,
      executedAt: executedAt,
      triggerReason: triggerReason,
      raw: raw,
    );
  }

  /// 从 **`habit_suggestion_created` 事件 payload** 构造。
  ///
  /// 形状真源：`BuildSuggestionCreatedPayload`（`timeline_events.go`）。
  static HabitSuggestion? fromEventPayload(
    Map<String, dynamic> payload, {
    String groupId = '',
    String userId = '',
    DateTime? createdAt,
  }) {
    final id = habitStr(payload, 'suggestion_id', 'suggestion_id');
    if (id == null) return null;
    final ruleDraft = habitMap(payload, 'rule_draft', 'rule_draft');
    final recommendation = habitMap(
      payload,
      'recommendation',
      'recommendation',
    );
    final triggerType =
        habitStr(ruleDraft, 'trigger_type', 'trigger_type') ??
        habitStr(payload, 'trigger_type', 'trigger_type');
    final rawConfig = habitMapOrNull(
      ruleDraft,
      'trigger_config',
      'trigger_config',
    );
    return HabitSuggestion(
      id: id,
      habitPatternId: habitNullString2(
        payload,
        'habit_pattern_id',
        'habit_pattern_id',
      ),
      userId: userId,
      originGroupId: groupId,
      deliveryGroupId: habitNullString2(
        ruleDraft,
        'delivery_group_id',
        'delivery_group_id',
      ),
      status: habitStr(payload, 'status', 'status') ?? 'pending',
      triggerType: HabitTriggerType.from(triggerType),
      topicKey: habitStr(ruleDraft, 'topic_key', 'topic_key') ?? '',
      triggerConfig: rawConfig == null
          ? null
          : HabitTriggerConfig.fromJson(rawConfig, triggerTypeRaw: triggerType),
      preferredAgentId: habitNullString2(
        ruleDraft,
        'preferred_agent_id',
        'preferred_agent_id',
      ),
      targetAcceptanceLevel: HabitAcceptanceLevel.from(
        habitStr(
          ruleDraft,
          'target_acceptance_level',
          'target_acceptance_level',
        ),
      ),
      confidence: habitDouble(recommendation, 'confidence', 'confidence'),
      reasons: habitStrList(recommendation, 'reasons', 'reasons'),
      evidence: habitMap(payload, 'evidence', 'evidence'),
      editableFields: habitStrList(
        payload,
        'editable_fields',
        'editable_fields',
      ),
      createdAt: createdAt,
      raw: Map.unmodifiable(payload),
    );
  }

  /// 从 **`GET /api/chat/habit-suggestions` 的列表项**构造
  /// （`habitRunToMap` 形状：`{id, habit_pattern_id, user_id, ..., trigger_context_json}`）。
  static HabitSuggestion fromListItem(Map<String, dynamic> json) {
    final run = HabitRun.fromJson(json);
    // 列表端点不解析 trigger_context_json 的 topic_key（`habitRunToMap` 不含
    // topic_key 键），但 payload 里有——本地解一次，否则列表只能显示「未命名」。
    final ctx = _decodeJsonObject(run.triggerContextJson);
    var topicKey = run.topicKey;
    if (topicKey.isEmpty) {
      topicKey = habitStr(ctx, 'topic_key', 'topicKey') ?? '';
      if (topicKey.isEmpty) {
        // 兼容 Python 旧形态 `{"candidate": {"topic_key": ...}}`。
        final candidate = habitMapOrNull(ctx, 'candidate', 'candidate');
        if (candidate != null) {
          topicKey = habitStr(candidate, 'topic_key', 'topicKey') ?? '';
        }
      }
    }
    final feedbackPayload = _decodeJsonObject(run.feedbackPayloadJson);
    return HabitSuggestion(
      id: run.id,
      habitPatternId: run.habitPatternId,
      userId: run.userId,
      originGroupId: run.originGroupId,
      deliveryGroupId: run.deliveryGroupId,
      status: run.outcome == HabitRunOutcome.suggested ? 'pending' : 'resolved',
      triggerType: HabitTriggerType.from(
        habitStr(ctx, 'trigger_type', 'trigger_type'),
      ),
      topicKey: topicKey,
      triggerConfig: _triggerConfigFromContext(ctx),
      preferredAgentId: habitNullString2(
        ctx,
        'preferred_agent_id',
        'preferred_agent_id',
      ),
      confidence: habitDouble(ctx, 'confidence', 'confidence'),
      reasons: habitStrList(ctx, 'reasons', 'reasons'),
      userFeedback: run.userFeedback,
      feedbackPayload: feedbackPayload.isEmpty ? null : feedbackPayload,
      feedbackAt: run.feedbackAt,
      createdAt: run.createdAt,
      executedAt: run.executedAt,
      triggerReason: run.triggerReason,
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'HabitSuggestion($id, $topicKey, pending=$isPending)';
}

/// 从 `trigger_context_json` 里尽力还原触发配置。
///
/// 该 JSON 是检测器写入的自由形态（`suggestion.go` 的 `createSuggestion`），
/// 键名不保证——故只在存在 `trigger_config` 子对象或 `hour`/`cadence` 时才构造，
/// 否则返回 null（UI 显示「未配置」而不是瞎猜一个 0 点）。
HabitTriggerConfig? _triggerConfigFromContext(Map<String, dynamic> ctx) {
  final nested = habitMapOrNull(ctx, 'trigger_config', 'trigger_config');
  if (nested != null && nested.isNotEmpty) {
    return HabitTriggerConfig.fromJson(nested);
  }
  if (ctx.containsKey('cadence') ||
      ctx.containsKey('hour') ||
      ctx.containsKey('times')) {
    return HabitTriggerConfig.fromJson(ctx);
  }
  return null;
}
