import 'package:spb_models/spb_models.dart';

/// 执行等待/重试状态（由 `queue_state` / `retry_scheduled` 归一化而来）。
///
/// ## 它解决什么问题
///
/// 「用户发了消息，但助手迟迟不回复」有两种截然不同的原因，而时间线上
/// **都没有任何内容**：
///
/// | 原因 | 服务端事件 | 用户该知道的事 |
/// |---|---|---|
/// | 还在排队等执行名额 | `queue_state` | 「在等，不是没收到」+ 排队规模 |
/// | 上一轮失败，正在安排重试 | `retry_scheduled` | 「在重试，第 N 次」 |
///
/// 没有它，这两种等待与「卡死」在 UI 上完全无法区分。
///
/// ## 与 [TurnActivitySnapshot] 的分工（不要混用）
///
/// | | ExecutionStatus | TurnActivitySnapshot |
/// |---|---|---|
/// | 语义 | **还没开始跑**（等名额 / 等重试） | **已经在跑**但没正文 |
/// | 事件 | `queue_state` / `retry_scheduled` | `turn_activity` |
/// | 视觉落点 | 同一槽位，**优先于** activity | 同一槽位，让位于 status |
///
/// webapp 用同一判定（`turn.activity && !turn.queueReason`），本模型照搬。
///
/// ## ⚠️ 纠正任务前提：这两类事件**不是** Transient
///
/// 任务描述称「两个事件都是 Transient 通知（真源在服务端队列）」。实测 Go 侧
/// **五个发射点全部未设 `Transient`**：
///
/// - `chat/enqueue.go:393,462` —— 走 `persistEventAtomic`（INSERT `chat_events`）
/// - `chat/turn_worker.go:1295,1499` —— 走 `w.emit`（`ev.Transient` 为假 → 落库分支）
/// - `chatgate/gate_impls.go:173` —— 经 `Emitter` → 同一 `w.emit`
///
/// 因此它们**有**有效 `eventId` / `globalSeq`、**会**推进 SSE 游标、**会**被
/// 历史回放。故：
///
/// 1. 归约器**不需要** Transient 豁免（对比 `goal_updated`，那个才是 Transient）；
/// 2. 「收到正文后清除」必须按 **globalSeq 顺序**判定，而不是「只在实时路径清除」
///    ——否则回放一段早已跑完的历史时，会永远挂着一条「排队中」。
class ExecutionStatus {
  const ExecutionStatus({
    required this.turnId,
    required this.kind,
    this.reason,
    this.attempt,
    this.maxRetries,
    this.delayMs,
    this.queueTotal,
    this.queueUser,
    this.globalSeq = 0,
    required this.at,
  });

  /// 所属 turn。等待/重试都是 per-turn 的（同一用户可能有多个 group 在排队）。
  final String turnId;

  /// 等待类型。
  final ExecutionStatusKind kind;

  /// 排队原因（`session_busy` / `user_concurrency_limit` /
  /// `global_concurrency_limit` / `scheduled` / `retry_scheduled`）。
  ///
  /// ⚠️ `retry_scheduled` 的 `reason` 是**执行器的 stderr 原文**
  /// （`gate_impls.go` 的 `gc.Outcome.Stderr`），可能很长且含噪声，
  /// **不要**把它渲染成横幅文案（webapp 同样只用 `attempt`）。
  final String? reason;

  /// 第几次重试（`retry_scheduled.attempt`，服务端为 1-based）。
  final int? attempt;

  /// 最大重试次数（`retry_scheduled.max_retries`）。
  final int? maxRetries;

  /// 距下次重试的毫秒数（`retry_scheduled.delay_ms`）。
  final int? delayMs;

  /// 队列中的总任务数（`queue_state.queue_total`）。
  final int? queueTotal;

  /// 队列中属于当前用户的任务数（`queue_state.queue_user`）。
  final int? queueUser;

