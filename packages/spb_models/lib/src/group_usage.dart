/// group 级 token 用量聚合（`GET /chat/groups/:group_id/usage-summary`）。
///
/// ## 它是什么，与 [ContextUsage] 有什么区别
///
/// 两者都描述「这个对话用了多少 token」，但**口径不同、不可合并**：
///
/// | | 本模型的 [GroupUsageTotals] | `ContextUsage` |
/// |---|---|---|
/// | 来源 | `token_usage` 事件求和（**账单**） | `context_update` 快照（**窗口水位**） |
/// | 语义 | 这个对话**总共烧了多少**（多轮工具调用的 input 逐帧累加） | 当前占了多少上下文窗口（compaction 后会**变小**） |
/// | 单调性 | 单调递增 | 可增可减 |
/// | 汇总位置 | **服务端** SQL `SUM(json_extract(payload_json, ...))` | 客户端按最后一条快照 |
///
/// 把两者塞进同一个「已用 / 窗口」里会得到一个既不解释账单、也不解释压缩的数字
/// ——webapp 的状态侧栏为此把它们拆成两段（见 Go `server/chat_usage.go` 的文件头）。
///
/// ## 为什么总量必须来自服务端，而不是前端把事件加起来
///
/// `token_usage` 是**持久化业务事件**，但**不在**渲染白名单
/// （`EventTypes.timelineVisible`）里：观测数据不挤占对话事件。客户端的时间线
/// 缓冲有上限（`ChatStreamController.maxBufferEvents = 2000`，且按**整轮**裁剪），
/// 长会话里较早的 `token_usage` 会被裁掉——从缓冲求和会**越用越少**。
/// 故真源是服务端的聚合端点；SSE 事件只在**已拿到基线之后**做本地增量
/// （见 [GroupUsageSummary.incrementedByEvent]）。
///
/// ## 数据起点
///
/// `token_usage` 事件从引入该能力的部署时点起才有，历史 turn 无数据。
/// [GroupUsageTotals.firstAt] 供 UI 提示「统计自 X 起（更早的会话无记录）」，
/// 避免用户误以为数字覆盖全史。
class GroupUsageSummary {
  const GroupUsageSummary({required this.totals, this.byAgent = const []});

  /// 全 group 合计。
  final GroupUsageTotals totals;

  /// 按 agent 的分布（服务端解析 agent 名；`agent_id` 为 NULL 时显示「未分配」）。
  ///
  /// ⚠️ **不做本地增量合并**：一条 `token_usage` 事件只能确定地加进 totals，
  /// 要加进正确的 by_agent 桶需要复刻服务端的 NULL/改名/分组逻辑。分布是低频
  /// 查看路径，交给下次拉取刷新（与 webapp `applyUsageIncrement` 同一取舍）。
  final List<GroupUsageAgentItem> byAgent;

  /// 是否已有可用数据（`calls == 0` 表示该 group 尚无 `token_usage` 记录）。
  ///
  /// 为 false 时 UI 应显示占位/不显示，**不得**渲染全 0 的账单——「还没有记录」
  /// 与「消耗为 0」是两回事。
  bool get hasData => totals.hasData;

  /// 从端点响应解析（字段全 snake_case，与 `token_usage` 事件 payload 同风格）。
  factory GroupUsageSummary.fromJson(Map<String, dynamic> json) {
    final totalsRaw = json['totals'];
    final byAgentRaw = json['by_agent'];
    return GroupUsageSummary(
      totals: totalsRaw is Map
          ? GroupUsageTotals.fromJson(Map<String, dynamic>.from(totalsRaw))
          : GroupUsageTotals.empty,
      byAgent: byAgentRaw is List
          ? List<GroupUsageAgentItem>.unmodifiable(
              // 用 Map<Object?, Object?> 而非裸 Map：严格模式（strict_raw_type）
              // 会报泛型缺失；而直接写 Map<String, dynamic> 又会在「手造的测试
              // 数据是 Map<String, Object?>」时漏匹配（匹配不上 ⇒ 条目静默丢失）。
              byAgentRaw.whereType<Map<Object?, Object?>>().map(
                (e) =>
                    GroupUsageAgentItem.fromJson(Map<String, dynamic>.from(e)),
              ),
            )
          : const [],
    );
  }

