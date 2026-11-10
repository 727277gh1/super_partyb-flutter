import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_features/spb_features.dart';

import '../support/conversation_page_harness.dart';

/// 时间线的**工具调用折叠**（A）与**底部工具进度条**（C）在页面上的接线。
///
/// ## 这个文件防的是什么
///
/// 折叠与状态条都是**展示层**的事：数据层（`_items`）一个字都没删。所以它们
/// 出错时**不会有任何异常**，只会表现成「用户看到的东西不对」：
///
/// - 折叠没接上 → 时间线还是几十条工具卡（噪声没减少，而没有任何测试红）；
/// - 折叠接得过头 → 单条工具调用也被并成批（用户找不到具体某次调用）；
/// - 状态条没接上 → 底部仍是「执行中 · 已运行 X」，用户看不出调了几个工具；
/// - 状态条优先级写反 → 排队/重试提示被工具进度盖掉（那是更该看的信息）。
///
/// 领域层的分组规则与 `turn_status.dart` 的文案已有各自单测
/// （`tool_call_batch_test.dart` / `turn_status_test.dart`），**本文件只测
/// 「页面真的这样接线」**——同 §6.17/§6.33 的教训：组件自己测自己，
/// 装配漏接它不知道。
void main() {
  setUpHarness();
  tearDownHarness();

  /// 推 [count] 条同轮工具调用，并按需补上结果（`output != null` 即完成）。
  ///
  /// 名字刻意带上序号（`tool_0`…）：后续「搜索定位到批内第 N 个成员」的用例
  /// 需要能唯一命中其中一条。
  Future<void> pushToolCalls(
    WidgetTester tester, {
    required String turnId,
    int count = 5,
    bool complete = true,
    int startSeq = 10,
  }) async {
    for (var i = 0; i < count; i++) {
      await pushEvent(
        tester,
        EventTypes.toolCall,
        sseEvent(
          EventTypes.toolCall,
          id: '${turnId}_tc$i',
          turnId: turnId,
          seq: startSeq + i,
          payload: {'tool_call_id': 'c$i', 'name': 'tool_$i'},
        ),
      );
      if (!complete) continue;
      await pushEvent(
        tester,
        EventTypes.toolResult,
        sseEvent(
          EventTypes.toolResult,
          id: '${turnId}_tr$i',
          turnId: turnId,
          seq: startSeq + 100 + i,
          payload: {'tool_call_id': 'c$i', 'output': 'ok_$i'},
        ),
      );
    }
  }

  /// 让这一轮处于「流式中」（页面靠它找 `streaming` 项，状态条也只在这种
  /// 轮次上有意义）。
  Future<void> pushStreamingText(
    WidgetTester tester, {
    String turnId = 'turn_1',
    String text = '我来看看',
  }) => pushEvent(
    tester,
    EventTypes.message,
    sseEvent(
      EventTypes.message,
      id: '${turnId}_msg',
      turnId: turnId,
      transient: true,
      seq: 2,
      payload: {'text': text},
    ),
  );

  group('时间线工具调用折叠', () {
    testWidgets('5 条连续同轮工具调用 → 折成一张卡（时间线不再是 5 张卡）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushToolCalls(tester, turnId: 'turn_1', count: 5);

      expect(
        find.byKey(const ValueKey('tool-call-batch-tile')),
        findsOneWidget,
      );
      expect(find.text('已调用 5 个工具'), findsOneWidget);
      // 全部完成 → 默认折叠：成员卡片不渲染（这正是省下的高度）。
      expect(
        find.byKey(const ValueKey('tool-batch-member-t1_tc0')),
        findsNothing,
      );
    });

    testWidgets('4 条不折叠（阈值边界：宁可留噪声也不把零散调用藏起来）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushToolCalls(tester, turnId: 'turn_1', count: 4);

      expect(find.byKey(const ValueKey('tool-call-batch-tile')), findsNothing);
      expect(find.byType(ToolCallTile), findsNWidgets(4));
    });

    testWidgets('跨轮不合并：两轮各 3 条仍是 6 张单卡', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushToolCalls(tester, turnId: 'turn_1', count: 3);
      await pushToolCalls(tester, turnId: 'turn_2', count: 3, startSeq: 50);

      expect(find.byKey(const ValueKey('tool-call-batch-tile')), findsNothing);
      expect(find.byType(ToolCallTile), findsNWidgets(6));
    });

    testWidgets('批内有在飞调用 → 默认展开（「它在跑」的证据不许藏）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      // 5 条调用，最后一条没有 tool_result → `hasRunning` 为真。
      await pushToolCalls(tester, turnId: 'turn_1', count: 4);
      await pushEvent(
        tester,
        EventTypes.toolCall,
        sseEvent(
          EventTypes.toolCall,
          id: 'turn_1_tc9',
          turnId: 'turn_1',
          seq: 60,
          payload: {'tool_call_id': 'c9', 'name': 'tool_9'},
        ),
      );

      expect(
        find.byKey(const ValueKey('tool-call-batch-tile')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tool-batch-member-turn_1_tc9')),
        findsOneWidget,
        reason: '在飞的调用必须在时间线上看得见',
      );
      expect(find.textContaining('执行中 · 最近：tool_9'), findsOneWidget);
    });
  });

  group('折叠后仍可搜索定位（数据层没被删）', () {
    testWidgets('对话内搜索命中批内成员 → 定位到那张折叠卡，不落「请向上滚动」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await pushToolCalls(tester, turnId: 'turn_1', count: 5);
      expect(
        find.byKey(const ValueKey('tool-call-batch-tile')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        'tool_2',
      );
      await tester.pumpAndSettle();

      // 搜索读的是 `_items`（含全部工具调用），不是展示行。
      final hit = find.byKey(
        const ValueKey('conversation-search-hit-turn_1_tc2'),
      );
      expect(hit, findsOneWidget, reason: '折叠是展示层的事，搜索必须仍能搜到批内第 3 条');

      await tester.tap(hit);
      await tester.pumpAndSettle();

      // 定位走 `_rowKeys`，而键按 `locateIdsOf` 的口径给**每个成员**都登记
      // （AGENTS.md §6.18）。缺一个成员就会退化成这条提示。
      expect(
        find.text('该条在更早的位置，请向上滚动后重试'),
        findsNothing,
        reason: '批内成员必须都能定位到同一张折叠卡',
      );
    });
  });

  group('底部状态条：工具进度优先于活动指示', () {
    testWidgets('有工具调用的流式轮次 → 报「已调用 N 个工具」而不是「已运行 X」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushStreamingText(tester);
      await pushToolCalls(tester, turnId: 'turn_1', count: 2, startSeq: 10);

      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsOneWidget,
        reason: '调了 2 个工具的轮次，底部必须说清楚「它在干活」',
      );
      expect(find.text('已调用 2 个工具'), findsOneWidget);
      expect(find.text('最近：tool_1'), findsOneWidget);
      // 更弱的信号（只报「已运行 X」）让位，否则两条同时出现会打架。
      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
      );
    });

    testWidgets('没有工具调用时仍是原来的活动指示（不抢占既有行为）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      // 活动指示只在「有流式项」的轮次上出现（页面靠流式项找当前轮），
      // 故先推一段无正文的思考——这正是长 turn 静默期的真实形态。
      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent(
          EventTypes.thought,
          id: 'e_thought',
          turnId: 'turn_1',
          transient: true,
          seq: 8,
          payload: {'text': '让我想想…'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          id: 'e_act',
          turnId: 'turn_1',
          transient: true,
          seq: 9,
          payload: {'elapsed_ms': 45000, 'last_event_type': 'bash'},
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsNothing,
      );
    });

    testWidgets('排队/重试提示优先于工具进度（「还没起跑」比「在跑」更该看）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushStreamingText(tester);
      await pushToolCalls(tester, turnId: 'turn_1', count: 2);
      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsOneWidget,
      );

      await pushEvent(
        tester,
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          id: 'e_queue',
          turnId: 'turn_1',
          transient: true,
          seq: 200,
          payload: {'state': 'queued', 'reason': 'concurrency'},
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-execution-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsNothing,
        reason: '两档共用同一槽位，判定顺序写反就会同时出现「在等」与「在跑」',
      );
    });

    testWidgets('离线队列条与状态条可以同时存在（不同槽位，互不挤占）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [
          OutboxEntry(
            id: 'req_1',
            userId: 'usr_1',
            input: '离线时写的这句',
            groupId: 'grp_1',
            createdAt: DateTime.utc(2026, 1, 1),
            nextAttemptAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );

      await pushStreamingText(tester);
      await pushToolCalls(tester, turnId: 'turn_1', count: 2);

      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsOneWidget,
      );
      expect(
        find.text('离线时写的这句'),
        findsOneWidget,
        reason: '改底部槽位时最容易顺手弄丢的就是离线队列条（issue #30）',
      );
    });
  });
}
