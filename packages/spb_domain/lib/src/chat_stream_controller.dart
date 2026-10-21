import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'event_reducer.dart';
import 'execution_status.dart';
import 'gate_decision.dart';
import 'goal_update.dart';
import 'outbox.dart';
import 'timeline_cache.dart';
import 'tts_status.dart';
import 'turn_activity.dart';

/// 对话流控制器：把 SSE 帧流 + timeline 回填统一成一条对话项流。
///
/// ## 职责
///
/// 1. **订阅 SSE**，把帧解析成 [ChatEvent] 并归约成对话项；
/// 2. **首屏回填**：连接前先用 timeline API 拉历史，避免只看到新消息；
/// 3. **断线续接**：重连时带 cursor，并把回放窗口外的情况转成 timeline 整段回填；
/// 4. **多 group 隔离**：只处理当前 group 的事件（SSE 是 user 级，会收到所有 group）。
///
/// ## 纯 Dart
///
/// 不依赖 Flutter，可直接在 `dart test` 里用假 SseClient 测试。
class ChatStreamController {
  ChatStreamController({
    required SseClient sse,
    required ChatApi api,
    required this.userId,
    Duration? turnTimeoutOverride,
    TimelineCacheStore? timelineCache,
    OutboxQueue? outbox,
  }) : assert(
         userId != '',
         // WHY 断言而非静默容忍：空 userId 会拼出 `/users//chat/stream` 这种
         // 畸形路径——请求会发出去、服务端返回 404/空订阅，而客户端看不出
         // 异常（issue #2）。这类错误必须在 debug 下立刻炸掉，而不是变成一个
         // 「能跑但收不到任何事件」的静默故障。
         'userId 不得为空：SSE 路径为 /users/:user_id/chat/stream，'
         '空值会拼出 /users//chat/stream（见 issue #2）',
       ),
       _sse = sse,
       _api = api,
       _timelineCache = timelineCache,
       _outbox = outbox,
       _turnTimeoutOverride = turnTimeoutOverride,
       _turnTimeout = turnTimeoutOverride;

  final SseClient _sse;
  final ChatApi _api;
  final String userId;

  /// timeline 只读缓存（issue #26 切片 B / issue #29）。
  ///
  /// ## 为什么可选（与页面侧 `cache` 参数同一取向）
  ///
  /// 为 null 时不读也不写缓存——保持「纯网络」的用法，也让领域层单测不必造库。
  ///
  /// ## 两条不变式（都不是可选的）
  ///
  /// 1. **只在 `_backfill` / `loadOlder` 成功后写**（`docs/offline-cache-design.md`
  ///    §4.3）：SSE 热路径**绝不**写——写放大，且流式增量本就不该缓存；
  /// 2. **只在网络完全不可用时读**（§4bis.3）：网络可用时缓存只被写入不被读取。
  ///    否则缓存的上界与 timeline 的下界之间若有一段缺口（断网期间服务端新增
  ///    了事件），拼出来的历史会让用户以为是连续的。
  final TimelineCacheStore? _timelineCache;

  /// 离线写队列（issue #26 切片 C / issue #30）。
  ///
  /// ## 方向是单向的
  ///
  /// 控制器**依赖**队列（[send] 遇可重试错误时入队）；队列**不**依赖控制器
  /// ——投递成功只推自己的 `delivered` 流，本控制器订阅它。故无循环依赖。
  ///
  /// 为 null 时不排队：可重试错误照旧上抛（修复前的行为），页面单测不必造库。
  final OutboxQueue? _outbox;

  StreamSubscription<OutboxDelivered>? _outboxDeliveredSub;
  StreamSubscription<OutboxFailure>? _outboxFailureSub;

  /// 当前聚焦的 group。null 表示接收全部 group 的事件。
  String? _groupId;

  final _itemsController = StreamController<List<ConversationItem>>.broadcast();
  final _gateDecisionsController =
      StreamController<List<GateDecision>>.broadcast();
  final _activitiesController =
      StreamController<Map<String, TurnActivitySnapshot>>.broadcast();
  final _contextUsageController = StreamController<ContextUsage?>.broadcast();
  final _executionStatusController =
      StreamController<ExecutionStatus?>.broadcast();
  final _ttsStatusController = StreamController<TtsStatus?>.broadcast();
  final _groupUpdatesController = StreamController<GroupUpdate>.broadcast();

  /// 目标变更通知流（`goal_updated`）。
  ///
  /// 与 [_groupUpdatesController] 分开而非复用：两者载荷类型不同
  /// （[GroupUpdate] 是最小身份快照，[GoalUpdate] 是完整目标快照），且消费方
  /// 也不同（列表页 vs 对话页/设置面板）。
  final _goalUpdatesController = StreamController<GoalUpdate>.broadcast();
  final _errorController = StreamController<SpbError>.broadcast();
  final _stateController = StreamController<SseState>.broadcast();

  /// 事件缓冲区上限（条）。
  ///
  /// ## 为什么必须有上限
  ///
  /// [_buffer] 只增不减：[start] / [_backfill] 灌首屏、[loadOlder] 每次往头部
  /// 前插一页、[_onFrame] 每条 SSE 事件追加，且**从不裁剪**。而 [_emit] 每次都
  /// `EventReducer.reduce(_buffer)` 全量重算——于是长会话下这是 O(n²)：翻 20 页
  /// 历史（约 1200 条）后，每来一条新事件都要重新归约上千条并重建整个对话项
  /// 列表，内存同样无界增长。
  ///
  /// ## 为什么取 2000
  ///
  /// 首屏 [_backfill] 拉 200 条、[loadOlder] 每次 50 条，2000 条相当于「连续往上
  /// 翻 36 页」——远超实际使用深度；同时把单次归约的输入规模固定在 2000 条以内。
  static const int maxBufferEvents = 2000;

  final List<ChatEvent> _buffer = [];

  /// 「曾经加载到过的最早落库事件」的 globalSeq（跨裁剪保持，不因丢头部而抬高）。
  ///
  /// ## 为什么不能用「当前缓冲区的最小 globalSeq」当翻页游标
  ///
  /// 裁剪从头部丢弃最旧事件，会把缓冲区的最小 globalSeq 抬高。若游标跟着抬高，
  /// 那些刚被裁掉的事件会被再次判为「更早的一页」重新拉回来，拉回来又立刻被
  /// 裁掉——形成「滚到顶 → 拉回 → 再裁掉」的抖动，而真正的更早历史永远拉不到。
  ///
  /// 故本字段记录「历史边界」：只在 [_backfill]（重置为首页最小值）与
  /// [loadOlder]（前插一页后下调）更新，裁剪**不影响**它。
  ///
  /// 重置时机：`start` / `switchGroup`——换了 group，历史边界无意义。
  int? _oldestLoadedGlobalSeq;

  StreamSubscription<SseFrame>? _frameSub;
  StreamSubscription<SseState>? _stateSub;
  bool _disposed = false;

  /// 时间线是否来自本地缓存（见 [timelineFromCache]）。
  bool _fromCache = false;

  final _fromCacheController = StreamController<bool>.broadcast();

  /// 正在执行 [loadOlder]（防止并发翻页把同一页插两次）。
  bool _loadingOlder = false;

  /// 归约后的对话项流（每次事件到达推送全量列表）。
  //
  // WHY 推全量而非增量：对话列表通常几百项，全量重建成本远低于维护增量合并
  // 的复杂度；且 Flutter 列表 diff 依赖稳定 id，全量重建 + key 复用效率足够。
  // 若将来列表规模显著增长，再改为增量 patch。
  Stream<List<ConversationItem>> get items => _itemsController.stream;

  /// Gate 决策流（与 [items] 平行，由同一次归约产出）。
  //
  // ## 为什么单独一条流而不是塞进 [items]
  //
  // Gate 决策是控制流诊断信息，不进时间线（见 [GateDecision] 类文档）。
  // 若放进 [items]，所有现有消费者（时间线渲染、侧边栏待办面板）都要
  // 自己过滤它，漏一处就是噪声。单独一条流让诊断面板只订阅自己关心的数据。
  Stream<List<GateDecision>> get gateDecisions =>
      _gateDecisionsController.stream;

  /// 执行中活动快照流（与 [items] 平行，由同一次归约产出）。
  ///
  /// 供对话页在「已起跑但还没有正文」的空窗期展示进度（见
  /// [TurnActivitySnapshot] 的类文档）。推送的是**全量 Map**（按 turnId 索引），
  /// 与 [items] 的全量重建取向一致：消费方按 turnId 直查，无需自己合并。
  Stream<Map<String, TurnActivitySnapshot>> get activities =>
      _activitiesController.stream;

