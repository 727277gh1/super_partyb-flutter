import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/habits_harness.dart';

/// 习惯页：执行记录 / 时间窗与原因筛选 / 今日预算条 / 按规则查看执行记录
///
/// ⚠️ 本文件由 `habits_page_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `../support/habits_harness.dart`。
void main() {
  group('执行记录', () {
    testWidgets('渲染主题、触发原因、结果与回复摘要', (tester) async {
      await tester.pumpWidget(host(runs: [run()]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.text('weekly-report'), findsOneWidget);
      expect(find.text('定时触发'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.text('已生成周报草稿。'), findsOneWidget);
      // 对话标题来自注入的 groupTitleOf（服务端只给 id）。
      expect(find.text('团队周报'), findsOneWidget);
    });

    testWidgets('手动触发标记「手动」', (tester) async {
      await tester.pumpWidget(host(runs: [run(isManual: true)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.text('手动'), findsOneWidget);
    });

    testWidgets('失败结果用错误色标注', (tester) async {
      await tester.pumpWidget(
        host(runs: [run(outcome: HabitRunOutcome.failed)]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.text('执行失败'), findsOneWidget);
    });

    testWidgets('点「查看对话」传出 group 与 turn', (tester) async {
      final opened = <(String, String)>[];
      await tester.pumpWidget(
        host(runs: [run()], onOpenTurn: (g, t) => opened.add((g, t))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-run-open-run-1')));
      await tester.pumpAndSettle();

      expect(opened, [('grp-1', 'turn-9')]);
    });

    testWidgets('无 turn 时不显示「查看对话」', (tester) async {
      await tester.pumpWidget(
        host(runs: [run(turnId: null)], onOpenTurn: (_, _) {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-run-open-run-1')), findsNothing);
    });

    testWidgets('空历史显示空态', (tester) async {
      await tester.pumpWidget(host(runs: const []));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有执行记录'), findsOneWidget);
    });
  });

  group('执行记录：时间窗与原因筛选（服务端筛选）', () {
    testWidgets('首次拉取默认带 days=30（不是服务端默认的 7）', (tester) async {
      final filters = <HabitRunsFilter>[];
      await tester.pumpWidget(
        host(
          loadRunsHistory: (f) async {
            filters.add(f);
            return runsResult();
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(filters, [const HabitRunsFilter(days: 30)]);
    });

    testWidgets('选「7 天」后重新请求带 days=7，且不重拉规则列表', (tester) async {
      final filters = <HabitRunsFilter>[];
      var habitsCalls = 0;
      await tester.pumpWidget(
        host(
          loadHabits: () async {
            habitsCalls++;
            return [habit()];
          },
          loadRunsHistory: (f) async {
            filters.add(f);
            return runsResult(items: [run()]);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();
      final habitsBefore = habitsCalls;

      await tester.tap(find.byKey(const ValueKey('habit-runs-days-7')));
      await tester.pumpAndSettle();

      // 第二次请求带 days=7（服务端据此筛选）。
      expect(filters.last, const HabitRunsFilter(days: 7));
      // 换时间窗不该把规则列表也重拉一遍。
      expect(habitsCalls, habitsBefore);
    });

    testWidgets('选原因后请求带 trigger_reason（转成 wire 值）', (tester) async {
      final filters = <HabitRunsFilter>[];
      await tester.pumpWidget(
        host(
          loadRunsHistory: (f) async {
            filters.add(f);
            return runsResult(items: [run()]);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-runs-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动触发').last);
      await tester.pumpAndSettle();

      expect(filters.last.reason, HabitTriggerReason.manual);
      // 保留当前时间窗，不回到默认值。
      expect(filters.last.days, 30);
    });

    testWidgets('筛选重拉失败只影响该 Tab（规则列表仍可用）', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadRunsHistory: (f) async {
            calls++;
            if (calls > 1) throw const NetworkError('筛选失败');
            return runsResult(items: [run()]);
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-runs-days-7')));
      await tester.pumpAndSettle();

      expect(find.text('筛选失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('habits-runs-retry')), findsOneWidget);
      // 规则列表没被错误页吞掉。
      await tester.tap(find.text('规则'));
      await tester.pumpAndSettle();
      expect(find.text('weekly report'), findsOneWidget);
    });
  });

  group('执行记录：今日预算条', () {
    testWidgets('渲染今日已用 / 上限与剩余次数', (tester) async {
      await tester.pumpWidget(
        host(runs: [run()], dailyBudget: budget(limit: 20, usedToday: 3)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-daily-budget')), findsOneWidget);
      expect(find.text('今日自动触发已用 3 / 20'), findsOneWidget);
      expect(find.text('剩余 17 次'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('habit-daily-budget-exhausted')),
        findsNothing,
      );
    });

    testWidgets('额度用尽时给出明确文案（不是只把进度条填满）', (tester) async {
      await tester.pumpWidget(
        host(runs: [run()], dailyBudget: budget(limit: 5, usedToday: 5)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.text('额度已用尽'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('habit-daily-budget-exhausted')),
        findsOneWidget,
      );
      expect(find.textContaining('手动「立即执行」也会被服务端拒绝'), findsOneWidget);
    });

    testWidgets('超出上限也不出现负数剩余', (tester) async {
      // 服务端统计与配置可能在并发下短暂不一致。
      await tester.pumpWidget(
        host(runs: [run()], dailyBudget: budget(limit: 5, usedToday: 8)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.text('今日自动触发已用 8 / 5'), findsOneWidget);
      expect(find.text('额度已用尽'), findsOneWidget);
    });

    testWidgets('服务端未下发 daily_budget 时不渲染预算条', (tester) async {
      await tester.pumpWidget(host(runs: [run()]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-daily-budget')), findsNothing);
    });

    testWidgets('limit=0 不渲染（不造一条恒满/恒空的条）', (tester) async {
      await tester.pumpWidget(
        host(runs: [run()], dailyBudget: budget(limit: 0, usedToday: 0)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-daily-budget')), findsNothing);
    });
  });

  group('按规则查看执行记录', () {
    testWidgets('点「执行记录」调 loadHabitRuns(patternId) 而非 loadRuns', (
      tester,
    ) async {
      var allRunsCalls = 0;
      final patternIds = <String>[];
      await tester.pumpWidget(
        host(
          habits: [habit(id: 'hp-7', topicKey: 'weekly-report')],
          loadRuns: () async {
            allRunsCalls++;
            return const <HabitRun>[];
          },
          loadHabitRuns: (patternId) async {
            patternIds.add(patternId);
            return [run(id: 'run-p')];
          },
        ),
      );
      await tester.pumpAndSettle();
      final callsBefore = allRunsCalls;

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-7')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      // 传的是这条规则的 id，不是「全部」。
      expect(patternIds, ['hp-7']);
      // 没有额外调跨规则的 listAllRuns。
      expect(allRunsCalls, callsBefore);
    });

    testWidgets('标题用规则自身的 topic_key（不依赖对话标题预取）', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit(topicKey: 'weekly-report')],
          loadHabitRuns: (_) async => const <HabitRun>[],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      // AppBar 标题 = 规则主题（分隔符换成空格），不是「团队周报」。
      expect(find.text('weekly report'), findsOneWidget);
    });

    testWidgets('渲染该规则的记录与空态', (tester) async {
      await tester.pumpWidget(
        host(habits: [habit()], loadHabitRuns: (_) async => const <HabitRun>[]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      expect(find.textContaining('这条规则还没有执行记录'), findsOneWidget);
    });

    testWidgets('加载失败显示错误与重试', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadHabitRuns: (_) async => throw const NetworkError('记录加载失败'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      expect(find.text('记录加载失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-runs-retry')), findsOneWidget);
    });

    testWidgets('筛选是**本地**的（单规则端点无 days/trigger_reason）', (tester) async {
      // ⚠️ 回归锁：服务端 `GET /api/habits/:pattern_id/runs` 只接受
      // limit/offset（SQL `ListHabitRuns` 无时间窗）。若这里改成「换筛选就
      // 重拉」，会造出「服务端筛选」的假象，而实际什么也没过滤。
      var calls = 0;
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadHabitRuns: (_) async {
            calls++;
            return [
              run(id: 'r-due'),
              run(id: 'r-manual', reason: HabitTriggerReason.manual),
            ];
          },
          onOpenTurn: (_, _) {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();
      final before = calls;

      await tester.tap(find.byKey(const ValueKey('habit-runs-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动触发').last);
      await tester.pumpAndSettle();

      // 没有重发请求。
      expect(calls, before);
      // 手动那条留着，due_rule 那条被滤掉。
      expect(
        find.byKey(const ValueKey('habit-run-open-r-manual')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('habit-run-open-r-due')), findsNothing);
    });

    testWidgets('本地筛选到空时给出可操作的空态（不是「没有记录」）', (tester) async {
      await tester.pumpWidget(
        host(habits: [habit()], loadHabitRuns: (_) async => [run()]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-runs-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('盯梢变化').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('当前筛选条件下没有记录'), findsOneWidget);
    });

    testWidgets('默认时间窗是 30 天：更早的记录被滤掉', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadHabitRuns: (_) async => [
            run(
              id: 'r-old',
              createdAt: DateTime.now().toUtc().subtract(
                const Duration(days: 40),
              ),
            ),
          ],
          onOpenTurn: (_, _) {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();

      // 40 天前 → 默认 30 天窗口外。
      expect(find.byKey(const ValueKey('habit-run-open-r-old')), findsNothing);
      expect(find.textContaining('当前筛选条件下没有记录'), findsOneWidget);
    });

    testWidgets('选「不限」后更早的记录重新出现（本地筛选的完整历史）', (tester) async {
      // ⚠️ 回归锁：单规则页存在的理由就是「看**完整**历史」。若只给
      // 7/30/90 而没有「不限」，40 天前的记录就永远看不到了——而服务端
      // 本已把它返回了。
      var calls = 0;
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadHabitRuns: (_) async {
            calls++;
            return [
              run(
                id: 'r-old',
                createdAt: DateTime.now().toUtc().subtract(
                  const Duration(days: 40),
                ),
              ),
            ];
          },
          onOpenTurn: (_, _) {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-runs')));
      await tester.pumpAndSettle();
      final before = calls;

      await tester.tap(find.byKey(const ValueKey('habit-runs-days-all')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-run-open-r-old')),
        findsOneWidget,
      );
      // 仍是本地筛选：不重发请求。
      expect(calls, before);
    });

    testWidgets('全局历史 Tab 不提供「不限」（days=0 服务端会归一成 1 天）', (tester) async {
      // ⚠️ 回归锁：服务端 `if days < 1 { days = 1 }`——传 0 得到的是**最窄**
      // 的结果（1 天），与「不限」语义相反。故该选项只能给本地筛选的页面。
      await tester.pumpWidget(host(runs: [run()]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行记录'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-runs-days-all')), findsNothing);
    });
  });
}
