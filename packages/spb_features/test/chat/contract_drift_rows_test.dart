import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 契约漂移的两条可见出口在**页面上**长什么样（issue #116 / #117）。
///
/// 归约层的判据在 `spb_domain/test/event_reducer_contract_drift_test.dart` 里
/// 逐条钉住；这里只验渲染：文案、计数、以及「未知事件行不抢正文视觉权重」的
/// 位置（它必须排在正文之下、且不形成卡片）。
void main() {
  setUpHarness();
  tearDownHarness();

  testWidgets('未知事件渲染成一行弱化提示，带类型名与次数', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 服务端新增、本仓不认识的时间线事件（非 transient、非诊断）。
    await pushEvent(
      tester,
      'brand_new_timeline_event',
      sseEvent('brand_new_timeline_event', id: 'evt_unknown'),
    );
    // 再来一条同类型：应合并成 ×2 而不是两行。
    await pushEvent(
      tester,
      'brand_new_timeline_event',
      sseEvent('brand_new_timeline_event', id: 'evt_unknown2', seq: 2),
    );

    expect(
      find.textContaining('未知事件：brand_new_timeline_event'),
      findsOneWidget,
      reason: '静默丢帧时用户只看到「回答缺了一块」，没有任何可归因线索',
    );
    expect(find.textContaining('×2'), findsOneWidget);
    expect(find.textContaining('客户端可能需要升级'), findsOneWidget);
    // 不是卡片：卡片会在长对话里抢走正文的视觉权重。
    final row = find.textContaining('未知事件：brand_new_timeline_event');
    expect(find.ancestor(of: row, matching: find.byType(Card)), findsNothing);
  });

  testWidgets('已登记的控制类不冒泡成「未知事件」行', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // `executor_startup` 服务端**每次执行都会发**，本仓有意不渲染。
    // 若它被当成「未知时间线事件」，每一次对话都会多一行噪声。
    await pushEvent(
      tester,
      'executor_startup',
      sseEvent('executor_startup', id: 'evt_exec'),
    );

    expect(find.textContaining('未知事件'), findsNothing);
  });

  testWidgets('习惯规则校准渲染成一行摘要（webapp 同口径）', (tester) async {
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    await pushEvent(
      tester,
      EventTypes.habitPatternRecalibrated,
      sseEvent(
        EventTypes.habitPatternRecalibrated,
        id: 'evt_recal',
        payload: {
          'topic_key': 'deep_work',
          'reason': 'blocking_feedback',
          'previous_acceptance_level': 'auto_run',
          'next_acceptance_level': 'confirm_required',
          'blocking_ratio': 0.55,
        },
      ),
    );

    expect(
      find.textContaining('习惯规则已降级'),
      findsOneWidget,
      reason: '这条事件此前落到 default 分支被静默丢弃（#116 目录对拍抓到的真 bug）',
    );
    expect(find.textContaining('deep work'), findsOneWidget);
    expect(find.textContaining('阻塞 55%'), findsOneWidget);
  });
}
