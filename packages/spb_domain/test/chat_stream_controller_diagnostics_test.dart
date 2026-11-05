import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 控制器的「时间线数据面快照」（`timelineDiagnostics` / `TimelineProbe`）。
///
/// ## 这个测试防的是什么
///
/// 报障时用户只能说「回复少了一大块」，而**两种成因的修法完全不同**：
///
/// | 成因 | 快照特征 |
/// |---|---|
/// | 数据层（裁剪 / 回放截断） | `assistant_chars` 本身就少；`trim_count > 0` |
/// | 渲染层（§6.51 那一类） | `assistant_chars` 正常，对话内搜索仍能命中 |
///
/// 故这里钉住的不是「有个 API」，而是三个**具体口径**：
///
/// 1. 快照在一轮结束时自动写入（不需要用户操作）；
/// 2. 裁剪计数按「每次裁」累加（缓冲满了之后每来一条事件就裁一次，这是事实）；
/// 3. 换 group 必须清零——否则报告会把上一个对话的裁剪史算到当前对话头上。
void main() {
  setUpHarness();
  setUp(() {
    SpbLog.clearRecentLogs();
    TimelineProbe.reset();
  });
  tearDown(TimelineProbe.reset);

  Future<ChatStreamController> started() async {
    mockTimeline();
    final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
    await c.start(groupId: 'grp_1');
    await pumpEventQueue();
    return c;
  }

  /// 推一条落库事件（`turnId` 可指定，用来构造「按整轮裁剪」与「单轮降级」）。
  void pushEvent(
    String type, {
    required int n,
    required String turnId,
    Map<String, dynamic>? payload,
  }) {
    sse.push(
      type,
      sseEvent(
        type,
        id: 'e$n',
        turnId: turnId,
        payload: payload ?? {'n': n},
        globalSeq: n,
      ),
    );
  }

  group('done：一轮结束时自动落快照', () {
    test('正文进没进归约结果，快照里能直接读出来', () async {
      final c = await started();

      pushEvent(
        EventTypes.userMessage,
        n: 1,
        turnId: 't1',
        payload: {'input': '问题'},
      );
      pushEvent(
        EventTypes.message,
        n: 2,
        turnId: 't1',
        payload: {'content': '你好世界'},
      );
      pushEvent(EventTypes.done, n: 3, turnId: 't1');
      await pumpEventQueue();

      // 不是等用户去点「导出诊断」——`done` 到达时就写了一份。
      final d = TimelineProbe.latest;
      expect(d, isNotNull, reason: '一轮结束必须自动落一份快照');
      expect(d!.groupId, 'grp_1');
      expect(d.assistantChars, 4, reason: '「你好世界」4 个字符');
      expect(d.itemCount, 2, reason: '用户消息 + 助手正文');
      expect(d.turns.single.turnId, 't1');
      expect(d.turns.single.chars, 4);
      expect(d.trimCount, 0, reason: '这才 3 条事件，没裁过');
      expect(d.newestBufferedGlobalSeq, 3);
      // 控制器算的与快照里的一致（快照不是另一条独立路径）。
      expect(c.timelineDiagnostics().assistantChars, d.assistantChars);
      await c.dispose();
    });

    test('done 也记进日志（环形缓冲 → 导出报告），字段是 snake_case', () async {
      final c = await started();

      pushEvent(
        EventTypes.message,
        n: 1,
        turnId: 't1',
        payload: {'content': 'abc'},
      );
      pushEvent(EventTypes.done, n: 2, turnId: 't1');
      await pumpEventQueue();

      final digest = SpbLog.recentLogs.where(
        (r) => r.message.contains('时间线数据面快照'),
      );
      expect(digest, isNotEmpty);
      expect(digest.last.fields['reason'], 'done');
      expect(digest.last.fields['assistant_chars'], 3);
      expect(digest.last.fields['group_id'], 'grp_1');
      await c.dispose();
    });

    test('快照只含数字与 id —— 正文一个字都不进', () async {
      final c = await started();

      pushEvent(
        EventTypes.message,
        n: 1,
        turnId: 't1',
        payload: {'content': '机密正文'},
      );
      pushEvent(EventTypes.done, n: 2, turnId: 't1');
      await pumpEventQueue();

      final d = TimelineProbe.latest!;
      final dump = '${d.toLogFields()} ${d.toReportLines()}';
      expect(
        dump,
        isNot(contains('机密正文')),
        reason: '报告会被贴进公开 issue（见 TimelineDiagnostics 的类文档）',
      );
      expect(dump, contains('t1'), reason: 'turnId 是允许的（要能定位是哪一轮）');
      await c.dispose();
    });
  });

  group('裁剪计数：报障时要能回答「到底裁过没有」', () {
    test('按整轮裁剪时计数逐次累加，且报告读得到', () async {
      final c = await started();

      // 每条事件属于**不同的轮**：`_trimBuffer` 会落在轮次边界上，一次丢一条。
      const overflow = 5;
      const total = ChatStreamController.maxBufferEvents + overflow;
      for (var n = 1; n <= total; n++) {
        pushEvent(EventTypes.heartbeat, n: n, turnId: 't$n');
      }
      await pumpEventQueue();

      final d = c.timelineDiagnostics();
      expect(d.bufferedEvents, ChatStreamController.maxBufferEvents);
      // 缓冲满了之后**每来一条新事件就裁一次**，故是 overflow 次而不是 1 次。
      // 这个数字本身是排障线索：它说明「一直在裁」而不是「偶发一次」。
      expect(d.trimCount, overflow);
      expect(d.lastTrimDropped, 1);
      expect(d.lastTrimPerTurn, isTrue);
      expect(c.bufferedEventIds.first, 'e${overflow + 1}');
      expect(TimelineProbe.latest?.trimCount, overflow);
      await c.dispose();
    });

    test('裁剪日志被节流（计数器不受影响）', () async {
      final c = await started();

      const total = ChatStreamController.maxBufferEvents + 5;
      for (var n = 1; n <= total; n++) {
        pushEvent(EventTypes.heartbeat, n: n, turnId: 't$n');
      }
      await pumpEventQueue();

      final trimLogs = SpbLog.recentLogs
          .where((r) => r.message.contains('事件缓冲区超出上限'))
          .length;
      // 裁了 5 次，但日志只写 1 条（30s 节流）：否则一秒能刷满 500 条的诊断
      // 环形缓冲，把真正的异常扫掉（与 §6.48 的 `_singleTurnTrimWarned` 同型）。
      expect(trimLogs, 1);
      expect(c.timelineDiagnostics().trimCount, 5);
      await c.dispose();
    });

    test('整个缓冲属于同一轮时标记为「逐条降级」', () async {
      final c = await started();

      const total = ChatStreamController.maxBufferEvents + 5;
      for (var n = 1; n <= total; n++) {
        pushEvent(EventTypes.heartbeat, n: n, turnId: 't_single');
      }
      await pumpEventQueue();

      final d = c.timelineDiagnostics();
      expect(d.lastTrimPerTurn, isFalse, reason: '单轮超限只能逐条丢，这是有意的降级');
      expect(d.trimCount, 5);
      await c.dispose();
    });

    test('换 group 清零计数与覆盖区间（否则报告张冠李戴）', () async {
      final c = await started();

      const total = ChatStreamController.maxBufferEvents + 1;
      for (var n = 1; n <= total; n++) {
        pushEvent(EventTypes.heartbeat, n: n, turnId: 't$n');
      }
      await pumpEventQueue();
      expect(c.timelineDiagnostics().trimCount, greaterThan(0));

      mockTimeline();
      await c.switchGroup('grp_2');
      await pumpEventQueue();

      final d = c.timelineDiagnostics();
      expect(d.trimCount, 0);
      expect(d.newestBufferedGlobalSeq, isNull);
      expect(d.groupId, 'grp_2');
      await c.dispose();
    });
  });

  group('回填：快照在整段替换后跟着更新', () {
    test('回填完成即落一份快照（网络基线）', () async {
      mockTimelineSequence([
        [
          sseEvent(
            EventTypes.message,
            id: 'e1',
            turnId: 't1',
            globalSeq: 1,
            payload: {'content': '历史正文'},
          ),
        ],
      ]);

      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      await c.start(groupId: 'grp_1');
      await pumpEventQueue();

      final d = TimelineProbe.latest;
      expect(d, isNotNull);
      expect(d!.assistantChars, 4);
      expect(d.newestBufferedGlobalSeq, 1);
      expect(d.oldestLoadedGlobalSeq, 1);
      await c.dispose();
    });
  });
}
