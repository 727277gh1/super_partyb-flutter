/// 用户记忆（`user_memories` 行）契约。
///
/// 真源：
/// - `super_partyb/apps/go-api/internal/db/queries/models.go` 的 `UserMemory`
///   （sqlc 生成，JSON tag 是 **camelCase**）；
/// - `internal/server/misc.go` 的 `memHandlers`（`GET /api/memories` 直接把它
///   序列化成 `{items: [...]}`，`PATCH` 返回整条对象，`DELETE` 返回
///   `{id, status:"archived"}`）。
///
/// ## 三个真实存在的形状问题（不是冗余防御）
///
/// 1. `contentJson` / `sourceGroupId` / `sourceTurnId` 是 `sql.NullString`，
///    Go 标准库**没有**自定义 MarshalJSON → 实际 JSON 是
///    `{"String":"x","Valid":true}`，不是裸串。直接当字符串读会拿到一个 Map。
/// 2. `lastReinforcedAt` 是 `sql.NullTime` → `{"Time":"…","Valid":true}`。
/// 3. `/api/memories`（内部面）发 camelCase，而 webapp / 小程序的类型声明写的是
///    snake_case（`user_id` / `source_group_id` / `last_reinforced_at`）。两份
///    形状都真实存在过，故 [fromJson] 同时接受两种键名。
///
/// 处理手法与 `habit.dart` 的 `habitNullString` / `habitNullTime` 一致——
/// 那套 helper 是 `habit.dart` 的 library-private，不能跨包复用，故本文件自带
/// 一份最小实现（`_memNullString` / `_memNullTime`）。
library;

/// 记忆分类（`user_memories.category`）。
///
/// 真源：`internal/server/open_api.go` 的 `memoryCategories`（与 schema CHECK 对齐）。
enum UserMemoryCategory {
  fact('fact', '事实'),
  preference('preference', '偏好'),
  goal('goal', '目标'),
  state('state', '状态'),
  unknown('', '未分类');

  const UserMemoryCategory(this.wire, this.label);

  /// 服务端字面量（发请求时用）。
  final String wire;

  /// 界面文案。
  final String label;

  static UserMemoryCategory from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 记忆状态（`user_memories.status`）。
///
/// `DELETE /api/memories/:id` 是**归档**（软删），不是物理删除；归档后提取器
/// 不再据此学习，但可用 `PATCH status=active` 恢复。
enum UserMemoryStatus {
  active('active', '生效中'),
  archived('archived', '已归档'),
  dismissed('dismissed', '已忽略'),
  unknown('', '未知');

  const UserMemoryStatus(this.wire, this.label);

  final String wire;
  final String label;

