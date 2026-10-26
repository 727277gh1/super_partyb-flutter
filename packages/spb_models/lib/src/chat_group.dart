import 'archive_snapshot.dart';

/// 对话分组（ChatGroup）。
///
/// 对应 Go 侧 `groupRowToDict`（`internal/server/chat.go`）的响应结构。
/// 注意：服务端返回 **snake_case** 键名（历史沿袭 Python 版），与 `ChatEvent`
/// 的 camelCase 不同——这是既有事实，客户端做映射，**不要试图统一**。
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.userId,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.goal,
    this.metadata,
    this.activeSession,
    this.currentGoal,
    this.archiveSnapshot,
  });

  final String id;
  final String userId;
  final String title;

  /// `active` / `archived`。
  final String status;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 分组的顶层目标描述（可能为空）。
  final String? goal;

  /// 自由元数据。关键键（均有对应只读 getter，见下）：
  /// - `follow_up_suggest.enabled`：后续提问建议开关（group 级）
  /// - `goal_gate.enabled` / `goal_gate.continue_until_done` / `goal_gate.max_auto_turns`
  /// - `tts.enabled` / `tts.narrate_thinking` / `tts.narration_mode` / `tts.file_summary`
  /// 值可能是嵌套 map，故用 `Object?` 而非 `String`。
  final Map<String, dynamic>? metadata;

  /// 当前活跃会话（agent 绑定）。
  final ActiveSession? activeSession;

  /// 当前 goal 快照（`GET /goals/current` 同结构）。
  final Map<String, dynamic>? currentGoal;

  /// 归档结项快照摘要（设计文档 §8.4）。
  ///
  /// ## 语义：null 与「没加载」是两件事
  ///
  /// 服务端对**无快照**的 group 显式写 `archive_snapshot: null`（不省略键），
  /// 所以 null 的意思是「这个 group 确实没有快照」。这与 `active_session`
  /// 相反——后者无值时省略键。
  ///
  /// 客户端只需一个 null 判定：非归档 group 永远没有快照，归档 group 在
  /// 快照生成前也没有。区分「没有」与「没加载」在本字段上没有实际用途。
  final ArchiveSnapshot? archiveSnapshot;

  /// 返回一个只替换 [metadata] 的副本。
  ///
  /// ## 为什么是整体替换（而不是深合并）
  ///
  /// `group_metadata_updated` 的 payload 带的是**完整** metadata
  /// （Go `updateGroupMetadata` 先读出整个 map、改完再返回它，不是子树）。
  /// 深合并反而会保留已被服务端删掉的键——服务端的删除语义就是「把键移除」
  /// （如关闭 tts 时整块删 `metadata.tts`，见 [ttsEnabled] 的注释），
  /// 合并会让「已关」的开关继续显示为开。
  ///
  /// 其余字段原样保留：该事件只描述 metadata，不携带 title/status/goal，
  /// 用一份残缺快照整体替换会让面板显示假的「全部关闭」。
  ChatGroup withMetadata(Map<String, dynamic>? next) => ChatGroup(
    id: id,
    userId: userId,
    title: title,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    goal: goal,
    metadata: next,
    activeSession: activeSession,
    currentGoal: currentGoal,
    archiveSnapshot: archiveSnapshot,
  );

  /// 返回一个只替换 [currentGoal] 的副本。
  ///
  /// ## 为什么需要它（而不是重新发一次 `GET /chat/groups/:id`）
  ///
  /// `goal_updated` 事件的 payload 携带与 `GET /goals/current` **逐字同构**的
  /// 快照（服务端 `goalToDTO`/`taskToDTO`/`progressFromTasks` 同一套函数，见
  /// Go `goal_api.go` 的文件头注释），故可以直接套进这里。重发 HTTP 只为拿
  /// 已经在手里的数据是白费一次往返，且会打断面板里的草稿编辑
  /// （见 `GroupSettingsPanel.didUpdateWidget` 的权威值对齐逻辑）。
  ///
  /// 其余字段原样保留：事件只描述 goal，**不**携带 group 的 title/status/
  /// metadata，用一份残缺快照整体替换会让面板显示假的「全部关闭」状态。
  ChatGroup withCurrentGoal(Map<String, dynamic>? next) => ChatGroup(
    id: id,
    userId: userId,
    title: title,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt,
    goal: goal,
    metadata: metadata,
    activeSession: activeSession,
    currentGoal: next,
    archiveSnapshot: archiveSnapshot,
  );

  bool get isArchived => status == 'archived';

  /// 后续提问建议是否对本 group 启用。
  ///
  /// 注意这是**双层开关**：group 级 metadata 之外还有全局 `FOLLOW_UP_SUGGEST_ENABLED`。
  /// 客户端只反映 group 级状态，全局关闭时即使此处为 true 也不会收到事件。
  bool get followUpSuggestEnabled =>
      _subMap(metadata?['follow_up_suggest'])?['enabled'] == true;

  /// 习惯建议是否对本 group 启用（`metadata.habit_suggest.enabled`）。
  ///
  /// 与 [followUpSuggestEnabled] 同构：键缺失 = 关闭（服务端关闭时
  /// `delete(meta, 'habit_suggest')` 而非写 false）。
  ///
  /// 同样是**双层开关**：group 级 metadata 之外还有全局 `HABIT_SUGGEST_ENABLED`
  /// （见 `chatexec.HabitSuggestReminderEnabled`）。客户端只反映 group 级状态。
  ///
  /// ⚠️ 与 goal gate **无依赖**：历史上习惯引导嵌在 goal 约定尾部，未开 goal gate
  /// 的群组永远拿不到；拆出后本开关独立生效。故面板不得因 goal gate 关闭而禁用它。
  bool get habitSuggestEnabled =>
      _subMap(metadata?['habit_suggest'])?['enabled'] == true;

  /// 当前目标文本（**结构化 goal 优先**，旧列兜底）。
  ///
  /// ## 为什么有这个优先级
  ///
  /// 迁移 0022 之后「goal 变更 = 新建 `chat_goals` 行」，`chat_groups.goal` 旧列
  /// 不再被写入。存量 group 可能只有旧列，故保留回退（与 webapp
  /// `WorkbenchGroupGoalControl` 及服务端 `goalGateEffectiveGoal` 同口径）。
  ///
  /// 快照形状见 `group_goal_snapshot.go` 的 `goalSnapshotDTO`：
  /// `{goal: {id, goal_text, status, ...}, tasks: [...], progress: {...}}`。
  String get currentGoalText {
    final snapshot = _subMap(currentGoal?['goal']);
    final text = (snapshot?['goal_text'] as String?)?.trim() ?? '';
    if (text.isNotEmpty) return text;
    return (goal ?? '').trim();
  }

  /// 「自动实现目标」（Goal Gate）是否对本 group 生效。
  ///
  /// ## 为什么是 `enabled && continue_until_done`（而不是只看 enabled）
  ///
  /// 服务端的接管判定是 `GoalGateConfig.CanTakeOver() = Enabled && ContinueUntilDone`
  /// （`chatgate/goal_gate_config.go`）。只看 `enabled` 会在「开了但没持续执行」
  /// 时谎报已接管。两个键由 `setGroupGoalGate` 端点成对写入，故实践中总是相等；
  /// 仍按服务端口径取「与」——否则手工改过 metadata 的存量 group 会显示错。
  ///
  /// 键缺失 = 关闭（与 [followUpSuggestEnabled] 及服务端的删除语义一致）。
  bool get goalGateEnabled {
    final gate = _subMap(metadata?['goal_gate']);
    return gate?['enabled'] == true && gate?['continue_until_done'] == true;
  }

  /// Goal Gate 的最大自动轮次。
  ///
  /// 键缺失时返回**服务端生效的默认值** 20（`chatgate/goal_gate_config.go` 的
  /// `clampAnyInt(gate["max_auto_turns"], 20, 1, 200)`），而不是 null——
  /// 面板要显示「当前生效值」，缺失时那个值就是 20。
  ///
  /// 非数字/越界的存量值同样按默认值处理（服务端读取时也会 clamp）。
  int get goalGateMaxAutoTurns {
    const fallback = 20;
    final raw = _subMap(metadata?['goal_gate'])?['max_auto_turns'];
    final n = raw is num ? raw.toInt() : null;
    if (n == null) return fallback;
    return n.clamp(1, 200);
  }

  /// `metadata.tts` 子对象（缺失或结构不对时为 null）。
  Map<String, dynamic>? get _tts => _subMap(metadata?['tts']);

  /// 语音回复总开关。
  ///
  /// 关闭时服务端**整块删除** `metadata.tts`（而非写 false），故键缺失 = 关闭。
  bool get ttsEnabled => _tts?['enabled'] == true;

  /// 思考阶段播报。
  ///
  /// ## 为什么在总开关关闭时恒为 false
  ///
  /// 存量 metadata 可能残留 `narrate_thinking`（历史上先开子开关、后关总开关）。
  /// 总开关关闭时该键**不生效**（服务端不会播报），如实返回 false 才不会让面板
  /// 在关闭的总开关下显示一个勾选的子开关。与 webapp `parseGroupTTS` 的归一化
  /// 口径一致（`enabled !== true` 时全部归零）。
  bool get ttsNarrateThinking =>
      ttsEnabled && _tts?['narrate_thinking'] == true;

  /// 播报模式：`filler`（固定短句）或 `summary`（中文摘要）。
  ///
  /// 未知值 / 键缺失 / 总开关关闭 → `filler`（服务端 `setTTS` 的归一化默认值）。
  String get ttsNarrationMode =>
      ttsEnabled && _tts?['narration_mode'] == 'summary' ? 'summary' : 'filler';

  /// 文件产出播报（同 [ttsNarrateThinking]，总开关关闭时恒为 false）。
  bool get ttsFileSummary => ttsEnabled && _tts?['file_summary'] == true;

  factory ChatGroup.fromJson(Map<String, dynamic> json) => ChatGroup(
    id: (json['id'] as String?) ?? '',
    userId: (json['user_id'] as String?) ?? '',
    title: (json['title'] as String?) ?? '',
    status: (json['status'] as String?) ?? 'active',
    goal: json['goal'] as String?,
    metadata: _asMap(json['metadata']),
    activeSession: ActiveSession.maybeFromJson(json['active_session']),
    currentGoal: _asMap(json['current_goal']),
    archiveSnapshot: _snapshot(json['archive_snapshot']),
    createdAt: _date(json['created_at']),
    updatedAt: _date(json['updated_at']),
  );

  /// 序列化回服务端的 JSON 形态（**本地缓存用**）。
  ///
  /// ## 为什么需要它
  ///
  /// 本地缓存（issue #26）存的是服务端返回的**原始 JSON**，而不是把 10 个字段
  /// 拆成数据库列——拆列的话服务端加一个字段就要改客户端 schema + 写迁移，而
  /// `metadata` 下已长到 `follow_up_suggest` / `habit_suggest` / `goal_gate` /
  /// `tts` 四块。存 JSON 则 [fromJson] 直接复用，服务端加字段客户端零改动。
  ///
  /// ## 与 [fromJson] 必须逐字对称
  ///
  /// 键名一律 **snake_case**（与 Go 侧一致，见类文档），嵌套键 `active_session` /
  /// `current_goal` 同样对称。**改这里就必须改 [fromJson]**——不对称会表现为
  /// 「缓存写进去、读出来字段全丢」，而不会报错（`fromJson` 对缺失键给默认值）。
  /// `chat_group_test.dart` 有 round-trip 用例守着这条。
  ///
  /// ## 为什么不写 `DateTime` 的原始字符串
  ///
  /// [createdAt] / [updatedAt] 在 [fromJson] 里已被归一成**本地时区**
  /// （`_date` 用 `toLocal()`），这里用 `toIso8601String()` 写回会丢失原时区
  /// 偏移。但这对缓存无影响：读回时 `_date` 会再 `toLocal()` 一次，而
  /// `DateTime` 的**时刻**（instant）不变——缓存不展示服务端的原始字符串。
  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'title': title,
    'status': status,
    if (goal != null) 'goal': goal,
    if (metadata != null) 'metadata': metadata,
    if (activeSession != null) 'active_session': activeSession!.toJson(),
    if (currentGoal != null) 'current_goal': currentGoal,
    if (archiveSnapshot != null) 'archive_snapshot': archiveSnapshot!.toJson(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// 解析 `archive_snapshot` 子对象。
  ///
  /// 服务端对无快照的 group 显式写 `null`（不省略键），故 null / 非 Map 都
  /// 归一成 null。与 `_asMap` 分开：后者返回空 Map 表示「字段存在但为空」，
  /// 而这里 null 表示「确实没有快照」，两者语义不同。
  static ArchiveSnapshot? _snapshot(Object? v) {
    if (v is Map<String, dynamic>) return ArchiveSnapshot.fromJson(v);
    if (v is Map) return ArchiveSnapshot.fromJson(Map<String, dynamic>.from(v));
    return null;
  }

  static Map<String, dynamic>? _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  /// 取嵌套子对象（metadata 下的 `tts` / `goal_gate` / `follow_up_suggest`）。
  ///
  /// 与 [_asMap] 的区别：后者用于顶层 JSON（非 Map 时返回 null 表示「没这个
  /// 字段」），本方法额外把**非 Map 的值**（如 `tts: false` 这种手工写坏的
  /// metadata）也归一成 null，让所有 getter 共用一条「结构不对 = 未配置」路径。
  static Map<String, dynamic>? _subMap(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : null;

  static DateTime _date(Object? v) =>
      DateTime.tryParse((v as String?) ?? '')?.toLocal() ?? DateTime.now();
}

/// group 中当前活跃的 agent 会话。
class ActiveSession {
  const ActiveSession({
    required this.agentId,
    this.sessionId,
    this.agentSessionId,
    this.role,
    this.joinedAt,
  });

  final String agentId;
  final String? sessionId;

  /// pigo 侧会话 ID，用于 `-r` 续接。
  final String? agentSessionId;
  final String? role;
  final DateTime? joinedAt;

  static ActiveSession? maybeFromJson(Object? v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    final agentId = m['agent_id'] as String?;
    if (agentId == null || agentId.isEmpty) return null;
    return ActiveSession(
      agentId: agentId,
      sessionId: m['session_id'] as String?,
      agentSessionId: m['agent_session_id'] as String?,
      role: m['role'] as String?,
      joinedAt: DateTime.tryParse((m['joined_at'] as String?) ?? '')?.toLocal(),
    );
  }

  /// 序列化回服务端形态（[maybeFromJson] 的逆，**本地缓存用**）。
  ///
  /// 与 [maybeFromJson] 逐字对称（snake_case）。仅在与缓存 round-trip 时被
  /// [ChatGroup.toJson] 调用；`joined_at` 缺失时不写该键，让 [maybeFromJson]
  /// 读回 null（而不是写出一个解析不出的空串）。
  Map<String, dynamic> toJson() => {
    'agent_id': agentId,
    if (sessionId != null) 'session_id': sessionId,
    if (agentSessionId != null) 'agent_session_id': agentSessionId,
    if (role != null) 'role': role,
    if (joinedAt != null) 'joined_at': joinedAt!.toIso8601String(),
  };
}
