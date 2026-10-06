/// 「我的最近轮次」列表项（`GET /me/turns`）。
///
/// 对应 Go 侧 `user_turns.go` 的 `turnToListItem` 输出。
///
/// ## 为什么不是 `ChatTurn`
///
/// `ChatTurn` 镜像的是 `turnToDict`（单轮次端点 `GET /chat/turns/:id`），字段是
/// `input_text` / `fanout_count` / `completed_count` / `error_count` / `metadata`。
/// 本列表用的是**另一套投影**（`turnToListItem`）：`turn_id` / `input_preview`
/// / `derived_source` / `has_error` / `message_count` / `group_title`。
/// 两者字段名与语义都不同，混用会解析出全空对象（且不报错）。
///
/// ## 字段名照抄服务端（snake_case）
///
/// 与 `ChatGroup` / `ChatConfirmation` 同一约定：各自照抄服务端，映射在此做。
library;

/// 轮次来源（服务端 `derived_source`，5 类）。
///
/// `habit` 优先于其它：一个 habit 触发的轮次即使 DB `source` 是 `direct`，
/// 派生结果也是 `habit`（见后端 `deriveTurnSource`）。
enum TurnSource {
  chat,
  mq,
  schedule,
  habit,
  toolAgent,
  unknown;

  /// 服务端字符串 → 枚举。未知值落到 [unknown]（向前兼容，不抛）。
  static TurnSource fromServer(String? raw) => switch (raw) {
    'chat' => TurnSource.chat,
    'mq' => TurnSource.mq,
    'schedule' => TurnSource.schedule,
    'habit' => TurnSource.habit,
    'tool_agent' => TurnSource.toolAgent,
    _ => TurnSource.unknown,
  };

  /// 服务端 `?source=` 过滤参数的取值（与 [fromServer] 严格互逆）。
  ///
  /// 需要它是因为枚举名与 wire 值**不是**同名映射：`toolAgent` ↔
  /// `tool_agent`。写成 `source.name` 会发出 `toolAgent`，服务端 `switch source`
  /// 落不到 `tool_agent` 分支 → 该过滤器静默失效（返回未过滤结果，不报错）。
  ///
  /// [unknown] 是「认不出的服务端值」占位，不是可筛选项，故返回空串
  /// （调用方应据此跳过该参数）。
  String get wire => switch (this) {
    TurnSource.chat => 'chat',
    TurnSource.mq => 'mq',
    TurnSource.schedule => 'schedule',
    TurnSource.habit => 'habit',
    TurnSource.toolAgent => 'tool_agent',
    TurnSource.unknown => '',
  };

  /// 中文标签（列表徽标展示）。
  String get label => switch (this) {
    TurnSource.chat => '对话',
    TurnSource.mq => '消息',
    TurnSource.schedule => '定时',
    TurnSource.habit => '习惯',
    TurnSource.toolAgent => '工具',
    TurnSource.unknown => '其它',
  };
}

class ChatTurnSummary {
  const ChatTurnSummary({
    required this.turnId,
    required this.groupId,
    required this.inputPreview,
    required this.status,
    required this.source,
    required this.createdAt,
    this.groupTitle,
    this.rawSource,
    this.startedAt,
    this.endedAt,
    this.hasError = false,
    this.messageCount = 0,
  });

  /// 轮次 id（服务端键名 `turn_id`，**不是** `id`）。
  final String turnId;

  /// 所属对话，用于点击跳转。
  final String groupId;

  /// 对话标题（服务端批量补齐）。可能为 null（对话已删等）。
  final String? groupTitle;

  /// 输入摘要（服务端截断到 200 字符）。
  final String inputPreview;

  /// `queued` / `running` / `pending` / `completed` / `failed` / `cancelled`。
  ///
  /// ⚠️ 取消态是**英式**拼写 `cancelled`（`domain.go` 的 `TurnStatusCanceled`
  /// 与 schema CHECK 约束都是英式），不是 `canceled`。按美式拼写比较会永远
  /// 落空，界面把已取消的轮次显示成「已完成」。
  final String status;

  /// 派生来源（展示用）。
  final TurnSource source;

  /// DB 原始 source（`direct` / `bridge` / `schedule`），诊断用。
  final String? rawSource;

  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// 该轮是否有失败（服务端 `error_count > 0`）。
  final bool hasError;

  /// 已完成消息数（服务端 `completed_count`）。
  final int messageCount;

  bool get isRunning => status == 'running' || status == 'queued';
  bool get isFailed => status == 'failed' || hasError;

  factory ChatTurnSummary.fromJson(Map<String, dynamic> json) =>
      ChatTurnSummary(
        turnId: (json['turn_id'] as String?) ?? '',
        groupId: (json['group_id'] as String?) ?? '',
        groupTitle: json['group_title'] as String?,
        inputPreview: (json['input_preview'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'queued',
        source: TurnSource.fromServer(json['derived_source'] as String?),
        rawSource: json['source'] as String?,
        createdAt: _date(json['created_at']) ?? DateTime.now(),
        startedAt: _date(json['started_at']),
        endedAt: _date(json['ended_at']),
        hasError: json['has_error'] == true,
        messageCount: _int(json['message_count']),
      );

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _date(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }
}
