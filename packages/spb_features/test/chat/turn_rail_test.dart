import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 轮次导航刻度条（[TurnRail]）的组件级回归（§6.94）。
///
/// ## 这个文件防的是什么
///
/// 三条交互各自有一条**静默**的失败方式：
///
/// 1. 常驻态只画横杠 → 若渲染成「每轮一行文本」，它会吃掉正文宽度（且
///    200 轮时把时间线挤成一列字）；
/// 2. hover 展开 → 若展开靠 `Row` 挤时间线，会触发整份 Markdown 重排
///    （远程桌面下就是一笔整窗重绘），测试里看不出来但用户能感觉到；
/// 3. 点某格跳转 → 若 `onJump` 传的是**序号**或别的 id，页面会跳到别的轮次
///    （或什么都不做），而这里仍全绿——故断言回调收到的是**归一化的 turnId**。
///
/// ⚠️ 本机无 `DISPLAY`：这些用例证明结构与回调契约，**不**证明真机上 hover
/// 的观感（见 `docs/development.md` 的验证边界）。
void main() {
  const turnA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const turnB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const turnC = 'cccccccccccccccccccccccccccccccc';

  List<TurnRailEntry> entriesOf(int count) => [
    for (var i = 0; i < count; i++)
      TurnRailEntry(
        turnId: [turnA, turnB, turnC][i % 3] + (i >= 3 ? '_$i' : ''),
        label: '第 ${i + 1} 轮的问题',
        createdAt: DateTime.utc(2026, 3, 5, 12, 0, i),
        index: i + 1,
        isLatest: i == count - 1,
      ),
  ];

  Future<void> pumpRail(
    WidgetTester tester, {
    required List<TurnRailEntry> entries,
    String? activeTurnId,
    void Function(String turnId)? onJump,
    VoidCallback? onOpenList,
    double height = 400,
    bool disableAnimations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                height: height,
                child: TurnRail(
                  entries: entries,
                  activeTurnId: activeTurnId,
                  onJump: onJump ?? (_) {},
                  onOpenList: onOpenList,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 鼠标悬停到某个 widget 上（`tester.tap` 不会触发 hover）。
  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(target));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('常驻态：每轮一根横杠，面板不出现', (tester) async {
    final entries = entriesOf(3);
    await pumpRail(tester, entries: entries);

    for (final entry in entries) {
      expect(
        find.byKey(ValueKey('turn-rail-tick-${entry.turnId}')),
        findsOneWidget,
      );
    }
    // 默认不展开：面板不存在（不是「存在但透明」——那会吞掉正文的指针）。
    expect(find.byKey(const ValueKey('turn-rail-panel')), findsNothing);
  });

  testWidgets('激活格用长度区分（不只是颜色）：比相邻格更宽', (tester) async {
    await pumpRail(tester, entries: entriesOf(3), activeTurnId: turnB);

    double tickWidth(String turnId) {
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey('turn-rail-tick-$turnId')),
          matching: find.byType(Container),
        ),
      );
      return box.constraints?.maxWidth ?? 0;
    }

    expect(tickWidth(turnB), greaterThan(tickWidth(turnA)));
    expect(tickWidth(turnB), greaterThan(tickWidth(turnC)));
  });

  testWidgets('hover 刻度列：浮出面板，逐行显示序号与该轮问题摘要', (tester) async {
    final entries = entriesOf(3);
    await pumpRail(tester, entries: entries, activeTurnId: turnB);

    await hover(
      tester,
      find.byKey(ValueKey('turn-rail-tick-${entries[1].turnId}')),
    );

    expect(find.byKey(const ValueKey('turn-rail-panel')), findsOneWidget);
    // 序号 + 标签都在面板里。
    expect(find.text('1'), findsOneWidget);
    expect(find.text(entries[0].label), findsOneWidget);
    expect(find.text(entries[2].label), findsOneWidget);
  });

  testWidgets('点横杠：回调收到该格的 turnId（不是序号）', (tester) async {
    final entries = entriesOf(3);
    String? jumped;
    await pumpRail(
      tester,
      entries: entries,
      activeTurnId: turnA,
      onJump: (turnId) => jumped = turnId,
    );

    await tester.tap(
      find.byKey(ValueKey('turn-rail-tick-${entries[1].turnId}')),
    );
    await tester.pump();

    expect(jumped, entries[1].turnId);
  });

  testWidgets('点面板某一行：同样跳转', (tester) async {
    final entries = entriesOf(3);
    String? jumped;
    await pumpRail(
      tester,
      entries: entries,
      activeTurnId: turnA,
      onJump: (turnId) => jumped = turnId,
    );

    await hover(
      tester,
      find.byKey(ValueKey('turn-rail-tick-${entries[0].turnId}')),
    );
    await tester.tap(
      find.byKey(ValueKey('turn-rail-row-${entries[2].turnId}')),
    );
    await tester.pump();

    expect(jumped, entries[2].turnId);
  });

  testWidgets('轮次很多时：刻度列自身可滚，且打开面板会把激活格滚进视野', (tester) async {
    // 40 轮 × 7px = 280px，视口只有 200px → 必然溢出，激活格在末尾。
    final entries = entriesOf(40);
    await pumpRail(
      tester,
      entries: entries,
      activeTurnId: entries.last.turnId,
      height: 200,
    );

    final ticks = tester.widget<ListView>(
      find.byKey(const ValueKey('turn-rail-ticks')),
    );
    final position = ticks.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    // 首帧就把激活格滚进来（否则「我在最新」的会话里，刻度条永远停在顶部）。
    expect(position.pixels, greaterThan(0));

    await hover(tester, find.byKey(const ValueKey('turn-rail-ticks')));
    final panel = tester.widget<ListView>(
      find.descendant(
        of: find.byKey(const ValueKey('turn-rail-panel')),
        matching: find.byType(ListView),
      ),
    );
    expect(panel.controller!.position.pixels, greaterThan(0));
  });

  testWidgets('触屏点刻度：改为打开列表（没有 hover 也要能看摘要）', (tester) async {
    final entries = entriesOf(3);
    String? jumped;
    var openedList = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 400,
              child: TurnRail(
                entries: entries,
                activeTurnId: turnA,
                onJump: (turnId) => jumped = turnId,
                onOpenList: () => openedList++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 触摸（`kind: touch`）→ 开列表，**不**直跳：手指看不到 hover 面板，
    // 盲跳等于让用户凭猜测点格子。
    await tester.tap(
      find.byKey(ValueKey('turn-rail-tick-${entries[1].turnId}')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(openedList, 1);
    expect(jumped, isNull);

    // 同一根横杠用鼠标点 → 直跳（接上鼠标的平板自动回到桌面语义）。
    await tester.tap(
      find.byKey(ValueKey('turn-rail-tick-${entries[1].turnId}')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(jumped, entries[1].turnId);
    expect(openedList, 1);
  });

  // ---------- 动效参数（§6.94「参数出处」）----------

  /// 参数守卫：这四个数不是随手写的，改它就必须解释。
  ///
  /// 没有这条用例时的失败方式是**静默的**：下一个人把入场调成 300ms（「更顺滑」），
  /// 测试全绿，用户却觉得浮层拖沓——而且远程桌面下帧数翻倍。把依据写进断言，
  /// 改动就会撞上这条，从而被要求给出新依据（与 `tools/` 的守卫同一思路）。
  test('动效参数落在 M3 / Atlassian 的令牌区间', () {
    // M3 `md.sys.motion.duration.short3` = 150ms（Flutter SDK 同名常量）。
    expect(kTurnRailMotion, Durations.short3);
    // hover 态的反馈比「元素进入屏幕」更快：50~150ms 区间，且严格小于入场。
    expect(kTurnRailTickMotion, lessThan(kTurnRailMotion));
    expect(
      kTurnRailTickMotion.inMilliseconds,
      inInclusiveRange(
        Durations.short1.inMilliseconds,
        kTurnRailMotion.inMilliseconds,
      ),
    );
    // M3：退出比进入快，常见做法压到入场的 50%~60%。
    final exitRatio =
        kTurnRailFadeOut.inMilliseconds / kTurnRailMotion.inMilliseconds;
    expect(exitRatio, inInclusiveRange(0.5, 0.6));
  });

  // ---------- 动效（§6.94「动效」）----------

  /// 面板当前的肉眼不透明度（`AnimatedOpacity` → `FadeTransition` 的实时值）。
  ///
  /// 断言「有渐变」只能读实时值：`tester.widget<AnimatedOpacity>().opacity` 是
  /// **目标值**，从它看不出有没有中间帧（那正是本组用例要防的「其实是闪现」）。
  double panelAlpha(WidgetTester tester) {
    // 从面板往上找：`InkWell` 的 hover/ripple 也会造出 `FadeTransition`，
    // 直接 `find.byType` 会命中多个。最近的祖先就是面板自己那层。
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('turn-rail-panel')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    return fade.opacity.value;
  }

  testWidgets('面板是渐变淡入，不是闪现（第一帧未完成）', (tester) async {
    await pumpRail(tester, entries: entriesOf(3));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('turn-rail-ticks'))),
    );

    // 第一帧：面板已在树上，但还几乎透明。
    await tester.pump();
    expect(find.byKey(const ValueKey('turn-rail-panel')), findsOneWidget);
    expect(panelAlpha(tester), lessThan(0.5));

    // 半程：介于 0 与 1 之间 → 确实在渐变，而不是「一帧到位」。
    await tester.pump(kTurnRailMotion ~/ 2);
    final mid = panelAlpha(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));

    await tester.pumpAndSettle();
    expect(panelAlpha(tester), 1);
  });

  testWidgets('指针离开：先淡出，播完才从树上移除', (tester) async {
    final entries = entriesOf(3);
    await pumpRail(tester, entries: entries);
    final gesture = await hover(
      tester,
      find.byKey(const ValueKey('turn-rail-ticks')),
    );
    expect(panelAlpha(tester), 1);

    // 移开到窗口左上角（离开刻度列与面板）。
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    // 还在树上（否则永远看不到出场动画），但目标已是不透明 0。
    expect(find.byKey(const ValueKey('turn-rail-panel')), findsOneWidget);
    await tester.pump(kTurnRailFadeOut ~/ 2);
    expect(panelAlpha(tester), lessThan(1));
    // 收起过程中不能拦住点击：它已经不可见，但还占着那 264px。
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('turn-rail-panel')),
                  matching: find.byType(IgnorePointer),
                )
                // 多层祖先（Material 等也可能插入忽略指针的包装）；
                // 最近的一层就是面板自己那层。
                .first,
          )
          .ignoring,
      isTrue,
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('turn-rail-panel')), findsNothing);
  });

  testWidgets('指针靠近：非激活横杠「填满」一点（不靠 tooltip 提示可点）', (tester) async {
    final entries = entriesOf(3);
    await pumpRail(tester, entries: entries, activeTurnId: turnB);

    double tickWidth(String turnId) =>
        tester
            .widget<Container>(
              find.descendant(
                of: find.byKey(ValueKey('turn-rail-tick-$turnId')),
                matching: find.byType(Container),
              ),
            )
            .constraints
            ?.maxWidth ??
        0;

    expect(tickWidth(turnA), kTurnRailTickWidthIdle);

    await hover(tester, find.byKey(const ValueKey('turn-rail-ticks')));

    expect(tickWidth(turnA), kTurnRailTickWidthHover);
    // 激活格不跟着变：长度是它「我是当前轮」的身份，不该被悬停抹平。
    expect(tickWidth(turnB), kTurnRailTickWidthActive);
  });

  testWidgets('面板标题给出「第几 / 共几轮」', (tester) async {
    await pumpRail(tester, entries: entriesOf(3), activeTurnId: turnB);
    await hover(tester, find.byKey(const ValueKey('turn-rail-ticks')));

    expect(find.text('第 2 / 3 轮'), findsOneWidget);
  });

  testWidgets('系统开启「减少动效」：不过渡、收起后立即移除', (tester) async {
    final entries = entriesOf(3);
    await pumpRail(tester, entries: entries, disableAnimations: true);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('turn-rail-ticks'))),
    );

    // 单帧就到位（时长 0）。
    await tester.pump();
    expect(panelAlpha(tester), 1);

    await gesture.moveTo(Offset.zero);
    await tester.pump();
    // 不等 `onEnd`：立即摘掉（否则会留 80ms 的不可见命中区）。
    expect(find.byKey(const ValueKey('turn-rail-panel')), findsNothing);
  });

  testWidgets('没有轮次时不占位（空对话不该出现一条空刻度列）', (tester) async {
    await pumpRail(tester, entries: const []);

    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);
    // 宽度为 0：调用方（页面）把它摆在时间线右侧的叠层里，占位就会压住正文。
    expect(tester.getSize(find.byType(TurnRail)).width, 0);
  });
}
