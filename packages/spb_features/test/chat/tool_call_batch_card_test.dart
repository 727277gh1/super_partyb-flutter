import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 连续工具调用的折叠卡（`ToolCallBatchCard`）测试。
///
/// ## 这个文件防的是什么
///
/// 折叠的价值是「少占视野」，代价是**信息被收起来**。所以最关键的不是
/// 「能不能折」，而是**什么时候不许折**：
///
/// - 批里有正在跑的工具（`output == null`）时必须默认展开——那是用户唯一
///   能看见的「它在干活」的证据（同 §5.8 保留未完成工具的取向）；
/// - 展开后必须逐条还原成 [ToolCallTile]，一条都不能少（折叠不能变成删除）；
/// - 展开态是视图状态，但**用户点过之后**不能被后续推送覆盖回去。
class _Tool {
  static ToolCallItem call(
    String id, {
    String name = 'Read',
    String? output = 'ok',
    Map<String, dynamic>? args,
    String turnId = 'turn_1',
  }) => ToolCallItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    name: name,
    turnId: turnId,
    args: args,
    output: output,
    isComplete: output != null,
  );

  static ToolCallBatchRow batch(
    int count, {
    int runningTail = 0,
    String Function(int i)? name,
  }) => ToolCallBatchRow(
    calls: [
      for (var i = 0; i < count - runningTail; i++)
        call('t$i', name: name?.call(i) ?? 'Tool$i'),
      for (var i = count - runningTail; i < count; i++)
        call('t$i', name: name?.call(i) ?? 'Tool$i', output: null),
    ],
  );
}

