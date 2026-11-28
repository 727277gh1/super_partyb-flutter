import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';

/// 动效策略（`SpbMotion`，issue #132）的契约测试。
///
/// ## 这个测试防的是什么
///
/// 「尊重减少动效」最容易的错法是**把时长写成 0 就收工**，而 `animateTo`
/// 恰恰不接受零时长（`ScrollPosition.animateTo` 里有
/// `assert(duration != Duration.zero)`）。那样改的下场是：开着「减少动效」
/// 的用户一追底就崩，正常用户却毫发无伤——不覆盖这条分支就永远发现不了。
///
/// 另一条同样隐蔽：**动效时长与「状态保持时长」混为一谈**。把
/// `SpbDuration.copyFeedback`（「已复制」的 2 秒提示）也一起归零，功能会坏掉。
/// 故这里显式钉住「减少动效只影响动效」。
void main() {
  /// 在指定偏好下读一次 `SpbMotion.duration`。
  Future<Duration?> readDuration(
    WidgetTester tester, {
    required bool disableAnimations,
    Duration? base,
  }) async {
    Duration? captured;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Builder(
          builder: (context) {
            captured = SpbMotion.duration(context, base ?? SpbDuration.normal);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  group('SpbMotion.duration', () {
    testWidgets('减少动效 → 零时长（`ensureVisible` / 隐式动画都接受零时长）', (tester) async {
      expect(
        await readDuration(tester, disableAnimations: true),
        Duration.zero,
      );
    });

    testWidgets('正常 → 令牌原值（不能顺手把全部动效吃掉）', (tester) async {
      expect(
        await readDuration(tester, disableAnimations: false),
        SpbDuration.normal,
      );
      expect(
        await readDuration(
          tester,
          disableAnimations: false,
          base: SpbDuration.fast,
        ),
        SpbDuration.fast,
        reason: 'base 参数必须被采纳（各处过渡的时长不同）',
      );
    });
  });

  group('SpbMotion.scrollTo', () {
    /// 造一个真能滚的 `ScrollController`。
    Future<ScrollController> pumpScrollable(
      WidgetTester tester, {
      required bool disableAnimations,
    }) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: MaterialApp(
            home: ListView.builder(
              controller: controller,
              itemCount: 50,
              itemBuilder: (_, i) =>
                  SizedBox(height: 48, child: Text('row $i')),
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('减少动效 → 同一帧就到位（jumpTo，而不是 animateTo 零时长）', (tester) async {
      final controller = await pumpScrollable(tester, disableAnimations: true);
      final target = controller.position.maxScrollExtent;
      expect(target, greaterThan(0), reason: '场景前提：可滚动');

      await SpbMotion.scrollTo(
        tester.element(find.byType(ListView)),
        controller,
        target,
        duration: SpbDuration.fast,
      );

      expect(
        controller.position.pixels,
        target,
        reason:
            '`jumpTo` 同步生效。若改成 `animateTo(duration: Duration.zero)`，'
            '会先撞上 `assert(duration != Duration.zero)`——本用例以异常失败。',
      );
    });

    testWidgets('正常动效 → 传令牌时长做动画（第一帧还没到位）', (tester) async {
      final controller = await pumpScrollable(tester, disableAnimations: false);
      final target = controller.position.maxScrollExtent;

      // ⚠️ 不能 `await`：假时钟下动画只有 pump 才推进，直接 await 会一直等。
      unawaited(
        SpbMotion.scrollTo(
          tester.element(find.byType(ListView)),
          controller,
          target,
          duration: SpbDuration.fast,
        ),
      );
      await tester.pump();
      expect(controller.position.pixels, lessThan(target));

      await tester.pumpAndSettle();
      expect(controller.position.pixels, target);
    });

    testWidgets('没有 attached position 时空转（不抛异常）', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await expectLater(
        SpbMotion.scrollTo(
          tester.element(find.byType(SizedBox)),
          controller,
          0,
        ),
        completes,
        reason: '页面在 `await` 之后被重建/卸载时不能因未挂载的 controller 崩掉',
      );
    });
  });

  test('减少动效不波及「非动效」的令牌时长', () {
    // 「已复制」提示的 2 秒是**状态保持**，不是过渡动画。归零会让用户看不到
    // 反馈；网络超时与防抖同理（它们压根不在 `SpbMotion` 覆盖范围内）。
    expect(SpbDuration.copyFeedback, const Duration(seconds: 2));
    expect(SpbDuration.copyFeedback, isNot(Duration.zero));
  });
}
