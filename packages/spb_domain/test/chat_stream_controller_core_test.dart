import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 控制器核心：send 乐观回显 / 去重 / SSE 帧处理 / 切组复用连接
///
/// ⚠️ 本文件由 `chat_stream_controller_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
void main() {
  setUpHarness();

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

    test('无法解析的载荷留下 warn 日志（issue #45）', () async {
      // 事件被**整个丢弃** → 用户会在时间线上看到一个缺口。修复前这条路径
      // 完全静默（`if (decoded == null) return;`），日志里毫无痕迹。
      SpbLog.clearRecentLogs();
      SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);

      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.framesController.add(
        const SseFrame(event: 'message', data: '{not json', id: null),
      );
      await Future<void>.delayed(Duration.zero);

      final rec = SpbLog.recentLogs
          .where((r) => r.message == 'SSE 事件载荷无法解析（该事件被丢弃）')
          .single;
      expect(rec.level, LogLevel.warn);
      expect(rec.fields['event'], 'message');
      expect(rec.fields['payload_bytes'], 9);
      // ⚠️ 不得记录载荷全文（可能含用户输入，而诊断报告会被贴进公开 issue）。
      expect(rec.fields.containsKey('data'), isFalse);

      await c.dispose();
    });

    test('空载荷也留下 warn 日志（与非法 JSON 区分）', () async {
      SpbLog.clearRecentLogs();
      SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);

      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.framesController.add(
        const SseFrame(event: 'message', data: '', id: null),
      );
      await Future<void>.delayed(Duration.zero);

      final rec = SpbLog.recentLogs
          .where((r) => r.message == 'SSE 事件载荷无法解析（该事件被丢弃）')
          .single;
      expect(rec.fields['empty'], isTrue);
      expect(rec.fields['payload_bytes'], 0);

      await c.dispose();
    });

    test('契约破坏的事件（缺 eventId）被吞掉且不影响后续', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.framesController.add(
        const SseFrame(
          event: 'message',
          data: '{"eventType":"message"}',
          id: null,
        ),
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
}
