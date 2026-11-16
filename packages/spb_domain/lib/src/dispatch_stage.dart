import 'package:spb_models/spb_models.dart';

/// 分发阶段进度（`dispatch_stage` 事件的归约输出）。
///
/// ## 它解决什么问题
///
/// 「按下发送」到「收到该 turn 首个事件」之间，客户端今天完全静默：服务端在建
/// turn **之前**要先做归属分类、向量编码、入队（实测中位 3~28ms，长尾 **3.7s**
/// 且其中 **3147ms 未被任何段记账**，见 super_partyb#86 / #181）。这段窗口里的
/// 唯一信号就是本包消费的 `dispatch_stage`。
///
/// 时间轴上的分工（四段互不重叠，缺一段就是黑屏）：
///
/// | 窗口 | 信号 |
/// |---|---|
/// | 按下发送 → 服务端受理 | 本地乐观回显 `pending`（`ChatStreamController.send`） |
/// | **分发（分类 / 编码 / 入队）** | **`dispatch_stage`（本文件）** |
/// | turn 已建、排队 | `queue_state` / `retry_scheduled` → [ExecutionStatus] |
/// | 执行中无正文 | `turn_activity` → [TurnActivitySnapshot] |
///
/// ## 三条不可违反的判据
///
/// 1. **归因只能靠 `request_id`**：事件无 group、无 turn（分发发生在定 group 之前），
///    而 SSE 是 user 级广播，别的设备 / 小程序 BFF / quick capture / habit 的
///    分发帧都会到同一条连接。只有与本端 `send()` 生成的那个 rid 比对才是可靠的。
/// 2. **配对键是 `(request_id, name)`，同名段可重复**（编码有重试）。展示取「最后
///    一条 `start` 且未 `end` 的段」；迟到的 `end` 只追加历史，不改当前段。
/// 3. **不是权威状态**：`Transient` 不落库、断线不回放。断线/切后台一律按本地
///    计时降级，重连后由 timeline 纠正。**禁止**拿它判定「服务端卡死」，也**禁止**
///    用它触发通知（通知范围见 AGENTS.md §6.99）。
///
/// ## 为什么不进对话时间线
///
/// 与 [TurnActivitySnapshot] 同族：它是进度提示，不是对话正文。故不进
/// `EventTypes.timelineVisible`、不进 `EventReducer` 的 items，走侧通道。

/// root 段名（Go `dispatch.Begin` 的 `Options.Name`）。
///
/// root 帧承载整次分发的**开始**与**收尾汇总**（`elapsed_ms` /
/// `unattributed_ms` / `critical` / `dropped`），与普通子段帧共用同一事件类型，
/// 靠 `name` 区分。**root 帧不得覆盖当前子段**（它是信封，不是一步）。
const String dispatchRootStageName = 'dispatch';

/// 段阶段（`payload.phase`）。
///
/// 服务端用同一事件类型发「开始」与「结束」两条帧（super_partyb#181），
/// 只有 start 才回答客户端唯一的问题：「**现在**在做什么」。
enum DispatchPhase {
  start('start'),
  end('end'),

  /// 缺失或服务端新增了本客户端不认识的 phase。
  ///
  /// 归到这里而不是「猜」：猜错会把未开始的段当成已结束（或反之），
  /// 比少显示一条进度糟得多。消费方见 [unknown] 一律丢弃该帧。
  unknown('');

  const DispatchPhase(this.wire);

  /// 服务端原始值。
  final String wire;

  /// 服务端值 → 枚举（未知值归 [unknown]，**不抛异常**）。
  static DispatchPhase fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return unknown;
    for (final p in values) {
      if (p.wire == wire) return p;
    }
    return unknown;
  }
}

/// 段终态（`payload.status`），真源 Go `dispatch.Status` 闭集。
enum DispatchStageStatus {
  ok('ok'),

  /// 没跑：预算不足 / 开关关闭 / 前置条件不满足。
  ///
  /// ⚠️ 渲染必须显示「已跳过」而**不是 0ms**——「没跑」与「瞬间跑完」是两件事
  /// （Go 侧 `StatusSkip` 的注释就是为此写的）。
  skip('skip'),
  deadline('deadline'),
  error('error'),