  /// 上下文用量流（与 [items] 平行，由同一次归约产出）。
  ///
  /// 推送**单个快照**（对话级状态，非 per-turn），供对话页在诊断区展示
  /// 「已用 / 窗口」与（若服务端提供）费用。推送 null 表示当前无可用数据
  /// ——消费方应隐藏该区域。
  ///
  /// 与 [activities] 同为「注入才订阅」：对话页不持有控制器时无需订阅。
  Stream<ContextUsage?> get contextUsage => _contextUsageController.stream;

  /// 执行等待/重试状态流（与 [items] 平行，由同一次归约产出）。
  ///
  /// 推送单个快照或 null（null = 当前无等待）。供对话页展示「尚未回复的原因」。
  /// 与 [contextUsage] 同为「注入才订阅」。
  Stream<ExecutionStatus?> get executionStatus =>
      _executionStatusController.stream;

  /// 语音播报状态流（与 [items] 平行，由同一次归约产出）。
  ///
  /// 推送单个快照或 null（null = 本群未开语音 / 尚无播报事件）。
  /// 与 [executionStatus] 同为「注入才订阅」。
  Stream<TtsStatus?> get ttsStatus => _ttsStatusController.stream;

  /// group 变更通知流（逐条推送，**不累积**）。
  ///
  /// ## 为什么与 [items] / [gateDecisions] 不同（增量而非全量）
  ///
  /// 前者是「当前状态快照」，后者是「发生了什么事」。group 变更按顺序处理
  /// （created 后 deleted 与反过来结果不同），累积成列表反而要求消费方自己
  /// 排序；逐条推送保留真实发生顺序，消费方按 op 增量更新或整体重拉。
  ///
  /// ## 为什么不受 [switchGroup] 的 group 过滤影响（全局模式）
  ///
  /// SSE 是 user 级订阅，group 变更与「当前打开哪个对话」无关：A 端建组时
  /// B 端侧栏要实时出现，而列表页在全局模式下运行。故 [_onFrame] 对
  /// `group_updated` 的 group 过滤有**例外**（见那里的注释）。
  Stream<GroupUpdate> get groupUpdates => _groupUpdatesController.stream;

  /// 目标变更通知流（`goal_updated`，逐条通知）。
  ///
  /// ## 为什么它也绕开 group 过滤
  ///
  /// 与 [groupUpdates] 同因：事件的 `groupId` 指向「被变更的那个 group」。
  /// 但本事件的消费方（设置面板）只在聚焦模式跑，故实际上过滤不会咬到它；
  /// 仍与 group 变更同路径处理是为了保持「通知类事件不受聚焦约束」这条
  /// 不变式一致。
  ///
  /// ## ⚠️ 本通道是游标安全的**唯一**保障
  ///
  /// 服务端 `emitGoalUpdated` 漏设 `Transient: true`（注释写着「不落库」但字段
  /// 留了零值 false，见 [GoalUpdate] 类文档），所以线上事件是
  /// `transient=false` + 有效 eventId，而它**不在** `chat_events` 表里。
  ///
  /// 若它落到通用路径，`_onFrame` 尾部的 `if (!event.transient && ...)` 会把它
  /// 记作 SSE 游标；服务端 `replayUserEvents` 按 `chat_events.id` 定位 cursor，
  /// 找不到该 ID → `start < 0` → 返回 nil → **整个断线回放窗口丢失**。
  ///
  /// 故 [_onFrame] 对它**提前分流并 return**，绝不落到 `recordEventId`。
  Stream<GoalUpdate> get goalUpdates => _goalUpdatesController.stream;

  Stream<SpbError> get errors => _errorController.stream;

  /// 当前时间线是否来自**本地缓存**（而非服务端）。
  ///
  /// ## 为什么需要这条信号（切片 B / issue #29）
  ///
  /// 回填失败时用缓存渲染，若不给任何提示，用户看到的是**一份陈旧且不再更新
  /// 的历史**——他会以为「对方没再说话」，而不是「我掉线了」。切片 A 的
  /// `GroupListPage._CacheNotice` 解决同一问题（那里的注释解释了为何用内联条
  /// 而非一次性通知），本信号是它在对话页的对应物。
  ///
  /// 置 true 的唯一位置是 [_fallbackToCache]；下一次**网络成功**的回填
  /// （[_backfill] 或 [loadOlder]）无条件置 false——否则提示条永久残留
  /// （与 `GroupListPage._fromCache` 同一不变式）。
  Stream<bool> get timelineFromCache => _fromCacheController.stream;

  /// 当前值快照（供 UI 首次渲染）。
  bool get timelineFromCacheSnapshot => _fromCache;

  Stream<SseState> get connectionState => _stateController.stream;

  SseState get currentState => _sse.state;

  /// 当前对话项快照（供 UI 首次渲染，避免等待下一次推送）。
  List<ConversationItem> get snapshot => _reduction.items;

  /// 当前 Gate 决策快照。
  List<GateDecision> get gateDecisionsSnapshot => _reduction.gateDecisions;

  /// 当前执行中活动快照（按 turnId 索引）。
  Map<String, TurnActivitySnapshot> get activitiesSnapshot =>
      _reduction.activities;

  /// 当前上下文用量快照；无数据时为 null。
  ContextUsage? get contextUsageSnapshot => _reduction.contextUsage;

  /// 当前执行等待/重试状态；无等待时为 null。
  ExecutionStatus? get executionStatusSnapshot => _reduction.executionStatus;

  /// 当前语音播报状态；无播报事件时为 [TtsPhase.idle]（非空）。
  TtsStatus get ttsStatusSnapshot => _reduction.ttsStatus;

  /// 缓冲区当前事件数（仅测试用）。
  ///
  /// ## 为什么需要它
  ///
  /// [maxBufferEvents] 的上限作用于 [_buffer]，而 [_buffer] 与 [snapshot]
  /// （归约后的对话项）**不是一一对应**：`queue_state` 等控制事件进缓冲但不产生
  /// 对话项，而 `message` 的多个增量帧会塌缩成一项。断言「裁剪真的发生了」必须
  /// 直接看缓冲长度，不能靠 `snapshot.length` 反推。
  @visibleForTesting
  int get bufferedEventCount => _buffer.length;

  /// 缓冲区当前事件的 eventId（按时间正序，仅测试用）。
  ///
  /// 用于断言裁剪「丢的是最旧的、留的是最新的」，同样无法从 [snapshot] 观测。
  @visibleForTesting
  List<String> get bufferedEventIds =>
      _buffer.map((e) => e.eventId).toList(growable: false);

  /// 归约缓冲区（缓存最近一次 [_emit] 的结果，避免在 `snapshot` /
  /// `gateDecisionsSnapshot` 上各自重算）。
  //
  // [_emit] 在每次缓冲变更后调用，刷新缓存。两个 getter 直接读它，
  // 不再各自调 `EventReducer.reduce`（归约几百条事件不是零成本）。
  ReductionResult? _cachedReduction;

  /// 缓冲已变、[_cachedReduction] 失效（issue #44）。
  ///
  /// [_emit] 现在把归约**推迟到 microtask**（合并一个 chunk 里的多条增量）。
  /// 在那之前若有同步读（如 `_syncStaleWatch` 在 `await` 后恢复、或调用方
  /// 直接读 [snapshot]），不能拿到旧结果——故置脏，让 [_reduction] 现场重算。
  bool _reductionDirty = false;

  ReductionResult get _reduction {
    if (_reductionDirty || _cachedReduction == null) {
      _cachedReduction = EventReducer.reduce(_buffer);
      _reductionDirty = false;
    }
    return _cachedReduction!;
  }

