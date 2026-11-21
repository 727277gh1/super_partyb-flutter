/// 跨 group 的待确认收件箱项（`GET /chat/confirmations`）。
///
/// 对应 Go 侧 `global_confirmations.go` 的 `scanConfirmationToListItem` 输出，
/// 直接查 `chat_confirmations` 表（**不是** chat_events）。字段名沿用服务端的
/// snake_case（与 `ChatGroup` 同一约定），客户端做映射，**不试图统一**。
///
/// ## 为什么是强类型而非裸 Map
///
/// `ChatApi.listConfirmations` 返回 `List<Map<String, dynamic>>`（历史遗留），
/// 调用方无法在编译期发现字段漂移。本类把字段名固定下来：服务端若改名，
/// `fromJson` 解析时得到 null（而不是一个永远匹配不上的魔法字符串键），
/// 测试也会立刻暴露。
///
/// ## `decision` 字段
///
/// 存的是签发时的确认快照（`EnsureConfirmationCard` 写的 `decision_json`）：
/// `{decision, confidence, reason}`。`reason` 是给用户看的问题正文。
/// 解析失败时 [reason] 回退到「需要确认」。
library;

class ChatConfirmation {
  const ChatConfirmation({
    required this.id,
    required this.turnId,
    required this.groupId,
    required this.userId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.agentId,
    this.sessionId,
    this.recommendationAction,
    this.confidence,
    this.decision,
    this.resolvedAction,
    this.resolvedComment,
    this.resolvedBy,
    this.expiresAt,
    this.resolvedAt,
    this.updatedAt,
  });

  /// 卡行 id（`chat_confirmations.id`）。调 resolve 端点用它。
  final String id;

  /// 所属轮次与 group。跳转回对话用 [groupId]。
  final String turnId;
  final String groupId;
  final String userId;

  /// agent / session（可空）。
  final String? agentId;
  final String? sessionId;

  /// 种类（如 `continue_suggestion`）。
  final String kind;

  /// 推荐动作（如 `continue`）。
  final String? recommendationAction;
  final double? confidence;

  /// 签发时的确认快照（`decision_json` 解析后的对象）。
  ///
  /// 形如 `{decision: "need_confirmation", confidence: 0.9, reason: "..."}`。
  /// [reason] 从中提取。
  final Map<String, dynamic>? decision;

  /// `pending` / `resolved` / `expired` / `cancelled`。
  final String status;

  final String? resolvedAction;
  final String? resolvedComment;
  final String? resolvedBy;
  final DateTime? expiresAt;
  final DateTime? resolvedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  /// 给用户看的问题正文：优先 `decision.reason`，否则兜底。
  String get reason {
    final d = decision;
    if (d != null) {
      final r = d['reason'];
      if (r is String && r.trim().isNotEmpty) return r;
    }
    return '需要确认';
  }

  /// 是否仍未解决（含未过期判定由服务端保证；此处仅按状态）。
  bool get isPending => status == 'pending';

  factory ChatConfirmation.fromJson(Map<String, dynamic> json) {
    return ChatConfirmation(
      id: (json['id'] as String?) ?? '',
      turnId: (json['turn_id'] as String?) ?? '',
      groupId: (json['group_id'] as String?) ?? '',
      userId: (json['user_id'] as String?) ?? '',
      agentId: json['agent_id'] as String?,
      sessionId: json['session_id'] as String?,
      kind: (json['kind'] as String?) ?? '',
      recommendationAction: json['recommendation_action'] as String?,
      confidence: (json['confidence'] is num)
          ? (json['confidence'] as num).toDouble()
          : null,
      decision: _asMap(json['decision']),
      status: (json['status'] as String?) ?? 'pending',
      resolvedAction: json['resolved_action'] as String?,
      resolvedComment: json['resolved_comment'] as String?,
      resolvedBy: json['resolved_by'] as String?,
      expiresAt: _date(json['expires_at']),
      resolvedAt: _date(json['resolved_at']),
      createdAt: _date(json['created_at']) ?? DateTime.now(),
      updatedAt: _date(json['updated_at']),
    );
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static DateTime? _date(Object? v) =>
      DateTime.tryParse((v as String?) ?? '')?.toLocal();
}
