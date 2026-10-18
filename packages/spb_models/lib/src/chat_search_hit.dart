/// 搜索命中项。
///
/// 对应 Go 侧 `search` 端点（`internal/server/chat_stream.go`）返回的 **turn 摘要**。
///
/// ## 为什么必须单独建模，不能复用 `ChatEvent`
///
/// 该端点的响应形状是 turn 摘要，**不是**事件：
///
/// ```json
/// {"turn_id": "...", "group_id": "...", "group_title": "...",
///  "input_text": "...", "created_at": "...", "agent_id": "..."}
/// ```
///
/// 而 `ChatEvent` 要求 `event_id` / `event_type`（它按事件归约设计）。
/// 用 `ChatEvent.fromJson` 解析这里的每一项都会**抛 `FormatException`**——
/// 这是「端点名字像聊天、返回的却不是事件」的典型陷阱。
///
/// 另注意字段名是 **snake_case**（`turn_id` / `input_text`），与 `ChatEvent`
/// 的 camelCase 不同。各自照抄服务端，映射在客户端做。
///
/// ## 关于 `group_title` 与 `agent_id` 可能为空
///
/// - `group_title`：服务端用 `ListChatGroupsByUser(status: "active")` 建标题表
///   （上限 500 条），**已归档或超出上限的 group 取不到标题**，于是该键的值为
///   Go 的零值 `""`（map 查不到不报错，写入空串）。故客户端必须容忍空标题。
/// - `agent_id`：服务端从 `turn.metadata_json.targets[0].agent_id` 提取，
///   无 targets 时返回 `nil`（JSON `null`）。
final class ChatSearchHit {
  const ChatSearchHit({
    required this.turnId,
    required this.groupId,
    required this.groupTitle,
    required this.inputText,
    this.createdAt,
    this.agentId,
    this.raw = const {},
  });

  /// 命中的轮次 id（`chat_turns.id`）。
  final String turnId;

  /// 该轮次所属对话。点击命中项跳转到它。
  final String groupId;

  /// 对话标题。**可能为空**（见类文档：归档或超出 500 条上限时取不到）。
  final String groupTitle;

  /// 命中的用户输入文本。
  ///
  /// 服务端在 **200 字符**处截断（`text[:200]`），故它可能是不完整的片段，
  /// 展示时不要假设它等于完整消息。
  final String inputText;

  /// 轮次创建时间。解析失败时为 null（不回退 `now()`，那会让「没有时间」的
  /// 条目看起来像刚刚创建）。
  final DateTime? createdAt;

  /// 该轮次的目标 agent id（`metadata_json.targets[0].agent_id`）。可能为 null。
  final String? agentId;

  /// 原始响应，保留未建模字段以备调试与将来扩展。
  final Map<String, dynamic> raw;

  /// 标题为空时的兜底展示文本。
  String get displayTitle => groupTitle.isEmpty ? '（未命名对话）' : groupTitle;

  factory ChatSearchHit.fromJson(Map<String, dynamic> json) => ChatSearchHit(
    turnId: (json['turn_id'] ?? '').toString(),
    groupId: (json['group_id'] ?? '').toString(),
    groupTitle: (json['group_title'] ?? '').toString(),
    inputText: (json['input_text'] ?? '').toString(),
    createdAt: _date(json['created_at']),
    agentId: _nonEmpty(json['agent_id']),
    raw: json,
  );

  /// 空串按「未提供」处理（服务端 `group_title` 缺失时写入 Go 零值 `""`）。
  static String? _nonEmpty(Object? v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  static DateTime? _date(Object? v) {
    final s = v?.toString();
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  @override
  String toString() =>
      'ChatSearchHit(turn=$turnId, group=$groupId, "$groupTitle")';
}