  // ==================== 归约合并（issue #44） ====================
  //
  // ## 它解决什么问题
  //
  // 流式回复是**逐 token 增量**（`message` 事件的 `transient: true`，见
  // AGENTS.md §5.4）。一个长回复产生几百条事件，而 [_emit] 原来**每条**都
  // `EventReducer.reduce(_buffer)` 全量重算（缓冲区上限 2000 条）并重建整个
  // `List<ConversationItem>`。
  //
  // 实测（缓冲区已满 2000、一个回复 300 条增量）：
  //
  // ```
  // 300 条增量 × 全量归约(2000 条): 640 ms   ← 单次归约约 1.8 ms
  // ```
  //
  // 这 640 ms 全部在 UI 线程上，表现为流式期间的滚动卡顿与输入框延迟。
  //
  // ## 为什么合并是有效的
  //
  // `_sse.frames` 是 broadcast stream，投递是**异步**的。但投递粒度很关键：
  // 实测一个同步块里的 N 次 `add` 会变成 **N 个独立的 microtask**（每次只投
  // 一个事件），而不是一个 microtask 投全部。
  //
  // 这直接决定了「用什么调度合并」：
  //
  // | 调度方式 | 5 条同步增量的归约次数（实测） |
  // |---|---|
  // | `scheduleMicrotask` | **5**（没合并） |
  // | `Timer(Duration.zero, ...)` | **1** |
  //
  // 因为 microtask 队列是 FIFO：listener(0) 在 microtask M0 里跑，它排的
  // flush 排在已经入队的 M1 **后面**，于是每投递一个事件就夹一次 flush。
  // `Timer` 是事件循环**任务**（不是 microtask），M0..M4 会先全部排空，
  // 然后计时器只触发一次。
  //
  // ⚠️ 故这里用**事件循环任务**（`Timer(Duration.zero, ...)`）而**不是**
  // `scheduleMicrotask`。本 issue 最初建议的 microtask 方案在本项目的数据流上
  // **不成立**（实测证据见上表）。
  //
  // 延迟代价：只多一个事件循环轮次（实测相对顺序为
  // `microtask → timer → delayed(zero)`），不是 VSync 对齐——VSync 对齐需要
  // `SchedulerBinding`，纯 Dart 层不用。一个轮次远小于一帧。
  //
  // ## 为什么是 `Set<String>` 而不是单个 id
  //
  // 一个 chunk 内可能含**多个 turn** 的事件（如 turn A 的尾部与 turn B 的
  // 开头）。[_syncStaleWatch] 的语义是「只重排**触发者**的到期时刻」
  // （AGENTS.md §5.8 的 per-turn 计时器不变式），故必须保留**全部**触发者；
  // 只留最后一个会让另一个 turn 的计时器被漏掉。
  //
  // null 表示「不是由具体事件触发的同步」（回填 / 乐观回显 / 切换 group），
  // 与空集合区分开。
  Timer? _emitTimer;
  Set<String>? _pendingTouchedTurnIds;

  // ==================== 超时兜底（长时间无进展） ====================
  //
  // ## 它解决什么问题
  //
  // 流式标记（`isStreaming`）只有两条清除路径：`done` 事件与 `start` 事件。
  // 一旦 `done` 丢失（turn worker 崩溃、长断线、回放窗口被打穿），UI 会**永久**
  // 停在流式态：光标不停闪、取消按钮永久可点（点下去得到 409）。
  //
  // 这里维护一条「距最后一条事件」的看门狗，把「长时间无进展」的 turn 集合
  // 推送出去，由 UI 停掉光标并给出提示。
  //
  // ## 为什么不直接改归约结果（强制封段）
  //
  // 详见 [EventReducer.inFlightTurnIds] 的说明：强制封段会制造重复气泡与
  // 虚假的「工具调用无输出」。故归约结果保持权威，stale 只是一个**派生的
  // 提示信号**，消费方不得据此写库、不得据此禁用取消。

  /// 生效的超时阈值；null = 尚未解析出（此时**不武装**计时器）。
  ///
  /// 解析完成前保持 null 而不是先用 [TurnRuntime.fallback]：一旦先武装，
  /// 服务端真实值更大时会多一次「判早了又撤销」的抖动。而判 stale 需要分钟级，
  /// 一次 HTTP 往返的窗口不可观测。
  Duration? _turnTimeout;

  /// 测试注入的阈值；非 null 时跳过 HTTP 拉取。
  final Duration? _turnTimeoutOverride;

  /// 一次性看门狗计时器（**按 turnId 一个**）。
  ///
  /// ## 为什么是「一次性 + 每条事件重排」而不是周期 tick
  ///
  /// 判据是「距最后一次活动」，等价于「每条事件把到期时刻往后推」。一次性
  /// 计时器天然表达这一点，且**不读墙钟**——测试可以用 `fake_async` 直接
  /// `elapse` 到到期时刻，无需注入 Clock（周期 tick 要读 `DateTime.now()`，
  /// 而 `fake_async` 不伪造它）。
  ///
  /// ## 为什么是 per-turn 而不是一个共享计时器
  ///
  /// 共享的话，别的 turn 的活动会把本 turn 的到期时刻也推后——一个已经卡死的
  /// turn 会因「旁边那个还在跑」而永远不被判 stale，兜底等于失效。归约器按
  /// turnId 去重、单连接下多 turn 并存不常见，但 `done` 只到一半时完全可能。
  final Map<String, Timer> _staleTimers = {};

  /// 阈值解析完成的信号（仅测试用）。
  ///
  /// 生产代码不 await 它：解析是异步的，而判 stale 需要分钟级，不存在可观测
  /// 竞态。但测试需要一个同步点——在假时区里跑真实 dio 请求永不 resolve
  /// （见测试文件头说明）。
  Completer<void>? _turnTimeoutResolved;

  /// 被判定为「长时间无进展」的 turn 集合。
  final Set<String> _staleTurnIds = {};

  final _staleTurnIdsController = StreamController<Set<String>>.broadcast();

  /// 「长时间无进展」的 turn 集合流（推送全量副本）。
  ///
  /// ## 语义是提示，不是终态
  ///
  /// turn 可能仍在后台跑。消费方：
  /// - **可以**据此停掉流式光标、让位提示条；
  /// - **不得**据此写库、**不得**据此禁用取消——取消正是用户此时唯一的出路。
  ///
  /// ## 为什么推送全量集合而不是逐条通知
  ///
  /// 与 [activities] / [contextUsage] 同取向：它是「当前状态快照」（哪些 turn
  /// 现在无进展），而状态快照的全量重建比增量合并简单且不会漂移。集合通常
  /// 只有 0 或 1 个元素。
  Stream<Set<String>> get staleTurnIds => _staleTurnIdsController.stream;

  /// 当前 stale 集合快照（供 UI 首帧渲染，避免等下一次推送）。
  Set<String> get staleTurnIdsSnapshot => Set.unmodifiable(_staleTurnIds);

  /// 当前生效的兜底阈值；null = 尚未解析出（仅测试/诊断用）。
  @visibleForTesting
  Duration? get turnTimeout => _turnTimeout;

  /// 归属反馈卡片的有效期；null = 服务端未下发（不做失效判定）。
  ///
  /// ## 为什么由控制器持有
  ///
  /// 它和 [turnTimeout] 来自**同一个** `GET /api/chat/turn-runtime` 响应，而
  /// 那次往返已经在 [_resolveTurnTimeout] 里发生。让页面自己再拉一次会多一次
  /// 请求，且两次响应可能不一致（管理员刚改了 TTL）。
  ///
  /// 页面用它给 [FeedbackRequestItem.isExpired] 传 `ttl`，从而把「已失效」的卡
  /// 直接置灰——而不是等用户点下去才得到 404。
  Duration? get attributionFeedbackTTL => _attributionFeedbackTTL;

  /// 见 [attributionFeedbackTTL]。
  ///
  /// 与 [_turnTimeout] 同寿命：切 group / 重启时**不**清空——它是服务端级配置，
  /// 与具体对话无关，清了只会让卡片暂时变回可点。
  Duration? _attributionFeedbackTTL;

  /// 测试专用：直接注入归属反馈有效期（跳过 HTTP 拉取）。
  @visibleForTesting
  void debugSetAttributionFeedbackTTL(Duration? ttl) {
    _attributionFeedbackTTL = ttl;
  }

  /// 阈值解析完成（仅测试用）。
  @visibleForTesting
  Future<void> get turnTimeoutResolved =>
      _turnTimeoutResolved?.future ?? Future<void>.value();

  /// 重置看门狗（[start] / [switchGroup] 调用：换了 group，旧结论无意义）。
  void _resetStaleWatch() {
    for (final t in _staleTimers.values) {
      t.cancel();
    }
    _staleTimers.clear();
    // 挂起的「本轮触及的 turn」随之失效：切 group / 重启后它们是旧时间线的
    // turn，若让随后的 flush 拿它们去重排计时器，会武装出无对应项的计时器。
    _pendingTouchedTurnIds = null;
    _turnTimeout = _turnTimeoutOverride;
    if (_staleTurnIds.isNotEmpty) {
      _staleTurnIds.clear();
      _pushStaleTurnIds();
    }
    // 测试注入了阈值就无需拉取（也避免测试意外的 HTTP 请求）。
    if (_turnTimeoutOverride != null) {
      _turnTimeoutResolved = Completer<void>()..complete();
      return;
    }
    final resolved = Completer<void>();
    _turnTimeoutResolved = resolved;
    unawaited(_resolveTurnTimeout(resolved));
  }

