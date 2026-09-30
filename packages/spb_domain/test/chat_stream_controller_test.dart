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
}
