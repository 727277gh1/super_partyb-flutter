/// 小程序工作台（miniapp BFF）契约。
///
/// ## 端点来源
///
/// 全部来自 `super_partyb/apps/go-api/internal/server/miniapp.go` 的
/// `registerMiniappRoutes`（挂在 `/chat/miniapp` 下，见 `router.go:98`）：
///
/// | 方法 | 路径 |
/// |---|---|
/// | GET/POST | `/chat/miniapp/works` |
/// | GET | `/chat/miniapp/works/:work_id` |
/// | POST | `/chat/miniapp/works/:work_id/messages` |
/// | POST | `/chat/miniapp/works/:work_id/complete` / `stop` |
/// | GET | `/chat/miniapp/works/:work_id/events` |
/// | GET | `/chat/miniapp/works/:work_id/artifacts[/:aid[/download]]` |
/// | POST | `/chat/miniapp/works/:work_id/files` |
/// | GET | `/chat/miniapp/confirmations` |
/// | POST | `/chat/miniapp/confirmations/:id/resolve` |
/// | GET/POST | `/chat/miniapp/notifications/subscriptions` |
///
/// **不含** `/ws` 与 `/ws-tickets`：本仓库禁止引入 WebSocket（见 AGENTS.md §6.1），
/// 实时更新复用既有 SSE `/users/:uid/chat/stream`。
///
/// ## 命名陷阱（三个，都会静默出错）
///
/// 1. **`work` 就是 `chat_groups` 行**。服务端没有独立的 works 表，`buildWorkItem`
///    把 group + turns + events + confirmations 投影成「工作」。故 `id` 是 group id。
/// 2. **`cursor` 其实是 offset**。`listWorks` 用 `parseOffset(c.Query("cursor"))`，
///    返回的 `next_cursor` 是 `strconv.Itoa(offset + len(groups))`。当 id 游标用会翻页错乱。
/// 3. **`/events` 返回的是数据库原始行，不是 SSE 事件形状**。见 [MiniappWorkEvent]。
library;

import 'dart:convert';

/// 工作列表项（`buildWorkItem` 的投影）。
///
/// ## 字段命名混合了 snake_case 与固定键
///
/// 服务端用 `gin.H` 手写键名，全部 snake_case。照抄，不要「统一」成驼峰。
class MiniappWork {
  const MiniappWork({
    required this.id,
    required this.title,
    required this.status,
    required this.statusLabel,
    required this.progress,
    required this.createdAt,
    required this.updatedAt,
    this.goal,
    this.pendingConfirmationCount = 0,
    this.latestSummary,
    this.latestArtifact,
    this.raw = const {},
  });

  /// 工作 id。**等于 `chat_groups.id`**（服务端没有独立的 works 表）。
  final String id;

  final String title;

  /// `running` / `waiting_user` / `completed` / `failed` / `stopped` / `draft` /
  /// `queued` / `archived`。用 String 而非 enum 以容忍服务端新增状态。
  final String status;

  /// 状态的**展示名**（如「运行中」）。
  ///
  /// ## 为什么由后端下发
  ///
  /// 前端两份硬编码状态表已漂移过（`work-list.tsx` 有 `archived`、
  /// `WorkHeader.tsx` 没有）。后端新增状态时前端无需发版/重新提审。
  ///
  /// 服务端未登记的状态返回**空串**（刻意不回落成 `status` 本身，以便前端
  /// 明确区分「后端未提供展示名」），故用 [displayStatus] 做兜底。
  final String statusLabel;

  final MiniappProgress progress;

  /// 生效目标（结构化表优先 → `group.goal` 兜底）。
  final String? goal;

  /// 待确认数量（`pending_confirmation_count`）。
  final int pendingConfirmationCount;

  /// 最新结果的正文（`latest_summary`）。服务端从 events 投影，可能为 null。
  final String? latestSummary;

  /// 最新产物摘要（`latest_artifact`），无产物时为 null。
  final MiniappArtifact? latestArtifact;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  final Map<String, dynamic> raw;

