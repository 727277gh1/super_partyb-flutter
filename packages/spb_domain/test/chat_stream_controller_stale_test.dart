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

  /// 让假时区里的「待办」全部跑完：microtask **加上**零延迟的归约计时器。
  ///
  /// ## 为什么不能只用 `flushMicrotasks`
  ///
  /// issue #44 起归约被合并到一个**零延迟 Timer**（`_emit` → `flushEmit`）。
  /// `flushMicrotasks` 只跑 microtask 队列，不跑 timer——故 `push` 之后若不
  /// 额外 `elapse(Duration.zero)`，归约会一直挂着，看门狗也就不会武装/撤销，
  /// 断言 `pendingTimers` 时还会把那个归约计时器误算进去。
  ///
  /// 先 `flushMicrotasks` 让 SSE 帧投递到 `_onFrame`（并排上归约计时器），
  /// 再 `elapse(zero)` 让它真正执行。
  void drain(FakeAsync async) {
    async.flushMicrotasks();
    async.elapse(Duration.zero);
    async.flushMicrotasks();
  }

  /// 在假时区里建控制器、起全局模式（**不回填 timeline**，故无 HTTP）。
  ///
  /// `start` 在 `groupId == null` 时没有 await 点，故同步就完成了 `_emit` 与帧
  /// 订阅——`push` 之后 `drain` 即可让 `_onFrame` 与归约跑起来。
  ChatStreamController boot(FakeAsync async, _FakeSseClient sse) {
    final controller = ChatStreamController(
      sse: sse,
      api: ChatApi(Dio()),
      userId: 'usr_1',
      turnTimeoutOverride: timeout,
    );
    unawaited(controller.start());
    drain(async);
    return controller;
  }

  /// 推一帧并让它被归约（假时区里必须显式冲 microtask + 跑归约计时器）。
  void push(
    FakeAsync async,
    _FakeSseClient sse,
    String type,
    Map<String, dynamic> data,
  ) {
    sse.push(type, data);
    drain(async);
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
            payload: {
              'tool_call_id': 'call_1',
              'name': 'bash',
              'args': <String, dynamic>{},
            },
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

  group('看门狗：回填场景（issue #9 / B1b）', () {
    /// 建一个带 mock timeline 的控制器并回填 `grp_1`。
    ///
    /// 与 [boot] 的区别：这里**必须**有 timeline 回填，因为本组测的正是
    /// 「重开对话时回填出来的历史里，服务端是否还在跑」。
    ///
    /// 用 `DioAdapter`（非真实 HTTP）故在假时区里也能 resolve；
    /// `turnTimeoutOverride` 仍注入以避免 `turn-runtime` 请求。
    ChatStreamController bootWithTimeline(
      FakeAsync async,
      _FakeSseClient sse,
      List<Map<String, dynamic>> history,
    ) {
      final dio = createDio(baseUrl: 'https://api.test/pba');
      final adapter = DioAdapter(dio: dio);
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) =>
            server.reply(200, {'items': history, 'next_before_global_seq': ''}),
        queryParameters: {'limit': 200},
      );
      final controller = ChatStreamController(
        sse: sse,
        api: ChatApi(dio),
        userId: 'usr_1',
        turnTimeoutOverride: timeout,
      );
      unawaited(controller.start(groupId: 'grp_1'));
      async.flushMicrotasks();
      // `http_mock_adapter` 的 mock 响应靠一个零延时 timer 兑现，而 `fake_async`
      // 里 timer 必须显式推进才会跑（`flushMicrotasks` 只跑 microtask）。故
      // `elapse(Duration.zero)` 是让 `_backfill` 真正完成的必要一步——
      // 推进 0 不会触发 30s 的看门狗。
      async.elapse(Duration.zero);
      return controller;
    }

    test('回填只有权威帧、无 done → 武装看门狗，到期判 stale', () {
      // 这是 B1b 缺口的端到端形态：全非 Transient，故流式标记为空；
      // 修好之前这里永远不会 stale（界面静止骗人）。
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = bootWithTimeline(async, sse, [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': '重开前发的'},
            globalSeq: 1,
          ),
          sseEvent(
            EventTypes.message,
            id: 'hist_2',
            payload: {'text': '已产出但服务端可能还在跑'},
            globalSeq: 2,
          ),
        ]);

        expect(c.snapshot, hasLength(2), reason: '回填应已生效');
        expect(async.pendingTimers, isNotEmpty, reason: '回填后应已武装看门狗（修复前这里为空）');
        expect(c.staleTurnIdsSnapshot, isEmpty, reason: '刚回填不该立刻判 stale');

        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('回填已终结的对话（有 done）→ 不武装、不判 stale', () {
      // 反向防线：若不做终态记录，每个历史对话都会被判成「仍在跑」并转圈。
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = bootWithTimeline(async, sse, [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': '历史用户消息'},
            globalSeq: 1,
          ),
          sseEvent(
            EventTypes.message,
            id: 'hist_2',
            payload: {'text': '历史回答'},
            globalSeq: 2,
          ),
          sseEvent(
            EventTypes.done,
            id: 'hist_3',
            payload: {'status': 'completed'},
            globalSeq: 3,
          ),
        ]);

        expect(c.snapshot, hasLength(2));
        expect(async.pendingTimers, isEmpty, reason: '已终结的历史对话不得武装看门狗');

        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, isEmpty, reason: '不得把所有历史对话都判成「仍在跑」');

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('回填后 SSE 补上 done → 脱出并取消计时器', () {
      // 回填时判为可能在跑，随后服务端补发 done：应回到「已结束」。
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = bootWithTimeline(async, sse, [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': 'x'},
            globalSeq: 1,
          ),
          sseEvent(
            EventTypes.message,
            id: 'hist_2',
            payload: {'text': '回复'},
            globalSeq: 2,
          ),
        ]);
        expect(async.pendingTimers, isNotEmpty);

        push(
          async,
          sse,
          EventTypes.done,
          sseEvent(
            'done',
            id: 'done_1',
            payload: {'status': 'completed'},
            globalSeq: 3,
          ),
        );

        expect(async.pendingTimers, isEmpty, reason: '终态到达后应取消计时器');
        expect(c.staleTurnIdsSnapshot, isEmpty);

        c.dispose();
        async.flushMicrotasks();
      });
    });

    test('回填只有用户消息（agent 未动）→ 同样武装（preparing）', () {
      fakeAsync((async) {
        final sse = _FakeSseClient();
        final c = bootWithTimeline(async, sse, [
          sseEvent(
            EventTypes.userMessage,
            id: 'hist_1',
            payload: {'input': '刚发出就断了'},
            globalSeq: 1,
          ),
        ]);

        expect(async.pendingTimers, isNotEmpty);
        async.elapse(timeout + const Duration(seconds: 1));
        expect(c.staleTurnIdsSnapshot, {'turn_1'});

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
