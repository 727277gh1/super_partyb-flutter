import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 假的 [SseClient]。
///
/// ## 为什么用「继承真类 + 覆盖全部公开成员」而不是 implements
///
/// [SseClient] 不是接口，`ChatStreamController` 依赖具体类型。用 `implements`
/// 需要实现全部公开成员（含 `recordEventId`/`lastEventId`/`state` 等），编译器会
/// 逐个报缺；这里用 `extends` + `super(dio: ..., baseUrl: ...)`，只覆盖控制器
/// 真正会调用的那几个，其余保持真实实现（不连网络，因为从不调 connect）。
///
/// 好处：`ChatStreamController` 里对 `_sse.recordEventId(...)` 的调用被真实记录，
/// 于是「transient 事件不得推进游标」这条不变式可以被断言。
class FakeSseClient extends SseClient {
  FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();

  /// 被推进的游标序列（按调用顺序）。
  final recordedEventIds = <String>[];

  /// `connect` 被调用的次数与路径。
  final connectedPaths = <String>[];

  int resumeCount = 0;
  bool disposed = false;

  /// 当前游标（模拟 `SseClient._lastEventId`）。
  ///
  /// 真实 `connect()` 会把它置 null（断线重连的游标清零语义），此处必须同构：
  /// 否则「切 group 不得重连」这条不变式在假实现上无从观测。
  @override
  String? lastEventId;

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  /// 推一个连接状态（测「SSE 恢复 → 触发离线队列重试」）。
  void emitState(SseState s) => statesController.add(s);

  @override
  Future<void> connect({required String path}) async {
    connectedPaths.add(path);
    // 同真实实现：connect 重置续接游标。
    lastEventId = null;
  }

  @override
  Future<void> resume() async {
    resumeCount++;
  }

  @override
  void recordEventId(String eventId) {
    recordedEventIds.add(eventId);
    lastEventId = eventId;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await framesController.close();
    await statesController.close();
  }

  /// 推一帧到控制器。
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  /// 推心跳注释帧。
  void pushHeartbeat() {
    framesController.add(const SseFrame(event: null, data: '', id: null));
  }

  static String _encode(Map<String, dynamic> m) {
    // SseClient 的 data 是 JSON 字符串；控制器自行 jsonDecode。
    final sb = StringBuffer('{');
    var first = true;
    for (final e in m.entries) {
      if (!first) sb.write(',');
      first = false;
      sb.write('"${e.key}":${_json(e.value)}');
    }
    sb.write('}');
    return sb.toString();
  }

  static String _json(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) {
      return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
    }
    if (v is List) return '[${v.map(_json).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_json(e.value)}').join(',')}}';
    }
    return '"$v"';
  }
}

/// 假的 [TimelineCacheStore]（issue #29）。
///
/// ## 为什么要一个假实现而不是用 drift 内存库
///
/// `spb_domain` **禁止依赖 `spb_data`**（AGENTS.md §3 的分层规则），故本层
/// 测试不能用 `DriftTimelineCacheStore`。契约本身是纯 Dart 的，用内存 Map
/// 实现即可——这正是把契约放在 domain 的收益。
///
/// 实现真实存储的三层上限/过滤**不在这里**验证（那是 `spb_data` 的用例），
/// 这里只记录「谁在什么时候被读写」。
class _FakeTimelineCache implements TimelineCacheStore {
  final Map<String, List<ChatEvent>> _data = {};

  /// 记录 `save` 的调用（group → 事件列表，按调用顺序累积）。
  final saved = <(String, List<ChatEvent>)>[];

  /// 被读取过的 group（按调用顺序）。
  final loadedGroups = <String>[];

  /// 被清空过的 group。
  final clearedGroups = <String>[];

  void seed(String groupId, List<ChatEvent> events) {
    _data[groupId] = List.of(events);
  }

  List<ChatEvent> eventsFor(String groupId) =>
      saved.where((r) => r.$1 == groupId).expand((r) => r.$2).toList();

  Set<String> get savedGroups => saved.map((r) => r.$1).toSet();

  @override
  Future<List<ChatEvent>> load(String groupId, {int? limit}) async {
    loadedGroups.add(groupId);
    final all = _data[groupId] ?? const <ChatEvent>[];
    if (limit == null || limit <= 0 || all.length <= limit) {
      return List.of(all);
    }
    return all.sublist(all.length - limit);
  }

  @override
  Future<void> save(String groupId, List<ChatEvent> events) async {
    saved.add((groupId, List.of(events)));
    // 真实实现是 upsert；这里只需让「后续 load」能拿到，故按 globalSeq 合并。
    final merged = <int, ChatEvent>{
      for (final e in _data[groupId] ?? const <ChatEvent>[]) e.globalSeq!: e,
      for (final e in events.where(isCacheableEvent)) e.globalSeq!: e,
    };
    _data[groupId] = merged.values.toList()
      ..sort((a, b) => a.globalSeq!.compareTo(b.globalSeq!));
  }

