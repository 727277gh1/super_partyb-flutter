import 'event_types.dart';

/// 聊天事件（SSE 推送与持久化共用）。
///
/// 对应 Go 侧 `chatbus.Event`。字段名逐一对齐 JSON tag，**不要重命名**——
/// 服务端是唯一真源，客户端只做映射。
class ChatEvent {
  const ChatEvent({
    required this.eventId,
    required this.userId,
    required this.groupId,
    required this.turnId,
    required this.eventType,
    required this.seq,
    required this.source,
    required this.createdAt,
    this.sessionId,
    this.agentId,
    this.globalSeq,
    this.payload,
    this.transient = false,
    this.diagnostic = false,
  });

  /// 事件唯一 ID（= chat_events.id）。SSE 断线重连的 cursor 就用它。
  final String eventId;
  final String userId;
  final String groupId;
  final String turnId;
  final String? sessionId;
  final String? agentId;

  /// 事件类型。见 [EventTypes]。用 String 而非 enum 以容忍服务端新增类型。
  final String eventType;

  /// per-turn 单调序（每个 turn 从 1 重来）。
  final int seq;

  /// 跨 turn 的全局单调序（落库分配）。
  ///
  /// **排序与分页游标应使用本字段**，而非 [seq]（per-turn）或 [createdAt]
  /// （仅毫秒精度，无法唯一定义先后）。Transient 事件不落库，此值为 null。
  final int? globalSeq;

  final String source;
  final DateTime createdAt;

  /// 事件负载。结构随 [eventType] 变化，各类型的访问器见下文。
  final Map<String, dynamic>? payload;

  /// `true` 表示「通知型」事件：仅广播给实时消费者，不持久化。
  ///
  /// 两类用法：
  /// 1. **流式增量片段**：`message`/`thought` 的增量帧。收到时应「追加/累加」；
  ///    权威帧（`transient == false`）应「替换」。这是渲染正确性的关键区分。
  /// 2. **状态变更通知**：`goal_updated` 等，真源在业务表，事件只提示「数据过期了」。
  ///
  /// 代价：断线期间这类事件会丢。第 2 类可接受（重连后拉业务表即最新）；
  /// 第 1 类由权威帧落库兼顾。
  final bool transient;

  /// `true` 表示诊断事件（`executor_started` / `gate_*` 等），默认不渲染给用户。
  final bool diagnostic;

  /// 服务端是否发出了本客户端认识的事件类型。
  bool get isKnown => EventTypes.all.contains(eventType);

  /// 是否应进入对话时间线渲染。
  //
  // 除本集合外，`agent.file.*` 走前缀匹配（见 [EventTypes.timelineVisible]
  // 的说明）：服务端可能新增 `agent.file.renamed` 之类，穷举枚举会让新类型
  // 静默被丢弃。
  bool get isTimelineVisible =>
      EventTypes.timelineVisible.contains(eventType) ||
      eventType.startsWith(EventTypes.agentFilePrefix);

  /// 是否为流式增量帧（应追加而非替换）。
  ///
  /// 注意：`transient` 单独不足以判定——`goal_updated` 也是 transient 但不是
  /// 文本增量。必须同时满足「类型属于增量类」且「transient 为 true」。
  bool get isIncremental =>
      transient && EventTypes.streamIncremental.contains(eventType);

  /// 是否为权威帧（完整快照，应替换累积的增量文本）。
  bool get isAuthoritativeFrame =>
      !transient && EventTypes.streamIncremental.contains(eventType);

  // ---------- payload 访问器 ----------
  //
  // 服务端 payload 是 map[string]any，结构随 eventType 变化。这里提供带默认值的
  // 访问器，避免调用方到处写 `payload?['x'] as String? ?? ''`。

  /// 文本内容（`message` / `thought` / `error` 的正文）。
  String get text => _str('text') ?? _str('content') ?? _str('message') ?? '';

  /// 工具名（`tool_call` / `tool_result`）。
  String? get toolName => _str('tool_name') ?? _str('toolName') ?? _str('name');

  /// 工具调用 ID（关联 call 与 result）。
  String? get toolCallId =>
      _str('tool_call_id') ?? _str('toolCallId') ?? _str('id');

  /// 工具入参（`tool_call`）。
  Map<String, dynamic>? get toolArgs =>
      _map('args') ?? _map('arguments') ?? _map('input');