void main() {
  /// 推一帧卡片并**推进固定时长**后返回。
  ///
  /// ⚠️ 不能用 `pumpAndSettle`：含在飞工具的批会渲染 `CircularProgressIndicator`
  /// （无限循环动画），`pumpAndSettle` 会一直等到超时。
  ///
  /// 展开动画只有 200ms，但**必须再补一帧**：单次 `pump(400ms)` 让
  /// `AnimationController` 走到终态后还要一帧才把「移除子树」这件事渲染出来
  /// （实测少那一帧，收起后的成员仍挂在树上）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  /// 点卡的**头部**（标题）。
  ///
  /// ⚠️ 不能点 `tool-call-batch-tile` 本身：`tester.tap` 点的是控件几何中心，
  /// 而卡片展开后中心落在正文里（某个成员的 `ToolCallTile` 上），点击不会传到
  /// 头部的 `ListTile.onTap`——实测表现为「怎么点都收不起来」。
  Future<void> tapHeader(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tool-call-batch-title')));
    await settle(tester);
  }

  Future<void> pumpCard(WidgetTester tester, ToolCallBatchRow batch) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [ToolCallBatchCard(batch: batch)]),
        ),
      ),
    );
    await settle(tester);
  }

  group('默认展开态', () {
    testWidgets('全部完成 → 默认折叠（成员不渲染，省下的正是这部分高度）', (tester) async {
      await pumpCard(tester, _Tool.batch(6));

      expect(find.text('已调用 6 个工具'), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-batch-member-t0')), findsNothing);
      expect(find.byType(ToolCallTile), findsNothing);
    });

    testWidgets('含执行中的调用 → 默认展开（「它在干活」的证据不许藏起来）', (tester) async {
      await pumpCard(tester, _Tool.batch(6, runningTail: 1));

      expect(find.byType(ToolCallTile), findsNWidgets(6));
      expect(
        find.byKey(const ValueKey('tool-batch-member-t5')),
        findsOneWidget,
      );
    });

    testWidgets('展开态按**批**判定：跑完的那一批会自己收回去', (tester) async {
      // 同一组件实例（同 key）从「有在飞」变成「全完成」，且用户从没点过 →
      // 展开态应跟着回到折叠。若把它固化在 initState，一轮跑完后这张卡会
      // 永远摊在时间线上——正是要消除的噪声。
      await pumpCard(tester, _Tool.batch(5, runningTail: 1));
      expect(find.byType(ToolCallTile), findsNWidgets(5));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [ToolCallBatchCard(batch: _Tool.batch(5))],
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(ToolCallTile), findsNothing);
    });

    testWidgets('自动收起之后同一批又出现执行中 → 必须再次自动展开', (tester) async {
      // 这是 `_syncingExpansion` 的唯一守卫用例：程序化 collapse 也会回调
      // `onExpansionChanged`，若不把「程序同步」与「用户点击」分开，那一次
      // 回调会把 `_expanded` 写成 false —— 组件从此认为「用户自己收起来的」，
      // 后续再也不会自动展开。
      //
      // 真实场景就是同一轮 agent 接着调第 7 个工具：批的 key 取首条 id，故
      // 组件实例不变、`hasRunning` 由 false 翻回 true。此时卡片必须重新摊开，
      // 否则「它在干活」又看不见了（正是本卡要避免的那件事）。
      await pumpCard(tester, _Tool.batch(5, runningTail: 1));
      await pumpCard(tester, _Tool.batch(5)); // 跑完 → 自动收起
      expect(find.byType(ToolCallTile), findsNothing);

      await pumpCard(tester, _Tool.batch(6, runningTail: 1));

      expect(
        find.byType(ToolCallTile),
        findsNWidgets(6),
        reason: '批里又有在飞的工具了，收起状态必须让位',
      );
    });
  });

  group('摘要文案', () {
    testWidgets('全部完成 → 「最近：最后一个工具」（不给多余的「已完成 5/5」）', (tester) async {
      await pumpCard(tester, _Tool.batch(5, name: (i) => 'T$i'));

      expect(find.text('已调用 5 个工具'), findsOneWidget);
      expect(find.text('最近：T4'), findsOneWidget);
      expect(find.textContaining('已完成'), findsNothing);
    });

    testWidgets('有执行中 → 「执行中 · 最近：X（已完成 N/M）」', (tester) async {
      await pumpCard(
        tester,
        _Tool.batch(12, runningTail: 1, name: (i) => 'T$i'),
      );

      expect(find.text('已调用 12 个工具'), findsOneWidget);
      expect(find.text('执行中 · 最近：T11（已完成 11/12）'), findsOneWidget);
    });

    testWidgets('标题与副标题各带稳定 key（页面用它断言接线）', (tester) async {
      await pumpCard(tester, _Tool.batch(5));

      expect(
        find.byKey(const ValueKey('tool-call-batch-tile')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tool-call-batch-title')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tool-call-batch-subtitle')),
        findsOneWidget,
      );
    });
  });

  group('展开后逐条还原（折叠 ≠ 删除）', () {
    testWidgets('点开后每个成员一条 [ToolCallTile]，顺序与批内一致', (tester) async {
      await pumpCard(tester, _Tool.batch(6, name: (i) => 'T$i'));
      expect(find.byType(ToolCallTile), findsNothing);

      await tapHeader(tester);

      final tiles = tester.widgetList<ToolCallTile>(find.byType(ToolCallTile));
      expect(tiles.map((t) => t.name).toList(), [
        'T0',
        'T1',
        'T2',
        'T3',
        'T4',
        'T5',
      ]);
      // 每个成员都有独立 key → 搜索定位能落到这张卡（`locateIdsOf` 的口径），
      // 也让单卡的展开态互不干扰。
      for (var i = 0; i < 6; i++) {
        expect(find.byKey(ValueKey('tool-batch-member-t$i')), findsOneWidget);
      }
    });

    testWidgets('成员的入参与输出照原样交给单卡（二次折叠由单卡自己管）', (tester) async {
      final batch = ToolCallBatchRow(
        calls: [
          for (var i = 0; i < 5; i++)
            _Tool.call(
              't$i',
              name: 'Bash',
              args: const {'cmd': 'ls'},
              output: 'out$i',
            ),
        ],
      );
      await pumpCard(tester, batch);
      await tapHeader(tester);

      final tiles = tester
          .widgetList<ToolCallTile>(find.byType(ToolCallTile))
          .toList();
      expect(tiles, hasLength(5));
      expect(tiles.every((t) => t.args != null), isTrue);
      expect(tiles.map((t) => t.output), [
        'out0',
        'out1',
        'out2',
        'out3',
        'out4',
      ]);
      // 单卡默认折叠 → 展开这张卡不等于把 5 段输出全摊开。
      expect(find.text('out0'), findsNothing);
    });

    testWidgets('收起后成员从树上摘掉（这是折叠省下的成本）', (tester) async {
      await pumpCard(tester, _Tool.batch(6, runningTail: 1));
      expect(find.byType(ToolCallTile), findsNWidgets(6));

      await tapHeader(tester);

      expect(find.byType(ToolCallTile), findsNothing);
    });

    testWidgets('⭐ 用户手动展开后，后续推送不得把它收回去', (tester) async {
      // 一轮流式里这张卡会被重建几十次。若每次都用 `hasRunning` 覆盖用户
      // 的选择，用户正在看的那一段输出会自己关掉。
      await pumpCard(tester, _Tool.batch(5));
      expect(find.byType(ToolCallTile), findsNothing);

      await tapHeader(tester);
      expect(find.byType(ToolCallTile), findsNWidgets(5));

      // 同 key、同内容再推一次（模拟一轮归约后的重建）。
      await pumpCard(tester, _Tool.batch(5));
      expect(find.byType(ToolCallTile), findsNWidgets(5));

      // ⚠️ 上面两次推送都**没有**让 `hasRunning` 发生变化，因此即使实现根本
      // 不尊重用户意图也照样绿（实测：把 `didUpdateWidget` 里的「用户点过就
      // 不再跟随」那条判据删掉，前三步全绿）。真正能抓住它的是下面这条
      // **展开→收起翻转**：用户展开的是已完成的一批，随后同批又跑起一个
      // 工具、再跑完 —— 这一次 true→false 的翻转正是自动收起的触发点，
      // 少了用户判据就会把用户正在看的清单关掉。
      await pumpCard(tester, _Tool.batch(6, runningTail: 1));
      expect(find.byType(ToolCallTile), findsNWidgets(6));

      await pumpCard(tester, _Tool.batch(6));
      expect(
        find.byType(ToolCallTile),
        findsNWidgets(6),
        reason: '用户自己展开的卡，不该被「跑完了」自动收起来',
      );
    });
  });
}
