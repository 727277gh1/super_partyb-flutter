/// 自动续跑排程（`chat_turn_schedules` 行，camelCase 契约）。
///
/// 对应 Go 侧 `db/queries/models.go` 的 `ChatTurnSchedule`（sqlc 生成，
/// `json_tags_case_style: camel`）。两个端点的契约：
///
/// | 用途 | 端点 |
/// |---|---|
/// | 列出 | `GET /api/chat/groups/:group_id/auto-schedules` |
/// | 停用 | `POST /chat/groups/:group_id/auto-schedule/stop` |
///
/// ## ⚠️ 字段名是 **camelCase**，不是 snake_case
///
/// webapp 的 TS 类型 `ChatTurnScheduleDebugItem`（`lib/api/group-chat.ts`）是
/// snake_case **且多出 Go 侧根本不发的三个字段**（`schedule_state` / `policy` /
/// `last_error`）。照抄它会让 `enabled` / `runCount` 等一片 `undefined`
/// ——解析不报错，只是全部落空。故本模型严格照抄 Go 的 json tag。
///
/// ## ⚠️ `sql.NullString` / `sql.NullTime` 是**嵌套对象**
///
/// Go 的 `database/sql` 未给这两个类型提供 `MarshalJSON`，仓库内也无自定义，
/// 故序列化为 `{"String":"…","Valid":true}` / `{"Time":"…","Valid":true}`。
/// 直接 `json['triggerStatus'] as String?` 会拿到一个 `Map`（类型转换抛错或
/// 静默落空）。见 [chatScheduleNullString] / [chatScheduleNullTime]。
///
/// ## 为什么放在 spb_models 而不是 spb_domain
///
/// 它只做**字段镜像 + 形态归一**，不含业务规则（与 `chat_event.dart` 的分工
/// 说明一致）。「哪些排程该显示、停用按钮何时可点」是领域规则，归 spb_domain。
library;

import 'dart:convert';

/// 归一 `sql.NullString` 的 JSON 形态（`{"String":..,"Valid":..}` / 裸串 / null）。
///
/// 与 `habit.dart` 的 `habitNullString` 同语义。此处独立实现而非复用，是为了
/// 让本模型自包含（该函数名带 `habit` 前缀，在排程语境下会误导读者）。
String? chatScheduleNullString(Object? v) {
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final s = v['String'] ?? v['string'];
    if (s is String && s.isNotEmpty) return s;
  }
  return null;
}

/// 归一 `sql.NullTime` 的 JSON 形态（嵌套对象 / 裸 RFC3339 串 / null）。
///
/// ## 为什么不能直接 `DateTime.tryParse`
///
/// 该字段是 Go `sql.NullTime`，JSON 形态是
/// `{"Time":"2026-10-04T09:00:00Z","Valid":true}`。传 Map 给 `tryParse` 只会
/// 得到 null。
///
/// ## 为什么 `Valid:false` 与零值都要返回 null
///
/// `Valid:false` 时 `Time` 是 Go 零值 `0001-01-01T00:00:00Z`。若不管它，UI
/// 会显示「下次触发：公元 1 年」而不是「无下次触发」。故 [valid] 为假、
/// 或解析出的年份 ≤ 1，都视为**无值**。
DateTime? chatScheduleNullTime(Object? v) {
  if (v == null) return null;
  if (v is String) {
    if (v.isEmpty) return null;
    final parsed = DateTime.tryParse(v);
    if (parsed == null || parsed.year <= 1) return null;
    return parsed.toLocal();
  }
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final raw = v['Time'] ?? v['time'];
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed == null || parsed.year <= 1) return null;
      return parsed.toLocal();
    }
  }
  return null;
}