  /// 收到一条 `token_usage` 事件后的本地增量。
  ///
  /// [occurredAt] 取**事件行**的 `created_at`（与 webapp 一致：`token_usage` 的
  /// payload 不带时间，时间在事件行上），用于推进 `last_at`。
  ///
  /// 返回新实例（不原地修改）：页面 State 会直接持有上一条快照。
  GroupUsageSummary incrementedByEvent(
    Map<String, dynamic> payload, {
    String occurredAt = '',
  }) {
    return GroupUsageSummary(
      totals: totals.plus(
        GroupUsageTotals.deltaFromEventPayload(payload, occurredAt: occurredAt),
      ),
      // 见 [byAgent] 的说明：分布不在本地合并。
      byAgent: byAgent,
    );
  }

  @override
  String toString() => 'GroupUsageSummary($totals, byAgent=${byAgent.length})';
}

/// group 级用量合计（计费口径）。
class GroupUsageTotals {
  const GroupUsageTotals({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.reasoningTokens = 0,
    this.totalTokens = 0,
    this.calls = 0,
    this.firstAt = '',
    this.lastAt = '',
  });

  /// 全零、无时间戳的基线（服务端无数据时的响应形状）。
  static const empty = GroupUsageTotals();

  final int inputTokens;
  final int outputTokens;

  /// 命中缓存的 input 量。
  ///
  /// ⚠️ **是 [inputTokens] 的子集**，只做维度展示，**不参与**加总
  /// （Anthropic `cache_read` / OpenAI `cached_tokens` 同义）。
  final int cachedTokens;

  /// 推理 token（仅部分模型上报；Go 侧为 0 时不发该字段）。
  final int reasoningTokens;

  /// 服务端/执行器上报的 total。
  ///
  /// 与 [burnedTokens] 可能不等（缺失时 Go 侧用累计 input+output 兜底），
  /// 但**展示口径一律用 [burnedTokens]**，避免两处数字打架。
  final int totalTokens;

  /// `token_usage` 事件条数 = 有账单的 turn 数。
  ///
  /// ⚠️ **不是** LLM 请求数：同一个 turn 内多轮工具调用的请求数在事件 payload
  /// 的 `calls` 字段里，而这里的 `calls` 是服务端 `COUNT(*)`——两者不可互换。
  final int calls;

  /// 首条 `token_usage` 事件时间（ISO 8601）。空串 = 尚无数据。
  final String firstAt;

  /// 最后一条 `token_usage` 事件时间（ISO 8601）。空串 = 尚无数据。
  final String lastAt;

  /// 已有可用数据（有账单记录）。
  bool get hasData => calls > 0;

  /// 计费口径的总消耗：`input + output`。
  ///
  /// 与 webapp `tokensBurned` 逐字对齐：**`cached` 不加进来**（它是 input 的
  /// 子集，加了就重复计数）。
  int get burnedTokens => inputTokens + outputTokens;

  /// [firstAt] 的解析结果；空串或不可解析时为 null。
  DateTime? get firstAtTime => _parseTime(firstAt);

  /// [lastAt] 的解析结果；空串或不可解析时为 null。
  DateTime? get lastAtTime => _parseTime(lastAt);

  /// 逐字段相加（`calls` 相加、时间取并集：首条取更早的非空值、末条取非空的新值）。
  GroupUsageTotals plus(GroupUsageTotals other) {
    return GroupUsageTotals(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      cachedTokens: cachedTokens + other.cachedTokens,
      reasoningTokens: reasoningTokens + other.reasoningTokens,
      totalTokens: totalTokens + other.totalTokens,
      calls: calls + other.calls,
      // 首条时间：已有值优先（本地增量的事件必然更晚）；基线为空时由增量补上。
      firstAt: firstAt.isNotEmpty ? firstAt : other.firstAt,
      // 末条时间：增量的（更晚）优先；增量没带时间时保留旧值。
      lastAt: other.lastAt.isNotEmpty ? other.lastAt : lastAt,
    );
  }

