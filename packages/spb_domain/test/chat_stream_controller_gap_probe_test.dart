import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 断线回放缺口探测（`ChatStreamController._probeReplayGap`）。
///
/// ## 这个测试防的是什么
///
/// 服务端 `replayUserEvents` 只取该用户**最近 500 条**落库事件，在里面定位
/// cursor；**找不到就返回空**，然后照常进入实时循环。于是「断线期间超过 500 条
/// 事件」与「断线期间什么都没有」在线上**完全同形**——客户端不探测，就会带着
/// 一段永久空洞继续渲染（用户看到「回复少了一大块」）。
///
/// 三个失败方向都必须钉住：
///
/// | 写错的方向 | 后果 | 对应用例 |
/// |---|---|---|
/// | 完全不探测（修复前的状态） | 缺口永久留白 | 「服务端领先 → 整段回填」 |
/// | 只按「落后」判定 | 每次重连都把缓冲重置成最新 200 条（用户在看的正文被换掉） | 「回放仍在到达 → 不回填」 |
/// | 首次连接也探测 | 刚 `start()` 回填完就再拉一次，白费一次请求 | 「首次连接不探测」 |
///
/// 所有用例都把 `replayGapProbeDelay` / `replayGapSettle` 压到 0：这两个时长是
/// **生产**的时序保护（等回放帧到达），不是被测逻辑本身。
void main() {
  setUpHarness();
  setUp(TimelineProbe.reset);
  tearDown(TimelineProbe.reset);

  /// 建一个探针时序为 0 的控制器并完成首屏回填。
  Future<ChatStreamController> started({
    List<Map<String, dynamic>>? backfill,
    String groupId = 'grp_1',
  }) async {
    mockTimeline(events: backfill);
    final c = ChatStreamController(
      sse: sse,
      api: api,
      userId: 'usr_1',
      replayGapProbeDelay: Duration.zero,
      replayGapSettle: Duration.zero,
    );
    await c.start(groupId: groupId);
    await pumpEventQueue();
    return c;
  }

  /// 推一条落库事件（推进游标与本地 `globalSeq` 上界）。
  void pushPersisted({
    required String id,
    required int globalSeq,
    String turnId = 'turn_1',
    String groupId = 'grp_1',
  }) {
    sse.push(
      EventTypes.userMessage,
      sseEvent(
        EventTypes.userMessage,
        id: id,
        turnId: turnId,
        groupId: groupId,
        payload: {'input': 'hi'},
        globalSeq: globalSeq,
      ),
    );
  }

  group('断线回放缺口探测', () {
    test('首次连接（游标为空）不探测：start() 已整段回填过', () async {
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 9);
      final c = await started();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 0, reason: '没有游标就没有「回放」，探测只会白拉一次');
      await c.dispose();
    });

    test('服务端没有更新 → 探测一次但不回填', () async {
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 2);
      final c = await started();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 1, reason: '本地与服务端一样新，说明回放/live 都到了');
      expect(c.bufferedEventIds, ['e2'], reason: '没有缺口就不得动缓冲区');
      expect(c.timelineDiagnostics().replayGapRepairs, 0);
      await c.dispose();
    });

    test('服务端领先且本地静默 → 判定缺口，改用 timeline 整段回填', () async {
      // 回填页按调用次数给不同内容：第 1 次（start）只有 e1，第 2 次（修复）
      // 是 e900——后者代表「服务端已经有 900 号事件了」。
      final backfills = mockTimelineSequence([
        [
          sseEvent(
            EventTypes.userMessage,
            id: 'e1',
            turnId: 't1',
            globalSeq: 1,
          ),
        ],
        [
          sseEvent(
            EventTypes.userMessage,
            id: 'e900',
            turnId: 't900',
            globalSeq: 900,
          ),
        ],
      ]);
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 900);

      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        replayGapProbeDelay: Duration.zero,
        replayGapSettle: Duration.zero,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 1);
      expect(backfills(), 2, reason: '修复必须真的走 timeline 整段回填');
      expect(c.bufferedEventIds, [
        'e900',
      ], reason: '缺口意味着缓冲中间有洞，只能整段替换（拼接会「看起来连续但缺一段」）');
      expect(c.timelineDiagnostics().replayGapRepairs, 1);
      expect(
        c.timelineDiagnostics().newestBufferedGlobalSeq,
        900,
        reason: '回填后本地覆盖上界必须跟着更新，否则下一次探测还会误判',
      );
      await c.dispose();
    });

    test('探测响应跑在 SSE 投递前面（回放仍在到达）→ 不回填', () async {
      // 这是最关键的一条：HTTP 探测与 SSE 是两条独立连接，探测的响应完全可能
      // 先回来。此时「本地落后」是**正常在途**，不是缺口——若据此回填，用户
      // 正在读的正文会被重置成最新 200 条（比缺口本身更烦人）。
      final probeCalls = mockTimelineProbe(
        newestGlobalSeq: 900,
        onRequest: () {
          // mock 回调跑在探测的 HTTP future 之前，故这条事件的投递一定早于
          // `_probeReplayGap` 读「本地最大值」那一步。
          pushPersisted(id: 'e900', globalSeq: 900);
        },
      );
      final c = await started();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 1);
      expect(c.bufferedEventIds, [
        'e2',
        'e900',
      ], reason: '追上之后不得回填（缓冲区里 e2 必须还在）');
      expect(c.timelineDiagnostics().replayGapRepairs, 0);
      await c.dispose();
    });

    test('回放仍在推进但一次追不上 → 重排探测，第二次追上后不回填', () async {
      // 与上一条的区别：第一次探测时只推进到 3（仍落后 900），本地最大值
      // **变了** → 判据是「还在动，先再看一次」，而不是立刻回填。
      var requests = 0;
      final probeCalls = mockTimelineProbe(
        newestGlobalSeq: 900,
        onRequest: () {
          requests++;
          pushPersisted(
            id: 'e_more_$requests',
            globalSeq: requests == 1 ? 3 : 900,
          );
        },
      );
      final c = await started();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 2, reason: '第一次「仍在动」→ 重排；第二次已追上 → 停');
      expect(c.bufferedEventIds.contains('e2'), isTrue, reason: '不得回填');
      expect(c.timelineDiagnostics().replayGapRepairs, 0);
      await c.dispose();
    });

    test('本地没有落库事件（回填失败/离线）→ 不探测', () async {
      // 真实场景：`switchGroup` 到另一个 group 时回填失败，缓冲被清空，但游标
      // 还是上一个 group 的。此时若去探测，就会拿「本地一无所知」当成缺口。
      final c = await started();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();
      expect(sse.lastEventId, 'e2');

      mockTimelineFailure(groupId: 'grp_2');
      final probeCalls = mockTimelineProbe(
        newestGlobalSeq: 900,
        groupId: 'grp_2',
      );
      await c.switchGroup('grp_2');
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 0, reason: '本地没有任何落库事件时无从对账，不得误判');
      expect(c.timelineDiagnostics().replayGapRepairs, 0);
      await c.dispose();
    });

    test('全局模式（没有聚焦 group）不探测', () async {
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 900);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        replayGapProbeDelay: Duration.zero,
        replayGapSettle: Duration.zero,
      );
      // 全局模式：不回填任何 group 的时间线。
      await c.start();
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 0, reason: '全局模式没有时间线，探测对象不存在');
      await c.dispose();
    });

    test('dispose 取消挂起的探测（不留下指向已释放对象的计时器）', () async {
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 900);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        // 生产量级的延迟：dispose 必须发生在探测真正跑起来之前。
        replayGapProbeDelay: const Duration(seconds: 30),
        replayGapSettle: Duration.zero,
      );
      mockTimeline();
      await c.start(groupId: 'grp_1');
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await c.dispose();
      await pumpEventQueue();

      expect(probeCalls(), 0);
    });

    test('整段替换丢掉了已加载的更早历史 → 记下丢弃量与翻页下界（§6.85）', () async {
      // 首屏回填 20 条（seq 100..119），再推一条实时事件（seq 120）。
      // 缺口修复页只有 1 条且 seq=900：**页最小值 900 高于缓冲里的全部事件**，
      // 于是这 21 条已加载历史会被整段替换扔掉——用户滚到顶部才能重新翻回来。
      SpbLog.clearRecentLogs();
      final backfills = mockTimelineSequence([
        [
          for (var i = 100; i < 120; i++)
            sseEvent(
              EventTypes.userMessage,
              id: 'e$i',
              turnId: 't$i',
              globalSeq: i,
            ),
        ],
        [
          sseEvent(
            EventTypes.userMessage,
            id: 'e900',
            turnId: 't900',
            globalSeq: 900,
          ),
        ],
      ]);
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 900);

      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        replayGapProbeDelay: Duration.zero,
        replayGapSettle: Duration.zero,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      pushPersisted(id: 'e120', globalSeq: 120);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 1);
      expect(backfills(), 2);
      final d = c.timelineDiagnostics();
      expect(d.replayGapRepairs, 1);
      expect(
        d.lastReplaceDropped,
        21,
        reason: '20 条回填 + 1 条实时事件全部早于新页最小值 900，都是「已加载但会被扔掉」的历史',
      );
      expect(d.lastReplaceOldestBefore, 100, reason: '替换前的翻页下界');
      expect(d.lastReplaceOldestAfter, 900, reason: '替换后的翻页下界被抬到新页最小值');

      // 日志侧证据：这是 release 包里唯一能看出「这次替换扔了东西」的地方。
      final warned = SpbLog.recentLogs.where(
        (r) => r.fields['dropped_loaded_events'] == 21,
      );
      expect(warned, hasLength(1));
      expect(warned.single.level, LogLevel.warn);
      expect(warned.single.fields['oldest_after'], 900);
      expect(
        warned.single.fields['before_events'],
        21,
        reason: '替换前的缓冲条数（不是回填页条数）',
      );
      await c.dispose();
    });

    test('整段替换没丢掉已加载历史 → 丢弃量为 0，不写 warn', () async {
      // 缺口页里含本地已有的最早那条（seq 1）→ 页最小值 1，缓冲里没有更早的
      // 事件可以丢。这种替换是正常的（用户什么都不会丢），不该发 warn。
      SpbLog.clearRecentLogs();
      final backfills = mockTimelineSequence([
        [
          sseEvent(
            EventTypes.userMessage,
            id: 'e1',
            turnId: 't1',
            globalSeq: 1,
          ),
        ],
        [
          sseEvent(
            EventTypes.userMessage,
            id: 'e1',
            turnId: 't1',
            globalSeq: 1,
          ),
          sseEvent(
            EventTypes.userMessage,
            id: 'e900',
            turnId: 't900',
            globalSeq: 900,
          ),
        ],
      ]);
      final probeCalls = mockTimelineProbe(newestGlobalSeq: 900);

      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        replayGapProbeDelay: Duration.zero,
        replayGapSettle: Duration.zero,
      );
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();
      pushPersisted(id: 'e2', globalSeq: 2);
      await pumpEventQueue();

      sse.emitState(SseState.connected);
      await pumpEventQueue();

      expect(probeCalls(), 1);
      expect(backfills(), 2);
      final d = c.timelineDiagnostics();
      expect(d.replayGapRepairs, 1);
      expect(d.lastReplaceDropped, 0);
      expect(d.lastReplaceOldestBefore, 1);
      expect(d.lastReplaceOldestAfter, 1, reason: '新页最小值与旧下界相同，区间没有被抬高');
      // ⚠️ 不能断言「整段缓冲里没有任何 warn」：缺口探测自己就会写一条
      // 「断线回放被截断」。只认**替换丢弃量**那一条，且它必须是 info。
      final replaceLogs = SpbLog.recentLogs.where(
        (r) => r.fields.containsKey('dropped_loaded_events'),
      );
      expect(replaceLogs, hasLength(1));
      expect(replaceLogs.single.level, LogLevel.info);
      expect(
        replaceLogs.single.fields['dropped_loaded_events'],
        0,
        reason: '没丢东西时不该 warn（每次重连都会走替换，全 warn 会淹没真异常）',
      );
      await c.dispose();
    });
  });
}
