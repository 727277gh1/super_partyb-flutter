import 'package:spb_models/spb_models.dart';

/// 执行中活动快照（由 `turn_activity` 事件归一化而来）。
///
/// ## 它解决什么问题
///
/// 执行器在「已起跑但还没有任何正文」的空窗期是静默的：pigo 可能正在读代码、
/// 跑 bash、等模型首 token。此时时间线上什么都不动，用户无法区分
/// 「在干活」与「卡死了」。`turn_activity` 是服务端把执行器心跳**升级**后的
/// turn 视角快照（见 Go `chat/turn_worker.go` 的 `upgradeHeartbeatToActivity`），
/// 携带「已运行多久 + 上一步是什么」，供 UI 展示进度。
///
/// ## 与 heartbeat 的区别（不要混用）
///
/// | | heartbeat | turn_activity |
/// |---|---|---|
/// | 视角 | 执行器（「15s 无输出」） | turn（「已跑 3 分，上一步是 tool_call」） |
/// | payload | 一句固定文案 | `elapsed_ms` + `last_event_type` + `since_last_event_ms` |
/// | 客户端用途 | 仅保活（不进时间线） | 空窗期进度指示 |
///
/// 两者**都是 Transient**（不落库、不回放），故 [TurnActivitySnapshot] 只存在于
/// 在线连接期内——重连后需要等下一个心跳才会重新出现，这是服务端契约而非缺陷。
///
/// ## 对齐 webapp
///
/// 字段与 `apps/webapp/src/lib/workbench/chat-timeline.ts` 的 `ChatTurnActivity`
/// 一一对应（`elapsedMs` / `lastEventType` / `sinceLastEventMs` / `at`），
/// 保证两端进度文案的判定依据一致。
class TurnActivitySnapshot {
  const TurnActivitySnapshot({
    required this.turnId,
    required this.elapsedMs,
    required this.at,
    this.lastEventType,
    this.sinceLastEventMs,
  });

  /// 所属 turn。
  ///
  /// 归约按它取最新（同 turn 多条只保留最后一条，越新越准）。
  final String turnId;

  /// 本 turn 已运行的毫秒数（服务端从 turn 起点算）。
  ///
  /// 服务端每次心跳重算，故**不要**在客户端按本地时钟累加——重连或时钟偏移
  /// 时两者会不一致，而服务端的值是权威的。
  final int elapsedMs;

  /// 最近一步实质动作的事件类型（如 `tool_call` / `thought`）。
  ///
  /// 为 null 表示本 turn 还没有过任何事件（刚起跑）——UI 应只显示已运行时长，
  /// 不要拼出「最近：null」。
  final String? lastEventType;

  /// 距最近一步实质动作的毫秒数。
  ///
  /// 为 null 表示没有上一步可参照（与 [lastEventType] 同时为 null）。
  /// **null ≠ 0**：「没有上一步」与「上一步就在此刻」语义不同。
  final int? sinceLastEventMs;

  /// 事件到达时间，供渲染层判断「这条快照有多旧」。
  final DateTime at;

  /// 从事件构造；非 `turn_activity` 事件返回 null。
  ///
  /// 放在领域层而非直接读 `ChatEvent` 的动机：UI 不应关心 payload 键名，
  /// 且 `turnId` 为空的事件无法按 turn 归并（丢弃而非静默挂到空 turn 上）。
  static TurnActivitySnapshot? fromEvent(ChatEvent ev) {
    if (ev.eventType != EventTypes.turnActivity) return null;
    if (ev.turnId.isEmpty) return null;
    return TurnActivitySnapshot(
      turnId: ev.turnId,
      // 缺失时取 0：与 webapp 一致（`typeof elapsedRaw === "number" ? ... : 0`），
      // 已运行时长是「总在」的字段，缺失属异常载荷，退化为 0 比 null 更好用
      // ——UI 只需处理一个分支（不过 0 会让 UI 显示「已运行 0 秒」，故 UI 侧
      // 仍可结合 elapsedMs == 0 判定为「刚起跑」）。
      elapsedMs: ev.turnActivityElapsedMs ?? 0,
      lastEventType: ev.turnActivityLastEventType,
      sinceLastEventMs: ev.turnActivitySinceLastEventMs,
      at: ev.createdAt,
    );
  }

  @override
  String toString() =>
      'TurnActivitySnapshot(turn=$turnId, elapsed=${elapsedMs}ms'
      '${lastEventType != null ? ', last=$lastEventType' : ''})';
}

