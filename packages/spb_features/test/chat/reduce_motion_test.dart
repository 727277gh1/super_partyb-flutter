import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 「减少动效」在时间线上的实际行为（issue #132）。
///
/// 判据不是「工具函数返回 0」，而是**滚动是否在这一帧就到位**：
/// 系统开了「减少动效」时，追底与定位必须瞬时到达；正常模式下同样的场景
/// 必须还在动画中（否则这条用例证明不了任何东西——见每个用例里的对照断言）。
void main() {
  setUpHarness();
  tearDownHarness();

  /// 时间线 `CustomScrollView` 的滚动位置。
  ///
  /// 不能 `find.byType(Scrollable).first`：页面上还有刻度条、搜索面板等其它
  /// 可滚动区，顺序靠不住。从时间线自身往下找。
  ScrollPosition timelinePosition(WidgetTester tester) {
    final list = find.byType(CustomScrollView).first;
    return tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
  }

  /// 推一条**足够长**的用户消息，让时间线可滚动。
  Future<void> pushFiller(WidgetTester tester) async {
    await pushEvent(
      tester,
      EventTypes.userMessage,
      sseEvent(
        EventTypes.userMessage,
        id: 'e_filler',
        turnId: 'turn_filler',
        seq: 1,
        payload: {'input': List.filled(30, '填满一屏的占位内容').join('\n')},
      ),
    );
  }

  /// 推一条**流式中**的回复（`transient: true`，服务端增量帧的形态）。
  Future<void> pushIncrement(
    WidgetTester tester, {
    required String turnId,
    required String text,
    required int seq,
  }) async {
    await pushEvent(
      tester,
      EventTypes.userMessage,
      sseEvent(
        EventTypes.userMessage,
        id: 'e_user_$turnId',
        turnId: turnId,
        seq: seq,
        payload: {'input': '增量场景 $turnId'},
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: 'e_msg_$turnId',
        turnId: turnId,
        seq: seq + 1,
        payload: {'text': text, 'is_final': false},
        transient: true,
      ),
    );
  }

  group('减少动效：自动追底', () {
    testWidgets('开启后一帧到位（不再 animateTo 150ms）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, disableAnimations: true);
      await pushFiller(tester);
      await tester.pumpAndSettle();

      final position = timelinePosition(tester);
      expect(position.maxScrollExtent, greaterThan(0), reason: '场景前提：可滚动');

      // 新内容到达：高度增长 → `_onItems` 排一次「滚到底」。
      await pushIncrement(
        tester,
        turnId: 'turn_motion',
        text: List.filled(6, '新增的回复内容').join('\n'),
        seq: 10,
      );
      // 两帧：第一帧完成布局 + 排 post-frame 追底，第二帧执行。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        position.extentAfter,
        lessThan(1),
        reason:
            '减少动效时追底必须是 jumpTo（瞬时到达）。这里若还有剩余距离，'
            '说明仍然在跑 150ms 的缓动——而 animateTo 又不接受零时长，'
            '所以「把时长设成 0」这条捷径是不存在的。',
      );
    });

    testWidgets('对照：正常动效下同一场景仍在动画中', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      await pushFiller(tester);
      await tester.pumpAndSettle();

      final position = timelinePosition(tester);
      await pushIncrement(
        tester,
        turnId: 'turn_motion',
        text: List.filled(6, '新增的回复内容').join('\n'),
        seq: 10,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        position.extentAfter,
        greaterThan(1),
        reason:
            '对照断言：正常模式下 16ms 后必然还没到底（SpbDuration.fast=150ms）。'
            '若这条也过了，说明上面那条用例的场景根本没触发滚动，测不出东西。',
      );
    });
  });

  group('减少动效：搜索命中定位', () {
    /// 打开搜索、搜到 [query]、点中第一个命中项。
    ///
    /// 返回「弹层退场完成后的第一帧」与「动画全部结束」两个滚动位置，
    /// 供用例比较「是否瞬时到位」。
    Future<(double, double)> tapHitAndSamplePosition(
      WidgetTester tester, {
      required String query,
      required String hitEventId,
    }) async {
      final position = timelinePosition(tester);
      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        query,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(ValueKey('conversation-search-hit-$hitEventId')),
      );
      // ⚠️ 不能 `pumpAndSettle`：那样会一次跑完整段退场 + 滚动动画，两种模式
      // 的结果完全一样，用例就失去分辨力。这里逐帧推进到弹层消失为止
      // （页面等的是 `route.completed`，即退场动画真正结束）。
      for (var i = 0; i < 60; i++) {
        if (find
            .byKey(const ValueKey('conversation-search-field'))
            .evaluate()
            .isEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 16));
      }
      // 退场完成后的**下一帧**：`route.completed` 兑现 → 定位开始。
      await tester.pump();
      final oneFrame = position.pixels;
      await tester.pumpAndSettle();
      return (oneFrame, position.pixels);
    }

    /// 目标 turn 在最前，8 条填充跟在后面。
    ///
    /// ⚠️ 两个前提缺一不可：
    ///
    /// 1. **顺序**：自动追底让初始视图停在末尾，目标在视口上方，定位必须真的
    ///    往上滚。若把目标放在最后（初始就行），`ensureVisible` 无处可滚，
    ///    两种模式的滚动位置完全相同。
    /// 2. **数量**：填充不能太多。目标行一旦滚出 `ListView` 的构建范围，
    ///    `_scrollToItem` 拿不到它的 context，会走「请向上滚动后重试」的提示
    ///    分支而不是定位——那样两种模式同样都是「没滚动」。
    Future<void> seedTimeline(WidgetTester tester) async {
      await pushEvent(
        tester,
        EventTypes.start,
        sseEvent(
          EventTypes.start,
          id: 'e_start_target',
          turnId: 'turn_target',
          seq: 1,
          payload: {'status': 'running'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'e_user_target',
          turnId: 'turn_target',
          seq: 2,
          payload: {'input': '要定位的目标问题'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'e_msg_target',
          turnId: 'turn_target',
          seq: 3,
          payload: {'text': '要定位的目标回复', 'is_final': true},
        ),
      );
      for (var i = 0; i < 8; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_fill_$i',
            turnId: 'turn_fill_$i',
            seq: 10 + i,
            payload: {'input': '第 $i 条填充内容'},
          ),
        );
      }
    }

    testWidgets('开启后一帧到位', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true, disableAnimations: true);
      await seedTimeline(tester);
      await tester.pumpAndSettle();

      final (oneFrame, settled) = await tapHitAndSamplePosition(
        tester,
        query: '要定位的目标回复',
        hitEventId: 'e_msg_target',
      );

      expect(
        (oneFrame - settled).abs(),
        lessThan(1),
        reason: '减少动效时 `ensureVisible` 走零时长，第一帧就已经在目标位置',
      );
    });

    testWidgets('对照：正常动效下同一帧还在途中', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);
      await seedTimeline(tester);
      await tester.pumpAndSettle();

      final (oneFrame, settled) = await tapHitAndSamplePosition(
        tester,
        query: '要定位的目标回复',
        hitEventId: 'e_msg_target',
      );

      expect(
        (oneFrame - settled).abs(),
        greaterThan(1),
        reason:
            '对照断言：正常模式下定位还在 220ms 的缓动里。若这条也过了，'
            '说明场景的滚动距离是 0（目标本来就在目标位置），上面那条测不出东西。',
      );
    });
  });
}