  /// 拉取服务端生效的兜底阈值。
  ///
  /// 不 await 进 [start]：那会让首屏渲染白等一次往返。
  Future<void> _resolveTurnTimeout(Completer<void> resolved) async {
    try {
      final rt = await _api.turnRuntime();
      // 已 dispose 或已切到别的 group：本次结果属于上一个上下文，丢弃。
      //
      // ⚠️ 不能只判 `_disposed`：切 group 会重新发起一次解析，而旧请求可能
      // 后返回——它会用上一个 group 的阈值覆盖刚重置的状态，并把已清空的
      // stale 集合又填回来。
      if (_disposed || !identical(_turnTimeoutResolved, resolved)) return;
      final next = rt.effectiveClientTurnTimeout;
      // 归属反馈有效期与阈值同批下发，顺手记下（见 [attributionFeedbackTTL]）。
      // 与 next 不同，它**不参与** stale 判定的撤销逻辑，故不触发 _syncStaleWatch。
      _attributionFeedbackTTL = rt.attributionFeedbackTTL;
      // 先前若已用较小值判过 stale，而真实阈值更大，说明判早了——撤销。
      final grew = _turnTimeout != null && next > _turnTimeout!;
      _turnTimeout = next;
      if (grew && _staleTurnIds.isNotEmpty) {
        _staleTurnIds.clear();
        _pushStaleTurnIds();
      }
    } catch (e) {
      if (_disposed || !identical(_turnTimeoutResolved, resolved)) return;
      SpbLog.warn('turn 运行时参数拉取失败，使用兜底阈值', {'error': e.toString()});
      _turnTimeout ??= TurnRuntime.fallback;
    } finally {
      if (!resolved.isCompleted) resolved.complete();
    }
    _syncStaleWatch();
  }

  /// 同步看门狗（每次缓冲变更后调用）。
  ///
  /// ## 续期只针对「本次事件所属的那些 turn」
  ///
  /// [touchedTurnIds] 是本轮被接受的**全部**事件的 turnId 集合（issue #44 起
  /// 归约被合并到一个 microtask，一个 chunk 内可能含多个 turn）。只有它们
  /// 的计时器重排：若任意事件都重排全部 turn，一个已卡死的 turn 会被旁边
  /// 还在跑的 turn（或全局模式下**别的 group** 的事件）无限续期，兜底等于
  /// 失效。
  ///
  /// 为 null 表示「不是由具体事件触发的同步」（如回填、乐观回显）：此时只
  /// 为新出现的进行中 turn 武装，不重置已有的。
  ///
  /// ## 心跳（SSE 注释帧）**不**续期
  ///
  /// [_onFrame] 对 `frame.isComment` 提前 return，故 `: heartbeat` 走不到这里。
  /// 这是**刻意的**：心跳只说明 SSE 连接活着，而 turn worker 崩了心跳照样在
  /// 流。若让它续期，超时兜底在「worker 崩溃但连接正常」这个主要场景下
  /// 永不触发。
  ///
  /// ## 回填场景：流式标记为空时用结构推断兜底（issue #9）
  ///
  /// [EventReducer.inFlightTurnIds] 只看**流式标记**，而流式标记只由 Transient
  /// 增量帧产生。重开对话时回填的全是落库权威帧 → 集合为空 → 一个仍在服务端
  /// 运行的 turn 不会被武装，界面静止而用户毫不知情。
  ///
  /// 故这里把判据扩为两者之并：
  /// - 流式标记（实时路径，B1 原有）；
  /// - [EventReducer.lastTurnMayBeRunning] 的结构推断（回填路径，本轮新增）。
  ///
  /// 两者都**只**产出「可能需要兜底」的 turn id 集合，不改归约结果。
  void _syncStaleWatch({Set<String>? touchedTurnIds}) {
    if (_disposed || _staleTurnIdsController.isClosed) return;

    final reduction = _reduction;
    final inFlight = <String>{...EventReducer.inFlightTurnIds(reduction.items)};
    // 回填路径的兜底判据：流式标记为空时，用「最后一个 turn 有 agent 产物且无
    // 终态」补上。仅当流式标记没给出任何结论时才加，避免与实时路径重复武装
    // （实时路径已经覆盖了「增量帧到达」的情形，且那时 lastTurnMayBeRunning
    // 同样为真，两者取并集不会改变结果，但显式分开让意图可读）。
    final lastRunning = EventReducer.lastRunningTurnId(
      reduction.items,
      terminalTurnIds: reduction.terminalTurnIds,
    );
    if (lastRunning.isNotEmpty) inFlight.add(lastRunning);

    // 已结束的 turn：取消它的计时器（不再续期），并从 stale 集合脱出。
    for (final id in _staleTimers.keys.toList()) {
      if (!inFlight.contains(id)) _staleTimers.remove(id)?.cancel();
    }
    final dropped = _staleTurnIds.difference(inFlight);
    if (dropped.isNotEmpty) {
      _staleTurnIds.removeAll(dropped);
      _pushStaleTurnIds();
    }

    final timeout = _turnTimeout;
    if (timeout == null) return;
    for (final id in inFlight) {
      final isNew = !_staleTimers.containsKey(id);
      // 只重排「本轮被触及」的 turn；touchedTurnIds 为 null 时（回填 /
      // 乐观回显）只武装新出现的，不重置已有的。
      if (touchedTurnIds != null && !touchedTurnIds.contains(id) && !isNew) {
        continue;
      }
      _staleTimers.remove(id)?.cancel();
      _staleTimers[id] = Timer(timeout, () => _markTurnStale(id));
    }
  }

  /// 看门狗到期：把该 turn 标为「长时间无进展」。
  ///
  /// 到期时**确认它仍在进行中**：这中间可能已收到 `done`（那时计时器已被
  /// [_syncStaleWatch] 取消，但取消与回调触发之间存在竞争窗口）。
  void _markTurnStale(String turnId) {
    _staleTimers.remove(turnId);
    if (_disposed || _staleTurnIdsController.isClosed) return;
    if (!_isTurnWatchable(turnId)) {
      return;
    }
    if (_staleTurnIds.contains(turnId)) return;
    _staleTurnIds.add(turnId);
    _pushStaleTurnIds();
  }

  /// 某个 turn 当前是否仍需要看门狗（到期确认与武装共用同一判据）。
  ///
  /// 必须与 [_syncStaleWatch] 的武装条件完全一致，否则会出现「武装了却立刻
  /// 被自己撤销」或「到期了却不认」的不一致。
  bool _isTurnWatchable(String turnId) {
    if (turnId.isEmpty) return false;
    final reduction = _reduction;
    if (EventReducer.inFlightTurnIds(reduction.items).contains(turnId)) {
      return true;
    }
    return EventReducer.lastRunningTurnId(
          reduction.items,
          terminalTurnIds: reduction.terminalTurnIds,
        ) ==
        turnId;
  }

  void _pushStaleTurnIds() {
    if (_staleTurnIdsController.isClosed) return;
    // 推不可变副本：页面 State 会直接持有它，共享可变集合会在下次变更时
    // 静默改写它已持有的快照。
    _staleTurnIdsController.add(Set.unmodifiable(_staleTurnIds));
  }

  /// 开始：回填历史 → 建立 SSE 连接。
  ///
  /// [groupId] 为 null 时进入「全局模式」，接收所有 group 的事件（用于通知中心）。
  Future<void> start({String? groupId}) async {
    _groupId = groupId;
    _buffer.clear();
    _oldestLoadedGlobalSeq = null;
    _resetStaleWatch();

    if (groupId != null) {
      await _backfill(groupId);
    }

    // 回填完立即推送：`_backfill` 只改 `_buffer`，自身不 emit（issue #3）。
    //
    // WHY 放在 `connect` **之前**：先把历史渲染出来，再建连接。
    // 若连接失败（网络不可达 / 认证失败），用户至少能看到已有历史，
    // 而不是一片空白——否则「连不上」与「没有消息」在界面上无法区分。
    _emit();

    _frameSub ??= _sse.frames.listen(_onFrame, onError: _onStreamError);
    _stateSub ??= _sse.states.listen((s) {
      if (!_stateController.isClosed) _stateController.add(s);
      // 网络恢复的**最强信号**：SSE 真的连上了。让离线队列立刻重试
      // （设计文档 §7bis.7）。比轮询准确，也比「有默认路由」更接近
      // 「服务端可达」这个真正关心的条件。
      if (s == SseState.connected) {
        unawaited(_outbox?.onConnectivityRestored() ?? Future<void>.value());
      }
    });

    // 离线队列只在首次 start 时接上（`??=` 的同一取向：重复 start 不应
    // 产生重复订阅）。
    if (_outboxDeliveredSub == null) _bindOutbox();

    await _sse.connect(path: '/users/$userId/chat/stream');
  }

