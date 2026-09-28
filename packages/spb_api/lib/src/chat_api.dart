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

  /// `GET /users/:user_id/chat/search?q=`
  Future<List<ChatEvent>> search(String userId, {required String query}) async {
    final res = await _get('/users/$userId/chat/search', query: {'q': query});
    return unwrapItems(res, ChatEvent.fromJson);
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

  /// `POST /chat/groups/:group_id/confirmations/:id/resolve`
  Future<void> resolveConfirmation(
    String groupId,
    String confirmationId, {
    required String decision,
    Map<String, dynamic>? payload,
  }) => _post(
    '/chat/groups/$groupId/confirmations/$confirmationId/resolve',
    body: {'decision': decision, if (payload != null) ...payload},
  );

  // ==================== 归属反馈 ====================

  /// `POST /chat/feedback/:token/resolve`
  ///
  /// 用户在「这条消息归属对吗」卡片上点按钮时调用（可视化渠道直接解决，
  /// 不经消息通道）。与 IM 文本回执共用同一套消费逻辑。
  Future<void> resolveFeedback(String token, {required bool correct}) =>
      _post('/chat/feedback/$token/resolve', body: {'correct': correct});

  // ==================== 内部 HTTP 辅助 ====================

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
      await _dio.delete(path);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Object? _unwrap(Response<dynamic> res) => res.data;

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
