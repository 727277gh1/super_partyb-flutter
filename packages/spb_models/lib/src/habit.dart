/// 习惯（habit）契约。
///
/// ## 端点来源（逐条核实，非推测）
///
/// 全部来自 `super_partyb/apps/go-api/internal/server/`：
///
/// | 方法 | 路径 | 处理器 |
/// |---|---|---|
/// | GET | `/api/habits?limit=&offset=` | `ext_routes.go` registerHabitRoutes → list |
/// | GET | `/api/habits/:pattern_id` | 同上 → get |
/// | GET | `/api/habits/runs?days=&limit=&trigger_reason=` | 同上 → allRuns |
/// | GET | `/api/habits/:pattern_id/runs` | 同上 → runs |
/// | POST | `/api/habits` | `habits_full.go` → create |
/// | PATCH | `/api/habits/:pattern_id` | 同上 → update |
/// | POST | `/api/habits/:pattern_id/trigger` \| `/pause` \| `/resume` \| `/archive` | 同上 |
/// | GET | `/api/chat/habit-suggestions?status=pending\|dismissed` | `misc_extra.go` |
/// | POST | `/api/chat/habit-suggestions/:suggestion_id/resolve` \| `/unresolve` | 同上 |
/// | GET | `/api/chat/habit-insights/summary?days=` | `habit_insights.go` |
///
/// 两者都挂在 `/api` 组下（`ext_routes.go`），故经 api-gateway 时前缀是
/// `/pba/api/...`；`SpbEndpoints.current.apiBaseUrl` 已含 `/pba`，各方法拼的路径以 `/api/` 开头。
///
/// ⚠️ **`/me/habits` 只有 create 与 trigger 两个别名**
/// （`registerUserHabitAliasRoutes`），列表/详情/更新都在 `/api/habits` 下。
///
/// ## `trigger_context` / `feedback_payload` 的两个形状
///
/// 候选建议列表（`habitRunToMap`）下发**对象**，执行记录
/// （`habitRunsWithReply`）下发 `*_json` **字符串**。用 `habitStr` 读对象形态会
/// 得到不合法的 JSON 文本，下游解析失败后被静默吃掉（见 [habitJsonString]）。
///
/// ## 命名是双形态，且有两处「裸列名」陷阱
///
/// `list` 直接序列化 sqlc 生成的 `queries.HabitPattern`，JSON tag 是
/// **camelCase**（`triggerConfigJson` / `topicKey` / `acceptanceLevel` /
/// `nextFireAt` …），与 webapp `user-habits.ts` 声明的 snake_case **不一致**
/// （webapp 那份是 Python 时代的形状，Go 版没跟）。
///
/// 而 `allRuns` 是**手写 gin.H**（`habitRunsWithReply`），用 snake_case
/// （`run_id` / `topic_key` / `trigger_reason` / `reply_text` …）。
///
/// 故本文件的 `fromJson` 都**同时接受两种命名**——这不是冗余防御，而是两份
/// 真实存在的序列化形状（同 `ChatEvent` 的 camelCase/snake_case 双形态问题）。
library;

import 'dart:convert';

part 'habit_entity.dart';
part 'habit_pattern.dart';
part 'habit_run.dart';
part 'habit_suggestion.dart';

/// 归一 `sql.NullString` 的 JSON 形态（`{"String":..,"Valid":..}` / 裸串 / null）。
String? habitNullString(Object? v) {
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final s = v['String'] ?? v['string'];
    if (s is String && s.isNotEmpty) return s;
  }
  return null;
}

/// 双形态取字符串：`json[camel] ?? json[snake]`。
String? habitStr(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v == null) return null;
  final s = v is String ? v : v.toString();
  return s.isEmpty ? null : s;
}

int? habitInt(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? habitDouble(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool? habitBool(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return null;
}

/// 服务端时间是 `domain.ISO`（RFC3339 UTC 字符串），非 epoch。
DateTime? habitDate(Map<String, dynamic> json, String camel, String snake) {
  final s = habitStr(json, camel, snake);
  if (s == null) return null;
  return DateTime.tryParse(s)?.toLocal();
}

/// 取「JSON 对象」或「JSON 字符串」两种形态的字段，统一归一为**字符串**。
///
/// ## 为什么需要这个（不是冗余防御）
///
/// 服务端两个端点对同一份数据下发了**不同的形状与键名**：
///
/// | 端点 | 键名 | 类型 |
/// |---|---|---|
/// | `habitRunToMap`（候选建议列表） | `trigger_context` / `feedback_payload` | **对象** |
/// | `habitRunsWithReply`（执行记录） | `trigger_context_json` / `feedback_payload_json` | 字符串 |
///
/// 只用 `habitStr` 读对象形态会得到 Dart 的 `Map.toString()`
/// （`{topic_key: x}`——**键无引号，不是合法 JSON**），下游 `jsonDecode` 抛
/// `FormatException` 后被当成「无上下文」静默吃掉：表现为候选卡显示「未命名」、
/// 无理由，已处理项显示不出「习惯已生效」。比 500 更难发现。
///
/// 故这里把对象形态 `jsonEncode` 回字符串，下游的 `_decodeJsonObject` 保持不变。
String? habitJsonString(Map<String, dynamic> json, String key) {
  final v = json[key] ?? json['${key}_json'];
  if (v == null) return null;
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map || v is List) return jsonEncode(v);
  return null;
}

Map<String, dynamic> habitMap(
  Map<String, dynamic> json,
  String camel,
  String snake,
) {
  final v = json[camel] ?? json[snake];
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return const {};
}

Map<String, dynamic>? habitMapOrNull(
  Map<String, dynamic> json,
  String camel,
  String snake,
) {
  final v = json[camel] ?? json[snake];
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return null;
}

List<String> habitStrList(
  Map<String, dynamic> json,
  String camel,
  String snake,
) {
  final v = json[camel] ?? json[snake];
  if (v is! List) return const [];
  return v
      .map((e) => e is String ? e : e?.toString() ?? '')
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
}

/// 归一 `sql.NullString` 形态的**可选**字段（双形态键名）。
String? habitNullString2(
  Map<String, dynamic> json,
  String camel,
  String snake,
) {
  final v = json.containsKey(camel) ? json[camel] : json[snake];
  return habitNullString(v);
}