/// group 变更操作（`group_updated` 的 `op`）。
///
/// ## 为什么用 enum 而不是原样 String
///
/// 与 [GateDecisionKind] 同一取向：UI 的 `switch` 可以穷举（编译期保证不漏
/// 分支），而不是散落的 `op == 'deleted'` 比较——后者在服务端新增 op 时会
/// **静默走 default**，表现为「这个变更不刷新列表」。
///
/// 但这里**额外保留 [unknown]** 而非丢弃事件：未知 op 的正确兜底是「整体重拉
/// 一次列表」（代价可忽略，见 Go `chatbus.EventGroupUpdated` 注释），
/// 而不是假装没发生过。
///
/// 值域真源：Go `internal/chat/group_events.go` 的 `GroupEventOp`。
enum GroupUpdateOp {
  /// 新建 group（可能是 chatpipeline 静默建组、habit 建独立组、miniapp 建 work
  /// ——这些都不经过用户的「新建」按钮，前端无从得知）。
  created('created', '已创建'),

  /// group 被删除。
  deleted('deleted', '已删除'),

  /// group 被归档（从活跃列表移出）。
  archived('archived', '已归档'),

  /// group 恢复为活跃。
  active('active', '已恢复'),

  /// 标题变更。
  title('title', '已改名'),

  /// 元数据变更（非标题、非状态的字段）。
  metadata('metadata', '已更新'),

  /// 服务端新增了本客户端不认识的 op（向前兼容，不丢弃事件）。
  unknown('', '未知变更');

  const GroupUpdateOp(this.wire, this.label);

  /// 服务端原始值。
  final String wire;

  /// 中文展示标签。
  final String label;

  /// 服务端值 → 枚举。未知值归 [unknown]，**不抛异常**。
  static GroupUpdateOp fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return unknown;
    for (final op in values) {
      if (op.wire == wire) return op;
    }
    return unknown;
  }

  /// 是否需要「整体重拉列表」而非增量处理。
  ///
  /// [unknown] 为真：未知 op 下我们不知道列表该怎么变，重拉是唯一安全兜底
  /// （group 变更频率极低，代价可忽略）。
  bool get needsRefetch => this == unknown;
}

/// 一条 group 变更通知（由 `group_updated` 事件归一化而来）。
///
/// ## 为什么是通知而不是快照
///
/// 真源是 `chat_groups` 表，事件只告诉前端「你手上的列表过期了」。payload 里的
/// group 是**刻意最小化**的身份快照（`{id, title, status}`），不含完整 DTO
/// ——见 Go `chat/group_events.go` 文件头注释：让 `chat` 包依赖 `server` 包的
/// 序列化是反向依赖，且 group 列表 refetch 很便宜。
///
/// 故 [title] / [status] 只用于**去重与占位**（乐观更新），详情字段仍以 refetch
/// 或业务表为准。
///
/// ## 为什么逐条推送而不累积
///
/// 它是**通知语义**：每次变更各是一次独立事件，按顺序处理（created 后 deleted
/// 与反过来结果不同）。累积成列表反而要求消费方自己排序与去重。
class GroupUpdate {
  const GroupUpdate({
    required this.op,
    required this.groupId,
    this.title,
    this.status,
    this.at,
  });

  /// 变更类型。
  final GroupUpdateOp op;

  /// 变更的 group id。
  ///
  /// 取事件自身的 `groupId`（broker 的 fan-out 路由键，必填），**不**依赖
  /// payload 快照里的 `id`——`PublishGroupUpdated` 对空 id 直接跳过发布，
  /// 故事件一定带 id；而快照字段在异常载荷下可能缺失。
  final String groupId;

  /// 快照里的标题（可能缺失：`op=deleted` 的快照只带 id）。
  final String? title;

  /// 快照里的状态（`active` / `archived`；可能缺失）。
  ///
  /// 保持 String 而非 enum：服务端 `GroupSnapshot.status` 是自由字符串，
  /// 且本字段只用于乐观更新展示，未知值忽略即可。
  final String? status;

  /// 事件到达时间。
  final DateTime? at;

  /// 从事件构造；非 `group_updated` 事件返回 null。
  ///
  /// `groupId` 为空的事件无法定位要更新哪一项，丢弃（服务端不变量是「发布即
  /// 有 group id」，缺失属异常载荷）。
  static GroupUpdate? fromEvent(ChatEvent ev) {
    if (ev.eventType != EventTypes.groupUpdated) return null;
    if (ev.groupId.isEmpty) return null;
    final snap = ev.groupUpdateSnapshot;
    return GroupUpdate(
      op: GroupUpdateOp.fromWire(ev.groupUpdateOp),
      groupId: ev.groupId,
      title: _strOrNull(snap?['title']),
      status: _strOrNull(snap?['status']),
      at: ev.createdAt,
    );
  }

  /// 取非空字符串；空串/非字符串返回 null。
  ///
  /// 空标题不能被当成有效标题（否则 UI 会把 group 名清空）。
  static String? _strOrNull(Object? v) {
    if (v is! String) return null;
    return v.isEmpty ? null : v;
  }

  @override
  String toString() =>
      'GroupUpdate(${op.wire}, group=$groupId'
      '${title != null ? ', title=$title' : ''}'
      '${status != null ? ', status=$status' : ''})';
}