  /// 缺失或未知值（fail-open，原样丢弃语义，不抛）。
  unknown('');

  const DispatchStageStatus(this.wire);

  final String wire;

  static DispatchStageStatus fromWire(String? wire) {
    if (wire == null || wire.isEmpty) return unknown;
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return unknown;
  }
}

/// 一条归一化后的分发帧（`start` / `end` / root 汇总三种形态合一）。
///
/// 只做「payload → 值对象」的映射，**不做配对与合并**（那是
/// [DispatchStageTracker] 的职责）。
class DispatchStageFrame {
  const DispatchStageFrame({
    required this.requestId,
    required this.name,
    required this.phase,
    required this.startMs,
    required this.at,
    this.endMs,
    this.budgetMs,
    this.status = DispatchStageStatus.unknown,
    this.reason,
    this.elapsedMs,
    this.unattributedMs,
    this.criticalStage,
    this.dropped,
  });

  /// 客户端幂等键（= `ChatStreamController.send` 生成的 rid）。
  final String requestId;

  /// 段名（含父子路径 `parent/child`）。
  final String name;

  final DispatchPhase phase;

  /// 相对本次分发起点的偏移（毫秒）。**只用于排序**，不用于「已等待多久」。
  final int startMs;

  /// 结束偏移；`phase=start` 时为 null。
  final int? endMs;

  /// 本段生效预算（毫秒），可直接用于「已用 / 预算」。
  final int? budgetMs;

  final DispatchStageStatus status;

  /// 终态原因（`skip` 的 `cache_hit` / `budget_low` 等）。
  final String? reason;

  /// root 收尾汇总：总耗时（毫秒）。
  final int? elapsedMs;

  /// root 收尾汇总：**未归因时长**（父墙钟 − 直属子段并集）。
  ///
  /// >0 表示「有等待没被任何段记账」——正是「用户等了 3 秒却看不出在干什么」
  /// 的可量化证据。实测生产值 3147ms / 1047ms。
  final int? unattributedMs;

  /// root 收尾汇总：关键路径段名（结束得最晚的直属子段）。
  final String? criticalStage;

  /// root 收尾汇总：被丢弃的子段条数（超出 `MaxRecords`）。
  final int? dropped;

  /// 事件到达时间（本地时钟），供 UI 算「已等待」的起点。
  final DateTime at;

  /// 是否为 root 帧（整次分发的信封，不是一步）。
  bool get isRoot => name == dispatchRootStageName;

  /// 从事件构造；不可用时返回 null（**不抛**：一条畸形帧不该断掉整条流）。
  ///
  /// 丢弃条件（都是「无法归因 / 无法判定」）：
  /// - 非 `dispatch_stage` 类型；
  /// - 缺 `request_id` 或 `name`（无键无法配对，挂到空键上只会污染别的请求）；
  /// - phase 未知（见 [DispatchPhase.unknown] 的理由）。
  static DispatchStageFrame? fromEvent(ChatEvent ev) {
    if (ev.eventType != EventTypes.dispatchStage) return null;
    final requestId = ev.dispatchRequestId;
    final name = ev.dispatchStageName;
    if (requestId == null || requestId.isEmpty) return null;
    if (name == null || name.isEmpty) return null;
    final phase = DispatchPhase.fromWire(ev.dispatchPhase);
    if (phase == DispatchPhase.unknown) return null;
    return DispatchStageFrame(
      requestId: requestId,
      name: name,
      phase: phase,
      // 缺 start_ms 退化为 0：它是排序键而非时长，缺失时按「最先开始」处理，
      // 不影响配对（配对靠 name + phase，不靠时间戳）。
      startMs: ev.dispatchStartMs ?? 0,
      endMs: ev.dispatchEndMs,
      budgetMs: ev.dispatchBudgetMs,
      status: DispatchStageStatus.fromWire(ev.dispatchStatus),
      reason: ev.dispatchReason,
      elapsedMs: ev.dispatchElapsedMs,
      unattributedMs: ev.dispatchUnattributedMs,
      criticalStage: ev.dispatchCriticalStage,
      dropped: ev.dispatchDropped,
      at: ev.createdAt,
    );
  }