  static UserMemoryStatus from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 一条用户记忆。
class UserMemory {
  const UserMemory({
    required this.id,
    this.userId = '',
    this.category = UserMemoryCategory.unknown,
    this.topicKey = '',
    this.topicId = '',
    this.content = '',
    this.contentJson = '',
    this.sourceGroupId,
    this.sourceTurnId,
    this.confidence = 0,
    this.learnedFromTurns = 0,
    this.status = UserMemoryStatus.unknown,
    this.lastReinforcedAt,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String userId;
  final UserMemoryCategory category;

  /// 主题键（`weekly-report` 这类稳定标识，同 topic 的条目由服务端去重）。
  final String topicKey;

  /// 主题 id（服务端解析 `topicKey` 后写入，客户端只读）。
  final String topicId;

  /// 记忆正文（用户可编辑的就是这一段）。
  final String content;

  /// 提取器附带的结构化载荷（原始 JSON 字符串；客户端只保留不展示）。
  final String contentJson;

  /// 学到这条记忆的对话。
  final String? sourceGroupId;

  /// 学到这条记忆的轮次。
  final String? sourceTurnId;

  /// 置信度（0–1）。服务端默认 0.5，随复述次数上升。
  final double confidence;

  /// 被多少轮对话学到过。
  final int learnedFromTurns;

  final UserMemoryStatus status;

  /// 最近一次被复述/强化的时刻。
  final DateTime? lastReinforcedAt;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// 原始 JSON（保留客户端未建模的字段，便于排障与将来扩展）。
  final Map<String, dynamic> raw;

  bool get isActive => status == UserMemoryStatus.active;

  /// 是否来自某次对话学习（`false` = 手动新建或来源字段缺失）。
  bool get hasSource => sourceGroupId != null;

  factory UserMemory.fromJson(Map<String, dynamic> json) {
    final content = _memStr(json, 'content', 'content') ?? '';
    return UserMemory(
      id: _memStr(json, 'id', 'id') ?? '',
      userId: _memStr(json, 'userId', 'user_id') ?? '',
      category: UserMemoryCategory.from(_memStr(json, 'category', 'category')),
      topicKey: _memStr(json, 'topicKey', 'topic_key') ?? '',
      topicId: _memStr(json, 'topicId', 'topic_id') ?? '',
      content: content,
      // 同样是 `sql.NullString`（键名较抖：`contentJson` / `content_json`）。
      contentJson: _memNullString(json, 'contentJson', 'content_json') ?? '',
      sourceGroupId: _memNullString(json, 'sourceGroupId', 'source_group_id'),
      sourceTurnId: _memNullString(json, 'sourceTurnId', 'source_turn_id'),
      confidence: _memDouble(json, 'confidence', 'confidence') ?? 0,
      learnedFromTurns:
          _memInt(json, 'learnedFromTurns', 'learned_from_turns') ?? 0,
      status: UserMemoryStatus.from(_memStr(json, 'status', 'status')),
      lastReinforcedAt: _memNullTime(
        json,
        'lastReinforcedAt',
        'last_reinforced_at',
      ),
      createdAt: _memNullTime(json, 'createdAt', 'created_at'),
      updatedAt: _memNullTime(json, 'updatedAt', 'updated_at'),
      raw: json,
    );
  }

  /// 复制并覆盖少数字段（编辑后本地回写用，避免整条重新解析）。
  UserMemory copyWith({
    String? content,
    UserMemoryCategory? category,
    UserMemoryStatus? status,
  }) {
    return UserMemory(
      id: id,
      userId: userId,
      category: category ?? this.category,
      topicKey: topicKey,
      topicId: topicId,
      content: content ?? this.content,
      contentJson: contentJson,
      sourceGroupId: sourceGroupId,
      sourceTurnId: sourceTurnId,
      confidence: confidence,
      learnedFromTurns: learnedFromTurns,
      status: status ?? this.status,
      lastReinforcedAt: lastReinforcedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      raw: raw,
    );
  }
}

// ==================== JSON 归一 helper ====================

String? _memStr(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v == null) return null;
  final s = v is String ? v : v.toString();
  return s.isEmpty ? null : s;
}

int? _memInt(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _memDouble(Map<String, dynamic> json, String camel, String snake) {
  final v = json[camel] ?? json[snake];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// 归一 `sql.NullString` 的 JSON 形态（`{"String":..,"Valid":..}` / 裸串 / null）。
String? _memNullString(Map<String, dynamic> json, String camel, String snake) {
  final v = json.containsKey(camel) ? json[camel] : json[snake];
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final s = v['String'] ?? v['string'];
    if (s is String && s.isNotEmpty) return s;
  }
  return null;
}

/// 归一 `sql.NullTime` 的 JSON 形态（`{"Time":..,"Valid":..}` / 裸串 / null）。
///
/// `Valid:false` **必须**返回 null：否则会得到零值 `0001-01-01`，界面会显示成
/// 「1970 年学过这条」而不是「从未强化」。
DateTime? _memNullTime(Map<String, dynamic> json, String camel, String snake) {
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
      // 零值（`0001-01-01T00:00:00Z`）即使 Valid:true 也应视为无值。
      if (parsed.year <= 1) return null;
      return parsed.toLocal();
    }
  }
  return null;
}
