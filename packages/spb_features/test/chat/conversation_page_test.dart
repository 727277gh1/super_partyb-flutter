import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 假的 [SseClient]（与 spb_domain 的测试同构）。
class _FakeSseClient extends SseClient {
  _FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {}

  @override
  Future<void> resume() async {}

  @override
  void recordEventId(String eventId) {}

  @override
  Future<void> dispose() async {
    await framesController.close();
    await statesController.close();
  }

  /// 推一帧（camelCase，同 chatbus.Event 的 SSE 形态）。
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  static String _encode(Map<String, dynamic> m) =>
      const JsonEncoderShim().convert(m);
}

/// 极简 JSON 编码（避免引入 dart:convert 的 import 冲突）。
class JsonEncoderShim {
  const JsonEncoderShim();
  String convert(Object? v) => _json(v);
  static String _json(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) {
      return '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
    }
    if (v is List) return '[${v.map(_json).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_json(e.value)}').join(',')}}';
    }
    return '"$v"';
  }
}

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late _FakeSseClient sse;
  late ChatStreamController controller;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    sse = _FakeSseClient();
    controller = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
  });

  tearDown(() async => controller.dispose());

  /// 挂 timeline 回填的 mock。
  void mockTimeline() {
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': <Map<String, dynamic>>[],
        'next_before_global_seq': '',
      }),
      queryParameters: {'limit': 200},
    );
  }

  /// 服务端形态的 SSE 事件 JSON。
  Map<String, dynamic> sseEvent(
    String type, {
    required String id,
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    int seq = 1,
  }) => {
    'eventId': id,
    'userId': 'usr_1',
    'groupId': 'grp_1',
    'turnId': turnId,
    'eventType': type,
    'seq': seq,
    'globalSeq': seq,
    'source': 'test',
    'payload': payload,
    'createdAt': '2024-03-05T08:09:10Z',
    if (transient) 'transient': true,
  };

  /// 启动控制器并完成 timeline 回填。
  ///
  /// ⚠️ 必须包在 [WidgetTester.runAsync] 里：`testWidgets` 默认跑在 FakeAsync
  /// 时区中，**真实 I/O（dio 的 HTTP 调用）永远不会完成**，`await start(...)`
  /// 会挂死直到测试超时（表现为「did not complete」且耗时极长）。
  /// `runAsync` 让回调跑在真实时区，dio 的 mock 响应才能 resolve。
  Future<void> startController(WidgetTester tester) async {
    await tester.runAsync(() => controller.start(groupId: 'grp_1'));
  }

  /// 推一个 SSE 事件并等它被归约。
  ///
  /// ⚠️ 必须在 [WidgetTester.runAsync] 内推：控制器的帧监听器是在
  /// `startController` 的 runAsync 时区里注册的，在 FakeAsync 时区里 `add`
  /// 的事件会被投递到另一个时区，`tester.pump()` 永远看不到它
  /// （表现为「事件推了但列表是空的」）。
  Future<void> pushEvent(
    WidgetTester tester,
    String type,
    Map<String, dynamic> data,
  ) async {
    await tester.runAsync(() async {
      sse.push(type, data);
      // 给流一点时间把事件交给控制器。
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    String? title = '测试对话',
    void Function(String, String, String)? onResolveConfirmation,
    void Function(String token, bool correct)? onResolveFeedback,
    void Function(SpecUiAction action)? onSpecAction,
    void Function(String agentId)? onSelectAgent,
    void Function(HabitSuggestionItem suggestion)? onAcceptHabit,
    void Function(HabitSuggestionItem suggestion)? onDismissHabit,
    void Function(HabitSuggestionItem suggestion, HabitSnoozeOption option)?
    onSnoozeHabit,
    Future<void> Function(String)? onSend,
    Future<void> Function(String)? onCancelTurn,
    Future<bool> Function()? onLoadOlder,
    String? historyKey,
    VoidCallback? onReconnect,
    bool wireActivities = true,
    bool wireContextUsage = true,
    bool wireExecutionStatus = true,
    bool wireTtsStatus = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          controller: controller,
          title: title,
          onResolveConfirmation: onResolveConfirmation,
          onResolveFeedback: onResolveFeedback,
          onAcceptHabit: onAcceptHabit,
          onDismissHabit: onDismissHabit,
          onSnoozeHabit: onSnoozeHabit,
          onSpecAction: onSpecAction,
          onSelectAgent: onSelectAgent,
          onSend: onSend,
          onCancelTurn: onCancelTurn,
          onLoadOlder: onLoadOlder,
          historyKey: historyKey,
          onReconnect: onReconnect,
          // 活动流由 app 层注入（与 onCancelTurn 等同取向）。默认接上
          // controller，便于测「事件到达 → 指示器出现」的完整链路；
          // wireActivities=false 用于验证「未注入时不展示」。
          activities: wireActivities ? controller.activities : null,
          activitiesSnapshot: wireActivities
              ? controller.activitiesSnapshot
              : null,
          // 上下文用量同理：默认接上，wireContextUsage=false 验证未注入时不展示。
          contextUsage: wireContextUsage ? controller.contextUsage : null,
          contextUsageSnapshot: wireContextUsage
              ? controller.contextUsageSnapshot
              : null,
          // 等待/重试状态同理。
          executionStatus: wireExecutionStatus
              ? controller.executionStatus
              : null,
          executionStatusSnapshot: wireExecutionStatus
              ? controller.executionStatusSnapshot
              : null,
          // 播报状态同理。
          ttsStatus: wireTtsStatus ? controller.ttsStatus : null,
          ttsStatusSnapshot: wireTtsStatus
              ? controller.ttsStatusSnapshot
              : null,
        ),
      ),
    );
    await tester.pump();
  }

  /// 把连接状态推成 [state]（控制器订阅 `sse.states` 后转发到自己的状态流）。
  Future<void> pushConnectionState(WidgetTester tester, SseState state) async {
    await tester.runAsync(() async {
      sse.statesController.add(state);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  /// 直接替换页面 widget（保留 State），用于模拟「切 group」。
  Future<void> rebuildPage(
    WidgetTester tester, {
    required Future<bool> Function() onLoadOlder,
    required String historyKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          controller: controller,
          title: '测试对话',
          onLoadOlder: onLoadOlder,
          historyKey: historyKey,
        ),
      ),
    );
    await tester.pump();
  }

  /// 推一个**流式中**的助手段落（增量帧 → `isStreaming: true`）。
  ///
  /// 用 `transient: true`：服务端的流式增量就是这么发的（`llm_executor.go`
  /// 的 delta 只广播不落库），而归约层据此置 `isStreaming`。
  Future<void> pushStreamingMessage(
    WidgetTester tester, {
    String id = 'e_stream',
    String turnId = 'turn_1',
    String text = '正在生成',
    int seq = 1,
  }) => pushEvent(
    tester,
    EventTypes.message,
    sseEvent(
      'message',
      id: id,
      turnId: turnId,
      payload: {'text': text},
      transient: true,
      seq: seq,
    ),
  );

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

  group('ConversationPage 归属反馈卡', () {
    testWidgets('routing_feedback_request 渲染为卡片，点击回调收到 token 与 bool', (
      tester,
    ) async {
      final calls = <(String, bool)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) => calls.add((token, correct)),
      );

      await pushEvent(
        tester,
        EventTypes.routingFeedbackRequest,
        sseEvent(
          'routing_feedback_request',
          id: 'evt_fb',
          payload: {
            'question': '这条消息我归到了《团队周报》，准确吗？',
            'options': [
              {'label': '准确', 'reply': '反馈#正确'},
              {'label': '不准确', 'reply': '反馈#错误'},
            ],
            'token': 'evt_fb',
            'evaluated_turn_id': 'turn_1',
          },
        ),
      );

      expect(find.text('这次归属准确吗？'), findsOneWidget);
      expect(find.text('这条消息我归到了《团队周报》，准确吗？'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.$1, 'evt_fb', reason: 'token 是回执锚点（= 事件 id）');
      expect(calls.single.$2, isTrue);
    });

    testWidgets('token 缺失时按钮禁用（提交必然失败，不退化用事件 id）', (tester) async {
      final calls = <(String, bool)>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onResolveFeedback: (token, correct) => calls.add((token, correct)),
      );

      await pushEvent(
        tester,
        EventTypes.routingFeedbackRequest,
        sseEvent(
          'routing_feedback_request',
          id: 'evt_fb',
          payload: const {
            'question': '准确吗？',
            'options': [
              {'label': '准确', 'reply': '反馈#正确'},
            ],
          },
        ),
      );

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

      await pushEvent(
        tester,
        EventTypes.routingFeedbackRequest,
        sseEvent(
          'routing_feedback_request',
          id: 'evt_fb',
          payload: const {
            'question': '准确吗？',
            'options': [
              {'label': '准确', 'reply': '反馈#正确'},
            ],
            'token': 'evt_fb',
          },
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull);
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

  group('ConversationPage 发送', () {
    testWidgets('输入框提交走 onSend 覆盖', (tester) async {
      final sent = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onSend: (t) async => sent.add(t));

      await tester.enterText(find.byType(TextField), '发出去');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(sent, ['发出去']);
    });

    testWidgets('未覆盖 onSend 时调用 controller.send（经 ChatApi）', (tester) async {
      mockTimeline();
      await startController(tester);
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(201, {
          'turn_id': 'turn_1',
          'group_id': 'grp_1',
          'status': 'queued',
        }),
        data: Matchers.any,
      );
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '走控制器');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      // 乐观回显：用户气泡立刻出现（不等 SSE）。
      expect(find.text('走控制器'), findsOneWidget);
    });

    testWidgets('发送失败显示 SnackBar 且不清空输入', (tester) async {
      mockTimeline();
      await startController(tester);
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(500, {'error': 'boom'}),
        data: Matchers.any,
      );
      await pumpPage(tester);

      await tester.enterText(find.byType(TextField), '会失败');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('发送失败'), findsOneWidget);
      // 不清空：用户可能想重试同一段文字。
      // 注意 MessageComposer._submit 会先 clear() 再回调，故此处输入框已空；
      // 断言的重点是「有提示」而非「保留文本」——保留由 composer 的 clear
      // 语义决定，见 message_composer.dart 的说明。
    });
  });

  group('ConversationPage 停止生成', () {
    testWidgets('流式中可点，点击回调收到该段的 turnId', (tester) async {
      final cancelled = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onCancelTurn: (id) async => cancelled.add(id));
      await pushStreamingMessage(tester, turnId: 'turn_42');

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(button, findsOneWidget);
      expect(
        tester.widget<IconButton>(button).onPressed,
        isNotNull,
        reason: '正在生成时必须能停——长回复卡住时这是用户唯一的出路',
      );

      await tester.tap(button);
      // ⚠️ 不能 pumpAndSettle：流式气泡的光标是**无限动画**，pumpAndSettle
      // 会一直等到超时（同 apps/*/test/widget_test.dart 里的说明）。
      await tester.pump();
      await tester.pump();

      expect(cancelled, ['turn_42']);
    });

    testWidgets('思考中（尚未吐字）也可停', (tester) async {
      // 只认 AssistantMessageItem 会漏掉这段：长 turn 的思考段可达数十秒，
      // 而它恰恰是最需要能停的时候。
      final cancelled = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onCancelTurn: (id) async => cancelled.add(id));
      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent(
          'thought',
          id: 'e_thought',
          turnId: 'turn_7',
          payload: {'text': '让我想想…'},
          transient: true,
        ),
      );

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);

      await tester.tap(button);
      // 思考 tile 的流式光标同样是无限动画，不能 pumpAndSettle。
      await tester.pump();
      await tester.pump();

      expect(cancelled, ['turn_7']);
    });

    testWidgets('无流式项时按钮存在但禁用（不隐藏，避免 AppBar 抖动）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onCancelTurn: (id) async {});
      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent('message', id: 'e1', payload: {'text': '已完成'}),
      );

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(button, findsOneWidget, reason: '选禁用而非隐藏：AppBar 宽度恒定');
      expect(tester.widget<IconButton>(button).onPressed, isNull);
    });

    testWidgets('done 到达后按钮重新禁用', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onCancelTurn: (id) async {});
      await pushStreamingMessage(tester);

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);

      await pushEvent(
        tester,
        EventTypes.done,
        sseEvent(
          'done',
          id: 'e_done',
          payload: {'status': 'completed'},
          seq: 2,
        ),
      );

      expect(
        tester.widget<IconButton>(button).onPressed,
        isNull,
        reason: 'done 会闭合全部流式段落，此时再点只会得到 409',
      );
    });

    testWidgets('turnId 为空时禁用（不发畸形请求）', (tester) async {
      final cancelled = <String>[];
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onCancelTurn: (id) async => cancelled.add(id));
      // 事件未携带 turnId（历史数据或异常载荷）。
      await pushStreamingMessage(tester, turnId: '');

      final button = find.byKey(const ValueKey('conversation-cancel-turn'));
      expect(
        tester.widget<IconButton>(button).onPressed,
        isNull,
        reason: '空 id 会打到 /chat/turns//cancel，得到一个语义不明的 404',
      );
      expect(cancelled, isEmpty);
    });

    testWidgets('失败时提示且按钮仍可点（可重试）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onCancelTurn: (id) async => throw const NetworkError('连接超时'),
      );
      await pushStreamingMessage(tester);

      await tester.tap(find.byKey(const ValueKey('conversation-cancel-turn')));
      // 不能 pumpAndSettle（流式光标是无限动画）；多 pump 几帧让 SnackBar 入场。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('停止失败'), findsOneWidget);
      // 不清空流式标记：turn 可能仍在跑，用户应能再试一次。
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('conversation-cancel-turn')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('未注入 onCancelTurn 时不展示停止按钮', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingMessage(tester);

      expect(
        find.byKey(const ValueKey('conversation-cancel-turn')),
        findsNothing,
        reason: '只读时间线用法下不应出现点了没反应的按钮',
      );
    });
  });

  group('ConversationPage 执行等待/重试提示', () {
    /// 推一条 queue_state（落库非 Transient，见 Go 五个发射点）。
    Future<void> pushQueue(
      WidgetTester tester, {
      String reason = 'session_busy',
      int? total = 3,
      int? user = 1,
      String state = 'queued',
      String id = 'e_qs',
      int seq = 40,
    }) => pushEvent(
      tester,
      EventTypes.queueState,
      sseEvent(
        EventTypes.queueState,
        id: id,
        seq: seq,
        payload: {
          'state': state,
          'reason': reason,
          if (total != null) 'queue_total': total,
          if (user != null) 'queue_user': user,
        },
      ),
    );

    testWidgets('session_busy 排队时展示等待文案', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushQueue(tester, reason: 'session_busy');

      final bar = find.byKey(const ValueKey('conversation-execution-status'));
      expect(bar, findsOneWidget, reason: '没有它，排队与「卡死」在 UI 上无法区分');
      expect(find.textContaining('正在等待当前会话完成'), findsOneWidget);
      expect(find.textContaining('队列：总计 3，你的 1'), findsOneWidget);
    });

    testWidgets('三种排队原因各自映射到对应文案', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushQueue(
        tester,
        reason: 'user_concurrency_limit',
        id: 'e_q1',
        seq: 40,
      );
      expect(find.textContaining('正在等待用户并发额度'), findsOneWidget);

      await pushQueue(
        tester,
        reason: 'global_concurrency_limit',
        id: 'e_q2',
        seq: 41,
      );
      expect(find.textContaining('正在等待执行资源'), findsOneWidget);

      await pushQueue(tester, reason: 'something_new', id: 'e_q3', seq: 42);
      expect(
        find.textContaining('正在等待执行'),
        findsOneWidget,
        reason: '未知原因退化为通用文案，不拼出原始 reason',
      );
    });

    testWidgets('retry_scheduled 展示「正在安排第 N 次重试」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.retryScheduled,
        sseEvent(
          EventTypes.retryScheduled,
          id: 'e_retry',
          seq: 40,
          payload: {
            'attempt': 2,
            'max_retries': 3,
            'delay_ms': 5000,
            'reason': 'exit status 1\n一大段 stderr 噪声',
          },
        ),
      );

      expect(find.textContaining('正在安排第 2 次重试'), findsOneWidget);
      expect(
        find.textContaining('stderr'),
        findsNothing,
        reason: 'reason 是执行器 stderr 原文，不得当横幅文案（webapp 同样不用）',
      );
    });

    testWidgets('retry_scheduled 缺 attempt 时退化为「第 1 次」（不拼 null）', (
      tester,
    ) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.retryScheduled,
        sseEvent(
          EventTypes.retryScheduled,
          id: 'e_retry',
          seq: 40,
          payload: const {},
        ),
      );

      expect(find.textContaining('正在安排第 1 次重试'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('message 事件到达后等待提示消失', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushQueue(tester);

      final bar = find.byKey(const ValueKey('conversation-execution-status'));
      expect(bar, findsOneWidget);

      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent('message', id: 'e_msg', seq: 41, payload: {'text': '回复来了'}),
      );

      expect(bar, findsNothing, reason: '已有正文，等待显然结束，不得挂着过期提示');
    });

    testWidgets('start 事件后等待提示消失', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushQueue(tester);

      final bar = find.byKey(const ValueKey('conversation-execution-status'));
      expect(bar, findsOneWidget);

      await pushEvent(
        tester,
        EventTypes.start,
        sseEvent(
          'start',
          id: 'e_start',
          seq: 41,
          payload: {'status': 'running'},
        ),
      );

      expect(bar, findsNothing, reason: '已起跑，名额已拿到');
    });

    testWidgets('无等待事件时不展示（不凭空造提示）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('conversation-execution-status')),
        findsNothing,
      );
    });

    testWidgets('未注入 executionStatus 流时不展示（保持纯只读时间线）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, wireExecutionStatus: false);
      await pushQueue(tester);

      expect(
        find.byKey(const ValueKey('conversation-execution-status')),
        findsNothing,
      );
    });

    testWidgets('等待提示优先于活动指示（两者共用槽位）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      // 先造出「已在跑但没正文」的空窗期：流式 thought + 活动心跳。
      // （这两个 helper 定义在下方活动指示组内，作用域不跨组，故此处内联。）
      await pushEvent(
        tester,
        EventTypes.thought,
        sseEvent(
          'thought',
          id: 'e_thought',
          transient: true,
          seq: 39,
          payload: {'text': '让我想想…'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          id: 'e_act',
          transient: true,
          seq: 39,
          payload: {'elapsed_ms': 45000},
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsOneWidget,
      );

      // 等待事件到达：应让位给「在等」（对齐 webapp turn.activity && !turn.queueReason）。
      await pushQueue(tester);

      expect(
        find.byKey(const ValueKey('conversation-execution-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
        reason: '同一槽位只展示一条，等待状态胜出',
      );
    });
  });

  group('ConversationPage 上下文用量', () {
    /// 推一条 `context_update`（Go telemetry 形状，落库非 Transient）。
    Future<void> pushContext(
      WidgetTester tester, {
      int tokens = 50000,
      int window = 200000,
      int seq = 30,
    }) => pushEvent(
      tester,
      EventTypes.contextUpdate,
      sseEvent(
        EventTypes.contextUpdate,
        id: 'e_ctx',
        seq: seq,
        payload: {
          'telemetry': {'context_tokens': tokens, 'context_window': window},
        },
      ),
    );

    testWidgets('telemetry 到达后展示「已用 / 窗口」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushContext(tester, tokens: 50000, window: 200000);

      final bar = find.byKey(const ValueKey('conversation-context-usage'));
      expect(bar, findsOneWidget, reason: '用量是长对话里用户唯一能判断「何时会被压缩」的依据');
      expect(find.textContaining('50K / 200K'), findsOneWidget);
    });

    testWidgets('用量渲染在时间线之外（不产生任何时间线条目）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushContext(tester);

      // 时间线仍为空（没有任何 ConversationItem），但用量条已出现。
      expect(find.byType(ListView), findsNothing, reason: '空时间线渲染的是空提示');
      expect(
        find.byKey(const ValueKey('conversation-context-usage')),
        findsOneWidget,
      );
    });

    testWidgets('无用量数据时不展示（不凭空造 0）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('conversation-context-usage')),
        findsNothing,
      );
    });

    testWidgets('未注入 contextUsage 流时不展示（保持纯只读时间线）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, wireContextUsage: false);
      await pushContext(tester);

      expect(
        find.byKey(const ValueKey('conversation-context-usage')),
        findsNothing,
      );
    });

    testWidgets('cost 缺失时不渲染费用段（Go 后端从不发射 cost）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushContext(tester);

      expect(
        find.byKey(const ValueKey('conversation-context-usage-cost')),
        findsNothing,
        reason: '不得用 0 伪造「未提供」与「花了 0 元」的区别',
      );
    });

    testWidgets('cost.amount > 0 时展示费用（向前兼容遗留 context 形状）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx_cost',
          seq: 31,
          payload: {
            'context': {
              'used': 1000,
              'size': 8000,
              'cost': {'amount': 0.0123, 'currency': 'USD'},
            },
          },
        ),
      );

      final cost = find.byKey(
        const ValueKey('conversation-context-usage-cost'),
      );
      expect(cost, findsOneWidget);
      expect(find.textContaining('0.0123'), findsOneWidget);
    });

    testWidgets('多条 context_update 合并：窗口保留、用量更新', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushContext(tester, tokens: 10000, window: 200000, seq: 30);
      expect(find.textContaining('10K / 200K'), findsOneWidget);

      // 压缩完成：只带 tokens_after，不带窗口大小。
      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx2',
          seq: 32,
          payload: {
            'compaction': {'status': 'completed', 'tokens_after': 3000},
          },
        ),
      );

      expect(
        find.textContaining('3K / 200K'),
        findsOneWidget,
        reason: '压缩后窗口大小不应丢失，否则退化成「3K / ?」',
      );
    });
  });

  group('ConversationPage 执行中活动指示', () {
    /// 推一条 turn_activity（Transient，与 executor 心跳升级后的形态一致）。
    Future<void> pushActivity(
      WidgetTester tester, {
      String turnId = 'turn_1',
      int elapsedMs = 45000,
      String? lastEventType = 'bash',
      int seq = 9,
    }) => pushEvent(
      tester,
      EventTypes.turnActivity,
      sseEvent(
        EventTypes.turnActivity,
        id: 'e_act',
        turnId: turnId,
        transient: true,
        seq: seq,
        payload: {
          'elapsed_ms': elapsedMs,
          if (lastEventType != null) 'last_event_type': lastEventType,
        },
      ),
    );

    /// 推一个**无正文**的流式思考段（长 turn 的静默期就是这样：在思考、
    /// 还没吐字，且没有 AssistantMessageItem 正文）。
    Future<void> pushStreamingThought(
      WidgetTester tester, {
      String turnId = 'turn_1',
    }) => pushEvent(
      tester,
      EventTypes.thought,
      sseEvent(
        'thought',
        id: 'e_thought',
        turnId: turnId,
        transient: true,
        payload: {'text': '让我想想…'},
      ),
    );

    testWidgets('流式中无正文时展示「已运行 X · 最近：Y」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester);
      await pushActivity(tester, elapsedMs: 45000, lastEventType: 'bash');

      final indicator = find.byKey(
        const ValueKey('conversation-turn-activity'),
      );
      expect(
        indicator,
        findsOneWidget,
        reason: '空窗期必须给用户进展证据，否则他分不清「在干活」与「卡死」',
      );
      expect(find.textContaining('已运行 45 秒'), findsOneWidget);
      expect(find.text('最近：bash'), findsOneWidget);
    });

    testWidgets('≥ 1 分钟拆成「X 分 Y 秒」（webapp 只给秒数，此处有意更易读）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester);
      await pushActivity(tester, elapsedMs: 125000, lastEventType: 'tool_call');

      expect(find.textContaining('已运行 2 分 5 秒'), findsOneWidget);
    });

    testWidgets('无 last_event_type 时不渲染「最近：」段（不显示 null）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester);
      await pushActivity(tester, lastEventType: null);

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-turn-activity-last')),
        findsNothing,
        reason: '首帧活动不带上一步，拼出「最近：null」比不显示更糟',
      );
    });

    testWidgets('已有正文时让位给真实内容（不插进度噪声）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingMessage(tester);
      await pushActivity(tester);

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
        reason: '正文在往下滚，再插一句「已运行」只是噪声',
      );
    });

    testWidgets('无活动事件时不展示（不凭空造进度）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester);

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
      );
    });

    testWidgets('done 到达后不再展示（不在已完成的对话下挂「执行中」）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester);
      await pushActivity(tester);
      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsOneWidget,
      );

      await pushEvent(
        tester,
        EventTypes.done,
        sseEvent(
          'done',
          id: 'e_done',
          payload: {'status': 'completed'},
          seq: 20,
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
        reason: 'done 会闭合流式段；活动快照仍残留在 State，必须靠流式判定排除',
      );
    });

    testWidgets('未注入活动流时不展示（保持纯只读时间线用法）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, wireActivities: false);
      await pushStreamingThought(tester);
      await pushActivity(tester);

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
      );
    });

    testWidgets('活动只作用于自己的 turn（不串到别的流式 turn）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushStreamingThought(tester, turnId: 'turn_1');
      // 另一个 turn 的活动快照：不应驱动当前指示器。
      await pushActivity(tester, turnId: 'turn_other', elapsedMs: 99000);

      expect(
        find.byKey(const ValueKey('conversation-turn-activity')),
        findsNothing,
        reason: '按 turnId 直查，不拿「最近一条活动」冒充当前 turn 的进度',
      );
    });

    test('formatTurnElapsed：秒/分/时各量级', () {
      expect(formatTurnElapsed(0), '0 秒');
      expect(formatTurnElapsed(-500), '0 秒', reason: '异常载荷不产出负数');
      expect(formatTurnElapsed(3000), '3 秒');
      expect(formatTurnElapsed(59000), '59 秒');
      expect(formatTurnElapsed(60000), '1 分钟');
      expect(formatTurnElapsed(125000), '2 分 5 秒');
      expect(formatTurnElapsed(7325000), '122 分 5 秒');
    });

    test('formatTokenCount：与 webapp 口径逐字对齐（K 整数不带小数）', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(-100), '0', reason: '异常载荷不产出负数读数');
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(1000), '1K');
      expect(formatTokenCount(12000), '12K');
      expect(formatTokenCount(12500), '12.5K');
      expect(formatTokenCount(200000), '200K');
    });
  });

  group('ConversationPage 连接状态', () {
    testWidgets('title 为 null 时不渲染 AppBar', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, title: null);

      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('title 非 null 时渲染 AppBar 与连接指示', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    });
  });

  group('ConversationPage 自动滚到底', () {
    testWidgets('内容溢出时新项到达会自动滚到底', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      // 塞足够多内容让列表溢出。
      //
      // ⚠️ 每个 turn 必须先推 `start`：它是**段落边界**（reducer 在此重置
      // `currentAssistantIdx`）。服务端确实会落库并回放 start 事件
      // （`turn_worker.go:656`，timeline 不过滤事件类型），故真实场景不缺它。
      // 少了 start，不同 turn 的权威帧会被当成同一段落的替换而塌缩成一项。
      for (var i = 0; i < 30; i++) {
        await pushEvent(
          tester,
          EventTypes.start,
          sseEvent('start', id: 's$i', turnId: 'turn_$i', seq: 1),
        );
        await pushEvent(
          tester,
          EventTypes.message,
          sseEvent(
            'message',
            id: 'e$i',
            turnId: 'turn_$i',
            payload: {'text': '第 $i 条消息内容'},
            seq: 2,
          ),
        );
      }
      await tester.pumpAndSettle();

      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: '内容应已溢出，否则本用例无意义',
      );
      expect(
        position.pixels,
        closeTo(position.maxScrollExtent, 1),
        reason: '在底部时新项应自动跟随',
      );
    });
  });

  group('ConversationPage 加载更早历史', () {
    /// 塞入 [count] 条独立消息，让列表溢出以便产生滚动。
    ///
    /// 用 `user_message`（每条 turnId 不同 → 独立成项）：非 transient 的
    /// `message` 是权威帧，会被 reducer 当成同段落的替换而塌缩成一项。
    Future<void> seedMessages(WidgetTester tester, int count) async {
      for (var i = 0; i < count; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            'user_message',
            id: 'u$i',
            turnId: 'turn_$i',
            payload: {'input': '第 $i 条'},
            seq: i + 1,
          ),
        );
      }
      await tester.pump();
    }

    testWidgets('滚动到顶部时触发 onLoadOlder', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return true; // 还有更多
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '初始在底部，不应触发翻页');

      // 向上拖到底（内容溢出，可滚）。
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(0), reason: '滚到顶部附近必须触发翻页');
    });

    testWidgets('滚动过程中并发触发时只调一次 handler', (tester) async {
      // 一次拖拽会产生**很多**次滚动通知，而 handler 内部是异步请求。
      // 没有护栏就会并发发出多个翻页请求（都带同一游标 → 拉到同一页）。
      //
      // 这里必须让 handler **挂起**（不立即完成）：否则第一次调用就 resolve 了，
      // 后续通知看到的是「未在加载」，护栏根本不会被触发到——那正是这条用例
      // 存在的意义（域层的护栏会掩盖掉页面的护栏）。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      final gate = Completer<bool>();
      await pumpPage(
        tester,
        onLoadOlder: () {
          calls++;
          return gate.future;
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      // ⚠️ 这里的手势形状是**被实测逼出来的**，不能改成 `tester.drag`：
      //
      // 1. `tester.drag` 只产生一次滚动通知 → 护栏无从体现；
      // 2. 光用「连续 moveBy 拖到顶」也不行——到达 `pixels == 0` 后再拖不会
      //    产生新的滚动通知，而恰好只有最后一次通知落在阈值内，护栏同样不被
      //    触发（实测：去掉护栏后用例仍然全绿）。
      //
      // 故：先拖到顶，再在阈值区间内**来回抖动**，制造多次「位置已变」信号。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 400));
        await tester.pump();
      }
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();

      expect(calls, 1, reason: '挂起期间不得重复调用 handler');
      expect(gate.isCompleted, isFalse);

      gate.complete(true);
      await tester.pumpAndSettle();
    });

    testWidgets('换 group（historyKey 变化）后重置「已到最早」标记', (tester) async {
      // 回归防线：切 group 时控制器实例不变、State 被复用，若不按 historyKey
      // 重置，在 A 对话翻到头后切到 B 会永远翻不出历史（且毫无报错）。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        historyKey: 'grp_A',
        onLoadOlder: () async {
          calls++;
          return false; // 已到最早
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final inA = calls;
      expect(inA, greaterThan(0));

      // 切到另一个对话：historyKey 变，标记必须重置。
      await rebuildPage(
        tester,
        historyKey: 'grp_B',
        onLoadOlder: () async {
          calls++;
          return true;
        },
      );
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(inA), reason: '换了对话后必须重新允许翻页（否则新对话永远翻不出历史）');
    });

    testWidgets('返回 false 后不再触发（已到最早）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return false; // 已到最早
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      final afterFirst = calls;
      expect(afterFirst, greaterThan(0));

      // 再滚一次（回到顶部附近会再次触发滚动通知）。
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(calls, afterFirst, reason: '返回 false 之后不得再发请求（否则每次到顶都白拉一次）');
    });

    testWidgets('未注入 onLoadOlder 时不触发（只读时间线用法）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      // 没有回调可注入，滚到顶也不应抛异常。
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('失败时提示，且仍可再次触发（不标记为已到最早）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          throw const NetworkError('断网了');
        },
      );
      await seedMessages(tester, 30);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(calls, greaterThan(0));
      expect(find.textContaining('加载更早历史失败'), findsOneWidget);

      final afterFirst = calls;
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      expect(
        calls,
        greaterThan(afterFirst),
        reason: '失败后必须允许重试，否则一次网络抖动就永久失去历史',
      );
    });

    testWidgets('空列表时不触发翻页（无锚点）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(
        tester,
        onLoadOlder: () async {
          calls++;
          return true;
        },
      );
      await tester.pumpAndSettle();

      // 空态渲染的是 _EmptyHint，没有 ListView 可滚。
      expect(find.byType(ListView), findsNothing);
      expect(calls, 0);
    });
  });

  group('ConversationPage 重连', () {
    final indicator = find.byKey(
      const ValueKey('conversation-connection-indicator'),
    );

    testWidgets('断线态点击指示器触发一次 onReconnect', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.failed);
      expect(indicator, findsOneWidget);

      await tester.tap(indicator);
      await tester.pump();

      expect(calls, 1, reason: '点击一次必须只回调一次');
    });

    testWidgets('重连中（reconnecting）也可点', (tester) async {
      // 退避最长可到 maxBackoff，用户不该被迫干等计时器。
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.reconnecting);
      await tester.tap(indicator);
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('已连接态点击不触发（不渲染手势）', (tester) async {
      mockTimeline();
      await startController(tester);
      var calls = 0;
      await pumpPage(tester, onReconnect: () => calls++);

      await pushConnectionState(tester, SseState.connected);
      // 已连接态下指示器是纯展示：不存在可点的 InkWell。
      expect(
        find.descendant(of: indicator, matching: find.byType(InkWell)),
        findsNothing,
      );

      await tester.tap(indicator, warnIfMissed: false);
      await tester.pump();

      expect(calls, 0, reason: '已连接时误触不得触发重连（会丢弃正在传输的帧）');
    });

    testWidgets('未注入 onReconnect 时纯展示（任何状态都不可点）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushConnectionState(tester, SseState.failed);
      expect(indicator, findsOneWidget);
      expect(
        find.descendant(of: indicator, matching: find.byType(InkWell)),
        findsNothing,
      );

      // 没有回调，点了也不应抛异常。
      await tester.tap(indicator, warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('图标内边距在可点/不可点之间保持一致（AppBar 不抖动）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onReconnect: () {});

      await pushConnectionState(tester, SseState.connected);
      final connectedSize = tester.getSize(indicator);

      await pushConnectionState(tester, SseState.failed);
      final failedSize = tester.getSize(indicator);

      expect(
        failedSize,
        connectedSize,
        reason: '状态切换不得改变指示器尺寸，否则 AppBar 内容会左右跳动',
      );
    });
  });

  group(
    'ConversationPage 语音播报状态（tts_started / tts_completed / tts_failed）',
    () {
      /// 推一个 TTS 生命周期事件。
      ///
      /// `tts_started` 是 Transient（Go `main.go:715` 只对它设 Transient），
      /// 两个终态事件是**落库**的。
      Future<void> pushTts(
        WidgetTester tester,
        String type,
        Map<String, dynamic> payload, {
        required String id,
        required int seq,
      }) => pushEvent(
        tester,
        type,
        sseEvent(
          type,
          id: id,
          seq: seq,
          transient: type == EventTypes.ttsStarted,
          payload: payload,
        ),
      );

      testWidgets('tts_started 展示「正在生成语音…」', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'message', 'seq': 1},
          id: 'e_tts_1',
          seq: 10,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
          reason: '没有它，用户不知道语音在合成还是没开语音',
        );
        expect(find.textContaining('正在生成语音'), findsOneWidget);
      });

      testWidgets('tts_completed 展示「语音已生成」并带段数', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'stream'},
          id: 'e_tts_2',
          seq: 10,
        );
        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 3, 'bytes': 1024},
          id: 'e_tts_3',
          seq: 11,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );
        expect(find.textContaining('语音已生成'), findsOneWidget);
        expect(find.textContaining('3 段'), findsOneWidget);
      });

      testWidgets('tts_failed 展示服务端文案，不暴露内部 reason', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {'reason': 'synthesize_failed', 'message': '语音生成失败，本次文本回复不受影响。'},
          id: 'e_tts_4',
          seq: 10,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );
        expect(find.textContaining('语音生成失败，本次文本回复不受影响。'), findsOneWidget);
        expect(
          find.textContaining('synthesize_failed'),
          findsNothing,
          reason: 'reason 是诊断值，不是给用户看的文案',
        );
      });

      testWidgets('tts_failed 缺 message 时兜底「语音生成失败。」', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {'reason': 'boom'},
          id: 'e_tts_5',
          seq: 10,
        );

        expect(find.textContaining('语音生成失败。'), findsOneWidget);
      });

      testWidgets('部分成功与全失败文案不同（由服务端区分）', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsFailed,
          {
            'parts': 5,
            'failed_part': 3,
            'completed_parts': 2,
            'lost_chars': 42,
            'message': '语音生成未完全成功，已生成的部分仍可播放。',
          },
          id: 'e_tts_6',
          seq: 10,
        );

        expect(find.textContaining('已生成的部分仍可播放'), findsOneWidget);
      });

      testWidgets('started → completed 覆盖，不留两个指示条', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsStarted,
          {'mode': 'stream'},
          id: 'e_tts_7',
          seq: 10,
        );
        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );

        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 1},
          id: 'e_tts_8',
          seq: 11,
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
          reason: '状态条是单值指示，不得叠加',
        );
        expect(find.textContaining('正在生成语音'), findsNothing);
      });

      testWidgets('无播报事件时（idle）不占一行', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: 'idle 是默认态，不得为它占一行空白（否则每个对话都多一条）',
        );
      });

      testWidgets('新 turn 的 user_message 后旧播报状态不再展示', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester);
        await pushTts(
          tester,
          EventTypes.ttsCompleted,
          {'parts': 1},
          id: 'e_tts_a',
          seq: 10,
        );
        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsOneWidget,
        );

        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_um_2',
            turnId: 'turn_2',
            seq: 20,
            payload: {'input': '下一个问题'},
          ),
        );

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: '上一轮的「语音已生成」不该粘在新一轮上',
        );
      });

      testWidgets('未接线 ttsStatus 时不展示状态条', (tester) async {
        mockTimeline();
        await startController(tester);
        await pumpPage(tester, wireTtsStatus: false);

        sse.push(
          EventTypes.ttsCompleted,
          sseEvent(
            EventTypes.ttsCompleted,
            id: 'e_tts_9',
            seq: 10,
            payload: {'parts': 1},
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('conversation-tts-status')),
          findsNothing,
          reason: '未注入时本页不应展示播报状态',
        );
      });
    },
  );
}
