import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 发送 / 取消 / 执行等待提示 / 上下文用量 / 执行中活动
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

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
      // ⚠️ 归约被合并到一个零延迟 Timer（issue #44），而它在**真实时区**里
      // （`controller.send` 由 `runAsync` 启动的链路触发）——`pumpAndSettle`
      // 跑不到真实计时器。故在 `runAsync` 内等一个真实轮次让它落地，再 pump。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();

      // 乐观回显：用户气泡立刻出现（不等 SSE）。
      expect(find.text('走控制器'), findsOneWidget);

      // 乐观回显产生了一个「已提交、agent 尚未产出」的 turn，自 issue #9 起
      // 这会被判为 `preparing` 并**武装看门狗计时器**（这正是「服务端可能已经
      // 崩了、永远不会发 done」需要兜底的场景）。
      //
      // ⚠️ 这条路径的计时器是 `tester.tap` 在 **FakeAsync 时区**里创建的（与
      // `pushEvent` 不同——后者包在 `runAsync` 里，创建的是真实 Timer，不被
      // 测试绑定追踪），故会被 `flutter_test` 的 `!timersPending` 不变式检出
      // （它在 `tearDown` 之前执行）。在 `runAsync` 里释放控制器即可取消它。
      await tester.runAsync(() => controller.dispose());
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
}