  /// 工具执行结果（`tool_result`）。
  String? get toolOutput => _str('output') ?? _str('result') ?? _str('content');

  /// 当前轮次状态（`done` / `queue_state`）。
  String? get status => _str('status');

  /// 错误信息（`error` / `gate_error`）。
  String? get errorMessage =>
      _str('error') ?? _str('detail') ?? _str('message');

  /// 归属判定的解释（`routing_selected`）。
  String? get routingReason =>
      _str('group_decision_reason') ?? _str('reason') ?? _str('mode');

  /// 归属选中的 group（`routing_selected`）。
  String? get routingGroupId =>
      _str('group_id') ?? _str('groupId') ?? _str('selected_group_id');

  /// 队列位置（`queue_state`）。
  int? get queuePosition {
    final v = payload?['position'] ?? payload?['queue_position'];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 续跑排程的下次触发时间（`schedule_created`）。
  DateTime? get scheduledAt {
    final raw = _str('scheduled_at') ?? _str('next_run_at') ?? _str('run_at');
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  /// TTS 音频地址（`tts_completed`）。
  String? get audioUrl => _str('audio_url') ?? _str('url');

  /// 后续提问建议列表（`follow_up_suggested`）。
  List<String> get followUpSuggestions {
    final raw = payload?['suggestions'] ?? payload?['items'];
    if (raw is! List) return const [];
    return raw
        .map((e) {
          if (e is String) return e;
          if (e is Map) return (e['text'] ?? e['title'] ?? '').toString();
          return '';
        })
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  // ---------- agent.file.* 访问器 ----------
  //
  // 字段名**已用生产真实 payload 实测**（非推测）：服务端 payload 是
  // `map[string]any`，字段名漂移不会被编译期发现，故这里的每个键都有
  // 生产样本佐证。
  //
  // 生产样本（created）：
  //   {"relative_path":"QWEN.md","metadata":{"relative_path":"QWEN.md"},
  //    "mime_type":"text/markdown; charset=utf-8","size_bytes":3585,
  //    "ufs_file_id":"4fa522bc-...","target_path":"/workspace/.../QWEN.md"}
  // 删除事件**没有** metadata / ufs_file_id / size_bytes。

  /// 文件相对路径（`agent.file.*`）。
  //
  // 优先顶层 `relative_path`：实测删除事件无 `metadata`，但顶层 `relative_path`
  // 总在（生产 2927/2927 条）。`metadata.relative_path` 作为兼容回退——历史上
  // 两者只在「无 metadata」场景下不一致（即删除事件），顶层优先即正确。
  String get relativePath =>
      _str('relative_path') ??
      _metadataStr('relative_path') ??
      _str('target_path') ??
      _str('path') ??
      _str('name') ??
      '';

  /// UFS 文件 id（`agent.file.created`/`modified`）。
  ///
  /// 删除事件**没有**此字段（生产库 11/11 条均缺），返回 null；调用方据此
  /// 禁用下载入口（UFS 已软删）。
  String? get ufsFileId => _str('ufs_file_id');

  /// MIME 类型（`agent.file.*`）。删除事件返回 `application/octet-stream`。
  String? get mimeType => _str('mime_type');

  /// 文件字节大小（`agent.file.created`/`modified`）。删除事件返回 null。
  int? get sizeBytes => _intField('size_bytes');

  /// 用户可见展示名：`nice_name` 优先，否则路径 basename。
  //
  // 生产实测：`nice_name` 字段**从未出现**（0/2927 条），但保留它是因为
  // webapp `agentFileDisplayName` 也读它，且服务端模型随时可能填。
  String get displayName {
    final nice = _str('nice_name');
    if (nice != null && nice.trim().isNotEmpty) return nice;
    final p = relativePath;
    if (p.isEmpty) return '';
    final norm = p.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    return i >= 0 ? norm.substring(i + 1) : norm;
  }

  /// 文件动作（从事件类型推导）：`created` / `modified` / `deleted`。
  //
  /// 非 `agent.file.*` 事件返回 null。
  String? get agentFileAction {
    if (!eventType.startsWith(EventTypes.agentFilePrefix)) return null;
    final rest = eventType.substring(EventTypes.agentFilePrefix.length);
    if (rest == 'created' || rest == 'modified' || rest == 'deleted') {
      return rest;
    }
    return null;
  }

  String? _metadataStr(String key) {
    final md = payload?['metadata'];
    if (md is Map) {
      final v = md[key];
      return v is String ? v : null;
    }
    return null;
  }

  int? _intField(String key) => _int(payload?[key]);

  // ---------- 内部辅助 ----------

  String? _str(String key) {
    final v = payload?[key];
    return v is String ? v : v?.toString();
  }

  Map<String, dynamic>? _map(String key) {
    final v = payload?[key];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  /// 从 JSON 构造。支持**两种字段命名形态**：
  ///
  /// | 来源 | 命名 | 例子 |
  /// |---|---|---|
  /// | SSE 实时流（`chatbus.Event` 的 JSON tag） | camelCase | `eventId` / `eventType` / `globalSeq` |
  /// | timeline / search（`chat.go` 的 `eventToDict`） | snake_case | `event_id` / `event_type` / `global_seq` |
  ///
  /// WHY 必须两种都吃：服务端把「实时广播」与「历史查询」交给两个不同的序列化点，
  /// 前者用 `chatbus.Event` 的结构体 tag，后者手写 `map[string]any`（键名 snake_case，
  /// 历史沿袭 Python 版）。客户端只读 camelCase 会让 timeline 整段解析失败——
  /// 而该异常会被 `ChatStreamController._backfill` 的 `catch (e)` 吞成一条 warn，
  /// 表现为「历史回填永久静默为空」，排查成本极高。
  ///
  /// camelCase 优先：SSE 是主路径且字段更全（含 `transient`/`diagnostic`）。
  ///
  /// 容错策略：缺少非关键字段时给安全默认值，而不是抛异常——一个畸形事件
  /// 不应该让整条流断掉。但 [eventId] / [eventType] 缺失属于契约破坏，
  /// 此时抛 [FormatException] 由调用方决定是否断开。
  factory ChatEvent.fromJson(Map<String, dynamic> json) {
    final eventId = _str2(json, 'eventId', 'event_id');
    final eventType = _str2(json, 'eventType', 'event_type');
    if (eventId == null || eventType == null) {
      throw FormatException('ChatEvent 缺少必填字段 eventId/eventType: $json');
    }
    final createdAtRaw = _str2(json, 'createdAt', 'created_at');
    return ChatEvent(
      eventId: eventId,
      userId: _str2(json, 'userId', 'user_id') ?? '',
      groupId: _str2(json, 'groupId', 'group_id') ?? '',
      turnId: _str2(json, 'turnId', 'turn_id') ?? '',
      sessionId: _str2(json, 'sessionId', 'session_id'),
      agentId: _str2(json, 'agentId', 'agent_id'),
      eventType: eventType,
      seq: _int(json['seq']) ?? 0,
      globalSeq: _int(json['globalSeq'] ?? json['global_seq']),
      source: (json['source'] as String?) ?? '',
      createdAt:
          DateTime.tryParse(createdAtRaw ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      payload: _asMap(json['payload']),
      transient: json['transient'] == true,
      diagnostic: json['diagnostic'] == true,
    );
  }

  /// 序列化回 JSON（本地缓存用）。
  ///
  /// 字段名与 Go 侧保持一致，使缓存数据能被服务端工具直接消费。
  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'userId': userId,
    'groupId': groupId,
    'turnId': turnId,
    if (sessionId != null) 'sessionId': sessionId,
    if (agentId != null) 'agentId': agentId,
    'eventType': eventType,
    'seq': seq,
    if (globalSeq != null) 'globalSeq': globalSeq,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    if (payload != null) 'payload': payload,
    if (transient) 'transient': true,
    if (diagnostic) 'diagnostic': true,
  };

  /// 取字符串字段：camelCase 优先，回退 snake_case。
  ///
  /// 只接受 String 与 null（timeline 的 `agent_id`/`session_id` 可能是 JSON null，
  /// 由 Go 侧 `nullStr` 产出）；不把数字/布尔强转成字符串，避免 `1` 被当成 ID。
  static String? _str2(Map<String, dynamic> json, String camel, String snake) {
    final v = json[camel] ?? json[snake];
    return v is String ? v : null;
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  @override
  String toString() =>
      'ChatEvent($eventType, turn=$turnId, seq=$seq, gseq=$globalSeq'
      '${transient ? ', transient' : ''})';
}
