import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// [TurnDetailPanel] / [TurnDetailSheet] 的渲染与交互测试。
///
/// ## 这个测试防的是什么
///
/// 详情面板的输入是**已落库的事件**（不像对话页那样有实时增量），故归约层
/// 不参与。这带来两个易错点：
///
/// 1. **顺序**：详情页要的是「这一轮内部的先后」，而事件到达顺序可能是
///    `global_seq` 序（timeline 分页）——与 per-turn `seq` 序未必一致。乱序渲染
///    会让用户看到「回复在思考之前」。
/// 2. **空事件是正常结果**（不是错误）：上游 `GET /chat/turns/:id` 不返回
///    events，事件来自 timeline 的本地过滤，可能被分页窗口甩出去。留白会让
///    用户以为页面坏了。
ChatTurn _turn({
  String id = 'turn_1',
  String groupId = 'grp_1',
  String inputText = '帮我看一下这个报错',
  String status = 'completed',
  int errorCount = 0,
  String? channel,
}) => ChatTurn(
  id: id,
  groupId: groupId,
  userId: 'usr_1',
  inputText: inputText,
  status: status,
  fanoutCount: 1,
  completedCount: 2,
  errorCount: errorCount,
  channel: channel,
  createdAt: DateTime(2024, 3, 5, 12, 0),
);

ChatEvent _event({
  String eventId = 'ev_1',
  String turnId = 'turn_1',
  required String eventType,
  int seq = 1,
  int? globalSeq,
  String source = 'agent',
  Map<String, dynamic>? payload,
  DateTime? createdAt,
}) => ChatEvent(
  eventId: eventId,
  userId: 'usr_1',
  groupId: 'grp_1',
  turnId: turnId,
  eventType: eventType,
  seq: seq,
  globalSeq: globalSeq,
  source: source,
  createdAt: createdAt ?? DateTime(2024, 3, 5, 12, 0, seq),
  payload: payload,
);