  /// 展示用状态名：优先服务端下发，空则回落原始 status。
  String get displayStatus => statusLabel.isNotEmpty ? statusLabel : status;

  bool get hasPendingConfirmation => pendingConfirmationCount > 0;

  factory MiniappWork.fromJson(Map<String, dynamic> json) => MiniappWork(
    id: _str(json['id']),
    title: _str(json['title']),
    status: _str(json['status']),
    statusLabel: _str(json['status_label']),
    progress: MiniappProgress.fromJson(_map(json['progress'])),
    goal: _nullableStr(json['goal']),
    pendingConfirmationCount: _int(json['pending_confirmation_count']),
    latestSummary: _nullableStr(json['latest_summary']),
    latestArtifact: _mapOrNull(json['latest_artifact']) == null
        ? null
        : MiniappArtifact.fromJson(_map(json['latest_artifact'])),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
    raw: json,
  );

  @override
  String toString() =>
      'MiniappWork($id, status=$status, progress=${progress.percent}%)';
}

/// 工作进度（`buildWorkProgress`）。
///
/// ## `total == 0` 时 `percent` 恒为 0
///
/// 服务端只在 `total > 0` 时计算百分比。故「没有任务列表」与「进度 0%」在
/// 数值上不可区分——UI 应据 [hasSteps] 决定是否画进度条，而不是看 `percent`。
class MiniappProgress {
  const MiniappProgress({
    this.total = 0,
    this.completed = 0,
    this.pending = 0,
    this.percent = 0,
    this.currentStepId,
    this.currentStepTitle,
  });

  final int total;
  final int completed;
  final int pending;

  /// 0–100 的整数百分比。
  final int percent;

  final String? currentStepId;
  final String? currentStepTitle;

  bool get hasSteps => total > 0;

  /// 归一化的 0–1 进度（供 `LinearProgressIndicator`）。
  ///
  /// 服务端 `percent` 是整数，直接除 100 会丢掉小数（如 1/3 → 33%）。
  /// 有 total 时用 completed/total 更精确。
  double get fraction {
    if (total <= 0) return 0;
    return (completed / total).clamp(0.0, 1.0);
  }

  factory MiniappProgress.fromJson(Map<String, dynamic> json) =>
      MiniappProgress(
        total: _int(json['total']),
        completed: _int(json['completed']),
        pending: _int(json['pending']),
        percent: _int(json['percent']),
        currentStepId: _nullableStr(json['current_step_id']),
        currentStepTitle: _nullableStr(json['current_step_title']),
      );

  @override
  String toString() => 'MiniappProgress($completed/$total, $percent%)';
}

/// 工作步骤（`steps` / `progress` 同源的任务项）。
class MiniappStep {
  const MiniappStep({
    required this.id,
    required this.title,
    required this.status,
    this.description = '',
    this.phase,
    this.orderIndex = 0,
  });

  final String id;
  final String title;

  /// 小程序 wire format：`pending` / `running` / `completed` / `skipped` / `failed`。
  ///
  /// 服务端已把存储层六态归一到这里（`miniappTaskStatus`）：`in_progress` 与
  /// `blocked` → `running`，`error_stopped` → `failed`。客户端不必再映射。
  final String status;

  final String description;
  final String? phase;
  final int orderIndex;

  bool get isDone => status == 'completed' || status == 'skipped';
  bool get isRunning => status == 'running';
  bool get isFailed => status == 'failed';

  factory MiniappStep.fromJson(Map<String, dynamic> json) => MiniappStep(
    id: _str(json['id']),
    title: _str(json['title']),
    status: _str(json['status']),
    description: _str(json['description']),
    phase: _nullableStr(json['phase']),
    orderIndex: _int(json['order_index']),
  );

  @override
  String toString() => 'MiniappStep($id, $status)';
}

