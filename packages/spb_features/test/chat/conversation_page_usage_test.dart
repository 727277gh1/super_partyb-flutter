import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 顶部读数区：group token 消耗（账单）+ 上下文窗口（水位）。
///
/// 真源：Go `server/chat_usage.go`（`usage-summary` 聚合）+ `chatexec/usage.go`
/// （`token_usage` 事件）。口径逐条对齐 webapp `WorkbenchStatusSidebar`。
///
/// ⚠️ 这两个量**不能合成一个「已用 / 窗口」**：消耗是账单（只增、跨轮累加），
/// 窗口占用是水位（会随压缩回落）。合成后既不解释花了多少钱，也不解释何时被
/// 压缩——webapp 的注释逐字说明过这一点。
void main() {
  setUpHarness();
  tearDownHarness();

  /// 挂 `usage-summary` 的 mock（全 snake_case，同 Go DTO）。
  void mockUsage({
    int calls = 3,
    int input = 100,
    int output = 50,
    int cached = 20,
    String firstAt = '2026-11-01T02:03:04Z',
    String lastAt = '2026-11-02T02:03:04Z',
  }) {
    adapter.onGet(
      '/chat/groups/grp_1/usage-summary',
      (server) => server.reply(200, {
        'totals': {
          'input_tokens': input,
          'output_tokens': output,
          'cached_tokens': cached,
          'reasoning_tokens': 0,
          'total_tokens': input + output,
          'calls': calls,
          'first_at': firstAt,
          'last_at': lastAt,
        },
        'by_agent': <Object?>[],
      }),
    );
  }

  /// 等基线请求在**真实时区**落地（它由控制器 `unawaited` 发出）。
  Future<void> settleBaseline(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }

  final bar = find.byKey(const ValueKey('conversation-context-usage'));

  group('Token 消耗（账单）', () {
    testWidgets('基线到达后展示消耗总量与明细', (tester) async {
      mockTimeline();
      mockUsage();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      expect(bar, findsOneWidget);
      // 默认收起为一行：总量 chip 可见，明细不渲染（读数不该比正文占地方）。
      expect(find.text('Token 消耗 150 · 请求 3 次'), findsOneWidget);
      expect(find.text('输入 100（缓存 20） · 输出 50'), findsNothing);

      // 点按展开后才见明细；缓存是 input 的子集：只括注，不参与加总。
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.text('输入 100（缓存 20） · 输出 50'), findsOneWidget);

      // 再点一次收起。
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.text('输入 100（缓存 20） · 输出 50'), findsNothing);
    });

    testWidgets('cached 为 0 时不括注（不写「缓存 0」）', (tester) async {
      mockTimeline();
      mockUsage(cached: 0);
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.text('输入 100 · 输出 50'), findsOneWidget);
      expect(find.textContaining('缓存'), findsNothing);
    });

    testWidgets('大数字按 K 缩写（与 webapp formatTokenCount 对齐）', (tester) async {
      mockTimeline();
      mockUsage(calls: 12, input: 50000, output: 10000, cached: 40000);
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      expect(find.text('Token 消耗 60K · 请求 12 次'), findsOneWidget);
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.text('输入 50K（缓存 40K） · 输出 10K'), findsOneWidget);
    });

    testWidgets('calls == 0（还没有账单记录）时不渲染消耗段', (tester) async {
      // 「还没有记录」与「消耗为 0」是两回事：后者会给出一个误导人的 0。
      mockTimeline();
      mockUsage(
        calls: 0,
        input: 0,
        output: 0,
        cached: 0,
        firstAt: '',
        lastAt: '',
      );
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      expect(bar, findsNothing);
      expect(find.textContaining('Token 消耗'), findsNothing);
    });

    testWidgets('无用量数据时不展示（不凭空造 0）', (tester) async {
      mockTimeline(); // 不挂 usage-summary ⇒ 基线拉取失败、静默降级
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      expect(bar, findsNothing);
    });

    testWidgets('未注入 usageSummary 流时不展示（装配层未接线也不崩）', (tester) async {
      mockTimeline();
      mockUsage();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester, wireUsageSummary: false);

      expect(bar, findsNothing);
    });

    testWidgets('首条记录时间以 Tooltip 提示「统计自 X 起」', (tester) async {
      // 数据自上线时点起算，不覆盖更早的会话——不告知会让用户以为统计漏了。
      mockTimeline();
      mockUsage();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      // Tooltip 挂在明细行上（默认收起）——先展开再找。
      await tester.tap(bar);
      await tester.pumpAndSettle();
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('conversation-usage-breakdown')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, contains('统计自 2026-11-01 起'));
      expect(tooltip.message, contains('更早的会话无记录'));
    });
  });

  group('SSE 增量与上下文并存', () {
    testWidgets('token_usage 到达后读数刷新（calls +1）', (tester) async {
      mockTimeline();
      mockUsage();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);
      expect(find.text('Token 消耗 150 · 请求 3 次'), findsOneWidget);

      await pushEvent(
        tester,
        EventTypes.tokenUsage,
        sseEvent(
          EventTypes.tokenUsage,
          id: 'e_usage',
          seq: 40,
          payload: {'input_tokens': 1000, 'output_tokens': 200},
        ),
      );
      await tester.pump();

      // payload 无 calls ⇒ 仍按事件条数 +1（服务端是 COUNT(*)）。
      expect(find.text('Token 消耗 1.4K · 请求 4 次'), findsOneWidget);
      // 明细行默认收起；展开后增量同步可见（totals 是同一份）。
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.text('输入 1.1K（缓存 20） · 输出 250'), findsOneWidget);
    });

    testWidgets('消耗与上下文两行并存（同一槽位、两个语义）', (tester) async {
      mockTimeline();
      mockUsage();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx',
          seq: 41,
          payload: {
            'telemetry': {'context_tokens': 50000, 'context_window': 200000},
          },
        ),
      );
      await tester.pump();

      expect(bar, findsOneWidget, reason: '同一条 bar，不拆成两条');
      expect(
        find.byKey(const ValueKey('conversation-usage-tokens')),
        findsOneWidget,
      );
      expect(find.textContaining('50K / 200K'), findsOneWidget);
    });

    testWidgets('只有上下文、没有消耗时也正常渲染（反之亦然）', (tester) async {
      mockTimeline();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx_only',
          seq: 42,
          payload: {
            'telemetry': {'context_tokens': 12000, 'context_window': 200000},
          },
        ),
      );
      await tester.pump();

      expect(bar, findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-usage-tokens')),
        findsNothing,
      );
      expect(find.textContaining('12K / 200K'), findsOneWidget);
    });

    testWidgets('旧版 pigo 的 0/0 遥测不渲染「上下文 0 / 0」', (tester) async {
      // 生产实测（2026-11-05）：202 条 context_update 里 198 条是这个形状
      // （headless 驱动在 pi-go a2c265b 之前不启用自动压缩 ⇒ ContextWindow=0）。
      // 窗口 0 = 「执行器没报」，不是「窗口是 0」——渲染 0 / 0 会让人以为窗口坏了。
      mockTimeline();
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx_zero',
          seq: 44,
          payload: {
            'telemetry': {
              'turns': 1,
              'context_utilization': 0.0,
              'context_tokens': 0,
              'context_window': 0,
            },
          },
        ),
      );
      await tester.pump();

      expect(bar, findsNothing, reason: '无水位数据时整条读数区不渲染');
      expect(find.textContaining('上下文 0 / 0'), findsNothing);
    });
  });

  group('窄屏（AGENTS.md §6.16）', () {
    testWidgets('320dp 下两行读数不溢出', (tester) async {
      // 读数区原来是单行 Row 硬塞多个字段，320dp 会 RenderFlex overflow。
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      mockTimeline();
      mockUsage(calls: 1234, input: 123456, output: 65432, cached: 111111);
      await startController(tester);
      await settleBaseline(tester);
      await pumpPage(tester);

      await pushEvent(
        tester,
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'e_ctx_narrow',
          seq: 43,
          payload: {
            'telemetry': {'context_tokens': 188888, 'context_window': 200000},
          },
        ),
      );
      await tester.pump();

      expect(bar, findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: '溢出走 FlutterError.onError，会被 takeException 捕获',
      );
    });
  });

  group('formatTokenCount', () {
    test('与 webapp 口径逐字一致', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(-5), '0');
      expect(formatTokenCount(999), '999');
      expect(formatTokenCount(1000), '1K');
      expect(formatTokenCount(1500), '1.5K');
      expect(formatTokenCount(15000), '15K');
      expect(formatTokenCount(131300), '131.3K');
    });
  });

  group('GroupUsageSummary 组合语义（模型层在这里再钉一次）', () {
    test('burnedTokens = input + output，cached 不加总', () {
      const totals = GroupUsageTotals(
        inputTokens: 100,
        outputTokens: 50,
        cachedTokens: 20,
        calls: 1,
      );
      expect(totals.burnedTokens, 150);
    });
  });
}