  @override
  String toString() =>
      'DispatchStageFrame(${phase.wire} $name, rid=$requestId, '
      '$startMs→${endMs ?? '?'}ms, ${status.wire}'
      '${reason != null ? ':$reason' : ''})';
}

/// 一条**已结束**的段（配对后的结果）。
class DispatchStageSpan {
  const DispatchStageSpan({
    required this.name,
    required this.startMs,
    required this.endMs,
    required this.status,
    this.reason,
    this.budgetMs,
    this.orphan = false,
  });

  final String name;

  /// 相对分发起点的起止偏移（毫秒）。
  final int startMs;
  final int endMs;

  final DispatchStageStatus status;

  /// `skip` / `deadline` / `error` 的具体原因。
  final String? reason;

  final int? budgetMs;

  /// 该 span 没有对应的 `start` 帧（`start` 帧丢失、或段在订阅前就开始了）。
  ///
  /// 仍然记录：`end` 帧本身带 `start_ms`，信息不缺失；但 UI 不应据此推断
  /// 「用户看得见这一段的过程」。
  final bool orphan;

  /// 本段墙钟时长（毫秒）。
  int get elapsedMs => endMs - startMs;

  /// 中文展示文案（见 [DispatchStageLabels]）。
  String get label => DispatchStageLabels.labelFor(name);

  @override
  String toString() =>
      'DispatchStageSpan($name, ${elapsedMs}ms, ${status.wire}'
      '${reason != null ? ':$reason' : ''}${orphan ? ', orphan' : ''})';
}

/// 一次分发的进度快照（**不可变**，按 `request_id` 归并后的结果）。
class DispatchStageProgress {
  const DispatchStageProgress({
    required this.requestId,
    required this.startedAt,
    required this.updatedAt,
    required this.completed,
    this.currentStage,
    this.currentStartMs,
    this.currentBudgetMs,
    this.rootStarted = false,
    this.rootFinished = false,
    this.rootBudgetMs,
    this.rootElapsedMs,
    this.rootUnattributedMs,
    this.rootCriticalStage,
    this.rootDropped,
  });

  /// 归因键（= 客户端 `send()` 的 rid）。
  final String requestId;

  /// 首帧到达时间（本地时钟）。UI 的「已等待」从它算起。
  ///
  /// ⚠️ 它是**下界**：root `start` 帧通常紧跟请求发出，但网络延迟与
  /// 服务端校验（`chatpipeline` 的 `user_id` 校验在 `Begin` 之前）不计入。
  final DateTime startedAt;

  /// 最近一帧的到达时间（本地时钟）。
  final DateTime updatedAt;

  /// **当前正在做的段名**（最后一条 `start` 且未 `end` 的段）。
  ///
  /// null 表示此刻没有进行中的段：可能全部结束，也可能是「两段之间的缝隙」
  /// （服务端没有为那段等待记账，见 [rootUnattributedMs]）。
  final String? currentStage;

  /// 当前段的开始偏移与生效预算（毫秒）。
  final int? currentStartMs;
  final int? currentBudgetMs;

  /// 已结束的段（按 `startMs` 升序，同名可重复）。
  final List<DispatchStageSpan> completed;

  /// root 是否已开始 / 已收尾。
  final bool rootStarted;
  final bool rootFinished;

  /// root 的生效预算（毫秒，仅 root `start` 帧携带）。
  final int? rootBudgetMs;

  /// root 收尾汇总（仅 [rootFinished] 时有值）。
  final int? rootElapsedMs;
  final int? rootUnattributedMs;
  final String? rootCriticalStage;
  final int? rootDropped;

  /// 已结束段数。
  int get completedCount => completed.length;

  /// 是否有可展示的进度（既无进行中段、也无已完成段时 UI 不该出条）。
  bool get hasProgress => currentStage != null || completed.isNotEmpty;

  /// 当前段的中文文案（无进行中段时为 null）。
  ///
  /// **未知段名必须兜底**（[DispatchStageLabels.fallback]）：服务端新增段
  /// 不能让进度条显示空字符串。
  String? get currentLabel {
    final name = currentStage;
    return name == null ? null : DispatchStageLabels.labelFor(name);
  }

