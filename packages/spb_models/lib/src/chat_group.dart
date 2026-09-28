/// 对话分组（ChatGroup）。
///
/// 对应 Go 侧 `groupRowToDict`（`internal/server/chat.go`）的响应结构。
/// 注意：服务端返回 **snake_case** 键名（历史沿袭 Python 版），与 `ChatEvent`
/// 的 camelCase 不同——这是既有事实，客户端做映射，**不要试图统一**。
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.userId,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.goal,
    this.metadata,
    this.activeSession,
    this.currentGoal,
  });

  final String id;
  final String userId;
  final String title;

  /// `active` / `archived`。
  final String status;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 分组的顶层目标描述（可能为空）。
  final String? goal;

  /// 自由元数据。关键键：
  /// - `follow_up_suggest.enabled`：后续提问建议开关（group 级）
  /// - `tts.narrate_thinking` / `tts.file_summary`：TTS 行为开关
  /// 值可能是嵌套 map，故用 `Object?` 而非 `String`。
  final Map<String, dynamic>? metadata;

  /// 当前活跃会话（agent 绑定）。
  final ActiveSession? activeSession;

  /// 当前 goal 快照（`GET /goals/current` 同结构）。
  final Map<String, dynamic>? currentGoal;

  bool get isArchived => status == 'archived';

  /// 后续提问建议是否对本 group 启用。
  ///
  /// 注意这是**双层开关**：group 级 metadata 之外还有全局 `FOLLOW_UP_SUGGEST_ENABLED`。
  /// 客户端只反映 group 级状态，全局关闭时即使此处为 true 也不会收到事件。
  bool get followUpSuggestEnabled {
    final v = metadata?['follow_up_suggest'];
    if (v is Map) return v['enabled'] == true;
    return false;
  }

  factory ChatGroup.fromJson(Map<String, dynamic> json) => ChatGroup(
    id: (json['id'] as String?) ?? '',
    userId: (json['user_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'active',
    goal: json['goal'] as String?,
    metadata: _asMap(json['metadata']),
    activeSession: ActiveSession.maybeFromJson(json['active_session']),
    currentGoal: _asMap(json['current_goal']),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
  );

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static DateTime _date(Object? v) =>
      DateTime.tryParse((v as String?) ?? '')?.toLocal() ?? DateTime.now();
}

/// group 中当前活跃的 agent 会话。
class ActiveSession {
  const ActiveSession({
    required this.agentId,
    this.sessionId,
    this.agentSessionId,
    this.role,
    this.joinedAt,
  });

  final String agentId;
  final String? sessionId;

  /// pigo 侧会话 ID，用于 `-r` 续接。
  final String? agentSessionId;
  final String? role;
  final DateTime? joinedAt;

  static ActiveSession? maybeFromJson(Object? v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    final agentId = m['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return null;
    return ActiveSession(
      agentId: agentId,
      sessionId: m['session_id'] as String?,
      agentSessionId: m['agent_session_id'] as String?,
      role: m['role'] as String?,
      joinedAt: DateTime.tryParse((m['joined_at'] as String?) ?? '')?.toLocal(),
    );
  }
}
