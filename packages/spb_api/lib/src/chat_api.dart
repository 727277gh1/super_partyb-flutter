import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// 聊天领域 API 客户端。
///
/// 端点全部来自 Go API 真实路由（见 `apps/go-api/internal/server/`）：
/// - `chat.go` → `/chat/groups*`
/// - `chat_stream.go` → `/users/:user_id/chat/*`
/// - `chat_ext.go` → goal / schedule / fork / workspace-sync
///
/// ⚠️ 本类只做「调用 + 反序列化」，**不含业务决策**（如路由、重试策略）。
class ChatApi {
  ChatApi(this._dio);

  final Dio _dio;

  // ==================== 分组 ====================

  /// `GET /chat/groups?status=&limit=&offset=`
  Future<List<ChatGroup>> listGroups({
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _get(
      '/chat/groups',
      query: {
        if (status != null && status.isNotEmpty) 'status': status,
        'limit': limit,
        'offset': offset,
      },
    );
    return unwrapItems(res, ChatGroup.fromJson);
  }

  /// `GET /chat/groups/:group_id`
  Future<ChatGroup> getGroup(String groupId) async {
    final res = await _get('/chat/groups/$groupId');
    return ChatGroup.fromJson(_asMap(res));
  }

  /// `POST /chat/groups`
  Future<ChatGroup> createGroup({
    required String title,
    String? agentId,
    Map<String, dynamic>? metadata,
  }) async {
    final res = await _post(
      '/chat/groups',
      body: {
        'title': title,
        if (agentId != null) 'agent_id': agentId,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return ChatGroup.fromJson(_asMap(res));
  }

  /// `PATCH /chat/groups/:group_id`
  ///
  /// 只发送显式传入的字段（PATCH 语义：未传的字段不变）。
  Future<ChatGroup> patchGroup(
    String groupId, {
    String? title,
    String? status,
    String? goal,
    Map<String, dynamic>? metadata,
  }) async {
    final res = await _patch(
      '/chat/groups/$groupId',
      body: {
        if (title != null) 'title': title,
        if (status != null) 'status': status,
        if (goal != null) 'goal': goal,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return ChatGroup.fromJson(_asMap(res));
  }

  /// `DELETE /chat/groups/:group_id`
  Future<void> deleteGroup(String groupId) => _delete('/chat/groups/$groupId');

  /// `POST /chat/groups/:group_id/archive`
  Future<void> archiveGroup(String groupId) =>
      _post('/chat/groups/$groupId/archive');

  /// `POST /chat/groups/:group_id/unarchive`
  Future<void> unarchiveGroup(String groupId) =>
      _post('/chat/groups/$groupId/unarchive');

  // ==================== 归档结项快照 ====================
  //
  // 端点见 Go `internal/server/archive_site.go` 与 `archive_snapshot_download.go`。
  //
  // ## 为什么列表摘要走 group DTO，而这里只做「动作 + 下载」
  //
  // 快照摘要已嵌在 `GET /chat/groups` 的每个 group 里（`archive_snapshot`），
  // 列表页不需要逐个请求（N+1）。这里只提供：
  //   - 下载正文（markdown / html）
  //   - 站点重新部署 / 公开（两个异步动作）
  //
  // ## 为什么不提供「查询快照列表」方法
  //
  // `GET .../archive-snapshots` 返回该 group 的**全部历史版本**，而客户端
  // 目前只展示最新版（已嵌在 group 里）。没有调用方的方法不提前写——
  // 写了就要跟着服务端演进维护，且容易被人误用成列表数据源（N+1）。

  /// `GET .../archive-snapshots/:snapshot_id/markdown`
  ///
  /// 下载快照全文 markdown（权威正文，含诊断字段与完整对话摘要）。
  ///
  /// ## 为什么返回字节而不是 String
  ///
  /// 服务端流式转发 UFS 内容并带 `Content-Disposition: attachment`。返回
  /// `String` 会强制客户端按 UTF-8 解码——markdown 确实是 UTF-8，但保持字节
  /// 让调用方自己决定（写文件、解码展示、或原样转存）。与
  /// [MiniappApi.downloadArtifact] 的取舍一致。
  ///
  /// ## 状态码语义
  ///
  /// - 409：快照正文未就绪（`status != ready`），或该快照没有 markdown 形态
  /// - 410：UFS 侧文件已删（快照行还在，正文没了）
  /// - 502：UFS 不可达
  ///
  /// 这些都经 [_unwrap] 转成 [HttpError]，调用方按 `statusCode` 区分。
  Future<List<int>> downloadSnapshotMarkdown(
    String groupId,
    String snapshotId,
  ) => _downloadSnapshot(groupId, snapshotId, 'markdown');

  /// `GET .../archive-snapshots/:snapshot_id/html`
  ///
  /// 下载自包含 HTML（单文件、内联样式，离线可读）。语义同
  /// [downloadSnapshotMarkdown]。
  Future<List<int>> downloadSnapshotHtml(String groupId, String snapshotId) =>
      _downloadSnapshot(groupId, snapshotId, 'html');

  Future<List<int>> _downloadSnapshot(
    String groupId,
    String snapshotId,
    String format,
  ) async {
    final path = '/chat/groups/$groupId/archive-snapshots/$snapshotId/$format';
    try {
      final res = await _dio.get<List<int>>(
        path,
        // 必须显式指定 bytes：默认 ResponseType.json 会拿 markdown/html 去按
        // JSON 解析（二进制直接失败；文本被解析后再序列化会破坏内容）。
        options: Options(responseType: ResponseType.bytes),
      );
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
      }
      return res.data ?? const <int>[];
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `POST .../archive-snapshots/:snapshot_id/site/redeploy`
  ///
  /// 重新触发站点渲染。用于：
  /// - UFS 重启后站点被重置为 failed，需要一次显式 redeploy 才能恢复；
  /// - 改了站点源想重新编译；
  /// - 首次发布超时（`render_status` 长期 pending）。
  ///
  /// ## 返回值的两种「非错误」状态
  ///
  /// 服务端可能返回 `site_status` 为 `pending`（渲染仍在进行）或 `none`
  /// （站点从未建成、已重置待 worker 重建）——都是 **202 语义**，不是失败。
  /// 调用方应据此刷新列表而不是报错。
  Future<ArchiveSnapshotSiteAction> redeploySnapshotSite(
    String groupId,
    String snapshotId,
  ) => _siteAction(groupId, snapshotId, 'redeploy');

  /// `POST .../archive-snapshots/:snapshot_id/site/publish`
  ///
  /// 把站点从 staging 切到 production（**公开可见**）。
  ///
  /// ## ⚠️ UI 必须二次确认
  ///
  /// 发布后任何人拿到 URL 就能读，而快照含对话摘要与工作区结构。这是不可逆的
  /// 对外动作（撤回只能重新 deploy 回 staging，URL 已可能被转发出去）。
  Future<ArchiveSnapshotSiteAction> publishSnapshotSite(
    String groupId,
    String snapshotId,
  ) => _siteAction(groupId, snapshotId, 'publish');

  Future<ArchiveSnapshotSiteAction> _siteAction(
    String groupId,
    String snapshotId,
    String action,
  ) async {
    final res = await _post(
      '/chat/groups/$groupId/archive-snapshots/$snapshotId/site/$action',
    );
    return ArchiveSnapshotSiteAction.fromJson(_asMap(res));
  }

  // ==================== 群级开关与目标 ====================
  //
  // 这一组全部是服务端注册的 **PUT 专用端点**（`chat_ext.go:83-89`），
  // 而不是 `PATCH /chat/groups/:id` 的 metadata 通道。
  //
  // ## 为什么不能用 PATCH 的 metadata 通道
  //
  // PATCH 是**整包替换**语义：只提交 `{metadata: {goal_gate: ...}}` 会把
  // `metadata.tts` / `metadata.follow_up_suggest` 等其它子系统写入的键一并
  // 清掉（webapp 的历史 bug）。专用端点服务端做 CAS 读-改-写，既保留其它键，
  // 也不与 goal gate worker / title gate / 另一台设备等并发写者互相覆盖。
  //
  // ## 为什么这些方法都返回 void
  //
  // 服务端只回 `{updated: true}` / `{enabled: ...}` / `{tts: ...}`，**没有**
  // group。若照 `ChatGroup.fromJson({updated: true})` 解析会得到字段全空的对象
  // （`id: ''`、`title: ''`），把它写回列表会让该条目变成空白行。故由调用方
  // 补一次 [getGroup] 取权威状态——与 `GroupManagementUseCase._reload` 同一约定。

  /// `PUT /chat/groups/:group_id/goal-gate` —— 「自动实现目标」开关与熔断上限。
  ///
  /// 两个字段共用一个 CAS 端点，**只提交显式传入的键**：
  /// - 只传 [maxAutoTurns] 时 `enabled` 保持不变（服务端 `toggleEnabled` 为 false，
  ///   不触发「开启需有目标」预检）。
  /// - 服务端要求两者**至少传一个**，都不传则 400。
  /// - [maxAutoTurns] 服务端会 clamp 到 `1..200`（越界夹取而非报错）。
  ///
  /// ## 开启时会校验非空目标
  ///
  /// `enabled: true` 而该 group 既没有结构化 goal 也没有旧 `group.goal` 列时，
  /// 服务端返回 **400 `{error: 'goal_required'}`**（开了也没法判定是否达成）。
  /// 调用方应提示「请先设置目标」而不是「保存失败」。
  Future<void> setGroupGoalGate(
    String groupId, {
    bool? enabled,
    int? maxAutoTurns,
  }) async {
    await _put(
      '/chat/groups/$groupId/goal-gate',
      body: {
        if (enabled != null) 'enabled': enabled,
        if (maxAutoTurns != null) 'max_auto_turns': maxAutoTurns,
      },
    );
  }

  /// `PUT /chat/groups/:group_id/follow-up-suggest` —— 「后续提问建议」开关。
  ///
  /// ⚠️ 这是**双层开关**：本端点只写 group 级 `metadata.follow_up_suggest`，
  /// 全局 `FOLLOW_UP_SUGGEST_ENABLED` 为 false 时即使开启也不会生效。
  ///
  /// 关闭时服务端**删键而非写 false**（「键缺失 = 关闭」），读取方
  /// [ChatGroup.followUpSuggestEnabled] 对缺失键返回 false，语义一致。
  Future<void> setGroupFollowUpSuggest(String groupId, bool enabled) async {
    await _put(
      '/chat/groups/$groupId/follow-up-suggest',
      body: {'enabled': enabled},
    );
  }

  /// `PUT /chat/groups/:group_id/habit-suggest` —— 「习惯建议」开关。
  ///
  /// ## 与 [setGroupFollowUpSuggest] 逐行同构
  ///
  /// 服务端 handler（`chat_ext.go` 的 `setHabitSuggest`）是 `setFollowUpSuggest`
  /// 的复制：同一套 CAS 读-改-写、关闭时 `delete(meta, 'habit_suggest')`
  /// （「键缺失 = 关闭」），故这里也照抄同一形状。
  ///
  /// ## 为什么必须走专用端点而非 PATCH metadata
  ///
  /// `PATCH /chat/groups/:id` 是 metadata **整包替换**：只提交 `{habit_suggest}`
  /// 会连带清掉 `metadata.tts` / `metadata.follow_up_suggest` / `goal_gate`
  /// 等其它子系统写入的键（webapp 的历史 bug）。
  ///
  /// ## 与 goal gate 无依赖（与历史行为不同）
  ///
  /// 习惯引导曾经嵌在 goal 约定尾部，未开 goal gate 的群组永远拿不到。拆出后
  /// 只要本开关 + 全局总闸 `HABIT_SUGGEST_ENABLED` 均为真即注入——故这是**双层
  /// 开关**，面板文案不得承诺「已生效」。
  Future<void> setGroupHabitSuggest(String groupId, bool enabled) async {
    await _put(
      '/chat/groups/$groupId/habit-suggest',
      body: {'enabled': enabled},
    );
  }

  /// `PUT /chat/groups/:group_id/tts` —— 语音回复及其子开关。
  ///
  /// 全部参数可空，**只提交显式传入的键**（服务端要求至少传一个，否则 400）：
  ///
  /// - [enabled]：总开关。`false` 时服务端**整块删除** `metadata.tts`；
  ///   **只传子开关时不动总开关**（否则「只改思考播报」会意外把语音回复整个关掉）。
  /// - [narrateThinking]：思考阶段播报。开启时服务端归一化写入
  ///   `narrate_thinking: true` + `narration_mode`；关闭时删两个键。
  /// - [narrationMode]：`filler`（默认）或 `summary`。仅传本参数时，服务端**只在
  ///   播报已开启时**才写入，避免留下 `narrate_thinking` 缺失但
  ///   `narration_mode` 存在的畸形配置。
  /// - [fileSummary]：文件产出播报。
  ///
  /// 服务端做浅合并，`provider_key` / `voice_id` 等本方法不管理的字段会被保留。
  Future<void> setGroupTts(
    String groupId, {
    bool? enabled,
    bool? narrateThinking,
    String? narrationMode,
    bool? fileSummary,
  }) async {
    await _put(
      '/chat/groups/$groupId/tts',
      body: {
        if (enabled != null) 'enabled': enabled,
        if (narrateThinking != null) 'narrate_thinking': narrateThinking,
        if (narrationMode != null) 'narration_mode': narrationMode,
        if (fileSummary != null) 'file_summary': fileSummary,
      },
    );
  }

  /// 设置 group 的目标文本（走**结构化 goal 表**，迁移 0022）。
  ///
  /// ## 为什么不用 `PUT /chat/groups/:group_id/goal`
  ///
  /// 那个端点（`chat_ext.go:112`）写的是 `chat_groups.goal` **旧列**——迁移 0022
  /// 之后该列已不再被写入（「goal 变更 = 新建 `chat_goals` 行」）。保留它只是为
  /// 兼容存量数据（`goalGateEffectiveGoal` 会回退读旧列）。本方法对齐 webapp，
  /// 走结构化表，使 goal 变更后**任务列表与进度**也跟着走同一份数据。
  ///
  /// ## 语义：goal 变更 = 重新创建 goal
  ///
  /// 旧 active goal 由服务端归档，其历史与任务全部保留。故：
  ///
  /// 1. 先读当前 goal（`GET .../goals/current`，无 goal 时服务端回 `goal: null`）；
  /// 2. **文本与当前 goal 相同时直接返回，不建新行**——否则双击保存（或调用方
  ///    没禁用按钮）就会留下一串内容相同的 goal 版本，而「重新创建」语义下这
  ///    不可逆（旧行只能归档）；
  /// 3. 文本非空 → `POST .../goals` 新建；
  /// 4. 文本为空且存在 current → `PATCH /chat/goals/:id` 置 `status=archived`。
  ///    **不建新行**，否则会留下一堆空目标。
  ///
  /// 返回 void，由调用方补一次 [getGroup] 取权威状态（同本节的其它写方法）。
  Future<void> setGroupGoal(String groupId, String goalText) async {
    final text = goalText.trim();
    final current = await _currentGoal(groupId);
    if (current != null && current.goalText.trim() == text) return;
    if (text.isNotEmpty) {
      await _post(
        '/chat/groups/$groupId/goals',
        body: {'goal_text': text, 'tasks_source': 'manual'},
      );
    } else if (current != null) {
      await _patch('/chat/goals/${current.id}', body: {'status': 'archived'});
    }
  }

  /// 读 `GET /chat/groups/:group_id/goals/current` 的当前 goal。
  ///
  /// 只取 [setGroupGoal] 需要的两个字段（id 与文本），不建完整 DTO：服务端还回
  /// `tasks` / `progress`，而本轮客户端不消费它们（Goal/Task 全量管理不在范围内）。
  /// 无 goal 时服务端回 `{goal: null}`，此处归一成 `null`。
  Future<({String id, String goalText})?> _currentGoal(String groupId) async {
    final res = await _get('/chat/groups/$groupId/goals/current');
    final goal = _asMap(res)['goal'];
    if (goal is! Map) return null;
    final m = Map<String, dynamic>.from(goal);
    final id = (m['id'] as String?) ?? '';
    if (id.isEmpty) return null;
    return (id: id, goalText: (m['goal_text'] as String?) ?? '');
  }

  // ==================== 时间线 ====================

  /// `GET /chat/groups/:group_id/timeline`
  ///
  /// 游标分页：首次不带 [beforeGlobalSeq]，后续传上一页的 `nextCursor`。
  ///
  /// 服务端同时兼容旧游标 `before_time` + `before_seq`，但客户端**只用新游标**
  /// （`before_global_seq`）——两套混用会导致分页错乱（见 `chat.go` 注释）。
  Future<CursorPage<ChatEvent>> groupTimeline(
    String groupId, {
    int limit = 200,
    String? beforeGlobalSeq,
  }) async {
    final res = await _get(
      '/chat/groups/$groupId/timeline',
      query: {
        'limit': limit,
        if (beforeGlobalSeq != null && beforeGlobalSeq.isNotEmpty)
          'before_global_seq': beforeGlobalSeq,
      },
    );
    return CursorPage<ChatEvent>.fromJson(_asMap(res), ChatEvent.fromJson);
  }

  // ==================== 轮次 ====================

  /// `POST /chat/groups/:group_id/turns` —— 直接建 turn（不经消息流）。
  ///
  /// 常规对话请用 [sendMessage]（`/users/:uid/chat/messages`），它会跑完整
  /// 前置链（分类 → 路由 → 归属判定）。本方法用于「已知 group 且要绕过前置链」
  /// 的场景（如重试、脚本化操作）。
  ///
  /// ## ⚠️ 请求体字段与响应形状都与 [sendMessage] 不同
  ///
  /// 本端点绑定的是 Go 的 `CreateTurnRequest`（`internal/server/chat.go:476`）：
  ///
  /// ```go
  /// type CreateTurnRequest struct {
  ///     RequestID string `json:"requestId"`   // 注意是 camelCase，不是 request_id
  ///     UserID    string `json:"userId"`      // 已弃用，不参与鉴权
  ///     InputText string `json:"inputText"`   // ← 必填；发 `input` 会 400
  ///     Source    string `json:"source"`
  ///     Channel   string `json:"channel"`
  ///     Metadata  string `json:"metadata"`
  /// }
  /// ```
  ///
  /// 响应是 `CreateTurnResponse{status, groupId, turnId}`（camelCase，**平铺**），
  /// 不是 `ChatTurn`。历史上这里发的是 `{input, agent_id, request_id}` 并解析成
  /// `ChatTurn` —— 字段名与形状**双双不符**，实际调用必然 400
  /// （`InputText` 的 `binding:"required"` 失败）。本方法此前无生产调用者，
  /// 故这个缺陷没有暴露出来（见 #11 的「未接端点族」收口）。
  ///
  /// `agent_id` **不是**本端点的参数：`CreateTurnRequest` 没有该字段，
  /// 服务端按 group 的 active session 决定 agent。要指定 agent 请用
  /// [switchGroupAgent] 或 [sendMessage] 的 `agentId`。
  Future<CreateTurnResult> createTurn(
    String groupId, {
    required String input,
    String? requestId,
    String source = 'direct',
    String? channel,
    String? metadata,
  }) async {
    final res = await _post(
      '/chat/groups/$groupId/turns',
      body: {
        'inputText': input,
        if (requestId != null) 'requestId': requestId,
        'source': source,
        if (channel != null) 'channel': channel,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return CreateTurnResult.fromJson(_asMap(res));
  }

  /// `GET /chat/groups/:group_id/turns`
  Future<List<ChatTurn>> listTurns(
    String groupId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final res = await _get(
      '/chat/groups/$groupId/turns',
      query: {'limit': limit, 'offset': offset},
    );
    return unwrapItems(res, ChatTurn.fromJson);
  }

  /// `GET /chat/turns/:turn_id`
  Future<ChatTurn> getTurn(String turnId) async {
    final res = await _get('/chat/turns/$turnId');
    return ChatTurn.fromJson(_asMap(res));
  }

  /// `POST /chat/turns/:turn_id/cancel`
  Future<void> cancelTurn(String turnId) => _post('/chat/turns/$turnId/cancel');

  // ==================== 用户消息流（含无归属入口）====================

  /// `POST /users/:user_id/chat/messages`
  ///
  /// ## 这是主要发消息入口
  ///
  /// 请求体字段（对齐 Go 侧 `sendChatToAgentRequest`）：
  /// - `input`：消息文本
  /// - `group_id`：**可省略**。省略时服务端走完整分类链判定归属，
  ///   这正是「无归属入口」（桌面端悬浮窗、MQ inbound）的语义。
  /// - `agent_id`：可省略，省略时由路由决定
  /// - `routing.mode`：`auto`（默认，允许路由）或 `manual`（强制用 group_id）
  /// - `request_id`：客户端幂等键，同值重复提交不新建 turn
  ///
  /// ⚠️ **桌面端悬浮输入窗必须不带 group_id**，与 MQ inbound 保持同一语义。
  /// 详见 super_partyb AGENTS.md「桌面端」章节。
  ///
  /// 返回：入队结果（含 turn_id 与最终判定的 group_id）。
  Future<SendMessageResult> sendMessage(
    String userId, {
    required String input,
    String? groupId,
    String? agentId,
    String routingMode = 'auto',
    String? requestId,
    Map<String, dynamic>? options,
  }) async {
    final res = await _post(
      '/users/$userId/chat/messages',
      body: {
        'input': input,
        if (groupId != null && groupId.isNotEmpty) 'group_id': groupId,
        if (agentId != null && agentId.isNotEmpty) 'agent_id': agentId,
        'routing': {'mode': routingMode},
        if (requestId != null) 'request_id': requestId,
        if (options != null) 'options': options,
      },
    );
    return SendMessageResult.fromJson(_asMap(res));
  }

  /// `GET /users/:user_id/chat/messages/pending?group_id=&limit=`
  ///
  /// 查询尚未处理的**收件箱消息**，用于冷启动时恢复进行中的对话。
  ///
  /// ⚠️ 返回的是 `chat_inbox_messages` 行（见 Go 侧 `inboxToDict`），**不是**
  /// [ChatTurn]：字段名是 `input`（而非 `input_text`）、`agent_type`、`processed_at`。
  /// 路径名有迷惑性，但服务端实现就在 `internal/server/chat_inbox.go` 的 `pending`。
  ///
  /// 默认只返回 `pending`（服务端在无 `group_id` 时还会多取一批再按状态过滤），
  /// 故调用方拿到的都是 [ChatInboxMessage.isPending] 为 true 的条目。
  Future<List<ChatInboxMessage>> pendingMessages(
    String userId, {
    String? groupId,
    int limit = 20,
  }) async {
    final res = await _get(
      '/users/$userId/chat/messages/pending',
      query: {if (groupId != null) 'group_id': groupId, 'limit': limit},
    );
    return unwrapItems(res, ChatInboxMessage.fromJson);
  }

  /// `POST /users/:user_id/chat/messages/:message_id/undo`
  Future<void> undoMessage(String userId, String messageId) =>
      _post('/users/$userId/chat/messages/$messageId/undo');

  /// `POST /users/:user_id/chat/messages/flush`
  ///
  /// 把缓冲区中的 pending 收件箱消息立即合并成一个 turn（通常用于「输入完立刻
  /// 发送」）。
  ///
  /// ## 为什么返回 [FlushResult] 而不是 `void`
  ///
  /// 原签名是 `Future<void>`，那会**丢掉一个关键状态**：服务端在「有**多条**
  /// pending 且未指定 `conflict_strategy`」时返回 **HTTP 200** 加
  /// `{status: "confirmation_required", ...}`——**什么都没提交**，而是要求
  /// 调用方选一个冲突策略后重试。只看状态码会把它当成成功。
  ///
  /// 把返回类型从 `Future<void>` 放宽到 `Future<FlushResult>` 是**兼容性变更**：
  /// 忽略返回值的既有调用方式（`await api.flushMessages(...)`）完全不受影响，
  /// 而需要区分两种结果的调用方拿到了信息。
  ///
  /// ## 为什么只传 `group_id`
  ///
  /// 服务端还接受 `message_ids`（指定要 flush 哪几条）。本方法只做
  /// 「把当前 group 的 pending 全部立即提交」这一种用法，与 UI 的
  /// 「立即发送」按钮语义一致。需要指定 message_ids 或冲突策略时用
  /// [flushMessagesDetailed]。
  Future<FlushResult> flushMessages(String userId, {String? groupId}) async {
    final res = await _post(
      '/users/$userId/chat/messages/flush',
      body: {if (groupId != null) 'group_id': groupId},
    );
    return FlushResult.fromJson(_asMap(res));
  }

  /// 带完整参数的 flush（可指定 `message_ids` 与 `conflict_strategy`）。
  ///
  /// 用于「多条 pending 待确认」后用户选定策略的重试。见 [flushMessages] 的
  /// 说明。
  Future<FlushResult> flushMessagesDetailed(
    String userId, {
    String? groupId,
    List<String>? messageIds,
    String? conflictStrategy,
  }) async {
    final res = await _post(
      '/users/$userId/chat/messages/flush',
      body: {
        if (groupId != null) 'group_id': groupId,
        if (messageIds != null && messageIds.isNotEmpty)
          'message_ids': messageIds,
        if (conflictStrategy != null) 'conflict_strategy': conflictStrategy,
      },
    );
    return FlushResult.fromJson(_asMap(res));
  }

  // ==================== 桌面悬浮输入窗（无归属入口）====================

  /// `POST /me/quick-capture` —— 桌面端悬浮输入窗的提交端点。
  ///
  /// ## 为什么走 `/me/*` 而不是 `/users/:uid/chat/messages`
  ///
  /// 悬浮窗是一个 480×86 的单行输入框，**没有对话上下文**：用户按 Alt+Space 打字
  /// 回车时，屏幕上没有「当前对话」可言。服务端为此提供专设端点，语义是「把一句话
  /// 交给平台，由平台决定它属于哪个对话」——与 MQ inbound 同一条分类链。
  ///
  /// 路径挂 `/me/*` 的原因：桌面壳**不知道也不应知道**自己的 user_id，身份由服务端
  /// 从网关注入的 session 解析。若做成 `/users/:id/*`，壳就得先拿 id 再发第二条请求，
  /// 且拿到 id 后还能改它（徒增一个越权面）。
  ///
  /// ## 请求体只有 `input`（安全设计，不是偷懒）
  ///
  /// 服务端**刻意不接受** `group_id` / `agent_id` / `user_id`：本端点的整个意义就是
  /// 「调用方不指定归属」，开放这三个字段等于让调用方绕过分类链、把消息塞进任意
  /// 对话（越权写入他人 group 的入口）。故本方法**不提供**这些参数。
  ///
  /// ## 返回值：`group_id` 是本端点的产出
  ///
  /// 同步返回 [QuickCaptureResult.groupId] 是关键——桌面壳据此把主窗口导航到该对话。
  /// 但要注意 [QuickCaptureResult.isFeedbackRecorded] 是**终态**（不建 turn），
  /// 此时不应导航、不应等回答。
  Future<QuickCaptureResult> quickCapture({required String input}) async {
    final res = await _post('/me/quick-capture', body: {'input': input});
    return QuickCaptureResult.fromJson(_asMap(res));
  }

  /// `POST /me/quick-capture/attachments` —— 上传附件到通用入站暂存区。
  ///
  /// ## 为什么先上传再投递（两个请求）
  ///
  /// 入队接口只接受**元数据**（download_url），字节必须先落盘。这不是设计缺陷：
  /// 附件可达 50 MiB，塞进消息体会让它被 json.Marshal 写进 mq-server 的 WAL，
  /// 且 at-least-once 下每次重投都重复传输同一份字节。
  ///
  /// ## 为什么只传字节，不传 URL
  ///
  /// 服务端（PartyB）会带着自己的服务级凭证去访问它。若由客户端指定 URL，
  /// 就出现了一个 SSRF 面（可指向任意内网地址）。故本方法只传字节，
  /// 由服务端上传 UFS 并返回 file_id。
  ///
  /// 返回 [QuickCaptureUpload]，其中 [QuickCaptureUpload.fileId] 要填进
  /// [enqueueQuickCapture] 的 `attachments`。
  ///
  /// ## 为什么同时接受 [path] 与 [bytes]（而不是只留一个）
  ///
  /// 两个来源的物理限制不同：
  ///
  ///   - 拖拽/文件选择给到的是**磁盘上的路径**（[path]）。走这条路时用
  ///     [MultipartFile.fromFile]，Dio 从磁盘流式读取——50 MiB 的文件不会在
  ///     内存里出现第二份副本。
  ///   - 剪贴板粘贴给到的是**内存里的字节**（[bytes]），根本没有路径可传。
  ///
  /// 两者都接受后，调用方无需为「粘贴的图」先写一个临时文件。
  ///
  /// ## 为什么优先用 [path]
  ///
  /// [bytes] 那条路要把整个文件先读进内存（调用方读 + 本层 multipart 缓冲），
  /// 而桌面端最常见的附件来源恰好是有路径的文件。故有路径时必须走路径。
  Future<QuickCaptureUpload> uploadQuickCaptureAttachment({
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) async {
    // Why 用运行时抛错而不是 assert：assert 只在 debug 构建里生效，release
    // 下会被完全剔除。若调用方两个都没传，bytes! 会抛一个空指针错误——错误
    // 信息指向 bytes 而不是「你没传参数」，排障成本高。
    if ((bytes == null) == (path == null)) {
      throw ArgumentError(
        'uploadQuickCaptureAttachment 必须且只能给 bytes 或 path 之一',
      );
    }
    try {
      final mediaType = contentType == null
          ? null
          : DioMediaType.parse(contentType);
      final part = path != null
          ? await MultipartFile.fromFile(
              path,
              filename: filename,
              contentType: mediaType,
            )
          : MultipartFile.fromBytes(
              bytes!,
              filename: filename,
              contentType: mediaType,
            );
      final form = FormData.fromMap({'file': part});
      final res = await _dio.post<dynamic>(
        '/me/quick-capture/attachments',
        data: form,
      );
      return QuickCaptureUpload.fromJson(_asMap(_unwrap(res)));
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `POST /me/quick-capture/enqueue` —— 把（可带附件的）消息投进 mq-server 队列。
  ///
  /// ## 与 [quickCapture] 的差别
  ///
  /// 语义相同（无归属入口），差别有二：
  ///
  /// | | `/me/quick-capture` | `/me/quick-capture/enqueue` |
  /// |---|---|---|
  /// | 链路 | 直接走 chatpipeline | 投进 mq-server 队列，由 worker 消费 |
  /// | 附件 | ❌ | ✅ |
  /// | 返回 | `group_id`（可导航） | 仅 202 受理 |
  ///
  /// ## 为什么不返回 group_id（调用方不能据此导航）
  ///
  /// 归属判定发生在 worker 侧，是**异步**的。本端点只保证「投递已受理」。
  /// 需要立即导航的场景应用 [quickCapture]（但它不支持附件）。
  ///
  /// 客户端观察结果的方式是订阅 SSE（与其它异步 turn 一致）。
  Future<void> enqueueQuickCapture({
    String input = '',
    List<String> attachments = const [],
  }) async {
    await _post(
      '/me/quick-capture/enqueue',
      body: {
        'input': input,
        if (attachments.isNotEmpty) 'attachments': attachments,
      },
    );
  }

  // ==================== 交付物回传（workspace-sync）====================

  /// `POST /chat/groups/:group_id/workspace-sync/ufs-upload` —— 回传本地改动。
  ///
  /// 服务端一次完成两件事（`workspace_sync.go` 的 `ufsUpload`）：
  /// UFS overwrite（新版本入 `file_versions`）+ 写 workspace 挂载目录
  /// （`sync_status=local_synced`），agent 在下一个 turn 就能读到新内容。
  ///
  /// ## 端点前缀必须带 `/chat`
  ///
  /// 注册链：`router.go` 的 `chatRG := r.Group("/chat")` → `chat_ext.go`
  /// 挂 `workspace-sync`。漏掉 `/chat` 会 **404**（不在任何路由树里）。
  ///
  /// ## [relativePath] 是**组内**相对路径
  ///
  /// 服务端自己拼 `workspace/groups/{groupId}/`。若把同步目录里的
  /// `{gid}/` 前缀也传上去，文件会落到 `workspace/groups/{gid}/{gid}/...`
  /// ——不报错，但位置不对，且下轮同步会在两个位置各出现一份。调用方
  /// （回传编排）负责用 `uploadTargetFor` 剥前缀。
  ///
  /// ## 为什么同时接受 [path] 与 [bytes]（同 [uploadQuickCaptureAttachment]）
  ///
  /// 拖拽/文件选择来的文件有磁盘路径，`MultipartFile.fromFile` 流式读取；
  /// 内存里的字节（如从 `LocalFileReader.readBytes` 读到的）没有路径可传。
  /// 有路径时必须优先走路径，避免大文件在内存里多一份副本。
  ///
  /// ## 体积上限不做客户端预判
  ///
  /// 服务端按 `WorkbenchFileContextMaxBytes` 拒收（默认 1 MiB，可配），
  /// 超限返回 **413**。客户端拿不到服务端实际生效值，故不复制这个上限，
  /// 而是接住 413 改走 quick-capture 附件链兑底（见
  /// `docs/deliverable-upload-and-conflict.md` §2.1③）。
  ///
  /// ## 响应不含 etag，不能 markSynced
  ///
  /// `fileEntryToMap` 不回 etag，客户端无法据此把文件标记为「已同步」。
  /// 收口靠下一轮同步：远端 etag 已变 → 重新下载刚上传的内容 → 脏状态
  /// 自然清除。因此 UI 只能说「已回传」，不能说「已同步」。
  Future<WorkspaceFileUpload> uploadWorkspaceFile({
    required String groupId,
    required String relativePath,
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) async {
    // 同 [uploadQuickCaptureAttachment]：运行时校验而非 assert（release 下
    // assert 被剔除，两个都没传时会变成难定位的空指针）。
    if ((bytes == null) == (path == null)) {
      throw ArgumentError('uploadWorkspaceFile 必须且只能给 bytes 或 path 之一');
    }
    try {
      final mediaType = contentType == null
          ? null
          : DioMediaType.parse(contentType);
      final part = path != null
          ? await MultipartFile.fromFile(
              path,
              filename: filename,
              contentType: mediaType,
            )
          : MultipartFile.fromBytes(
              bytes!,
              filename: filename,
              contentType: mediaType,
            );
      final form = FormData.fromMap({
        'file': part,
        'relative_path': relativePath,
      });
      final res = await _dio.post<dynamic>(
        '/chat/groups/$groupId/workspace-sync/ufs-upload',
        data: form,
      );
      // multipart 请求不能走 _post（它会把 FormData 当 JSON body 序列化前的
      // map 处理），但 4xx 判定逻辑必须一致：validateStatus 放行 4xx，
      // 不判会把错误体当成成功响应解析。
      return WorkspaceFileUpload.fromJson(_asMap(_unwrap(res)));
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  // ==================== 当前用户 ====================

  /// `GET /api/auth/me` —— 取当前登录用户。
  ///
  /// ## 为什么必须有这个方法
  ///
  /// [ChatApi] 里所有 `/users/:user_id/chat/*` 方法都要调用方传 `userId`，但此前
  /// **没有任何地方能拿到它**：客户端不解析 JWT、不申请 API Key，身份由网关 OIDC
  /// 注入。本端点是唯一能问到「我是谁」的入口（服务端从 session 解析，不接受参数）。
  ///
  /// 注意路径前缀是 `/api`（`router.go` 里 `apiv1 := r.Group("/api")` 下的
  /// `auth` 组），与 `/chat/*`、`/me/*` 并列而非嵌套。
  Future<CurrentUser> me() async {
    final res = await _get('/api/auth/me');
    return CurrentUser.fromJson(_asMap(res));
  }

  // ==================== 用户偏好 ====================

  /// `GET /me/preferences` —— 读当前用户的偏好。
  ///
  /// ## ⚠️ 路径**不带** `/api` 前缀
  ///
  /// 用户级端点在服务端挂在 `r.Group("/me")`（与 `/me/turns` 同组，见
  /// `router.go` 的 `meRG := r.Group("/me")`），**不在** `apiv1 := r.Group("/api")`
  /// 下。写成 `/api/me/preferences` 会 404，且因前端会把失败降级成「选项区空白」，
  /// 界面上不报错、很难定位——webapp 用回归测试钉住了这一条
  /// （`apps/webapp/src/lib/api/user-preferences.test.ts` 的 `pathOf(...)` 断言
  /// `toBe("/me/preferences")`），客户端照抄该约束。
  ///
  /// 注意与上面 [me] 的对比：那个是 `/api/auth/me`（**带** `/api`）。两个端点的
  /// 前缀不同是既有事实，不能「统一」。
  ///
  /// 服务端只返回**已显式设置**的项，但 `reply_language` 恒有值（未设置时为
  /// `auto`），故调用方无需区分「字段缺失」与「默认」。
  Future<UserPreferences> getPreferences() async {
    final res = await _get('/me/preferences');
    return UserPreferences.fromJson(_asMap(res));
  }

  /// `PUT /me/preferences` —— 部分更新偏好，返回**生效值**。
  ///
  /// ## 只提交显式传入的键
  ///
  /// 服务端是**部分更新**语义（未提交的保持原值），且显式校验「至少要提交一个
  /// 字段」（全空 body 返回 400）。故这里用 `if (x != null)` 逐键拼接，而非提交
  /// 一个完整对象——后者会把未编辑的字段一并覆盖，且空串会被当成「清空」
  /// （例如只改昵称却把回复语言重置成 auto）。
  ///
  /// ## 空串是**有效入参**（清除），不是「不传」
  ///
  /// 三个字段的空串各有语义，且服务端都接受：
  /// - `displayName: ''` / `avatarUrl: ''` → 清除自设值，展示侧回落默认；
  /// - `defaultAgentId: ''` → 恢复「跟随系统默认」（服务端删记录）；
  /// - `replyLanguage: 'auto'` → 同上（删记录），**不是**空串。
  ///
  /// ## 两个 bool 的语义
  ///
  /// [followUpSuggest] / [habitSuggest] 是**新建 group 的默认播种值**，仅影响
  /// 之后新建的 group，不回溯修改既有 group（服务端 `user_preferences.go` 的
  /// `FollowUpSuggest` / `HabitSuggest` 字段注释）。两者与群级同名开关是不同
  /// 层次的东西：本处是「以后新建的默认」，群级那个是「这个对话现在开不开」。
  ///
  /// 同样只在非 null 时写入：传 `false` 是**有意义的显式关闭**，与「不传」
  /// （保持原值）必须区分——若写成 `if (x == true)` 就会永远无法关闭。
  ///
  /// ## 非法 `replyLanguage` 会 400（而非静默回落）
  ///
  /// 服务端对白名单外的语言值直接 400 并带上 `supported` 列表。这是**有意**的：
  /// 静默回落 `auto` 会让用户以为设置成功了。故调用方必须把该错误透出给用户，
  /// 不能吞掉。
  ///
  /// ⚠️ 服务端的文案在 [HttpError.body] 里，**不在** `message`——后者恒为
  /// `"HTTP 400"`（见 [_unwrap]）。要展示给用户必须从 body 提取
  /// `error` / `message` 字段（参见 `GroupSettingsUseCase` 的 `_errorDetail`）。
  ///
  /// ## 返回的是服务端**回读的生效值**
  ///
  /// 与群设置写端点只回布尔不同，这里回的就是完整偏好对象，调用方可直接用它
  /// 替换本地状态（无需再发一次 GET）。
  Future<UserPreferences> updatePreferences({
    String? displayName,
    String? avatarUrl,
    String? replyLanguage,
    String? defaultAgentId,
    String? habitNotifyChannels,
    bool? followUpSuggest,
    bool? habitSuggest,
  }) async {
    final body = <String, dynamic>{
      if (displayName != null) 'display_name': displayName,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (replyLanguage != null) 'reply_language': replyLanguage,
      if (defaultAgentId != null) 'default_agent_id': defaultAgentId,
      if (habitNotifyChannels != null)
        'habit_notify_channels': habitNotifyChannels,
      if (followUpSuggest != null) 'follow_up_suggest': followUpSuggest,
      if (habitSuggest != null) 'habit_suggest': habitSuggest,
    };
    final res = await _put('/me/preferences', body: body);
    return UserPreferences.fromJson(_asMap(res));
  }

  /// `GET /me/turns` —— 跨 group 列出当前用户的最近轮次。
  ///
  /// ## 身份来自网关注入的 `X-User-ID`
  ///
  /// 路径里没有 user_id（服务端 `user_turns.go` 的 `currentUser(c)` 取网关
  /// 注入的头），故不需要调用方传 userId。
  ///
  /// ## 参数
  ///
  /// - [limit]：返回条数（服务端默认 100、上限 200）；
  /// - [days]：时间窗口（服务端默认 7、限制 1–90）；
  /// - [status] / [source] / [groupId]：可选过滤。
  ///
  /// 走 [_get]（内部调 [_unwrap]）：`createDio` 的 `validateStatus` 放行 4xx，
  /// 不补判会把 `404 {"error":...}` 当成功解析成空列表。
  Future<List<ChatTurnSummary>> listMyTurns({
    int limit = 50,
    int? days,
    String? status,
    String? source,
    String? groupId,
  }) async {
    final res = await _get(
      '/me/turns',
      query: {
        'limit': limit,
        if (days != null) 'days': days,
        if (status != null) 'status': status,
        if (source != null) 'source': source,
        if (groupId != null) 'group_id': groupId,
      },
    );
    return unwrapItems(res, ChatTurnSummary.fromJson);
  }

  /// `GET /me/turns/search?q=&limit=` —— 跨 group 按输入文本关键字搜索轮次。
  ///
  /// ## 响应形状与 [listMyTurns] **完全相同**
  ///
  /// 服务端 `user_turns.go` 的 `search` 与 `list` 尾部都调
  /// `turnToListItem(t, groupTitle, habitTurnIDs)`，故这里同样是
  /// `{items: [...]}` 的 [ChatTurnSummary] 投影。
  ///
  /// ⚠️ **不要**改用 [ChatSearchHit]：那是
  /// `/users/:uid/chat/search`（`chat_stream.go` 的 `search`）的投影，字段是
  /// `input_text` / `agent_id`，与本端点不同。误用的后果见 [ChatSearchHit]
  /// 类文档（每个命中项都退化成空对象，不报错）。
  ///
  /// ## 服务端不认筛选条件
  ///
  /// `search` 只读 `q` 与 `limit`（`parseLimit(c.Query("limit"), 20, 50)`）；
  /// **没有** `days` / `status` / `source` / `group_id`。调用方不要在搜索模式下
  /// 继续展示筛选器为「生效中」（UI 侧必须显式提示或禁用）。
  ///
  /// ## 空 [query] 直接返回空列表，**不发请求**
  ///
  /// 服务端对 trim 后为空的 `q` 返回 **400** `{"error":"q is required"}`
  /// （`user_turns.go:169`）。这里拦在客户端：一个必然失败的往返对调用方没有
  /// 价值，且 400 会被 [_unwrap] 抛成 `SpbError`——调用方得为一个「输入还没打
  /// 完」的正常中间态去处理异常。
  ///
  /// 这是本文件里少有的「客户端主动拦下请求」的方法，与其余方法的「照实转发」
  /// 惯例不同，故显式记录。
  ///
  /// ## limit 的语义
  ///
  /// 服务端默认 20、上限 50（超限静默夹到 50，不报错），故客户端不必自己夹。
  Future<List<ChatTurnSummary>> searchMyTurns({
    required String query,
    int limit = 20,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final res = await _get('/me/turns/search', query: {'q': q, 'limit': limit});
    return unwrapItems(res, ChatTurnSummary.fromJson);
  }

  /// `GET /users/:user_id/chat/search?q=&limit=`
  ///
  /// ## 返回的是 turn 摘要，**不是** `ChatEvent`
  ///
  /// 服务端（`chat_stream.go` 的 `search`）返回的是
  /// `{turn_id, group_id, group_title, input_text, created_at, agent_id}`，
  /// **没有** `event_id` / `event_type`。用 `ChatEvent.fromJson` 解析每一项都会
  /// 抛 `FormatException`（该方法对缺失的必需字段做显式校验）。
  ///
  /// 这个陷阱的来源是端点名：它挂在 `/chat/*` 下、又由 `chat_stream.go` 实现，
  /// 很容易让人以为返回事件流的一部分。
  ///
  /// ## limit 的语义
  ///
  /// 服务端 `parseLimit(c.Query("limit"), 20, 50)`：默认 20、上限 50。传超过 50
  /// 会被夹到 50（不会报错），故客户端不必自己夹。
  Future<List<ChatSearchHit>> search(
    String userId, {
    required String query,
    int? limit,
  }) async {
    final res = await _get(
      '/users/$userId/chat/search',
      query: {'q': query, if (limit != null) 'limit': limit},
    );
    return unwrapItems(res, ChatSearchHit.fromJson);
  }

  /// `POST /users/:user_id/chat/routing-preview`
  ///
  /// 预览「这句话会落到哪个 agent」。
  ///
  /// ## ⚠️ 服务端当前**只返回兜底默认 Agent**（文案不得夸大）
  ///
  /// 原实现调 `chatrouter.Resolve` 展示 embedding 级联的 trace；**该级联已移除**
  /// （链 A 下线，见 super_partyb AGENTS.md「相似度算法与打分」）。现在服务端返回
  /// 的是 `PickDefaultAgent` 的结果：用户级 `user.default_agent_id` > 系统级
  /// `router.default_agent_id` > 名字序第一个 active agent（`chat_stream.go` 的
  /// `routingPreview`）。
  ///
  /// 因此：
  /// - **不会返回 group**：响应里没有 `group_id`，归属仍由发消息时的分类链决定；
  /// - `route_source` 恒为 `"fallback"`，`votes` 恒为空；
  /// - `candidates` 是**全部 active agent 的前 5 个**（按 id 排序），与这句话的
  ///   语义无关，不能当成「候选排序」。
  ///
  /// 用 [RoutingPreview.fromJson] 解析返回值得到强类型结果（推荐）。
  ///
  /// 不在本方法里直接返回 `RoutingPreview`：本方法的返回类型是既有公开契约
  /// （`Map`），改它会是一个破坏性变更；而解析只需一行。
  Future<Map<String, dynamic>> routingPreview(
    String userId, {
    required String input,
    String? groupId,
  }) async {
    final res = await _post(
      '/users/$userId/chat/routing-preview',
      body: {'input': input, if (groupId != null) 'group_id': groupId},
    );
    return _asMap(res);
  }

  // ==================== 运行时参数 ====================

  /// `GET /api/chat/turn-runtime` —— 只读的 turn 运行时参数。
  ///
  /// ## 为什么客户端要拉它（而不是硬编码阈值）
  ///
  /// 客户端的「超时兜底」（距最后一条事件过久仍未收到 `done` 时停掉流式光标）
  /// 需要一个阈值，而服务端是可配置的：生产
  /// `CHAT_TURN_REQUEST_TIMEOUT_SECONDS=600`，客户端若写 300 就会把长 turn
  /// 提前判成静止。故这里拉取**服务端生效值**，避免两侧常量漂移
  /// （详见 [TurnRuntime] 类文档）。
  ///
  /// ## 权限
  ///
  /// 与其它 `/api/*` 端点一致，只要求登录态（不要求管理员）——超时时长不是
  /// 机密，而要求管理员会让普通用户拿不到值、只能回落硬编码，等于没修。
  Future<TurnRuntime> turnRuntime() async {
    final res = await _get('/api/chat/turn-runtime');
    return TurnRuntime.fromJson(_asMap(res));
  }

  // ==================== 自动续跑排程 ====================

  /// `GET /api/chat/groups/:group_id/auto-schedules` —— 列出排程。
  ///
  /// ## ⚠️ 路径带 `/api` 前缀（与下面的停用端点不同）
  ///
  /// 两个端点注册在不同的路由组：
  ///
  /// | 端点 | 注册位置 | 实际路径 |
  /// |---|---|---|
  /// | 列出 | `ext_routes.go` 的 `registerScheduleRoutes(api.Group("/chat/groups"))` | `/api/chat/groups/…/auto-schedules`（**复数**） |
  /// | 停用 | `chat_ext.go` 的 `rg.POST("/groups/:group_id/auto-schedule/stop")`（`/chat` 组） | `/chat/groups/…/auto-schedule/stop`（**单数**） |
  ///
  /// 写错任一即 404。客户端已有同类先例（[turnRuntime] 也走 `/api`）。
  ///
  /// ## ⚠️ 必须传 `agent_id` 并本地按 group 过滤
  ///
  /// 服务端 handler（`admin.go` 的 `listByAgent`）**忽略路径里的 `:group_id`**，
  /// 只读 `c.Query("agent_id")`，SQL 是 `WHERE agent_id = ?`。不传 `agent_id`
  /// 会得到空集；传了则得到「该 agent 的全部排程」（可能跨多个 group）。
  /// 故调用方需再用 [ChatTurnSchedule.groupId] 本地过滤出当前 group——
  /// 那层过滤由 spb_domain 的用例做（本层只负责传输）。
  ///
  /// `agent_id` 取 `ChatGroup.activeSession.agentId`（`GET /chat/groups/:id`
  /// 已填）。
  Future<List<ChatTurnSchedule>> listAutoSchedules(
    String groupId, {
    String? agentId,
    int limit = 50,
  }) async {
    final res = await _get(
      '/api/chat/groups/$groupId/auto-schedules',
      query: {if (agentId != null) 'agent_id': agentId, 'limit': limit},
    );
    return unwrapItems(res, ChatTurnSchedule.fromJson);
  }

  /// `POST /chat/groups/:group_id/auto-schedule/stop` —— 撤销该 group 下所有
  /// 未触发的 goal_gate 续跑排程。
  ///
  /// ⚠️ 路径**不带** `/api` 前缀，且是**单数** `auto-schedule/stop`
  /// （与 [listAutoSchedules] 的复数 `auto-schedules` 不同）。
  ///
  /// 返回被撤销的条数（服务端 `{group_id, disabled_count}`）。服务端谓词是
  /// `enabled=1 AND run_count < max_runs AND dedupe_key LIKE 'goal_gate:%'`
  /// 且按 `policy_json.meta.group_id` 过滤，故**不会**误伤 retry / fastpath，
  /// 也**不会**碰别的 group。
  ///
  /// 调用方写完应**回读列表**（而非回读 group）——停用改变的是排程集合。
  Future<int> stopAutoSchedule(String groupId) async {
    final res = await _post('/chat/groups/$groupId/auto-schedule/stop');
    final map = _asMap(res);
    final raw = map['disabled_count'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  // ==================== 确认卡 ====================

  /// `GET /chat/confirmations` —— 跨 group 的待确认列表。
  Future<List<Map<String, dynamic>>> listConfirmations({
    String? status,
    int limit = 50,
  }) async {
    final res = await _get(
      '/chat/confirmations',
      query: {if (status != null) 'status': status, 'limit': limit},
    );
    return unwrapItems(res, (m) => m);
  }

  /// [listConfirmations] 的强类型版本（推荐调用方使用）。
  //
  // 不修改 [listConfirmations] 的签名（避免破坏既有测试），而是在外层做一层
  // `ChatConfirmation.fromJson` 转换。字段名漂移会在解析时得到 null 而非
  // 静默拿到错误值，调用方也能拿到编译期字段访问。
  Future<List<ChatConfirmation>> listConfirmationsTyped({
    String? status,
    int limit = 50,
  }) async {
    final raw = await listConfirmations(status: status, limit: limit);
    return raw.map(ChatConfirmation.fromJson).toList(growable: false);
  }

  /// `GET /api/chat/groups/:group_id/confirmations` —— **按 group 过滤**的确认卡列表。
  ///
  /// ⚠️ **路径必须带 `/api` 前缀**（与 [resolveConfirmation] 同一族）。
  /// 该端点在 Go 侧挂在 `registerExtRoutes(apiv1, ...)` 里（`ext_routes.go:40`），
  /// 而 `apiv1 := r.Group("/api")`（`router.go:168`）——故完整路径是
  /// `/api/chat/groups/:group_id/confirmations`。
  ///
  /// 此前拼的是 `/chat/groups/:group_id/confirmations`（缺 `/api`）——该路径在
  /// 路由表里**不存在**（`/chat` 组下只有 `/chat/confirmations` 这个扁平列表，
  /// 见 [listConfirmations]），故调用必然 404。本方法此前无生产调用者，
  /// 缺陷因此长期潜伏（与 §6.14 的 `createTurn` 同一模式）。
  ///
  /// 注意 webapp 的 `listGroupConfirmations` 也拼这个路径且**同样缺 `/api`**
  /// （`group-chat.ts:1569`）——那是上游的既有缺陷，不在本仓库修复范围；
  /// 客户端按**服务端真实路由表**拼，不照抄 webapp 的 bug。
  Future<List<Map<String, dynamic>>> groupConfirmations(String groupId) async {
    final res = await _get('/api/chat/groups/$groupId/confirmations');
    return unwrapItems(res, (m) => m);
  }

  /// `POST /api/chat/groups/:group_id/confirmations/:confirmation_id/resolve`
  ///
  /// ## 路径必须带 group_id（issue #1：写错会静默 404）
  ///
  /// 真实路由表（在 `super_partyb/apps/go-api` 内枚举 `r.Routes()` 得到）：
  ///
  /// ```
  /// ROUTE  GET    /chat/confirmations
  /// ROUTE  GET    /api/chat/groups/:group_id/confirmations
  /// ROUTE  POST   /api/chat/groups/:group_id/confirmations/:confirmation_id/resolve
  /// ROUTE  POST   /api/chat/groups/:group_id/confirmations/:confirmation_id/confirm
  /// ROUTE  POST   /api/chat/groups/:group_id/confirmations/:confirmation_id/reject
  /// ```
  ///
  /// **`/chat/confirmations` 下只有 GET 列表**；三个写端点全在
  /// `/api/chat/groups/:gid/confirmations/` 下。挂载点：
  /// `ext_routes.go:39` 的 `registerConfirmRoutes(api.Group("/chat/groups/:group_id/confirmations"), db)`，
  /// 而 `api` 是 `router.go` 里的 `apiv1 := r.Group("/api")`。
  ///
  /// 历史教训：曾一度改成不带 group_id 的全局路径（依据是 webapp 的调用路径），
  /// 但**webapp 那条路径同样 404**。判断「哪个路径对」
  /// 不能靠读前端调用方（它可能与后端漂移），必须枚举真实路由表。
  ///
  /// ## 请求体键是 `action` 而非 `decision`
  ///
  /// 服务端 `misc.go:resolve` 绑定的结构体是 `{Action, Comment}`，用 `decision` 会
  /// 被 JSON 绑定忽略（不报错）→ `action` 取默认值 `"resolved"`。
  /// 因为 `resolved_action` 当前无下游消费者，这个错误**不会报错也不会崩溃**，
  /// 只是把用户选的动作静默丢掉。
  ///
  /// [confirmationId] 必须是**卡行 id**（`chat_confirmations.id`），不是事件 id
  /// ——见 `ConfirmationItem.confirmationId` 的说明。
  Future<void> resolveConfirmation(
    String groupId,
    String confirmationId, {
    required String action,
    String? comment,
  }) => _post(
    '/api/chat/groups/$groupId/confirmations/$confirmationId/resolve',
    body: {'action': action, if (comment != null) 'comment': comment},
  );

  // ==================== 归属反馈 ====================

  /// `POST /chat/feedback/:token/resolve`
  ///
  /// 用户在「这条消息归属对吗」卡片上点按钮时调用（可视化渠道直接解决，
  /// 不经消息通道）。与 IM 文本回执共用同一套消费逻辑。
  ///
  /// ## ⚠️ 请求体键是 `reply`（字符串），不是 `correct`（布尔）
  ///
  /// 服务端 `feedback_resolve.go` 的入参结构只有 `reply` / `index` / `group_id`：
  ///
  /// ```go
  /// type resolveFeedbackRequest struct {
  ///     Reply   string `json:"reply"`
  ///     Index   int    `json:"index"`
  ///     GroupID string `json:"group_id"`
  /// }
  /// ```
  ///
  /// 它把 `reply` 交给 `confirmtext.IsAffirmVerdict` / `IsDenyVerdict` 判定，
  /// 再合成回执文本 `反馈#<token>#正确` 交给统一的 `ParseFeedback`。
  ///
  /// **发 `{'correct': bool}` 会静默失败**：`ShouldBindJSON` 忽略未知字段，
  /// `Reply` 留空 → `composeFeedbackReply` 返回 `""` → `400 reply is required`。
  /// 这是 2026-10 的真实缺陷（与 §6.14 的 `createTurn` 发 `input` 而非
  /// `inputText` 同一类）：卡片点了没反应，而客户端把 400 吞成了 `debugPrint`。
  ///
  /// 文案用「准确 / 不准确」而不是「正确 / 错误」——两者都在服务端词表里，
  /// 但前者正是卡片上按钮的 label（`FeedbackRequestCard.defaultOptions`），
  /// 保持一致可减少「我点的是准确、发出去的是正确」这类疑问。
  Future<void> resolveFeedback(String token, {required bool correct}) => _post(
    '/chat/feedback/$token/resolve',
    body: {'reply': correct ? '准确' : '不准确'},
  );

  // ==================== 内部 HTTP 辅助 ====================
  //
  // ## 为什么每个辅助都要显式判 4xx
  //
  // `createDio` 的 `validateStatus: (s) => s < 500` 意味着 **4xx 不会抛
  // `DioException`**（只有 5xx 才会走错误拦截器）。若在此处不判状态码，
  // `404 {"error":"..."}` 会被当成成功响应返回，调用方的 `fromJson` 再把
  // 错误体解析成一个**字段全空的对象**——不报错、不抛异常，UI 表现为
  // 「数据莫名是空的」。这与 `http_client.dart` 里「统一转成 SpbError，使调用方
  // 只需 catch 一种类型」的设计意图相违，故在此补齐 4xx 分支。

  /// 把非 2xx 响应转成 [HttpError]；2xx 返回响应体。
  Object? _unwrap(Response<dynamic> res) {
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw HttpError(status, 'HTTP $status', body: _bodyPreview(res.data));
    }
    return res.data;
  }

  /// 响应体预览（截断，避免把整页 HTML 塞进错误对象与日志）。
  static String? _bodyPreview(Object? data) {
    if (data == null) return null;
    final s = data is String ? data : data.toString();
    return s.length > 500 ? '${s.substring(0, 500)}…' : s;
  }

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _post(
    String path, {
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await _dio.post<dynamic>(
        path,
        data: body,
        queryParameters: query,
      );
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _patch(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.patch<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// `PUT` 请求。
  ///
  /// ## 为什么必须有这个 helper
  ///
  /// 群级开关（goal-gate / follow-up-suggest / tts）在服务端注册的是 **PUT**
  /// 专用端点（`chat_ext.go:83-89`），不是 PATCH。缺了 `_put` 就只能改用
  /// `PATCH /chat/groups/:id` 的 metadata 通道，而那是**整包替换**语义：只提交
  /// `{goal_gate}` 会连带清掉 `metadata.tts` 等其它子系统写入的键（webapp 历史
  /// bug）。PUT 端点服务端做 CAS 读-改-写，既保其它键，也不与并发写者互相覆盖。
  ///
  /// ## 为什么要走 [_unwrap]
  ///
  /// 同 [_patch]：`validateStatus` 放行了 <500 的状态码，4xx 不会抛
  /// `DioException`。不补判会把 `400 goal_required` 当成成功。
  Future<Object?> _put(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.put<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<void> _delete(String path) async {
    try {
      final res = await _dio.delete<dynamic>(path);
      // 返回值用不上，但状态码必须检查：4xx 不会抛 DioException（见上文说明），
      // 不检查会让「删除失败」静默成功。
      _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// 把 dio 异常里的 [SpbError] 取出，保留原始错误类型。
  SpbError _toSpbError(DioException e) {
    final inner = e.error;
    if (inner is SpbError) return inner;
    return mapDioError(e);
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return const {};
  }
}

/// `POST /users/:user_id/chat/routing-preview` 的响应。
///
/// ## ⚠️ 这不是「归属预览」（名字有迷惑性）
///
/// 端点叫 routing-preview，但**响应里没有 group_id**。它预览的是
/// **「这句话会用哪个 agent」**，且当前服务端只走兜底路径（embedding 级联已下线）。
/// 详见 [ChatApi.routingPreview] 的说明。
///
/// UI 展示时必须如实说明这一点：不能写成「将发送到某对话」——服务端没给那个
/// 信息，写成那样是编造。
class RoutingPreview {
  const RoutingPreview({
    required this.resolvedAgentId,
    required this.routeSource,
    this.focusTopic,
    this.candidates = const [],
    this.trace = const {},
    this.raw = const {},
  });

  /// 服务端解析出的 agent id。可能为空串（没有 active agent 时）。
  final String resolvedAgentId;

  /// 路由来源。当前**恒为** `"fallback"`（链 A 已下线）。
  final String? routeSource;

  /// 聚焦话题。级联下线后**恒为 null**（保留字段以便将来恢复）。
  final String? focusTopic;

  /// 候选 agent（当前是「前 5 个 active agent」，与输入语义无关）。
  final List<RoutingCandidate> candidates;

  /// 服务端 trace（上线回归比对的观测点）。
  final Map<String, dynamic> trace;

  /// 原始响应，保留未建模字段。
  final Map<String, dynamic> raw;

  /// 是否走了兜底路径（当前总是）。
  bool get isFallback => routeSource == 'fallback';

  /// 解析出的候选里能否找到 [resolvedAgentId] 对应的名字。
  ///
  /// 找不到时返回 null（服务端可能只给了 id，或候选被截断到 5 条之外）。
  String? get resolvedAgentName {
    for (final c in candidates) {
      if (c.agentId == resolvedAgentId) return c.name;
    }
    return null;
  }

  factory RoutingPreview.fromJson(Map<String, dynamic> json) => RoutingPreview(
    resolvedAgentId: (json['resolved_agent_id'] ?? '').toString(),
    routeSource: _nonEmptyStr(json['route_source']),
    focusTopic: _nonEmptyStr(json['focus_topic']),
    candidates: (json['candidates'] is List)
        ? (json['candidates'] as List<dynamic>)
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (m) => RoutingCandidate.fromJson(Map<String, dynamic>.from(m)),
              )
              .toList(growable: false)
        : const <RoutingCandidate>[],
    trace: json['trace'] is Map
        ? Map<String, dynamic>.from(json['trace'] as Map<dynamic, dynamic>)
        : const <String, dynamic>{},
    raw: json,
  );

  @override
  String toString() =>
      'RoutingPreview(agent: $resolvedAgentId, source: $routeSource, '
      'candidates: ${candidates.length})';
}

/// 路由预览里的一个候选 agent。
class RoutingCandidate {
  const RoutingCandidate({
    required this.agentId,
    required this.name,
    this.description,
    this.groupName,
  });

  final String agentId;
  final String name;

  /// 可能为 null（服务端 `nullStr`）。
  final String? description;

  /// agent 所属分组名。服务端未取到时为 null。
  final String? groupName;

  factory RoutingCandidate.fromJson(Map<String, dynamic> json) =>
      RoutingCandidate(
        agentId: (json['agent_id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: _nonEmptyStr(json['description']),
        groupName: _nonEmptyStr(json['group_name']),
      );
}

/// `POST /users/:user_id/chat/messages/flush` 的响应。
///
/// ## 两种结果（服务端都用 **HTTP 200** 返回）
///
/// | status | 含义 | 客户端应做 |
/// |---|---|---|
/// | `confirmation_required` | 有多条 pending 且未指定策略，**什么都没提交** | 让用户选策略后重试 |
/// | 其它/空（提交成功） | 已合并成 turn | 刷新待处理栏 |
///
/// 故「HTTP 200」**不等于**「提交成功」——必须看 [status]。
class FlushResult {
  const FlushResult({
    required this.status,
    this.turnId,
    this.flushStrategy,
    this.consumedMessageIds = const [],
    this.reason,
    this.options = const [],
    this.preview = const {},
    this.raw = const {},
  });

  /// 服务端状态。空串 = 成功且服务端未给 status（成功分支只返回 turn_id 等）。
  final String status;

  /// 新建的 turn id（成功时有值）。
  final String? turnId;

  /// 实际使用的策略：`latest_only` / `merge_all` / `new_group`。
  final String? flushStrategy;

  /// 被合并进该 turn 的收件箱消息 id。
  final List<String> consumedMessageIds;

  /// 待确认时的原因（如 `multiple_pending_messages`）。
  final String? reason;

  /// 待确认时可选的策略列表。
  final List<String> options;

  /// 待确认时的预览（`latest_input` / `merged_input` / `group_id`）。
  final Map<String, dynamic> preview;

  final Map<String, dynamic> raw;

  /// 是否处于「需要用户选冲突策略」状态（未提交）。
  bool get needsConfirmation => status == 'confirmation_required';

  /// 是否已成功提交（合并出 turn）。
  ///
  /// 判据是 [turnId] 非空：待确认分支没有 turn_id，而成功分支一定有。
  bool get committed => !needsConfirmation && (turnId ?? '').isNotEmpty;

  factory FlushResult.fromJson(Map<String, dynamic> json) => FlushResult(
    status: (json['status'] ?? '').toString(),
    turnId: _nonEmptyStr(json['turn_id']),
    flushStrategy: _nonEmptyStr(json['flush_strategy']),
    consumedMessageIds: (json['consumed_message_ids'] is List)
        ? (json['consumed_message_ids'] as List)
              .map((e) => e.toString())
              .toList(growable: false)
        : const [],
    reason: _nonEmptyStr(json['reason']),
    options: (json['options'] is List)
        ? (json['options'] as List)
              .map((e) => e.toString())
              .toList(growable: false)
        : const [],
    preview: json['preview'] is Map
        ? Map<String, dynamic>.from(json['preview'] as Map)
        : const {},
    raw: json,
  );

  @override
  String toString() => needsConfirmation
      ? 'FlushResult(待确认冲突, options: $options)'
      : 'FlushResult(turn: $turnId, strategy: $flushStrategy) ';
}

/// 把 JSON 值转成「非空字符串或 null」。
///
/// 服务端用 `omitempty` 与 `nullStr` 两种方式表达「没有」，故空串与 null 都要
/// 归一成 null——否则调用方得同时判两种，很容易漏一种。
String? _nonEmptyStr(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

/// `POST /chat/groups/:group_id/turns` 的响应（Go 侧 `CreateTurnResponse`）。
///
/// ## 为什么不用 `ChatTurn`
///
/// 该端点返回的是 `{status, groupId, turnId}`（camelCase，**平铺**），
/// 而 `ChatTurn` 需要 `id`/`group_id`/`user_id`/`input_text`/`created_at` 等
/// snake_case 字段。用 `ChatTurn.fromJson` 解析它只会得到一堆空串（不报错），
/// 调用方拿到的是个「看似存在实则全空」的对象——比直接 400 更难排查。
///
/// 需要完整 turn 时再调 [ChatApi.getTurn]。
class CreateTurnResult {
  const CreateTurnResult({
    required this.turnId,
    required this.groupId,
    required this.status,
  });

  final String turnId;
  final String groupId;

  /// 固定为 `queued`（服务端 `c.JSON(201, ...{Status: "queued"})`）。
  final String status;

  factory CreateTurnResult.fromJson(Map<String, dynamic> json) =>
      CreateTurnResult(
        // 兼容 snake_case：服务端用 camelCase，但历史/网关改写可能出现下划线。
        turnId: (json['turnId'] ?? json['turn_id'] ?? '').toString(),
        groupId: (json['groupId'] ?? json['group_id'] ?? '').toString(),
        status: (json['status'] ?? 'queued').toString(),
      );
}

/// `POST /users/:user_id/chat/messages` 的响应（Go 侧 `SendMessageResponse`）。
///
/// 服务端可能返回**新建 turn** 或**命中已有 turn**（同 request_id 幂等命中），
/// 后者通过 [deduped] 标识。
class SendMessageResult {
  const SendMessageResult({
    required this.turnId,
    required this.groupId,
    required this.status,
    this.requestId,
    this.deduped = false,
    this.raw = const {},
  });

  final String turnId;

  /// 最终判定的归属 group。**无归属入口提交时这里是服务端的分类结果**，
  /// 桌面端悬浮窗据此导航到对应对话。
  final String groupId;

  final String status;
  final String? requestId;

  /// 是否命中了已有 turn（幂等去重）。
  final bool deduped;

  final Map<String, dynamic> raw;

  factory SendMessageResult.fromJson(Map<String, dynamic> json) {
    // 服务端可能把 turn 放在 `turn` 子对象里，也可能平铺在顶层。
    final turn = json['turn'] is Map
        ? Map<String, dynamic>.from(json['turn'] as Map)
        : json;
    return SendMessageResult(
      turnId: (turn['id'] ?? turn['turn_id'] ?? json['turn_id'] ?? '')
          .toString(),
      groupId: (turn['group_id'] ?? json['group_id'] ?? '').toString(),
      status: (turn['status'] ?? json['status'] ?? 'queued').toString(),
      requestId: (json['request_id'] ?? turn['request_id']) as String?,
      deduped: json['deduped'] == true || json['deduplicated'] == true,
      raw: json,
    );
  }
}

/// `POST /me/quick-capture` 的响应（Go 侧 `quickCaptureResponse`）。
///
/// ## 两种终态语义（`status`）
///
/// | status | 含义 | 桌面壳应做 |
/// |---|---|---|
/// | `queued` | 已建 turn 入队 | 导航到 [groupId] 并等回答 |
/// | `feedback_recorded` | 命中归属反馈元指令，**不建 turn** | 不导航、不等回答 |
///
/// 服务端用 String 而非 bool 表达状态，以便新增状态时不必改响应形状；
/// 故这里也用 String + 语义化 getter，而非 enum。
///
/// 注意 [feedbackRecorded] 时 [turnId] 为空串（服务端不填该字段）。
class QuickCaptureResult {
  const QuickCaptureResult({
    required this.turnId,
    required this.groupId,
    required this.status,
    this.createdGroup = false,
    this.matchedTitle,
    this.routeSource,
    this.raw = const {},
  });

  /// 新建的 turn ID。`feedback_recorded` 时为空串。
  final String turnId;

  /// 服务端判定的归属 group。
  ///
  /// **这是本端点的核心产出**：调用方没给 group_id，归属由分类链判定。
  final String groupId;

  /// `queued` / `feedback_recorded`。见类文档的语义表。
  final String status;

  /// 是否为本轮**新建**了 group（而非落到既有对话）。
  final bool createdGroup;

  /// 匹配到的 group 标题（服务端 `omitempty`，可能缺失）。
  final String? matchedTitle;

  /// 归属判定来源（如 `fastpath` / `llm`），供诊断与埋点。
  final String? routeSource;

  /// 原始响应，保留未建模字段以备调试。
  final Map<String, dynamic> raw;

  /// 是否为终态：不建 turn，调用方**不应导航、不应等待回答**。
  ///
  /// 判定依据是 `status == 'feedback_recorded'`。刻意用显式比较而非
  /// `status != 'queued'`：服务端未来新增状态时，未知状态不应被误当成终态
  /// （那会让一条真正入队的消息被静默丢弃）。
  bool get isFeedbackRecorded => status == 'feedback_recorded';

  /// 是否成功入队（有 turn 可等）。
  bool get isQueued => status == 'queued';

  /// 是否应当导航到 [groupId]。
  ///
  /// 与 [isQueued] 同义，但命名从「UI 该做什么」的角度表达，避免调用方
  /// 直接比较字符串。
  bool get shouldNavigate => isQueued && groupId.isNotEmpty;

  factory QuickCaptureResult.fromJson(Map<String, dynamic> json) =>
      QuickCaptureResult(
        turnId: (json['turn_id'] ?? json['turnId'] ?? '').toString(),
        groupId: (json['group_id'] ?? json['groupId'] ?? '').toString(),
        status: (json['status'] ?? '').toString(),
        createdGroup: json['created_group'] == true,
        matchedTitle: json['matched_title'] as String?,
        routeSource: json['route_source'] as String?,
        raw: json,
      );

  @override
  String toString() =>
      'QuickCaptureResult(status=$status, group=$groupId, turn=$turnId'
      '${createdGroup ? ', createdGroup' : ''})';
}

/// 当前登录用户（`GET /api/auth/me`，Go 侧 `authHandlers.me`）。
///
/// ## 用途：提供 `userId`
///
/// [ChatApi] 的 `/users/:user_id/chat/*` 系列都需要 userId，而客户端不解析 JWT、
/// 不申请 API Key（身份由网关 OIDC 注入）。本模型是拿到 userId 的唯一途径。
///
/// 服务端返回 snake_case 的 `id`/`email`/`name`/`role`/`roles`/`permissions`/`status`。
/// 其中 `roles` 是数组（`useIsAdmin()` 依赖 `roles.includes('admin')`），
/// 而 `role` 是单个字符串——两者并存是既有事实，不要试图合并。
class CurrentUser {
  const CurrentUser({
    required this.id,
    required this.email,
    required this.name,
    this.role,
    this.roles = const [],
    this.permissions = const [],
    this.status,
    this.raw = const {},
  });

  final String id;
  final String email;
  final String name;

  /// 单个角色字符串（服务端 `users.role` 列）。
  final String? role;

  /// 角色数组。服务端保证非 null（空角色时返回 `[]`），UI 用它判管理员。
  final List<String> roles;

  /// 权限列表。当前服务端恒返回 `[]`（预留）。
  final List<String> permissions;

  final String? status;

  final Map<String, dynamic> raw;

  /// 是否为管理员。对齐 webapp 的 `useIsAdmin()`。
  bool get isAdmin => roles.contains('admin') || role == 'admin';

  bool get hasId => id.isNotEmpty;

  /// 是否自设了昵称（`users.name` 非空）。
  ///
  /// ## `name` 已经是**回退后的结果**，不需要客户端再拼回退链
  ///
  /// 服务端 `GET /api/auth/me` 已按 `user.display_name` 偏好 → `users.name` →
  /// `email` 解析好昵称（见 Go `auth_me_test.go` 的
  /// `TestAuthMeFallsBackToUserName` / `TestAuthMePrefersDisplayPrefs`），
  /// 故客户端**不要**自己再拿 `preferences.displayName` 拼一遍回退链——那会与
  /// 服务端结果不一致（例如偏好被另一台设备清空时）。
  ///
  /// 本 getter 只用于判断「是否已有一个可展示的名称」。
  bool get hasName => name.isNotEmpty;

  /// 展示用名称（昵称 → 邮箱）；两者都空时返回空串，由调用方给占位文案。
  String get displayNameFallback => name.isNotEmpty ? name : email;

  /// 头像地址（服务端 `/api/auth/me` 的 `avatar_url`）。
  ///
  /// 服务端已把 `user.avatar_url` 偏好合并进来；**空串 = 未设置**，渲染侧应回落
  /// 内置图标（服务端下发前不做 URL 校验，故渲染前需自行 sanitize）。
  ///
  /// 从 [raw] 取：本类未把它提成构造参数（后加字段，硬加会破坏既有调用方），
  /// 而 `raw` 保留了完整响应。
  String get avatarUrl => (raw['avatar_url'] ?? '').toString();

  factory CurrentUser.fromJson(Map<String, dynamic> json) => CurrentUser(
    id: (json['id'] ?? '').toString(),
    email: (json['email'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    role: json['role'] as String?,
    roles: _stringList(json['roles']),
    permissions: _stringList(json['permissions']),
    status: json['status'] as String?,
    raw: json,
  );

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  @override
  String toString() => 'CurrentUser($id, roles=$roles)';
}

/// `POST /me/quick-capture/attachments` 的响应。
///
/// 只保留客户端真正要用的字段：`file_id` 要回填进
/// [ChatApi.enqueueQuickCapture] 的 `attachments`，其余供 UI 展示进度/预览。
class QuickCaptureUpload {
  const QuickCaptureUpload({
    required this.fileId,
    this.fileName,
    this.size = 0,
    this.mimeType,
  });

  /// 服务端在 UFS 侧生成的文件 ID。
  ///
  /// ## 为什么是 file_id 而不是文件名
  ///
  /// 附件字节现在直传 UFS（不再先落 mq-server），服务端用 UFS 返回的 ID
  /// 作为句柄。客户端必须原样回传——它不是「文件名」，不能自行拼装或改名。
  ///
  /// 消费侧会带着服务级凭证用它去 UFS 取字节；若允许客户端指定 URL，
  /// 就成了一个 SSRF 面（可指向任意内网地址）。
  final String fileId;

  /// 服务端回显的文件名（仅用于 UI 展示，**不**用于投递）。
  ///
  /// 可为空：该值只作展示，缺失不影响链路。
  final String? fileName;

  /// 字节数。
  final int size;

  /// 服务端回显的 MIME 类型（可能为空）。
  final String? mimeType;

  factory QuickCaptureUpload.fromJson(Map<String, dynamic> json) =>
      QuickCaptureUpload(
        fileId: (json['file_id'] ?? '').toString(),
        fileName: json['file_name'] as String?,
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mime_type'] as String?,
      );

  /// 上传是否拿到了可用的 file_id。
  ///
  /// 为 false 时不应把它放进 enqueue 的 attachments——服务端会 400
  /// （附件 file_id 不能为空/不合法）。
  bool get isValid => fileId.isNotEmpty;

  @override
  String toString() => 'QuickCaptureUpload($fileId, $size bytes)';
}

/// `POST /chat/groups/:group_id/workspace-sync/ufs-upload` 的响应。
///
/// ## 服务端形状（`workspace_sync.go` 的 `ufsUpload` 尾部）
///
/// ```json
/// {
///   "group_id": "...",
///   "relative_path": "reports/x.md",
///   "file": {"id": "...", "name": "...", "path": "...", "size": 12,
///            "mime_type": "...", "is_directory": false, "updated_at": "..."},
///   "absolute_path": "/opt/<app>/.../workspace/groups/.../reports/x.md",
///   "size_bytes": 12,
///   "sync_status": "local_synced",
///   "needs_local_sync": false
/// }
/// ```
///
/// ## ⚠️ 没有 `etag`（这是本模型刻意不提供 etag 的原因）
///
/// `fileEntryToMap` 不回 etag（`workspace_sync.go:711`）。调用方**不能**用本响应
/// 去 `markSynced`——那样会把一个空的 etag 写进状态，下轮预检时本地记录 etag
/// 为 null，于是每次都被判成 `conflict`。收口只能靠下一轮同步重新下载。
class WorkspaceFileUpload {
  const WorkspaceFileUpload({
    required this.groupId,
    required this.relativePath,
    this.fileId,
    this.fileName,
    this.filePath,
    this.fileSize = 0,
    this.fileMimeType,
    this.absolutePath,
    this.sizeBytes = 0,
    this.syncStatus,
    this.raw = const {},
  });

  /// 服务端回显的 group（应等于请求里的 groupId）。
  final String groupId;

  /// 服务端**归一化后**的组内相对路径。
  ///
  /// 值得与请求值对比：服务端会走 `normalizeWorkspaceRelativePath`（去前导
  /// 斜杠、折叠 `./` 等），若请求值非法它会**回退到用文件名**（见
  /// `ufsUpload` 的 err 分支）——那时 [relativePath] 与请求值不同，文件其实
  /// 落到了别处。回传编排应据此发现「我传的路径没被采纳」。
  final String relativePath;

  /// UFS 侧文件 id。
  final String? fileId;

  final String? fileName;

  /// UFS materialized path（如 `workspace/groups/{gid}/reports/x.md`）。
  final String? filePath;

  /// UFS 侧文件大小（响应 `file.size`）。
  final int fileSize;

  final String? fileMimeType;

  /// 服务端本地 workspace 里的绝对路径（诊断用，客户端一般不用）。
  final String? absolutePath;

  /// 本次写入的字节数（响应 `size_bytes`）。
  final int sizeBytes;

  /// 服务端同步状态，正常为 `local_synced`。
  final String? syncStatus;

  /// 原始响应，保留未建模字段以备调试。
  final Map<String, dynamic> raw;

  /// 服务端是否确认已同步到本地 workspace。
  ///
  /// 只认 `local_synced`：若服务端将来新增中间状态（如 `pending`），
  /// 调用方不应把它当成完成——「已回传」的语义必须由服务端明确确认。
  bool get isLocalSynced => syncStatus == 'local_synced';

  factory WorkspaceFileUpload.fromJson(Map<String, dynamic> json) {
    final file = json['file'] is Map
        ? Map<String, dynamic>.from(json['file'] as Map)
        : const <String, dynamic>{};
    return WorkspaceFileUpload(
      groupId: (json['group_id'] ?? '').toString(),
      relativePath: (json['relative_path'] ?? '').toString(),
      fileId: file['id']?.toString(),
      fileName: file['name']?.toString(),
      filePath: file['path']?.toString(),
      fileSize: (file['size'] as num?)?.toInt() ?? 0,
      fileMimeType: file['mime_type']?.toString(),
      absolutePath: json['absolute_path']?.toString(),
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      syncStatus: json['sync_status']?.toString(),
      raw: json,
    );
  }

  @override
  String toString() =>
      'WorkspaceFileUpload($relativePath, $sizeBytes bytes, '
      'status=$syncStatus)';
}
