/// Agent（`GET /api/agents`）与会话绑定（`GET /chat/groups/:gid/sessions`）。
///
/// ## 字段名照抄服务端（snake_case）
///
/// `agents.go` 的 `agentDTO` 显式注释「字段名用 snake_case（前端 Agent 类型
/// 期望）」，与本仓库 `ChatGroup` / `ChatTurnSummary` 同一约定。
///
/// ## `provider_config` / `env` 为什么收成不透明 Map
///
/// 服务端把它们作为 `json.RawMessage` 原样透传（结构随 `provider_type` 变：
/// openai 是 `{base_url, api_key_ref}`、anthropic 是另一套），客户端**不解析**
/// 也不该展示敏感值。收成 `Map<String, dynamic>?` 只用于「有没有配置」的判断。
library;

/// 一个 agent（`agentDTO`）。
class Agent {
  const Agent({
    required this.id,
    required this.name,
    this.groupName = '',
    this.description = '',
    this.contentMd = '',
    this.tags = const [],
    this.userId = '',
    this.skills = const [],
    this.status = '',
    this.providerType = '',
    this.providerConfig,
    this.env,
    this.defaultModelId = '',
    this.modelTier = '',
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String name;

  /// 分组名（用于下拉里分节展示）。
  final String groupName;

  final String description;

  /// agent 的 prompt/说明正文（Markdown）。列表里不展示，详情用。
  final String contentMd;

  final List<String> tags;

  /// 归属用户 id。`omitempty`——系统内置 agent 可能为空（对所有用户可见）。
  final String userId;

  final List<String> skills;

  /// `active` / `archived`（服务端 `agents.status`）。
  final String status;

  /// `pigo` / `acb` / `llm` 等执行器类型。
  final String providerType;

  /// provider 配置（不透明；可能含凭据引用，**不要渲染**）。
  final Map<String, dynamic>? providerConfig;

  /// 环境变量（不透明；可能含凭据引用，**不要渲染**）。
  final Map<String, dynamic>? env;

  final String defaultModelId;

  /// 模型档位（`small` / `large` 等）。
  final String modelTier;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  final Map<String, dynamic> raw;

  /// 是否可被选用（服务端 `filterActive` 只放行 active）。
  bool get isActive => status.isEmpty || status == 'active';

  /// 下拉里展示的标签：名称缺失时回退 id。
  ///
  /// 显示空白会让用户不知道这是哪个 agent（与 `PreferenceAgentOption.label`
  /// 同一取向）。
  String get label => name.isEmpty ? id : name;

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    groupName: (json['group_name'] ?? '').toString(),
    description: (json['description'] ?? '').toString(),
    contentMd: (json['content_md'] ?? '').toString(),
    tags: _stringList(json['tags']),
    userId: (json['user_id'] ?? '').toString(),
    skills: _stringList(json['skills']),
    status: (json['status'] ?? '').toString(),
    providerType: (json['provider_type'] ?? '').toString(),
    providerConfig: _map(json['provider_config']),
    env: _map(json['env']),
    defaultModelId: (json['default_model_id'] ?? '').toString(),
    modelTier: (json['model_tier'] ?? '').toString(),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
    raw: json,
  );

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  static Map<String, dynamic>? _map(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  static DateTime? _date(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  @override
  String toString() => 'Agent($id, name=$name, status=$status)';
}

/// group 的一条 session 绑定（`sessionRowToDict`）。
///
/// ## 与 [ActiveSession] 的区别
///
/// `ChatGroup.activeSession` 是**当前生效的那一条**（服务端内联进 group 行）；
/// 本类来自 `GET /chat/groups/:gid/sessions`，是**全部绑定**（含历史归档）。
/// 两者的 `agent_id` / `session_id` 语义相同，但本类还带 `agent_name` /
/// `agent_provider` / `status`——下拉要显示 agent 名，不能只有一个 id。
class GroupSession {
  const GroupSession({
    required this.id,
    required this.groupId,
    required this.agentId,
    this.sessionId,
    this.agentSessionId,
    this.agentName = '',
    this.agentProvider = '',
    this.role = '',
    this.status = '',
    this.joinedAt,
    this.createdAt,
    this.updatedAt,
    this.raw = const {},
  });

  final String id;
  final String groupId;
  final String agentId;

  /// 上游会话 id。**null 是正常的**——服务端 lazy 激活，`session_id` 留 NULL，
  /// 由下一轮 turn 让 executor 自产（见 `sessions.go` 的 `switchAgent` 注释）。
  final String? sessionId;

  final String? agentSessionId;

  /// agent 展示名（服务端 join 出来的）。
  final String agentName;

  /// agent 的执行器类型（`pigo` / `acb` / `llm`）。
  final String agentProvider;

  final String role;
  final String status;

  final DateTime? joinedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  final Map<String, dynamic> raw;

  /// 下拉里展示的标签：agent 名缺失时回退 agent id。
  String get label => agentName.isEmpty ? agentId : agentName;

  factory GroupSession.fromJson(Map<String, dynamic> json) => GroupSession(
    id: (json['id'] ?? '').toString(),
    groupId: (json['group_id'] ?? '').toString(),
    agentId: (json['agent_id'] ?? '').toString(),
    sessionId: json['session_id'] as String?,
    agentSessionId: json['agent_session_id'] as String?,
    agentName: (json['agent_name'] ?? '').toString(),
    agentProvider: (json['agent_provider'] ?? '').toString(),
    role: (json['role'] ?? '').toString(),
    status: (json['status'] ?? '').toString(),
    joinedAt: _date(json['joined_at']),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
    raw: json,
  );

  static DateTime? _date(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toLocal();
  }

  @override
  String toString() => 'GroupSession($id, agent=$agentId, status=$status)';
}

/// `POST /chat/groups/:gid/sessions/switch` 的响应。
///
/// 注意 `session_id` 为 null 是**预期**的：服务端 lazy 激活，上游 session 由
/// 下一轮 turn 自产回填（`sessions.go` 的 `"session_id": nullStr(sess.SessionID)
/// // null：lazy，待 turn 执行回填`）。故 UI 不能把「session_id 为空」当成失败。
class GroupAgentSwitchResult {
  const GroupAgentSwitchResult({
    required this.groupId,
    required this.newAgentId,
    this.sessionId,
    this.status = '',
    this.forceNewSession = false,
    this.switched = false,
    this.raw = const {},
  });

  final String groupId;
  final String newAgentId;
  final String? sessionId;
  final String status;
  final bool forceNewSession;

  /// 服务端显式回报「已切换」。用它而不是「HTTP 200」判断成功——200 也可能是
  /// 被中间层改写的响应。
  final bool switched;

  final Map<String, dynamic> raw;

  factory GroupAgentSwitchResult.fromJson(Map<String, dynamic> json) =>
      GroupAgentSwitchResult(
        groupId: (json['group_id'] ?? '').toString(),
        newAgentId: (json['new_agent_id'] ?? '').toString(),
        sessionId: json['session_id'] as String?,
        status: (json['status'] ?? '').toString(),
        forceNewSession: json['force_new_session'] == true,
        switched: json['switched'] == true,
        raw: json,
      );

  @override
  String toString() =>
      'GroupAgentSwitchResult($groupId, agent=$newAgentId, switched=$switched)';
}
