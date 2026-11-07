/// 收件箱消息（ChatInboxMessage）。
///
/// 对应 Go 侧 `inboxToDict`（`internal/server/chat_inbox.go`）。
///
/// ## 为什么必须与 [ChatTurn] 分开建模
///
/// `GET /users/:uid/chat/messages/pending` 的路径名会让人以为它返回 turn，实际
/// 返回的是 **`chat_inbox_messages` 行**——一个「消息先进收件箱、再由 dispatcher
/// 合并成 turn」的两段式模型。两者字段名不同（`input` vs `input_text`），
/// 用 `ChatTurn.fromJson` 解析会得到**全空字段且不报错**（缺失键走安全默认值）。
///
/// ## 状态机
///
/// 取值来自 `db/queries/domains.sql` 与 `internal/server/chat_inbox.go`：
///
/// | status | 含义 | 终态 |
/// |---|---|---|
/// | `pending` | 已入收件箱，尚未被 dispatcher 消费 | 否 |
/// | `committed` | 已合并成 turn（`turn_id` 有值，`result` 含 strategy） | 是 |
/// | `superseded` | 被后续消息合并取代（同批里非最新的那条） | 是 |
/// | `withdrawn` | 用户主动撤回（`POST .../undo`） | 是 |
///
/// 用 String 而非 enum：服务端新增状态时旧客户端不应解析失败。
class ChatInboxMessage {
  const ChatInboxMessage({
    required this.id,
    required this.userId,
    required this.input,
    required this.status,
    required this.agentType,
    required this.createdAt,
    required this.updatedAt,
    this.groupId,
    this.requestId,
    this.agentId,
    this.turnId,
    this.payload,
    this.result,
    this.processedAt,
  });

  final String id;
  final String userId;

  /// 消息正文。
  ///
  /// ⚠️ **不是** `input_text`——那是 `ChatTurn` 的字段名。服务端此处键名是 `input`。
  final String input;

  /// `pending` / `committed` / `superseded` / `withdrawn`。见类文档的状态机表。
  final String status;

  /// 目标 agent 类型（`claude` / `pigo` 等），来自 `chat_inbox_messages.agent_type`。
  final String agentType;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 归属 group。**可为 null**：入收件箱时归属可能尚未判定。
  final String? groupId;

  /// 客户端幂等键（同一 requestId 的消息会被 dispatcher 合并）。
  final String? requestId;

  final String? agentId;

  /// 合并成的 turn ID。仅在 [isCommitted] 时有值。
  final String? turnId;

  /// 附加负载（如 `{"source":"bridge","channel":"wechat_ilink"}`）。
  final Map<String, dynamic>? payload;

  /// 处理结果。`committed` 时形如 `{"status":"committed","strategy":"...","turn_id":"..."}`。
  final Map<String, dynamic>? result;

  /// 处理完成时间。未处理时为 null。
  final DateTime? processedAt;

  bool get isPending => status == 'pending';
  bool get isCommitted => status == 'committed';
  bool get isSuperseded => status == 'superseded';
  bool get isWithdrawn => status == 'withdrawn';

  /// 是否已离开 `pending`（不再等待处理）。
  bool get isProcessed => !isPending;

  /// 是否可被撤回——服务端 `WithdrawChatInboxMessage` 的 WHERE 子句限定
  /// `status = 'pending'`，客户端据此决定是否展示撤回入口，避免必然失败的请求。
  bool get isWithdrawable => isPending;

  factory ChatInboxMessage.fromJson(Map<String, dynamic> json) =>
      ChatInboxMessage(
        id: (json['id'] as String?) ?? '',
        userId: (json['user_id'] as String?) ?? '',
        input: (json['input'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'pending',
        agentType: (json['agent_type'] as String?) ?? '',
        createdAt: _date(json['created_at']) ?? DateTime.now(),
        updatedAt: _date(json['updated_at']) ?? DateTime.now(),
        groupId: _str(json['group_id']),
        requestId: _str(json['request_id']),
        agentId: _str(json['agent_id']),
        turnId: _str(json['turn_id']),
        payload: _asMap(json['payload']),
        result: _asMap(json['result']),
        processedAt: _date(json['processed_at']),
      );

  /// 服务端 `nullStr` 把空值产出为 JSON null；`iso` 把零值时间产出为**空串**。
  /// 两者都要归一成 null，避免出现 `''` 这种「假有值」。
  static String? _str(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return v;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static DateTime? _date(Object? v) {
    final s = v is String ? v : null;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  @override
  String toString() =>
      'ChatInboxMessage($id, status=$status, group=$groupId, '
      'input=${input.length} chars)';
}
