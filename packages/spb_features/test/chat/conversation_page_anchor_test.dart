import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 深链锚点（`?turn=<turnId>`）在**页面层**的行为回归。
///
/// ## 这个文件防的是什么
///
/// `turn_anchor_test.dart` 只能证明纯函数算得对；钉不住「页面真的按它落位」：
/// 页面若把锚点参数丢掉、或落位后又立刻被「新事件滚到底」拽回去，纯逻辑测试
/// 仍全绿。而这类缺陷的现场表现是**用户点了链接看到对话末尾**——没有异常、
/// 没有日志。
///
/// 故这里断言的是三件**用户可见**的事：
///
/// 1. 命中历史轮次 → 该轮被高亮，且视口**不在底部**（真的跳上去了）；
/// 2. 锚点态下新事件到达 → 视口**不动**（不被拽回底部），并给出「回到最新」；
/// 3. 越界 / 即最后一轮 → 说话 + 不移动视口，而不是静默停在某处。
///
/// ⚠️ 夹具用**真实形态**的 turnId（32 位 hex，对齐 Go `chatid.NewID`）。
///
/// ⚠️ 本机是无头 LXC：这些用例证明状态机与落位参数正确，**不能**证明真机上
/// 「换分界行」那次跳变的观感（见 `docs/development.md` 的验证边界）。
void main() {
  setUpHarness();
  tearDownHarness();
  setUp(() {
    PerfProbe.reset();
    SpbLog.clearRecentLogs();
  });

  /// 真实形态的 turn id（hex）。`turnA` = 首轮，`turnC` = 从未加载过的轮次。
  const turnA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const turnC = 'cccccccccccccccccccccccccccccccc';

  /// 时间线的滚动位置。
  ///
  /// 必须从 `CustomScrollView` 的 controller 取，不能 `find.byType(Scrollable).first`：
  /// 页面上还有别的可滚动区域（输入框、弹出层）。
  ScrollPosition timelinePosition(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView).first)
      .controller!
      .position;

  bool atBottom(WidgetTester tester) {
    final position = timelinePosition(tester);
    return position.extentAfter <= 1;
  }

  /// 推一轮完整对话（`start` → `user_message` → `message` → `done`），
  /// 返回用户消息与回复的 eventId。
  ///
  /// ## 为什么必须**按真实顺序**推四个事件
  ///
  /// 归约器把「流式段落」记在 `currentAssistantIdx` 里，只有 `start` 会把它清空
  /// （见 `event_reducer.dart` 的 `EventTypes.start` 分支）。少推 `start`，下一轮的
  /// `message` 就会被当成**同一段的权威帧**原地替换上一轮的回复——夹具于是只剩
  /// 一条回复，而测试仍然“绿”（历史没有被真正堆起来）。这是我在本文件里踩过的
  /// 坑：先用 2 个事件堆 10 轮，结果只有 11 个 item。
  ///
  /// `done` 让该轮进入 `completedTurns`（失败/执行中的视觉状态不同，混进来会让
  /// 快照与断言不稳）。
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
    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: '$short-start-$seq',
        turnId: turnId,
        seq: seq,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.userMessage,
      sseEvent(
        EventTypes.userMessage,
        id: userId,
        turnId: turnId,
        payload: {'input': input},
        seq: seq + 1,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: assistantId,
        turnId: turnId,
        payload: {
          'text': List.generate(
            lines,
            (i) => '$input 的第 $i 段回复正文。',
          ).join('\n\n'),
        },
        seq: seq + 2,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: '$short-done-$seq',
        turnId: turnId,
        seq: seq + 3,
      ),
    );
    return [userId, assistantId];
  }

  testWidgets('锚点命中历史轮次：落到该轮并高亮，新事件不再把视口拽回底部', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);

    // 先堆出「远超一屏」的历史，让第一轮落在视口外（未构建的行）。
    final ids = <List<String>>[];
    for (var i = 0; i < 10; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    TurnAnchorOutcome? outcome;
    await pumpPage(
      tester,
      anchorTurnId: turnA,
      onAnchorResolved: (o) => outcome = o,
    );
    await tester.pumpAndSettle();

    expect(outcome, TurnAnchorOutcome.jumped);
    // 该轮的两行（用户消息 + 回复）都被高亮：高亮按**行**渲染，键按行主键唯一。
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[1]}')),
      findsOneWidget,
    );
    // 真的跳上去了，而且是**贴顶**落到该轮（不是「安静地停在对话末尾」）。
    // 断言落点的绝对 dy，而不是「不在底部」：后者在「页面本来就停在顶部」时
    // 也成立，等于什么都没证明。
    final anchoredDy = tester.getTopLeft(find.text('第 0 轮')).dy;
    expect(anchoredDy, lessThan(120));
    // 下方仍有大量内容（这就是「从这一轮往下读」的语境）。
    expect(timelinePosition(tester).extentAfter, greaterThan(500));
    // 锚点态才有「回到最新」。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    // 新事件到达：跟随已关，视口不能被拽回底部（这正是 webapp 的
    // `followOutput` 在锚点态要关掉的那件事）。
    await pushTurn(tester, turnId: _hex(99), input: '锚点之后的新一轮', seq: 900);
    await tester.pumpAndSettle();
    // 视口**逐像素没动**：这才是「不被拽回底部」的强断言。
    // （只断言「不在底部」会让「本来就没跟随」的缺陷漏过去。）
    expect(tester.getTopLeft(find.text('第 0 轮')).dy, closeTo(anchoredDy, 1));
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );

    // 「回到最新」：清锚点 + 回底部。
    await tester.tap(find.byKey(const ValueKey('conversation-back-to-latest')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);
  });

  testWidgets('用户自己滚回底部 → 退出锚点态（高亮与「回到最新」都消失）', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    final ids = <List<String>>[];
    for (var i = 0; i < 8; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    await pumpPage(tester, anchorTurnId: turnA);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );

    // 手动滚到底（等价于用户自己往下翻到最新）。
    timelinePosition(tester).jumpTo(timelinePosition(tester).maxScrollExtent);
    await tester.pumpAndSettle();

    // 锚点态按「用户在不在那一轮」判定，而不是按「曾经跳没跳过」：滚到底就是
    // 离开了那一轮，高亮与入口都该消失（否则会一直挂着一个无用按钮）。
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 且**不会**被下一批 items 拽回那一轮（已滚到底 = 恢复跟随）。
    await pushTurn(tester, turnId: _hex(99), input: '滚回底部后的新消息', seq: 900);
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
  });

  testWidgets('锚点越界：不移动视口，只提示一次', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    // 堆到**必须滚动**的高度：否则 `atBottom` 在「内容不满一屏」时恒真，
    // 「越界不移动视口」就成了一条永远成立的断言。
    for (var i = 0; i < 6; i++) {
      await pushTurn(
        tester,
        turnId: i == 0 ? turnA : _hex(i),
        input: '第 $i 轮',
        seq: i * 4 + 1,
      );
    }

    final outcomes = <TurnAnchorOutcome>[];
    await pumpPage(
      tester,
      anchorTurnId: turnC, // 从未加载过的轮次
      onAnchorResolved: outcomes.add,
    );
    await tester.pumpAndSettle();

    expect(outcomes, [TurnAnchorOutcome.missing]);
    expect(find.textContaining('不在已加载的消息范围'), findsOneWidget);
    // 不移动视口：越界时停在底部（首屏的正常落点），而不是停在顶部/半空。
    expect(atBottom(tester), isTrue);
    // 越界不进锚点态 → 不该出现「回到最新」。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 后续事件不重复提示（按锚点值去重），也不补跳（v1 作用域只有已加载）。
    await pushTurn(tester, turnId: _hex(77), input: '新的一轮', seq: 700);
    await tester.pumpAndSettle();
    expect(find.textContaining('不在已加载的消息范围'), findsOneWidget);
    expect(atBottom(tester), isTrue);
  });

  testWidgets('锚点即最后一轮：按「跟随最新」处理（不高亮、不钉住滚动）', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    // 同上：内容必须超过一屏，「仍在跟随」才是有意义的断言。
    final ids = <List<String>>[];
    for (var i = 0; i < 6; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }
    final first = ids.first;
    final last = ids.last;
    // 锚点指向**最后一轮**（用它的 turnId，与「第 N 轮」序号无关）。
    final lastTurnId = _hex(5);

    TurnAnchorOutcome? outcome;
    await pumpPage(
      tester,
      anchorTurnId: lastTurnId,
      onAnchorResolved: (o) => outcome = o,
    );
    await tester.pumpAndSettle();

    expect(outcome, TurnAnchorOutcome.followingLatest);
    expect(find.byKey(ValueKey('turn-highlight-${last[0]}')), findsNothing);
    expect(find.byKey(ValueKey('turn-highlight-${first[0]}')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);

    // 内容真的超过一屏（上面的 `atBottom` 不是「无滚动」时恒真）。
    expect(timelinePosition(tester).maxScrollExtent, greaterThan(100));

    // 仍跟随：新一轮到达后依旧在底部（锚点没有把它钉在旧位置）。
    await pushTurn(tester, turnId: turnC, input: '新的最后一轮', seq: 900);
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
  });

  testWidgets('换锚点值 / 切对话：锚点态重置', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    final ids = <List<String>>[];
    for (var i = 0; i < 8; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    // 无锚点进入：正常跟到底部（这是「已经在对话里」的基线，也是下面
    // 「从底部被送到历史某一轮」这条最常用路径的起点）。
    await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(timelinePosition(tester).maxScrollExtent, greaterThan(100));
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 同一个 State 被复用（只换锚点值）：必须从底部**跳上去**，而不是停在原处
    // 或安静地什么也不做。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_1',
      anchorTurnId: _hex(1),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[1][0]}')), findsOneWidget);
    expect(timelinePosition(tester).extentAfter, greaterThan(500));
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    // 再换锚点值（这一次目标行在底部视口外 → 走「搬分界行」的落位原语）：
    // 必须重新定位，而不是停在旧锚点。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_1',
      anchorTurnId: _hex(5),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[1][0]}')), findsNothing);
    expect(find.byKey(ValueKey('turn-highlight-${ids[5][0]}')), findsOneWidget);

    // 换对话（historyKey 变 + 不带锚点，即从列表点进另一个对话）→ 锚点态与
    // 高亮全部清掉，且重新回到「跟随最新」。
    //
    // ⚠️ 若换对话时**仍**带着同一个锚点值（URL 里就写着 `?turn=`），页面会拿它
    // 在新对话里重新解析——这是对的：锚点是 URL 的一部分，它描述的是「这个对话
    // 的某一轮」而不是「上一次定位的结论」。故这里故意不传锚点。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_2',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[5][0]}')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);
  });
}

/// 生成一个真实形态的 turnId（32 位 hex），避免用例之间撞 id。
String _hex(int n) => n.toRadixString(16).padLeft(32, '0');
