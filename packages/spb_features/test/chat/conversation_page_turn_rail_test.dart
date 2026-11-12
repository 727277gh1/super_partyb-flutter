import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
/// 4. **自己滚动时高亮也跟得上**——见文件末尾三条「激活格跟随」的用例：这条
///    曾经全线失灵（`_onScroll` 的两条 early return 把刷新跳过了、锚点态又把
///    高亮钉死），而刻度条自己「画得对、回调传得对」，组件测试一条都不会红。
///
/// ⚠️ 本机是无头 LXC：这些用例证明状态机与几何判据，**不**证明真机上 hover
/// 与跳转的观感（见 `docs/development.md` 的验证边界）。
/// 溢出菜单里那个无关条目的动作（只为了凑出「有调用方条目」的形态）。
void _noop() {}

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

  /// 刻度条当前高亮的轮次（读页面传给 [TurnRail] 的那个值）。
  String? activeTurn(WidgetTester tester) =>
      tester.widget<TurnRail>(find.byType(TurnRail)).activeTurnId;

  /// 拖时间线（正数 = 往回看更早内容，负数 = 往新内容方向）。
  Future<void> scrollTimeline(WidgetTester tester, double dy) async {
    await tester.drag(find.byType(CustomScrollView).first, Offset(0, dy));
    await tester.pumpAndSettle();
  }

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

    // 鼠标点（`kind: mouse`）：桌面语义是直跳。触屏点会打开列表（见下一条用例）
    // ——`tester.tap` 默认是 touch，这里必须显式声明，否则断言的语义会随实现漂移。
    await tester.tap(
      find.byKey(const ValueKey('turn-rail-tick-$turnA')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    // 真的跳上去了（不是「点了没反应」）：贴顶落到该轮、下方仍有大量内容。
    // 限定在时间线内找：鼠标点按会让指针停在刻度列上 → hover 面板里也有
    // 一份「第 0 轮」文本，直接 `find.text` 会命中两个。
    expect(
      tester
          .getTopLeft(
            find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.text('第 0 轮'),
            ),
          )
          .dy,
      lessThan(120),
    );
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

  testWidgets('窄屏：刻度条不出现，但「更多」里有轮次列表，选中即跳转', (tester) async {
    tester.view.physicalSize = const Size(430, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);

    final ids = <List<String>>[];
    for (var i = 0; i < 6; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : hex(i),
          input: '第 $i 轮',
          seq: i * 10 + 1,
        ),
      );
    }
    // 窄屏没有 AppBar 图标的位置，页面靠调用方交来的 overflowItems 摆「更多」。
    await pumpPage(
      tester,
      overflowItems: const [
        ConversationOverflowItem(
          key: ValueKey('menu-test-item'),
          icon: Icons.settings,
          label: '测试项',
          onTap: _noop,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('conversation-overflow-menu')));
    await tester.pumpAndSettle();
    final menuEntry = find.byKey(const ValueKey('menu-conversation-turns'));
    expect(menuEntry, findsOneWidget);

    await tester.tap(menuEntry);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-list-sheet')), findsOneWidget);

    // 选中最早那一轮：弹层关闭并**真的落位**（复用锚点状态机）。
    await tester.tap(find.byKey(const ValueKey('turn-list-row-$turnA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-list-sheet')), findsNothing);
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );
  });

  testWidgets('只有一轮时「更多」里不摆轮次列表（点了也没变化）', (tester) async {
    tester.view.physicalSize = const Size(430, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pushTurn(tester, turnId: turnA, input: '只此一轮', seq: 1);
    await pumpPage(
      tester,
      overflowItems: const [
        ConversationOverflowItem(
          key: ValueKey('menu-test-item'),
          icon: Icons.settings,
          label: '测试项',
          onTap: _noop,
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('conversation-overflow-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu-conversation-turns')), findsNothing);
    expect(
      find.byKey(const ValueKey('menu-conversation-search')),
      findsOneWidget,
    );
  });

  testWidgets('宽屏触屏（平板 / 折叠屏展开）点刻度：打开列表而不是盲跳', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    for (var i = 0; i < 6; i++) {
      await pushTurn(
        tester,
        turnId: i == 0 ? turnA : hex(i),
        input: '第 $i 轮',
        seq: i * 10 + 1,
      );
    }
    await pumpPage(tester);
    await tester.pumpAndSettle();

    // 刻度条在（宽度够），但没有 hover 面板可看；手指点刻度 → 打开列表。
    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('turn-rail-tick-${hex(3)}')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('turn-list-sheet')), findsOneWidget);
    // 弹层里点选才跳（两段式，不是第一下就跳）。
    await tester.tap(find.byKey(ValueKey('turn-list-row-${hex(3)}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-list-sheet')), findsNothing);
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

    // 先跳到首轮（进入锚点态），再点最后一格。两处都是鼠标语义。
    await tester.tap(
      find.byKey(const ValueKey('turn-rail-tick-$turnA')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(ValueKey('turn-rail-tick-${hex(9)}')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    // 回到最新 = 退出锚点态：出口消失、视口回到底部。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(timelinePosition(tester).extentAfter, lessThan(2));
  });

  // ---------- 激活格跟随滚动（2026-11 回归）----------
  //
  // 这一组防的是「刻度条画得对、也点得动，但**从不跟着滚动换格**」——用户看到
  // 的现象是「齿轮不会随滚动条切换」。两处独立的成因，都要钉住：
  //
  //   1. 刷新被 `_onScroll` 的 early return 跳过：用户朝上滚（`forward`）为了
  //      「零容差脱离跟随」直接 return；自动滚动（跟随动画 / 跳转）也 `return`。
  //      而这两条恰好覆盖了「看到更早的轮次」与「程序把我送到某处」两个主场景；
  //   2. 锚点态把高亮钉死：点过刻度跳转之后，无论再怎么滚都停在被跳的那一轮。
  //
  // 两者都**不会**让任何组件测试变红，所以只能在页面层用真几何验证。

  testWidgets('跟随最新时激活格是最后一轮（自动滚动后也要刷新）', (tester) async {
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

    // 首帧后的定位是**自动滚动**（`isAutomatic`）——正是曾经被 early return
    // 跳过的那条路径，所以这条断言同时覆盖成因 1 的另一半。
    expect(timelinePosition(tester).extentAfter, lessThan(2));
    expect(activeTurn(tester), hex(9));
  });

  testWidgets('用户向上滚动：激活格切到视口顶部那一轮', (tester) async {
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
    expect(activeTurn(tester), hex(9));

    // 一轮有 12 段正文，拖 4 次才真正离开最后一轮——拖一次就断言会「碰巧过」。
    for (var i = 0; i < 4; i++) {
      await scrollTimeline(tester, 600);
    }

    final now = activeTurn(tester);
    expect(now, isNotNull);
    expect(now, isNot(hex(9)), reason: '上滚之后高亮必须离开最后一轮');
    // 高亮必须落在**视口顶部可见**的那一轮上，而不是随便一个更早的轮次。
    final rail = tester.widget<TurnRail>(find.byType(TurnRail));
    final index = rail.entries.indexWhere((e) => e.turnId == now);
    final lastIndex = rail.entries.length - 1;
    expect(index, greaterThanOrEqualTo(0));
    expect(index, lessThan(lastIndex));
  });

  testWidgets('点刻度跳转后再自己滚动：激活格不再钉在被跳的那一轮', (tester) async {
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

    await tester.tap(
      find.byKey(const ValueKey('turn-rail-tick-$turnA')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(activeTurn(tester), turnA);

    // 往下滚回更晚的轮次：高亮必须跟着走（曾经会永远停在 turnA）。
    for (var i = 0; i < 3; i++) {
      await scrollTimeline(tester, -600);
    }
    final now = activeTurn(tester);
    expect(now, isNotNull);
    expect(now, isNot(turnA), reason: '锚点态不该把高亮钉死在跳转目标上');
  });
}