/// 产物摘要（`buildArtifactSummaries` / `getArtifact` / `uploadFile`）。
///
/// ## 两种来源，字段一致但 `content` 只有一处有
///
/// - 事件投影（列表里的 `artifacts` / `latest_artifact`）：**无** `content`；
/// - `GET /works/:id/artifacts/:aid`：文本类且不超阈值时**内联** `content`。
///
/// 故 [content] 为 null 不代表「没有内容」，只代表「本次没内联」——要拿内容
/// 得走 [MiniappApi.downloadArtifact]（或详情端点）。
class MiniappArtifact {
  const MiniappArtifact({
    required this.id,
    required this.name,
    required this.type,
    this.workId,
    this.mimeType = '',
    this.sizeBytes = 0,
    this.previewMode = '',
    this.url,
    this.thumbnailUrl,
    this.createdAt,
    this.content,
    this.downloadUrl,
    this.webviewUrl,
    this.raw = const {},
  });

  /// 产物 id。
  ///
  /// ⚠️ 事件投影时它可能是 `ufs_file_id`，**也可能**是服务端合成的
  /// `"<group_id>:<relative_path>"`（`artifactSummaryFromEvent` 在 payload 无
  /// `ufs_file_id` 时兜底）。合成的 id **不能**用于下载（UFS 查不到）。
  /// 故 [isDownloadable] 只在详情/上传来源为真时可信——UI 应把下载失败当常态处理。
  final String id;

  final String name;

  /// `image` / `prototype` / `document` / `file`（`artifactType`）。
  final String type;

  final String? workId;
  final String mimeType;
  final int sizeBytes;

  /// `image` / `audio` / `webview` / `map` / `download` / `text`（`previewMode`）。
  final String previewMode;

  final String? url;
  final String? thumbnailUrl;
  final DateTime? createdAt;

  /// 内联内容。仅 `GET .../artifacts/:aid` 对文本类且不超阈值时提供。
  final String? content;

  /// 下载路径（**相对路径**，如 `/chat/miniapp/works/w1/artifacts/a1/download`）。
  ///
  /// 注意是服务端拼的绝对路径（以 `/` 开头），而客户端 baseUrl 带网关前缀
  /// （如 `.../pba`）。直接拿它发请求会丢掉前缀——必须用
  /// [MiniappApi.downloadArtifact] 按 id 拼，或自行补前缀。
  final String? downloadUrl;

  final String? webviewUrl;

  final Map<String, dynamic> raw;

  bool get isImage => type == 'image';
  bool get hasInlineContent => content != null && content!.isNotEmpty;

  factory MiniappArtifact.fromJson(Map<String, dynamic> json) =>
      MiniappArtifact(
        id: _str(json['id']),
        name: _str(json['name']),
        type: _str(json['type']),
        workId: _nullableStr(json['work_id']),
        mimeType: _str(json['mime_type']),
        sizeBytes: _int(json['size_bytes']),
        previewMode: _str(json['preview_mode']),
        url: _nullableStr(json['url']),
        thumbnailUrl: _nullableStr(json['thumbnail_url']),
        createdAt: _date(json['created_at']),
        content: json['content'] is String ? json['content'] as String : null,
        downloadUrl: _nullableStr(json['download_url']),
        webviewUrl: _nullableStr(json['webview_url']),
        raw: json,
      );

  @override
  String toString() => 'MiniappArtifact($id, $name, $type)';
}

/// 确认卡（`buildConfirmation`）。
///
/// ## `type` 是服务端归一后的结果，不是数据库的 `kind`
///
/// `miniappConfirmationType` 把 `chat_confirmations.kind` + `recommendation_action`
/// 映射成五类：`risk_approval` / `missing_info` / `stop_suggestion` / `continue` /
/// `choose_option`。客户端只需按这五类渲染。
class MiniappConfirmation {
  const MiniappConfirmation({
    required this.id,
    required this.workId,
    required this.type,
    required this.title,
    required this.status,
    this.description,
    this.options = const [],
    this.requiredInputs = const [],
    this.createdAt,
    this.expiresAt,
    this.raw = const {},
  });

  /// 卡行 id（`chat_confirmations.id`）。
  ///
  /// ⚠️ **不是**事件 id。resolve 端点的路径参数用这个值。
  final String id;

