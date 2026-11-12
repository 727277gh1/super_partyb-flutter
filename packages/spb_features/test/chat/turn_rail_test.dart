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
    double height = 400,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: height,
              child: TurnRail(
                entries: entries,
                activeTurnId: activeTurnId,
                onJump: onJump ?? (_) {},
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

  testWidgets('没有轮次时不占位（空对话不该出现一条空刻度列）', (tester) async {
    await pumpRail(tester, entries: const []);

    expect(find.byKey(const ValueKey('turn-rail-ticks')), findsNothing);
    // 宽度为 0：调用方（页面）把它摆在时间线右侧的叠层里，占位就会压住正文。
    expect(tester.getSize(find.byType(TurnRail)).width, 0);
  });
}
