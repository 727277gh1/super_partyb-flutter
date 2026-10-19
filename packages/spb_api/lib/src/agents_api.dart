import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'auth_interceptor.dart';

/// Agent 目录与对话内 agent 会话绑定的 API 客户端。
///
/// 端点全部来自 Go API 真实路由：
/// - `agents.go` → `/api/agents`（列表 / 详情）
/// - `sessions.go` → `/chat/groups/:gid/sessions*`（列绑定 / 换 agent）
///
/// ## 为什么单独一个类而不塞进 [ChatApi]
///
/// `/api/agents` 不在 `/chat/*` 命名空间下（`ChatApi` 的类文档把自己限定在
/// `/chat/*` 与 `/users/:uid/chat/*`）。混在一起会让「agent 功能整体关闭」时
/// 无法从依赖注入层面摘掉它——与 [HabitApi] 同一理由。
///
/// ## 前缀易踩坑
///
/// `/api/agents` **带** `/api` 前缀，而会话绑定端点 `/chat/groups/:gid/...`
/// **不带**。两者是同一批调用里相邻的两个请求，照抄其中一个去改另一个就会 404。
class AgentsApi {
  AgentsApi(this._dio);

  final Dio _dio;

  /// `GET /api/agents?limit=&offset=`
  ///
  /// 服务端 `parseLimit(c.Query("limit"), 50, 200)`：默认 50、**上限 200**。
  /// 本方法默认 100（下拉够用且不必翻页），传超过 200 会被服务端夹取。
  ///
  /// ⚠️ 服务端**只返回 active**（`ListAgents` 走 `filterActive`），故不传
  /// `status` 也拿不到归档 agent。若要含归档，得用 `/api/agents?status=archived`
  /// ——但那不是本方法的目标场景（下拉只应列可选的）。
  Future<List<Agent>> listAgents({
    int limit = 100,
    int offset = 0,
    String? status,
  }) async {
    final res = await _get(
      '/api/agents',
      query: {
        'limit': limit,
        'offset': offset,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    return unwrapItems(res, Agent.fromJson);
  }

  /// `GET /api/agents/:agent_id`
  Future<Agent> getAgent(String agentId) async {
    final res = await _get('/api/agents/$agentId');
    return Agent.fromJson(_asMap(res));
  }

  /// `GET /chat/groups/:gid/sessions?status=`
  ///
  /// 返回该 group 的 session 绑定（`{items: [...]}`）。`status` 默认 `active`
  /// ——服务端 `c.DefaultQuery("status", "active")`；传空串会**原样查询空状态**，
  /// 得到一个空列表（不是「不限」），故这里对空串回落 `active`。
  Future<List<GroupSession>> listGroupSessions(
    String groupId, {
    String status = 'active',
  }) async {
    final res = await _get(
      '/chat/groups/$groupId/sessions',
      query: {'status': status.isEmpty ? 'active' : status},
    );
    return unwrapItems(res, GroupSession.fromJson);
  }

  /// `POST /chat/groups/:gid/sessions/switch` —— 把 group 切到另一个 agent。
  ///
  /// ## ⚠️ 请求体键名是 **camelCase**，且 `agentId` 不是 `agent_id`
  ///
  /// 服务端 `sessions.go` 的匿名结构体 tag 是：
  ///
  /// ```go
  /// AgentID         string `json:"agentId"`
  /// Role            string `json:"role"`
  /// ForceNewSession bool   `json:"force_new_session"`
  /// ```
  ///
  /// 只有 `agentId` 是 camelCase（其余字段名本来就无下划线），且**没有**
  /// `bindJSONCompat` 的双形态兜底（那是 `/api/*` 的 helper）。写成
  /// `agent_id` 会让 `AgentID` 保持空串 → 400 `agentId 不能为空`，而错误
  /// 文案不会提示「你的键名写错了」。
  ///
  /// ## 副作用：旧绑定被归档，历史上下文断开
  ///
  /// 服务端先 `ArchiveChatGroupSessionsByGroup`（归档该 group 全部旧绑定），
  /// 再写一条新 active binding。故**切换 agent 会断开与历史对话的上下文链路**
  /// ——UI 必须提示这一点，否则用户会以为「换个 agent 接着聊」而实际是新开
  /// 一段上下文。
  ///
  /// ## `session_id` 为 null 是正常的
  ///
  /// 服务端 lazy 激活：新 binding 的 `session_id` 留 NULL，由下一轮 turn 让
  /// executor 自产回填。不要据此判断失败。
  ///
  /// [role] 缺省时服务端取 `owner`（`firstNonEmpty(req.Role, "owner")`）。
  /// [forceNewSession] = 同 agent 开新会话（断开旧 session 上下文）。
  Future<GroupAgentSwitchResult> switchGroupAgent(
    String groupId, {
    required String agentId,
    String? role,
    bool forceNewSession = false,
  }) async {
    final res = await _post(
      '/chat/groups/$groupId/sessions/switch',
      body: {
        // ⚠️ camelCase：写错成 agent_id 会 400「agentId 不能为空」。
        'agentId': agentId,
        if (role != null && role.isNotEmpty) 'role': role,
        'force_new_session': forceNewSession,
      },
    );
    return GroupAgentSwitchResult.fromJson(_asMap(res));
  }

  // ==================== 传输 ====================

  Future<Object?> _get(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<dynamic>(path, queryParameters: query);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  Future<Object?> _post(String path, {Map<String, dynamic>? body}) async {
    try {
      final res = await _dio.post<dynamic>(path, data: body);
      return _unwrap(res);
    } on DioException catch (e) {
      throw _toSpbError(e);
    }
  }

  /// 取响应体并**显式检查状态码**。
  ///
  /// `createDio` 的 `validateStatus` 放行 4xx（见 `http_client.dart`），故
  /// 400/404 不会抛 `DioException`。不补判会把 `400 agentId 不能为空` 当成
  /// 切换成功。
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
