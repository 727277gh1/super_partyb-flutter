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
  Future<ChatTurn> createTurn(
    String groupId, {
    required String input,
    String? agentId,
    String? requestId,
  }) async {
    final res = await _post(
      '/chat/groups/$groupId/turns',
      body: {
        'input': input,
        if (agentId != null) 'agent_id': agentId,
        if (requestId != null) 'request_id': requestId,
      },
    );
    return ChatTurn.fromJson(_asMap(res));
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
  /// 把缓冲区中的消息立即提交（通常用于「输入完立刻发送」）。
  Future<void> flushMessages(String userId, {String? groupId}) => _post(
    '/users/$userId/chat/messages/flush',
    body: {if (groupId != null) 'group_id': groupId},
  );

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
  /// ## 为什么只传文件名/字节，不传 URL
  ///
  /// 服务端（PartyB）会带着自己的服务级 Bearer 去下载这个 URL。若由客户端指定
  /// URL，就出现了一个 SSRF 面（可指向任意内网地址）。故本方法只传字节，
  /// download_url 由服务端拼装。
  ///
  /// 返回 [QuickCaptureUpload]，其中 [QuickCaptureUpload.fileName] 要填进
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
      final res = await _dio.post('/me/quick-capture/attachments', data: form);
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
  /// 预览「这句话会落到哪个 group / agent」。注意：当前服务端**只返回兜底默认
  /// Agent 的解析结果**，不再调用 embedding 路由（链 A 已下线，见 super_partyb
  /// AGENTS.md「相似度算法与打分」）。
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

  /// `GET /chat/groups/:group_id/confirmations`
  Future<List<Map<String, dynamic>>> groupConfirmations(String groupId) async {
    final res = await _get('/chat/groups/$groupId/confirmations');
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
  Future<void> resolveFeedback(String token, {required bool correct}) =>
      _post('/chat/feedback/$token/resolve', body: {'correct': correct});

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
      final res = await _dio.get(path, queryParameters: query);
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
      final res = await _dio.post(path, data: body, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _patch(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.patch(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<void> _delete(String path) async {
    try {
      final res = await _dio.delete(path);
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

/// `POST /users/:user_id/chat/messages` 的响应。
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
/// 只保留客户端真正要用的字段：`file_name` 要回填进
/// [ChatApi.enqueueQuickCapture] 的 `attachments`，其余供 UI 展示进度/预览。
class QuickCaptureUpload {
  const QuickCaptureUpload({
    required this.fileName,
    required this.downloadUrl,
    this.size = 0,
    this.mimeType,
  });

  /// 服务端生成的安全文件名（**不是**用户原始文件名）。
  ///
  /// 命名规则为 `<纳秒时间戳>_<8位随机hex>_<安全化原名>`，服务端据此校验
  /// 归属（见 mq-server 的 looksLikeUploadName）。故客户端必须原样回传，
  /// 不能自行拼装或改名。
  final String fileName;

  /// 服务端拼装的相对地址（`/api/v1/inbound/uploads/<file_name>`）。
  ///
  /// 客户端**不传**这个值给入队接口（只传 [fileName]）：若允许客户端指定
  /// URL，服务端就会带着自己的 Bearer 去下载任意地址（SSRF 面）。
  final String downloadUrl;

  /// 字节数。
  final int size;

  /// 服务端回显的 MIME 类型（可能为空）。
  final String? mimeType;

  factory QuickCaptureUpload.fromJson(Map<String, dynamic> json) =>
      QuickCaptureUpload(
        fileName: (json['file_name'] ?? '').toString(),
        downloadUrl: (json['download_url'] ?? '').toString(),
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mime_type'] as String?,
      );

  /// 上传是否拿到了可用的文件名。
  ///
  /// 为 false 时不应把它放进 enqueue 的 attachments——服务端会 400
  /// （附件名不能为空/不合法）。
  bool get isValid => fileName.isNotEmpty;

  @override
  String toString() => 'QuickCaptureUpload($fileName, $size bytes)';
}
