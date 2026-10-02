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
}