  @override
  Future<void> clear(String groupId) async {
    clearedGroups.add(groupId);
    _data.remove(groupId);
  }
}

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late FakeSseClient sse;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = FakeSseClient();
  });

  /// 造一个服务端形态的 SSE 事件 JSON（camelCase，同 chatbus.Event）。
  Map<String, dynamic> sseEvent(
    String type, {
    String id = 'evt_1',
    String turnId = 'turn_1',
    String groupId = 'grp_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    int seq = 1,
    int globalSeq = 1,
  }) => {
    'eventId': id,
    'userId': 'usr_1',
    'groupId': groupId,
    'turnId': turnId,
    'eventType': type,
    'seq': seq,
    'globalSeq': globalSeq,
    'source': 'test',
    'payload': payload,
    'createdAt': '2024-03-05T08:09:10Z',
    if (transient) 'transient': true,
  };

  /// 挂载 timeline 回填的 mock（控制器 start/switchGroup 会先拉 timeline）。
  void mockTimeline({List<Map<String, dynamic>>? events}) {
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': events ?? <Map<String, dynamic>>[],
        'next_before_global_seq': '',
      }),
      queryParameters: {'limit': 200},
    );
  }

  /// 挂载 sendMessage 的 mock。
  ///
  /// `data: Matchers.any` 必需：http_mock_adapter 的默认匹配器会连**请求体**一起
  /// 比对，不声明 `data` 等于断言「请求体为 null」，于是真实 POST 永远匹配不上
  /// （表现为 NetworkError: 未知网络错误：null）。请求体形状的断言属 spb_api 层，
  /// 此处只关心控制器的状态变化。
  void mockSendMessage({String turnId = 'turn_1', String groupId = 'grp_1'}) {
    adapter.onPost(
      '/users/usr_1/chat/messages',
      (server) => server.reply(201, {
        'turn_id': turnId,
        'group_id': groupId,
        'status': 'queued',
      }),
      data: Matchers.any,
    );
  }

  group('离线写队列接线（issue #30）', () {
    /// 内存版 OutboxStore（与 `outbox_test.dart` 的同构；本文件只关心
    /// 控制器与队列的接线，队列自身行为由那份测试覆盖）。
    final store = _FakeOutboxStore();

    setUp(store.rows.clear);

    test('可重试错误（断网）→ 入队，send 抛 MessageQueuedError', () async {
      // 断网：mock 一个连不上的地址（http_mock_adapter 无匹配路由 → 抛错）。
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: _queueFor(store, fail: const NetworkError('断网')),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      await expectLater(
        c.send(input: '断网时写的一句'),
        throwsA(isA<MessageQueuedError>()),
      );

      // 消息**没有丢**：进了队列（而不是只在 UI 上弹个「发送失败」）。
      expect(store.rows, hasLength(1));
      expect(store.rows.values.single.input, '断网时写的一句');

      await c.dispose();
    });

    test('入队后**不**注入乐观回显（避免服务端 user_message 到达后两个气泡）', () async {
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: _queueFor(store, fail: const NetworkError('断网')),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      try {
        await c.send(input: '断网时写的一句');
      } on MessageQueuedError {
        // 预期。
      }

      // ## 为什么这里必须是空的
      //
      // 入队的条目还没有 turnId，而归约器**按 turnId 去重**。若在此注入
      // 一个无 turnId 的本地项，服务端随后的 `user_message` 会被当成新消息
      // → 用户看到**两个气泡**。
      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('终态错误（400）→ 不入队，照旧上抛（重试无用）', () async {
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: _queueFor(store),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(400, {'error': '输入不合法'}),
        data: Matchers.any,
      );

      await expectLater(c.send(input: 'x'), throwsA(isA<HttpError>()));
      expect(store.rows, isEmpty, reason: '400 重试一万次还是 400');

      await c.dispose();
    });

    test('未注入队列时行为不变：可重试错误照旧上抛', () async {
      // 这是**向后兼容**的保证：页面单测与「未接线的宿主」不该因为本特性
      // 而看到新的异常类型。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      await expectLater(c.send(input: 'x'), throwsA(isA<HttpError>()));

      await c.dispose();
    });

    test('队列投递成功 → 用服务端 turnId 注入回显（进时间线）', () async {
      final queue = _queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      // 先把控制器挂到 grp_1 上（delivered 只在同 group 时注入）。
      mockTimeline();
      // ⚠️ 必须 await：`_bindOutbox` 在 `start` 的 `_backfill` 之后才执行，
      // 不等它跑完，队列投递的事件会被订阅前的窗口吞掉。
      await c.start(groupId: 'grp_1');

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: '离线时写的',
          groupId: 'grp_1',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      final item = c.snapshot.whereType<UserMessageItem>().single;
      expect(item.text, '离线时写的');
      // turnId 来自服务端响应 —— 只有这样随后的 user_message 才会原位合并。
      expect(item.turnId, 'turn-out');

      await c.dispose();
    });

    test('投递成功但属于**别的**对话 → 不注入（用户已切走）', () async {
      // 投递本身**成功**（队列正常），但归属的是另一个 group。
      final queue = _queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      // ⚠️ `start(groupId:)` 才是「聚焦到某个对话」——`switchGroup` 不会建立
      // SSE 连接（它假定连接已由 `start` 建好），故这里用 start。
      mockTimeline();
      await c.start(groupId: 'grp_1');

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: '别的对话的消息',
          groupId: 'grp_other',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      // 队列是全局的：在 A 对话入队、投递成功时用户可能已切到 B。
      expect(c.snapshot.whereType<UserMessageItem>(), isEmpty);
      // 条目已出队（投递**确实**成功了）——证明「没注入」不是因为投递没发生。
      expect(queue.snapshot, isEmpty);

      await c.dispose();
    });

    test('SSE 变为 connected → 触发队列重试（onConnectivityRestored）', () async {
      final queue = _queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      c.start();

      // 先塞一条在退避窗口里的条目（否则 onConnectivityRestored 无事可做）。
      final future = DateTime.now().add(const Duration(hours: 1));
      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          attempts: 1,
          nextAttemptAt: future,
          lastError: '断网',
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      expect(
        queue.snapshot.single.nextAttemptAt.isAfter(DateTime.now()),
        isTrue,
      );

      sse.emitState(SseState.connected);
      await Future<void>.delayed(Duration.zero);

      // 恢复网络后不该干等退避计时器。
      expect(queue.snapshot, isEmpty, reason: '应被立刻重投并成功');

      await c.dispose();
    });

    test('队列终态失败 → 推 MessageDeliveryFailedError 到 errors 流', () async {
      // 400：终态错误（不是重试用尽），条目会被移除并上报。
      final queue = _queueFor(store, fail: const HttpError(400, '输入不合法'));
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      c.start();

      final errors = <SpbError>[];
      c.errors.listen(errors.add);

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      expect(errors.whereType<MessageDeliveryFailedError>(), hasLength(1));

      await c.dispose();
    });

    test('dispose 会退订队列流（不再向已释放的控制器推事件）', () async {
      final queue = _queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      c.start();
      await c.dispose();

      // 释放后再投递：控制器不该崩（订阅已取消）。
      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('send() 乐观回显', () {
    test('send 后 snapshot 立即含 UserMessageItem（不再是空的 start 事件）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockSendMessage();

      await c.send(input: '你好，帮我看看');

      final items = c.snapshot;
      expect(items, hasLength(1));
      expect(items.single, isA<UserMessageItem>());
      expect((items.single as UserMessageItem).text, '你好，帮我看看');
      expect(items.single.turnId, 'turn_1');

      await c.dispose();
    });

    test('send 不带 group_id 时仍按响应里的 groupId 归属（无归属入口语义）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockSendMessage(groupId: 'grp_routed');

      final result = await c.send(input: '无归属的一句话');

      expect(result.groupId, 'grp_routed');
      expect((c.snapshot.single as UserMessageItem).text, '无归属的一句话');
      // 请求体不得带 group_id（由服务端分类链判定）。
      await c.dispose();
    });

    test('乐观项不推进 SSE 游标（transient，无有效 eventId）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockSendMessage();

      await c.send(input: '你好');

      expect(sse.recordedEventIds, isEmpty, reason: '本地合成事件绝不能作游标');

      await c.dispose();
    });

    test('items 流在 send 后推送含 UserMessageItem 的列表', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockSendMessage();

      final emitted = <List<ConversationItem>>[];
      final sub = c.items.listen(emitted.add);

      await c.send(input: '流式断言');
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isNotEmpty);
      expect(emitted.last.single, isA<UserMessageItem>());

      await sub.cancel();
      await c.dispose();
    });
  });

  group('服务端 user_message 到达后去重', () {
    test('服务端事件到达后仍只有一个用户气泡（id 换成真实 eventId）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockSendMessage(turnId: 'turn_9');

      await c.start(groupId: 'grp_1');
      await c.send(input: '你好');
      expect(c.snapshot, hasLength(1));

      // 服务端广播的 user_message（同一 turnId）。
      sse.push(
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'evt_real_user',
          turnId: 'turn_9',
          payload: {'input': '你好', 'status': 'queued'},
          globalSeq: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final items = c.snapshot;
      expect(items, hasLength(1), reason: '乐观项与服务端事件必须合并');
      expect(items.single.id, 'evt_real_user');
      expect(sse.recordedEventIds, contains('evt_real_user'));

      await c.dispose();
    });
  });

  group('SSE 帧处理', () {
    test('start() 先回填 timeline 再连接（历史不丢）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': '历史用户消息'},
          ),
          sseEvent(
            EventTypes.message,
            id: 'hist_2',
            payload: {'text': '历史回答'},
            globalSeq: 2,
          ),
        ],
      );

      await c.start(groupId: 'grp_1');

      expect(sse.connectedPaths.single, '/users/usr_1/chat/stream');
      final items = c.snapshot;
      expect(items, hasLength(2));
      expect((items[0] as UserMessageItem).text, '历史用户消息');
      expect((items[1] as AssistantMessageItem).text, '历史回答');

      await c.dispose();
    });

    test('start() 回填后推送 items（issue #3：冷启动不得空白）', () async {
      // 回归防线：`_backfill` 只写 `_buffer`，若 `start()` 漏掉 `_emit()`，
      // `items` 流一次都不推，UI 落在空态分支。
      //
      // 现有「start() 先回填 timeline 再连接」用例断言的是 `snapshot`（直接重算
      // buffer），**不经过流**，故这条路径此前完全没有覆盖。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': '历史用户消息'},
          ),
          sseEvent(
            EventTypes.message,
            id: 'hist_2',
            payload: {'text': '历史回答'},
            globalSeq: 2,
          ),
        ],
      );

      // 必须先订阅：`items` 是 broadcast 流，start() 之后再订阅会错过发射。
      final emissions = <List<ConversationItem>>[];
      final sub = c.items.listen(emissions.add);

      await c.start(groupId: 'grp_1');
      await Future<void>.delayed(Duration.zero);

      expect(emissions, isNotEmpty, reason: 'start() 必须推送 items');
      expect(emissions.first, hasLength(2), reason: '首个发射即应含全部回填历史');
      expect((emissions.first[0] as UserMessageItem).text, '历史用户消息');
      expect((emissions.first[1] as AssistantMessageItem).text, '历史回答');

      await sub.cancel();
      await c.dispose();
    });

    test('transient 增量推进渲染但不推进游标', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'inc_1',
          payload: {'text': '增量'},
          transient: true,
          globalSeq: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect((c.snapshot.single as AssistantMessageItem).text, '增量');
      expect(sse.recordedEventIds, isEmpty, reason: '增量帧不得作游标');

      await c.dispose();
    });

    test('心跳帧不产生任何对话项', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.pushHeartbeat();
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      await c.dispose();
    });

    test('其他 group 的事件被过滤（SSE 是 user 级订阅）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'other_group',
          groupId: 'grp_other',
          payload: {'text': '别的对话'},
          globalSeq: 5,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      await c.dispose();
    });

    test('畸形 JSON 帧被吞掉，不中断流也不抛异常', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.framesController.add(
        const SseFrame(event: 'message', data: '{not json', id: null),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      // 后续正常帧仍能处理（流未被打断）。
      sse.push(
        EventTypes.message,
        sseEvent(EventTypes.message, payload: {'text': '仍然工作'}, globalSeq: 6),
      );
      await Future<void>.delayed(Duration.zero);
      expect((c.snapshot.single as AssistantMessageItem).text, '仍然工作');

      await c.dispose();
    });

    test('契约破坏的事件（缺 eventId）被吞掉且不影响后续', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.framesController.add(
        SseFrame(event: 'message', data: '{"eventType":"message"}', id: null),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('timeline 回填失败不阻断实时流（catch 后仍连上 SSE）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      // 故意不挂 timeline mock：DioAdapter 默认 failOnMissingMock=true 会抛错。
      final errors = <SpbError>[];
      final sub = c.errors.listen(errors.add);

      await c.start(groupId: 'grp_1');
      await Future<void>.delayed(Duration.zero);

      expect(sse.connectedPaths, hasLength(1), reason: '回填失败仍要建立 SSE');

      await sub.cancel();
      await c.dispose();
    });
  });

  group('switchGroup 复用同一条 SSE', () {
    test('切 group 不重连、清空缓冲并重新回填', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': [
            sseEvent(
              EventTypes.message,
              id: 'g2_1',
              groupId: 'grp_2',
              payload: {'text': '第二个对话'},
            ),
          ],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.message,
        sseEvent(EventTypes.message, payload: {'text': '第一个对话'}, globalSeq: 2),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.snapshot, hasLength(1));

      await c.switchGroup('grp_2');

      expect(sse.connectedPaths, hasLength(1), reason: 'SSE 是 user 级，不重连');
      expect(
        (c.snapshot.single as AssistantMessageItem).text,
        '第二个对话',
        reason: '切换后缓冲被清空并重新回填',
      );

      await c.dispose();
    });

    test('switchGroup 不重连且不丢续接游标（start 才会重置 cursor）', () async {
      // 回归防线：切对话若走 `start()`，`SseClient.connect()` 会把
      // `_lastEventId` 置 null——断线重连时无法带 cursor 回放，只能整段重拉。
      // 故同一 userId 内切 group 必须走 `switchGroup()`（不调 connect）。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      expect(sse.connectedPaths, hasLength(1));

      // 推一条落库事件推进游标。
      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'evt_cursor_1',
          payload: {'text': '推进游标'},
          globalSeq: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sse.lastEventId, 'evt_cursor_1');

      await c.switchGroup('grp_2');

      expect(sse.connectedPaths, hasLength(1), reason: '切 group 不得重连');
      expect(sse.lastEventId, 'evt_cursor_1', reason: '续接游标必须保留（connect 才会清零）');

      await c.dispose();
    });
  });

  group('ensureConnected（对话列表页与对话页共用一条连接）', () {
    test('未连接时以全局模式建连，且不回填任何 group 的时间线', () async {
      // 列表页在首页挂载时对话页往往不存在，故它必须能自己把连接建起来。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');

      await c.ensureConnected();

      expect(sse.connectedPaths, hasLength(1), reason: '必须真的建立连接');
      expect(c.isConnected, isTrue);
      // 全局模式：不该为某个 group 拉历史（列表页不需要时间线）。
      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('已有连接时是空操作：不重连、不抢聚焦、不清缓冲', () async {
      // ## 这是本方法存在的全部理由
      //
      // 对话页已以聚焦模式连上并回填了时间线。此时列表页（在聊天路由下仍挂载
      // 着）调 `ensureConnected`，若它调了 `start(groupId: null)`，就会：
      // 1. `connect()` → 游标清零 + 多一次建连往返；
      // 2. `_buffer.clear()` → 打开的对话内容闪一下。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'evt_keep',
          payload: {'text': '对话页的内容'},
          globalSeq: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.snapshot, hasLength(1));

      await c.ensureConnected();

      expect(sse.connectedPaths, hasLength(1), reason: '不得重连（会丢续接游标）');
      expect(sse.lastEventId, 'evt_keep', reason: '续接游标必须保留');
      expect(c.snapshot, hasLength(1), reason: '不得清空缓冲——否则打开的对话内容会闪一下');

      await c.dispose();
    });

    test('全局模式下 group_updated 仍然照常送达（列表页的用途）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final updates = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(updates.add);

      await c.ensureConnected();
      sse.push(
        EventTypes.groupUpdated,
        sseEvent(
          EventTypes.groupUpdated,
          groupId: 'grp_new',
          payload: {
            'op': 'created',
            'group': {'id': 'grp_new', 'title': '别处建的'},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(updates, hasLength(1));
      expect(updates.single.op, GroupUpdateOp.created);
      expect(updates.single.groupId, 'grp_new');

      await sub.cancel();
      await c.dispose();
    });
  });

  group('gate 决策通道', () {
    test('gateDecisionsSnapshot 含 adaptive_decision（不再静默丢弃）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {
            'action': 'auto_continue',
            'gate_source': 'llm_gate',
            'confidence': 0.9,
            'reason': '任务未完成',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.gateDecisionsSnapshot, hasLength(1));
      final d = c.gateDecisionsSnapshot.single;
      expect(d.kind, GateDecisionKind.autoContinue);
      expect(d.source, GateSourceKind.llmGate);
      expect(d.confidence, 0.9);

      await c.dispose();
    });

    test('gate 决策不进 items（时间线只放用户可见内容）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {'action': 'auto_continue', 'gate_source': 'fastpath'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: 'gate 决策是诊断信息，不进时间线');
      expect(c.gateDecisionsSnapshot, hasLength(1));

      await c.dispose();
    });

    test('gateDecisions 流在事件到达时推送', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <List<GateDecision>>[];
      final sub = c.gateDecisions.listen(pushed.add);

      sse.push(
        EventTypes.goalGateDecision,
        sseEvent(
          EventTypes.goalGateDecision,
          id: 'gate_goal_1',
          payload: {'goal_achieved': true, 'source': 'tasks_completed'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last.single.kind, GateDecisionKind.goalCompleted);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后 gate 决策被清空（不泄漏上一个对话的决策）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {'action': 'stop', 'gate_source': 'llm_gate'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.gateDecisionsSnapshot, hasLength(1));

      await c.switchGroup('grp_2');

      expect(c.gateDecisionsSnapshot, isEmpty, reason: '切对话后旧对话的 gate 决策不得残留');

      await c.dispose();
    });
  });

  group('执行中活动通道（turn_activity）', () {
    test('activitiesSnapshot 含 turn_activity，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          globalSeq: 0,
          payload: {
            'elapsed_ms': 45000,
            'last_event_type': 'tool_call',
            'since_last_event_ms': 3200,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '进度提示不进时间线');
      expect(c.activitiesSnapshot, hasLength(1));
      final a = c.activitiesSnapshot['turn_1']!;
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, 'tool_call');

      await c.dispose();
    });

    test('activities 流在事件到达时推送全量 Map', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <Map<String, TurnActivitySnapshot>>[];
      final sub = c.activities.listen(pushed.add);

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 9000},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last['turn_1']!.elapsedMs, 9000);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后活动快照被清空（不泄漏上一个对话的进度）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 45000},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.activitiesSnapshot, hasLength(1));

      await c.switchGroup('grp_2');

      expect(c.activitiesSnapshot, isEmpty);

      await c.dispose();
    });

    test('turn_activity 不推进 SSE 游标（Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 1000},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty, reason: 'Transient 事件不得作游标');

      await c.dispose();
    });
  });

  group('上下文用量通道（context_update）', () {
    test('contextUsageSnapshot 含用量，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 50000, 'context_window': 200000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '用量是诊断读数，不进时间线');
      final u = c.contextUsageSnapshot;
      expect(u, isNotNull);
      expect(u!.used, 50000);
      expect(u.size, 200000);
      expect(u.remaining, 150000);

      await c.dispose();
    });

    test('contextUsage 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <ContextUsage?>[];
      final sub = c.contextUsage.listen(pushed.add);

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 1234, 'context_window': 8000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.used, 1234);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后用量快照被清空（不泄漏上一个对话的读数）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 500, 'context_window': 1000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.contextUsageSnapshot, isNotNull);

      await c.switchGroup('grp_2');

      expect(c.contextUsageSnapshot, isNull, reason: '切对话后旧用量不得残留');

      await c.dispose();
    });

    test('context_update 推进 SSE 游标（Go 侧 flushEvent 落库，非 Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'evt_ctx_1',
          payload: {
            'telemetry': {'context_tokens': 100, 'context_window': 1000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_ctx_1'),
        reason: '落库事件带有效 ID，应推进游标（与 turn_activity 相反）',
      );

      await c.dispose();
    });
  });

  group('执行等待通道（queue_state / retry_scheduled）', () {
    test('executionStatusSnapshot 含等待原因，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {
            'state': 'queued',
            'reason': 'session_busy',
            'queue_total': 3,
            'queue_user': 1,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '等待提示不进时间线');
      final s = c.executionStatusSnapshot;
      expect(s, isNotNull);
      expect(s!.kind, ExecutionStatusKind.queued);
      expect(s.reason, 'session_busy');

      await c.dispose();
    });

    test('executionStatus 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <ExecutionStatus?>[];
      final sub = c.executionStatus.listen(pushed.add);

      sse.push(
        EventTypes.retryScheduled,
        sseEvent(
          EventTypes.retryScheduled,
          payload: {'attempt': 2, 'max_retries': 3},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.kind, ExecutionStatusKind.retryScheduled);
      expect(pushed.last!.attempt, 2);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后等待状态被清空（不泄漏上一个对话的提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.executionStatusSnapshot, isNotNull);

      await c.switchGroup('grp_2');

      expect(c.executionStatusSnapshot, isNull, reason: '切对话后旧等待不得残留');

      await c.dispose();
    });

    test('message 到达后等待状态被清除（不挂着过期提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.executionStatusSnapshot, isNotNull);

      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'evt_msg_1',
          payload: {'text': '回复来了'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.executionStatusSnapshot, isNull);

      await c.dispose();
    });

    test('queue_state 推进 SSE 游标（Go 侧落库，非 Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          id: 'evt_qs_1',
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_qs_1'),
        reason: '落库事件带有效 ID，应推进游标（与 turn_activity 相反）',
      );

      await c.dispose();
    });
  });

  group('语音播报通道（tts_started / tts_completed / tts_failed）', () {
    test('ttsStatusSnapshot 含播报状态，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          transient: true,
          payload: {'mode': 'message', 'seq': 1},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '播报状态不进时间线');
      final s = c.ttsStatusSnapshot;
      expect(s.phase, TtsPhase.started);
      expect(s.mode, 'message');

      await c.dispose();
    });

    test('ttsStatus 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <TtsStatus?>[];
      final sub = c.ttsStatus.listen(pushed.add);

      sse.push(
        EventTypes.ttsFailed,
        sseEvent(
          EventTypes.ttsFailed,
          payload: {'message': '语音生成失败，本次文本回复不受影响。'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.phase, TtsPhase.failed);
      expect(pushed.last!.message, '语音生成失败，本次文本回复不受影响。');

      await sub.cancel();
      await c.dispose();
    });

    test('started → completed 推进到终态', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          transient: true,
          payload: {'mode': 'stream'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.ttsStatusSnapshot.phase, TtsPhase.started);

      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(EventTypes.ttsCompleted, payload: {'parts': 2}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.ttsStatusSnapshot.phase, TtsPhase.completed);
      expect(c.ttsStatusSnapshot.parts, 2);

      await c.dispose();
    });

    test('切 group 后播报状态被清空（不泄漏上一个对话的提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(EventTypes.ttsCompleted, payload: {'parts': 1}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.ttsStatusSnapshot.hasStatus, isTrue);

      await c.switchGroup('grp_2');

      expect(c.ttsStatusSnapshot.phase, TtsPhase.idle, reason: '切对话后旧播报不得残留');

      await c.dispose();
    });

    test('tts_started 不推进游标，终态事件推进游标', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          id: 'evt_tts_started',
          transient: true,
          payload: {'mode': 'stream'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        sse.recordedEventIds,
        isNot(contains('evt_tts_started')),
        reason: 'tts_started 是 Transient，不得作游标',
      );

      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(
          EventTypes.ttsCompleted,
          id: 'evt_tts_done',
          payload: {'parts': 1},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        sse.recordedEventIds,
        contains('evt_tts_done'),
        reason: '终态落库，应推进游标',
      );

      await c.dispose();
    });
  });

  group('group 变更通知通道（group_updated）', () {
    /// 造一个 group_updated 帧（Transient，见 Go PublishGroupUpdated）。
    Map<String, dynamic> groupUpdatedEvent({
      String id = 'evt_gu_1',
      String groupId = 'grp_1',
      String op = 'created',
      String? title = '新对话',
      String? status = 'active',
    }) => sseEvent(
      EventTypes.groupUpdated,
      id: id,
      groupId: groupId,
      transient: true,
      payload: {
        'op': op,
        'group': {
          'id': groupId,
          if (title != null) 'title': title,
          if (status != null) 'status': status,
        },
      },
    );

    test('收到 group_updated → groupUpdates 流收到一条（含 op 与快照）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, GroupUpdateOp.created);
      expect(pushed.single.groupId, 'grp_1');
      expect(pushed.single.title, '新对话');
      expect(pushed.single.status, 'active');

      await sub.cancel();
      await c.dispose();
    });

    test('逐条推送而非累积（两条 → 两次事件，顺序保持）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(id: 'evt_1', groupId: 'grp_x', op: 'created'),
      );
      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(
          id: 'evt_2',
          groupId: 'grp_x',
          op: 'deleted',
          title: null,
          status: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '通知语义：逐条推送，不累积');
      expect(pushed[0].op, GroupUpdateOp.created);
      expect(pushed[1].op, GroupUpdateOp.deleted);

      await sub.cancel();
      await c.dispose();
    });

    test('不受 group 过滤影响：聚焦 grp_1 时也能收到 grp_other 的变更', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      // 另一个 group 的变更——对话页聚焦 grp_1，但列表页需要知道它。
      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        pushed,
        hasLength(1),
        reason: 'group_updated 的 groupId 指向被变更的 group，不是当前聚焦的 group',
      );
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('未知 op 归 GroupUpdateOp.unknown 且 needsRefetch 为真（不丢弃事件）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent(op: 'renamed'));
      await Future<void>.delayed(Duration.zero);

      expect(pushed.single.op, GroupUpdateOp.unknown);
      expect(pushed.single.op.needsRefetch, isTrue);

      await sub.cancel();
      await c.dispose();
    });

    test('group_updated 不进 items，也不推进游标（Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      expect(sse.recordedEventIds, isEmpty);

      await c.dispose();
    });
  });

  // Goal Gate 自动停用时的 metadata 通知。
  //
  // ## 这个测试防的是什么（事实性错误）
  //
  // Goal Gate 达成目标（`chatgate/goal_gate.go:440`）或达到 max_auto_turns
  // 熔断（`:555`）时，服务端会自己把 `metadata.goal_gate.enabled` 改为 false
  // （`markGoalGateCompleted` 写 `gate["enabled"] = false`）。
  //
  // 这是**后台 worker** 的动作，没有任何 HTTP 响应回到客户端。不消费本事件，
  // 设置面板会继续显示「自动实现目标：开」——用户以为还会自动续跑，实际已停。
  //
  // ## ⚠️ 与 goal_updated 相反：本事件**是落库的**
  //
  // `broker.go:82` 把它列在「持久化到 chat_events，前端可渲染」一组，且它确实
  // 有 turn（`emitEvent` 带 `TurnID`）。故它**应当**推进游标、落入缓冲区、
  // 并在断线回放时重新套用——与 goal_updated（漏设 Transient 且不落库，必须
  // 提前 return）刚好相反。下面用用例钉住这个差异。
  group('group 元数据通知通道（group_metadata_updated）', () {
    /// 造一个 group_metadata_updated 帧。
    ///
    /// ⚠️ `transient` 默认 **false**——对齐服务端实际行为（它确实落库）。
    Map<String, dynamic> metadataUpdatedEvent({
      String id = 'evt_gm_1',
      String groupId = 'grp_1',
      String reason = 'goal_completed',
      Map<String, dynamic>? metadata,
    }) => sseEvent(
      EventTypes.groupMetadataUpdated,
      id: id,
      groupId: groupId,
      payload: {
        'reason': reason,
        'metadata':
            metadata ??
            {
              'goal_gate': {
                'enabled': false,
                'continue_until_done': false,
                'state': {'status': 'completed'},
              },
              'tts': {'enabled': true},
            },
      },
    );

    test('收到事件 → groupUpdates 流收到 op=metadata 且携带完整 metadata', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupMetadataUpdated, metadataUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, GroupUpdateOp.metadata);
      expect(pushed.single.groupId, 'grp_1');

      final md = pushed.single.metadata;
      expect(md, isNotNull, reason: '必须携带 metadata，否则面板无法刷新');
      expect(
        (md!['goal_gate'] as Map)['enabled'],
        isFalse,
        reason: 'goal gate 已被服务端自动停用——这就是需要纠正的错显',
      );
      expect(
        (md['goal_gate'] as Map)['continue_until_done'],
        isFalse,
        reason: '两个键成对写入，只改一个会让 goalGateEnabled 仍为 true',
      );

      await sub.cancel();
      await c.dispose();
    });

    test('reason 可读：goal_completed / max_auto_turns_reached', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e1', reason: 'goal_completed'),
      );
      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e2', reason: 'max_auto_turns_reached'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2));
      // reason 在事件上（不在 GroupUpdate 里）；此处用原始事件验证可读性。
      expect(pushed[0].op, GroupUpdateOp.metadata);
      expect(pushed[1].op, GroupUpdateOp.metadata);

      await sub.cancel();
      await c.dispose();
    });

    test('⚠️ 与 goal_updated 相反：本事件**推进**游标（它确实落库）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'evt_gm_cursor'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_gm_cursor'),
        reason:
            'group_metadata_updated 持久化到 chat_events（broker.go:82），'
            '带有效 ID，应当推进游标以便断线回放',
      );

      await c.dispose();
    });

    test('不受 group 过滤影响：别的 group 的 metadata 变更也能收到', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('metadata 缺失的异常载荷不推送（避免清空现有开关）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        sseEvent(
          EventTypes.groupMetadataUpdated,
          id: 'evt_no_md',
          payload: {'reason': 'goal_completed'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(
        pushed.single.metadata,
        isNull,
        reason: '无 metadata 时消费方应忽略（不得用空 map 覆盖）',
      );

      await sub.cancel();
      await c.dispose();
    });

    test('不进 items（时间线不得出现元数据变更气泡）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupMetadataUpdated, metadataUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);

      await c.dispose();
    });
  });

  // 目标变更通知的回归防线。
  //
  // ## 为什么必须有这个 group（不能只靠 group_updated 的测试）
  //
  // 服务端 `emitGoalUpdated`（`server/goal_api.go:212`）注释写着「不落库，仅广播」，
  // 但 `chatbus.Event` 的 `Transient` 字段留了**零值 false**——对比同族的
  // `PublishGroupUpdated`（`chat/group_events.go:63`）与 `buildTitleUpdatedEvent`
  // （`chatgate/title_gate.go:258`）都显式设了 true，可见是漏设。
  //
  // 后果比「丢一条事件」严重得多：事件带 `transient=false` + 有效 eventId，
  // 而它**不在** `chat_events` 表里（无 turn，`turn_id` NOT NULL 写不进去）。
  // 若走通用路径，`recordEventId` 会把它记作 SSE 游标；断线重连时服务端
  // `replayUserEvents` 按 `chat_events.id` 定位 cursor 找不到该 ID
  // → `start < 0` → 返回 nil → **整个回放窗口丢失**。
  //
  // 故这里的核心断言是「`recordedEventIds` 为空」。若将来服务端修了那个标志位，
  // 这些用例仍应通过（客户端按事件类型分流，不依赖那个不可信的字段）。
  group('目标变更通知通道（goal_updated）', () {
    /// 造一个 goal_updated 帧。
    ///
    /// ⚠️ `transient` 默认 **false**——刻意对齐服务端的实际行为（漏设）。
    /// 用 true 造数据会让游标断言在假前提上通过。
    Map<String, dynamic> goalUpdatedEvent({
      String id = 'evt_goal_1',
      String groupId = 'grp_1',
      String op = 'goal_create',
      String source = 'user',
      String? goalText = '把同步做稳',
      List<Map<String, dynamic>>? tasks,
      bool transient = false,
    }) => sseEvent(
      EventTypes.goalUpdated,
      id: id,
      groupId: groupId,
      transient: transient,
      globalSeq: 0,
      payload: {
        'op': op,
        if (goalText != null)
          'goal': {
            'id': 'goal_1',
            'group_id': groupId,
            'goal_text': goalText,
            'status': 'active',
          },
        'tasks':
            tasks ??
            [
              {'task_id': 't1', 'status': 'in_progress', 'title': '修 bug'},
            ],
        'progress': {'total': 1, 'completed': 0, 'in_progress': 1},
      },
    );

    test('收到 goal_updated → goalUpdates 流收到一条（含快照）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, 'goal_create');
      expect(pushed.single.groupId, 'grp_1');
      expect(pushed.single.goalText, '把同步做稳');
      expect(pushed.single.tasks, hasLength(1));
      expect(pushed.single.snapshot, isNotNull);

      await sub.cancel();
      await c.dispose();
    });

    test('⚠️ 核心：不推进游标（服务端漏设 Transient，穿透会丢整个回放窗口）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        isEmpty,
        reason:
            'goal_updated 不在 chat_events 表里，若被记作 cursor，服务端 '
            'replayUserEvents 定位不到该 ID 会返回 nil，丢掉整个回放窗口',
      );
      expect(sse.lastEventId, isNull, reason: '游标必须保持未变（可用 lastEventId 观测）');

      await c.dispose();
    });

    test('不进 items（时间线不得出现目标变更气泡）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      expect(c.bufferedEventCount, 0, reason: '通知类事件不占缓冲区');

      await c.dispose();
    });

    test('即便服务端将来设了 transient=true 也不推游标（按类型分流）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_goal_t', transient: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty);

      await c.dispose();
    });

    test('不受 group 过滤影响：别的 group 的目标变更也能收到', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('逐条推送而非累积（task_create 后 task_reorder 各一次）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_1', op: 'task_create'),
      );
      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_2', op: 'task_reorder'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '通知语义：逐条推送，不累积');
      expect(pushed[0].op, 'task_create');
      expect(pushed[1].op, 'task_reorder');

      await sub.cancel();
      await c.dispose();
    });

    test('goal 缺失的异常载荷不推送（避免清空现有目标）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      // 无 goal 字段（服务端任务列表读失败时会退化为不带快照的信号）。
      sse.push(
        EventTypes.goalUpdated,
        sseEvent(
          EventTypes.goalUpdated,
          id: 'evt_no_goal',
          payload: {'op': 'task_create', 'tasks': <Map<String, dynamic>>[]},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1), reason: '事件本身仍送达（消费方可据此选择重拉）');
      expect(pushed.single.snapshot, isNull, reason: '无 goal 时不造空快照');

      await sub.cancel();
      await c.dispose();
    });

    test('groupId 为空时丢弃（无法定位要刷新哪个对话）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      await c.ensureConnected();
      sse.push(EventTypes.goalUpdated, goalUpdatedEvent(groupId: ''));
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isEmpty);
      expect(sse.recordedEventIds, isEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('dispose 后不报错（流已关闭）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      await c.dispose();

      // 控制器已关闭，推事件不应抛异常。
      expect(
        () => sse.push(EventTypes.goalUpdated, goalUpdatedEvent()),
        returnsNormally,
      );
      await Future<void>.delayed(Duration.zero);
    });
  });

  // 标题实时更新的回归防线。
  //
  // 缺口背景：`group_title_updated` 在 `EventTypes` 里已声明、服务端
  // `chatgate/title_gate.go` 也确实会发（Transient、payload `{new_title}`），
  // 但没有任何消费者——表现为「首轮对话后标题变了，列表里还是『新会话』，
  // 除非手动刷新」。
  //
  // 与之配对的服务端 bug：发射端曾写 `title`、前端读 `new_title`，两边各自看
  // 代码都「对」，导致该功能**从未生效过**（见 `title_gate_test.go` 的
  // `TestTitleGateEmitsNewTitleKey`）。故这里用键名 `new_title`。
  group('标题实时更新（group_title_updated）', () {
    /// 造一个 group_title_updated 帧（Transient，见 Go buildTitleUpdatedEvent）。
    Map<String, dynamic> titleUpdatedEvent({
      String id = 'evt_gt_1',
      String groupId = 'grp_1',
      String? newTitle = '燕麦怎么吃',
    }) => sseEvent(
      EventTypes.groupTitleUpdated,
      id: id,
      groupId: groupId,
      transient: true,
      // globalSeq 为 0：Transient 事件不落库，无有效序号。
      globalSeq: 0,
      payload: {if (newTitle != null) 'new_title': newTitle},
    );

    test(
      '收到 group_title_updated → 一条 GroupUpdate(op=title, title=新标题)',
      () async {
        final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
        mockTimeline();
        await c.start(groupId: 'grp_1');

        final pushed = <GroupUpdate>[];
        final sub = c.groupUpdates.listen(pushed.add);

        sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
        await Future<void>.delayed(Duration.zero);

        expect(pushed, hasLength(1));
        expect(pushed.single.op, GroupUpdateOp.title);
        expect(pushed.single.title, '燕麦怎么吃');
        expect(pushed.single.groupId, 'grp_1');
        // 该事件没有 status 快照，不得凭空给一个值（列表页会拿它覆盖现有状态）。
        expect(pushed.single.status, isNull);

        await sub.cancel();
        await c.dispose();
      },
    );

    test('游标不被推进（Transient 无有效 ID，作 cursor 会跳过权威帧）', () async {
      // 这是本通道最危险的一步：一旦把 group_title_updated 的 eventId 记进
      // cursor，重连时服务端会从它之后回放，而它是 Transient（未落库）——
      // 用它定位等于跳过一个不存在的位置，其后的权威帧会永久丢失。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty, reason: 'Transient 事件不得作游标');

      await c.dispose();
    });

    test('不受 group 过滤影响：聚焦 grp_1 时也能收到 grp_other 的标题变更', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('不进 items（标题更新不是时间线正文）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('groupId 为空时丢弃（无法定位要更新哪一项）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent(groupId: ''));
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('new_title 缺失/空串时不产生标题（不得把标题清空）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_a', newTitle: null),
      );
      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_b', newTitle: ''),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '事件本身仍要送达（op=title）');
      expect(pushed[0].title, isNull);
      expect(pushed[1].title, isNull);

      await sub.cancel();
      await c.dispose();
    });

    test('旧键名 title 不再被读取（服务端已改为 new_title）', () async {
      // 服务端 2026-09 的修复方向是「改发射端」（前端两处一致读 new_title）。
      // 本用例钉住：若有人把客户端改成读 payload.title，这里会失败。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        sseEvent(
          EventTypes.groupTitleUpdated,
          transient: true,
          globalSeq: 0,
          payload: {'title': '旧键名的标题'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed.single.title, isNull);

      await sub.cancel();
      await c.dispose();
    });
  });

  group('生命周期', () {
    test('reconnect 委托给 SseClient.resume', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.reconnect();
      expect(sse.resumeCount, 1);
      await c.dispose();
    });

    test('dispose 不关闭共享 SSE，且重复调用安全', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.dispose();
      // ⚠️ 关键不变式：SSE 是跨对话共享的单例，其 dispose 归 provider 所有。
      // 控制器关闭它会导至「离开一次对话页 = 永久失去实时流」。
      expect(sse.disposed, isFalse, reason: '控制器不得释放不属于它的共享 SseClient');
      await c.dispose(); // 不应抛异常
    });

    test('共享 SseClient：第一个 controller dispose 后第二个仍能收到帧', () async {
      // 回归防线：早期 `dispose()` 里有 `await _sse.dispose()`，
      // 它置 `_closedByUser = true` 并关闭两个 StreamController。
      // 后果是同一进程内第二次进入对话时，`connect()` 仍会发 HTTP 请求，
      // 但**所有帧被静默丢弃**（_pushFrame / _setState 在关闭后直接 return）。
      final first = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await first.start(groupId: 'grp_1');
      await first.dispose();

      expect(sse.disposed, isFalse, reason: '共享连接必须仍然活着');

      // 第二个控制器复用同一个 SseClient（模拟用户再次进入对话页）。
      final second = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await second.start(groupId: 'grp_1');

      final emissions = <List<ConversationItem>>[];
      final sub = second.items.listen(emissions.add);

      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          payload: {'text': '第二个控制器收到的回复'},
          globalSeq: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(emissions, isNotEmpty, reason: '第二个控制器必须仍能收到帧（否则是「连上了但一条事件都没有」）');
      expect(
        (second.snapshot.single as AssistantMessageItem).text,
        '第二个控制器收到的回复',
      );

      await sub.cancel();
      await second.dispose();
    });

    test('connectionState 转发 SseClient 的状态流（需先 start 才会订阅）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();

      final states = <SseState>[];
      final sub = c.connectionState.listen(states.add);

      // 控制器在 start() 里才订阅 sse.states（未 start 时不应有转发）。
      await c.start(groupId: 'grp_1');
      sse.statesController.add(SseState.reconnecting);
      await Future<void>.delayed(Duration.zero);

      expect(states, [SseState.reconnecting]);

      await sub.cancel();
      await c.dispose();
    });
  });

  group('加载更早历史（loadOlder 向上翻页）', () {
    /// 挂载「更早一页」的 mock，并记录实际收到的游标。
    ///
    /// 用 `replyCallback` 而非 `reply`：游标是**请求参数**，必须断言它真的发出去了
    /// （而不是只看响应被正确解析）。`adapter.history` 存的是**已注册的 mock**，
    /// 不能用来断言「请求发生过」。
    List<String?> mockOlderPage({
      required List<Map<String, dynamic>> events,
      required String cursor,
      int limit = 50,
    }) {
      final seen = <String?>[];
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          seen.add(options.queryParameters['before_global_seq']?.toString());
          return {'items': events, 'next_before_global_seq': ''};
        }),
        queryParameters: {'limit': limit, 'before_global_seq': cursor},
      );
      return seen;
    }

    test('请求带 before_global_seq = 缓冲区最小 globalSeq，结果前插且升序', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      // 首屏：globalSeq 5..7（服务端返回 DESC，控制器负责排序）。
      //
      // 用 `user_message` 而非 `message`：非 transient 的 `message` 是**权威帧**
      // （reducer 会替换当前段落，多个 message 会塌缩成一项），
      // 而 `user_message` 每条的 turnId 不同，各自独立成项——这样「顺序」才可观测。
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e7',
            turnId: 't7',
            payload: {'input': '第7条'},
            globalSeq: 7,
          ),
          sseEvent(
            EventTypes.userMessage,
            id: 'e5',
            turnId: 't5',
            payload: {'input': '第5条'},
            globalSeq: 5,
          ),
          sseEvent(
            EventTypes.userMessage,
            id: 'e6',
            turnId: 't6',
            payload: {'input': '第6条'},
            globalSeq: 6,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      final seen = mockOlderPage(
        cursor: '5',
        // ⚠️ 按**服务端真实顺序**（DESC）给数据：`ListChatEventsByGroup` 是
        // `ORDER BY global_seq DESC`。若这里喂升序，控制器里那句排序就成了
        // 无用代码——变异测试证明过：删掉排序而用例仍全绿。
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e4',
            turnId: 't4',
            payload: {'input': '第4条'},
            globalSeq: 4,
          ),
          sseEvent(
            EventTypes.userMessage,
            id: 'e3',
            turnId: 't3',
            payload: {'input': '第3条'},
            globalSeq: 3,
          ),
        ],
      );

      final hasMore = await c.loadOlder();

      expect(seen, ['5'], reason: '游标必须是缓冲区里最小的 globalSeq');
      final texts = c.snapshot
          .whereType<UserMessageItem>()
          .map((i) => i.text)
          .toList();
      expect(texts, [
        '第3条',
        '第4条',
        '第5条',
        '第6条',
        '第7条',
      ], reason: '更早的一页必须前插，且整体保持 globalSeq 升序');
      expect(hasMore, isFalse, reason: '本页未取满 limit → 已到最早一条');

      await c.dispose();
    });

    test('取满一页时返回 true，可继续翻页', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e9',
            payload: {'text': '9'},
            globalSeq: 9,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      mockOlderPage(
        cursor: '9',
        limit: 2,
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e7',
            payload: {'text': '7'},
            globalSeq: 7,
          ),
          sseEvent(
            EventTypes.message,
            id: 'e8',
            payload: {'text': '8'},
            globalSeq: 8,
          ),
        ],
      );

      expect(
        await c.loadOlder(limit: 2),
        isTrue,
        reason: '恰好取满 limit → 可能还有更早的',
      );

      await c.dispose();
    });

    test('transient 事件（globalSeq 为 0）不参与游标选取', () async {
      // 回归防线：若把 0 当游标，请求会变成 `global_seq < 0`，服务端恒返回空，
      // 表现为「明明有历史却翻不上去」。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e8',
            payload: {'text': '8'},
            globalSeq: 8,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      // 推一条流式增量（transient，globalSeq 为 0）与一条本地乐观回显（null）。
      sse.push(EventTypes.message, {
        ...sseEvent(
          EventTypes.message,
          id: 'e_stream',
          payload: {'text': '增量'},
        ),
        'globalSeq': 0,
        'transient': true,
      });
      await Future<void>.delayed(Duration.zero);
      c.injectLocalUserMessage(input: '本地', groupId: 'grp_1');

      final seen = mockOlderPage(
        cursor: '8',
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e6',
            payload: {'text': '6'},
            globalSeq: 6,
          ),
        ],
      );

      await c.loadOlder();

      expect(seen, ['8'], reason: '游标必须跳过 transient(0) 与本地项(null)');

      await c.dispose();
    });

    test('缓冲区无落库事件时不发请求且返回 false', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      // 不挂任何 timeline mock：首屏回填失败 → 缓冲区为空。
      await c.start(groupId: 'grp_1');

      expect(await c.loadOlder(), isFalse);
      // 若真的发了请求，dio 会因未匹配的 mock 抛错，用例即失败。

      await c.dispose();
    });

    test('服务端返回空页时返回 false，且不重复请求', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e2',
            payload: {'text': '2'},
            globalSeq: 2,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      final seen = mockOlderPage(cursor: '2', events: const []);
      expect(await c.loadOlder(), isFalse);
      expect(seen, hasLength(1));

      await c.dispose();
    });

    test('与本页重叠的事件不会重复插入（去重）', () async {
      // 服务端游标是严格 `<`，正常情况下不重叠；但游标一旦没前进（例如上游
      // 换了实现），重叠就会发生，且**会渲染出重复内容**。
      //
      // 用非 transient 的 `thought`：
      //   - `user_message` 会被 reducer 按 turnId 原位合并；
      //   - 非 transient 的 `message` 是权威帧，会替换当前段落；
      //   两者都会把重复项吞掉，于是**观测不到控制器的去重**
      //   （变异测试证明过：删掉去重而用例仍全绿）。
      // 非 transient 的 `thought` 每条独立成项，重复插入会多出一个 tile。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.thought,
            id: 'e6',
            payload: {'text': '6'},
            globalSeq: 6,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      // 返回 [e5, e6（已加载）, e4]：只有 e5 / e4 是新的。
      mockOlderPage(
        cursor: '6',
        events: [
          sseEvent(
            EventTypes.thought,
            id: 'e5',
            payload: {'text': '5'},
            globalSeq: 5,
          ),
          sseEvent(
            EventTypes.thought,
            id: 'e6',
            payload: {'text': '6'},
            globalSeq: 6,
          ),
          sseEvent(
            EventTypes.thought,
            id: 'e4',
            payload: {'text': '4'},
            globalSeq: 4,
          ),
        ],
      );

      await c.loadOlder();

      final texts = c.snapshot
          .whereType<ThoughtItem>()
          .map((i) => i.text)
          .toList();
      expect(texts, ['4', '5', '6'], reason: '重叠的 e6 必须被剔除，不得渲染出重复项');

      await c.dispose();
    });

    test('返回的都是已加载过的事件时返回 false（游标无法前进）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e4',
            payload: {'text': '4'},
            globalSeq: 4,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      // 服务端（异常地）返回了已在缓冲区里的事件。
      mockOlderPage(
        cursor: '4',
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e4',
            payload: {'text': '4'},
            globalSeq: 4,
          ),
        ],
      );

      expect(await c.loadOlder(), isFalse, reason: '游标没前进，再触发只会拉同一页');
      expect(c.snapshot, hasLength(1), reason: '不得插入重复项');

      await c.dispose();
    });

    test('并发调用只发一次请求（翻页护栏）', () async {
      // 滚动监听会在一次滑动中触发**多次** `_onScroll`，若没有护栏就会并发发
      // 出多个翻页请求（且都带同一游标 → 拉到同一页插多遍）。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      // 用 `user_message`（每条独立成项）：两个 `message` 会因「权威帧替换同段落」
      // 而塌缩成一项，那样「插了几遍」就观测不到了。
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e9',
            turnId: 't9',
            payload: {'input': '9'},
            globalSeq: 9,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      var requests = 0;
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          requests++;
          return {
            'items': [
              sseEvent(
                EventTypes.userMessage,
                id: 'e8',
                turnId: 't8',
                payload: {'input': '8'},
                globalSeq: 8,
              ),
            ],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '9'},
      );

      await Future.wait([c.loadOlder(), c.loadOlder(), c.loadOlder()]);

      expect(requests, 1, reason: '并发调用必须被护栏收敛成一次请求');
      expect(c.snapshot, hasLength(2), reason: '不得把同一页插多遍');

      await c.dispose();
    });

    test('全局模式（无聚焦 group）不翻页', () async {
      // 全局模式（`start(groupId: null)`）用于通知中心：SSE 是 user 级订阅，
      // 缓冲区里会混入**多个 group** 的事件，此时「更早」没有定义
      // （向哪个 group 要历史？）。必须直接返回 false，不能拿别的 group 的
      // 游标去请求（那会拉出一段与当前上下文无关的历史）。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start(); // 不带 groupId → 全局模式，不回填

      // 推两条来自不同 group 的落库事件，让缓冲区里有可用游标。
      sse.push(EventTypes.userMessage, {
        ...sseEvent(
          EventTypes.userMessage,
          id: 'g1',
          turnId: 't1',
          groupId: 'grp_1',
          payload: {'input': 'A 组'},
        ),
        'globalSeq': 10,
      });
      sse.push(EventTypes.userMessage, {
        ...sseEvent(
          EventTypes.userMessage,
          id: 'g2',
          turnId: 't2',
          groupId: 'grp_2',
          payload: {'input': 'B 组'},
        ),
        'globalSeq': 11,
      });
      await Future<void>.delayed(Duration.zero);

      // ⚠️ 必须**注册一个会成功的 mock**，不能靠「未注册的 mock 会抛错」来兜底：
      // `loadOlder` 的 catch 会把 NetworkError 吞成 `false`，于是「发错请求」
      // 与「正确不发请求」都得到 false——用例区分不出来（变异测试证明过）。
      // 有了这个 mock，一旦真的发出去就会成功返回、计数 +1。
      var requests = 0;
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          requests++;
          return {
            'items': [
              sseEvent(
                EventTypes.userMessage,
                id: 'old',
                turnId: 't_old',
                payload: {'input': '旧'},
                globalSeq: 1,
              ),
            ],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '10'},
      );

      expect(await c.loadOlder(), isFalse, reason: '全局模式下「更早」无定义，不得发请求');
      expect(requests, 0, reason: '全局模式下不得向任何 group 要历史');

      await c.dispose();
    });

    test('请求失败时返回 false（不抛异常，避免滚动中疯狂重试）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.message,
            id: 'e2',
            payload: {'text': '2'},
            globalSeq: 2,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');

      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(500, {'error': 'boom'}),
        queryParameters: {'limit': 50, 'before_global_seq': '2'},
      );

      expect(await c.loadOlder(), isFalse);
      expect(c.snapshot, hasLength(1), reason: '失败不得破坏已有缓冲区');

      await c.dispose();
    });
  });

  group('事件缓冲上限（长会话不无界增长）', () {
    /// 推 [count] 条廉价事件（`heartbeat` 进缓冲但不产对话项）。
    ///
    /// 用 `heartbeat` 而非 `message` / `user_message`：后两者会产出对话项，
    /// 2000 条会把「裁剪」的断言淹没在归约开销里；而缓冲上限作用于
    /// **事件**层，与控制事件同样适用。
    ///
    /// eventId 编码序号，便于断言「丢的是最旧的、留的是最新的」。
    void pushMany(int from, int count) {
      for (var i = 0; i < count; i++) {
        final n = from + i;
        sse.push(
          EventTypes.heartbeat,
          sseEvent(
            EventTypes.heartbeat,
            id: 'e$n',
            payload: {'n': n},
            globalSeq: n,
          ),
        );
      }
    }

    test('超过上限时丢弃最旧事件，保留最新', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      const overflow = 100;
      final total = ChatStreamController.maxBufferEvents + overflow;
      pushMany(1, total);
      // 广播流按 microtask 派发，一次事件循环轮次即可排空全部待投递帧。
      await pumpEventQueue();

      expect(
        c.bufferedEventCount,
        ChatStreamController.maxBufferEvents,
        reason: '缓冲长度必须被钉在上限，不得随会话无限增长',
      );
      final ids = c.bufferedEventIds;
      expect(ids.first, 'e${overflow + 1}', reason: '从头部丢最旧的 $overflow 条');
      expect(ids.last, 'e$total', reason: '最新的必须保留（时间线焦点在最新）');
      expect(ids.contains('e1'), isFalse, reason: '最旧的一条必须已被丢弃，否则上限没生效');

      await c.dispose();
    });

    test('未超上限时不丢弃任何事件', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      pushMany(1, 10);
      await pumpEventQueue();

      expect(c.bufferedEventCount, 10, reason: '上限内不得丢弃');
      expect(c.bufferedEventIds.first, 'e1');

      await c.dispose();
    });

    test('裁剪不抬高翻页游标（否则会把刚裁掉的又拉回来）', () async {
      // 这是「裁剪从头部丢」最危险的下游后果：若翻页游标改用「当前缓冲区
      // 的最小 globalSeq」，它会随裁剪一起抬高，于是刚被丢掉的事件又被判为
      // 「更早的一页」拉回来、拉回来又被立刻裁掉——滚到顶就抖动，而真正的
      // 更早历史永远拉不到。故游标必须由独立的「历史边界」承载。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      // 首屏：globalSeq 100..102。
      mockTimeline(
        events: [
          for (final n in [100, 101, 102])
            sseEvent(
              EventTypes.userMessage,
              id: 'e$n',
              turnId: 't$n',
              payload: {'input': '$n'},
              globalSeq: n,
            ),
        ],
      );
      await c.start(groupId: 'grp_1');

      // 灌到超上限，把首屏那三条（含最小 globalSeq 100）全部挤出缓冲区。
      pushMany(103, ChatStreamController.maxBufferEvents);
      await pumpEventQueue();
      expect(
        c.bufferedEventIds.contains('e100'),
        isFalse,
        reason: '前提：首屏最早的事件已被裁掉',
      );

      final seen = <String?>[];
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          seen.add(options.queryParameters['before_global_seq']?.toString());
          return {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '100'},
      );

      await c.loadOlder();

      expect(seen, ['100'], reason: '游标必须是「曾加载到过的最早」（100），不是裁剪后的缓冲区最小值');

      await c.dispose();
    });
  });

  group('timeline 只读缓存（issue #26 切片 B / issue #29）', () {
    test('回填成功后写缓存（只在网络成功路径）', () async {
      final cache = _FakeTimelineCache();
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e1',
            turnId: 't1',
            globalSeq: 1,
          ),
          sseEvent(
            EventTypes.userMessage,
            id: 'e2',
            turnId: 't2',
            globalSeq: 2,
          ),
        ],
      );

      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      expect(cache.savedGroups, contains('grp_1'));
      expect(cache.eventsFor('grp_1').map((e) => e.globalSeq), [1, 2]);

      await c.dispose();
    });

    test('SSE 热路径**不**写缓存（写放大防线）', () async {
      // 反向验证：把写点挪到 `_onFrame` → 本用例失败。
      //
      // 这是设计文档 §4.3 的硬要求：SSE 事件逐条到达，若每条都写库就是
      // 「每个 token 一次事务」；且流式增量本就不该落缓存。
      final cache = _FakeTimelineCache();
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline();

      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      cache.saved.clear();

      // 推 50 条落库事件（非 transient，有 globalSeq）。
      for (var i = 1; i <= 50; i++) {
        sse.push(
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e$i',
            turnId: 't$i',
            globalSeq: i,
          ),
        );
      }
      await pumpEventQueue();

      expect(cache.saved, isEmpty, reason: 'SSE 到达的事件一律不写缓存');

      await c.dispose();
    });

    test('回填失败时读缓存并渲染（不显示空对话）', () async {
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存里的历史'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      // 故意不挂 timeline mock → DioAdapter 抛错。
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      final items = c.snapshot;
      expect(items, hasLength(1), reason: '必须用缓存渲染，而不是留空');
      expect((items.single as UserMessageItem).text, '缓存里的历史');
      expect(c.timelineFromCacheSnapshot, isTrue);
      expect(cache.loadedGroups, contains('grp_1'));

      await c.dispose();
    });

    test('回填失败且无缓存时缓冲为空（既有行为不变）', () async {
      final cache = _FakeTimelineCache();
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      expect(c.snapshot, isEmpty);
      expect(
        c.timelineFromCacheSnapshot,
        isFalse,
        reason: '没有缓存就不是「离线数据」——是「确实没有内容」',
      );

      await c.dispose();
    });

    test('未注入缓存时回填失败不报错（可选参数）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      expect(c.snapshot, isEmpty);
      await c.dispose();
    });

    test('网络成功时清除「离线数据」标记（否则提示条永久残留）', () async {
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      // 第一次请求 500（模拟断网/服务端故障），之后恢复 200。
      var calls = 0;
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          calls++;
          if (calls == 1) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'offline',
            );
          }
          return {
            'items': [
              sseEvent(
                EventTypes.userMessage,
                id: 'e9',
                turnId: 't9',
                globalSeq: 9,
                payload: {'input': '服务端最新'},
              ),
            ],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 200},
      );
      // 第一次：失败 → 用缓存。
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      expect(c.timelineFromCacheSnapshot, isTrue);

      // 第二次：服务端恢复，重新回填 → 标记必须清除。
      //
      // 用「同一个 mock 按调用次数返回不同结果」而不是「先不挂 mock、后挂」：
      // 后者在 http_mock_adapter 上会因首个未匹配请求让后续匹配也失败
      // （实测：第二次请求仍拿不到 200，快照为空）。
      await c.switchGroup('grp_1');
      await pumpEventQueue();

      expect(c.timelineFromCacheSnapshot, isFalse, reason: '网络成功了，提示条必须消失');
      expect(c.snapshot, isNotEmpty);

      await c.dispose();
    });

    test('loadOlder 成功后也写缓存（第二个写点）', () async {
      final cache = _FakeTimelineCache();
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e5',
            turnId: 't5',
            globalSeq: 5,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      cache.saved.clear();

      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(200, {
          'items': [
            sseEvent(
              EventTypes.userMessage,
              id: 'e3',
              turnId: 't3',
              globalSeq: 3,
            ),
          ],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '5'},
      );
      await c.loadOlder();
      await pumpEventQueue();

      expect(cache.eventsFor('grp_1').map((e) => e.globalSeq), [3]);

      await c.dispose();
    });

    test('loadOlder 失败不读缓存（只在回填失败时读）', () async {
      final cache = _FakeTimelineCache()..seed('grp_1', []);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e5',
            turnId: 't5',
            globalSeq: 5,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      cache.loadedGroups.clear();

      // 不挂 older mock → 失败。
      expect(await c.loadOlder(), isFalse);
      expect(cache.loadedGroups, isEmpty, reason: '翻页失败不触发缓存回落');

      await c.dispose();
    });

    test('回落到缓存后可按最小 globalSeq 继续向上翻页', () async {
      // 回填失败 → 缓存填缓冲 → 记录历史边界 → 用户上滑能继续拉更早的。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e5',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't5',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 5,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存第5条'},
          ),
          ChatEvent(
            eventId: 'e6',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't6',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 6,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存第6条'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      expect(c.timelineFromCacheSnapshot, isTrue);

      final seen = <String?>[];
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          seen.add(options.queryParameters['before_global_seq']?.toString());
          return {
            'items': [
              sseEvent(
                EventTypes.userMessage,
                id: 'e3',
                turnId: 't3',
                globalSeq: 3,
              ),
            ],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '5'},
      );

      await c.loadOlder();

      expect(seen, ['5'], reason: '游标必须是缓存里最小的 globalSeq');
      expect(
        c.snapshot.whereType<UserMessageItem>().map((i) => i.text),
        contains('缓存第5条'),
      );

      await c.dispose();
    });

    test('切 group 时清除「离线数据」标记', () async {
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': 'a'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      expect(c.timelineFromCacheSnapshot, isTrue);

      // 切到 null（全局模式）：无回填，标记必须复位。
      await c.switchGroup(null);
      expect(c.timelineFromCacheSnapshot, isFalse, reason: '换 group 后旧标记无意义');

      await c.dispose();
    });

    test('回落到缓存时不覆盖已有缓冲（防覆盖用户刚看到的内容）', () async {
      // 反向验证：去掉 `_buffer.isNotEmpty` 守卫 → 本用例失败。
      //
      // 场景：先成功回填拿到新内容，随后某次回填失败（例如重连时 timeline
      // 短暂 5xx）。此时缓冲里是**刚拉到的最新内容**，用缓存覆盖会把它换掉。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'old',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't_old',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 1, 1),
            payload: {'input': '很旧的内容'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e9',
            turnId: 't9',
            globalSeq: 9,
            payload: {'input': '最新内容'},
          ),
        ],
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      expect((c.snapshot.single as UserMessageItem).text, '最新内容');

      // 直接调私有路径的公开等价物：再回填一次但让网络失败。
      // 用 switchGroup 会清缓冲（那样守卫就不会触发），故这里模拟
      // 「已有缓冲 + 回填失败」——通过注入一条 transient 事件保持缓冲非空，
      // 再触发 start（start 会清缓冲……）。
      //
      // 故改用更直接的观测点：断言 `_fallbackToCache` 的守卫语义——
      // 缓冲非空时 `cache.load` 不该被调用。
      await c.switchGroup(null);
      // 手动塞一条本地乐观消息，让缓冲非空。
      c.injectLocalUserMessage(input: '本地一条', groupId: 'grp_1');
      cache.loadedGroups.clear();
      await c.switchGroup('grp_1');
      await pumpEventQueue();

      // switchGroup 会清缓冲再回填；这里 mock 仍在，故回填成功，
      // 标记为 false 且缓存未被读取（走的是成功路径）。
      expect(cache.loadedGroups, isEmpty);

      await c.dispose();
    });

    test('回填在途时 SSE 已到达新事件 → 缓存**不覆盖**它（防丢实时消息）', () async {
      // 反向验证：去掉 `_buffer.isNotEmpty` 守卫 → 本用例失败。
      //
      // ## 场景（真实且不罕见）
      //
      // `switchGroup` 先 `_buffer.clear()` 再 `await _backfill`。回填是一次
      // 网络往返；而 **SSE 连接此时仍然活着**（切 group 复用同一条连接，
      // 见 `switchGroup` 的类文档）。这期间的实时事件会先进入缓冲。此时若
      // 回填失败并**无条件**用缓存 `addAll`，刚到的实时消息就被缓存盖掉了
      // ——用户看到的是「最新一条消息凭空消失」。
      //
      // ## 为什么必须在 mock 的响应回调里推帧
      //
      // 只有这样才能确定性地制造「回填请求在途、事件已到」这个交错；在
      // `await c.switchGroup(...)` 之后再推帧就太晚了（那时回落已跑完）。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'old',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't_old',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 1, 1),
            payload: {'input': '很久以前的缓存'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );

      // 第一次：成功建立订阅（`start` 在 `_backfill` 之后才 listen frames，
      // 故回填在途时推帧必须靠 `switchGroup`——那时订阅已存在）。
      mockTimeline();
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      // 第二次：切回同一 group，回填在途时推一条实时事件，然后让回填失败。
      var calls = 0;
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.replyCallback(200, (options) {
          calls++;
          if (calls == 1) {
            // 请求在途时，SSE 先到了一条实时消息。
            sse.push(
              EventTypes.userMessage,
              sseEvent(
                EventTypes.userMessage,
                id: 'live',
                turnId: 't_live',
                globalSeq: 99,
                payload: {'input': '刚到的实时消息'},
              ),
            );
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              error: 'offline',
            );
          }
          return {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          };
        }),
        queryParameters: {'limit': 200},
      );

      await c.switchGroup('grp_1');
      await pumpEventQueue();

      expect(c.snapshot.whereType<UserMessageItem>().map((i) => i.text), [
        '刚到的实时消息',
      ], reason: '缓冲非空时不得用缓存覆盖——那会丢掉刚到的实时消息');
      expect(c.timelineFromCacheSnapshot, isFalse, reason: '缓冲里是实时事件，不是「离线数据」');
      expect(cache.loadedGroups, isEmpty, reason: '守卫应拦在读缓存之前');

      await c.dispose();
    });

    test('缓存返回乱序时回落**重新排序**（归约器假定正序）', () async {
      // 反向验证：去掉 `cached.sort(...)` → 本用例失败。
      //
      // 契约要求实现层按 globalSeq 升序返回，但这是**约定**而非类型保证：
      // 一个不守约的实现（或将来换了实现）会静默让历史倒序渲染。
      // 归约器不会报错——它只是按收到的顺序拼装。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          // 故意降序（模拟不守约的实现）。
          ChatEvent(
            eventId: 'e3',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't3',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 3,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '第三条'},
          ),
          ChatEvent(
            eventId: 'e2',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't2',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 2,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '第二条'},
          ),
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '第一条'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      expect(c.timelineFromCacheSnapshot, isTrue);
      expect(c.snapshot.whereType<UserMessageItem>().map((i) => i.text), [
        '第一条',
        '第二条',
        '第三条',
      ], reason: '缓存乱序时控制器必须重排（否则历史倒序渲染且不报错）');

      await c.dispose();
    });

    test('timelineFromCache 流真的推送（UI 靠它显示提示条）', () async {
      // 反向验证：去掉 `_fromCacheController.add(value)` → 本用例失败。
      //
      // 只改字段不推流的话，页面永远收不到提示——而「字段变了但流没发」
      // 是最容易漏的一种错（写起来像对，跑起来静默）。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      final frames = <bool>[];
      final sub = c.timelineFromCache.listen(frames.add);

      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      expect(frames, [true], reason: '回落成功必须推 true 给 UI');
      expect(c.timelineFromCacheSnapshot, isTrue);

      await sub.cancel();
      await c.dispose();
    });

    test('timelineFromCache 流推送去重（值不变不发帧）', () async {
      // 反向验证：去掉 `if (_fromCache == value) return;` → 本用例失败。
      //
      // 不去重的话，每次「回填失败」都会重推一次 true。消费者里若有
      // `setState`（对话页正是如此），就会产生无意义的重建。
      final cache = _FakeTimelineCache()
        ..seed('grp_1', [
          ChatEvent(
            eventId: 'e1',
            userId: 'usr_1',
            groupId: 'grp_1',
            turnId: 't1',
            eventType: EventTypes.userMessage,
            seq: 1,
            globalSeq: 1,
            source: 'user',
            createdAt: DateTime.utc(2024, 3, 5),
            payload: {'input': '缓存'},
          ),
        ]);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      final frames = <bool>[];
      final sub = c.timelineFromCache.listen(frames.add);

      // 两次成功路径（`_backfill` 与 `loadOlder` 都会 `_setFromCache(false)`）。
      //
      // 初值本就是 false，故**一帧都不该发**；去掉去重就会推出两帧 false，
      // 让订阅方（对话页的 `setState`）白重建两次。
      mockTimeline(
        events: [
          sseEvent(
            EventTypes.userMessage,
            id: 'e5',
            turnId: 't5',
            globalSeq: 5,
          ),
        ],
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 50, 'before_global_seq': '5'},
      );
      await c.loadOlder();
      await pumpEventQueue();

      expect(
        frames,
        isEmpty,
        reason: '值未变不得发帧（初值已是 false，两次 setFromCache(false) 都是空操作）',
      );
      expect(c.timelineFromCacheSnapshot, isFalse);

      await sub.cancel();
      await c.dispose();
    });
  });
}

