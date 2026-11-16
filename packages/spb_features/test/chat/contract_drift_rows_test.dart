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

  group('error 红卡按 code 出表现（#115 的页面级验收）', () {
    // 这组是 #115 唯一还缺的**页面级**闭环：归约层已断言 `isRecoverable`、
    // `spb_ui` 已断言徽标渲染，但「一条真实形状的 error 事件 → 页面上出什么」
    // 之前只有肉眼确认，没有自动化。OOM 在线上一直没样本，若不在这里钉住，
    // 「OOM 显示成什么样」就永远只能靠推理。
    const oomPayload = {
      'code': 'oom_kill',
      'message': '执行被系统内存不足中断，请缩小任务规模后重试',
      'detail': 'oom_kill: 内存上限 128MiB，进程被 SIGKILL (exit 137)',
    };
    const rateLimitedPayload = {
      'code': 'upstream_rate_limited',
      'message': '模型服务繁忙，请稍后重试',
      'detail': 'transport: upstream 429',
    };

    Future<void> pumpWithError(
      WidgetTester tester,
      Map<String, dynamic> payload, {
      String id = 'evt_err',
    }) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onRetryTurn: (_, _) async {});
      await pushEvent(
        tester,
        EventTypes.error,
        sseEvent(EventTypes.error, id: id, payload: payload),
      );
    }

    testWidgets('OOM：徽标「内存不足」、技术详情含 OOM 原文、但没有「重发」', (tester) async {
      await pumpWithError(tester, oomPayload);

      expect(find.textContaining('内存不足'), findsWidgets);
      expect(
        find.text('重发'),
        findsNothing,
        reason: '同样输入 + 同样内存上限必然再崩，重发只会再吃一次杀进程开销',
      );
      expect(find.text('技术详情'), findsOneWidget);
      // detail 默认折叠：原文不进正文（含英文诊断与路径）。
      expect(find.textContaining('SIGKILL'), findsNothing);

      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SIGKILL'), findsOneWidget);
    });

    testWidgets('限流：徽标「上游限流」、有「重发」', (tester) async {
      await pumpWithError(tester, rateLimitedPayload, id: 'evt_err_429');

      expect(find.textContaining('上游限流'), findsWidgets);
      expect(find.text('重发'), findsOneWidget);
      expect(find.textContaining('transport: upstream 429'), findsNothing);
    });
  });
}
