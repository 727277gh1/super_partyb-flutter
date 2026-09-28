import 'dart:async';
import 'dart:convert';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'event_reducer.dart';

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
  }) : _sse = sse,
       _api = api;

  final SseClient _sse;
  final ChatApi _api;
  final String userId;

  /// 当前聚焦的 group。null 表示接收全部 group 的事件。
  String? _groupId;

  final _itemsController = StreamController<List<ConversationItem>>.broadcast();
  final _errorController = StreamController<SpbError>.broadcast();
  final _stateController = StreamController<SseState>.broadcast();

  final List<ChatEvent> _buffer = [];
  StreamSubscription<SseFrame>? _frameSub;
  StreamSubscription<SseState>? _stateSub;
  bool _disposed = false;

  /// 归约后的对话项流（每次事件到达推送全量列表）。
  ///
  /// WHY 推全量而非增量：对话列表通常几百项，全量重建成本远低于维护增量合并
  /// 的复杂度；且 Flutter 列表 diff 依赖稳定 id，全量重建 + key 复用效率足够。
  /// 若将来列表规模显著增长，再改为增量 patch。
  Stream<List<ConversationItem>> get items => _itemsController.stream;

  Stream<SpbError> get errors => _errorController.stream;

  Stream<SseState> get connectionState => _stateController.stream;

  SseState get currentState => _sse.state;

  /// 当前对话项快照（供 UI 首次渲染，避免等待下一次推送）。
  List<ConversationItem> get snapshot => EventReducer.reduce(_buffer).items;

  /// 开始：回填历史 → 建立 SSE 连接。
  ///
  /// [groupId] 为 null 时进入「全局模式」，接收所有 group 的事件（用于通知中心）。
  Future<void> start({String? groupId}) async {
    _groupId = groupId;
    _buffer.clear();

    if (groupId != null) {
      await _backfill(groupId);
    }

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
    final result = EventReducer.reduce(_buffer);
    _itemsController.add(result.items);
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
    // 服务端的 start 事件到达后会重新归约，此处仅消除输入延迟感。
    _buffer.add(
      ChatEvent(
        eventId: 'local-${DateTime.now().microsecondsSinceEpoch}',
        userId: userId,
        groupId: result.groupId,
        turnId: result.turnId,
        eventType: EventTypes.start,
        seq: 0,
        source: 'client',
        createdAt: DateTime.now().toUtc(),
        payload: {'input': input},
        transient: true,
      ),
    );
    _emit();

    return result;
  }

  /// 重连（用户手动点「重试」时调用）。
  Future<void> reconnect() => _sse.resume();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _frameSub?.cancel();
    await _stateSub?.cancel();
    await _sse.dispose();
    await _itemsController.close();
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