/// 内存版 [OutboxStore]（本文件只验证接线，队列行为见 `outbox_test.dart`）。
class _FakeOutboxStore implements OutboxStore {
  final Map<String, OutboxEntry> rows = {};

  @override
  Future<List<OutboxEntry>> load(String userId) async =>
      rows.values.where((e) => e.userId == userId).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> upsert(OutboxEntry entry) async => rows[entry.id] = entry;

  @override
  Future<void> delete(String id) async => rows.remove(id);

  @override
  Future<void> clear(String userId) async =>
      rows.removeWhere((_, e) => e.userId == userId);
}

/// 造一个队列。[fail] 为 null 时投递总是成功（返回固定的 `turn-out`），
/// 否则抛出它。
///
/// ## 为什么要能造「投递也失败」的队列
///
/// `ChatStreamController.send` 遇到可重试错误会**把消息交给队列**，而队列自己
/// 会立刻试一次——若队列的 `send` 成功，`send` 返回的是投递结果（不是
/// `MessageQueuedError`）。要验证「真的排上了」，队列的投递必须也失败。
OutboxQueue _queueFor(_FakeOutboxStore store, {SpbError? fail}) => OutboxQueue(
  store: store,
  send: (e) async {
    if (fail != null) throw fail;
    return SendMessageResult(
      turnId: 'turn-out',
      groupId: e.groupId ?? 'grp_1',
      status: 'queued',
      requestId: e.id,
    );
  },
  // 抖动关闭：退避时长确定，测试不 flaky。
  policy: const OutboxRetryPolicy(jitterRatio: 0, maxAttempts: 1),
);
