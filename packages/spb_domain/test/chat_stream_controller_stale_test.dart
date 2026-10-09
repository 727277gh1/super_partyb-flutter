import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 假的 [SseClient]（与 `chat_stream_controller_test.dart` 同构，此处独立一份
/// 避免跨文件共享测试夹具）。
class _FakeSseClient extends SseClient {
  _FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {}

  @override
  Future<void> resume() async {}

  @override
  void recordEventId(String eventId) {}

  @override
  Future<void> dispose() async {
    await framesController.close();
  }

  /// 推一帧（camelCase，同 chatbus.Event 的 SSE 形态）。
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  /// 推心跳注释帧（服务端每 3s 一条，**不进业务事件流**）。
  void pushHeartbeat() {
    framesController.add(const SseFrame(event: null, data: '', id: null));
  }

  static String _encode(Map<String, dynamic> m) {
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

/// `ChatStreamController` 的**超时兜底**（stale turn 看门狗）行为测试。
///
/// ## 这个测试防的是什么
///
/// 流式标记只有 `done` / `start` 两条清除路径。一旦 `done` 丢失（turn worker
/// 崩溃、长断线、回放窗口被打穿），UI 会**永久**停在流式态。看门狗是唯一兜底。
///
/// ## 为什么用 `fake_async`
///
/// 看门狗判据是「距最后一条事件超过阈值」，用真实时间测要么等分钟级、要么在
/// 毫秒级阈值下与 CI 抖动赛跑。`fake_async` 让 `elapse` 精确推进假时区。
///
/// 前提是**不产生真实 I/O**：故这组测试全部注入 `turnTimeoutOverride`，控制器
/// 因此跳过 `GET /api/chat/turn-runtime`（真实 dio 请求在假时区里不会 resolve，
/// 会让 `elapse` 提前停下并留下 pending timer）。HTTP 解析单独在文件末尾那组
/// 用真实时区测。
void main() {
  const timeout = Duration(seconds: 30);

  /// 服务端形态的 SSE 事件 JSON（camelCase，同 chatbus.Event）。
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

  /// 在假时区里建控制器、起全局模式（**不回填 timeline**，故无 HTTP）。
  ///
  /// `start` 在 `groupId == null` 时没有 await 点，故同步就完成了 `_emit` 与帧
  /// 订阅——`push` 之后 `flushMicrotasks` 即可让 `_onFrame` 跑起来。
  ChatStreamController boot(FakeAsync async, _FakeSseClient sse) {
    final controller = ChatStreamController(
      sse: sse,
      api: ChatApi(Dio()),
      userId: 'usr_1',
      turnTimeoutOverride: timeout,
    );
    unawaited(controller.start());
    async.flushMicrotasks();
    return controller;
  }

  /// 推一帧并让它被归约（假时区里必须显式冲 microtask）。
  void push(
    FakeAsync async,
    _FakeSseClient sse,
    String type,
    Map<String, dynamic> data,
  ) {
    sse.push(type, data);
    async.flushMicrotasks();
  }

  /// 推一条**流式增量**（`transient: true` → `isStreaming: true`）。
  void pushStreaming(
    FakeAsync async,
    _FakeSseClient sse, {
    String turnId = 'turn_1',
    String text = '正在生成',
    int seq = 1,
  }) => push(
    async,
    sse,
    EventTypes.message,
    sseEvent(
      'message',
      id: 'stream_$turnId',
      turnId: turnId,
      payload: {'text': text},
      transient: true,
      seq: seq,
    ),
  );

  group('看门狗：判定与续期', () {
    test('距最后一条事件超过阈值 → 该 turn 判为无进展', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);

        expect(c.staleTurnIdsSnapshot, isEmpty, reason: '刚推完帧不该立刻判 stale');

        async.elapse(timeout + const Duration(seconds: 1));

        expect(c.staleTurnIdsSnapshot, {'turn_1'});
        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('阈值内不判；每条新事件把到期时刻往后推（续期）', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);

        async.elapse(const Duration(seconds: 29));
        expect(c.staleTurnIdsSnapshot, isEmpty);

        // 续期：再推一帧，重新计时。
        pushStreaming(async, sse, text: '继续', seq: 2);
        async.elapse(const Duration(seconds: 29));
        expect(
          c.staleTurnIdsSnapshot,
          isEmpty,
          reason: '长 turn 持续产出事件时不得被判成静止——这正是活动信号的意义',
        );

        // 停止产出 → 到期。
        async.elapse(const Duration(seconds: 2));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('判 stale 后同 turn 又有事件 → 立即脱出', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);
        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        pushStreaming(async, sse, text: '又动了', seq: 2);

        expect(c.staleTurnIdsSnapshot, isEmpty);
        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('只有 turn_activity（不进 items）的长 turn 同样能续期', () {
      // 这是本方案必须把看门狗放在控制器而非页面的**唯一理由**：
      // turn_activity 是「执行器仍在跑」的直接证据，但它不进 items。
      // 若按 items 判超时，「只有工具心跳、尚无正文」的长 turn 会被误判。
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);

        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(seconds: 20));
          push(
            async,
            sse,
            EventTypes.turnActivity,
            sseEvent(
              'turn_activity',
              id: 'act_$i',
              payload: {'elapsed_ms': 20000 * (i + 1)},
              transient: true,
              seq: 10 + i,
            ),
          );
        }

        expect(
          c.staleTurnIdsSnapshot,
          isEmpty,
          reason: '活动心跳持续到达即说明 turn 在推进，不得判静止',
        );

        // 心跳停了 → 到期。
        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('SSE 心跳（注释帧）不续期', () {
      // 心跳只说明 SSE 连接活着，而 turn worker 崩了心跳照样在流。
      // 若让它续期，超时兜底在「worker 崩溃但连接正常」这个主要场景下永不触发。
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);

        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(seconds: 5));
          sse.pushHeartbeat();
          async.flushMicrotasks();
        }

        expect(c.staleTurnIdsSnapshot, {
          'turn_1',
        }, reason: '心跳不得续期——它是连接存活信号，不是 turn 进展信号');

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('其他 group 的事件不续期、不误判', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);

        // 本 group 的流式项在，别的 group 的事件被 group 过滤挡掉（不 emit）。
        for (var i = 0; i < 5; i++) {
          async.elapse(const Duration(seconds: 10));
          push(
            async,
            sse,
            EventTypes.message,
            sseEvent(
              'message',
              id: 'other_$i',
              turnId: 'turn_other',
              groupId: 'grp_other',
              payload: {'text': '别的对话'},
              transient: true,
              seq: 50 + i,
            ),
          );
        }

        expect(c.staleTurnIdsSnapshot, {'turn_1'});
        expect(
          c.staleTurnIdsSnapshot,
          isNot(contains('turn_other')),
          reason: '别的 group 的事件不该把它的 turn 带进本 group 的 stale 集合',
        );

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('未配对的 tool_call 也算进行中（长工具无正文场景）', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        // 只有一条 tool_call，没有 message / thought。
        push(
          async,
          sse,
          EventTypes.toolCall,
          sseEvent(
            'tool_call',
            id: 'tc_1',
            payload: {'tool_call_id': 'call_1', 'name': 'bash', 'args': {}},
          ),
        );

        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {
          'turn_1',
        }, reason: '只看 isStreaming 会漏掉长工具静默期，而那是最需要兜底的情形');

        c.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('看门狗：终态与生命周期', () {
    test('done 到达 → 脱出 stale，且计时器被取消', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);
        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        push(
          async,
          sse,
          EventTypes.done,
          sseEvent(
            'done',
            id: 'done_1',
            payload: {'status': 'completed'},
            seq: 2,
          ),
        );

        expect(c.staleTurnIdsSnapshot, isEmpty);
        expect(async.pendingTimers, isEmpty, reason: 'turn 已终结，不该留着看门狗计时器');

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('切 group 清空 stale 集合', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);
        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        // 切到全局模式（groupId: null，不回填、无 HTTP）。
        unawaited(c.switchGroup(null));
        async.flushMicrotasks();

        expect(
          c.staleTurnIdsSnapshot,
          isEmpty,
          reason: '上一个 group 的「无进展」结论对新 group 无意义',
        );

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose 取消计时器，不留 pending timer', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);
        pushStreaming(async, sse);
        expect(async.pendingTimers, isNotEmpty, reason: '有进行中的 turn 时应已武装');

        c.dispose();
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('无进行中的 turn 时不武装计时器（空转开销为零）', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = boot(async, sse);

        expect(async.pendingTimers, isEmpty);

        c.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('看门狗：阈值来自服务端', () {
    late Dio dio;
    late DioAdapter adapter;
    late ChatApi api;

    setUp(() {
      dio = createDio(baseUrl: 'https://api.test/pba');
      adapter = DioAdapter(dio: dio);
      api = ChatApi(dio);
    });

    /// 挂 `GET /api/chat/turn-runtime` 的 mock。
    void mockRuntime(Object body, {int status = 200}) {
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(status, body),
      );
    }

    test('拉取成功 → 用服务端生效值（不是硬编码）', () async {
      mockRuntime({
        'request_timeout_seconds': 600,
        'inactivity_timeout_seconds': 0,
        'client_turn_timeout_seconds': 600,
      });
      final c = ChatStreamController(
        sse: _FakeSseClient(),
        api: api,
        userId: 'usr_1',
      );

      await c.start();
      await c.turnTimeoutResolved;

      expect(
        c.turnTimeout,
        const Duration(minutes: 10),
        reason: '生产该 env 是 600；客户端若写死 300 会把长 turn 提前判成静止',
      );
      await c.dispose();
    });

    test('client_turn_timeout_seconds 为 0 → 退化为兜底（不是「立即超时」）', () async {
      mockRuntime({
        'request_timeout_seconds': 0,
        'inactivity_timeout_seconds': 0,
        'client_turn_timeout_seconds': 0,
      });
      final c = ChatStreamController(
        sse: _FakeSseClient(),
        api: api,
        userId: 'usr_1',
      );

      await c.start();
      await c.turnTimeoutResolved;

      expect(c.turnTimeout, TurnRuntime.fallback);
      expect(
        c.turnTimeout,
        isNot(Duration.zero),
        reason: '0 若被当成阈值，会把所有正在跑的 turn 瞬间判成静止',
      );
      await c.dispose();
    });

    test('拉取失败 → 退化到兜底阈值，不抛异常', () async {
      mockRuntime({'error': 'boom'}, status: 500);
      final c = ChatStreamController(
        sse: _FakeSseClient(),
        api: api,
        userId: 'usr_1',
      );

      await c.start();
      await c.turnTimeoutResolved;

      expect(c.turnTimeout, TurnRuntime.fallback);
      await c.dispose();
    });

    test('注入 turnTimeoutOverride 时不发请求（测试与离线场景）', () async {
      // 不挂 mock：若仍发请求，DioAdapter 会因「没有匹配的 mock」而抛错。
      final c = ChatStreamController(
        sse: _FakeSseClient(),
        api: api,
        userId: 'usr_1',
        turnTimeoutOverride: const Duration(seconds: 7),
      );

      await c.start();
      await c.turnTimeoutResolved;

      expect(c.turnTimeout, const Duration(seconds: 7));
      await c.dispose();
    });

    test('切 group 后旧请求返回 → 不覆盖新上下文的阈值', () async {
      // 切 group 会重新发起解析，而旧请求可能**后**返回。若不丢弃过期结果，
      // 它会用上一个 group 的阈值覆盖刚重置的状态。
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 600,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 600,
        }),
      );
      final c = ChatStreamController(
        sse: _FakeSseClient(),
        api: api,
        userId: 'usr_1',
      );

      final first = c.start();
      // 第一次解析还没回来就切 group（全局模式，无 timeline 请求）。
      await c.switchGroup(null);
      await c.turnTimeoutResolved;
      await first;

      expect(c.turnTimeout, const Duration(minutes: 10));
      await c.dispose();
    });
  });
}
