part of 'habit.dart';

/// 一条习惯规则（`habit_patterns` 行）。
///
/// ⚠️ **序列化是 camelCase**（sqlc `queries.HabitPattern` 直接 JSON 出去），
/// 但 [fromJson] 同时接受 snake_case，因为 `/me/habits` 等别名路径与
/// 未来可能的 DTO 化都可能换形状。见 `habit.dart` 顶部说明。
class UserHabit {
  const UserHabit({
    required this.id,
    required this.userId,
    this.originGroupId = '',
    this.deliveryGroupId,
    this.preferredAgentId,
    this.routeStrategy = '',
    required this.triggerType,
    required this.triggerConfig,
    this.topicKey = '',
    this.topicId = '',
    this.promptStrategy = '',
    this.promptContractJson = '',
    this.sourceType = HabitSourceType.unknown,
    this.learnedFromEvents = 0,
    this.confidence = 0,
    this.acceptanceLevel = HabitAcceptanceLevel.unknown,
    this.status = HabitPatternStatus.unknown,
    this.nextFireAt,
    this.cooldownUntil,
    this.lastTriggeredAt,
    this.triggerCount = 0,
    this.lastErrorNotifiedAt,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String userId;
  final String originGroupId;
  final String? deliveryGroupId;

  /// 执行该习惯时优先使用的 agent（null = 走默认路由）。
  final String? preferredAgentId;

  final String routeStrategy;
  final HabitTriggerType triggerType;
  final HabitTriggerConfig triggerConfig;

  /// 习惯主题（如 `weekly-report`）。
  final String topicKey;

  /// 归属的 topic id（服务端建 pattern 时由 topic_key 解析得到）。
  final String topicId;

  final String promptStrategy;

  /// 提示词契约的原始 JSON 字符串。
  final String promptContractJson;

  final HabitSourceType sourceType;
  final int learnedFromEvents;
  final double confidence;
  final HabitAcceptanceLevel acceptanceLevel;
  final HabitPatternStatus status;

  /// 下次触发时刻。
  ///
  /// ⚠️ 服务端该列是 `sql.NullTime`，**没有自定义 MarshalJSON**，故 JSON 形态是
  /// `{"Time":"2026-10-04T09:00:00Z","Valid":true}`（已用 Go 实测确认）。
  /// 直接 `DateTime.tryParse(json['nextFireAt'])` 会失败——必须走 [habitNullTime]。
  final DateTime? nextFireAt;

  final DateTime? cooldownUntil;
  final DateTime? lastTriggeredAt;
  final int triggerCount;
  final DateTime? lastErrorNotifiedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 原始 JSON（保留客户端未建模的字段）。
  final Map<String, dynamic> raw;

  bool get isActive => status == HabitPatternStatus.active;
  bool get isPaused => status == HabitPatternStatus.paused;

  /// 是否可暂停（服务端只允许 active → paused）。
  bool get canPause => isActive;

  /// 是否可恢复（服务端只允许 paused → active）。
  bool get canResume => isPaused;

  /// 是否可手动触发（服务端只允许 active）。
  bool get canTrigger => isActive;

  /// 是否可归档（archived 是终态）。
  bool get canArchive => status != HabitPatternStatus.archived;

  static UserHabit fromJson(Map<String, dynamic> json) {
    return UserHabit(
      id: habitStr(json, 'id', 'id') ?? '',
      userId: habitStr(json, 'userId', 'user_id') ?? '',
      originGroupId: habitStr(json, 'originGroupId', 'origin_group_id') ?? '',
      deliveryGroupId: habitNullString2(
        json,
        'deliveryGroupId',
        'delivery_group_id',
      ),
      preferredAgentId: habitNullString2(
        json,
        'preferredAgentId',
        'preferred_agent_id',
      ),
      routeStrategy: habitStr(json, 'routeStrategy', 'route_strategy') ?? '',
      triggerType: HabitTriggerType.from(
        habitStr(json, 'triggerType', 'trigger_type'),
      ),
      triggerConfig: HabitTriggerConfig.fromJsonString(
        habitStr(json, 'triggerConfigJson', 'trigger_config_json'),
        triggerTypeRaw: habitStr(json, 'triggerType', 'trigger_type'),
      ),
      topicKey: habitStr(json, 'topicKey', 'topic_key') ?? '',
      topicId: habitStr(json, 'topicId', 'topic_id') ?? '',
      promptStrategy: habitStr(json, 'promptStrategy', 'prompt_strategy') ?? '',
      promptContractJson:
          habitStr(json, 'promptContractJson', 'prompt_contract_json') ?? '',
      sourceType: HabitSourceType.from(
        habitStr(json, 'sourceType', 'source_type'),
      ),
      learnedFromEvents:
          habitInt(json, 'learnedFromEvents', 'learned_from_events') ?? 0,
      confidence: habitDouble(json, 'confidence', 'confidence') ?? 0,
      acceptanceLevel: HabitAcceptanceLevel.from(
        habitStr(json, 'acceptanceLevel', 'acceptance_level'),
      ),
      status: HabitPatternStatus.from(habitStr(json, 'status', 'status')),
      nextFireAt: habitNullTime(json, 'nextFireAt', 'next_fire_at'),
      cooldownUntil: habitNullTime(json, 'cooldownUntil', 'cooldown_until'),
      lastTriggeredAt: habitNullTime(
        json,
        'lastTriggeredAt',
        'last_triggered_at',
      ),
      triggerCount: habitInt(json, 'triggerCount', 'trigger_count') ?? 0,
      lastErrorNotifiedAt: habitNullTime(
        json,
        'lastErrorNotifiedAt',
        'last_error_notified_at',
      ),
      createdAt: habitDate(json, 'createdAt', 'created_at'),
      updatedAt: habitDate(json, 'updatedAt', 'updated_at'),
      raw: Map.unmodifiable(json),
    );
  }

  @override
  String toString() => 'UserHabit($id, $topicKey, ${status.wire})';
}

/// `POST /api/habits` 的响应。
///
/// 服务端返回 `{pattern_id, group_id, topic_id, next_fire_at, ...}`（201）。
class HabitCreateResult {
  const HabitCreateResult({
    required this.patternId,
    this.groupId,
    this.topicId,
    this.nextFireAt,
    this.raw = const {},
  });

  final String patternId;

  /// 服务端为 pattern 解析出的归属 group（可能 null）。
  final String? groupId;

  final String? topicId;
  final DateTime? nextFireAt;
  final Map<String, dynamic> raw;

  static HabitCreateResult fromJson(Map<String, dynamic> json) {
    return HabitCreateResult(
      patternId: habitStr(json, 'pattern_id', 'pattern_id') ?? '',
      groupId: habitNullString2(json, 'group_id', 'group_id'),
      topicId: habitNullString2(json, 'topic_id', 'topic_id'),
      nextFireAt: habitNullTime(json, 'next_fire_at', 'next_fire_at'),
      raw: Map.unmodifiable(json),
    );
  }
}

/// 归一 `sql.NullTime` 的 JSON 形态。
///
/// Go 的 `sql.NullTime` **没有** `MarshalJSON`（`database/sql` 未提供，
/// 仓库内也无自定义），实测序列化为：
///
/// ```json
/// {"Time":"2026-10-04T09:00:00Z","Valid":true}
/// {"Time":"0001-01-01T00:00:00Z","Valid":false}
/// ```
///
/// 故不能直接 `DateTime.tryParse`。三种形态（嵌套对象 / 裸 RFC3339 串 / null）
/// 都归一成 `DateTime?`；`Valid:false` 时**必须**返回 null，否则会得到零值
/// `0001-01-01` 而不是「无下次触发」。
DateTime? habitNullTime(Map<String, dynamic> json, String camel, String snake) {
  final v = json.containsKey(camel) ? json[camel] : json[snake];
  if (v == null) return null;
  if (v is String) {
    if (v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final raw = v['Time'] ?? v['time'];
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) return null;
      // 零值（`0001-01-01T00:00:00Z`）即使 Valid:true 也应视为无值——那是
      // SQLite NULL 被 Go 读成零值时间再写回时的残留形态。
      if (parsed.year <= 1) return null;
      return parsed.toLocal();
    }
  }
  return null;
}