  /// 归属工作（= `group_id`）。服务端键名是 `work_id`。
  final String workId;

  final String type;
  final String title;

  /// `pending` / `resolved` / `expired` / `cancelled`。
  final String status;

  /// 说明文本。服务端可能返回 **null**（`confirmationDescription` 无 reason 时
  /// 返回 nil），故这里可空。
  final String? description;

  final List<MiniappConfirmationOption> options;
  final List<MiniappConfirmationInput> requiredInputs;

  final DateTime? createdAt;
  final DateTime? expiresAt;

  final Map<String, dynamic> raw;

  bool get isPending => status == 'pending';

  /// 推荐选项的 key（无推荐时为 null）。
  String? get recommendedOptionKey {
    for (final o in options) {
      if (o.recommended) return o.key;
    }
    return null;
  }

  factory MiniappConfirmation.fromJson(Map<String, dynamic> json) =>
      MiniappConfirmation(
        id: _str(json['id']),
        workId: _str(json['work_id']),
        type: _str(json['type']),
        title: _str(json['title']),
        status: _str(json['status']),
        description: _nullableStr(json['description']),
        options: _list(json['options'], MiniappConfirmationOption.fromJson),
        requiredInputs: _list(
          json['required_inputs'],
          MiniappConfirmationInput.fromJson,
        ),
        createdAt: _date(json['created_at']),
        expiresAt: _date(json['expires_at']),
        raw: json,
      );

  @override
  String toString() => 'MiniappConfirmation($id, $type, $status)';
}

/// 确认卡选项（`confirmationOptions`）。
class MiniappConfirmationOption {
  const MiniappConfirmationOption({
    required this.key,
    required this.label,
    this.recommended = false,
  });

  /// 传给 resolve 端点的 `action`（`approve` / `reject` / `revise` / `stop`）。
  final String key;
  final String label;
  final bool recommended;

  factory MiniappConfirmationOption.fromJson(Map<String, dynamic> json) =>
      MiniappConfirmationOption(
        key: _str(json['key']),
        label: _str(json['label']),
        recommended: json['recommended'] == true,
      );
}

/// 确认卡需要用户补充的输入项（`confirmationInputs`）。
class MiniappConfirmationInput {
  const MiniappConfirmationInput({
    required this.key,
    required this.label,
    this.placeholder = '',
    this.required = true,
  });

  final String key;
  final String label;
  final String placeholder;
  final bool required;

  factory MiniappConfirmationInput.fromJson(Map<String, dynamic> json) =>
      MiniappConfirmationInput(
        key: _str(json['key']),
        label: _str(json['label']),
        placeholder: _str(json['placeholder']),
        required: json['required'] != false,
      );
}

