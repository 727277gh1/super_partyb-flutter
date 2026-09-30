import 'dart:async';
import 'dart:convert';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'event_reducer.dart';
import 'gate_decision.dart';

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
       _api = api;

  final SseClient _sse;
  final ChatApi _api;
  final String userId;

  /// 当前聚焦的 group。null 表示接收全部 group 的事件。
  String? _groupId;

  final _itemsController = StreamController<List<ConversationItem>>.broadcast();
  final _gateDecisionsController =
      StreamController<List<GateDecision>>.broadcast();
  final _errorController = StreamController<SpbError>.broadcast();
  final _stateController = StreamController<SseState>.broadcast();

  final List<ChatEvent> _buffer = [];
  StreamSubscription<SseFrame>? _frameSub;
  StreamSubscription<SseState>? _stateSub;
  bool _disposed = false;

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

  Stream<SpbError> get errors => _errorController.stream;

  Stream<SseState> get connectionState => _stateController.stream;

  SseState get currentState => _sse.state;

  /// 当前对话项快照（供 UI 首次渲染，避免等待下一次推送）。
  List<ConversationItem> get snapshot => _reduction.items;

  /// 当前 Gate 决策快照。
  List<GateDecision> get gateDecisionsSnapshot => _reduction.gateDecisions;

  /// 归约缓冲区（缓存最近一次 [_emit] 的结果，避免在 `snapshot` /
  /// `gateDecisionsSnapshot` 上各自重算）。
  //
  // [_emit] 在每次缓冲变更后调用，刷新缓存。两个 getter 直接读它，
  // 不再各自调 `EventReducer.reduce`（归约几百条事件不是零成本）。
  ReductionResult? _cachedReduction;

  ReductionResult get _reduction {
    // 若 emit 还没跑过（构造后未 start），现场算一次。
    return _cachedReduction ??= EventReducer.reduce(_buffer);
  }

  /// 开始：回填历史 → 建立 SSE 连接。
  ///
  /// [groupId] 为 null 时进入「全局模式」，接收所有 group 的事件（用于通知中心）。
  Future<void> start({String? groupId}) async {
    _groupId = groupId;
    _buffer.clear();

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
    });

    await _sse.connect(path: '/users/$userId/chat/stream');
  }

  /// 切换聚焦的 group（如用户点了另一个对话）。
  ///
  /// 复用同一条 SSE 连接——SSE 是 user 级订阅，切 group 无需重连，
  /// 只需清空缓冲并重新回填。
  Future<void> switchGroup(String? groupId) async {
    _groupId = groupId;
    _buffer.clear();
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
        payload: {'input': input},
        // 见方法文档：绝不能推进游标。
        transient: true,
      ),
    );
    _emit();
  }

  /// 用 timeline API 拉取历史事件。
  ///
  /// 服务端 timeline 返回的是 `ChatEvent` 列表（按 global_seq 升序），
  /// 直接灌入缓冲即可。
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
      SpbLog.info('对话历史回填完成', {'groupId': groupId, 'count': events.length});
    } catch (e) {
      SpbLog.warn('对话历史回填失败，仅依赖实时流', {'error': e.toString()});
      if (e is SpbError && !_errorController.isClosed) {
        _errorController.add(e);
      }
      // 回填失败不阻断实时流——用户仍能看到新消息。
    }
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
  /// ## 游标为什么取「缓冲区里最小的 globalSeq」
  ///
  /// 首屏 [_backfill] 拉的是**最新**一页，故缓冲区里最小的 globalSeq 就是
  /// 「已知最早的落库事件」；服务端返回的正是「比它更早的一页」。
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

    final cursor = _minLoadedGlobalSeq();
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
      _emit();
      SpbLog.info('加载更早历史完成', {
        'groupId': groupId,
        'cursor': cursor,
        'count': fresh.length,
      });
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

  /// 缓冲区中最小的**落库**事件 globalSeq；无有效游标时返回 null。
  ///
  /// 跳过 `null` 与 `<= 0`：前者是本地乐观回显，后者是 transient 事件
  /// （不落库，服务端从不给它分配 global_seq）。
  int? _minLoadedGlobalSeq() {
    int? min;
    for (final e in _buffer) {
      final g = e.globalSeq;
      if (g == null || g <= 0) continue;
      if (min == null || g < min) min = g;
    }
    return min;
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
      if (decoded == null) return;
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
    final gid = _groupId;
    if (gid != null && event.groupId.isNotEmpty && event.groupId != gid) {
      return;
    }

    // 未知事件类型：记录一次以便发现契约漂移，但不影响渲染。
    if (!event.isKnown) {
      SpbLog.debug('收到未知事件类型（可能是服务端新增）', {'eventType': event.eventType});
    }

    _buffer.add(event);

    // cursor 只在落库事件上推进（Transient 事件无有效 ID）。
    if (!event.transient && event.eventId.isNotEmpty) {
      _sse.recordEventId(event.eventId);
    }

    _emit();
  }

  void _onStreamError(Object error) {
    final mapped = error is SpbError
        ? error
        : NetworkError(error.toString(), cause: error);
    SpbLog.warn('SSE 流错误', {'error': mapped.toString()});
    if (!_errorController.isClosed) _errorController.add(mapped);
  }

  void _emit() {
    if (_itemsController.isClosed) return;
    _cachedReduction = EventReducer.reduce(_buffer);
    _itemsController.add(_cachedReduction!.items);
    if (!_gateDecisionsController.isClosed) {
      _gateDecisionsController.add(_cachedReduction!.gateDecisions);
    }
  }

  /// 发送消息（经完整前置链）。
  ///
  /// [groupId] 省略即「无归属入口」——服务端跑分类链判定归属，
  /// 响应里的 groupId 是判定结果。
  Future<SendMessageResult> send({
    required String input,
    String? groupId,
    String? agentId,
    String routingMode = 'auto',
    String? requestId,
  }) async {
    final result = await _api.sendMessage(
      userId,
      input: input,
      groupId: groupId ?? _groupId,
      agentId: agentId,
      routingMode: routingMode,
      requestId: requestId,
    );

    // 乐观回显：立刻把用户消息放进列表，不等服务端事件回来。
    //
    // 构造细节集中在 injectLocalUserMessage（与 quick capture 路径共用），
    // 那里解释了「为什么事件类型必须是 user_message」「为什么 transient 必须为 true」。
    injectLocalUserMessage(
      input: input,
      groupId: result.groupId,
      turnId: result.turnId,
    );

    return result;
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
  /// 故这里只取消**自己的**订阅并关闭**自己的**三个 StreamController。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _frameSub?.cancel();
    await _stateSub?.cancel();
    await _itemsController.close();
    await _gateDecisionsController.close();
    await _errorController.close();
    await _stateController.close();
  }

  static Map<String, dynamic>? _decode(String data) {
    if (data.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return null;
    }
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }
}