  /// 是否已建立过 SSE 连接（[start] 已调用过）。
  ///
  /// ## 为什么需要它（对话列表与对话页共用一条连接）
  ///
  /// SSE 是 **user 级订阅**：整个进程一个 userId 只有一条连接（见 [switchGroup]）。
  /// 对话列表页也要实时反映 group 变更，故它必须确保连接在——但它**不该**
  /// 抢走对话页的聚焦目标，也不该清掉对话页刚回填好的时间线。
  ///
  /// [ensureConnected] 依赖本标志判断「连接是否已经有人建好了」。
  bool get isConnected => _frameSub != null;

  /// 确保 SSE 连接已建立，**不改变**当前聚焦的 group、不清空缓冲。
  ///
  /// 供「只关心全局通知、不关心某个 group 时间线」的页面（对话列表）使用。
  ///
  /// - 已有连接（无论是对话页建的聚焦模式，还是本方法建的全局模式）：空操作；
  /// - 尚未连接：以全局模式建立（`groupId: null`，不回填时间线）。
  ///
  /// ## 为什么不直接调 [start]
  ///
  /// `start` 会 `_buffer.clear()` 并按 groupId 回填。若对话页正在显示某个对话，
  /// 列表页的一次「确保连接」就会把它的时间线清空重建——表现为列表页一挂载，
  /// 打开的对话内容就闪一下。故这里只在**确实还没有连接**时才动手。
  ///
  /// 注：`group_updated` 在 [_onFrame] 里是**先于 group 过滤**推送的（见那里的
  /// 注释），故即便连接是由对话页以聚焦模式建立的，列表页依然能收到所有
  /// group 的变更——本方法不需要强制切到全局模式。
  Future<void> ensureConnected() async {
    if (_frameSub != null) return;
    await start(groupId: null);
  }

  /// 切换聚焦的 group（如用户点了另一个对话）。
  ///
  /// 复用同一条 SSE 连接——SSE 是 user 级订阅，切 group 无需重连，
  /// 只需清空缓冲并重新回填。
  Future<void> switchGroup(String? groupId) async {
    _groupId = groupId;
    _buffer.clear();
    _oldestLoadedGlobalSeq = null;
    _setFromCache(false);
    _resetStaleWatch();
    if (groupId != null) {
      await _backfill(groupId);
    }
    _emit();
  }

