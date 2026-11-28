import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

void main() {
  setUpHarness();

  Map<String, dynamic> event(int n) =>
      sseEvent(EventTypes.userMessage, id: 'e$n', turnId: 't$n', globalSeq: n);

  Future<ChatStreamController> started() async {
    final c = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
      replayGapProbeDelay: Duration.zero,
    );
    addTearDown(c.dispose);
    await c.start(groupId: 'grp_1');
    await pumpEventQueue();
    return c;
  }

  Future<void> reconnect({int tail = 900}) async {
    sse.emitState(SseState.reconnecting);
    sse.push(EventTypes.userMessage, event(tail));
    await pumpEventQueue();
    sse.emitState(SseState.connected);
    await pumpEventQueue();
  }

  test('首次连接没有游标时不重复回填', () async {
    final calls = mockTimelineSequence([[]]);
    await started();
    sse.emitState(SseState.connected);
    await pumpEventQueue();
    expect(calls(), 1);
  });

  test('最新 SSE 已到达仍补齐中间缺页，保留已加载历史', () async {
    final calls = mockTimelineSequence([
      [event(1)],
      [event(701), event(900)],
    ]);
    var olderCalls = 0;
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.replyCallback(200, (_) {
        olderCalls++;
        return {
          'items': [event(1), event(500)],
          'next_before_global_seq': '1',
        };
      }),
      queryParameters: {'limit': 200, 'before_global_seq': '701'},
    );
    final c = await started();
    await reconnect();
    expect(calls(), 2);
    expect(olderCalls, 1);
    expect(c.bufferedEventIds, ['e1', 'e500', 'e701', 'e900']);
    expect(c.timelineDiagnostics().replayGapRepairs, 1);
    expect(c.timelineDiagnostics().lastReplaceDropped, 0);
  });

  test('重连没有缺页也不重复气泡或删除旧历史', () async {
    mockTimelineSequence([
      [event(1), event(2)],
      [event(1), event(2)],
    ]);
    final c = await started();
    await reconnect(tail: 2);
    expect(c.bufferedEventIds.toSet(), {'e1', 'e2'});
    expect(c.bufferedEventIds, hasLength(2));
    expect(c.timelineDiagnostics().replayGapRepairs, 0);
  });

  test('本地为空时重连恢复首屏', () async {
    mockTimelineSequence([
      [],
      [event(900)],
    ]);
    final c = await started();
    // 游标可来自其他 group，本组首屏失败也应重新获取。
    sse.lastEventId = 'other-group-event';
    sse.emitState(SseState.connected);
    await pumpEventQueue();
    expect(c.bufferedEventIds, ['e900']);
  });

  test('补拉中切组，旧页不会灌入新对话', () async {
    mockTimelineSequence([
      [event(1)],
      [event(900)],
    ]);
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': [event(1), event(500)],
      }, delay: const Duration(milliseconds: 100)),
      queryParameters: {'limit': 200, 'before_global_seq': '900'},
    );
    adapter.onGet(
      '/chat/groups/grp_2/timeline',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 200},
    );
    final c = await started();
    await reconnect();
    await c.switchGroup('grp_2');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.bufferedEventIds, isEmpty);
  });

  test('补拉失败后自动重试，不依赖下一次断线', () async {
    mockTimeline(events: [event(1)]);
    final c = await started();
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(500, <String, dynamic>{}),
      queryParameters: {'limit': 200},
    );
    await reconnect();
    expect(c.bufferedEventIds, contains('e1'));
    mockTimeline(events: [event(1), event(500), event(900)]);
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    expect(c.bufferedEventIds, contains('e500'));
  });

  test('dispose 取消挂起的恢复任务', () async {
    final calls = mockTimelineSequence([
      [event(1)],
    ]);
    final c = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
      replayGapProbeDelay: const Duration(seconds: 30),
    );
    await c.start(groupId: 'grp_1');
    await reconnect();
    await c.dispose();
    expect(calls(), 1);
  });
}