/// 从 `policyJson` 里取 `meta.group_id`（容错返回 null）。
///
/// ## 为什么需要它（客户端侧的 group 归属判定）
///
/// `chat_turn_schedules` **没有 group 列**——group 只存在于
/// `policy_json.meta.group_id`（服务端停用端点的 SQL 也是靠
/// `json_extract(policy_json, '$.meta.group_id')` 过滤）。
///
/// 而列出端点（`admin.go` 的 `listByAgent`）**忽略路径里的 `:group_id`**，
/// 只按 `agent_id` 查。故客户端拿到的是「同一 agent 的全部排程」，必须再按
/// 本字段本地过滤出属于当前 group 的那些——否则会把别的对话的排程显示出来。
///
/// `policyJson` 是**字符串**（不是对象），要解两层：外层 policy → `meta` →
/// `group_id`。任何一层形状不对都返回 null，不抛异常（形状漂移不该炸掉面板）。
String? chatScheduleGroupIdFromPolicy(String? policyJson) {
  if (policyJson == null || policyJson.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(policyJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final meta = decoded['meta'];
  if (meta is! Map) return null;
  final groupId = meta['group_id'] ?? meta['groupId'];
  if (groupId is String && groupId.isNotEmpty) return groupId;
  return null;
}

/// `chat_turn_schedules` 行。
class ChatTurnSchedule {
  const ChatTurnSchedule({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.agentType,
    required this.triggerReason,
    required this.message,
    required this.policyJson,
    required this.dedupeKey,
    required this.enabled,
    required this.runCount,
    required this.maxRuns,
    required this.createdAt,
    required this.updatedAt,
    this.triggerStatus,
    this.nextRunAt,
    this.lastRunAt,
    this.lastErrorJson,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String agentType;

  /// 为什么排了这一条（如 `goal_gate` 续跑）。
  final String triggerReason;

  /// `sql.NullString` → 可空。
  final String? triggerStatus;

  /// 排程触发时要发的内容。
  final String message;

  /// 策略 JSON **原文**（字符串）。group 归属在 `meta.group_id`，见
  /// [chatScheduleGroupIdFromPolicy]。
  final String policyJson;

  /// 去重键。goal_gate 续跑的以 `goal_gate:` 开头（服务端停用端点据此
  /// 限定范围，不误伤 retry / fastpath）。
  final String dedupeKey;

  final bool enabled;
  final int runCount;
  final int maxRuns;

  /// `sql.NullTime` → 可空（`Valid:false` / 零值均为 null）。
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;

  /// `sql.NullString` → 可空（最后一次失败的错误 JSON 原文）。
  final String? lastErrorJson;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 所属 group（从 [policyJson] 解析）；解析不出时 null。
  String? get groupId => chatScheduleGroupIdFromPolicy(policyJson);

  /// 是否仍在等待触发（未停用且未用完次数）。
  ///
  /// 与停用端点的 SQL 谓词同口径（`enabled = 1 AND run_count < max_runs`），
  /// 故「可停用的那些」就是本 getter 为真的那些——面板据此决定停用按钮
  /// 是否可点，与服务端实际会撤销的集合一致。
  bool get isPending => enabled && runCount < maxRuns;

  factory ChatTurnSchedule.fromJson(Map<String, dynamic> json) =>
      ChatTurnSchedule(
        id: (json['id'] as String?) ?? '',
        agentId: (json['agentId'] as String?) ?? '',
        sessionId: (json['sessionId'] as String?) ?? '',
        agentType: (json['agentType'] as String?) ?? '',
        triggerReason: (json['triggerReason'] as String?) ?? '',
        triggerStatus: chatScheduleNullString(json['triggerStatus']),
        message: (json['message'] as String?) ?? '',
        policyJson: (json['policyJson'] as String?) ?? '',
        dedupeKey: (json['dedupeKey'] as String?) ?? '',
        enabled: json['enabled'] == true,
        runCount: _int(json['runCount']),
        maxRuns: _int(json['maxRuns']),
        nextRunAt: chatScheduleNullTime(json['nextRunAt']),
        lastRunAt: chatScheduleNullTime(json['lastRunAt']),
        lastErrorJson: chatScheduleNullString(json['lastErrorJson']),
        createdAt: _date(json['createdAt']) ?? DateTime.now(),
        updatedAt: _date(json['updatedAt']) ?? DateTime.now(),
      );

  /// 取整数；非 num / 字符串数字均可解析，其余归 0（与 `ChatTurn._int` 同取向）。
  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _date(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }
}