  /// 插入一条本地合成的用户消息（乐观回显）。
  ///
  /// ## 与 send() 共用同一实现
  ///
  /// 事件类型、`transient` 标志、payload 形状三者必须完全一致，否则
  /// 「发送」与「无归属提交」两条路径会出现「一个渲染、一个不渲染」的诡异差异。
  /// 故本方法把构造逻辑集中到一处，[send] 与 [QuickCaptureUseCase] 都走它。
  ///
  /// ## 为什么 transient 必须为 true
  ///
  /// 乐观项是**本地合成**、不落库、无有效 eventId。若让它推进 SSE 游标
  /// （`recordEventId`），重连时会以它为 cursor 请求回放，**跳过**其后的权威帧。
  /// 故 [send] 与 [QuickCaptureUseCase] 都传 `transient: true`。
  ///
  /// ## 为什么需要 turnId
  ///
  /// [EventReducer] 按 turnId 去重：服务端的 `user_message` 事件随后会到
  /// （`enqueue.go` 把它放进 broadcasts，确实经 SSE 推送），两者用同一 turnId
  /// 时归约器会原位合并，不会渲染出两个气泡。**turnId 为空则不去重**——
  /// 那时会短暂出现两个气泡（见 [QuickCaptureUseCase] 的说明，这是刻意取舍）。
  void injectLocalUserMessage({
    required String input,
    required String groupId,
    String? turnId,
    String? agentId,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime.now().toUtc();
    _buffer.add(
      ChatEvent(
        eventId: 'local-${now.microsecondsSinceEpoch}',
        userId: userId,
        groupId: groupId,
        turnId: turnId ?? '',
        eventType: EventTypes.userMessage,
        seq: 0,
        source: 'client',
        createdAt: now,
        // `agent_id` 是本地回显**额外**带的键（服务端 `user_message` 事件没有它）。
        // 归约器读它填进 [UserMessageItem.agentId]，供「重发」带上同一个 agent。
        // 权威帧到达后原位替换，该字段随之丢失——重发仍能工作，因为页面在
        // agentId 为空时退化为「不指定 agent」（由服务端按 active session 决定）。
        payload: {'input': input, if (agentId != null) 'agent_id': agentId},
        // 见方法文档：绝不能推进游标。
        transient: true,
      ),
    );
    // 乐观回显在尾部，裁剪只丢头部，故它不会被丢；这里仍调用以维持
    // 「所有 _buffer 变更点都裁剪」这一不变式。
    _trimBuffer();
    _emit();
  }

  /// 用 timeline API 拉取历史事件。
  ///
  /// ## 失败时回落缓存（issue #29）
  ///
  /// 回填失败（断网 / 5xx）时，用 [TimelineCacheStore] 里的落库事件渲染历史，
  /// 而不是留一片空白。这是切片 B 的**唯一读点**——网络可用时缓存只被写入
  /// 不被读取（`docs/offline-cache-design.md` §4bis.3）。
  ///
  /// ## 为什么回落时**不能**沿用「失败就不 emit」的既有行为
  ///
  /// 原来失败只记 warn + 推 errors 流，`_buffer` 保持空。对话页在「没有 items」
  /// 时渲染 [EmptyState]，于是断网点进对话看到的是「还没有消息」——用户会以为
  /// 对话是空的，而不是「离线」。有缓存时填入它，至少能看到上次看到的历史。
  ///
  /// 缓存与网络的**互斥性**由调用点保证：只有 catch 分支才读缓存，故不会出现
  /// 「缓存上界与 timeline 下界重叠/缺口」的拼接问题。
  Future<void> _backfill(String groupId, {int limit = 200}) async {
    try {
      final page = await _api.groupTimeline(groupId, limit: limit);
      // timeline 返回顺序为「新 → 旧」或「旧 → 新」取决于服务端实现；
      // 归约要求按时间正序，这里按 globalSeq 显式排序保证正确性。
      final events = page.items.toList()
        ..sort((a, b) => (a.globalSeq ?? 0).compareTo(b.globalSeq ?? 0));
      _buffer
        ..clear()
        ..addAll(events);
      // 首屏拉的是**最新**一页，故本页最小值就是「历史边界」。
      _oldestLoadedGlobalSeq = _minGlobalSeqOf(events);
      _trimBuffer();
      SpbLog.info('对话历史回填完成', {'groupId': groupId, 'count': events.length});
      // 写缓存：**只在网络成功路径**（§4.3）。SSE 热路径不写。
      //
      // 不 await：写缓存是旁路，不应拖慢首屏渲染（实现层已静默，不会抛）。
      unawaited(_saveTimelineCache(groupId, events));
      // 网络成功 → 清除「离线数据」提示（否则提示条永久残留）。
      _setFromCache(false);
    } catch (e) {
      SpbLog.warn('对话历史回填失败，仅依赖实时流', {'error': e.toString()});
      if (e is SpbError && !_errorController.isClosed) {
        _errorController.add(e);
      }
      // 回填失败不阻断实时流——用户仍能看到新消息。
      //
      // 但若本地有缓存，把它填进缓冲，让断网时至少能看到历史（issue #29）。
      await _fallbackToCache(groupId);
    }
  }

  /// 回填失败时用缓存填缓冲（issue #29）。
  ///
  /// ## 为什么只在缓冲为空时填
  ///
  /// 已有内容时填入会**覆盖用户刚看到的内容**——与 `GroupListPage` 的回落
  /// 判据同一取向（那里的注释解释了「加载更多失败」的场景）。回填失败发生在
  /// [start] / [switchGroup]（那时缓冲刚被清空），故实际上总会填。
  Future<void> _fallbackToCache(String groupId) async {
    final cache = _timelineCache;
    if (cache == null || _buffer.isNotEmpty) return;
    final cached = await cache.load(groupId, limit: maxBufferEvents);
    if (_disposed || cached.isEmpty) return;
    // 缓存里的就是落库事件，按 globalSeq 升序（实现层保证）。这里再排一次是
    // 防御性的：归约器假定输入正序，而错序**不会报错**，只会渲染顺序颠倒。
    cached.sort((a, b) => (a.globalSeq ?? 0).compareTo(b.globalSeq ?? 0));
    _buffer.addAll(cached);
    // 历史边界：缓存里最小的事件就是能继续向上翻页的起点。
    //
    // ⚠️ 但服务端分页谓词是 `global_seq < cursor`，而缓存**可能**不含连续的
    // 一段（只缓存了最近 2000 条）。故这里设边界是「乐观」的：翻页拿回的更早
    // 事件会被 `loadOlder` 的 eventId 去重挡住重叠部分，缺口则表现为「翻到
    // 一半跳了一下」——比完全不能翻页好，且只在断网时可见。
    _oldestLoadedGlobalSeq = _minGlobalSeqOf(cached);
    _trimBuffer();
    _setFromCache(true);
    SpbLog.info('对话历史回填失败，已用本地缓存渲染', {
      'groupId': groupId,
      'count': cached.length,
    });
  }

  /// 更新 [timelineFromCache] 并推送（去重，避免重复帧）。
  void _setFromCache(bool value) {
    if (_fromCache == value) return;
    _fromCache = value;
    if (!_fromCacheController.isClosed) _fromCacheController.add(value);
  }

  /// 把落库事件写进缓存（旁路，失败静默）。
  Future<void> _saveTimelineCache(
    String groupId,
    List<ChatEvent> events,
  ) async {
    final cache = _timelineCache;
    if (cache == null || events.isEmpty) return;
    // 过滤由实现层做（`isCacheableEvent`），这里不重复。
    await cache.save(groupId, events);
  }

  /// 向上翻页：加载比当前缓冲区更早的一页历史。
  ///
  /// ## 游标必须用 globalSeq（不是 seq、不是 createdAt）
  ///
  /// 服务端分页谓词是 `WHERE global_seq < :before_global_seq ORDER BY global_seq DESC`
  /// （见 Go 侧 `db/queries/chat_events.sql` 的 `ListChatEventsByGroup`）。
  /// 用 [ChatEvent.seq] 会错：它是 **per-turn** 的，每个 turn 都从 1 重来；
  /// 用 `createdAt` 也会错——只有毫秒精度，同毫秒内的多条事件无法定序。
  /// `global_seq` 是唯一「全局唯一且单调」的排序键。
  ///
  /// ## 游标为什么取 [_oldestLoadedGlobalSeq]（而不是当前缓冲区的最小值）
  ///
  /// 首屏 [_backfill] 拉的是**最新**一页，故它记录「曾经加载到过的最早落库
  /// 事件」；服务端返回的正是「比它更早的一页」。
  ///
  /// ⚠️ **不能改用「当前缓冲区的最小 globalSeq」**：[_trimBuffer] 会从头部丢弃
  /// 最旧事件，最小值随之抬高，于是刚被裁掉的事件会被当成「更早的一页」重新
  /// 拉回来、又被立刻裁掉。详见 [_oldestLoadedGlobalSeq] 的说明。
  ///
  /// ## 为什么必须跳过 0 与 null
  ///
  /// `transient` 事件不落库、`globalSeq` 为 0；本地合成的乐观回显
  /// （[injectLocalUserMessage]）为 null。若把 0 当作游标，请求会变成
  /// `global_seq < 0`——**恒返回空**，而空页会被判为「没有更早的消息」，
  /// 表现为「明明有历史却翻不上去」。
  ///
  /// ## 返回值
  ///
  /// `true` 表示「可能还有更早的，可以继续触发」；`false` 表示已到最早一条
  /// （或本次无法翻页），调用方应停止触发。判定依据是**本页是否取满**：
  /// 取满 [limit] 条说明可能还有下一页，不足则已到最早。
  ///
  /// ## 已知边界
  ///
  /// 缓冲区里没有任何落库事件时（典型场景是首屏 [_backfill] 失败）无从确定
  /// 游标，此时返回 `false` 而不发请求——发一页「最新」历史只会重复首屏动作，
  /// 与「向上翻页」语义不符。
  ///
  /// 并发调用时返回 `true`（乐观），避免调用方把「正在加载」误判成「已到最早」
  /// 而永久停止翻页。
  Future<bool> loadOlder({int limit = 50}) async {
    final groupId = _groupId;
    if (groupId == null || _disposed) return false;
    if (_loadingOlder) return true;

    final cursor = _oldestLoadedGlobalSeq;
    if (cursor == null) return false;

    _loadingOlder = true;
    try {
      final page = await _api.groupTimeline(
        groupId,
        limit: limit,
        beforeGlobalSeq: cursor.toString(),
      );
      final events = page.items.toList()
        ..sort((a, b) => (a.globalSeq ?? 0).compareTo(b.globalSeq ?? 0));
      if (events.isEmpty) return false;

      // 前插：本页全部早于缓冲区里最早的事件，故插到头部即天然有序
      // （页内已按 globalSeq 升序排好）。
      //
      // 去重是防御性的：服务端游标是严格 `<`，正常情况下不会重叠；但归约层
      // 按 eventId 建项，一旦重叠就会渲染出重复气泡。
      final known = _buffer.map((e) => e.eventId).toSet();
      final fresh = events.where((e) => !known.contains(e.eventId)).toList();
      if (fresh.isEmpty) {
        // 全部已加载过 → 游标没能前进，再触发只会拉同一页。
        return false;
      }
      _buffer.insertAll(0, fresh);
      // 历史边界下调到本页最小值（只降不升）：裁剪不影响它，故这里用
      // 「本页最小值」而不是「缓冲区最小值」。
      final oldest = _minGlobalSeqOf(fresh);
      if (oldest != null &&
          (_oldestLoadedGlobalSeq == null ||
              oldest < _oldestLoadedGlobalSeq!)) {
        _oldestLoadedGlobalSeq = oldest;
      }
      _trimBuffer();
      _emit();
      SpbLog.info('加载更早历史完成', {
        'groupId': groupId,
        'cursor': cursor,
        'count': fresh.length,
      });
      // 写缓存：与 `_backfill` 同一写点（§4.3）。只写**新取到的**那页，
      // upsert 语义下不会影响已有页。
      unawaited(_saveTimelineCache(groupId, fresh));
      // 网络又通了 → 撤下「离线数据」提示。
      //
      // 此时缓冲里是「缓存 + 新拉的更早页」的混合体，严格说仍含陈旧数据；
      // 但提示条的语义是「你现在离线，看到的东西不会再更新」——既然能成功
      // 拉到更早的历史，后半句已经不成立。整段刷新留给下一次 `_backfill`
      // （重连 / 切 group 会触发），不在翻页路径上做。
      _setFromCache(false);
      return events.length >= limit;
    } catch (e) {
      SpbLog.warn('加载更早历史失败', {'error': e.toString()});
      if (e is SpbError && !_errorController.isClosed) {
        _errorController.add(e);
      }
      // 失败一律返回 false：让调用方停下，避免在滚动中疯狂重试。
      return false;
    } finally {
      _loadingOlder = false;
    }
  }

  /// 一组事件中最小的**落库** globalSeq；无有效值返回 null。
  ///
  /// 跳过 `null` 与 `<= 0`：前者是本地乐观回显，后者是 transient 事件
  /// （不落库，服务端从不给它分配 global_seq）。
  static int? _minGlobalSeqOf(Iterable<ChatEvent> events) {
    int? min;
    for (final e in events) {
      final g = e.globalSeq;
      if (g == null || g <= 0) continue;
      if (min == null || g < min) min = g;
    }
    return min;
  }

  /// 丢弃缓冲区里最旧的事件，使其不超过 [maxBufferEvents]。
  ///
  /// ## 为什么从头部丢
  ///
  /// [_buffer] 按 globalSeq 升序（见 [_backfill] / [loadOlder] 的排序），头部
  /// 最旧。时间线以「最新」为焦点（打开即滚到底部、新事件从尾部追加），故丢
  /// 头部对用户可感知的影响最小。
  ///
  /// ## 为什么不抬高翻页游标
  ///
  /// 只丢事件、**不动** [_oldestLoadedGlobalSeq]——否则被裁掉的事件会被再次
  /// 拉回来。见 [_oldestLoadedGlobalSeq] 的说明。
  void _trimBuffer() {
    final excess = _buffer.length - maxBufferEvents;
    if (excess <= 0) return;
    _buffer.removeRange(0, excess);
    SpbLog.debug('事件缓冲区超出上限，丢弃最旧事件', {
      'dropped': excess,
      'kept': _buffer.length,
      'limit': maxBufferEvents,
    });
  }

  void _onFrame(SseFrame frame) {
    // 心跳帧：不产生对话项，但可用于刷新「连接存活」UI 状态。
    if (frame.isComment) return;

    final eventType = frame.event;
    if (eventType == null || eventType.isEmpty) return;

    // 服务端 `data:` 是 JSON。解析失败说明契约破坏，记日志但不中断流。
    Map<String, dynamic> json;
    try {
      final decoded = _decode(frame.data);
      if (decoded == null) {
        // `_decode` 对空串与非法 JSON 都返回 null。两种情况都意味着这个事件
        // 被**整个丢弃**——用户会在时间线上看到一个缺口，而日志里毫无痕迹。
        //
        // ⚠️ 不记 `frame.data` 全文：载荷可能含用户输入，而诊断报告会被贴进
        // 公开 issue（AGENTS.md §6.20 的安全红线）。只记长度与类型。
        SpbLog.warn('SSE 事件载荷无法解析（该事件被丢弃）', {
          'event': eventType,
          'payload_bytes': frame.data.length,
          'empty': frame.data.isEmpty,
        });
        return;
      }
      json = decoded;
    } catch (e) {
      SpbLog.warn('SSE 帧解析失败', {'event': eventType, 'error': e.toString()});
      return;
    }

    ChatEvent event;
    try {
      event = ChatEvent.fromJson(json);
    } catch (e) {
      SpbLog.warn('ChatEvent 构造失败', {
        'event': eventType,
        'error': e.toString(),
      });
      return;
    }

    // group 过滤：SSE 是 user 级订阅，会收到其他 group 的事件。
    // 全局模式（_groupId == null）不过滤。
    //
    // ⚠️ **`group_updated` / `group_title_updated` / `group_metadata_updated`
    // 是例外**：它们的 groupId 指向「被变更的那个 group」，而与「当前打开哪个
    // 对话」无关（列表页在全局模式运行，但要实时反映任何 group 的变更）。按
    // 当前 group 过滤会把「新建了另一个 group」这类恰恰最需要的事件全部丢掉。
    // 故它们在过滤**之前**先推入通知流。
    //
    // 放在这里（而非下面的 switch/归约层）的理由：它们是**通知**而非对话状态，
    // 不应受「当前聚焦哪个对话」约束；而 turn_activity 是对话状态，必须受约束。
    //
    // ## 三者的游标语义**不同**（不能一概而论）
    //
    // - `group_updated` / `group_title_updated`：Go 侧显式设了
    //   `Transient: true`（`group/group_events.go:63`、
    //   `chatgate/title_gate.go:258`），无有效 ID，下面的游标推进天然不会
    //   碰到它们（故本分支**不** return，让它们自然穿透）。
    // - `group_metadata_updated`：**是落库的**（`broker.go:82` 的「持久化到
    //   chat_events」一组，且它确实有 turn），故它**应当**推进游标并落入
    //   [_buffer] 以便回放——本分支同样**不** return，让它继续走通用路径。
    //
    // 这与 `goal_updated` 的处理刚好相反：后者漏设 Transient 且不落库，必须
    // 提前 return 才能避免污染游标（见下方）。
    //
    // （三者对归约器都无 case、不产生对话项，故对时间线无影响。）
    if (event.eventType == EventTypes.groupUpdated ||
        event.eventType == EventTypes.groupTitleUpdated ||
        event.eventType == EventTypes.groupMetadataUpdated) {
      final update = GroupUpdate.fromEvent(event);
      if (update != null && !_groupUpdatesController.isClosed) {
        _groupUpdatesController.add(update);
      }
    }

    // `goal_updated`：目标/任务变更通知（含完整快照）。
    //
    // ## 为什么必须在这里 return（不能像 group_updated 那样穿透）
    //
    // 上面两类事件靠 Go 侧显式设了 `Transient: true` 而天然不推游标
    // （`group/group_events.go:63`、`chatgate/title_gate.go:258`）。
    //
    // `goal_updated` **没有**：`goal_api.go` 的 `emitGoalUpdated` 注释写着
    // 「不落库，仅广播」，但 `chatbus.Event` 的 `Transient` 字段留了零值
    // **false**——对比同族的 `PublishGroupUpdated` 可见这是漏设，不是有意。
    //
    // 于是事件带 `transient=false` + 有效 eventId，而它**不在** `chat_events`
    // 表里（无 turn，`turn_id` NOT NULL 写不进去）。若穿透到下面的游标推进，
    // 它会被 `recordEventId` 记下；服务端 `replayUserEvents` 按 `chat_events.id`
    // 定位 cursor 找不到该 ID → `start < 0` → 返回 nil → **整个断线回放窗口
    // 丢失**（不只是丢这一条）。
    //
    // 客户端无法修正服务端标志位（约束：Go API 一行不改），故在这里按
    // **事件类型**显式分流 + return——不依赖那个不可信的 transient 字段。
    //
    // 同样不进 [_buffer]：它无 turn、无 globalSeq，对时间线无任何贡献
    // （与 group_updated 不同，后者至少被归约器忽略而无害；这里直接不放入，
    // 避免无意义的缓冲占用）。
    if (event.eventType == EventTypes.goalUpdated) {
      final update = GoalUpdate.fromEvent(event);
      if (update != null && !_goalUpdatesController.isClosed) {
        _goalUpdatesController.add(update);
      }
      return;
    }

    final gid = _groupId;
    if (gid != null && event.groupId.isNotEmpty && event.groupId != gid) {
      return;
    }

    // 未知事件类型：记录一次以便发现契约漂移，但不影响渲染。
    if (!event.isKnown) {
      SpbLog.debug('收到未知事件类型（可能是服务端新增）', {'eventType': event.eventType});
    }

    // 该 turn 又活过来了：撤销超时判定。
    //
    // ## 为什么必须在这里（而非归约后按 items 判断）
    //
    // `turn_activity` 是「执行器仍在跑」的直接证据，但它**不进 items**
    // （走 activities 通道，见 [TurnActivitySnapshot] 类文档）。只按 items
    // 撤销，会让「只有工具心跳、没有正文」的长 turn 永久停在 stale。
    //
    // 放在 group 过滤**之后**：其他 group 的事件不得续期本 group 的看门狗。
    if (event.turnId.isNotEmpty && _staleTurnIds.remove(event.turnId)) {
      _pushStaleTurnIds();
    }

    _buffer.add(event);
    _trimBuffer();

    // cursor 只在落库事件上推进（Transient 事件无有效 ID）。
    if (!event.transient && event.eventId.isNotEmpty) {
      _sse.recordEventId(event.eventId);
    }

    _emit(touchedTurnId: event.turnId);
  }

  void _onStreamError(Object error) {
    final mapped = error is SpbError
        ? error
        : NetworkError(error.toString(), cause: error);
    SpbLog.warn('SSE 流错误', {'error': mapped.toString()});
    if (!_errorController.isClosed) _errorController.add(mapped);
  }

  /// 是否有挂起的归约（测试用，issue #44）。
  ///
  /// 合并把归约推迟到事件循环任务，故「挂起」是一个真实状态：
  /// [dispose] 必须把它取消，否则会留下一个指向已释放对象的计时器。
  @visibleForTesting
  bool get hasPendingEmit => _emitTimer != null;

  /// 请求一次归约 + 推送。
  ///
  /// 真正的计算在 [flushEmit] 里，由事件循环任务触发。同一轮次内多次调用只会
  /// 产生一次归约（issue #44，理由见 [_emitTimer] 上方的长注释）。
  void _emit({String? touchedTurnId}) {
    if (_itemsController.isClosed) return;
    // 缓冲已变 → 缓存的归约结果失效（即使本次不立即重算）。
    _reductionDirty = true;
    if (touchedTurnId != null && touchedTurnId.isNotEmpty) {
      (_pendingTouchedTurnIds ??= <String>{}).add(touchedTurnId);
    }
    // 用 `Timer(Duration.zero, ...)` 而非 `Timer.run`：后者返回 void，无法存入
    // 字段以便取消（切 group / dispose 时要丢掉挂起的合并）。两者都是事件循环
    // **任务**（非 microtask），合并效果实测一致。
    _emitTimer ??= Timer(Duration.zero, flushEmit);
  }

  /// 执行挂起的归约并推送全部派生流。
  ///
  /// 对测试可见：需要「立刻看到结果」而不想等一个事件循环轮次的用例可以显式
  /// 调它（见测试里的 `flushEmit()`）。生产路径只由 [_emit] 的计时器触发。
  @visibleForTesting
  void flushEmit() {
    _emitTimer?.cancel();
    _emitTimer = null;
    final touched = _pendingTouchedTurnIds;
    _pendingTouchedTurnIds = null;
    if (_itemsController.isClosed) return;
    // 用 `_reduction` 而非直接 reduce：若期间已有同步读把它算过，这里直接复用。
    _cachedReduction = _reduction;
    final reduction = _cachedReduction!;
    _itemsController.add(reduction.items);
    if (!_gateDecisionsController.isClosed) {
      _gateDecisionsController.add(reduction.gateDecisions);
    }
    if (!_activitiesController.isClosed) {
      _activitiesController.add(reduction.activities);
    }
    if (!_contextUsageController.isClosed) {
      _contextUsageController.add(reduction.contextUsage);
    }
    if (!_executionStatusController.isClosed) {
      _executionStatusController.add(reduction.executionStatus);
    }
    if (!_ttsStatusController.isClosed) {
      _ttsStatusController.add(reduction.ttsStatus);
    }
    // 每次缓冲变更都同步看门狗：判据是「距最后一次活动」，故只有
    // [touched] 里那些 turn 的到期时刻被推后（见 [_syncStaleWatch]）。
    _syncStaleWatch(touchedTurnIds: touched);
  }

  /// 发送消息（经完整前置链）。
  ///
  /// [groupId] 省略即「无归属入口」——服务端跑分类链判定归属，
  /// 响应里的 groupId 是判定结果。
  ///
  /// ## 离线时自动入队（issue #26 切片 C / issue #30）
  ///
  /// 若注入了 [OutboxQueue] 且失败是**可重试**的（断网 / 5xx / 429），
  /// 则消息进队列而不是上抛异常——用户打好的字不会丢。终态错误（400 等）
  /// 照旧上抛：重试无用，入队只会让用户在「待发送」里看到一条永远发不出去的
  /// 消息。
  ///
  /// ⚠️ **入队时不注入乐观回显**（设计文档 §7bis.6）：入队的条目还没有
  /// `turnId`，而归约器**按 turnId 去重**——无 turnId 的本地项在服务端
  /// `user_message` 到达后会渲染成两个气泡。故离线消息进「待发送」条，不进
  /// 时间线；投递成功后才用**服务端返回的 turnId** 注入回显。
  Future<SendMessageResult> send({
    required String input,
    String? groupId,
    String? agentId,
    String routingMode = 'auto',
    String? requestId,
  }) async {
    final resolvedGroupId = groupId ?? _groupId;
    try {
      final result = await _api.sendMessage(
        userId,
        input: input,
        groupId: resolvedGroupId,
        agentId: agentId,
        routingMode: routingMode,
        requestId: requestId,
      );
      _injectEcho(result, input, agentId: agentId);
      return result;
    } on SpbError catch (e) {
      final outbox = _outbox;
      if (outbox == null || !OutboxRetryPolicy.isRetryable(e)) rethrow;

      final outcome = await outbox.submit(
        userId: userId,
        input: input,
        groupId: resolvedGroupId,
        agentId: agentId,
        routingMode: routingMode,
      );
      switch (outcome) {
        case OutboxSubmittedNow(:final result):
          // 队列自己重试成功了（例如第一次失败只是偶发）。
          _injectEcho(result, input, agentId: agentId);
          return result;
        case OutboxQueuedOffline():
          // 已入队。调用方需要知道「没发出去」——用一条携带原始错误的信息
          // 让页面提示「已排队，联网后自动发送」而不是「发送失败」。
          throw MessageQueuedError(e.message, cause: e);
        case OutboxEnqueueFailed(:final error):
          // 存储也挂了 → 降级为旧行为（发送失败）。
          throw error;
      }
    }
  }

  /// 注入乐观回显（构造细节集中在 [injectLocalUserMessage]，那里解释了
  /// 「为什么事件类型必须是 user_message」「为什么 transient 必须为 true」）。
  void _injectEcho(SendMessageResult result, String input, {String? agentId}) {
    injectLocalUserMessage(
      input: input,
      groupId: result.groupId,
      turnId: result.turnId,
      agentId: agentId,
    );
  }

  /// 把离线队列接上：订阅投递成功 / 终态失败。
  ///
  /// ## 为什么由控制器订阅而不是队列反向回调控制器
  ///
  /// 方向保持单向（控制器 → 队列）。否则队列要持有控制器引用，而控制器的
  /// 生命周期是 `autoDispose.family`（离开对话页即释放）——队列会被迫感知
  /// 「当前哪个页面在看」，两者耦合。
  void _bindOutbox() {
    final outbox = _outbox;
    if (outbox == null) return;
    _outboxDeliveredSub = outbox.delivered.listen((d) {
      if (_disposed) return;
      // 投递成功：用**服务端返回的 turnId** 注入回显。此时 turnId 是真的，
      // 服务端随后的 `user_message` 会原位合并，不会出现两个气泡。
      //
      // ⚠️ 只在「这条消息属于当前打开的对话」时注入：队列是全局的，用户可能
      // 在 A 对话里发了一条，投递成功时已经切到 B 对话。
      final target = d.result.groupId;
      if (_groupId != null && target != _groupId) return;
      _injectEcho(d.result, d.entry.input, agentId: d.entry.agentId);
    });
    _outboxFailureSub = outbox.failures.listen((f) {
      if (_disposed) return;
      if (!_errorController.isClosed) {
        _errorController.add(
          MessageDeliveryFailedError(
            f.exhausted
                ? '离线消息重试多次仍失败：${f.error.message}'
                : '离线消息发送失败：${f.error.message}',
            cause: f.error,
          ),
        );
      }
    });
  }

  /// 重连（用户手动点「重试」时调用）。
  Future<void> reconnect() => _sse.resume();

  /// 释放本控制器自己的资源。
  ///
  /// ## 不释放 [SseClient]（重要）
  ///
  /// SSE 是 **user 级订阅**：一个进程内只有一条连接，跨所有对话共享
  /// （见 [switchGroup] 与 `sseClientProvider`）。它的生命周期属于**持有它的
  /// provider**，不属于任何一次对话页。
  ///
  /// 早期实现里这里曾调用共享连接的 dispose，后果是：离开一次对话页就把共享
  /// 连接永久关闭（`SseClient.dispose` 置 `_closedByUser = true` 并关闭两个
  /// StreamController），之后所有对话的 `connect()` 虽然仍会发 HTTP 请求，
  /// 但**所有帧都被静默丢弃**（`_pushFrame`/`_setState` 在关闭后直接 return）
  /// ——表现为「看起来连上了，其实一条事件都没有」。
  ///
  /// 故这里只取消**自己的**订阅（`_frameSub` / `_stateSub`）并关闭**自己的**
  /// 十个 StreamController（`_items` / `_gateDecisions` / `_activities` /
  /// `_contextUsage` / `_executionStatus` / `_ttsStatus` / `_staleTurnIds` /
  /// `_groupUpdates` / `_goalUpdates` / `_error` / `_state`）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // 丢弃挂起的合并（其计时器回调会因控制器已关而提前返回）。
    _emitTimer?.cancel();
    _emitTimer = null;
    _pendingTouchedTurnIds = null;
    for (final t in _staleTimers.values) {
      t.cancel();
    }
    _staleTimers.clear();
    await _frameSub?.cancel();
    await _stateSub?.cancel();
    await _outboxDeliveredSub?.cancel();
    await _outboxFailureSub?.cancel();
    await _itemsController.close();
    await _gateDecisionsController.close();
    await _activitiesController.close();
    await _contextUsageController.close();
    await _executionStatusController.close();
    await _ttsStatusController.close();
    await _staleTurnIdsController.close();
    await _fromCacheController.close();
    await _groupUpdatesController.close();
    await _goalUpdatesController.close();
    await _errorController.close();
    await _stateController.close();
  }

  static Map<String, dynamic>? _decode(String data) {
    if (data.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      // 静默返回 null，由调用方（`_onFrame`）决定怎么记——那里才有
      // `frame.event`（事件类型），而事件类型是这条日志最有用的字段。
      return null;
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }
}
