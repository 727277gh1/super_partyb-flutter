import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 轮次导航刻度条在**页面层**的行为回归（§6.94）。
///
/// ## 这个文件防的是什么
///
/// `turn_rail_test.dart` 证明组件自身画得对、回调传得对；它钉不住页面这一侧
/// 的三件事，而这三件恰好都是「静默」的：
///
/// 1. **它到底出不出现**——宽度不足时不出现（否则 390dp 的手机上它会压住正文），
///    宽度够时出现。页面若把判断写反，组件测试全绿；
/// 2. **点它真的会跳**——组件只负责回调，页面得把它接到锚点状态机
///    （[_anchoredTurnId] + `_following` + `_scrollToTurn`）。接不上就是
///    「点了没反应」；
/// 3. **跳过去之后高亮跟着走**——刻度条的激活格来自「视口顶部那一轮」，
///    而这是页面的几何计算，纯组件测试根本触碰不到。
///
/// ⚠️ 本机是无头 LXC：这些用例证明状态机与几何判据，**不**证明真机上 hover
/// 与跳转的观感（见 `docs/development.md` 的验证边界）。
void main() {
  setUpHarness();
  tearDownHarness();
  setUp(() {
    PerfProbe.reset();
    SpbLog.clearRecentLogs();
  });

  const turnA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  /// 推一轮完整对话（`start` → `user_message` → `message` → `done`）。
  ///
  /// 顺序不能省：少了 `start`，归约器会把下一轮的 `message` 当成同一段的权威帧
  /// 原地替换，历史就堆不起来（详见 `conversation_page_anchor_test.dart` 的说明）。
  Future<List<String>> pushTurn(
    WidgetTester tester, {
    required String turnId,
    required String input,
    required int seq,
    int lines = 12,
  }) async {
    final short = turnId.substring(0, 8);
    final userId = '$short-user-$seq';
    final assistantId = '$short-reply-$seq';
    for (final (type, id, payload) in [
      (EventTypes.start, '$short-start-$seq', <String, dynamic>{}),
      (EventTypes.userMessage, userId, <String, dynamic>{'input': input}),
      (
        EventTypes.message,
        assistantId,
        <String, dynamic>{
          'text': List.generate(
            lines,
            (i) => '$input 的第 $i 段回复正文。',
          ).join('\n\n'),
        },
      ),
      (EventTypes.done, '$short-done-$seq', <String, dynamic>{}),
    ]) {
      await pushEvent(
        tester,
        type,
        sseEvent(type, id: id, turnId: turnId, payload: payload, seq: seq++),
      );
    }
    return [userId, assistantId];
  }

  String hex(int i) => i.toRadixString(16).padLeft(32, '0');

  ScrollPosition timelinePosition(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView).first)
      .controller!
      .position;

  testWidgets('宽屏且有两轮以上：刻度条出现；一轮都没有时不出现', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 空对话：没有刻度条（也没有一条空刻度列占着右边）。
    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);

    await pushTurn(tester, turnId: turnA, input: '第一轮', seq: 1);
    await tester.pumpAndSettle();
    // 只有一轮时仍不出现：一格刻度条没有导航价值，只是噪音。
    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);

    await pushTurn(tester, turnId: hex(2), input: '第二轮', seq: 10);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsOneWidget);
  });

  testWidgets('窄屏（手机宽度）不出现刻度条', (tester) async {
    tester.view.physicalSize = const Size(430, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pushTurn(tester, turnId: turnA, input: '第一轮', seq: 1);
    await pushTurn(tester, turnId: hex(2), input: '第二轮', seq: 10);
    await pumpPage(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);
  });

  testWidgets('点刻度跳到历史轮次：真的落位、关掉跟随、给出「回到最新」', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);

    // 堆出远超一屏的历史，让第一轮落在视口外。
    final ids = <List<String>>[];
    for (var i = 0; i < 10; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : hex(i),
          input: '第 $i 轮',
          seq: i * 10 + 1,
        ),
      );
    }
    await pumpPage(tester);
    await tester.pumpAndSettle();

    // 起始态是「跟随最新」：视口在底部。
    expect(timelinePosition(tester).extentAfter, lessThan(2));

    await tester.tap(find.byKey(const ValueKey('turn-rail-tick-$turnA')));
    await tester.pumpAndSettle();

    // 真的跳上去了（不是「点了没反应」）：贴顶落到该轮、下方仍有大量内容。
    expect(tester.getTopLeft(find.text('第 0 轮')).dy, lessThan(120));
    expect(timelinePosition(tester).extentAfter, greaterThan(500));
    // 该轮被高亮，且出现「回到最新」出口（复用锚点态，不是另造一套状态）。
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );
  });

  testWidgets('点最后一格 = 跟随最新（不进锚点态）', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);

    for (var i = 0; i < 10; i++) {
      await pushTurn(
        tester,
        turnId: i == 0 ? turnA : hex(i),
        input: '第 $i 轮',
        seq: i * 10 + 1,
      );
    }
    await pumpPage(tester);
    await tester.pumpAndSettle();

    // 先跳到首轮（进入锚点态），再点最后一格。
    await tester.tap(find.byKey(const ValueKey('turn-rail-tick-$turnA')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ValueKey('turn-rail-tick-${hex(9)}')));
    await tester.pumpAndSettle();

    // 回到最新 = 退出锚点态：出口消失、视口回到底部。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(timelinePosition(tester).extentAfter, lessThan(2));
  });
}