void main() {
  Widget host(TurnDetail detail) => MaterialApp(
    home: Scaffold(body: TurnDetailPanel(detail: detail)),
  );

  group('渲染事件时间线', () {
    testWidgets('用户输入置顶（不依赖事件里有没有 user_message）', (t) async {
      // 历史 turn 可能没有 user_message 事件，而 input_text 一定在 turn 行上。
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(inputText: '把 CI 修绿'),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('turn-detail-input')), findsOneWidget);
      expect(find.text('把 CI 修绿'), findsOneWidget);
    });

    testWidgets('输入为空时给占位而不是留白', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(inputText: ''),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('（空）'), findsOneWidget);
    });

    testWidgets('message 事件渲染为 agent 回复正文', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventType: EventTypes.message,
                payload: {'text': '这是 agent 的回复'},
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('这是 agent 的回复'), findsOneWidget);
    });

    testWidgets('error 事件醒目渲染（含错误文案）', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(status: 'failed'),
            events: [
              _event(eventType: EventTypes.error, payload: {'error': '执行器崩溃'}),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('错误'), findsOneWidget);
      expect(find.text('执行器崩溃'), findsOneWidget);
    });

    testWidgets('工具调用与结果都渲染', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventId: 'ev_call',
                eventType: EventTypes.toolCall,
                seq: 2,
                payload: {'tool_name': 'bash'},
              ),
              _event(
                eventId: 'ev_result',
                eventType: EventTypes.toolResult,
                seq: 3,
                payload: {'tool_name': 'bash', 'output': 'ok'},
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      // 两张卡：tool_call 一张、tool_result 一张（详情页不归约配对）。
      expect(find.text('bash'), findsNWidgets(2));
      // 结果默认折叠，展开结果那张（树序在后）才可见。
      await t.tap(find.text('bash').last);
      await t.pumpAndSettle();
      expect(find.text('ok'), findsOneWidget);
    });

    testWidgets('tool_call 无配对结果时给占位（不是无限转圈）', (t) async {
      // ## 这个测试防的是什么
      //
      // `ToolCallTile` 的 `isRunning` 判据是 `output == null`，而 `ToolCallTile`
      // 在 running 态渲染 `CircularProgressIndicator`（无限动画）。详情页是历史
      // 快照——转圈会让用户以为一个去年的工具调用还在跑，且会让任何
      // `pumpAndSettle` 永久超时（本用例若去掉占位就会挂住，是同一问题的信号）。
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventType: EventTypes.toolCall,
                payload: {'tool_name': 'bash'},
              ),
            ],
          ),
        ),
      );
      // 关键：pumpAndSettle 能返回（无无限动画）。
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('完成'), findsOneWidget);
      await t.tap(find.text('bash'));
      await t.pumpAndSettle();
      expect(find.textContaining('结果未在本次加载的事件中'), findsOneWidget);
    });

    testWidgets('thought 事件渲染为思考块', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(eventType: EventTypes.thought, payload: {'text': '先看看日志'}),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('先看看日志'), findsOneWidget);
    });

    testWidgets('未知类型落到通用卡（不静默丢弃）', (t) async {
      // 详情页的职责是把服务端发的都摊开；静默丢弃会让「事件流（N）」的计数
      // 与可见项数对不上，用户以为渲染漏了。
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(eventType: 'some_future_event', payload: {'text': '新事件'}),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('some_future_event'), findsOneWidget);
      expect(find.text('新事件'), findsOneWidget);
    });

    testWidgets('计数与渲染项数一致（"事件流（N）" 不是谎报）', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventId: 'ev_1',
                eventType: EventTypes.message,
                seq: 1,
                payload: {'text': 'a'},
              ),
              _event(
                eventId: 'ev_2',
                eventType: EventTypes.message,
                seq: 2,
                payload: {'text': 'b'},
              ),
              _event(eventId: 'ev_3', eventType: EventTypes.done, seq: 3),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('事件流（3）'), findsOneWidget);
    });
  });

  group('按 per-turn seq 排序（乱序输入也要正确）', () {
    testWidgets('seq 乱序的输入按 seq 升序渲染', (t) async {
      // timeline 分页给的是 global_seq 序，与 per-turn seq 序未必一致。
      // 这里刻意倒着传（seq 3 → 1），断言渲染顺序回到 1 → 3。
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventId: 'ev_3',
                eventType: EventTypes.message,
                seq: 3,
                payload: {'text': '第三'},
              ),
              _event(
                eventId: 'ev_1',
                eventType: EventTypes.thought,
                seq: 1,
                payload: {'text': '第一'},
              ),
              _event(
                eventId: 'ev_2',
                eventType: EventTypes.toolCall,
                seq: 2,
                payload: {'tool_name': '第二工具'},
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      final firstY = t.getTopLeft(find.text('第一')).dy;
      final secondY = t.getTopLeft(find.text('第二工具')).dy;
      final thirdY = t.getTopLeft(find.text('第三')).dy;
      expect(firstY, lessThan(secondY));
      expect(secondY, lessThan(thirdY));
    });

    testWidgets('seq 相同时退到 globalSeq 排序（毫秒精度无法定序）', (t) async {
      // createdAt 只有毫秒精度，同毫秒内无法定序——这正是 globalSeq 存在的理由。
      final same = DateTime(2024, 3, 5, 12, 0, 0);
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(),
            events: [
              _event(
                eventId: 'ev_b',
                eventType: EventTypes.message,
                seq: 1,
                globalSeq: 20,
                createdAt: same,
                payload: {'text': '后'},
              ),
              _event(
                eventId: 'ev_a',
                eventType: EventTypes.message,
                seq: 1,
                globalSeq: 10,
                createdAt: same,
                payload: {'text': '前'},
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(
        t.getTopLeft(find.text('前')).dy,
        lessThan(t.getTopLeft(find.text('后')).dy),
      );
    });
  });

  group('空事件（正常结果，不是错误）', () {
    testWidgets('events 为空 → 渲染空提示而非白屏', (t) async {
      await t.pumpWidget(host(TurnDetail(turn: _turn(), events: const [])));
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('turn-detail-events-empty')),
        findsOneWidget,
      );
      expect(find.text('这一轮没有可展示的事件'), findsOneWidget);
      // 面板本身仍在（不是白屏）：meta 与用户输入都渲染了。
      expect(find.byKey(const ValueKey('turn-detail-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('turn-detail-input')), findsOneWidget);
    });

    testWidgets('空提示解释原因（用户要知道是「超出窗口」还是「坏了」）', (t) async {
      await t.pumpWidget(host(TurnDetail(turn: _turn(), events: const [])));
      await t.pumpAndSettle();

      expect(find.textContaining('超出时间线窗口'), findsOneWidget);
    });

    testWidgets('计数显示 0（与空提示一致）', (t) async {
      await t.pumpWidget(host(TurnDetail(turn: _turn(), events: const [])));
      await t.pumpAndSettle();

      expect(find.text('事件流（0）'), findsOneWidget);
    });
  });

  group('顶部 meta', () {
    testWidgets('失败态徽标', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(status: 'failed'),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('失败'), findsOneWidget);
    });

    testWidgets('英式 cancelled 显示「已取消」（不是「已完成」）', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(status: 'cancelled'),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
    });

    testWidgets('error_count > 0 但 status 未标 failed 时仍提示错误数', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(status: 'completed', errorCount: 2),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('2 个错误'), findsOneWidget);
    });

    testWidgets('channel 非空时展示来源渠道', (t) async {
      await t.pumpWidget(
        host(
          TurnDetail(
            turn: _turn(channel: 'wechat_ilink'),
            events: const [],
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('wechat_ilink'), findsOneWidget);
    });
  });

  group('TurnDetailSheet 加载壳', () {
    testWidgets('加载中显示转圈', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TurnDetailSheet(
              groupId: 'grp_1',
              turnId: 'turn_1',
              // 永不完成：停在加载态。
              //
              // 用 Completer 而不是 `Future.delayed`：后者会留一个 pending
              // timer，测试结束时框架断言 `!timersPending` 失败（与「加载中」
              // 这个断言无关的噪音）。
              load: (g, tid) => Completer<TurnDetail>().future,
            ),
          ),
        ),
      );
      await t.pump();

      expect(find.byKey(const ValueKey('turn-detail-loading')), findsOneWidget);
    });

    testWidgets('加载成功渲染面板', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TurnDetailSheet(
              groupId: 'grp_1',
              turnId: 'turn_1',
              load: (g, tid) async => TurnDetail(
                turn: _turn(inputText: '加载好了'),
                events: const [],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('turn-detail-panel')), findsOneWidget);
      expect(find.text('加载好了'), findsOneWidget);
    });

    testWidgets('加载失败展示错误与重试，重试成功后渲染面板', (t) async {
      // 一次网络抖动不该逼用户关掉弹层重进。
      var calls = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TurnDetailSheet(
              groupId: 'grp_1',
              turnId: 'turn_1',
              load: (g, tid) async {
                calls++;
                if (calls == 1) throw StateError('连接超时');
                return TurnDetail(turn: _turn(), events: const []);
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('turn-detail-error')), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('turn-detail-retry')));
      await t.pumpAndSettle();

      expect(calls, 2);
      expect(find.byKey(const ValueKey('turn-detail-panel')), findsOneWidget);
    });
  });
}
