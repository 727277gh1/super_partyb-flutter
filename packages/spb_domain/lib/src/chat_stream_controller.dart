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
import 'timeline_diagnostics.dart';
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
    this.replayGapProbeDelay = const Duration(seconds: 2),
    this.replayGapSettle = const Duration(milliseconds: 600),
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

  /// 连上后等多久再探测「断线回放是否被截断」（见 [_probeReplayGap]）。
  ///
  /// 这个延迟的意义是**让回放帧先到达**：服务端在同一个响应里先写回放、再进
  /// 实时循环，探测若跑得太早会把「回放还在路上」误判成缺口。
  final Duration replayGapProbeDelay;

  /// 判定缺口前的「静默窗口」：本地 `globalSeq` 在这段时间内**不再前进**，
  /// 且仍落后于服务端，才认定回放被截断。
  ///
  /// 单纯「落后」不足以判定——HTTP 探测的响应完全可能跑在 SSE 投递前面
  /// （两个独立连接）。故先等一个窗口再看本地是否还在追。
  final Duration replayGapSettle;

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

  /// group 级 token 消耗合计流（与 [items] 平行，**不是**归约产物）。
  final _usageSummaryController =
      StreamController<GroupUsageSummary?>.broadcast();

  /// 当前 group 的用量基线 + 本地增量（见 [usageSummary]）。
  ///
  /// **不走 `EventReducer`**：归约的输入是 [_buffer]，而缓冲有上限（2000 条，
  /// 按整轮裁剪）——从缓冲求和会「越用越少」。真源是 `usage-summary` 端点
  /// （服务端 `SUM(json_extract(...))`），这里只在拿到基线之后按 SSE 事件
  /// 做本地增量，并把结果同时缓存为本字段与推给 [_usageSummaryController]。
  GroupUsageSummary? _usageSummary;

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
  ///
  /// ## 上限作用于「合并后」的条数
  ///
  /// 流式增量在入缓冲前会先与尾部合并（见 [_coalesceIntoTail]）：一个回复无论
  /// 流了多少 token，都只占 1 个槽位。故 2000 条现在真正对应「2000 个事件」
  /// 而非「2000 个 token」——修复前一个长回复就能吃掉全部配额。
  static const int maxBufferEvents = 2000;

  final List<ChatEvent> _buffer = [];

  /// 乐观回显 eventId 的单调计数（见 [injectLocalUserMessage] 里的碰撞说明）。
  int _echoSeq = 0;

  /// 本会话最近一次**本地投递成功**的 turnId；空串 = 还没发过。
  ///
  /// 用途：对话页的兵底细条只对该 turn 显示「正在准备响应」（见
  /// [lastSentTurnId]）。为何不用「最后一个 turn 是 preparing」直接判，见 getter
  /// 的说明。
  String _lastSentTurnId = '';

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

  /// 缓冲区里见过的最大落库 `globalSeq`（**只增不减**，裁剪不降低它）。
  ///
  /// ## 为什么要单独记，而不是每次扫缓冲
  ///
  /// 用途是「本地覆盖到哪一段」的对账（[TimelineDiagnostics]）与断线缺口探测
  /// （[_probeReplayGap]），两者都在低频路径上，但扫描 2000 条事件并不便宜；
  /// 而它在追加时顺手更新是 O(1)。
  ///
  /// 只增不减是**有意**的：裁剪把最旧的事件丢掉，最大值不受影响；而
  /// [_backfill] / [_fallbackToCache] 是整段替换，必须显式重置（否则残留的
  /// 旧最大值会让缺口探测漏判）。
  int? _maxBufferedGlobalSeq;

  /// 裁剪统计（诊断用，见 [timelineDiagnostics]）。
  int _trimCount = 0;
  int _lastTrimDropped = 0;
  int _lastTrimKept = 0;
  bool _lastTrimPerTurn = false;

  /// 上一次把裁剪写进日志的时刻（节流用，见 [_recordTrim]）。
  DateTime? _lastTrimLogAt;

  /// 本 group 的裁剪是否已做过一次**完整**快照（见 [_recordTrim]）。
  bool _trimEpisodeStarted = false;

  /// 裁剪日志的最小间隔。
  ///
  /// 缓冲满了之后**每来一条新事件都会裁一次**，逐次 info 会在一秒内刷满 500 条
  /// 的诊断环形缓冲（AGENTS.md §6.20），把真正的异常扫掉——与 §6.48 单轮降级
  /// 路径只 warn 一次是同一教训。计数器不受节流影响，报告里永远是准的。
  static const Duration _trimLogInterval = Duration(seconds: 30);

  /// 本次聚焦期间「回放被截断 → 整段回填」的次数。
  int _replayGapRepairs = 0;

  /// 挂起的缺口探测 / 已重试次数。
  Timer? _gapProbeTimer;
  int _gapProbeAttempts = 0;

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

  /// group 级 token 消耗合计流（账单口径，与 `ContextUsage` 的水位口径是**两个量**）。
  ///
  /// ## 数据来源：REST 基线 + SSE 增量
  ///
  /// 1. [start] / [switchGroup] 时拉一次 `usage-summary` 作基线（非阻塞、失败静默）；
  /// 2. 之后每条 `token_usage` 事件（持久化业务事件，不在渲染白名单里）在
  ///    [_onFrame] 里做本地 `+1 条事件` 的增量，把结果推给本流。
  ///
  /// **不从 [_buffer] 求和**：缓冲有上限且按整轮裁剪（见 [maxBufferEvents]），
  /// 长会话里较早的 `token_usage` 会被丢掉——那样算出来的总量会越用越少。
  /// **也不在 [_backfill] / [loadOlder] 时增量**：基线已包含那些已落库的事件，
  /// 再累加就是双重计数。
  ///
  /// 推 null 表示当前无可用数据（未拉取 / 拉取失败 / 已切到无 group 的模式），
  /// 消费方应隐藏该区域。
  Stream<GroupUsageSummary?> get usageSummary => _usageSummaryController.stream;

  /// 用量快照（供 UI 首次渲染，同 [contextUsageSnapshot]）。
  GroupUsageSummary? get usageSummarySnapshot => _usageSummary;

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

  /// 最后一个 turn 的运行态 + 它的 turnId（**结构推断**，判据见
  /// [EventReducer.lastTurnRun]）。
  ///
  /// ## 它解决什么
  ///
  /// 「请求已落地、agent 还没产出任何东西」这段空窗期既没有流式标记（增量
  /// 帧还没来）、也没有 `queue_state` / `turn_activity`——归约结果看起来与
  /// 「什么都没发生」一样。唯一能说出「它可能还在跑」的是结构推断（与看门狗
  /// 武装计时器用的是**同一个**判据，见 `_syncStaleWatch`）。
  ///
  /// 故它必须是**派生的只读查询**：不写库、不改归约结果（§5.8 三条不变式）。
  ///
  /// ## 为什么按 `identical` 缓存
  ///
  /// 对话页每次 build 都会读它（→ 底部细条）。一次扫描是 O(n)，而流式期间
  /// 状态条每几秒变一次、每次都是一次完整 build（§6.47）。归约结果只在事件
  /// 到达后变化，故键就取它：同一份归约最多扫一遍。
  ({LastTurnRunState state, String turnId}) get lastTurnRunSnapshot {
    final reduction = _reduction;
    if (!identical(_cachedRunFor, reduction)) {
      _cachedRun = EventReducer.lastTurnRun(
        reduction.items,
        terminalTurnIds: reduction.terminalTurnIds,
      );
      _cachedRunFor = reduction;
    }
    return _cachedRun!;
  }

  /// 本会话最近一次**本地投递成功**的 turnId；空串 = 本会话还没发过。
  ///
  /// ## 它解决什么（为何不直接用「最后一个 turn 是 preparing」）
  ///
  /// `preparing` 在两种情形下都成立：
  /// 1. 我刚发了一条，等服务端开吐（要提示）；
  /// 2. 很久以前那个 turn 没收到 `done`、也没产出任何东西（历史里留下的破碎
  ///    状态，重开对话时会重现）。
  ///
  /// 情形 2 假设界面说「正在准备响应」就是**编造**：那是几小时前的事，而客户端
  /// 唯一的证据只是「没有终态」（看门狗自己也知道这一点，故它等超时才说
  /// 「可能仍在后台运行」）。故兵底细条只认本会话真正发出去的那个 turn——
  /// 控制器的生命周期是 `autoDispose.family`（离开对话页即释放），重开对话
  /// 时本字段自然为空，情形 2 不会误报。
  String get lastSentTurnId => _lastSentTurnId;

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

  /// [lastTurnRunSnapshot] 的缓存：上一次算过的归约结果与它对应的答案。
  ///
  /// 键用 `identical` 而不是「内容相等」：[ReductionResult] 每个事件批次都是
  /// 新建的，且逐字段比较比扫描本身还贵（与 `_displayRows` 的缓存同一取向）。
  ({LastTurnRunState state, String turnId})? _cachedRun;
  ReductionResult? _cachedRunFor;

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
    _resetTimelineTracking();
    _resetStaleWatch();
    _resetUsageSummary(groupId);

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
        // 断线期间错过的 `token_usage` 事件若不在回放窗口内，本地增量会偏小；
        // 重连即向服务端对一次账（成功才覆盖，失败保留本地读数）。同取向：
        // webapp 在 `use-workbench-state` 的重连路径上重拉 `usage-summary`。
        unawaited(_loadUsageSummaryQuietly());
        // 同一次重连也要对一次**时间线**的账：服务端回放窗口只有 500 条，
        // 超出时它会静默返回空（与「没有事件」同形），见 [_probeReplayGap]。
        _scheduleReplayGapProbe();
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
    _resetTimelineTracking();
    _setFromCache(false);
    _resetStaleWatch();
    _resetUsageSummary(groupId);
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
  ///
  /// ## 返回值与 pending（issue #52）
  ///
  /// 返回本地事件的 eventId，供调用方在「响应到达后」原位转正/移除这条回显
  /// （[_settleLocalEcho] / [_removeLocalEcho]）。
  /// `pending: true` 时归约层给 [UserMessageItem.pending] 置 true（UI 显示
  /// 「发送中」）——仅用于「请求在飞、尚未拿到服务端 turnId」的窗口。
  String injectLocalUserMessage({
    required String input,
    required String groupId,
    String? turnId,
    String? agentId,
    DateTime? createdAt,
    bool pending = false,
  }) {
    final now = createdAt ?? DateTime.now().toUtc();
    // ⚠️ 同微秒碰撞防御：这个 ID 现在被 [_settleLocalEcho] / [_removeLocalEcho]
    // 用作**精确定位**（不再只是去重标记）。两次注入若拿到同一微秒，会拿到
    // 同一个 eventId，转正/移除就会命中错误的回显。outbox 批量投递等路径
    // 有可能在同一微秒内连续注入，故补一个单调计数。
    final echoId = 'local-${now.microsecondsSinceEpoch}-${_echoSeq++}';
    _buffer.add(
      ChatEvent(
        eventId: echoId,
        userId: userId,
        groupId: groupId,
        turnId: turnId ?? '',
        eventType: EventTypes.userMessage,
        seq: 0,
        source: 'client',
        createdAt: now,
        payload: {
          'input': input,
          if (agentId != null) 'agent_id': agentId,
          if (pending) 'pending': true,
        },
        // 见方法文档：绝不能推进游标。
        transient: true,
      ),
    );
    // 乐观回显在尾部，裁剪只丢头部，故它不会被丢；这里仍调用以维持
    // 「所有 _buffer 变更点都裁剪」这一不变式。
    _trimBuffer();
    // 记住「本会话刚投递出去的 turn」：对话页据此判断要不要报「正在准备响应」
    // （见 [lastSentTurnId]）。turnId 为空（请求在飞 / 反馈类响应不建 turn）
    // 时**不**覆盖——上一次发送的值仍然有效。
    if ((turnId ?? '').isNotEmpty) _lastSentTurnId = turnId!;
    _emit();
    return echoId;
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
      // 缓冲被整段换掉 → 缓存的归约立即失效。
      //
      // ⚠️ 不能只靠后面的 `_emit()` 置脏：本方法在 `_emit()` **之前**就要读
      // 一次归约（写诊断快照），不先置脏就会把「旧对话的归约结果」当成本次
      // 回填的基线写进报告（实测踩过：回填后快照的助手字符数恒为 0）。
      _reductionDirty = true;
      // 整段替换：必须先清掉旧的最大值，否则上一个对话残留的 globalSeq 会让
      // 缺口探测（[_probeReplayGap]）把「本轮真的有缺口」判成「已追上」。
      _maxBufferedGlobalSeq = null;
      _noteMaxGlobalSeq(events);
      // 首屏拉的是**最新**一页，故本页最小值就是「历史边界」。
      _oldestLoadedGlobalSeq = _minGlobalSeqOf(events);
      _trimBuffer();
      SpbLog.info('对话历史回填完成', {'groupId': groupId, 'count': events.length});
      // 回填后的基线写进诊断快照：
      // 报告里能分「一开始就只有 200 条」与「跑着跑着被裁到 200 条」。
      TimelineProbe.record(timelineDiagnostics());
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
    _reductionDirty = true;
    _maxBufferedGlobalSeq = null;
    _noteMaxGlobalSeq(cached);
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
      _reductionDirty = true;
      // 前插的是更早的事件，最大值通常不变；仍走一遍以保持「任何灌入路径都
      // 更新区间」这条不变式（避免将来改成乱序插入时静默失效）。
      _noteMaxGlobalSeq(fresh);
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

  /// 一组事件中最大的**落库** globalSeq；无有效值返回 null。
  ///
  /// 与 [_minGlobalSeqOf] 同一语义（跳过 `null` 与 `<= 0`），用在缺口探测与
  /// [TimelineDiagnostics] 的「本地覆盖到哪一段」上。
  static int? _maxGlobalSeqOf(Iterable<ChatEvent> events) {
    int? max;
    for (final e in events) {
      final g = e.globalSeq;
      if (g == null || g <= 0) continue;
      if (max == null || g > max) max = g;
    }
    return max;
  }

  /// 把 [events] 的落库 globalSeq 并入 [_maxBufferedGlobalSeq]（只增不减）。
  void _noteMaxGlobalSeq(Iterable<ChatEvent> events) {
    final max = _maxGlobalSeqOf(events);
    if (max == null) return;
    final cur = _maxBufferedGlobalSeq;
    if (cur == null || max > cur) _maxBufferedGlobalSeq = max;
  }

  /// 换 group / 重新 start 时重置「本地覆盖区间」与裁剪、修复统计。
  ///
  /// 与 `_oldestLoadedGlobalSeq` 同一时机：换了一个 group，这些数字描述的
  /// 都是**上一个**对话的事实，留着会让诊断报告张冠李戴。
  void _resetTimelineTracking() {
    _maxBufferedGlobalSeq = null;
    _trimCount = 0;
    _lastTrimDropped = 0;
    _lastTrimKept = 0;
    _lastTrimPerTurn = false;
    _lastTrimLogAt = null;
    _trimEpisodeStarted = false;
    _replayGapRepairs = 0;
    _gapProbeAttempts = 0;
    _gapProbeTimer?.cancel();
    _gapProbeTimer = null;
  }

  /// 把事件追加到缓冲区尾部（**流式增量先与尾部合并**）。
  ///
  /// 所有「往尾部追加」的路径都必须经这里，而不是直接 `_buffer.add`——否则
  /// 增量合并会在某些入口失效，表现为「同一段回复有时能超过上限、有时不能」。
  /// 目前只有 [_onFrame] 走这条路径；[_backfill] / [loadOlder] 灌的是**落库**
  /// 事件（`transient == false`），不参与合并。
  void _appendEvent(ChatEvent event) {
    // 先置脏：合并与追加都会改缓冲。放在最前面是因为 [_coalesceIntoTail] 的
    // 命中路径也会就地改写 `_buffer.last`（合并后文本变了）。
    _reductionDirty = true;
    if (_coalesceIntoTail(event)) return;
    _buffer.add(event);
    // 合并路径不会走到这里，而增量事件本就没有 globalSeq——故只需在真正
    // 追加时更新一次。
    _noteMaxGlobalSeq([event]);
  }

  /// 若 [event] 可以并入 `_buffer.last` 就并入并返回 true。
  ///
  /// ## 为什么合并流式增量（一次真实缺陷）
  ///
  /// 服务端每产出一个 token 就发一条 `transient: true` 的增量事件
  /// （`chatexec/pigo_core.go` 的 `handleUpdate` → `flushEventTransient`）。
  /// 一个长回复能产出上千条，而 [maxBufferEvents] 是 2000——于是**几轮正常对话
  /// 就能把缓冲区灌满**，[_trimBuffer] 随即从头部丢事件。
  ///
  /// 而 [_reduction] 是 `EventReducer.reduce(_buffer)` 的**全量重算**：丢头部
  /// 等于把归约的输入掐掉一截，后果不是「少一条事件」而是**整轮对话从时间线上
  /// 消失**、或某条回复的**开头被截掉**。用户看到的正是「多轮之后往下滚，
  /// 前面的正文没了」。
  ///
  /// 合并后一个回复只占 **1** 个缓冲槽位（归约器本来就是把同 turn 的增量逐条
  /// 追加到同一个段落，故**归约结果逐字不变**），2000 的上限不再被流式增量
  /// 撑爆。
  ///
  /// ## 为什么必须保留**第一条**的 eventId
  ///
  /// 归约器用「首个增量帧的 `eventId`」当 [AssistantMessageItem.id]，而页面用
  /// `ValueKey(item.id)` 复用 Element。若合并时改用最后一条的 id，流式期间 id
  /// 会逐条变化 → Element 反复重建 → `gpt_markdown` 的增量解析缓存（`_engine`）
  /// 每次重置 → 气泡**塌成一行再重新打字**（实测：一次 `pump` 内渲染字符数
  /// `12912 → 36`）。保留首条的 id 则 id 从段落诞生到被权威帧接管都恒定。
  ///
  /// ## 合并条件为什么这么严
  ///
  /// 只在「紧邻、同 turn、同类型、同 session/agent、且两边都恰好只有一个
  /// 文本键、键名相同、值为字符串」时合并。任一不满足就退回独立入缓冲——
  /// 合并错了会**篡改正文**（比不合并严重得多），故宁可不合。
  bool _coalesceIntoTail(ChatEvent event) {
    if (!event.isIncremental || _buffer.isEmpty) return false;
    final last = _buffer.last;
    if (!last.isIncremental) return false;
    if (last.turnId != event.turnId) return false;
    if (last.eventType != event.eventType) return false;
    // sessionId / agentId 理论上随 turn 固定，但归约器会读它们（如
    // `AssistantMessageItem.agentId`）；不一致时合并会把后者覆盖掉，故直接不合并。
    if (last.sessionId != event.sessionId) return false;
    if (last.agentId != event.agentId) return false;

    final prevKey = _singleTextKeyOf(last);
    final nextKey = _singleTextKeyOf(event);
    if (prevKey == null || nextKey != prevKey) return false;

    final prevText = last.payload![prevKey] as String;
    final nextText = event.payload![nextKey] as String;

    _buffer[_buffer.length - 1] = ChatEvent(
      // 首条的标识（见方法文档：id 必须稳定）。
      eventId: last.eventId,
      userId: last.userId,
      groupId: last.groupId,
      turnId: last.turnId,
      sessionId: last.sessionId,
      agentId: last.agentId,
      eventType: last.eventType,
      seq: last.seq,
      // transient 事件不落库、globalSeq 恒为 null；保留首条的值以保持
      // 「合并前后对 [_minGlobalSeqOf] / 缓存过滤的可见性完全一致」。
      globalSeq: last.globalSeq,
      source: last.source,
      createdAt: last.createdAt,
      payload: {...last.payload!, prevKey: prevText + nextText},
      transient: last.transient,
      diagnostic: last.diagnostic,
    );
    return true;
  }

  /// 若 [event] 的 payload 恰好**只有一个**键且该键属于文本键集合、值为
  /// `String`，返回该键名；否则返回 null。
  ///
  /// ## 为什么要求「只有一个键」
  ///
  /// 服务端的增量帧目前只有 `{content: "..."}`（pigo / llm / responses 三个
  /// 执行器都是）。但只要带了任何附加键（未来的 `index` / `role` / 完成标记…），
  /// 合并就会**丢掉那条附加信息**。要求「唯一键」把这类演进挡在外面——多键时
  /// 不合并，行为退回到修复前（只是慢一点，不会错）。
  static String? _singleTextKeyOf(ChatEvent event) {
    final payload = event.payload;
    if (payload == null || payload.length != 1) return null;
    final entry = payload.entries.first;
    if (!_textPayloadKeys.contains(entry.key)) return null;
    if (entry.value is! String) return null;
    return entry.key;
  }

  /// 服务端可能用来承载流式文本的键（对齐 [ChatEvent.text] 的读取顺序）。
  static const Set<String> _textPayloadKeys = {'text', 'content', 'message'};

  /// 丢弃缓冲区里最旧的事件，使其不超过 [maxBufferEvents]。
  ///
  /// ## 为什么从头部丢
  ///
  /// [_buffer] 按 globalSeq 升序（见 [_backfill] / [loadOlder] 的排序），头部
  /// 最旧。时间线以「最新」为焦点（打开即滚到底部、新事件从尾部追加），故丢
  /// 头部对用户可感知的影响最小。
  ///
  /// ## 为什么以**整轮**为粒度（一次真实缺陷）
  ///
  /// 原先直接 `removeRange(0, excess)`，边界落在哪条事件上完全看运气。而
  /// [_reduction] 是 `EventReducer.reduce(_buffer)` 的全量重算：切在一轮对话
  /// 中间就等于**把那轮的头部删掉**——用户看到回复少了一段开头；切在两轮之间
  /// 的某条落库事件上，则整轮的用户消息可能先被丢掉，只剩一条「无主的 agent
  /// 回复」。
  ///
  /// 故改为「以 turnId 的连续段为粒度」：裁剪点只会落在一轮的**起点**上，
  /// 前面若干轮整段丢弃——宁可多丢一两轮，也不留半轮。
  ///
  /// ## 为什么有单轮兜底
  ///
  /// 缓冲区里**只有一个 turn** 时（首屏回填了一轮超长对话、或翻页翻进了同一轮），
  /// 按整轮丢就等于「全丢」，比原来的「丢一半」更糟。那时退回逐条丢头部，并
  /// 记一条 warn——这是有意的降级，不是遗漏。
  ///
  /// ## 为什么不抬高翻页游标
  ///
  /// 只丢事件、**不动** [_oldestLoadedGlobalSeq]——否则被裁掉的事件会被再次
  /// 拉回来。见 [_oldestLoadedGlobalSeq] 的说明。
  ///
  /// ## 已知边界：[loadOlder] 在触顶时的翻页会「白拉」
  ///
  /// 缓冲区触顶时，[loadOlder] 先往头部 `insertAll` 再调本方法，而本方法仍从
  /// 头部丢——刚插进去的那页会被原样丢掉，用户看到「翻页转了一圈什么都没变」。
  /// 这是**修复前就存在**的独立缺陷（不是本次引入），且修它要改翻页语义
  /// （是「前插时临时提高上限」还是「翻页时暂停裁剪」需要产品决定），故本次
  /// 不动，只在此记录。
  void _trimBuffer() {
    final excess = _buffer.length - maxBufferEvents;
    if (excess <= 0) return;

    final cut = _turnBoundaryAtOrAfter(excess);
    if (cut == null) {
      // 整个缓冲区都在同一个 turn 里，没有边界可切——退回逐条丢头部。
      _buffer.removeRange(0, excess);
      _recordTrim(excess, perTurn: false);
      // 只在本降级时段的第一条记 warn（见 `_singleTurnTrimWarned`）。
      if (!_singleTurnTrimWarned) {
        _singleTurnTrimWarned = true;
        SpbLog.warn('事件缓冲区超限但无法按轮裁剪（整个缓冲区属于同一轮），退回逐条丢弃', {
          'dropped': excess,
          'kept': _buffer.length,
          'limit': maxBufferEvents,
          'turnId': _buffer.isEmpty ? '' : _buffer.first.turnId,
        });
      }
      return;
    }
    if (cut <= 0) return;

    _singleTurnTrimWarned = false;
    _buffer.removeRange(0, cut);
    _recordTrim(cut, perTurn: true);
  }

  /// 记一次裁剪：先更新**不受节流影响**的计数器，再按需写日志与诊断快照。
  ///
  /// ## 为什么日志要节流、计数器不能
  ///
  /// 缓冲满了之后**每来一条新事件就裁一次**（新事件 → 超限 → 丢一条）。逐次
  /// info 会在一秒内刷满 500 条的诊断环形缓冲，把真正的异常扫掉——与
  /// `_singleTurnTrimWarned` 是同一教训。而报障时要回答的「到底裁过没有、
  /// 裁掉多少」必须**永远准**，故计数器不节流，只节流写日志。
  ///
  /// 裁剪日志从 debug 升 **info**：debug 在发布构建被过滤，等于没写
  /// （AGENTS.md §6.57 的同一纠正）。
  void _recordTrim(int dropped, {required bool perTurn}) {
    _trimCount++;
    _lastTrimDropped = dropped;
    _lastTrimKept = _buffer.length;
    _lastTrimPerTurn = perTurn;

    // ① 计数与区间是 O(1) 的，**每次都**补到已有快照上：报障要回答的
    // 「到底裁过没有、裁了多少」不能靠采样。
    _patchProbeTrimStats();

    // ② 完整快照（正文字符数与逐轮明细）要一次归约，故只在本 group 的
    // **首次**裁剪与每 [_trimLogInterval] 采一次。
    final now = DateTime.now();
    final firstOfEpisode = !_trimEpisodeStarted;
    final last = _lastTrimLogAt;
    if (!firstOfEpisode &&
        last != null &&
        now.difference(last) < _trimLogInterval) {
      return;
    }
    _trimEpisodeStarted = true;
    _lastTrimLogAt = now;
    SpbLog.info('事件缓冲区超出上限，已丢弃最旧事件', {
      'dropped': dropped,
      'kept': _buffer.length,
      'limit': maxBufferEvents,
      'per_turn': perTurn,
      'trim_count': _trimCount,
    });
    // 裁剪是「内容从客户端消失」最直接的可疑原因，故顺手落一份诊断快照：
    // 报告里能看到裁剪**之后**还剩多少正文。
    TimelineProbe.record(timelineDiagnostics());
  }

  /// 把「计数与区间」补到已有快照上（**不重算归约**）。
  ///
  /// ## 为什么要判断 group
  ///
  /// 跨 group 的补丁会把上一个对话的裁剪史算到当前对话头上（`switchGroup`
  /// 会清计数，但快照是进程级的）。不同 group 就什么都不做——本 group 的
  /// 首次完整快照（和 `done`）会带上正确的累计值。
  void _patchProbeTrimStats() {
    final cur = TimelineProbe.latest;
    if (cur == null || cur.groupId != _groupId) return;
    TimelineProbe.record(
      cur.withTrimStats(
        bufferedEvents: _buffer.length,
        trimCount: _trimCount,
        lastTrimDropped: _lastTrimDropped,
        lastTrimKept: _lastTrimKept,
        lastTrimPerTurn: _lastTrimPerTurn,
        oldestLoadedGlobalSeq: _oldestLoadedGlobalSeq,
        newestBufferedGlobalSeq: _maxBufferedGlobalSeq,
        replayGapRepairs: _replayGapRepairs,
        sseCursorPresent: (_sse.lastEventId ?? '').isNotEmpty,
        fromCache: _fromCache,
      ),
    );
  }

  /// 单轮降级裁剪是否已记过 warn（防日志洪水）。
  ///
  /// 单轮超限时每条新事件都会触发一次裁剪，若每次都 warn，一秒就能把 500 条的
  /// 诊断环形缓冲（AGENTS.md §6.20）刷满，把真正的异常扫掉。故按「降级时段」
  /// 只记一次：一旦重新出现轮次边界（可正常按轮裁剪），标记复位。
  bool _singleTurnTrimWarned = false;

  /// 找到「至少丢掉 [minDrop] 条、且落在轮次边界上」的裁剪点；无边界返回 null。
  ///
  /// 从 `minDrop` 往后找第一个 turnId 与它的**前一条**不同的位置——那里是
  /// 一轮的起点，从它开始丢就完整丢掉了前面若干轮。
  ///
  /// ## 为什么是「向后找」而不是「就近取整」
  ///
  /// 向后找只会**多丢**、不会少丢：缓冲区一定回到上限以下（上限的硬保证）。
  /// 就近取整则可能丢得不够，于是下一批事件到达时又要再裁一次——而那时新的一轮
  /// 可能已经开始了，反而更容易切错。
  int? _turnBoundaryAtOrAfter(int minDrop) {
    for (var i = minDrop; i < _buffer.length; i++) {
      if (_buffer[i].turnId != _buffer[i - 1].turnId) return i;
    }
    return null;
  }

  // ==================== 诊断：时间线数据面快照 ====================

  /// 当前时间线的「数据面」快照（见 [TimelineDiagnostics]）。
  ///
  /// ## 成本与调用点（重要）
  ///
  /// 它需要**一次归约**（若缓存已失效）+ 一遍 O(items) 统计。故只在低频节点
  /// 调用：一轮结束、裁剪、回填、回放修复。**不要**放进每帧/每条事件的路径。
  ///
  /// ## 它解决的判据
  ///
  /// 用户报「回复大块内容消失」时，先看这里的 `assistant_chars` 与 `trim_count`：
  ///
  /// | 快照 | 结论 |
  /// |---|---|
  /// | 字符数正常、搜索也能命中 | **渲染层**（§6.51 那一类），数据没丢 |
  /// | 字符数本身就少 / `assistant_chars` 比记忆中少 | **数据层**：裁剪或回放截断 |
  /// | `trim_count > 0` 且丢的轮次对得上 | 就是 2000 上限裁的（§6.48），不是新缺陷 |
  TimelineDiagnostics timelineDiagnostics() {
    final items = _reduction.items;
    var assistantChars = 0;
    final byTurn = <String, List<int>>{};
    final streaming = <String>{};
    for (final item in items) {
      if (item is! AssistantMessageItem) continue;
      final len = item.text.length;
      assistantChars += len;
      if (item.isStreaming) streaming.add(item.turnId);
      // [字符数, 段数]
      final acc = byTurn.putIfAbsent(item.turnId, () => <int>[0, 0]);
      acc[0] += len;
      acc[1] += 1;
    }
    final turns =
        byTurn.entries
            .map(
              (e) => TurnTextStat(
                turnId: e.key,
                chars: e.value[0],
                items: e.value[1],
                isStreaming: streaming.contains(e.key),
              ),
            )
            .toList()
          ..sort((a, b) => b.chars.compareTo(a.chars));

    return TimelineDiagnostics(
      groupId: _groupId,
      bufferedEvents: _buffer.length,
      maxBufferEvents: maxBufferEvents,
      itemCount: items.length,
      assistantChars: assistantChars,
      turns: turns,
      oldestLoadedGlobalSeq: _oldestLoadedGlobalSeq,
      newestBufferedGlobalSeq: _maxBufferedGlobalSeq,
      trimCount: _trimCount,
      lastTrimDropped: _lastTrimDropped,
      lastTrimKept: _lastTrimKept,
      lastTrimPerTurn: _lastTrimPerTurn,
      fromCache: _fromCache,
      replayGapRepairs: _replayGapRepairs,
      sseCursorPresent: (_sse.lastEventId ?? '').isNotEmpty,
    );
  }

  /// 把快照写进日志环形缓冲与 [TimelineProbe]（导出诊断报告读的就是它）。
  void _logTimelineDigest(String reason) {
    final d = timelineDiagnostics();
    TimelineProbe.record(d);
    SpbLog.info('时间线数据面快照', {'reason': reason, ...d.toLogFields()});
  }

  // ==================== 断线回放缺口探测 ====================

  /// 排一次缺口探测（见 [_probeReplayGap]）。
  ///
  /// 只在**带游标的重连**上排：首次连接（游标为空）时 [start] 已经整段回填过，
  /// 没有「回放」可言；全局模式（`_groupId == null`）没有时间线，也无从对账。
  void _scheduleReplayGapProbe() {
    if (_disposed || _groupId == null) return;
    final cursor = _sse.lastEventId;
    if (cursor == null || cursor.isEmpty) return;
    _gapProbeAttempts = 0;
    _gapProbeTimer?.cancel();
    _gapProbeTimer = Timer(
      replayGapProbeDelay,
      () => unawaited(_probeReplayGap()),
    );
  }

  /// 探测「断线回放是不是被服务端截断了」，是则改用 timeline 整段回填。
  ///
  /// ## 为什么客户端必须自己探测（服务端给不出任何信号）
  ///
  /// 服务端 `replayUserEvents`（`chat_stream.go`）只取该用户**最近 500 条**
  /// 落库事件，在其中定位 cursor；**找不到就返回空**，然后照常进入实时循环。
  /// 于是「断线期间超过 500 条事件」与「断线期间什么都没有」在线上**完全同形**
  /// ——客户端不探测，就会带着一段永久空洞继续渲染（用户看到「回复少了一大块」）。
  ///
  /// `docs/api-contract.md` §5.4 早就写了「超出窗口时返回空 → 客户端应改用
  /// timeline API 整段回填」，但本方法之前**没有实现**：`_backfill` 只在
  /// `start` / `switchGroup` 调用，重连路径上一次也不拉。
  ///
  /// ## 判据（两道）
  ///
  /// 1. **不是「落后」，是「追不上」**：拉一条 `limit=1` 的 timeline 拿该 group
  ///    的最新 globalSeq，与本地见过的最大值比。HTTP 探测的响应完全可能跑在
  ///    SSE 投递前面（两个独立连接），故「落后」只作为必要条件；
  /// 2. **静默窗口**：等 [replayGapSettle]，若本地最大值在这段时间里**还在前进**，
  ///    说明回放仍在到达（或实时流仍在追），重新排一次探测（最多 2 次）；
  ///    静默了整整一个窗口仍然落后，才判定为真缺口。
  ///
  /// 这两道缺一不可：只按「落后」判，正常流式期间的每次重连都会误触发整段回填
  /// （把用户在看的正文重置成最新 200 条）；只按「静默」判，缓冲根本不动时
  /// 永远判不出缺口（因为「不动」本身不代表回放结束了）。
  ///
  /// ## 修复动作就是既有路径
  ///
  /// 缺口意味着缓冲区**中间有洞**，拼接无意义（无法得知洞在哪、有多长）——
  /// 与部分页拼接相比，整段回填是唯一不会「看起来连续但实际缺一段」的选择。
  /// 代价是丢掉缓冲里更早的已加载页与滚动位置（文档已把它列为该路径的既有语义）。
  Future<void> _probeReplayGap() async {
    final groupId = _groupId;
    if (_disposed || groupId == null || _loadingOlder) return;
    final localMax = _maxBufferedGlobalSeq;
    // 本地还没有任何落库事件（首屏回填失败/离线）：无从对账，不得误判成缺口。
    if (localMax == null) return;

    CursorPage<ChatEvent> page;
    try {
      page = await _api.groupTimeline(groupId, limit: 1);
    } on Object catch (e) {
      // 探测失败不打扰用户：下一次重连会再探一次。debug 级（发布构建被过滤）。
      SpbLog.debug('断线回放缺口探测失败（忽略）', {'error': e.toString()});
      return;
    }
    if (_disposed || _groupId != groupId) return;

    final serverMax = _maxGlobalSeqOf(page.items);
    if (serverMax == null || serverMax <= localMax) return;

    await Future<void>.delayed(replayGapSettle);
    if (_disposed || _groupId != groupId) return;
    final after = _maxBufferedGlobalSeq;
    // 追上了：回放/实时流已经把差距补上——这正是「探测跑在 SSE 前面」的正常情况。
    if (after == null || after >= serverMax) return;
    // ⚠️ 与 [localMax]（**发请求之前**的值）比，不是与「响应到达后」的值比：
    // 探针的响应可能已经把回放帧憋在路上，读到的是已经前进过的值，于是
    // 「还在动」这个信号被吃掉（实测踩过：换成响应后重新读，「重排一次再
    // 追上」那条用例直接跳到整段回填）。
    if (after != localMax && _gapProbeAttempts < 2) {
      _gapProbeAttempts++;
      _gapProbeTimer?.cancel();
      _gapProbeTimer = Timer(
        replayGapSettle,
        () => unawaited(_probeReplayGap()),
      );
      return;
    }

    _gapProbeAttempts = 0;
    _replayGapRepairs++;
    SpbLog.warn('断线回放被截断（cursor 已超出服务端回放窗口），改用 timeline 整段回填', {
      'group_id': groupId,
      'local_max_global_seq': after,
      'server_max_global_seq': serverMax,
      'repairs': _replayGapRepairs,
    });
    await _backfill(groupId);
    _emit();
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

    // token_usage：本地增量累加到 group 总量（账单口径）。
    //
    // 放在 group 过滤**之后**（不按当前 group 过滤就会把别的对话的账记到本 group），
    // 且只在这里（实时帧）做——[_backfill] / [loadOlder] 拿到的是**已落库**的
    // 同一批事件，REST 基线已包含它们，再累加就是双重计数。
    //
    // 它**继续**走下面的通用路径：`token_usage` 是落库事件（`Transient` 为零值
    // false）、带有效 eventId，故游标应当推进、事件也应落入 [_buffer]
    // （归约器无 case ⇒ 不产生时间线条目，只是保持「落库事件走通用路径」
    // 这条不变式不被特例破坏）。
    if (event.eventType == EventTypes.tokenUsage) {
      _applyUsageIncrement(event);
    }

    _appendEvent(event);
    _trimBuffer();

    // cursor 只在落库事件上推进（Transient 事件无有效 ID）。
    if (!event.transient && event.eventId.isNotEmpty) {
      _sse.recordEventId(event.eventId);
    }

    _emit(touchedTurnId: event.turnId);

    // 一轮结束：把「数据面」快照写进日志/诊断报告。
    //
    // 为什么在 `done` 而不是每条事件：这是「这一轮的正文到底进了归约结果没有」
    // 的唯一稳定对账点——用户报障时说的是「刚才那条长回复没了」，而下一轮
    // 开始后缓冲/裁剪已经又变了一次。频度也是一轮一条，不会刷满环形缓冲。
    //
    // 若 `done` 丢失（turn worker 崩了 / 断线），还有裁剪与回填两个点会写快照，
    // 不会因为少一个对账点就什么都看不到。
    if (event.eventType == EventTypes.done) {
      _logTimelineDigest('done');
    }
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

  /// 重拉当前 group 的用量基线（供页面主动刷新，如下拉 / 回到前台）。
  ///
  /// 无聚焦 group 时为空操作。失败静默（用量是非关键展示）。
  Future<void> refreshUsageSummary() async {
    final gid = _groupId;
    if (gid == null) return;
    await _loadUsageSummary(gid);
  }

  /// 重连时的对账（内部用，不暴露给页面）。
  ///
  /// 与 [refreshUsageSummary] 的差别只是「没有聚焦 group 时什么都不做」——
  /// 列表页建的全局连接（`groupId == null`）也会收到 `SseState.connected`，
  /// 那时既无账单可拉，也不该为一个没打开的对话发请求。
  Future<void> _loadUsageSummaryQuietly() async {
    final gid = _groupId;
    if (gid == null || gid.isEmpty) return;
    await _loadUsageSummary(gid);
  }

  /// 切换 group 时重置用量状态，并按需拉取新 group 的基线。
  ///
  /// 先重置再拉取：否则旧 group 的账单会在新对话的首帧继续显示
  /// （那是一个会误导人的跨对话串数据）。
  void _resetUsageSummary(String? groupId) {
    _usageSummary = null;
    if (!_usageSummaryController.isClosed) _usageSummaryController.add(null);
    if (groupId != null && groupId.isNotEmpty) {
      // 不 await：用量是非关键展示，不能拖慢首屏回填 / 切对话。
      unawaited(_loadUsageSummary(groupId));
    }
  }

  /// 拉一次 group 用量基线。
  ///
  /// ## 三条约束
  ///
  /// 1. **不重试、不报错**：只记 debug。用量是一块只读读数，拉取失败应静默
  ///    降级为「不显示」，而不是给用户一个错误提示（同 webapp `loadUsageSummary`
  ///    的 `catch {}`）。
  /// 2. **结果必须校验归属**：请求在飞期间用户可能已切到另一个对话，晚到的响应
  ///    会把 A 的账单挂到 B 上（跨对话串数据，比不显示更糟）。
  /// 3. **失败时保留旧值？不**——失败时什么都不改，故旧值（此时一定为 null，
  ///    因为 [_resetUsageSummary] 刚清过）保持不变。
  Future<void> _loadUsageSummary(String groupId) async {
    try {
      final summary = await _api.groupUsageSummary(groupId);
      if (_disposed || _groupId != groupId) return;
      _usageSummary = summary;
      if (!_usageSummaryController.isClosed) {
        _usageSummaryController.add(summary);
      }
    } catch (e) {
      SpbLog.debug('group 用量汇总拉取失败（静默降级为不显示）', {
        'group': groupId,
        'error': e.toString(),
      });
    }
  }

  /// 收到一条 `token_usage` 事件：把本轮账加到本地总量上。
  ///
  /// ## 基线未就绪时跳过（不是「先攒着」）
  ///
  /// 基线（[_usageSummary]）为 null 有两种情形：刚切 group、基线请求在飞。
  /// 此时若先累加再叠加晚到的基线，会**双重计数**（基线快照通常已包含这条事件）。
  /// 故跳过——基线落地后自会包含它。代价是「基线快照早于事件」时会少算一轮，
  /// 下次拉取即纠正：偏好「少算」而非「多算」（与 webapp `if (!cur) return prev`
  /// 同一取舍）。
  void _applyUsageIncrement(ChatEvent event) {
    final current = _usageSummary;
    if (current == null) {
      SpbLog.debug('token_usage 到达时用量基线未就绪，跳过本地增量', {
        'group': event.groupId,
        'turn': event.turnId,
      });
      return;
    }
    _usageSummary = current.incrementedByEvent(
      event.payload ?? const <String, dynamic>{},
      // 时间在**事件行**上（payload 不带），与服务端 `MIN/MAX(created_at)` 同源。
      occurredAt: event.createdAt.toIso8601String(),
    );
    if (!_usageSummaryController.isClosed) {
      _usageSummaryController.add(_usageSummary);
    }
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
  /// ## 为什么 pending 的注入与移除都在这里集中
  ///
  /// 请求在飞时回显带 `pending: true`（UI 显示「发送中」）；成功后
  /// [_settleLocalEcho] 原位转正（关 pending、落 turnId）；失败（含**入队**
  /// ——待发送条有自己的 UI，issue #30）由 [_removeLocalEcho] 移除，不留
  /// 幽灵气泡。
  Future<SendMessageResult> send({
    required String input,
    String? groupId,
    String? agentId,
    String routingMode = 'auto',
    String? requestId,
  }) async {
    final resolvedGroupId = groupId ?? _groupId;
    // 乐观回显：请求在飞时立即渲染（issue #52）。pending 让 UI 显示「发送中」；
    // 拿到响应后原位转正（成功）或移除（失败/入队）。
    final echoId = injectLocalUserMessage(
      input: input,
      groupId: resolvedGroupId ?? '',
      agentId: agentId,
      pending: true, // 请求在飞：UI 显示「发送中」，转正/权威帧都会落回 false
    );
    try {
      final result = await _api.sendMessage(
        userId,
        input: input,
        groupId: resolvedGroupId,
        agentId: agentId,
        routingMode: routingMode,
        requestId: requestId,
      );
      _settleLocalEcho(echoId, result.groupId, result.turnId, input, agentId);
      return result;
    } on SpbError catch (e) {
      _removeLocalEcho(echoId);
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

  /// 发送成功后把 [injectLocalUserMessage] 注入的乐观回显**原位转正**：
  /// 换成带服务端 turnId、`pending: false` 的版本。后续权威 `user_message` 帧
  /// 到达时按 turnId 原位合并，不产生第二个气泡。
  ///
  /// ## turnId 为空也要转正（不能提前 return）
  ///
  /// [SendMessageResult.turnId] 可为空：反馈类响应（`feedback_recorded`）
  /// **不建 turn**——此后不会再有权威帧到达。若 turnId 为空时直接 return，
  /// 回显会带着 `pending: true` **永久**显示「发送中」。故转正分两档：
  ///
  /// - turnId 非空：换上真 turnId，后续权威帧按 turnId 去重合并；
  /// - turnId 为空：只关 pending（保持无 turnId）。不会再来权威帧可去重，
  ///   这是 [injectLocalUserMessage] 文档里「无 turnId 不去重」的既有取舍；
  ///   防御性解析失败（turn 对象缺失但 turn 存在）时可能短暂双气泡，
  ///   仍优于永久转圈。
  void _settleLocalEcho(
    String echoId,
    String? groupId,
    String turnId,
    String input,
    String? agentId,
  ) {
    final idx = _buffer.indexWhere((e) => e.eventId == echoId);
    if (idx < 0) {
      // 回显已不在缓冲（切 group 清空 / 入队前移除）。**不重新注入**：
      // 此时缓冲可能已属于另一个对话，往里塞旧对话的消息会串场；
      // 且服务端权威帧自会把它渲染出来。
      return;
    }
    _buffer[idx] = ChatEvent(
      eventId: echoId,
      userId: _buffer[idx].userId,
      groupId: groupId ?? _buffer[idx].groupId,
      turnId: turnId,
      eventType: EventTypes.userMessage,
      seq: 0,
      source: 'client',
      createdAt: _buffer[idx].createdAt,
      payload: {'input': input, if (agentId != null) 'agent_id': agentId},
      transient: true,
    );
    // 转正是「本会话真正发出去了」的确切时刻（也是 `preparing` 成立的前提）：
    // 对话页据此显示「正在准备响应」，见 [lastSentTurnId]。
    //
    // ⚠️ 不能只写在 [injectLocalUserMessage] 里：本方法**原位替换**缓冲事件，
    // 不走那个入口（pending 阶段 turnId 还是空的，那时也无从判断）。
    if (turnId.isNotEmpty) _lastSentTurnId = turnId;
    _trimBuffer();
    _emit();
  }

  /// 发送失败时把乐观回显移除（避免永久停留的幽灵消息）。
  /// **不可重试错误与入队成功**都走这里（入队那条有自己的「待发送」UI，issue #30）。
  void _removeLocalEcho(String echoId) {
    final before = _buffer.length;
    _buffer.removeWhere((e) => e.eventId == echoId);
    if (_buffer.length == before) return;
    _trimBuffer();
    _emit();
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
    // 丢弃挂起的缺口探测（回调里会再查 `_disposed`，但取消更干净）。
    _gapProbeTimer?.cancel();
    _gapProbeTimer = null;
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
    await _usageSummaryController.close();
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
