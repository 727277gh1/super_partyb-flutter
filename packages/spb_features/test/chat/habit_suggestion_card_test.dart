import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 造一张未处理的建议卡。
HabitSuggestionItem item({
  String suggestionId = 'run-sugg-1',
  String topicKey = 'weekly-report',
  HabitTriggerType triggerType = HabitTriggerType.timeBased,
  HabitTriggerConfig? triggerConfig,
  double? confidence = 0.72,
  List<String> reasons = const ['每周一你都会让我写周报'],
  HabitUserFeedback? userFeedback,
  String? resolvedPatternId,
  DateTime? snoozeUntil,
}) => HabitSuggestionItem(
  id: 'evt-1',
  createdAt: DateTime.utc(2026, 10, 4),
  turnId: 'turn-1',
  suggestionId: suggestionId,
  topicKey: topicKey,
  triggerType: triggerType,
  triggerConfig: triggerConfig,
  confidence: confidence,
  reasons: reasons,
  userFeedback: userFeedback,
  resolvedPatternId: resolvedPatternId,
  snoozeUntil: snoozeUntil,
);

/// time_based 的典型配置。
HabitTriggerConfig timeCfg() => const HabitTriggerConfig(
  triggerType: HabitTriggerType.timeBased,
  time: HabitTimeTriggerConfig(
    times: [HabitTimeOfDay(hour: 9, minute: 0)],
    weekdays: [1],
  ),
);

/// watch 的典型配置。
HabitTriggerConfig watchCfg() => const HabitTriggerConfig(
  triggerType: HabitTriggerType.watch,
  watch: HabitWatchTriggerConfig(initialSeconds: 3600),
);

void main() {
  group('习惯建议卡：渲染', () {
    testWidgets('展示主题、触发节奏、置信度与理由', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: timeCfg()),
            onAccept: () {},
          ),
        ),
      );

      // topic_key 是机器键，展示时把分隔符换成空格（不编造中文名）。
      expect(find.text('weekly report'), findsOneWidget);
      // 触发节奏按 time 形状渲染。
      expect(find.textContaining('09:00'), findsOneWidget);
      expect(find.text('置信度 72%'), findsOneWidget);
      expect(find.text('· 每周一你都会让我写周报'), findsOneWidget);
    });

    testWidgets('watch 候选不显示「凌晨 0 点」（用户从未表达过的时刻）', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerType: HabitTriggerType.watch,
              triggerConfig: watchCfg(),
            ),
            onAccept: () {},
          ),
        ),
      );

      expect(find.textContaining('00:00'), findsNothing);
      expect(find.textContaining('小时'), findsWidgets);
    });

    testWidgets('triggerConfig 为 null 时不崩，显示「未配置触发时间」', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: null),
            onAccept: () {},
          ),
        ),
      );

      expect(find.text('未配置触发时间'), findsOneWidget);
    });

    testWidgets('topicKey 为空时显示「未命名习惯」而非空白', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(topicKey: '', triggerConfig: timeCfg()),
            onAccept: () {},
          ),
        ),
      );

      expect(find.text('未命名习惯'), findsOneWidget);
    });

    testWidgets('confidence 为 null 时不显示置信度徽标', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(confidence: null, triggerConfig: timeCfg()),
            onAccept: () {},
          ),
        ),
      );

      expect(find.textContaining('置信度'), findsNothing);
    });

    testWidgets('reasons 为空时不渲染理由区', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(reasons: const [], triggerConfig: timeCfg()),
            onAccept: () {},
          ),
        ),
      );

      expect(find.textContaining('· '), findsNothing);
    });
  });

  group('习惯建议卡：回调语义', () {
    testWidgets('点「让它自动做」触发 onAccept', (tester) async {
      var accepts = 0;
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: timeCfg()),
            onAccept: () => accepts++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-accept')));
      await tester.pump();

      expect(accepts, 1);
    });

    testWidgets('点「忽略」触发 onDismiss', (tester) async {
      var dismisses = 0;
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: timeCfg()),
            onDismiss: () => dismisses++,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-dismiss')));
      await tester.pump();

      expect(dismisses, 1);
    });

    testWidgets('稍后菜单列出四个时长，选中传出对应枚举', (tester) async {
      final picked = <HabitSnoozeOption>[];
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: timeCfg()),
            onSnooze: picked.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-snooze')));
      await tester.pumpAndSettle();

      // 四个预设时长全部可见（对齐 webapp SNOOZE_OPTIONS）。
      for (final o in HabitSnoozeOption.values) {
        expect(find.text(o.label), findsOneWidget);
      }

      await tester.tap(find.text(HabitSnoozeOption.oneHour.label));
      await tester.pumpAndSettle();

      expect(picked, [HabitSnoozeOption.oneHour]);
    });

    testWidgets('回调未注入时不显示对应按钮（只读展示）', (tester) async {
      await tester.pumpWidget(
        _host(HabitSuggestionCard(suggestion: item(triggerConfig: timeCfg()))),
      );

      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
      expect(find.byKey(const ValueKey('habit-dismiss')), findsNothing);
      expect(find.byKey(const ValueKey('habit-snooze')), findsNothing);
    });
  });

  group('习惯建议卡：已处理状态', () {
    testWidgets('已接受：按钮消失、显示结果行', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.accepted,
              resolvedPatternId: 'hp-1',
            ),
            onAccept: () {},
            onDismiss: () {},
          ),
        ),
      );

      // 卡片仍在（历史回看要看到「当时建议过什么、我答了什么」）。
      expect(
        find.byKey(const ValueKey('habit-suggestion-run-sugg-1')),
        findsOneWidget,
      );
      expect(find.text('已采纳，习惯已生效'), findsOneWidget);
      // 但按钮全部消失——不能对已处理的建议再操作。
      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
      expect(find.byKey(const ValueKey('habit-dismiss')), findsNothing);
      expect(find.byKey(const ValueKey('habit-snooze')), findsNothing);
    });

    testWidgets('已忽略：显示「已忽略」', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.dismissed,
            ),
            onAccept: () {},
          ),
        ),
      );

      expect(find.text('已忽略'), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-accept')), findsNothing);
    });

    testWidgets('已延后：显示延后时刻', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.snoozed,
              snoozeUntil: DateTime.utc(2026, 10, 5, 0, 0),
            ),
            onAccept: () {},
          ),
        ),
      );

      expect(find.textContaining('已延后至'), findsOneWidget);
    });
  });

  group('习惯建议卡：busy 与在途禁用', () {
    testWidgets('busy 时按钮禁用并显示进度指示', (tester) async {
      var accepts = 0;
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(triggerConfig: timeCfg()),
            busy: true,
            onAccept: () => accepts++,
          ),
        ),
      );

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('habit-accept')),
      );
      expect(btn.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('habit-accept')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(accepts, 0);
    });
  });
}