  /// 未归因时长的可读提示；没有（或为 0）时返回 null。
  ///
  /// 「已等待 3.7s，其中 3.1s 未归类」是 issue #86 那个盲窗唯一可展示的形态
  /// ——客户端无法进一步细分它（服务端压根没记账）。
  String? get unattributedNotice {
    final ms = rootUnattributedMs;
    if (ms == null || ms <= 0) return null;
    if (ms < 1000) return null;
    final secs = (ms / 1000).toStringAsFixed(1);
    return '其中 $secs 秒未归类';
  }

  @override
  String toString() =>
      'DispatchStageProgress(rid=$requestId, current=$currentStage, '
      'done=${completed.length}, root=${rootFinished
          ? "end"
          : rootStarted
          ? "start"
          : "-"}'
      '${rootElapsedMs != null ? ', ${rootElapsedMs}ms' : ''})';
}

/// 一次分发的**可变累积器**（按 `request_id` 归并一串帧）。
///
/// 为什么需要它：`start` / `end` 是两条独立帧，客户端必须自己配对才能回答
/// 「现在在做什么」（服务端只在**段结束时**发帧的时代，这个问题无法回答）。
///
/// 纯 Dart、无 I/O、无 Flutter —— 配对规则（重试同名段、迟到 `end`、root 信封不
/// 覆盖当前段）全部可在无引擎的 CI 里单测。
///
/// ## 生命周期
///
/// 归因与启停由调用方负责（见 `ChatStreamController`）：
/// - 只对**本端在飞**的 `request_id` 调 [apply]（其余直接丢，别进累积器）；
/// - 该请求的 turn 首个事件到达、或收到 root 收尾帧后调 [forget]；
/// - 断线 / 切 group 时整体丢弃（Transient 不回放，没有恢复语义）。
class DispatchStageTracker {
  DispatchStageTracker({this.maxSessions = 16});

  /// 同时保留的请求数上限。
  ///
  /// 存在的理由：`forget` 依赖调用方记得收尾（root 收尾帧丢失时不会发生）。
  /// 无界增长在「App 常驻 + 偶发长尾」下会变成内存泄漏，故退化为**淘汰最久未
  /// 更新的会话**——被淘汰的请求本来也不再有实时进度可展示。
  final int maxSessions;

  final Map<String, _Session> _sessions = {};

  /// 应用一条帧。返回是否有状态变化（调用方据此决定要不要推送/重建 UI）。
  ///
  /// 丢弃的帧（无用例）：`request_id` 缺失、`name` 缺失、phase 未知——
  /// 判定发生在 [DispatchStageFrame.fromEvent]，到这里的都是可用帧。
  bool apply(DispatchStageFrame frame) {
    final session = _sessionFor(frame.requestId, at: frame.at);
    session.updatedAt = frame.at;
    if (frame.isRoot) {
      return _applyRoot(session, frame);
    }
    switch (frame.phase) {
      case DispatchPhase.start:
        return session.openStart(frame);
      case DispatchPhase.end:
        return session.closeEnd(frame);
      case DispatchPhase.unknown:
        return false;
    }
  }

  /// [apply] 的事件版（`dispatch_stage` → 帧 → 累积）。
  bool applyEvent(ChatEvent ev) {
    final frame = DispatchStageFrame.fromEvent(ev);
    if (frame == null) return false;
    return apply(frame);
  }

  /// 当前快照；没有该请求时返回 null。
  DispatchStageProgress? progressFor(String requestId) =>
      _sessions[requestId]?.snapshot();

  /// 已保留的请求 id（调试/测试用）。
  Iterable<String> get requestIds => _sessions.keys;

  /// 丢弃该请求的全部状态（请求结束、断线、群忙转 deferred 时调用）。
  void forget(String requestId) {
    _sessions.remove(requestId);
  }

  /// 全部丢弃（切 group / 断线 / 登出）。
  void clear() => _sessions.clear();

