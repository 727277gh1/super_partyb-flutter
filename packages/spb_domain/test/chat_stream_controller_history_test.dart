import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 控制器生命周期与向上翻页（loadOlder）/ 事件缓冲上限
///
/// ⚠️ 本文件由 `chat_stream_controller_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
void main() {
  setUpHarness();

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
      const total = ChatStreamController.maxBufferEvents + overflow;
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
}
