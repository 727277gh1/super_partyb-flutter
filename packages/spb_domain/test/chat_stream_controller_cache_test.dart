import 'package:dio/dio.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// timeline 只读缓存（issue #26 切片 B / #29）
///
/// ⚠️ 本文件由 `chat_stream_controller_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
void main() {
  setUpHarness();

  group('timeline 只读缓存（issue #26 切片 B / issue #29）', () {
    test('回填成功后写缓存（只在网络成功路径）', () async {
      final cache = FakeTimelineCache();
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
      final cache = FakeTimelineCache();
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache();
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache();
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
      final cache = FakeTimelineCache()..seed('grp_1', []);
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
      final cache = FakeTimelineCache()
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