/// 工作详情（`buildWorkDetail`，即 `{work: {...}}` 里的那个对象）。
class MiniappWorkDetail {
  const MiniappWorkDetail({
    required this.id,
    required this.title,
    required this.status,
    required this.statusLabel,
    required this.progress,
    required this.canSendMessage,
    required this.canStop,
    required this.canComplete,
    this.goal,
    this.steps = const [],
    this.latestResult,
    this.pendingConfirmations = const [],
    this.artifacts = const [],
    this.recentEvents = const [],
    this.activeSession,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String title;
  final String status;
  final String statusLabel;
  final MiniappProgress progress;

  /// 服务端下发的**能力位**，UI 据此决定按钮可用性，而不是自己推状态。
  ///
  /// `can_send_message = group.status=='active' && status ∉ {completed,failed,stopped}`；
  /// `can_stop = group.status=='active' && status ∈ {running,waiting_user}`；
  /// `can_complete` 同 `can_send_message`。
  ///
  /// 这些位**比客户端自己判断更权威**：状态机在服务端，客户端复刻一份必然会漂移。
  final bool canSendMessage;
  final bool canStop;
  final bool canComplete;

  final String? goal;
  final List<MiniappStep> steps;

  /// 最新结果（`extractLatestResult`）：`{title, content, created_at}`，可能为 null。
  final Map<String, dynamic>? latestResult;

  final List<MiniappConfirmation> pendingConfirmations;
  final List<MiniappArtifact> artifacts;
  final List<MiniappEventItem> recentEvents;

  /// 当前绑定的 agent（`active_session`，服务端可选提供）。
  final Map<String, dynamic>? activeSession;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  final Map<String, dynamic> raw;

  String get displayStatus => statusLabel.isNotEmpty ? statusLabel : status;

  /// 最新结果的正文（无则 null）。
  String? get latestResultText {
    final v = latestResult?['content'];
    return v is String && v.isNotEmpty ? v : null;
  }

  factory MiniappWorkDetail.fromJson(Map<String, dynamic> json) =>
      MiniappWorkDetail(
        id: _str(json['id']),
        title: _str(json['title']),
        status: _str(json['status']),
        statusLabel: _str(json['status_label']),
        progress: MiniappProgress.fromJson(_map(json['progress'])),
        canSendMessage: json['can_send_message'] == true,
        canStop: json['can_stop'] == true,
        canComplete: json['can_complete'] == true,
        goal: _nullableStr(json['goal']),
        steps: _list(json['steps'], MiniappStep.fromJson),
        latestResult: _mapOrNull(json['latest_result']),
        pendingConfirmations: _list(
          json['pending_confirmations'],
          MiniappConfirmation.fromJson,
        ),
        artifacts: _list(json['artifacts'], MiniappArtifact.fromJson),
        recentEvents: _list(json['recent_events'], MiniappEventItem.fromJson),
        activeSession: _mapOrNull(json['active_session']),
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
        raw: json,
      );

  @override
  String toString() => 'MiniappWorkDetail($id, $status)';
}

/// 投影后的事件项（`buildWorkEvent` / `workEvent`）。
///
/// 形状：`{id, work_id, type, title, content, created_at}`，其中 `type` 是
/// **投影类型**而非原始事件类型：
///
/// | 原始 `event_type` | 投影 `type` |
/// |---|---|
/// | `user_message` | `user_input` |
/// | `start` / `thought` / `reasoning` / `thinking` | `progress` |
/// | `message` | `result` |
/// | `agent.file.*` | `artifact_created` |
/// | `confirmation_required` | `waiting_confirmation` |
/// | `error` | `failed` |
///
/// 用于 `recent_events`（详情页）与 WS 推送（本仓库不走 WS）。
class MiniappEventItem {
  const MiniappEventItem({
    required this.id,
    required this.type,
    required this.title,
    this.workId = '',
    this.content,
    this.createdAt,
  });

  final String id;

  /// `user_input` / `progress` / `result` / `artifact_created` /
  /// `waiting_confirmation` / `failed`。
  final String type;

  final String title;

  final String workId;

  /// 正文。服务端类型是 `any`：多数情况是字符串，`artifact_created` 为 **null**。
  final Object? content;

  final DateTime? createdAt;

  /// 正文的字符串形式（非字符串或 null 时返回 null）。
  String? get contentText => content is String ? content as String : null;

  bool get isFailure => type == 'failed';
  bool get isArtifact => type == 'artifact_created';
  bool get needsUser => type == 'waiting_confirmation';

  factory MiniappEventItem.fromJson(Map<String, dynamic> json) =>
      MiniappEventItem(
        id: _str(json['id']),
        type: _str(json['type']),
        title: _str(json['title']),
        workId: _str(json['work_id']),
        content: json['content'],
        createdAt: _date(json['created_at']),
      );

  @override
  String toString() => 'MiniappEventItem($id, $type)';
}

/// `GET /works/:work_id/events` 返回的**数据库原始行**。
///
/// ## 为什么不能复用 `ChatEvent`
///
/// `workEvents` 直接把 `[]queries.ChatEvent` 交给 `c.JSON`，于是序列化结果由
/// Go 结构体的 json tag 决定，与 SSE / timeline 的事件形状**不同**：
///
/// | 字段 | 本端点（DB 行） | SSE / timeline（`chatEventToStream`） |
/// |---|---|---|
/// | 事件 id | `id` | `eventId` |
/// | 类型 | `eventType` | `eventType` |
/// | 负载 | **`payloadJson`（字符串）** | `payload`（对象） |
/// | agent | **`{"String":..,"Valid":..}`** | `agentId`（字符串） |
/// | 归属 | `group_id` / `user_id` | `groupId` / `userId` |
///
/// 用 `ChatEvent.fromJson` 解析这些行会**抛 `FormatException`**——它要求
/// `eventId`（此处没有，只有 `id`），正是 `search` 端点踩过的同一个坑。
///
/// 另有 `transient` / `globalSeq` 等字段的语义差异：本端点是落库行，没有
/// transient 概念。故**单独建模**，不要试图合并。
class MiniappWorkEvent {
  const MiniappWorkEvent({
    required this.id,
    required this.eventType,
    required this.seq,
    this.turnId = '',
    this.groupId = '',
    this.userId = '',
    this.agentId,
    this.sessionId,
    this.globalSeq,
    this.source = '',
    this.payloadJson,
    this.createdAt,
    this.raw = const {},
  });

  /// 事件 id（`chat_events.id`）。**键名是 `id`**，不是 `eventId`。
  final String id;

  final String eventType;
  final int seq;

  final String turnId;
  final String groupId;
  final String userId;

  /// 服务端此处是 `sql.NullString`，JSON 形如 `{"String":"a1","Valid":true}`；
  /// 空值时是 `{"String":"","Valid":false}`。本类已归一成 `String?`。
  final String? agentId;
  final String? sessionId;

  final int? globalSeq;
  final String source;

  /// 负载的**原始 JSON 字符串**（键名 `payloadJson`）。
  ///
  /// 用 [payload] 拿解析后的对象。解析失败时 [payload] 返回 null（服务端
  /// `eventPayload` 在 JSON 非法时也返回空 map，两边一致地「不抛」）。
  final String? payloadJson;

  final DateTime? createdAt;

  final Map<String, dynamic> raw;

  /// 解析后的负载对象；无负载或 JSON 非法时为 null。
  Map<String, dynamic>? get payload {
    final s = payloadJson;
    if (s == null || s.isEmpty) return null;
    try {
      final v = jsonDecode(s);
      if (v is Map<String, dynamic>) return v;
      if (v is Map) return Map<String, dynamic>.from(v);
      return null;
    } on FormatException {
      return null;
    }
  }

  /// 负载里的文本正文（`content` / `text` / `message`）。
  String get text {
    final p = payload;
    if (p == null) return '';
    for (final key in const ['content', 'text', 'message']) {
      final v = p[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return '';
  }

  factory MiniappWorkEvent.fromJson(Map<String, dynamic> json) =>
      MiniappWorkEvent(
        id: _str(json['id']),
        eventType: _str(json['eventType']),
        seq: _int(json['seq']),
        turnId: _str(json['turnId']),
        groupId: _str(json['groupId']),
        userId: _str(json['userId']),
        agentId: _nullStringColumn(json['agentId']),
        sessionId: _nullStringColumn(json['sessionId']),
        globalSeq: json['globalSeq'] == null ? null : _int(json['globalSeq']),
        source: _str(json['source']),
        payloadJson: json['payloadJson'] is String
            ? json['payloadJson'] as String
            : null,
        createdAt: _date(json['createdAt']),
        raw: json,
      );

  @override
  String toString() => 'MiniappWorkEvent($id, $eventType)';
}

/// 分页的工作列表（`listWorks`）。
class MiniappWorkPage {
  const MiniappWorkPage({required this.items, this.nextCursor});

  final List<MiniappWork> items;

  /// ⚠️ **这是 offset 的字符串形式，不是 id 游标**。
  ///
  /// `listWorks` 用 `parseOffset(c.Query("cursor"))` 解析入参，返回
  /// `strconv.Itoa(offset + len(groups))`。把它当 id 游标传给别的端点（或
  /// 期望它是不透明 token）都会错。
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory MiniappWorkPage.fromJson(Map<String, dynamic> json) =>
      MiniappWorkPage(
        items: _list(json['items'], MiniappWork.fromJson),
        nextCursor: _nullableStr(json['next_cursor']),
      );
}

/// 发消息 / 建工作的派发结果（`dispatchWorkMessage`）。
///
/// ## 三种终态
///
/// | `status` | 含义 |
/// |---|---|
/// | `feedback_recorded` | 命中归属反馈回执，**不建 turn**（`turn_id` 为空串） |
/// | 其它 / 缺省 | 已建 turn，`turn_id` 有值 |
///
/// 注意 `dispatch` 是 `any`：Pipeline 未装配的回退分支只返回 `{turn_id}`，
/// 主链路返回 `{turn_id, agent_id, route_source}`，出错时返回 `{error}`。
class MiniappDispatchResult {
  const MiniappDispatchResult({
    required this.turnId,
    this.groupId = '',
    this.status = '',
    this.agentId,
    this.routeSource,
    this.feedbackRecorded = false,
    this.error,
    this.raw = const {},
  });

  final String turnId;
  final String groupId;
  final String status;
  final String? agentId;
  final String? routeSource;

  final bool feedbackRecorded;

  /// 原始响应，保留未建模字段以备调试。
  final Map<String, dynamic> raw;

  /// 服务端把派发失败**嵌在 200 响应体**里（`{"error": "..."}`）而非用错误码。
  /// 故必须检查它——否则「派发失败」会被当成「成功但没有 turn_id」。
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;

  /// 是否真的建了 turn。
  bool get isQueued => !hasError && !feedbackRecorded && turnId.isNotEmpty;

  factory MiniappDispatchResult.fromJson(Map<String, dynamic> json) =>
      MiniappDispatchResult(
        turnId: _str(json['turn_id']),
        groupId: _str(json['group_id']),
        status: _str(json['status']),
        agentId: _nullableStr(json['agent_id']),
        routeSource: _nullableStr(json['route_source']),
        feedbackRecorded: json['feedback_recorded'] == true,
        error: _nullableStr(json['error']),
        raw: json,
      );

  @override
  String toString() =>
      'MiniappDispatchResult(turn=$turnId, status=$status, error=$error)';
}

/// 通知订阅额度（`notifications.Subscription`）。
///
/// ## 额度语义
///
/// `POST` 的请求体是 `{"accepted": {"<template_key>": n}}`：
/// - `n > 0`：微信弹窗 accept，**累加**额度（`AddQuota`）；
/// - `n == 0`：用户拒收，额度归零并禁用（`ResetQuota`），再次 accept 自动恢复。
///
/// 未知 `template_key` 服务端返回 **400**（不会静默忽略）。
class MiniappNotificationSubscription {
  const MiniappNotificationSubscription({
    required this.templateKey,
    required this.remainingQuota,
    required this.enabled,
    this.userId = '',
    this.updatedAt,
  });

  final String templateKey;
  final int remainingQuota;
  final bool enabled;
  final String userId;
  final DateTime? updatedAt;

  factory MiniappNotificationSubscription.fromJson(Map<String, dynamic> json) =>
      MiniappNotificationSubscription(
        templateKey: _str(json['template_key']),
        remainingQuota: _int(json['remaining_quota']),
        enabled: json['enabled'] == true,
        userId: _str(json['user_id']),
        updatedAt: _date(json['updated_at']),
      );

  @override
  String toString() =>
      'MiniappNotificationSubscription($templateKey, quota=$remainingQuota, '
      'enabled=$enabled)';
}

/// 通知模板白名单。
///
/// **真源**：`apps/go-api/internal/notifications/store.go` 的 `KnownTemplate`。
/// 本类是它的镜像，两边必须同步（同 [EventTypes] 的做法）。
///
/// ## 为什么必须用白名单 key，不能自造
///
/// `saveNotificationSubscriptions` 逐个 `KnownTemplate` 校验，**有一个不认就
/// 整体 400**——不是忽略那一项。故传一个拼错的 key 会让整批保存失败，
/// 而调用方可能只看到「保存失败」四个字。
///
/// ## 四个 key 的真实地位不同（读代码前必须知道）
///
/// | key | 地位 |
/// |---|---|
/// | [notify] | **唯一有生产者**的 key。turn 完成/失败、待确认三类事件都由
/// `OutboxService` 以它入队（`dispatcher.go` 的 `EnqueueTurnCompleted` /
/// `EnqueueConfirmationRequired`），状态由模板 `phrase` 字段区分 |
/// | [workCompleted] | 与 [notify] **共用同一微信模板**（`TemplateMap.ID` 里两者都
/// 解析到 `Completed`）。保留用于兼容历史 `miniapp_subscriptions` 行 |
/// | [workFailed] | 服务端**预留**：`TemplateMap` 有对应字段但 `MINIAPP_NOTIFY_TEMPLATE_FAILED`
/// 未配置，且当前**没有任何事件会以它入队** |
/// | [confirmationRequired] | 同上，预留 |
///
/// 后两个 key 写入是**成功的**（白名单放行），只是没有事件会消耗它们的额度。
/// 这是服务端的现状，不是客户端的 bug——UI 如实展示即可，但文案不该
/// 暗示「打开它就能收到某类通知」。
class MiniappNotificationTemplates {
  // 私有构造：纯常量命名空间（全部成员是 `static const String`），任何地方
  // 都不会调用——结构上不可达，非「漏测」。
  const MiniappNotificationTemplates._(); // coverage:ignore-line

  /// 三类事件共用的主 key（唯一有生产者）。
  static const notify = 'notify';

  /// 与 [notify] 共用同一微信模板的历史兼容 key。
  static const workCompleted = 'work_completed';

  /// 服务端预留（无生产者）。
  static const workFailed = 'work_failed';

  /// 服务端预留（无生产者）。
  static const confirmationRequired = 'confirmation_required';

  /// 全部白名单 key，顺序即 UI 展示顺序（主 key 在前）。
  static const all = <String>[
    notify,
    workCompleted,
    workFailed,
    confirmationRequired,
  ];

  /// 是否白名单 key（客户端侧预校验，避免把整批保存打成 400）。
  static bool isKnown(String key) => all.contains(key);
}

// ==================== 归一化辅助 ====================
//
// 与 `ChatInboxMessage` 同策略：服务端 `nullStr` 产出 JSON null、`iso` 对零值
// 时间产出**空串**、`gin.H` 里的数字可能是 int 也可能是 float64（经
// `json.Unmarshal` 走一遍会变成 float64）。全部在此归一，调用方只面对干净类型。

String _str(Object? v) => v is String ? v : (v == null ? '' : v.toString());

String? _nullableStr(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return v;
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

DateTime? _date(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v)?.toLocal();
}

Map<String, dynamic> _map(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return const {};
}

Map<String, dynamic>? _mapOrNull(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return Map<String, dynamic>.from(v);
  return null;
}

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) fromJson) {
  if (v is! List) return const [];
  final out = <T>[];
  for (final e in v) {
    if (e is Map) out.add(fromJson(Map<String, dynamic>.from(e)));
  }
  return out;
}

/// 归一 `sql.NullString` 的 JSON 形态。
///
/// Go 的 `sql.NullString` 没有自定义 `MarshalJSON`（全仓库 grep 无命中），
/// 故序列化为 `{"String":"a1","Valid":true}`。也容忍服务端将来改成裸字符串
/// 或 null——三种形态都归一成 `String?`。
String? _nullStringColumn(Object? v) {
  if (v is String) return v.isEmpty ? null : v;
  if (v is Map) {
    final valid = v['Valid'] ?? v['valid'];
    if (valid == false) return null;
    final s = v['String'] ?? v['string'];
    if (s is String && s.isNotEmpty) return s;
  }
  return null;
}
