import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 轮次列表弹层（[showTurnListSheet]）的组件级回归（§6.94「移动端形态」）。
///
/// ## 这个文件防的是什么
///
/// 它替代刻度条在触屏 / 窄屏上的位置，三条失败方式各自静默：
///
/// 1. **行高不到 48dp** → 手指点不准，用户点「第 7 轮」跳到「第 6 轮」，
///    而所有断言（行存在、文案对）依然绿；
/// 2. **回调传序号而不是 turnId** → 页面跳到别的轮次或什么都不做；
/// 3. **当前轮没高亮 / 没滚进视野** → 40 轮时打开列表停在顶部，用户看不出来
///    自己在哪一轮（与刻度条同样的坑，但这里没有像素可数，只能靠高亮）。
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

  /// 打开弹层。选中/关闭的结果经 [onResult] 回传（null = 用户滑走或点遮罩）。
  Future<void> openSheet(
    WidgetTester tester, {
    required List<TurnRailEntry> entries,
    String? activeTurnId,
    void Function(String? turnId)? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final turnId = await showTurnListSheet(
                    context,
                    entries: entries,
                    activeTurnId: activeTurnId,
                  );
                  onResult?.call(turnId);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('列出每一轮：序号 + 摘要，行高够手指点', (tester) async {
    final entries = entriesOf(3);
    await openSheet(tester, entries: entries, activeTurnId: turnB);

    expect(find.byKey(const ValueKey('turn-list-sheet')), findsOneWidget);
    for (final entry in entries) {
      final row = find.byKey(ValueKey('turn-list-row-${entry.turnId}'));
      expect(row, findsOneWidget);
      // 48dp 是 Material 的最小可点区域：小于它手指就点不准。
      expect(tester.getSize(row).height, kTurnListRowHeight);
      expect(
        find.descendant(of: row, matching: find.text(entry.label)),
        findsOneWidget,
      );
    }
    // 提示文案给出总轮数（触屏上数不出横杠，只能直接告诉用户）。
    expect(find.text('本对话共 3 轮'), findsOneWidget);
  });

  testWidgets('点某一行：把该轮的 turnId 回传（不是序号）', (tester) async {
    final entries = entriesOf(3);
    String? picked;
    await openSheet(tester, entries: entries, onResult: (id) => picked = id);

    await tester.tap(
      find.byKey(ValueKey('turn-list-row-${entries[2].turnId}')),
    );
    await tester.pumpAndSettle();

    expect(picked, entries[2].turnId);
  });

  testWidgets('多轮时把当前轮滚进视野（否则打开就停在最早几轮）', (tester) async {
    final entries = entriesOf(40);
    await openSheet(
      tester,
      entries: entries,
      activeTurnId: entries.last.turnId,
    );

    final rows = tester.widget<ListView>(
      find.byKey(const ValueKey('turn-list-rows')),
    );
    expect(rows.controller!.position.pixels, greaterThan(0));
  });

  testWidgets('当前轮整行高亮（触屏没有 hover，只能靠底色）', (tester) async {
    final entries = entriesOf(3);
    await openSheet(tester, entries: entries, activeTurnId: turnC);

    Color? rowColor(String turnId) {
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byKey(ValueKey('turn-list-row-$turnId')),
          matching: find.byType(Container),
        ),
      );
      return box.color;
    }

    expect(rowColor(turnC), isNotNull);
    expect(rowColor(turnA), isNull);
  });
}
