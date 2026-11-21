import 'package:spb_models/spb_models.dart';

/// 决策动作（归一化后的值域）。
///
/// ## 为什么用 enum 而不是原样 String
///
/// 服务端两类 gate 事件的「决策」语义不同、字段名也不同：
///
/// | 事件 | 决策字段 | 值域 |
/// |---|---|---|
/// | `adaptive_decision` | `action` | `stop` / `auto_continue` / `auto_repeat` / `need_confirmation` |
/// | `goal_gate_decision` | 无（由 `goal_achieved` / `stopped` 推导） | `goal_completed` / `goal_failed` / `stop` / `auto_continue` |
///
/// 归一到一个枚举后，UI 的 `switch` 可以穷举（编译期保证不漏分支），
/// 而不是对字符串做散落的 `== 'stop'` 比较——后者在服务端新增一个
/// 动作时会**静默走 default**，表现为「这个决策不显示任何徽标」。
enum GateDecisionKind {
  autoContinue('auto_continue', '继续'),
  autoRepeat('auto_repeat', '重试'),
  stop('stop', '停止'),
  needConfirmation('need_confirmation', '待确认'),
  goalCompleted('goal_completed', '目标达成'),
  goalFailed('goal_failed', '目标未达成'),

  /// 服务端新增了本客户端不认识的决策值（向前兼容，不丢弃事件）。
  unknown('', '未知');

  const GateDecisionKind(this.wire, this.label);

  /// 服务端原始值（`adaptive_decision.action` 或归一化推导值）。
  final String wire;

  /// 中文展示标签（UI 徽标）。
  final String label;

  /// 服务端值 → 枚举。未知值归 [unknown]，**不抛异常**：
  /// 服务端随时可能新增决策类型，让客户端崩掉或静默丢弃都是错的。
  static GateDecisionKind fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return unknown;
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return unknown;
  }

  /// 是否「不再自动续跑、等人工处理」。
  ///
  /// 包含 [stop]、[goalCompleted]、[goalFailed] 与 [needConfirmation]：
  /// `need_confirmation` 同样是「停下来等人工」——服务端降级建确认卡并
  /// 停止自动续跑（见 `chatgate/arbiter.go` 的 enforce 分支）。把它排除在
  /// 终态之外，会让 UI 把它误展示为「还在自动跑」，用户便不会去处理那张卡。
  ///
  /// [autoContinue] / [autoRepeat] 不是终态：agent 会继续自己跑下一轮。
  /// [unknown] 也不是：对未知决策断言「已停止」是危险的误报。
  bool get isTerminal =>
      this == stop ||
      this == goalCompleted ||
      this == goalFailed ||
      this == needConfirmation;
}

/// 决策来源（用于分组展示与排障）。
enum GateSourceKind {
  /// Fast Path 规则命中（`gate_source=fastpath`）。
  fastPath('fastpath', '规则'),

  /// LLM Gate（`gate_source=llm_gate`）。
  llmGate('llm_gate', 'LLM 判定'),

  /// 重试 Gate（`gate_source=retry_gate`）。
  retryGate('retry_gate', '重试'),

  /// Goal Gate（任务表判定，来源值是 `tasks_completed` 等具体原因）。
  goalGate('', '目标'),

  /// 未识别的来源。
  unknown('', '未知');

  const GateSourceKind(this.wire, this.label);

  final String wire;
  final String label;

  static GateSourceKind fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return unknown;
    for (final k in values) {
      if (k.wire.isNotEmpty && k.wire == wire) return k;
    }
    // goal gate 的 source 是具体原因（tasks_completed / task_blocked /
    // no_tasks / task_error_stopped），不是固定枚举值——凡不以已知
    // fastpath/llm_gate/retry_gate 开头的，都归为 goalGate。
    return goalGate;
  }
}

/// 一条 Gate 决策（由 `adaptive_decision` / `goal_gate_decision` 事件归约而来）。
///
/// ## 为什么不放进 `ConversationItem`
///
/// 时间线的核心不变式是「只放用户可见的对话内容」（见 `ConversationItem`
/// 的类文档：heartbeat / queue_state / gate_* 不进对话列表）。Gate 决策是
/// **控制流诊断信息**——`auto_continue` 这类决策在对话流里夹在消息之间会
/// 严重干扰阅读，而它在「为什么 agent 自己又跑了一轮」这个排障场景下又
/// 极有价值。故它走独立通道（[ReductionResult.gateDecisions]），由侧边栏的
/// 诊断面板消费，与 webapp `WorkbenchGatePanel` 的定位一致。
///
/// ## 这是修复一个既有缺陷
///
/// 此前 `event_reducer.dart` 的 `default` 分支把 `adaptive_decision` /
/// `goal_gate_decision` **静默丢弃**（事件类型常量已在 `EventTypes` 里声明，
/// 但没有消费者）。这与 AGENTS.md §5.4「新增/改名事件必须两边同步，否则
/// 客户端静默丢弃」的告警同源：常量同步了，消费端漏了。
class GateDecision {
  const GateDecision({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.source,
    this.turnId = '',
    this.rawSource = '',
    this.confidence,
    this.reason,
    this.nextInputPreview,
    this.stopReason,
  });

