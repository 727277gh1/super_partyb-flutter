import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

void main() {
  setUpHarness();
  tearDownHarness();

  Future<void> sent(WidgetTester tester) async {
    await tester.runAsync(() async {
      controller.injectLocalUserMessage(
        input: '开始',
        groupId: 'grp_1',
        turnId: 'turn_1',
      );
      controller.flushEmit();
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> stale(WidgetTester tester, Set<String> ids) async {
    await tester.runAsync(() async {
      staleController.add(ids);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  void expectStatus(WidgetTester tester, String label, {int spinners = 1}) {
    expect(find.byType(TurnStatusStrip), findsOneWidget);
    expect(
      tester.widget<TurnStatusStrip>(find.byType(TurnStatusStrip)).summary.text,
      label,
    );
    expect(find.byType(CircularProgressIndicator), findsNWidgets(spinners));
    expect(find.text('正在生成…'), findsNothing);
    expect(find.text('思考中…'), findsNothing);
  }

  testWidgets('同一轮准备、思考、工具、回复、超时恢复、结束只有一个主状态', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);
    await sent(tester);
    expectStatus(tester, '正在准备响应');

    await pushEvent(
      tester,
      EventTypes.thought,
      sseEvent(
        EventTypes.thought,
        id: 'thought',
        seq: 2,
        transient: true,
        payload: {'text': '分析问题'},
      ),
    );
    expectStatus(tester, '思考中');

    for (var i = 0; i < 2; i++) {
      await pushEvent(
        tester,
        EventTypes.toolCall,
        sseEvent(
          EventTypes.toolCall,
          id: 'call$i',
          seq: 3 + i,
          payload: {'tool_call_id': 'tool$i', 'name': 'bash$i'},
        ),
      );
    }
    expectStatus(tester, '正在执行工具 · bash1');
    await tester.tap(find.byTooltip('查看详情'));
    await tester.pump();
    expectStatus(tester, '正在执行工具 · bash1');
    expect(find.textContaining('已调用 2 个工具'), findsOneWidget);

    for (var i = 0; i < 2; i++) {
      await pushEvent(
        tester,
        EventTypes.toolResult,
        sseEvent(
          EventTypes.toolResult,
          id: 'result$i',
          seq: 5 + i,
          payload: {'tool_call_id': 'tool$i', 'output': 'ok'},
        ),
      );
    }
    expectStatus(tester, '执行中');
    await pushStreamingMessage(tester, id: 'reply', text: '这是结果', seq: 7);
    expectStatus(tester, '正在回复', spinners: 0);
    // 阶段切换不会重建同轮详情，避免用户读到一半被折回去。
    expect(find.byTooltip('收起详情'), findsOneWidget);

    await stale(tester, {'turn_1'});
    expectStatus(tester, '长时间无进展 · 可能仍在后台运行', spinners: 0);
    await stale(tester, {});
    expectStatus(tester, '正在回复', spinners: 0);

    await pushEvent(
      tester,
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: 'done',
        seq: 8,
        payload: {'status': 'completed'},
      ),
    );
    expect(find.byType(TurnStatusStrip), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('没有思考或正文时，工具返回后仍保留轮次状态直到结束', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);
    await sent(tester);
    await pushEvent(
      tester,
      EventTypes.toolCall,
      sseEvent(
        EventTypes.toolCall,
        id: 'call',
        seq: 2,
        payload: {'tool_call_id': 'tool', 'name': 'bash'},
      ),
    );
    expectStatus(tester, '正在执行工具 · bash');
    await pushEvent(
      tester,
      EventTypes.toolResult,
      sseEvent(
        EventTypes.toolResult,
        id: 'result',
        seq: 3,
        payload: {'tool_call_id': 'tool', 'output': 'ok'},
      ),
    );
    expectStatus(tester, '执行中');
    await pushEvent(
      tester,
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: 'done',
        seq: 4,
        payload: {'status': 'completed'},
      ),
    );
    expect(find.byType(TurnStatusStrip), findsNothing);
  });

  testWidgets('准备阶段停止入口在状态栏内，无 AppBar 也能取消', (tester) async {
    final cancelled = <String>[];
    mockTimeline();
    await startController(tester);
    await pumpPage(
      tester,
      title: null,
      onCancelTurn: (id) async => cancelled.add(id),
    );
    await sent(tester);
    final button = find.descendant(
      of: find.byType(TurnStatusStrip),
      matching: find.byKey(const ValueKey('conversation-cancel-turn')),
    );
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(cancelled, ['turn_1']);
  });

  testWidgets('只有排队事件时超时优先，恢复后显示重试，终态后收起', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);
    await pushEvent(
      tester,
      EventTypes.queueState,
      sseEvent(
        EventTypes.queueState,
        id: 'queued',
        seq: 1,
        payload: {'state': 'queued', 'reason': 'session_busy'},
      ),
    );
    expectStatus(tester, '正在等待当前会话完成');
    await stale(tester, {'turn_1'});
    expectStatus(tester, '长时间无进展 · 可能仍在后台运行', spinners: 0);
    await pushEvent(
      tester,
      EventTypes.retryScheduled,
      sseEvent(
        EventTypes.retryScheduled,
        id: 'retry',
        seq: 2,
        payload: {'attempt': 2},
      ),
    );
    await stale(tester, {});
    expectStatus(tester, '正在安排第 2 次重试');
    await pushEvent(
      tester,
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: 'done',
        seq: 3,
        payload: {'status': 'completed'},
      ),
    );
    expect(find.byType(TurnStatusStrip), findsNothing);
  });
}
