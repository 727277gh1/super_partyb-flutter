/// 自动续跑排程（`chat_turn_schedules` 行，snake_case 契约）。
///
/// 对应 Go 侧 `internal/server/schedules.go` 的 `scheduleToDTO`（2026-11，
/// Go `b2a54b5a` 重写该端点时从「直接返回 sqlc 行（camelCase）」改为**统一
/// DTO（snake_case）**，与 webapp 的 `ChatTurnScheduleDebugItem` 对齐）。
///
/// ## ⚠️ 契约曾断裂过一次（不要回退）
///
/// 客户端首版模型按旧端点的 sqlc 行写（camelCase：`agentId` / `runCount` /
/// `policyJson` 字符串）。Go `b2a54b5a` 换成 `scheduleToDTO` 后形状全变：
/// 字段名 snake_case、`policyJson` 字符串变成 `policy` **对象**、新增
/// `schedule_state`。按旧契约解析**不报错**，只是全部字段落空（`fromJson`
/// 的 `?? ''` / `?? 0` 兜底把缺失吞掉）——面板看起来像「没有排程」。这正
/// 是 AGENTS.md §6.28 反复出现的「静默不兼容」形态，故这里逐字段镜像新
/// DTO 并有契约测试钉住。
///
/// ## 字段形态对照
///
/// | Go DTO | 形态 | 本模型 |
/// |---|---|---|
/// | `policy` | **对象**（`parseJSON` 解析过） | `policy`（Map）→ [groupId] |
/// | `trigger_status` | `nullStr`：串或 null | `triggerStatus` |
/// | `last_error` | `parseJSON`：对象或 null | `lastError`（保留原文形态） |
/// | `schedule_state` | `pending`/`triggered`/`disabled`/`failed` | `scheduleState` |
/// | `next_run_at` 等 | RFC3339 串或 null（`timeOrNil`） | `DateTime?` |
/// | `created_at` 等 | RFC3339（`iso`，零值是**空串**） | `DateTime?` |
library;

import 'dart:convert';

/// 从 `policy` 对象里取 `meta.group_id`（容错返回 null）。
///
/// ## 为什么需要它（客户端侧的 group 归属判定）
///
/// `chat_turn_schedules` **没有 group 列**——group 只存在于
/// `policy_json.meta.group_id`（服务端停用端点的 SQL 也是靠
/// `json_extract(policy_json, '$.meta.group_id')` 过滤）。
///
/// 新 DTO（Go `b2a54b5a` 起）把 `policy` 解析成**对象**下发，故直接下探两层
/// 取值；历史形态（`policyJson` 字符串）不再支持——服务端只有一个列表端点，
/// 双形状共存只会制造「哪边是真」的漂移。
///
/// 任何一层形状不对都返回 null，不抛异常（形状漂移不该炸掉面板）。
String? chatScheduleGroupIdFromPolicy(Object? policy) {
  if (policy is String && policy.isNotEmpty) {
    // 防御：万一上游把原文串透传，仍按字符串解析一次（与旧逻辑同语义）。
    Object? decoded;
    try {
      decoded = jsonDecode(policy);
    } on FormatException {
      return null;
    }
    return chatScheduleGroupIdFromPolicy(decoded);
  }
  if (policy is! Map) return null;
  final meta = policy['meta'];
  if (meta is! Map) return null;
  final groupId = meta['group_id'] ?? meta['groupId'];
  if (groupId is String && groupId.isNotEmpty) return groupId;
  return null;
}

/// `chat_turn_schedules` 行（新 DTO，snake_case）。
class ChatTurnSchedule {
  const ChatTurnSchedule({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.agentType,
    required this.triggerReason,
    required this.message,
    required this.policy,
    required this.dedupeKey,
    required this.enabled,
    required this.runCount,
    required this.maxRuns,
    required this.createdAt,
    required this.updatedAt,
    this.triggerStatus,
    this.nextRunAt,
    this.lastRunAt,
    this.lastError,
    this.scheduleState,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String agentType;

  /// 为什么排了这一条（如 `goal_gate` 续跑）。
  final String triggerReason;

  /// 触发时的子状态（`nullStr`：串或 null，如 `pending`）。
  final String? triggerStatus;

  /// 排程触发时要发的内容。
  final String message;

  /// 策略对象（服务端已把 JSON 文本解析成对象）。group 归属在
  /// `meta.group_id`，见 [chatScheduleGroupIdFromPolicy]。
  final Object? policy;

  /// 去重键。goal_gate 续跑的以 `goal_gate:` 开头（服务端停用端点据此
  /// 限定范围，不误伤 retry / fastpath）。
  final String dedupeKey;

  final bool enabled;
  final int runCount;
  final int maxRuns;

  /// 服务端派生的展示态（`pending` / `triggered` / `disabled` / `failed`）。
  ///
  /// 派生规则（`scheduleToDTO`）：有 last_error → `failed`；enabled 且有
  /// next_run_at → `pending`；跑过 → `triggered`；否则 `disabled`。
  /// 客户端**不重新派生**：展示直接用它（与服务端、webapp 三方同词），
  /// 只有业务判据（是否可停用）才用 [isPending]。
  final String? scheduleState;

  /// 下次触发时间（`timeOrNil`：null = 无）。
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;

  /// 最后一次失败的错误对象原文（`parseJSON`：对象或 null）。
  final Object? lastError;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 所属 group（从 [policy] 解析）；解析不出时 null。
  String? get groupId => chatScheduleGroupIdFromPolicy(policy);

  /// 是否仍在等待触发（未停用且未用完次数）。
  ///
  /// 与停用端点的 SQL 谓词同口径（`enabled = 1 AND run_count < max_runs`），
  /// 故「可停用的那些」就是本 getter 为真的那些——面板据此决定停用按钮
  /// 是否可点，与服务端实际会撤销的集合一致。
  bool get isPending => enabled && runCount < maxRuns;

  factory ChatTurnSchedule.fromJson(Map<String, dynamic> json) =>
      ChatTurnSchedule(
        id: (json['id'] as String?) ?? '',
        agentId: (json['agent_id'] as String?) ?? '',
        sessionId: (json['session_id'] as String?) ?? '',
        agentType: (json['agent_type'] as String?) ?? '',
        triggerReason: (json['trigger_reason'] as String?) ?? '',
        triggerStatus: _stringOrNull(json['trigger_status']),
        message: (json['message'] as String?) ?? '',
        policy: json['policy'],
        dedupeKey: (json['dedupe_key'] as String?) ?? '',
        enabled: json['enabled'] == true,
        runCount: _int(json['run_count']),
        maxRuns: _int(json['max_runs']),
        scheduleState: _stringOrNull(json['schedule_state']),
        nextRunAt: _dateOrNull(json['next_run_at']),
        lastRunAt: _dateOrNull(json['last_run_at']),
        lastError: json['last_error'],
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
      );

  /// `nullStr` 形态：串或 null；空串归 null（与旧语义一致——空串当无值）。
  static String? _stringOrNull(Object? v) {
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  /// 取整数；非 num / 字符串数字均可解析，其余归 0（与 `ChatTurn._int` 同取向）。
  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  /// `timeOrNil` 形态：RFC3339 串或 null。**required 字段**用 [_date]。
  static DateTime? _dateOrNull(Object? v) => _date(v);

  /// `iso()` 形态：RFC3339 串；**零值是空串**（不是 null），空串同样归 null。
  static DateTime? _date(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
}
