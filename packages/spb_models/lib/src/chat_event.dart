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

  // ---------- queue_state / retry_scheduled 访问器 ----------
  //
  // 字段名取自 Go **真实写端**（非推测）：
  //   - `chat/enqueue.go` / `chat/turn_worker.go` 的 queue_state：
  //       {state, reason, priority, queue_class, retry_attempt, queue_total,
  //        queue_user, enqueued_at|blocked_at}
  //   - `chatgate/gate_impls.go` 的 retry_scheduled：
  //       {attempt, max_retries, delay_ms, reason, http_status, exit_code}
  //
  // ⚠️ 两类事件都带 `reason`，而 gate 事件（adaptive_decision / goal_gate_decision）
  // **也**用 `reason`，routing_selected 亦然。不加门禁的话，gate 的原因会被误读成
  // 排队原因（同 turn_activity 访问器门禁的理由）。
  //
  // ⚠️ 注意 queue_state 用的是 `state` 而非 `status`——上面的 [status] getter
  // 读的是 `status`，对它恒为 null，不要拿它判排队态。
  //
  // ⚠️ 上面的 [queuePosition] 读的是 `position` / `queue_position`，而 Go 两个
  // 发射点**都不发这两个键**（只发 `queue_total` / `queue_user`）——它是历史遗留
  // 的死访问器，勿据此判定排队位置。

  /// `queue_state` 的状态值：`queued` / `cancelled`。
  ///
  /// 非 `queue_state` 事件返回 null。`cancelled` 是**终态**而非等待
  /// （见 Go `TurnWorker.EmitCanceled`）。
  String? get queueStateValue =>
      eventType == EventTypes.queueState ? _str('state') : null;

  /// 排队/重试原因。
  ///
  /// ⚠️ `retry_scheduled` 的该值是执行器 stderr 原文，可能很长，
  /// **不要**直接当横幅文案（见 `ExecutionStatus.reason`）。
  String? get queueReason =>
      (eventType == EventTypes.queueState ||
          eventType == EventTypes.retryScheduled)
      ? _str('reason')
      : null;

  /// 队列中的总任务数（`queue_state.queue_total`）。
  int? get queueTotal =>
      eventType == EventTypes.queueState ? _intField('queue_total') : null;

  /// 队列中属于当前用户的任务数（`queue_state.queue_user`）。
  int? get queueUser =>
      eventType == EventTypes.queueState ? _intField('queue_user') : null;

  /// 第几次重试（`retry_scheduled.attempt`，服务端 1-based）。
  int? get retryAttempt =>
      eventType == EventTypes.retryScheduled ? _intField('attempt') : null;

  /// 最大重试次数（`retry_scheduled.max_retries`）。
  int? get retryMaxRetries =>
      eventType == EventTypes.retryScheduled ? _intField('max_retries') : null;

  /// 距下次重试的毫秒数（`retry_scheduled.delay_ms`）。
  int? get retryDelayMs =>
      eventType == EventTypes.retryScheduled ? _intField('delay_ms') : null;

  /// 距下次自动继续的秒数（`schedule_created.delay_seconds`）。
  ///
  /// ## 为什么是秒而不是时间戳
  ///
  /// 唯一产出点（`chatgate/goal_gate.go:519`）发的是
  /// `{schedule_id, reason, status, delay_seconds, source, auto_turn_count,
  /// max_auto_turns}`——**没有** `scheduled_at` / `next_run_at` / `run_at`。
  /// 服务端给的是**相对时长**而非绝对时刻，因为绝对时刻会随重放/回放变得
  /// 无意义（回放一条昨天的 `schedule_created`，它说的绝对时间已经过去了）。
  /// 相对时长在回放时仍然可读：「当时说 30 秒后继续」。
  ///
  /// 本访问器替换了原先一个读 `scheduled_at` / `next_run_at` / `run_at` 的
  /// `DateTime?` 访问器——那三个字段 Go 侧一个都不发，它永远不会非 null，
  /// 是死访问器（对照 `gate_decision.dart` 对「永远不被命中的分支」的批评）。
  int? get scheduleDelaySeconds => eventType == EventTypes.scheduleCreated
      ? _intField('delay_seconds')
      : null;

  /// TTS 音频地址（`tts_completed`）。
  String? get audioUrl => _str('audio_url') ?? _str('url');

  // ---------- TTS 生命周期访问器（tts_started / tts_completed / tts_failed）----------
  //
  // 字段名取自 Go **真实写端**（非推测）：
  //   - `tts/service.go:357` tts_started（message 模式）：{mode:"message", seq}
  //   - `tts/service.go:607` tts_started（stream 模式）：{mode:"stream", reason:"first_delta"}
  //   - `tts/service.go:367` tts_completed（message 模式）：{seq, parts:1}
  //   - `tts/service.go:999` emitTerminal（stream 模式）：
  //       completed → {parts, bytes, duration_ms}
  //       failed    → {parts, bytes, duration_ms, reason, failed_part,
  //                    completed_parts, lost_chars, message}
  //   - `tts/service.go:361` tts_failed（message 模式）：
  //       {reason:"synthesize_failed", seq, message}
  //
  // ⚠️ 必须按事件类型门禁：`reason` / `message` / `parts` / `seq` 都是**极通用**
  // 的键名，不加门禁时 `error` 事件的 `message`、gate 事件的 `reason`、
  // `user_message` 的 `seq` 都会被误读成播报字段。
  //
  // ⚠️ **Transient 不一致**（与任务描述不符）：只有 `tts_started` 是 Transient
  // （`cmd/server/main.go:715` 的 `Transient: ev.EventType == tts.EventTTSStarted`），
  // 两个终态事件是**落库**的（`tts/service.go:170` 注释：「started 仅实时广播，
  // 终态事件持久化」）。故终态事件有有效 ID、会推进游标、会回放。

  /// 本事件是否属 TTS 生命周期三事件之一。
  bool get isTtsEvent =>
      eventType == EventTypes.ttsStarted ||
      eventType == EventTypes.ttsCompleted ||
      eventType == EventTypes.ttsFailed;

  /// 播报模式（`tts_started.mode`）：`message`（整段合成）/ `stream`（流式）。
  String? get ttsMode => isTtsEvent ? _str('mode') : null;

  /// 失败/启动原因（`tts_failed.reason` / `tts_started.reason`）。
  ///
  /// 值域：`synthesize_failed`（message 模式失败）、`first_delta`（stream 启动）、
  /// 以及 stream 终态的各类内部原因。
  String? get ttsReason => isTtsEvent ? _str('reason') : null;

  /// 面向用户的失败文案（`tts_failed.message`）。
  ///
  /// 服务端已给出可直接展示的中文（如「语音生成失败，本次文本回复不受影响。」），
  /// 故 UI 优先用它而不是自己拼。
  String? get ttsMessage => isTtsEvent ? _str('message') : null;

  /// 已生成的语音分段数。
  ///
  /// ⚠️ 两种语义不同、**不要混用**：`tts_completed` 用 `parts`（总段数）；
  /// `tts_failed` 用 `completed_parts`（失败前已完成数）。
  int? get ttsParts => isTtsEvent ? _intField('parts') : null;

  /// 失败前已完成的语音分段数（`tts_failed.completed_parts`）。
  int? get ttsCompletedParts =>
      eventType == EventTypes.ttsFailed ? _intField('completed_parts') : null;

  /// 失败发生在第几段（`tts_failed.failed_part`，1-based）。
  int? get ttsFailedPart =>
      eventType == EventTypes.ttsFailed ? _intField('failed_part') : null;

  /// 因失败丢失的字符数（`tts_failed.lost_chars`）。
  int? get ttsLostChars =>
      eventType == EventTypes.ttsFailed ? _intField('lost_chars') : null;

  /// 合成音频总字节数（stream 模式终态）。
  int? get ttsBytes => isTtsEvent ? _intField('bytes') : null;

  /// 合成耗时毫秒（stream 模式终态）。
  int? get ttsDurationMs => isTtsEvent ? _intField('duration_ms') : null;

  /// 服务端编译的 UI 描述（`spec_schema`），供 spec 渲染器消费。
  ///
  /// 形状是 JsonUiSchema `{root, elements}`，解析在 `spb_domain` 的
  /// `parseSpecUi`（本包只做字段镜像，不含解析规则）。
  ///
  /// 当前三类生产者：`goal_gate_decision`（进度卡）、`follow_up_suggested`
  /// （建议列表卡）、`routing_feedback_request`（归属反馈卡，但客户端按
  /// options 渲染，不用它）。
  Object? get specSchema => payload?['spec_schema'];

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

  /// 每条建议适用的 agent（`suggestions[].agent_id`，可选）。
  ///
  /// 与 [followUpSuggestions] **按下标一一对应**：服务端
  /// `FollowUpSuggestion.AgentID` 是 omitempty（历史建议无此字段），
  /// 缺失时对应下标为 null——点击该建议保持原有行为（不切 agent）。
  List<String?> get followUpAgentIds {
    final raw = payload?['suggestions'] ?? payload?['items'];
    if (raw is! List) return const [];
    return raw
        .map((e) {
          if (e is! Map) return null;
          final v = e['agent_id']?.toString() ?? '';
          return v.isEmpty ? null : v;
        })
        .toList(growable: false);
  }

  // ---------- 归属反馈访问器（routing_feedback_request / routing_feedback） ----------
  //
  // 字段名取自 Go `chatpipeline/classify_feedback_request.go` 的
  // `feedbackRequestPayload`（真实写端，非推测）：payload 只描述**语义**
  // （问句 + 选项 + 回执），不含渲染细节。
  //
  // ⚠️ payload 里还有个 `spec`（JSON UI 描述）字段，本包**故意不解析**：
  // Go 侧注释明示「Options 是**语义真源**（所有渠道都靠它），Spec 只是其中
  // 一种呈现」。只给 Spec 的话纯文本渠道得反向解析 JSON 才能拿到按钮文字——
  // 那就是把渲染格式当协议用。Flutter 有自己的组件体系，按 Options 渲染。

  /// 面向用户的问句（如「归到《团队周报》对吗？」）。
  String get feedbackQuestion => _str('question') ?? '这条消息归到这个对话，对吗？';

  /// 回执锚点（= 本事件的 event id），调 `resolveFeedback` 时用。
  ///
  /// 服务端把它嵌进可视化渠道按钮的 nextInput，据此直查请求、校验归属、
  /// 一次性消费。为空表示异常载荷，此时 UI 应禁用按钮。
  String get feedbackToken => _str('token') ?? '';

  /// 可选回答（语义真源）。
  ///
  /// 每项含 `label`（展示文字）与 `reply`（回执文本）。这里只取 label——
  /// 客户端不走「复用普通消息通道回传 reply」的路径，而是直接调
  /// `resolveFeedback`（一次性 CAS，不产生用户消息）。
  List<String> get feedbackOptions {
    final raw = payload?['options'];
    if (raw is! List) return const [];
    return raw
        .map((e) {
          if (e is String) return e;
          if (e is Map) return (e['label'] ?? e['text'] ?? '').toString();
          return '';
        })
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// 当时归到的对话（供 UI 展示「归到《X》对吗」中的 X）。
  String? get feedbackChosenGroupId =>
      _str('chosen_group_id') ?? _str('group_id');

  /// 被评价的那个 turn（回执标注将附到它上面）。
  ///
  /// 注意：**不是**本事件自身的 [turnId]——请求事件在完成它的 turn 上，
  /// 而标注要写回被评价的 turn。服务端两者通常相同（请求在完成时发出），
  /// 但语义不同，取值以 payload 为准。
  String? get feedbackEvaluatedTurnId => _str('evaluated_turn_id');

  /// 归属反馈的标注结果（`routing_feedback`）：用户认为归属是否正确。
  ///
  /// 该事件是「答」，与 `routing_feedback_request`（问）一问一答。payload =
  /// `{correct, correct_group_id?, chosen_index?, candidate_ids?}`（见 Go
  /// `classify_feedback_resolve.go` 的 `ParseAttributionFeedback`）。
  ///
  /// 为 null 表示 payload 未携带该字段（异常载荷）——与 `false` 不同：
  /// 「没标注」不能被当成「标注为错」。
  bool? get feedbackCorrect {
    final v = payload?['correct'];
    if (v is bool) return v;
    if (v is String) {
      if (v.toLowerCase() == 'true') return true;
      if (v.toLowerCase() == 'false') return false;
    }
    return null;
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

  // ---------- turn_activity 访问器 ----------
  //
  // 字段名取自 Go `internal/chat/turn_worker.go` 的 `upgradeHeartbeatToActivity`
  // （真实写端，非推测）：payload = `{elapsed_ms, last_event_type?,
  // since_last_event_ms?, content?}`。三个数值字段都是「有上一步事件才有」，
  // 故均可为 null——调用方不能把 null 当成 0。
  //
  // ⚠️ 与 gate 访问器不同，这五个访问器**按 eventType 做了门禁**：
  // `elapsed_ms` / `op` / `group` 都是通用键名，不加门禁的话，任何 payload 里
  // 恰好带同名键的事件都会被误读成本类事件的字段（例如 goal_updated 的 `op`
  // 会被当成 group 变更 op）。门禁让「类型不符 → null」成为可靠契约。

  /// 本 turn 已运行的毫秒数（`turn_activity`）。
  ///
  /// 服务端在每次心跳时用 `time.Since(turnStartedAt)` 重算，故直接用它即可，
  /// 无需客户端按本地时钟重算（两者会在重连/时钟偏移时不一致）。
  int? get turnActivityElapsedMs =>
      eventType == EventTypes.turnActivity ? _intField('elapsed_ms') : null;

  /// 上一步发生的事件类型（`turn_activity`）。
  ///
  /// 为空表示本 turn 还没有过任何事件（刚起跑）——UI 应只显示已运行时长。
  String? get turnActivityLastEventType =>
      eventType == EventTypes.turnActivity ? _str('last_event_type') : null;

  /// 距上一步事件已过去的毫秒数（`turn_activity`）。
  int? get turnActivitySinceLastEventMs => eventType == EventTypes.turnActivity
      ? _intField('since_last_event_ms')
      : null;

  // ---------- context_update 访问器 ----------
  //
  // ⚠️ 只做「按类型门禁 + 原样给出 payload」，**不在本层解析**成领域对象：
  // 解析（含 Go `telemetry` / `compaction` 与遗留 `context` 三种形状的归一）
  // 归 `ContextUsage.fromEventPayload`。门禁的理由同 turn_activity 的访问器：
  // `used` / `size` / `cost` 都是极通用的键名，不加门禁时任何恰好带同名键的
  // 事件都会被误读成用量数据。

  /// `context_update` 的原始 payload；非该类型事件返回 null。
  ///
  /// 形状有两种（见 `ContextUsage` 类文档）：Go 的 `{telemetry}` /
  /// `{compaction}`，以及遗留的 `{context}`。
  Map<String, dynamic>? get contextUpdatePayload =>
      eventType == EventTypes.contextUpdate ? payload : null;

  // ---------- habit 建议访问器 ----------
  //
  // 字段名取自 Go `internal/workers/habit/timeline_events.go` 的
  // `BuildSuggestionCreatedPayload` / `BuildSuggestionResolvedPayload`
  // （真实写端，非推测）。
  //
  // 本包只做字段镜像与解析，**不构造**领域对象：完整映射在 `spb_domain` 的
  // `HabitSuggestion.fromEventPayload`，因为那里才是「建议」语义的归属层
  // （同 `spec_schema` 与 `parseSpecUi` 的分工）。

  /// 建议 id（`habit_suggestion_created` / `habit_suggestion_resolved`）。
  ///
  /// 两个事件共用它作身份键，归约时据此把 resolved 合到 created 的卡上。
  /// 非 habit 事件或载荷异常时返回 null。
  String? get habitSuggestionId {
    if (eventType != EventTypes.habitSuggestionCreated &&
        eventType != EventTypes.habitSuggestionResolved) {
      return null;
    }
    final v = _str('suggestion_id');
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 建议草稿（`rule_draft`）：`topic_key` / `trigger_type` /
  /// `trigger_config` / `preferred_agent_id` / `delivery_group_id` /
  /// `target_acceptance_level`。
  ///
  /// 仅 `habit_suggestion_created` 有；resolved 事件不带草稿（返回 null）。
  Map<String, dynamic>? get habitRuleDraft =>
      eventType == EventTypes.habitSuggestionCreated
      ? _map('rule_draft')
      : null;

  /// 推荐信息（`recommendation`）：`{action, confidence, reasons[]}`。
  Map<String, dynamic>? get habitRecommendation =>
      eventType == EventTypes.habitSuggestionCreated
      ? _map('recommendation')
      : null;

  /// 候选为 null（`habit_pattern_id` 显式下发为 null）。
  ///
  /// 服务端刻意用 null 而非空串区分「没有 pattern」与「有 pattern 但为空」，
  /// 故这里也保留 null 语义。
  String? get habitPatternId {
    if (eventType != EventTypes.habitSuggestionCreated) return null;
    return _str('habit_pattern_id');
  }

  /// 用户反馈（resolved 事件的 `user_feedback`）：`accepted` / `dismissed` /
  /// `snoozed`。
  ///
  /// ⚠️ 这里给的是**服务端写库值**（`accept_rule` 会被归一成 `accepted`——
  /// 服务端写 `user_feedback` 时用的是 `mapFeedbackValue` 的结果，事件 payload
  /// 里的 `user_feedback` 就是那个值）。不要拿它去匹配请求体的 `action`
  /// （请求体是 `accept`，见 `HabitSuggestionAction`）。
  String? get habitUserFeedback =>
      eventType == EventTypes.habitSuggestionResolved
      ? _str('user_feedback')
      : null;

  /// 用户动作（resolved 事件的 `action`）：`accept` / `dismiss` / `snooze` /
  /// `edit_and_accept`。
  String? get habitResolvedAction =>
      eventType == EventTypes.habitSuggestionResolved ? _str('action') : null;

  /// accept 后建出的 pattern id（resolved 事件的 `resolved_pattern_id`）。
  ///
  /// ⚠️ 与 `POST .../resolve` **响应**里的 `pattern_id` 不同名（两处真源：
  /// 事件在 `BuildSuggestionResolvedPayload`，响应在 `misc_extra.go`）。
  String? get habitResolvedPatternId =>
      eventType == EventTypes.habitSuggestionResolved
      ? _str('resolved_pattern_id')
      : null;

  /// snooze 截止时刻（resolved 事件的 `snooze_until`，RFC3339）。
  DateTime? get habitSnoozeUntil {
    if (eventType != EventTypes.habitSuggestionResolved) return null;
    final s = _str('snooze_until');
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  // ---------- habit_auto_run_completed 访问器 ----------
  //
  // 载荷形状取自 Python 的 `build_habit_auto_run_completed_payload`
  // （`apps/api/utilities/habit_internal/timeline_events.py:89`）——
  // Go 侧暂无产出点（见 [EventTypes.habitAutoRunCompleted] 的说明），
  // 故 Python 与 webapp 的解析器是仅有的两份契约依据：
  // `{habit_pattern_id, habit_run_id, turn_id, delivery_group_id,
  //   topic_key, summary}`。

  /// 主题 key（`topic_key`）。
  ///
  /// 这是本卡片的**主要展示内容**（webapp 的摘要就是
  /// `habit 提醒已送达 · <topic_key 下划线转空格>`）。
  /// 非本事件或载荷缺失时返回 null。
  String? get habitAutoRunTopicKey =>
      eventType == EventTypes.habitAutoRunCompleted
      ? _nonEmpty(_str('topic_key'))
      : null;

  /// 服务端生成的摘要文案（`summary`）。
  ///
  /// ⚠️ **不用它作主文案**：服务端文案是「给 IM 渠道的成句」（
  /// 「X 习惯提醒已成功送达，完成本轮强化。」），而时间线卡片需要的是
  /// 与 webapp 一致的短标签。保留访问器是为了排障时能看到服务端原话。
  String? get habitAutoRunSummary =>
      eventType == EventTypes.habitAutoRunCompleted
      ? _nonEmpty(_str('summary'))
      : null;

  /// 本次执行记录 id（`habit_run_id`）。
  ///
  /// 供卡片深链到「习惯执行历史」时定位具体那一条。
  String? get habitAutoRunRunId => eventType == EventTypes.habitAutoRunCompleted
      ? _nonEmpty(_str('habit_run_id'))
      : null;

  /// 命中的习惯规则 id（`habit_pattern_id`）。
  String? get habitAutoRunPatternId =>
      eventType == EventTypes.habitAutoRunCompleted
      ? _nonEmpty(_str('habit_pattern_id'))
      : null;

  /// 去空白后为空的串归为 null。
  ///
  /// 服务端可能下发空串（而非缺键），空串当「有值」会让卡片显示空白标题。
  static String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

  // ---------- group_updated 访问器 ----------
  //
  // 字段名取自 Go `internal/chat/group_events.go` 的 `PublishGroupUpdated`：
  // payload = `{op, group: {id, title, status, created_at?, updated_at?}}`，
  // 快照**刻意最小化**（只带身份字段），列表内容以 refetch 为准。

  /// group 变更操作（`group_updated`）：`created` / `deleted` / `archived` /
  /// `active` / `title` / `metadata`（见 Go `GroupEventOp`）。
  ///
  /// 服务端可能新增 op，故调用方应对未知值走「忽略或整体重拉」而非抛异常。
  String? get groupUpdateOp =>
      eventType == EventTypes.groupUpdated ? _str('op') : null;

  /// group 身份快照（`group_updated` 的 `group` 字段）。
  ///
  /// 非 Map（缺失/异常载荷）返回 null。**不是**完整 group DTO——只有
  /// `id` / `title` / `status` 等身份字段，需要完整字段时应重新拉列表。
  Map<String, dynamic>? get groupUpdateSnapshot =>
      eventType == EventTypes.groupUpdated ? _map('group') : null;

  // ---------- group_metadata_updated 访问器 ----------
  //
  // 发射点：Go `chatgate/goal_gate.go:440`（目标达成）与 `:555`（max_auto_turns
  // 熔断）。两处 payload 同为 `{reason, metadata}`。
  //
  // `metadata` 是**完整**的 group metadata：`updateGroupMetadata` 先 `loadGroupMetadata`
  // 读出整个 map、`apply` 改动、再返回同一个 map（不是子树）。故客户端应**整体
  // 替换**而非局部合并。
  //
  // ## 为什么需要它（事实性错误）
  //
  // goal gate 自动停用时（`markGoalGateCompleted` 写 `gate["enabled"] = false`，
  // 熔断路径同理），服务端改了 `chat_groups.metadata` 但**没有任何 HTTP 响应**
  // 回到客户端（这是后台 worker 的动作）。没有本事件，设置面板会继续显示
  // 「自动实现目标：开」——用户以为还会自动续跑，实际已停。
  //
  // ## ⚠️ 与 goal_updated 相反：本事件**是落库的**
  //
  // `broker.go:82` 把它列在「持久化到 chat_events，前端可渲染」一组，且
  // `emitEvent`（`goal_gate.go:619`）走 turn worker 的持久化 emit、未设
  // `Transient`（它也确实有 turn，`turn_id` 可满足 NOT NULL）。
  //
  // 故它**会**带有效 eventId/globalSeq、**会**推进游标、**会**回放——客户端
  // 无需（也**不应**）像 goal_updated 那样做游标豁免。历史回放时它会重新
  // 套用同一份 metadata，幂等无害。

  /// 停用原因（`group_metadata_updated.reason`）：
  /// `goal_completed` / `max_auto_turns_reached`。
  String? get groupMetadataReason =>
      eventType == EventTypes.groupMetadataUpdated ? _str('reason') : null;

  /// 变更后的**完整** group metadata（`group_metadata_updated.metadata`）。
  ///
  /// 形状与 `ChatGroup.metadata` 同（含 `goal_gate` / `tts` /
  /// `follow_up_suggest` 等子对象），故可直接交给 `ChatGroup.withMetadata`。
  Map<String, dynamic>? get groupMetadata =>
      eventType == EventTypes.groupMetadataUpdated ? _map('metadata') : null;

  // ---------- goal_updated 访问器 ----------
  //
  // 字段名取自 Go `internal/server/goal_api.go` 的 `emitGoalUpdated`：
  // payload = `{op, goal, tasks, progress, task_id?}`，其中 goal/tasks/progress
  // 由与 `GET /goals/current` **完全相同**的 DTO 函数生成（`goalToDTO` /
  // `taskToDTO` / `progressFromTasks`）。这是服务端刻意的防漂移设计（见那里的
  // 文件头注释：同一个函数生成的结构不可能对不上），故客户端解析事件与解析
  // API 响应用同一套逻辑。
  //
  // ⚠️ 与 group_updated 的**致命**差异：`goal_updated` 在 Go 侧**漏设**
  // `Transient: true`。`emitGoalUpdated` 的注释写着「不落库，仅广播」，但
  // `chatbus.Event` 的 Transient 字段留了零值 false（对比 `PublishGroupUpdated`
  // 与 `buildTitleUpdatedEvent` 都显式设了 true）。
  //
  // 于是它在线上表现为 `transient=false` + **有效 eventId**。若走通用路径，
  // 控制器的 `if (!event.transient && event.eventId.isNotEmpty)` 会把它记作
  // SSE 游标；而服务端 `replayUserEvents` 是按 `chat_events.id` 定位的，
  // goal_updated 根本不在那张表里 → cursor 未命中 → `start < 0` → 返回 nil →
  // **整个断线回放窗口丢失**。故控制器必须提前分流、绝不落到 recordEventId。
  //
  // 客户端无法修正服务端这个标志位（约束：Go API 一行不改），只能在消费侧
  // 按「事件类型」而非「Transient 标志」判断该不该推进游标。

  /// goal 变更操作（`goal_updated.op`）。
  ///
  /// 值域（`goal_api.go` 的 `emitGoalUpdated` 调用点）：`goal_create` /
  /// `goal_switch` / `goal_status` / `task_create` / `task_update` /
  /// `task_delete` / `task_status` / `task_reorder` / `task_reset_expand`。
  ///
  /// 保持 String 而非 enum：服务端新增 op 时不应静默走 default 分支丢掉刷新
  /// （本事件的消费方只需知道「快照变了」）。
  String? get goalUpdateOp =>
      eventType == EventTypes.goalUpdated ? _str('op') : null;

  /// goal 快照（`goal_updated.goal`，形状同 `goalToDTO`）。
  Map<String, dynamic>? get goalUpdateGoal =>
      eventType == EventTypes.goalUpdated ? _map('goal') : null;

  /// 任务列表快照（`goal_updated.tasks`，每项形状同 `taskToDTO`）。
  ///
  /// 非 List / 元素非 Map 时跳过该项（异常载荷不应让整个快照解析失败）。
  List<Map<String, dynamic>> get goalUpdateTasks =>
      eventType == EventTypes.goalUpdated ? _listOfMaps('tasks') : const [];

  /// 进度快照（`goal_updated.progress`，形状同 `progressFromTasks`）：
  /// `{total, completed, in_progress, blocked, error_stopped, pending, percent?}`。
  Map<String, dynamic>? get goalUpdateProgress =>
      eventType == EventTypes.goalUpdated ? _map('progress') : null;

  /// 本次操作涉及的任务 id（`goal_updated.task_id`）。
  ///
  /// 只有任务级操作带它（`goal_create` / `goal_switch` / `goal_status` /
  /// `task_reorder` 等传空串，服务端便不加该键）。
  String? get goalUpdateTaskId =>
      eventType == EventTypes.goalUpdated ? _str('task_id') : null;

  // ---------- gate 决策访问器（adaptive_decision / goal_gate_decision）----------
  //
  // 两类事件共用这几个访问器，键名差异已在各 getter 里归一：
  //   - `adaptive_decision`（Go 现行，扁平 payload）：
  //       action / confidence / reason / gate_source（见 chatgate/arbiter.go
  //       的 emitDecisionEvent）。
  //   - `goal_gate_decision`（任务表判定）：
  //       goal_achieved / stopped / stop_reason / decision_reason / source /
  //       next_input_preview（见 chatgate/goal_gate.go 的 decisionPayload）。
  //
  // 字段名漂移不会被编译期发现（payload 是 map[string]any），每个键都对齐过
  // webapp 的 collectGateDecisions 与 Go 的 emitDecisionEvent。

  /// gate 判定来源：`fastpath` / `llm_gate` / `retry_gate`（adaptive）
  /// 或 `tasks_completed` / `task_blocked` / `no_tasks` / `task_error_stopped`
  /// （goal gate）。
  //
  // adaptive_decision 用 `gate_source`；goal_gate_decision 用 `source`，
  // 故先试前者再试后者。
  String? get gateSource =>
      _str('gate_source') ?? _str('gateSource') ?? _str('source');

  /// 决策动作（`adaptive_decision.action`）。
  //
  /// 值域：`stop` / `auto_continue` / `auto_repeat` / `need_confirmation`
  /// （见 chatgate/decision.go 的 actionString）。
  /// goal_gate_decision **没有** action 字段，返回 null（决策由
  /// [goalAchieved]/[goalStopped] 推导）。
  String? get gateAction => _str('action');

  /// 决策理由：goal gate 用 `decision_reason`，adaptive 用 `reason`。
  String? get gateReason => _str('decision_reason') ?? _str('reason');

  /// 决策置信度（仅 adaptive_decision 带；goal gate 为任务表判定，恒为 null）。
  double? get gateConfidence => _double(payload?['confidence']);

  /// 下一步输入预览（两类事件都可能带）。
  String? get gateNextInputPreview =>
      _str('next_input') ?? _str('next_input_preview');

  /// 目标是否达成（`goal_gate_decision`）。
  bool get goalAchieved => payload?['goal_achieved'] == true;

  /// 是否「停止等人工」（`goal_gate_decision`）。
  //
  /// 仅 `goal_achieved=false` 且有 `stopped=true` 时为真；goal 达成或自动续跑
  /// 时为假。**必须**与 [goalAchieved] 配合看，单凭 `goal_achieved=false`
  /// 无法区分「续跑」与「停止」（两者都是 false）。
  bool get goalStopped => payload?['stopped'] == true;

  /// 停止原因（`goal_gate_decision` 的 `stop_reason`）。
  String? get goalStopReason => _str('stop_reason');

  String? _metadataStr(String key) {
    final md = payload?['metadata'];
    if (md is Map) {
      final v = md[key];
      return v is String ? v : null;
    }
    return null;
  }

  int? _intField(String key) => _int(payload?[key]);

  double? _double(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

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

  /// 取「对象数组」字段；非 List 返回空列表，元素非 Map 的项跳过。
  ///
  /// 用于 `goal_updated.tasks` 这类载荷。宽松而非抛异常：一个畸形的任务项
  /// 不应让整个快照（含 goal/progress）解析失败。
  List<Map<String, dynamic>> _listOfMaps(String key) {
    final v = payload?[key];
    if (v is! List) return const [];
    final out = <Map<String, dynamic>>[];
    for (final item in v) {
      if (item is Map<String, dynamic>) {
        out.add(item);
      } else if (item is Map) {
        out.add(Map<String, dynamic>.from(item));
      }
    }
    return out;
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
