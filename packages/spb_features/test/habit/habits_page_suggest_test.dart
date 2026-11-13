import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/habits_harness.dart';

/// 习惯页：建议 Tab（可见性 / 动作 / 撤销）/ 洞察摘要 / 编辑规则
///
/// ⚠️ 本文件由 `habits_page_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `../support/habits_harness.dart`。
void main() {
  group('建议 Tab 的可见性', () {
    testWidgets('未注入 loadSuggestions 时只有两个 Tab（向后兼容）', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.text('规则'), findsOneWidget);
      expect(find.text('执行记录'), findsOneWidget);
      expect(find.text('建议'), findsNothing);
      // 未注入时不渲染「显示已处理」开关（它属于建议 Tab）。
      expect(
        find.byKey(const ValueKey('habit-suggestions-show-resolved')),
        findsNothing,
      );
    });

    testWidgets('注入后出现第三个 Tab，且能切过去', (tester) async {
      await tester.pumpWidget(
        suggestionsHost(
          items: [suggestion()],
          resolveSuggestion: (s, action, {snooze}) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('建议'), findsOneWidget);
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      // 卡片与时间线里的是同一个组件（同主题名、同按钮）。
      expect(find.text('weekly report'), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-accept')), findsOneWidget);
    });

    testWidgets('空列表给空态而不是转圈', (tester) async {
      await tester.pumpWidget(suggestionsHost(items: const []));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('没有待处理的建议'), findsOneWidget);
    });
  });

  group('建议 Tab：动作', () {
    testWidgets('「让它自动做」提交 accept 并刷新列表', (tester) async {
      final calls = <HabitSuggestionAction>[];
      var loads = 0;
      await tester.pumpWidget(
        suggestionsHost(
          items: [suggestion()],
          loadSuggestions: (_) async {
            loads++;
            return loads == 1 ? [suggestion()] : const <HabitSuggestion>[];
          },
          resolveSuggestion: (s, action, {snooze}) async => calls.add(action),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-accept')));
      await tester.pumpAndSettle();

      expect(calls, [HabitSuggestionAction.accept]);
      // 成功后重拉：服务端的权威状态可能与本地预期不同（故不本地移除）。
      expect(loads, 2);
      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
    });

    testWidgets('「忽略」提交 dismiss', (tester) async {
      final calls = <HabitSuggestionAction>[];
      await tester.pumpWidget(
        suggestionsHost(
          items: [suggestion()],
          resolveSuggestion: (s, action, {snooze}) async => calls.add(action),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-dismiss')));
      await tester.pumpAndSettle();

      expect(calls, [HabitSuggestionAction.dismiss]);
    });

    testWidgets('「稍后」提交 snooze 且带选中的时长', (tester) async {
      HabitSnoozeOption? got;
      await tester.pumpWidget(
        suggestionsHost(
          items: [suggestion()],
          resolveSuggestion: (s, action, {snooze}) async => got = snooze,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-snooze')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(HabitSnoozeOption.oneHour.label));
      await tester.pumpAndSettle();

      expect(got, HabitSnoozeOption.oneHour);
    });

    testWidgets('未注入 resolveSuggestion 时卡片没有动作按钮', (tester) async {
      await tester.pumpWidget(suggestionsHost(items: [suggestion()]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
      expect(find.byKey(const ValueKey('habit-dismiss')), findsNothing);
      // 只读展示仍在（用户至少知道「有这条建议」）。
      expect(find.text('weekly report'), findsOneWidget);
    });
  });

  group('建议 Tab：撤销', () {
    testWidgets('「显示已处理」切到 dismissed 分支（服务端只有两个分支）', (tester) async {
      final filters = <HabitSuggestionListFilter>[];
      await tester.pumpWidget(
        suggestionsHost(
          loadSuggestions: (f) async {
            filters.add(f);
            return const <HabitSuggestion>[];
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('habit-suggestions-show-resolved')),
      );
      await tester.pumpAndSettle();

      expect(filters, [
        HabitSuggestionListFilter.pending,
        HabitSuggestionListFilter.dismissed,
      ]);
    });

    testWidgets('已处理项可撤销，撤销后刷新列表', (tester) async {
      final unresolved = <String>[];
      var loads = 0;
      await tester.pumpWidget(
        suggestionsHost(
          loadSuggestions: (_) async {
            loads++;
            return loads == 1
                ? [
                    suggestion(
                      id: 'sugg-9',
                      feedback: 'dismissed',
                      feedbackPayload: const {'action': 'dismiss'},
                    ),
                  ]
                : const <HabitSuggestion>[];
          },
          unresolveSuggestion: (id) async => unresolved.add(id),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-unresolve-sugg-9')));
      await tester.pumpAndSettle();

      expect(unresolved, ['sugg-9']);
      expect(loads, 2);
    });

    testWidgets('未注入 unresolveSuggestion 时不渲染撤销入口', (tester) async {
      await tester.pumpWidget(
        suggestionsHost(
          items: [
            suggestion(
              id: 'sugg-9',
              feedback: 'dismissed',
              feedbackPayload: const {'action': 'dismiss'},
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-unresolve-sugg-9')),
        findsNothing,
      );
    });

    testWidgets('409（已被别处处理）弹提示并说明要刷新', (tester) async {
      await tester.pumpWidget(
        suggestionsHost(
          items: [suggestion()],
          resolveSuggestion: (s, action, {snooze}) async =>
              throw const HttpError(409, '建议已被处理或状态不符'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('建议'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-accept')));
      await tester.pumpAndSettle();

      // 用户必须知道「是别人处理过了」而不是「客户端坏了」。
      expect(find.textContaining('已被别处处理'), findsOneWidget);
      expect(find.textContaining('建议已被处理或状态不符'), findsOneWidget);
    });
  });

  group('洞察摘要', () {
    testWidgets('未注入 loadInsights 时不渲染摘要条', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-insights-bar')), findsNothing);
    });

    testWidgets('渲染建议计数与采纳率', (tester) async {
      await tester.pumpWidget(
        host(habits: const [], loadInsights: (_) async => insights()),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-insights-bar')), findsOneWidget);
      expect(find.textContaining('近 30 天的习惯表现'), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);
      expect(find.textContaining('规则触发 6 次'), findsOneWidget);
    });

    testWidgets('没有建议时不显示「采纳率 0%」（那不是观测，是没有分母）', (tester) async {
      await tester.pumpWidget(
        host(
          habits: const [],
          loadInsights: (_) async => insights(created: 0, accepted: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-insights-empty')),
        findsOneWidget,
      );
      expect(find.textContaining('采纳率'), findsNothing);
      expect(find.textContaining('0%'), findsNothing);
    });

    testWidgets('不呈现重校准指标（Go 版恒为 0，渲染会误导）', (tester) async {
      await tester.pumpWidget(
        host(
          habits: const [],
          // 即使服务端某天开始下发非零值，也不该在本摘要条里出现。
          loadInsights: (_) async => insights(recalibrationTotal: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('重校准'), findsNothing);
      expect(find.textContaining('7'), findsNothing);
    });

    testWidgets('洞察加载失败时静默，页面主体仍可用', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          loadInsights: (_) async => throw const NetworkError('摘要挂了'),
        ),
      );
      await tester.pumpAndSettle();

      // 摘要不该拖垮整页：规则仍在，且没有错误页。
      expect(find.byKey(const ValueKey('habit-insights-bar')), findsNothing);
      expect(find.text('weekly report'), findsOneWidget);
      expect(find.byKey(const ValueKey('habits-retry')), findsNothing);
    });
  });

  group('编辑规则', () {
    testWidgets('对话框回填现值，只提交改动过的字段', (tester) async {
      final patches = <HabitPatch>[];
      await tester.pumpWidget(
        host(
          habits: [habit(topicKey: 'weekly-report')],
          onEdit: (h, patch) async => patches.add(patch),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();

      // 回填现值（不是新建时的默认值）。
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('habit-edit-topic')))
            .controller!
            .text,
        'weekly-report',
      );

      // 只改主题。
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-topic')),
        'daily-report',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-save')));
      await tester.pumpAndSettle();

      expect(patches, hasLength(1));
      final p = patches.single;
      expect(p.topicKey, 'daily-report');
      // 其余字段未动 → 必须是 null（服务端只覆盖「真正出现」的字段；
      // 多发一个 trigger_config 就会重算 next_fire_at）。
      expect(p.acceptanceLevel, isNull);
      expect(p.triggerConfig, isNull);
      expect(p.preferredAgentId, isNull);
    });

    testWidgets('没改动时保存按钮禁用（不发无意义的 PATCH）', (tester) async {
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async {}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('habit-edit-save')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('改接受级别时只提交 acceptance_level', (tester) async {
      final patches = <HabitPatch>[];
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async => patches.add(patch)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-level-auto_run')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-save')));
      await tester.pumpAndSettle();

      final p = patches.single;
      expect(p.acceptanceLevel, HabitAcceptanceLevel.autoRun);
      expect(p.topicKey, isNull);
      expect(p.triggerConfig, isNull);
    });

    testWidgets('改星期时提交 trigger_config（times + 1-based weekday）', (
      tester,
    ) async {
      final patches = <HabitPatch>[];
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async => patches.add(patch)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();
      // 现值是 [1]（周一），加上周三。
      await tester.tap(find.byKey(const ValueKey('habit-edit-weekday-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-save')));
      await tester.pumpAndSettle();

      final cfg = patches.single.triggerConfig!;
      expect(cfg.time!.weekdays, [1, 3]);
      expect(cfg.time!.firstHour, 9);
      expect(cfg.time!.firstMinute, 0);
    });

    testWidgets('盯梢型规则不提供时间编辑，只展示只读节奏', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [
            habit(
              triggerType: HabitTriggerType.watch,
              triggerConfigJson: '{"cadence":{"initial_seconds":1800}}',
            ),
          ],
          onEdit: (h, patch) async {},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-edit-watch-readonly')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('habit-edit-time')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-weekday-1')), findsNothing);
    });

    testWidgets('清空优先 Agent 时提交空串（服务端当清除）', (tester) async {
      final patches = <HabitPatch>[];
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async => patches.add(patch)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-agent')),
        'agent-x',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-agent')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-save')));
      await tester.pumpAndSettle();

      // 原值为空串（无 agent）→ 输入 'agent-x' 再清空 = 回到原点，不算改动。
      expect(patches, isEmpty);
    });

    testWidgets('409 弹提示并说明要刷新', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onEdit: (h, patch) async =>
              throw const HttpError(409, 'habit pattern 不存在'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-topic')),
        'other',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('habit pattern 不存在'), findsOneWidget);
    });

    testWidgets('取消不发请求', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async => calls++),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-topic')),
        'other',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-cancel')));
      await tester.pumpAndSettle();

      expect(calls, 0);
    });
  });
}