  _Session _sessionFor(String requestId, {required DateTime at}) {
    final existing = _sessions[requestId];
    if (existing != null) return existing;
    if (_sessions.length >= maxSessions) {
      // 淘汰最久未更新的会话（`reduce` 而非排序：会话数 ≤ maxSessions，
      // 为此分配一个 List 不划算）。
      _Session? oldest;
      for (final s in _sessions.values) {
        if (oldest == null || s.updatedAt.isBefore(oldest.updatedAt)) {
          oldest = s;
        }
      }
      if (oldest != null) _sessions.remove(oldest.requestId);
    }
    final session = _Session(requestId: requestId, startedAt: at);
    _sessions[requestId] = session;
    return session;
  }

  /// root 帧（信封）：只更新汇总字段，**绝不动当前子段**。
  ///
  /// 因为 root 的 `name` 也会被普通的 start/end 逻辑认领：若不做区分，
  /// root `start` 会把 `currentStage` 顶成 `dispatch`（UI 永远显示「正在分发」，
  /// 而不是真正在跑的那一步），root `end` 又会把当前段清空（进度条提前收起）。
  bool _applyRoot(_Session session, DispatchStageFrame frame) {
    if (frame.phase == DispatchPhase.start) {
      session.rootStarted = true;
      session.rootBudgetMs = frame.budgetMs;
      return true;
    }
    session.rootStarted = true;
    session.rootFinished = true;
    session.rootElapsedMs = frame.elapsedMs;
    session.rootUnattributedMs = frame.unattributedMs;
    session.rootCriticalStage = frame.criticalStage;
    session.rootDropped = frame.dropped;
    return true;
  }
}

/// 单个请求的累积状态（可变、私有）。
class _Session {
  _Session({required this.requestId, required this.startedAt})
    : updatedAt = startedAt;

  final String requestId;
  final DateTime startedAt;
  DateTime updatedAt;

  /// 未结束的 `start`：name → 起点。
  ///
  /// 用 Map 而非 List：同名重试时必须**覆盖**旧起点（旧的已被放弃，服务端不会
  /// 再给它发 `end`；留着它会让「当前段」永远指向一条不会收尾的记录）。
  final Map<String, _OpenSpan> _open = {};

  final List<DispatchStageSpan> _completed = [];

  /// 到达序号：`startMs` 相同时用它定先后（并发段的偏移可以完全相同）。
  int _seq = 0;

  bool rootStarted = false;
  bool rootFinished = false;
  int? rootBudgetMs;
  int? rootElapsedMs;
  int? rootUnattributedMs;
  String? rootCriticalStage;
  int? rootDropped;

  bool openStart(DispatchStageFrame frame) {
    _open[frame.name] = _OpenSpan(
      name: frame.name,
      startMs: frame.startMs,
      budgetMs: frame.budgetMs,
      seq: _seq++,
    );
    return true;
  }

  bool closeEnd(DispatchStageFrame frame) {
    final open = _open.remove(frame.name);
    if (open == null) {
      // 迟到 / 丢了 start 的 end：仍记录（`end` 帧自带 `start_ms`，信息不缺），
      // 但不改「当前段」——那一段的可见过程本来就没到达过本端。
      _completed.add(
        DispatchStageSpan(
          name: frame.name,
          startMs: frame.startMs,
          endMs: frame.endMs ?? frame.startMs,
          status: frame.status,
          reason: frame.reason,
          budgetMs: frame.budgetMs,
          orphan: true,
        ),
      );
      _sortCompleted();
      return true;
    }
    _completed.add(
      DispatchStageSpan(
        name: frame.name,
        startMs: open.startMs,
        endMs: frame.endMs ?? frame.startMs,
        status: frame.status,
        reason: frame.reason,
        budgetMs: open.budgetMs ?? frame.budgetMs,
      ),
    );
    _sortCompleted();
    return true;
  }

  void _sortCompleted() {
    // 按「起点 → 结束」排序：并发段的 `end` 顺序与 `start` 顺序可以不同，
    // 展示要按实际开始时间排（否则进度条会跳）。同名段的 start 可能相同
    // （重试几乎同时），用 end 作为次级键保证顺序确定（`List.sort` 不保证稳定）。
    _completed.sort((a, b) {
      final byStart = a.startMs.compareTo(b.startMs);
      if (byStart != 0) return byStart;
      return a.endMs.compareTo(b.endMs);
    });
  }