  /// 一条 `token_usage` 事件 payload 对应的增量。
  ///
  /// ## `calls` 恒 +1（**不要**读 payload 的 `calls`）
  ///
  /// 服务端的合计是 `COUNT(*)`——**一条事件一个 turn**。而 payload 里的 `calls`
  /// 是「本 turn 内采到用量的 LLM 请求数」（见 `chatexec.TokenUsage.Calls`），
  /// 两者量纲不同。用 payload 的 `calls` 做增量会让客户端的「请求次数」与服务端
  /// 聚合**永久漂移**（刷新前偏大、刷新后突然变小）。
  ///
  /// ## 缺字段按 0 处理
  ///
  /// Go 的 `TokenUsage.Payload()` 对零值字段**不落键**（`cached_tokens` /
  /// `reasoning_tokens` / `total_tokens` 都可能缺席），服务端 `SUM` 对缺失行同样
  /// 计 0，故这里是缺省 0 而非「不可用」。
  static GroupUsageTotals deltaFromEventPayload(
    Map<String, dynamic> payload, {
    String occurredAt = '',
  }) {
    return GroupUsageTotals(
      inputTokens: _int(payload['input_tokens']),
      outputTokens: _int(payload['output_tokens']),
      cachedTokens: _int(payload['cached_tokens']),
      reasoningTokens: _int(payload['reasoning_tokens']),
      totalTokens: _int(payload['total_tokens']),
      calls: 1,
      firstAt: occurredAt,
      lastAt: occurredAt,
    );
  }

  /// 从端点响应的 `totals` 对象解析。
  factory GroupUsageTotals.fromJson(Map<String, dynamic> json) {
    return GroupUsageTotals(
      inputTokens: _int(json['input_tokens']),
      outputTokens: _int(json['output_tokens']),
      cachedTokens: _int(json['cached_tokens']),
      reasoningTokens: _int(json['reasoning_tokens']),
      totalTokens: _int(json['total_tokens']),
      calls: _int(json['calls']),
      firstAt: _string(json['first_at']),
      lastAt: _string(json['last_at']),
    );
  }

  @override
  String toString() =>
      'GroupUsageTotals(in=$inputTokens, out=$outputTokens, cached=$cachedTokens, '
      'reasoning=$reasoningTokens, total=$totalTokens, calls=$calls, '
      "firstAt='$firstAt', lastAt='$lastAt')";
}

/// 按 agent 的用量分布（`by_agent` 的一项）。
class GroupUsageAgentItem {
  const GroupUsageAgentItem({
    this.agentId = '',
    this.agentName,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.calls = 0,
    this.lastAt = '',
  });

  /// agent id。空串表示事件落账时 `agent_id` 为 NULL（绑定解析前 / agent 被硬删），
  /// 服务端把这种归为「未分配」且**保留在合计里**（不会静默丢失）。
  final String agentId;

  /// 展示名。服务端解析不到时缺席（UI 退回 [agentId]）。
  final String? agentName;

  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;
  final int calls;
  final String lastAt;

  /// 展示用名字：优先服务端解析的名字，其次 id，都没有时给「未分配」占位。
  String get displayName {
    final name = agentName;
    if (name != null && name.isNotEmpty) return name;
    if (agentId.isNotEmpty) return agentId;
    return '未分配';
  }

  factory GroupUsageAgentItem.fromJson(Map<String, dynamic> json) {
    return GroupUsageAgentItem(
      agentId: _string(json['agent_id']),
      agentName: json['agent_name'] is String
          ? json['agent_name'] as String
          : null,
      inputTokens: _int(json['input_tokens']),
      outputTokens: _int(json['output_tokens']),
      cachedTokens: _int(json['cached_tokens']),
      calls: _int(json['calls']),
      lastAt: _string(json['last_at']),
    );
  }

  @override
  String toString() =>
      'GroupUsageAgentItem($displayName, in=$inputTokens, out=$outputTokens, '
      'calls=$calls)';
}

// ---------- 内部辅助 ----------

/// 数字解析：接受 int / num / 数字字符串；其余（含 null）按 0。
///
/// 按 0 而非「不可用」：调用方都是聚合场景，缺字段意味着该项为 0
/// （见 `deltaFromEventPayload` 的说明）。
int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) {
    final parsed = int.tryParse(v) ?? double.tryParse(v)?.round();
    if (parsed != null) return parsed;
  }
  return 0;
}

String _string(Object? v) => v is String ? v : '';

DateTime? _parseTime(String raw) {
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toLocal();
}
