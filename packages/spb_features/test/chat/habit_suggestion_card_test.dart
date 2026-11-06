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
  List<String> editableFields = const [],
  String? preferredAgentId,
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
  editableFields: editableFields,
  preferredAgentId: preferredAgentId,
  userFeedback: userFeedback,
  resolvedPatternId: resolvedPatternId,
  snoozeUntil: snoozeUntil,
);

/// 服务端 `SuggestionEditableFields` 的典型下发值
/// （`workers/habit/timeline_events.go:52`）。
const kEditableFields = [
  'topic_key',
  'trigger_config',
  'preferred_agent_id',
  'delivery_group_id',
];

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

    testWidgets('已处理 + 注入 onUnresolve 时渲染撤销入口', (tester) async {
      final unresolved = <String>[];
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              suggestionId: 'sugg-9',
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.dismissed,
            ),
            onUnresolve: () => unresolved.add('sugg-9'),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-unresolve-sugg-9')));
      expect(unresolved, ['sugg-9']);
    });

    testWidgets('未注入 onUnresolve 时不渲染撤销入口', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              suggestionId: 'sugg-9',
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.dismissed,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('habit-unresolve-sugg-9')),
        findsNothing,
      );
    });

    testWidgets('未处理时**不**渲染撤销入口（服务端 CAS 必然 409）', (tester) async {
      // `UnresolveHabitRunFeedback` 的 WHERE 带 `user_feedback IS NOT NULL`，
      // 对未处理的建议提交必然命中 0 行 → 409。故入口不应出现。
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(suggestionId: 'sugg-9', triggerConfig: timeCfg()),
            onAccept: () {},
            onUnresolve: () {},
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('habit-unresolve-sugg-9')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('habit-accept')), findsOneWidget);
    });

    testWidgets('busy 时撤销按钮禁用', (tester) async {
      var unresolved = 0;
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              suggestionId: 'sugg-9',
              triggerConfig: timeCfg(),
              userFeedback: HabitUserFeedback.dismissed,
            ),
            busy: true,
            onUnresolve: () => unresolved++,
          ),
        ),
      );

      final btn = tester.widget<TextButton>(
        find.byKey(const ValueKey('habit-unresolve-sugg-9')),
      );
      expect(btn.onPressed, isNull);

      await tester.tap(
        find.byKey(const ValueKey('habit-unresolve-sugg-9')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(unresolved, 0);
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

  group('习惯建议卡：「编辑并接受」入口', () {
    testWidgets('canEdit=false（editableFields 为空）时**没有**编辑入口', (tester) async {
      // ## 为什么是隐藏而不是禁用
      //
      // 服务端没给可编辑字段时，对话框会是一个**空白表单**，提交出的 patch 是
      // `{}`——与「直接接受」等价但多一次无效往返。一个灰按钮只会让用户
      // 反复点击试探。
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const [],
            ),
            onEditAndAccept: (_) {},
          ),
        ),
      );

      expect(find.byKey(const ValueKey('habit-edit-and-accept')), findsNothing);
      expect(find.text('编辑并接受'), findsNothing);
    });

    testWidgets('canEdit=true 且注入了回调时才渲染编辑入口', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
            onEditAndAccept: (_) {},
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('habit-edit-and-accept')),
        findsOneWidget,
      );
    });

    testWidgets('canEdit=true 但未注入回调时也不渲染（点了没反应不如不显示）', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('habit-edit-and-accept')), findsNothing);
    });

    testWidgets('已处理（resolved）的卡片不再渲染编辑入口', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
              userFeedback: HabitUserFeedback.accepted,
              resolvedPatternId: 'hp-1',
            ),
            onEditAndAccept: (_) {},
          ),
        ),
      );

      expect(find.byKey(const ValueKey('habit-edit-and-accept')), findsNothing);
      expect(find.textContaining('已采纳'), findsOneWidget);
    });

    testWidgets('点入口弹出编辑器，而不是直接发空 patch', (tester) async {
      final patches = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
            onEditAndAccept: patches.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-edit-and-accept')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-suggestion-editor')),
        findsOneWidget,
      );
      expect(patches, isEmpty, reason: '打开对话框不应直接提交——用户还没改任何东西');
    });

    testWidgets('取消对话框不发请求', (tester) async {
      final patches = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
            onEditAndAccept: patches.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-edit-and-accept')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-edit-cancel')));
      await tester.pumpAndSettle();

      expect(patches, isEmpty);
      expect(
        find.byKey(const ValueKey('habit-suggestion-editor')),
        findsNothing,
      );
    });

    testWidgets('确认后把 patch 交给回调（action 由装配层决定）', (tester) async {
      final patches = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _host(
          HabitSuggestionCard(
            suggestion: item(
              topicKey: 'weekly-report',
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
            onEditAndAccept: patches.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('habit-edit-and-accept')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-topic-key')),
        'weekly-report-v2',
      );
      await tester.tap(find.byKey(const ValueKey('habit-edit-submit')));
      await tester.pumpAndSettle();

      expect(patches, hasLength(1));
      expect(patches.single['topic_key'], 'weekly-report-v2');
      // 未改的触发配置仍按 editableFields 提交（不是「只发改过的」）——
      // 因为对话框的初始值就是候选值，提交它等于「保持原值」。
      expect(patches.single['trigger_config'], isA<Map<String, dynamic>>());
    });
  });

  group('习惯建议编辑器：字段由 editableFields 决定', () {
    testWidgets('editableFields 只含 topic_key 时只渲染主题输入', (tester) async {
      // ## 这个测试防的是什么
      //
      // `applyPatternPatch` 对**不认识**的键静默忽略（不报错），所以客户端多带
      // 一个键不会失败，只会得到「保存成功但配置没变」。故字段集必须由服务端
      // 下发的 editable_fields 决定，不能写死。
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['topic_key'],
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('habit-edit-topic-key')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('habit-edit-hour')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-minute')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-weekday-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-agent-id')), findsNothing);
    });

    testWidgets('editableFields 只含 trigger_config 时只渲染时间/星期', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['trigger_config'],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('habit-edit-topic-key')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-hour')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-edit-minute')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('habit-edit-weekday-1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('habit-edit-agent-id')), findsNothing);
    });

    testWidgets('editableFields 含 preferred_agent_id 时渲染 Agent 输入', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['preferred_agent_id'],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('habit-edit-agent-id')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-edit-topic-key')), findsNothing);
    });

    testWidgets('delivery_group_id 在白名单里但本编辑器不渲染（不放进 patch 即保留原值）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['delivery_group_id'],
            ),
          ),
        ),
      );

      // 没有任何可渲染的字段——但不崩。
      expect(find.byKey(const ValueKey('habit-edit-topic-key')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-hour')), findsNothing);
      expect(find.byKey(const ValueKey('habit-edit-agent-id')), findsNothing);
      expect(
        find.byKey(const ValueKey('habit-suggestion-editor')),
        findsOneWidget,
      );
    });

    testWidgets('提交的 patch 只含 editableFields 里的键（不自行扩大字段集）', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              topicKey: 'weekly-report',
              triggerConfig: timeCfg(),
              editableFields: const ['topic_key', 'preferred_agent_id'],
            ),
          ),
        ),
      );
      final state = tester.state<State<HabitSuggestionEditor>>(
        find.byType(HabitSuggestionEditor),
      );

      final patch = (state as dynamic).buildPatch() as Map<String, dynamic>;

      expect(patch.keys.toSet(), {'topic_key', 'preferred_agent_id'});
      expect(
        patch.containsKey('trigger_config'),
        isFalse,
        reason: 'trigger_config 不在 editableFields 里，不得下发（服务端会静默忽略）',
      );
    });

    testWidgets('watch 候选不渲染时间输入，改为只读节奏说明', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerType: HabitTriggerType.watch,
              triggerConfig: watchCfg(),
              editableFields: kEditableFields,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('habit-edit-watch-readonly')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('habit-edit-hour')),
        findsNothing,
        reason: 'watch 没有钟点，渲染时刻输入会把它重建为钟点任务',
      );
    });

    testWidgets('watch 候选提交时原样回传 trigger_config + trigger_type=watch', (
      tester,
    ) async {
      // 缺 trigger_type 会让服务端按 time_based 重建出一条「每周一 09:00」的
      // 钟点任务，与用户意图相反。
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerType: HabitTriggerType.watch,
              triggerConfig: watchCfg(),
              editableFields: const ['trigger_config'],
            ),
          ),
        ),
      );
      final state = tester.state<State<HabitSuggestionEditor>>(
        find.byType(HabitSuggestionEditor),
      );

      final patch = (state as dynamic).buildPatch() as Map<String, dynamic>;
      final cfg = patch['trigger_config'] as Map<String, dynamic>;

      expect(cfg['trigger_type'], 'watch');
      expect(cfg.containsKey('cadence'), isTrue, reason: '候选节奏必须原样带上');
      expect(cfg.containsKey('times'), isFalse);
    });

    testWidgets('时间型提交的 trigger_config 用 times 数组 + 1-based weekday', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['trigger_config'],
            ),
          ),
        ),
      );
      final state = tester.state<State<HabitSuggestionEditor>>(
        find.byType(HabitSuggestionEditor),
      );

      final patch = (state as dynamic).buildPatch() as Map<String, dynamic>;
      final cfg = patch['trigger_config'] as Map<String, dynamic>;

      expect(cfg['times'], [
        {'hour': 9, 'minute': 0},
      ]);
      expect(cfg['weekday'], [1]);
      // 用 weekday（单数）而非 weekdays：服务端两种都认，但单数是 pattern 与
      // 引擎的统一口径（applyPatternPatch 的注释）。
      expect(cfg.containsKey('weekdays'), isFalse);
    });

    testWidgets('preferred_agent_id 清空时发 null（不是空串）', (tester) async {
      // 服务端把 null 解释为「清除指定 agent」。发空串虽然最终效果相同，
      // 但 null 是 webapp 的既有形态，且语义更明确。
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['preferred_agent_id'],
              preferredAgentId: 'agent_old',
            ),
          ),
        ),
      );
      final state = tester.state<State<HabitSuggestionEditor>>(
        find.byType(HabitSuggestionEditor),
      );

      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-agent-id')),
        '',
      );
      final patch = (state as dynamic).buildPatch() as Map<String, dynamic>;

      expect(patch.containsKey('preferred_agent_id'), isTrue);
      expect(patch['preferred_agent_id'], isNull);
    });

    testWidgets('取消全部星期时阻止提交并说明原因', (tester) async {
      // 空数组会被服务端当成「无该键」而保留候选值——静默忽略用户操作。
      // 故这里阻止提交，而不是像 webapp 那样静默回填成 [1]（那会在候选本是
      // 周三时把规则悄悄改成周一）。
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['trigger_config'],
            ),
          ),
        ),
      );

      // 初始是 [1]（候选值），先点掉它。
      await tester.tap(find.byKey(const ValueKey('habit-edit-weekday-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('habit-edit-weekday-error')),
        findsOneWidget,
      );
      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('habit-edit-submit')),
      );
      expect(submit.onPressed, isNull);
    });

    testWidgets('canEdit=false 时提交按钮禁用（没有可提交的内容）', (tester) async {
      // 卡片已经不会渲染入口，但对话框本身也不应允许提交一个 `{}`。
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const [],
            ),
          ),
        ),
      );

      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('habit-edit-submit')),
      );
      expect(submit.onPressed, isNull);
    });

    testWidgets('busy 时输入与按钮全禁用', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: kEditableFields,
            ),
            busy: true,
          ),
        ),
      );

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('habit-edit-topic-key')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('habit-edit-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('habit-edit-cancel')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('小时/分钟越界时被夹到合法范围', (tester) async {
      await tester.pumpWidget(
        _host(
          HabitSuggestionEditor(
            suggestion: item(
              triggerConfig: timeCfg(),
              editableFields: const ['trigger_config'],
            ),
          ),
        ),
      );
      final state = tester.state<State<HabitSuggestionEditor>>(
        find.byType(HabitSuggestionEditor),
      );

      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-hour')),
        '99',
      );
      await tester.enterText(
        find.byKey(const ValueKey('habit-edit-minute')),
        '99',
      );
      final patch = (state as dynamic).buildPatch() as Map<String, dynamic>;
      final cfg = patch['trigger_config'] as Map<String, dynamic>;

      expect(cfg['times'], [
        {'hour': 23, 'minute': 59},
      ]);
    });
  });
}