  /// 当前段 = 未结束的 `start` 中**最后开始**的那条（同偏移取后到达的）。
  _OpenSpan? get _current {
    _OpenSpan? best;
    for (final open in _open.values) {
      if (best == null ||
          open.startMs > best.startMs ||
          (open.startMs == best.startMs && open.seq > best.seq)) {
        best = open;
      }
    }
    return best;
  }

  DispatchStageProgress snapshot() {
    final current = _current;
    return DispatchStageProgress(
      requestId: requestId,
      startedAt: startedAt,
      updatedAt: updatedAt,
      currentStage: current?.name,
      currentStartMs: current?.startMs,
      currentBudgetMs: current?.budgetMs,
      completed: List<DispatchStageSpan>.unmodifiable(_completed),
      rootStarted: rootStarted,
      rootFinished: rootFinished,
      rootBudgetMs: rootBudgetMs,
      rootElapsedMs: rootElapsedMs,
      rootUnattributedMs: rootUnattributedMs,
      rootCriticalStage: rootCriticalStage,
      rootDropped: rootDropped,
    );
  }
}

/// 未结束的 `start`（私有）。
class _OpenSpan {
  const _OpenSpan({
    required this.name,
    required this.startMs,
    required this.budgetMs,
    required this.seq,
  });

  final String name;
  final int startMs;
  final int? budgetMs;
  final int seq;
}

/// 段名 → 中文文案（闭集映射 + 兜底）。
///
/// ## 为什么放在领域层而不是 UI 层
///
/// 两端（desktop / mobile）都渲染同一条进度条，文案写两处必然漂移；而同类的
/// 先例就在本包（[GroupUpdateOp.label] 也带中文标签）。这里只做**字符串映射**，
/// 不碰任何 `package:flutter/*`，不违反 §4 的分层约束。
///
/// ## 闭集真源与兜底
///
/// 段名真源 Go `chatpipeline/pipeline_stages.go`（另含 `chatrouter` /
/// `embeddingresolver` 的段名常量）。**未登记的名字一律显示
/// [fallback]**——服务端新增段时宁可文案笼统，也不能空转或抛异常。
class DispatchStageLabels {
  const DispatchStageLabels._();

  /// 「服务端新增了段，本客户端还没跟上」时的文案。
  static const String fallback = '正在处理';

  /// 精确匹配（含 root）。
  static const Map<String, String> _exact = {
    dispatchRootStageName: '正在分发',
    'classify.prepare': '正在检索候选对话',
    'classify.gate': '正在校验归属置信度',
    'classify.llm': '正在判断消息归属',
    'feedback.judge': '正在判定归属反馈',
    'enqueue': '正在入队',
    'reminder.prepare': '正在准备提醒',
    'router.query_encode': '正在匹配 Agent',
    'embedding.encode': '正在向量编码',
  };

  /// 前缀匹配：`reminder.prepare/<n>` 是**每条提醒一个段**（名字不可穷举），
  /// 故按前缀归到同一句文案。
  static const Map<String, String> _prefixes = {'reminder.prepare/': '正在准备提醒'};

  /// 段名 → 文案。
  ///
  /// 查找顺序：全名 → 前缀规则 → **叶子名**（父子路径 `parent/child` 的
  /// child，例如 `router.query_encode/embedding.encode` 显示成「正在向量编码」，
  /// 比显示「正在匹配 Agent」更贴近此刻真正在等的事）→ [fallback]。
  static String labelFor(String? name) {
    if (name == null || name.isEmpty) return fallback;
    final exact = _exact[name];
    if (exact != null) return exact;
    for (final entry in _prefixes.entries) {
      if (name.startsWith(entry.key)) return entry.value;
    }
    final slash = name.lastIndexOf('/');
    if (slash >= 0) {
      final leaf = name.substring(slash + 1);
      final leafLabel = _exact[leaf];
      if (leafLabel != null) return leafLabel;
    }
    return fallback;
  }

  /// 已登记的全部段名（测试与文档用；父子路径的 `<n>` 子段不在此列）。
  static Iterable<String> get knownStages => _exact.keys;
}
