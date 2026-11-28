import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 时间线上的归属提示端到端（SSE 事件 → 归约 → 页面渲染）。
///
/// 核心语义：`routing_selected` 与 `user_message` 同 turn 时合并进气泡，
/// 无聊原因（`fixed_reuse` 等）不占任何时间线空间；只有孤儿事件回退成
/// `_RoutingNotice` 独立行（且无聊的孤儿也不渲染）。
void main() {
  setUpHarness();

  group('时间线归属提示（routing_selected 端到端）', () {
    testWidgets('fixed_reuse：时间线既无独立行也无徽标（零空间）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'evt_u1',
          payload: {'input': '在吗'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.routingSelected,
        sseEvent(
          EventTypes.routingSelected,
          id: 'evt_r1',
          payload: {
            'group_decision_reason': 'fixed_reuse',
            'selected_group_id': 'grp_1',
          },
        ),
      );

      expect(find.byType(RoutingNoticeItem), findsNothing);
      expect(find.byType(UserMessageBubble), findsOneWidget);
      expect(find.textContaining('归属'), findsNothing);
      expect(find.text('已自动判定归属'), findsNothing);
      expect(find.text('已新建对话'), findsNothing);
      expect(find.text('已切换对话'), findsNothing);
    });

    testWidgets('create_new：气泡上出现「已新建对话」徽标，无独立行', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'evt_u1',
          payload: {'input': '开工'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.routingSelected,
        sseEvent(
          EventTypes.routingSelected,
          id: 'evt_r1',
          payload: {
            'group_decision_reason': 'create_new',
            'selected_group_id': 'grp_new',
          },
        ),
      );

      expect(find.byType(RoutingNoticeItem), findsNothing);
      expect(find.text('已新建对话'), findsOneWidget);
    });

    testWidgets('group_switched：气泡上出现「已切换对话」徽标', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'evt_u1',
          payload: {'input': '这件事接着办'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.routingSelected,
        sseEvent(
          EventTypes.routingSelected,
          id: 'evt_r1',
          payload: {
            'group_decision_reason': 'classify_reuse',
            'selected_group_id': 'grp_other',
            'group_switched': true,
          },
        ),
      );

      expect(find.byType(RoutingNoticeItem), findsNothing);
      expect(find.text('已切换对话'), findsOneWidget);
    });

    testWidgets('孤儿事件（无聊原因）：归约层丢弃后时间线干净', (tester) async {
      await startController(tester);
      // 只有归属事件、没有用户消息（空文本被跳过的模拟）。
      await pushEvent(
        tester,
        EventTypes.routingSelected,
        sseEvent(
          EventTypes.routingSelected,
          id: 'evt_r1',
          payload: {'group_decision_reason': 'fixed_reuse'},
        ),
      );

      expect(find.byType(RoutingNoticeItem), findsNothing);
      expect(find.textContaining('fixed_reuse'), findsNothing);
    });

    testWidgets('孤儿事件（新建原因）：回退成居中提示行', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.routingSelected,
        sseEvent(
          EventTypes.routingSelected,
          id: 'evt_r1',
          payload: {'group_decision_reason': 'create_new'},
        ),
      );

      expect(find.textContaining('create_new'), findsNothing);
      expect(find.text('已新建对话'), findsOneWidget);
    });
  });
}
