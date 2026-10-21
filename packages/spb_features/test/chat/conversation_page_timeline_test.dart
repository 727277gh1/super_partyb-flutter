import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 时间线渲染与各类卡片（时间线 / 目标 / 排程 / 反馈 / 习惯 / 确认）
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

  group('ConversationPage 时间线渲染', () {
    testWidgets('空列表显示空提示', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, title: null);

      expect(find.text('还没有对话，输入消息开始吧'), findsOneWidget);
    });

    testWidgets('用户消息与助手回复分别渲染为气泡', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent('user_message', id: 'e1', payload: {'input': '你好'}),
      );

      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent('message', id: 'e2', payload: {'text': '你好，有什么可以帮你'}, seq: 2),
      );

      expect(find.text('你好'), findsOneWidget);
      expect(find.text('你好，有什么可以帮你'), findsOneWidget);
    });

    testWidgets('思考项渲染为可折叠 tile', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent('thought', id: 'e1', payload: {'text': '我在想'}),
      );

      expect(find.text('思考过程'), findsOneWidget);
    });

    testWidgets('工具调用项渲染', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.toolCall,
        sseEvent('tool_call', id: 'e1', payload: {'name': 'bash'}),
      );

      expect(find.text('bash'), findsOneWidget);
    });

    testWidgets('后续建议渲染为 chip', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.followUpSuggested,
        sseEvent(
          'follow_up_suggested',
          id: 'e1',
          payload: {
            'suggestions': ['再详细点'],
          },
        ),
      );

      expect(find.text('再详细点'), findsOneWidget);
    });
  });

  group('ConversationPage 后续提问建议（agent 标注）', () {
    Future<void> pushFollowUp(WidgetTester tester) => pushEvent(
      tester,
      EventTypes.followUpSuggested,
      sseEvent(
        'follow_up_suggested',
        id: 'evt_fu',
        payload: {
          'suggestions': [
            {'id': 's0', 'title': '总结要点', 'text': '帮我总结要点'},
            {
              'id': 's1',
              'title': '查漏补缺',
              'text': '帮我查漏补缺',
              'agent_id': 'agt_review',
            },
          ],
        },
      ),
    );

    testWidgets('点了带 agent_id 的建议：先切 agent，再把文本回填输入框', (tester) async {
      // 语义对齐 webapp FollowUpSuggestCard：服务端按钮动作是 copy_text
      // 「点击复制问题，可修改后再发送」，故**回填输入框**而非直接发送。
      // 顺序固定「切 agent → 追加」。
      final order = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onSelectAgent: (id) => order.add('agent:$id'),
        onSpecAction: (action) => order.add('action:${action.type.name}'),
      );
      await pushFollowUp(tester);

      // chip 展示的是 suggestions[].text（不是 title）——`followUpSuggestions`
      // 取 text ?? title。
      expect(find.text('帮我查漏补缺'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('follow-up-帮我查漏补缺')));
      await tester.pump();

      expect(order, ['agent:agt_review'], reason: '切 agent 由 onSelectAgent 上报');
      // 回填写在输入框里（不产生网络动作）：断言输入框拿到了建议文本。
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        contains('帮我查漏补缺'),
      );
    });

    testWidgets('未标注 agent_id 的建议只回填（不误切 agent）', (tester) async {
      final order = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onSelectAgent: (id) => order.add('agent:$id'),
        onSpecAction: (_) {},
      );
      await pushFollowUp(tester);

      await tester.tap(find.byKey(const ValueKey('follow-up-帮我总结要点')));
      await tester.pump();

      expect(order, isEmpty, reason: '该建议无 agent_id，不得切换');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        contains('帮我总结要点'),
      );
    });
  });

  group('ConversationPage 目标进度卡（goal_gate spec）', () {
    testWidgets('goal_gate_decision 带 spec_schema 时渲染进度卡', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.goalGateDecision,
        sseEvent(
          'goal_gate_decision',
          id: 'evt_goal',
          payload: {
            'root': 'goal-card',
            'goal': '整理周报',
            'status': '进行中',
            'spec_schema': {
              'root': 'goal-card',
              'elements': {
                'goal-card': {
                  'type': 'card',
                  'props': {'title': '目标进度'},
                  'children': ['goal-progress', 'goal-status'],
                },
                'goal-progress': {
                  'type': 'progress',
                  'props': {'value': 40, 'label': '2/5'},
                },
                'goal-status': {
                  'type': 'metric',
                  'props': {'value': '进行中', 'hint': '下一个：写文档'},
                },
              },
            },
          },
        ),
      );

      expect(find.text('目标进度'), findsOneWidget);
      expect(find.byKey(const ValueKey('spec-progress-bar')), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
    });

    testWidgets('spec_schema 损坏时不产出进度卡，时间线其余部分照常', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.goalGateDecision,
        sseEvent(
          'goal_gate_decision',
          id: 'evt_goal',
          payload: {'spec_schema': 'not-a-spec'},
        ),
      );

      expect(find.byKey(const ValueKey('spec-progress-bar')), findsNothing);
      expect(tester.takeException(), isNull, reason: '损坏的 spec 必须静默降级，不能炸掉时间线');
    });
  });

  group('ConversationPage 目标自动推进停止（goal_gate_stopped）', () {
    testWidgets('渲染停止提示与轮次副文案', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.goalGateStopped,
        sseEvent(
          'goal_gate_stopped',
          id: 'evt_gate_stop',
          payload: {
            'reason': 'max_auto_turns_reached',
            'auto_turn_count': 5,
            'max_auto_turns': 5,
          },
        ),
      );

      expect(
        find.byKey(const ValueKey('goal-gate-stopped-notice')),
        findsOneWidget,
        reason: 'goal_gate_stopped 必须渲染（此前落到 default 被静默丢弃）',
      );
      expect(find.text('已达自动推进轮次上限，发送新消息后可继续'), findsOneWidget);
      expect(find.text('已自动推进 5/5 轮'), findsOneWidget);
    });

    testWidgets('目标达成用中性样式，不误渲染为错误卡', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.goalGateStopped,
        sseEvent(
          'goal_gate_stopped',
          id: 'evt_gate_done',
          payload: {'reason': 'goal_completed'},
        ),
      );

      expect(find.text('目标已实现，自动推进已停用'), findsOneWidget);
      // goal_completed 是**成功终态**，用错误红底会让用户以为失败了。
      expect(find.byType(Card), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('ConversationPage 自动续跑排程（schedule_created）', () {
    testWidgets('渲染「多久后继续」与轮次进度', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.scheduleCreated,
        sseEvent(
          'schedule_created',
          id: 'evt_sched_1',
          payload: {
            'schedule_id': 'sched_1',
            'reason': 'done',
            'status': 'pending',
            'delay_seconds': 30,
            'source': 'goal_gate',
            'auto_turn_count': 2,
            'max_auto_turns': 5,
          },
        ),
      );

      expect(
        find.byKey(const ValueKey('schedule-created-notice')),
        findsOneWidget,
        reason: 'schedule_created 必须渲染（此前落到 default 被静默丢弃）',
      );
      expect(find.text('将在 30 秒后自动继续（第 2/5 轮）'), findsOneWidget);
    });

    testWidgets('缺 delay_seconds 时不编造秒数', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.scheduleCreated,
        sseEvent('schedule_created', id: 'evt_sched_2', payload: {}),
      );

      expect(
        find.byKey(const ValueKey('schedule-created-notice')),
        findsOneWidget,
      );
      expect(find.text('已排入下一轮自动继续'), findsOneWidget);
      // 兜底文案里不能出现任何秒数（编造的时间会让用户真的去等它）。
      expect(find.textContaining('秒'), findsNothing);
    });

    testWidgets('与「已停止」提示视觉可区分（不是同一个 key）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.scheduleCreated,
        sseEvent(
          'schedule_created',
          id: 'evt_sched_3',
          payload: {'delay_seconds': 10},
        ),
      );

      expect(
        find.byKey(const ValueKey('schedule-created-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goal-gate-stopped-notice')),
        findsNothing,
        reason: '「即将继续」与「已停止」是两个相反结论，不能长得一样',
      );
    });
  });

  group('ConversationPage 会话绑定失效诊断（pigo_session_missing）', () {
    testWidgets('渲染诊断提示并透传服务端说明', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.pigoSessionMissing,
        sseEvent(
          'pigo_session_missing',
          id: 'evt_ghost',
          payload: {
            'content': '检测到失效的会话绑定（历史会话文件未落盘），本次将新建会话继续',
            'session_id': 'sess-ghost-1',
          },
        ),
      );

      expect(
        find.byKey(const ValueKey('diagnostic-notice')),
        findsOneWidget,
        reason: 'pigo_session_missing 必须渲染（此前全仓零消费）',
      );
      expect(find.textContaining('失效的会话绑定'), findsOneWidget);
    });

    testWidgets('载荷缺 content 时用兜底文案，不渲染空壳', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.pigoSessionMissing,
        sseEvent('pigo_session_missing', id: 'evt_ghost2', payload: {}),
      );

      expect(find.byKey(const ValueKey('diagnostic-notice')), findsOneWidget);
      expect(find.text('检测到失效的会话绑定，本次将新建会话继续'), findsOneWidget);
    });
  });

  group('ConversationPage 归属反馈卡', () {
    /// 推一条归属反馈请求事件。
    Future<void> pushFeedback(
      WidgetTester tester, {
      String id = 'evt_fb',
      String token = 'evt_fb',
      bool includeToken = true,
    }) => pushEvent(
      tester,
      EventTypes.routingFeedbackRequest,
      sseEvent(
        'routing_feedback_request',
        id: id,
        payload: {
          'question': '这条消息我归到了《团队周报》，准确吗？',
          'options': [
            {'label': '准确', 'reply': '反馈#正确'},
            {'label': '不准确', 'reply': '反馈#错误'},
          ],
          if (includeToken) 'token': token,
          'evaluated_turn_id': 'turn_1',
        },
      ),
    );

    testWidgets('routing_feedback_request 渲染为卡片，点击回调收到 token 与 bool', (
      tester,
    ) async {
      final calls = <(String, bool)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async =>
            calls.add((token, correct)),
      );
      await pushFeedback(tester);

      expect(find.text('这次归属准确吗？'), findsOneWidget);
      expect(find.text('这条消息我归到了《团队周报》，准确吗？'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1, 'evt_fb', reason: 'token 是回执锚点（= 事件 id）');
      expect(calls.single.$2, isTrue);
    });

    testWidgets('提交成功后本地置灰（不等 routing_feedback 事件）', (tester) async {
      // ## 这条用例钉住的真实报障
      //
      // 回执是一次性 CAS，而卡片置灰此前**只**看服务端的 `routing_feedback`
      // 事件。该事件是旁路事件：SSE 断线/回放窗口缺失时永不到达，于是用户
      // 看到按钮仍可点 → 再点 → 404 → 反复重试一张已作答的卡。
      //
      // 修复前本断言会失败（卡片仍显示「这次归属准确吗？」）。
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onResolveFeedback: (token, correct) async {});
      await pushFeedback(tester);

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();

      expect(
        find.text('已反馈'),
        findsOneWidget,
        reason: '成功提交后必须立即置灰，不能等服务端旁路事件',
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull, reason: '已作答的卡不得再可点（重试必然 404）');
    });

    testWidgets('提交失败时提示且保留可点（不把网络故障变成只读卡）', (tester) async {
      // 反方向：若失败也置灰，一次网络抖动就让用户永久失去作答机会。
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async =>
            throw const NetworkError('连接超时'),
      );
      await pushFeedback(tester);

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();

      expect(find.textContaining('反馈提交失败'), findsOneWidget);
      expect(find.text('这次归属准确吗？'), findsOneWidget, reason: '失败不得置灰');
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNotNull, reason: '失败后必须可重试');
    });

    testWidgets('404 的提示是「已失效」而不是「提交失败」', (tester) async {
      // 404 在服务端有确定含义（已过期 / 已消费 / 非本人，三者统一 404）。
      // 文案若写成「提交失败」，用户会反复重试一个永远不会成功的请求。
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async =>
            throw const HttpError(404, 'HTTP 404'),
      );
      await pushFeedback(tester);

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();

      expect(find.text('这条反馈已失效，无法再作答'), findsOneWidget);
    });

    testWidgets('token 缺失时按钮禁用（提交必然失败，不退化用事件 id）', (tester) async {
      final calls = <(String, bool)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async =>
            calls.add((token, correct)),
      );
      await pushFeedback(tester, includeToken: false);

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull);
      expect(calls, isEmpty);
    });

    testWidgets('onResolveFeedback 未注入时按钮禁用（移动端旧装配不炸）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushFeedback(tester);

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('超过服务端下发的有效期时直接置灰为「已失效」', (tester) async {
      // ## 这条用例钉住的真实报障
      //
      // 请求事件的 payload 不带 expires_at，而回执过期后服务端统一返 404。
      // 修复前客户端无从判断「还没答」与「已经失效」——用户点一张早就过期的
      // 卡得到 404，表现就是「点了没反应」。
      //
      // 夹具里事件 createdAt 固定为 2024-03-05T08:09:10Z（见 sseEvent），
      // 故注入一个**极短**的 TTL 就能让它在「现在」看来已过期。
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async {},
        feedbackTTL: const Duration(seconds: 1),
      );
      await pushFeedback(tester);

      expect(
        find.text('已失效'),
        findsOneWidget,
        reason: '过期卡片必须显式告知已失效，而不是让用户点下去才得到 404',
      );
      expect(
        find.text('已反馈'),
        findsNothing,
        reason: '用户没答过，不能显示成「已反馈」（把未发生的事显示成已发生）',
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull, reason: '过期后点下去必然 404，不得可点');
    });

    testWidgets('TTL 未下发（旧版后端）时不做失效判定，保持可点', (tester) async {
      // 反方向：把「未下发」当成「立即过期」会让所有卡片一次性变灰，
      // 比不判定更糟（同 TurnRuntime.clientTurnTimeout 对 0 的处理取向）。
      final calls = <(String, bool)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) async =>
            calls.add((token, correct)),
        // 不传 feedbackTTL → 控制器保持 null。
      );
      await pushFeedback(tester);

      expect(find.text('这次归属准确吗？'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNotNull, reason: '未下发 TTL 时应保持旧行为（可点）');

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
    });
  });

  group('ConversationPage 习惯建议卡', () {
    /// `habit_suggestion_created` 的服务端载荷（snake_case，见
    /// `workers/habit/timeline_events.go`）。
    Map<String, dynamic> createdPayload({
      String id = 'run-sugg-1',
      String topicKey = 'weekly-report',
    }) => {
      'suggestion_id': id,
      'habit_pattern_id': null,
      'status': 'pending',
      'trigger_type': 'time_based',
      'recommendation': {
        'action': 'accept_rule',
        'confidence': 0.72,
        'reasons': ['每周一你都会让我写周报'],
      },
      'rule_draft': {
        'topic_key': topicKey,
        'trigger_type': 'time_based',
        'trigger_config': {
          'hour': 9,
          'weekday': [1],
        },
        'delivery_group_id': 'grp-1',
        'target_acceptance_level': 'suggest_only',
      },
      'evidence': {'occurrences': 3},
      'editable_fields': ['topic_key', 'trigger_config'],
    };

    /// 推一条建议卡事件。
    Future<void> pushSuggestion(
      WidgetTester tester, {
      String id = 'run-sugg-1',
      String eventId = 'evt_sugg',
    }) async {
      await pushEvent(
        tester,
        EventTypes.habitSuggestionCreated,
        sseEvent(
          EventTypes.habitSuggestionCreated,
          id: eventId,
          payload: createdPayload(id: id),
        ),
      );
    }

    testWidgets('建议卡渲染（不再被 default 分支丢弃）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onAcceptHabit: (_) {}, onDismissHabit: (_) {});

      await pushSuggestion(tester);

      expect(find.byType(HabitSuggestionCard), findsOneWidget);
      expect(find.text('weekly report'), findsOneWidget);
    });

    testWidgets('点接受回调收到该建议（而非事件 id）', (tester) async {
      final seen = <HabitSuggestionItem>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onAcceptHabit: seen.add);

      await pushSuggestion(tester);
      await tester.tap(find.byKey(const ValueKey('habit-accept')));
      await tester.pumpAndSettle();

      expect(seen, hasLength(1));
      // 身份键是 suggestion_id（服务端 resolve 路径里的 id），不是事件 id。
      expect(seen.single.suggestionId, 'run-sugg-1');
    });

    testWidgets('点忽略回调收到该建议', (tester) async {
      final seen = <HabitSuggestionItem>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onDismissHabit: seen.add);

      await pushSuggestion(tester);
      await tester.tap(find.byKey(const ValueKey('habit-dismiss')));
      await tester.pumpAndSettle();

      expect(seen.single.suggestionId, 'run-sugg-1');
    });

    testWidgets('稍后提醒：回调收到选中的时长选项', (tester) async {
      final seen = <(HabitSuggestionItem, HabitSnoozeOption)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onSnoozeHabit: (s, o) => seen.add((s, o)));

      await pushSuggestion(tester);
      await tester.tap(find.byKey(const ValueKey('habit-snooze')));
      await tester.pumpAndSettle();

      // 选一个具体时长（选项由 `HabitSnoozeOption` 定义，不在此处硬编时间）。
      final option = HabitSnoozeOption.values.first;
      await tester.tap(find.text(option.label));
      await tester.pumpAndSettle();

      expect(seen, hasLength(1));
      expect(seen.single.$1.suggestionId, 'run-sugg-1');
      expect(seen.single.$2, option);
    });

    testWidgets('未注入回调时三个按钮都不显示（只读装配不炸）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushSuggestion(tester);

      // 卡本身仍要渲染（历史回看能看到「当时建议过什么」）。
      expect(find.byType(HabitSuggestionCard), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
      expect(find.byKey(const ValueKey('habit-dismiss')), findsNothing);
      expect(find.byKey(const ValueKey('habit-snooze')), findsNothing);
    });

    testWidgets('已 resolved 的卡不再显示操作按钮（不显示必然 409 的按钮）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onAcceptHabit: (_) {}, onDismissHabit: (_) {});

      await pushSuggestion(tester);
      // resolved 事件与 created 同 turn（服务端 resolve 时重取最近 turn）。
      await pushEvent(
        tester,
        EventTypes.habitSuggestionResolved,
        sseEvent(
          EventTypes.habitSuggestionResolved,
          id: 'evt_res',
          payload: const {
            'suggestion_id': 'run-sugg-1',
            'status': 'resolved',
            'action': 'accept',
            'user_feedback': 'accepted',
            'resolved_pattern_id': 'hp-1',
          },
        ),
      );

      // 卡不隐藏（历史回看需要看到「建议过什么、答了什么」），只置灰。
      expect(find.byType(HabitSuggestionCard), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
      expect(find.byKey(const ValueKey('habit-dismiss')), findsNothing);
    });

    testWidgets('两张建议卡按 suggestionId 各自独立（不互相覆盖）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onAcceptHabit: (_) {});

      await pushSuggestion(tester, id: 'sugg-a', eventId: 'evt_a');
      await pushSuggestion(tester, id: 'sugg-b', eventId: 'evt_b');

      expect(find.byType(HabitSuggestionCard), findsNWidgets(2));
    });
  });

  group('ConversationPage 确认卡', () {
    testWidgets('点击选项回调收到【卡行 id】而非事件 id', (tester) async {
      // 这是本页最容易错的一处：ConfirmationItem.id 是**事件 id**，而 resolve
      // 端点要的是 chat_confirmations.id（payload.confirmation_id）。
      // 传错会 404 且不报错（0 行受影响），表现为「点了按钮没反应」。
      final calls = <(String, String, String)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveConfirmation: (gid, id, opt) => calls.add((gid, id, opt)),
      );

      await pushEvent(
        tester,
        EventTypes.confirmationRequired,
        sseEvent(
          'confirmation_required',
          id: 'evt_abc',
          payload: {
            'confirmation_id': 'conf_row_xyz',
            'recommendation': {'action': 'continue', 'confidence': 0.9},
          },
        ),
      );

      expect(find.text('需要你的确认'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('confirmation-option-继续')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1, 'grp_1', reason: 'groupId 用于拼 resolve 路径');
      expect(calls.single.$2, 'conf_row_xyz', reason: '必须是卡行 id，不是 evt_abc');
      expect(calls.single.$3, '继续');
    });

    testWidgets('事件未携带 confirmation_id 时按钮禁用（不退化用事件 id）', (tester) async {
      final calls = <(String, String, String)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveConfirmation: (gid, id, opt) => calls.add((gid, id, opt)),
      );

      await pushEvent(
        tester,
        EventTypes.confirmationRequired,
        sseEvent('confirmation_required', id: 'evt_only', payload: const {}),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull, reason: '缺 id 应禁用，而不是拿事件 id 去试');
      expect(calls, isEmpty);
    });
  });
}
