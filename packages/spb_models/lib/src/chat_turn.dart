/// 对话轮次（ChatTurn）。
///
/// 对应 Go 侧 `turnToDict`（`internal/server/chat.go`）。状态机：
/// `queued → running → completed | failed | canceled`
/// （另有 `pending` 表示等待用户确认，属通用 TTL 回收范畴）。
class ChatTurn {
  const ChatTurn({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.inputText,
    required this.status,
    required this.fanoutCount,
    required this.completedCount,
    required this.errorCount,
    required this.createdAt,
    this.requestId,
    this.metadata,
    this.channel,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String groupId;
  final String userId;

  /// 客户端幂等键。**同一 requestId 重复提交不会新建 turn**（MQ 重投防护）。
  final String? requestId;

  final String inputText;
  final String status;
  final int fanoutCount;
  final int completedCount;
  final int errorCount;

  /// 已由服务端 `scrubTurnMetadata` 清洗（剔除 `_forward_headers` 等凭据键）。
  final Map<String, dynamic>? metadata;

  /// 来源渠道（`webapp` / `wechat_ilink` / `desktop` 等）。
  final String? channel;

  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  bool get isQueued => status == 'queued';
  bool get isRunning => status == 'running';
  bool get isPending => status == 'pending';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isCanceled => status == 'canceled';

  /// 是否已终结（不再产生事件）。
  bool get isTerminal => isCompleted || isFailed || isCanceled;

  /// 轮次耗时。进行中时以当前时间计算。
  Duration? get duration {
    final start = startedAt;
    if (start == null) return null;
    return (endedAt ?? DateTime.now()).difference(start);
  }

  factory ChatTurn.fromJson(Map<String, dynamic> json) => ChatTurn(
    id: (json['id'] as String?) ?? '',
    groupId: (json['group_id'] as String?) ?? '',
    userId: (json['user_id'] as String?) ?? '',
    requestId: json['request_id'] as String?,
    inputText: (json['input_text'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'queued',
    fanoutCount: _int(json['fanout_count']),
    completedCount: _int(json['completed_count']),
    errorCount: _int(json['error_count']),
    metadata: _asMap(json['metadata']),
    channel: json['channel'] as String?,
    createdAt: _date(json['created_at']) ?? DateTime.now(),
    startedAt: _date(json['started_at']),
    endedAt: _date(json['ended_at']),
  );

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static DateTime? _date(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }
}