  /// 事件 id（稳定标识，供列表 diff）。
  final String id;

  final DateTime createdAt;
  final String turnId;

  /// 归一化后的决策动作。
  final GateDecisionKind kind;

  /// 归一化后的来源分类。
  final GateSourceKind source;

  /// 服务端原始来源值（如 `tasks_completed`），供排障展示。
  final String rawSource;

  /// 决策置信度。**仅 `adaptive_decision` 带**：goal gate 是任务表确定性
  /// 判定，没有置信度概念，恒为 null。
  final double? confidence;

  final String? reason;

  /// 下一步输入预览（服务端截断到 240 字符）。
  final String? nextInputPreview;

  /// 停止原因（`goal_gate_decision.stop_reason`，如 `task_blocked`）。
  final String? stopReason;

  /// 是否由 Goal Gate（任务表判定）产生。
  bool get isGoalGate => source == GateSourceKind.goalGate;

  @override
  String toString() =>
      'GateDecision(${kind.wire}, source=$rawSource, turn=$turnId)';
}

/// 从事件流中收集 Gate 决策（按事件顺序，即时间正序）。
///
/// ## 与 webapp `collectGateDecisions` 的差异（有意为之）
///
/// webapp 版本兼容了 Python 时代的三类事件与「嵌套 gate_decision /
/// fused_decision 对象」形态（`adaptive_gate_decision` / `fused_decision` /
/// `decision_changed` / `fusion_debug` 等）。Go 版**只发** `adaptive_decision`
/// （扁平 payload，见 `chatgate/arbiter.go` 的 `emitDecisionEvent`）与
/// `goal_gate_decision`（见 `chatgate/goal_gate.go`）。
///
/// 故这里只认这两种，**不为已不存在的形态写兼容分支**：那些分支永远不被
/// 命中，却会让人以为服务端可能发它们，反而掩盖真实契约（对齐
/// `event_reducer.dart` 里对「误导性托底注释」的批评）。
///
/// 新增事件类型时的正确做法：先确认 Go 侧 `chatbus/broker.go` 的常量与
/// payload 构造点，再在这里加分支。
List<GateDecision> collectGateDecisions(Iterable<ChatEvent> events) {
  final out = <GateDecision>[];
  for (final ev in events) {
    final d = gateDecisionFrom(ev);
    if (d != null) out.add(d);
  }
  return out;
}

/// 单个事件 → Gate 决策；非 gate 事件返回 null。
///
/// 供 [collectGateDecisions]（批量）与 `EventReducer.reduce`（单趟归约，避免对
/// 惰性 Iterable 迭代两次）共用，保证两处判定规则永远一致。
GateDecision? gateDecisionFrom(ChatEvent ev) {
  switch (ev.eventType) {
    case EventTypes.adaptiveDecision:
      final rawSource = ev.gateSource ?? '';
      return GateDecision(
        id: ev.eventId,
        createdAt: ev.createdAt,
        turnId: ev.turnId,
        kind: GateDecisionKind.fromWire(ev.gateAction),
        source: GateSourceKind.fromWire(rawSource),
        rawSource: rawSource,
        confidence: ev.gateConfidence,
        reason: ev.gateReason,
        nextInputPreview: ev.gateNextInputPreview,
      );

    case EventTypes.goalGateDecision:
      // goal gate 没有 action 字段，决策由三个布尔/字符串推导。
      //
      // 顺序不能换：`goal_achieved=false` 与 `stopped=true` 同时成立时
      // 语义是「停止等人工」，而不是「继续」。这正是服务端加 `stopped`
      // 字段的原因（见 goal_gate.go 的注释：单凭 goal_achieved 会把停止
      // 误展示为 continue）。
      final failed = ev.payload?['goal_gate_failed'] == true;
      final rawSource = ev.gateSource ?? '';
      final kind = failed
          ? GateDecisionKind.goalFailed
          : ev.goalAchieved
          ? GateDecisionKind.goalCompleted
          : ev.goalStopped
          ? GateDecisionKind.stop
          : GateDecisionKind.autoContinue;

      return GateDecision(
        id: ev.eventId,
        createdAt: ev.createdAt,
        turnId: ev.turnId,
        kind: kind,
        source: GateSourceKind.goalGate,
        rawSource: rawSource,
        reason: ev.gateReason,
        nextInputPreview: ev.gateNextInputPreview,
        stopReason: ev.goalStopReason,
      );

    default:
      return null;
  }
}