  /// 该事件的 `globalSeq`，供 UI 在多条状态间选最新。
  ///
  /// 为 0 表示服务端未给（异常载荷）——此时按到达顺序，后到的覆盖先到的。
  final int globalSeq;

  /// 事件到达时间。
  final DateTime at;

  /// 从事件构造；不是 `queue_state` / `retry_scheduled`，或载荷不可用时返回 null。
  ///
  /// `queue_state` 只在 `state == 'queued'` 时产出状态：`state == 'cancelled'`
  /// （`EmitCanceled` 发的那种）是**终态**而非等待，由 [clearsOn] 负责清除。
  static ExecutionStatus? fromEvent(ChatEvent ev) {
    if (ev.turnId.isEmpty) return null;

    if (ev.eventType == EventTypes.queueState) {
      if (ev.queueStateValue != 'queued') return null;
      return ExecutionStatus(
        turnId: ev.turnId,
        kind: ExecutionStatusKind.queued,
        reason: ev.queueReason,
        queueTotal: ev.queueTotal,
        queueUser: ev.queueUser,
        globalSeq: ev.globalSeq ?? 0,
        at: ev.createdAt,
      );
    }

    if (ev.eventType == EventTypes.retryScheduled) {
      return ExecutionStatus(
        turnId: ev.turnId,
        kind: ExecutionStatusKind.retryScheduled,
        reason: ev.queueReason,
        attempt: ev.retryAttempt,
        maxRetries: ev.retryMaxRetries,
        delayMs: ev.retryDelayMs,
        globalSeq: ev.globalSeq ?? 0,
        at: ev.createdAt,
      );
    }

    return null;
  }

  /// 该事件是否意味着「等待已结束」，应清除该 turn 的状态。
  ///
  /// ## 为什么在归约层清除而不是只在 UI 里判断
  ///
  /// 清除必须按事件顺序生效。归约器单趟按 globalSeq 升序处理，`queue_state`
  /// 之后到来的 `start`/`message` 自然把状态抹掉——回放一段历史（排队 → 起跑 →
  /// 回复）也会得到「无等待」的终态，与实时路径一致。
  ///
  /// 只清**同一 turn**：别的 turn 的正文不该抹掉本 turn 的排队提示。
  static bool clearsOn(ChatEvent ev) {
    switch (ev.eventType) {
      // 起跑：名额已拿到，等待结束。Go `turn_worker.go:767` 在真正执行前发它，
      // 且**落库**，故回放路径同样能命中。
      case EventTypes.start:
      // 有正文（含流式增量）：助手已经在回话，等待显然结束。
      case EventTypes.message:
      // 终态：turn 已结束，不该再挂「等待中」。
      case EventTypes.done:
      case EventTypes.error:
        return true;
      case EventTypes.queueState:
        // 只有 `queued` 是「在等」；`cancelled` 等其余状态是等待结束。
        return ev.queueStateValue != 'queued';
      default:
        return false;
    }
  }

  @override
  String toString() =>
      'ExecutionStatus(${kind.wire}, turn=$turnId'
      '${reason != null ? ', reason=$reason' : ''}'
      '${attempt != null ? ', attempt=$attempt' : ''})';
}

/// 等待类型。
///
/// 用 enum 而非原样 String：UI 的 `switch` 可穷举（编译期保证不漏分支），
/// 避免散落的 `kind == 'retry_scheduled'` 比较在服务端新增类型时静默走 default。
///
/// 与 [GroupUpdateOp] 不同，这里**不设 `unknown`**：未知类型由
/// [ExecutionStatus.fromEvent] 直接返回 null（即「不认识就当没有」）。
/// 理由是本模型只驱动一条提示横幅，漏掉一条未知状态最多是「少提示一次」，
/// 不像 group 变更那样需要「未知也要重拉」的兜底。
enum ExecutionStatusKind {
  /// 排队等待执行名额。
  queued('queued'),

  /// 上一轮失败，已安排重试。
  retryScheduled('retry_scheduled');

  const ExecutionStatusKind(this.wire);

  /// 服务端原始值。
  final String wire;
}
