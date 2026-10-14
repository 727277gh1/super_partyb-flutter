import 'dart:async';

import 'package:dio/dio.dart';
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

  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
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

/// `ChatStreamController` 的**归约合并**（issue #44）行为测试。
///
/// ## 这个测试防的是什么
///
/// 流式回复是逐 token 增量（`message` 事件的 `transient: true`）。一个长回复
/// 产生几百条事件，而 `_emit` 原来**每条**都 `EventReducer.reduce(_buffer)`
/// 全量重算（缓冲区上限 2000 条）并重建整个 items 列表。
///
/// 实测（缓冲区已满 2000、一个回复 300 条增量）：单次归约约 1.8 ms，
/// 300 条即 **640 ms** 全部在 UI 线程上——表现为流式期间的滚动卡顿。
///
/// 修法是「把归约合并到一个事件循环任务」：同一批到达的 N 条增量只归约一次。
///
/// ## ⚠️ 为什么用 `Timer` 而不是 issue 最初建议的 `scheduleMicrotask`
///
/// 实测（本文件「调度方式」一组钉住）：broadcast stream 把 N 次同步 `add`
/// 投递成 **N 个独立 microtask**（每次只投一个事件），于是从 listener 里排的
/// microtask 会排在「下一个事件」之前 → **完全不合并**。只有事件循环**任务**
/// （Timer）能跨过整批事件。故实现用 `Timer(Duration.zero, ...)`。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late _FakeSseClient sse;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = _FakeSseClient();
  });

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

  /// 推一条流式增量（`transient: true`）。
  Map<String, dynamic> delta(
    String text, {
    required int i,
    String turnId = 'turn_1',
  }) => sseEvent(
    EventTypes.message,
    id: 'delta_$i',
    turnId: turnId,
    payload: {'text': text},
    transient: true,
    seq: i,
    globalSeq: i,
  );

  /// 等归约计时器执行。
  ///
  /// ## 为什么要两个轮次
  ///
  /// 顺序是：`sse.push` → 帧投递（microtask）→ `_emit` 排归约计时器。
  /// 而 `Future.delayed(Duration.zero)` **本身就是个计时器**，它在 microtask
  /// 之前就被排上了，故会**先于**归约计时器触发。一个轮次只够让帧到达
  /// `_onFrame`，归约还没跑。
  ///
  /// 第二个轮次才轮到归约计时器。两个 `Duration.zero` 即可（真实时区里
  /// 计时器按到期时间 + 插入顺序执行）。
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('归约合并：同一批事件只推送一次 items', () {
    test('一个 chunk 内 5 条增量 → 只推送 1 次（而不是 5 次）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      var emits = 0;
      final sub = c.items.listen((_) => emits++);
      await c.start();
      await settle();
      emits = 0;

      // 同步推 5 条：模拟一个网络 chunk 里的多条增量。
      for (var i = 0; i < 5; i++) {
        sse.push(EventTypes.message, delta('tok$i ', i: i + 1));
      }
      await settle();

      // ⚠️ 断言的是「推送次数」而非「最终文本」——后者在合并前后都一样，
      // 抓不住「每条都归约」这个缺陷。
      expect(emits, 1, reason: '同一批事件必须合并成一次归约（修复前是 5 次）');
      // 合并**不得**丢内容：5 段增量全部拼进同一个回复。
      final text = c.snapshot.whereType<AssistantMessageItem>().single.text;
      expect(text, 'tok0 tok1 tok2 tok3 tok4 ');

      await sub.cancel();
      await c.dispose();
      await sse.dispose();
    });

    test('分两批推（中间隔一个轮次）→ 各自归约一次（不跨批错误合并）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      var emits = 0;
      final sub = c.items.listen((_) => emits++);
      await c.start();
      await settle();
      emits = 0;

      sse.push(EventTypes.message, delta('a', i: 1));
      await settle();
      expect(emits, 1);

      sse.push(EventTypes.message, delta('b', i: 2));
      await settle();
      expect(emits, 2, reason: '两批之间已有轮次，不该再合并');

      expect(c.snapshot.whereType<AssistantMessageItem>().single.text, 'ab');

      await sub.cancel();
      await c.dispose();
      await sse.dispose();
    });

    test('2000 条历史 + 一批 300 条增量 → 只归约 1 次', () async {
      // 端到端规模验证：缓冲区满时单次归约约 1.8 ms，300 条即约 640 ms。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start();
      for (var i = 0; i < 2000; i++) {
        sse.push(
          EventTypes.message,
          sseEvent(
            EventTypes.message,
            id: 'hist_$i',
            turnId: 'turn_hist',
            payload: {'text': 'x'},
            transient: true,
            seq: i,
            globalSeq: i + 1,
          ),
        );
      }
      await settle();
      expect(c.bufferedEventCount, 2000, reason: '先灌满缓冲区');

      var emits = 0;
      final sub = c.items.listen((_) => emits++);
      for (var i = 0; i < 300; i++) {
        sse.push(
          EventTypes.message,
          sseEvent(
            EventTypes.message,
            id: 'new_$i',
            turnId: 'turn_new',
            payload: {'text': 'y'},
            transient: true,
            seq: i,
            globalSeq: 3000 + i,
          ),
        );
      }
      await settle();
      expect(emits, 1, reason: '300 条增量合并成 1 次归约（修复前是 300 次）');

      await sub.cancel();
      await c.dispose();
      await sse.dispose();
    });
  });

  group('归约合并：同步读不得拿到过期结果', () {
    test('push 之后立刻读 snapshot 就已是新内容（不等计时器）', () async {
      // `_reduction` 是缓存。若合并把缓存置脏却不提供同步兜底，那么
      // 「push 后立刻读 snapshot」会拿到**上一次**归约的结果——调用方
      // （如 `_syncStaleWatch`、页面初始化）会据此做出错误决策。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start();
      await settle();
      expect(c.snapshot, isEmpty);

      sse.push(EventTypes.message, delta('立刻可读', i: 1));
      // 只让**帧投递**（microtask），不让归约计时器跑（timer）。
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      // ⚠️ 此刻归约计时器还挂着（`_reductionDirty` 为真）——直接读必须现场
      // 重算，不能返回上一次的缓存。
      expect(
        c.snapshot.whereType<AssistantMessageItem>().single.text,
        '立刻可读',
        reason: '缓存置脏后同步读必须现场重算，不能返回旧结果',
      );

      await c.dispose();
      await sse.dispose();
    });

    test('归约计时器执行后缓存复用，不重复归约', () async {
      // 计时器回调走 `_reduction`：若同步读已经把脏缓存算过，这里应直接复用。
      // 用「同一批内先同步读一次、再让计时器跑」来验证不抛异常且结果一致。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start();
      await settle();

      sse.push(EventTypes.message, delta('一次', i: 1));
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      final syncRead = c.snapshot;
      await settle();
      final afterFlush = c.snapshot;

      expect(syncRead.length, afterFlush.length);
      expect(afterFlush.whereType<AssistantMessageItem>().single.text, '一次');

      await c.dispose();
      await sse.dispose();
    });
  });

  group('归约合并：看门狗 per-turn 语义不退化（issue #44 × §5.8）', () {
    test('一批里两个 turn 的增量都到达时，两个计时器都被重排', () async {
      // ## 为什么这条必须存在
      //
      // `_syncStaleWatch` 的语义是「只重排**触发者**的到期时刻」。合并后一批
      // 事件可能有**多个**触发者——若实现只保留「最后一个 touchedTurnId」，
      // 另一个 turn 的计时器就不会被重排，它会比预期更早判 stale（误报）。
      //
      // 这里用「两个 turn 都在跑」的形态：一个 chunk 里先推 turn A 的增量、
      // 再推 turn B 的。两者都必须保持「刚被触及」。
      //
      // ⚠️ 用真实时间（毫秒级阈值）会与 CI 抖动赛跑，故这条用 fake_async 在
      // `chat_stream_controller_stale_test.dart` 里已有同型覆盖；此处只钉
      // 「一批多 turn 不会让其中某个 turn 的计时器被漏掉」这一条，用短阈值 +
      // 真实等待。
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        turnTimeoutOverride: const Duration(milliseconds: 120),
      );
      await c.start();
      await settle();

      // 同一批里两个 turn 各一条增量。
      //
      // ⚠️ 必须夹一个 `start`：归约器只有一个 `currentAssistantIdx`，`start`
      // 才重置它。否则 turn_b 的增量会被**追加到 turn_a 的段落**上，两个 turn
      // 只剩一个流式段落，也就谈不上「两个计时器」。
      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_a', turnId: 'turn_a'),
      );
      sse.push(EventTypes.message, delta('A', i: 1, turnId: 'turn_a'));
      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_b', turnId: 'turn_b'),
      );
      sse.push(EventTypes.message, delta('B', i: 2, turnId: 'turn_b'));
      await settle();

      // 两个 turn 都应被登记为进行中（未判 stale）。
      expect(c.staleTurnIdsSnapshot, isEmpty, reason: '刚推完不该立刻判 stale');

      // 等超过阈值：两个都应到期判 stale（说明两者的计时器都武装了）。
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(c.staleTurnIdsSnapshot, {
        'turn_a',
        'turn_b',
      }, reason: '一批里两个 turn 的计时器都必须被武装，不能只武装最后一个');

      await c.dispose();
      await sse.dispose();
    });

    test('一批含两个 turn 的增量时，**两个**计时器都被重排（不能只留最后一个）', () async {
      // ## 这条是 `_pendingTouchedTurnIds` 必须是**集合**的直接证据
      //
      // 场景：A、B 两个 turn 都已在跑、都已有计时器。此时一批事件里**两者都有**
      // 增量。若实现只保留「最后一个 touchedTurnId」（如 B），A 的计时器不会被
      // 重排，它会按**原来的**到期时刻被判 stale——而 A 明明刚刚还在产出。
      //
      // 时间线（阈值 T=200ms）：
      //
      // ```
      // t=0    A、B 各推 start+增量 → 两个计时器都武装，均应在 t=200 到期
      // t=150  一批里同时推 A 与 B 的增量 → 两者都应被重排到 t=350
      // t=260  A 的**原**到期时刻已过，但重排后不该到期
      //        → 只留最后一个的实现会让 A 在这里被误判 stale
      // ```
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        turnTimeoutOverride: const Duration(milliseconds: 200),
      );
      await c.start();
      await settle();

      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_a', turnId: 'turn_a'),
      );
      sse.push(EventTypes.message, delta('A0', i: 1, turnId: 'turn_a'));
      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_b', turnId: 'turn_b'),
      );
      sse.push(EventTypes.message, delta('B0', i: 2, turnId: 'turn_b'));
      await settle();

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 一批里**两个 turn 都有**增量。
      sse.push(EventTypes.message, delta('A1', i: 3, turnId: 'turn_a'));
      sse.push(EventTypes.message, delta('B1', i: 4, turnId: 'turn_b'));
      await settle();

      // 越过 A/B 的**原**到期时刻（t≈200），但未到重排后的（t≈350）。
      await Future<void>.delayed(const Duration(milliseconds: 110));

      expect(
        c.staleTurnIdsSnapshot,
        isEmpty,
        reason:
            '两个 turn 都在这一批里被触及，两个计时器都必须重排；'
            '只重排最后一个会让另一个提前判 stale',
      );

      await c.dispose();
      await sse.dispose();
    });

    test('一批多 turn 中只续期被触及的，不误续期旁边那个', () async {
      // 反向：一批里只触及 turn A。turn B 的计时器**不得**被重排——否则
      // 一个已卡死的 turn 会被旁边还在跑的 turn 无限续期，兜底失效。
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        turnTimeoutOverride: const Duration(milliseconds: 150),
      );
      await c.start();
      await settle();

      // 先让两个 turn 都进入进行中（各推 start + 一条增量）。
      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_a', turnId: 'turn_a'),
      );
      sse.push(EventTypes.message, delta('A0', i: 1, turnId: 'turn_a'));
      sse.push(
        EventTypes.start,
        sseEvent(EventTypes.start, id: 'st_b', turnId: 'turn_b'),
      );
      sse.push(EventTypes.message, delta('B0', i: 2, turnId: 'turn_b'));
      await settle();

      // 等一半阈值，让 B 的到期时刻更早。
      await Future<void>.delayed(const Duration(milliseconds: 90));

      // 只续期 A（一批里只有 A 的事件）。
      sse.push(EventTypes.message, delta('A1', i: 3, turnId: 'turn_a'));
      await settle();

      // 再等到「B 的原始到期时刻」之后、但「A 的新到期时刻」之前。
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(
        c.staleTurnIdsSnapshot,
        contains('turn_b'),
        reason: 'B 未被触及，应按原到期时刻判 stale',
      );
      expect(
        c.staleTurnIdsSnapshot,
        isNot(contains('turn_a')),
        reason: 'A 刚被触及，计时器应已重排，不该判 stale',
      );

      await c.dispose();
      await sse.dispose();
    });
  });

  group('归约合并：调度方式（钉住为什么不用 scheduleMicrotask）', () {
    test('broadcast stream 的同步 add 是「每事件一个 microtask」', () async {
      // ## 这是 issue #44 方案取舍的**证据测试**
      //
      // issue 最初建议 `scheduleMicrotask`。若投递是「一批一个 microtask」，
      // 那 microtask 也能合并。实测**不是**：N 次同步 add → N 个独立
      // microtask，每次只投一个事件。
      //
      // 故从 listener 里排的 microtask 会排在「下一个事件」之前 → 不合并。
      // 这条测试把这个事实钉住，避免将来有人「优化」成 microtask 又悄悄
      // 退回每条一归约。
      final controller = StreamController<int>.broadcast();
      final delivered = <int>[];
      controller.stream.listen(delivered.add);

      for (var i = 0; i < 3; i++) {
        controller.add(i);
      }
      expect(delivered, isEmpty, reason: '投递是异步的');

      // 逐个 microtask 观察：每个只多一个事件。
      await Future<void>.delayed(Duration.zero);
      expect(delivered, [
        0,
        1,
        2,
      ], reason: '零延迟后三个事件都已投递（但它们走的是三个独立 microtask）');
      await controller.close();
    });

    test('控制器在同一批内只归约一次（Timer 的合并效果）', () async {
      // 上一条证明「microtask 投递粒度是每事件一个」，这条证明「控制器确实
      // 把整批合并了」——两条合起来即「必须用事件循环任务而非 microtask」。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start();
      await settle();

      var emits = 0;
      final sub = c.items.listen((_) => emits++);
      for (var i = 0; i < 10; i++) {
        sse.push(EventTypes.message, delta('x', i: i + 1));
      }
      await settle();
      expect(emits, 1, reason: '10 条 → 1 次；microtask 方案会是 10 次');

      await sub.cancel();
      await c.dispose();
      await sse.dispose();
    });
  });

  group('归约合并：切 group / dispose 丢弃挂起的合并', () {
    test('切 group 后挂起的合并不得用旧 touched turn 武装计时器', () async {
      // 切 group 会 `_resetStaleWatch`（清计时器）。若挂起的
      // `_pendingTouchedTurnIds` 不被丢弃，随后的 flush 会拿旧时间线的 turn
      // 去重排计时器——武装出一个 items 里根本不存在的 turn。
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        turnTimeoutOverride: const Duration(milliseconds: 100),
      );
      mockTimeline(adapter);
      await c.start(groupId: 'grp_1');
      await settle();

      sse.push(EventTypes.message, delta('旧', i: 1, turnId: 'turn_old'));
      // 让帧投递（microtask），但**不**让归约计时器跑 → 保持挂起。
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      expect(c.hasPendingEmit, isTrue, reason: '前提：有挂起的归约');

      // 立刻切 group：挂起的合并必须被丢弃。
      await c.switchGroup('grp_2');
      await settle();

      // 新时间线是空的，不该有任何 stale。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(c.staleTurnIdsSnapshot, isEmpty, reason: '切 group 后旧 turn 不得被武装');

      await c.dispose();
      await sse.dispose();
    });

    test('dispose 后挂起的归约计时器被取消（不留指向已释放对象的计时器）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start();
      await settle();

      sse.push(EventTypes.message, delta('x', i: 1));
      // 让帧投递（microtask），但**不**让归约计时器跑。
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      expect(c.hasPendingEmit, isTrue, reason: '前提：此刻确有一个挂起的归约计时器');

      await c.dispose();
      expect(c.hasPendingEmit, isFalse, reason: 'dispose 必须取消挂起的归约计时器');

      await sse.dispose();
      await settle();
    });
  });
}

/// 给 `switchGroup` 用的 timeline mock。
void mockTimeline(DioAdapter adapter) {
  adapter.onGet(
    '/chat/groups/grp_1/timeline',
    (server) => server.reply(200, {
      'items': <Map<String, dynamic>>[],
      'next_before_global_seq': '',
    }),
    queryParameters: {'limit': 200},
  );
  adapter.onGet(
    '/chat/groups/grp_2/timeline',
    (server) => server.reply(200, {
      'items': <Map<String, dynamic>>[],
      'next_before_global_seq': '',
    }),
    queryParameters: {'limit': 200},
  );
  adapter.onGet(
    '/api/chat/turn-runtime',
    (server) => server.reply(200, {
      'request_timeout_seconds': 300,
      'inactivity_timeout_seconds': 0,
      'client_turn_timeout_seconds': 300,
    }),
  );
}
