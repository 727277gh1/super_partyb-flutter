import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 习惯管理页的行为测试。
///
/// ## 这个测试防的是什么
///
/// 服务端的规则状态机是**单向且部分可用**的（`habits_full.go`）：
/// - `trigger` / `pause` 仅 `active`；
/// - `resume` 仅 `paused`；
/// - `archive` 是**终态**（无 unarchive）。
///
/// 页面若按「有按钮就显示」渲染，用户会看到点了必然 409 的按钮；若归档不确认，
/// 误点后无法撤销。故这里逐条钉住「什么状态下显示哪些按钮」与「归档需确认」。
void main() {
  /// UTC RFC3339（无毫秒）——服务端 `created_at` 的形态。
  String isoUtc(DateTime t) {
    final u = t.toUtc();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${p2(u.month)}-${p2(u.day)}'
        'T${p2(u.hour)}:${p2(u.minute)}:${p2(u.second)}Z';
  }

  /// 造一条规则。
  UserHabit habit({
    String id = 'hp-1',
    String topicKey = 'weekly-report',
    HabitPatternStatus status = HabitPatternStatus.active,
    HabitAcceptanceLevel level = HabitAcceptanceLevel.suggestOnly,
    HabitSourceType source = HabitSourceType.manual,
    int triggerCount = 3,
    DateTime? nextFireAt,
    HabitTriggerType triggerType = HabitTriggerType.timeBased,
    String triggerConfigJson =
        '{"weekday":[1],"times":[{"hour":9,"minute":0}]}',
  }) => UserHabit.fromJson({
    'id': id,
    'userId': 'usr-1',
    'originGroupId': 'grp-1',
    'topicKey': topicKey,
    'triggerType': triggerType.wire,
    'triggerConfigJson': triggerConfigJson,
    'acceptanceLevel': level.wire,
    'sourceType': source.wire,
    'status': status.wire,
    'triggerCount': triggerCount,
    'confidence': 0.5,
    'nextFireAt': nextFireAt == null
        ? {'Time': '0001-01-01T00:00:00Z', 'Valid': false}
        : {'Time': nextFireAt.toIso8601String(), 'Valid': true},
  });

  /// 造一条执行记录（`habitRunsWithReply` 形状）。
  ///
  /// `createdAt` 默认为「一天前」而不是写死日期：单规则页的时间窗筛选是
  /// **本地**的（[applyHabitRunsFilter]），写死日期会让用例在 30 天后
  /// 静默失效（记录落到默认时间窗外，断言变空）。
  HabitRun run({
    String id = 'run-1',
    String topicKey = 'weekly-report',
    String? deliveryGroupId = 'grp-1',
    String? turnId = 'turn-9',
    HabitRunOutcome outcome = HabitRunOutcome.completed,
    HabitTriggerReason reason = HabitTriggerReason.dueRule,
    String replyText = '已生成周报草稿。',
    bool isManual = false,
    HabitUserFeedback? feedback,
    DateTime? createdAt,
  }) => HabitRun.fromJson({
    'run_id': id,
    'pattern_id': 'hp-1',
    'topic_key': topicKey,
    'trigger_reason': reason.wire,
    'outcome': outcome.wire,
    'created_at': isoUtc(
      createdAt ?? DateTime.now().toUtc().subtract(const Duration(days: 1)),
    ),
    'delivery_group_id': deliveryGroupId,
    'delivery_group_title': '团队周报',
    'turn_id': turnId,
    'reply_text': replyText,
    'is_manual': isManual,
    'user_feedback': feedback?.wire,
  });

  /// 造一条建议（`habitRunToMap` 形状，即列表端点返回的）。
  HabitSuggestion suggestion({
    String id = 'sugg-1',
    String topicKey = 'weekly-report',
    String? feedback,
    Map<String, dynamic>? feedbackPayload,
    String triggerContextJson =
        '{"topic_key":"weekly-report","hour":9,"reasons":["每周一你都会让我写周报"]}',
  }) => HabitSuggestion.fromListItem({
    'id': id,
    'user_id': 'usr-1',
    'origin_group_id': 'grp-1',
    'trigger_reason': 'candidate_detected',
    'outcome': 'suggested',
    'trigger_context_json': triggerContextJson,
    'user_feedback': feedback,
    'feedback_payload': feedbackPayload,
    'created_at': '2026-10-04T01:30:00Z',
  });

  /// 造一份洞察摘要（`habit_insights.go` 的 gin.H 形状）。
  HabitInsightsSummary insights({
    int days = 30,
    int created = 4,
    double acceptRate = 0.5,
    int accepted = 2,
    int dismissed = 1,
    int snoozed = 1,
    int pending = 0,
    int triggerCount = 6,
    int continuedRuns = 3,
    int recalibrationTotal = 0,
  }) => HabitInsightsSummary.fromJson({
    'window': {
      'days': days,
      'start_at': '2026-09-04T00:00:00Z',
      'end_at': '2026-10-04T00:00:00Z',
    },
    'suggestions': {
      'created_count': created,
      'accept_rate': acceptRate,
      'feedback_counts': {
        'accepted': accepted,
        'dismissed': dismissed,
        'snoozed': snoozed,
        'pending': pending,
      },
      'by_topic': const [],
      'by_hour': const [],
      'by_weekday': const [],
    },
    'due_rules': {
      'trigger_count': triggerCount,
      'reward_count': 0,
      'continued_interaction': {
        'total_runs': triggerCount,
        'continued_runs': continuedRuns,
        'continued_rate': 0.5,
      },
      'recalibration': {
        'total_count': recalibrationTotal,
        'reason_counts': {'acceptance_feedback': 0, 'blocking_feedback': 0},
      },
      'by_user_day': const [],
      'by_group_day': const [],
    },
    'signal_coverage': {
      'user_message_count': 10,
      'routing_selected_count': 4,
      'coverage_rate': 0.4,
    },
  });

  /// 造一份今日预算（`daily_budget`）。
  HabitDailyBudget budget({int limit = 20, int usedToday = 3}) =>
      HabitDailyBudget(limit: limit, usedToday: usedToday);

  /// 造一份 `GET /api/habits/runs` 的完整响应。
  HabitRunsResult runsResult({
    List<HabitRun>? items,
    HabitDailyBudget? daily,
  }) => HabitRunsResult(items: items ?? const <HabitRun>[], dailyBudget: daily);

  Widget host({
    List<UserHabit>? habits,
    List<HabitRun>? runs,
    HabitDailyBudget? dailyBudget,
    Future<List<UserHabit>> Function()? loadHabits,
    Future<List<HabitRun>> Function()? loadRuns,
    LoadHabitRunsHistory? loadRunsHistory,
    Future<void> Function(UserHabit)? onTrigger,
    Future<void> Function(UserHabit)? onPause,
    Future<void> Function(UserHabit)? onResume,
    Future<void> Function(UserHabit)? onArchive,
    Future<String> Function(HabitDraft)? onCreate,
    EditHabit? onEdit,
    LoadHabitRuns? loadHabitRuns,
    void Function(String, String)? onOpenTurn,
    Object? error,
    // ---------- 建议收件箱 ----------
    List<HabitSuggestion>? suggestions,
    Future<List<HabitSuggestion>> Function(HabitSuggestionListFilter)?
    loadSuggestions,
    ResolveHabitSuggestion? resolveSuggestion,
    UnresolveHabitSuggestion? unresolveSuggestion,
    // ---------- 洞察 ----------
    HabitInsightsSummary? insightsSummary,
    LoadHabitInsights? loadInsights,
    Object? insightsError,
  }) => MaterialApp(
    home: HabitsPage(
      loadHabits:
          loadHabits ??
          () async {
            if (error != null) throw error;
            return habits ?? const [];
          },
      loadRuns:
          loadRunsHistory ??
          (filter) async {
            if (error != null) throw error;
            // 旧用例只关心「列表内容」，这里把裸列表包成完整响应。
            final list = loadRuns != null
                ? await loadRuns()
                : (runs ?? const <HabitRun>[]);
            return runsResult(items: list, daily: dailyBudget);
          },
      groupTitleOf: (gid) => gid == 'grp-1' ? '团队周报' : null,
      onTrigger: onTrigger,
      onPause: onPause,
      onResume: onResume,
      onArchive: onArchive,
      onCreate: onCreate,
      onEdit: onEdit,
      loadHabitRuns: loadHabitRuns,
      onOpenTurn: onOpenTurn,
      loadSuggestions: loadSuggestions,
      resolveSuggestion: resolveSuggestion,
      unresolveSuggestion: unresolveSuggestion,
      loadInsights: loadInsights,
    ),
  );

  /// 注入了建议回调的 host（三个 Tab）。默认建议列表为空。
  Widget suggestionsHost({
    List<HabitSuggestion>? items,
    Future<List<HabitSuggestion>> Function(HabitSuggestionListFilter)?
    loadSuggestions,
    ResolveHabitSuggestion? resolveSuggestion,
    UnresolveHabitSuggestion? unresolveSuggestion,
  }) => host(
    habits: const [],
    runs: const [],
    loadSuggestions:
        loadSuggestions ?? (_) async => items ?? const <HabitSuggestion>[],
    resolveSuggestion: resolveSuggestion,
    unresolveSuggestion: unresolveSuggestion,
  );

  group('规则列表', () {
    testWidgets('渲染主题、触发节奏与元信息', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      // topic_key 是机器键，换分隔符展示（不编造中文名）。
      expect(find.text('weekly report'), findsOneWidget);
      // time_based 形状按 times/weekday 渲染。
      expect(find.textContaining('每周一'), findsOneWidget);
      expect(find.textContaining('09:00'), findsOneWidget);
      expect(find.textContaining('已执行 3 次'), findsOneWidget);
      // 接受级别与来源拼在同一行（一个 Text），故用 textContaining。
      expect(find.textContaining('仅建议'), findsOneWidget);
      expect(find.textContaining('手动创建'), findsOneWidget);
    });

    testWidgets('空列表显示空态（而不是空白页）', (tester) async {
      await tester.pumpWidget(host(habits: const []));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没有习惯'), findsOneWidget);
    });
  });

  group('状态机：只显示当前状态可用的按钮', () {
    testWidgets('active：显示立即执行 + 暂停 + 归档，不显示恢复', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsOneWidget);
      // 服务端 resume 仅接受 paused；对 active 显示它是「点了必然 409」。
      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsNothing);
    });

    testWidgets('paused：只显示恢复（trigger/pause 都会 409）', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit(status: HabitPatternStatus.paused)],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
    });

    testWidgets('archived：只剩「归档」以外的操作全部消失', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit(status: HabitPatternStatus.archived)],
          onTrigger: (_) async {},
          onPause: (_) async {},
          onResume: (_) async {},
          onArchive: (_) async {},
        ),
      );
      await tester.pumpAndSettle();

      // 归档是终态：不再显示归档按钮（避免重复归档）。
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-resume-hp-1')), findsNothing);
    });

    testWidgets('未注入回调时不显示任何操作按钮（只读展示）', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-trigger-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-pause-hp-1')), findsNothing);
      expect(find.byKey(const ValueKey('habit-archive-hp-1')), findsNothing);
    });
  });

  group('操作回调', () {
    testWidgets('点「立即执行」传出该规则', (tester) async {
      final seen = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onTrigger: (h) async => seen.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-trigger-hp-1')));
      await tester.pumpAndSettle();

      expect(seen.single.id, 'hp-1');
    });

    testWidgets('点「暂停」传出该规则', (tester) async {
      final seen = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onPause: (h) async => seen.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-pause-hp-1')));
      await tester.pumpAndSettle();

      expect(seen.single.id, 'hp-1');
    });

    testWidgets('归档必须先确认；取消则不调用', (tester) async {
      final archived = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onArchive: (h) async => archived.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-archive-hp-1')));
      await tester.pumpAndSettle();

      // 归档是终态，必须先说明不可撤销。
      expect(find.textContaining('无法恢复'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(archived, isEmpty, reason: '取消不应触发归档');
    });

    testWidgets('归档确认后调用回调', (tester) async {
      final archived = <UserHabit>[];
      await tester.pumpWidget(
        host(habits: [habit()], onArchive: (h) async => archived.add(h)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-archive-hp-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('habit-archive-confirm')));
      await tester.pumpAndSettle();

      expect(archived.single.id, 'hp-1');
    });

    testWidgets('409（状态不符）弹提示并说明原因，而非静默失败', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onTrigger: (_) async =>
              throw const HttpError(409, '仅 active 状态可触发，当前: paused'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-trigger-hp-1')));
      await tester.pumpAndSettle();

      // 用户必须知道「是状态变了」而不是「客户端坏了」。
      expect(find.textContaining('仅 active 状态可触发'), findsOneWidget);
    });
  });

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

  group('新建规则', () {
    testWidgets('未注入 onCreate 时不显示新建入口', (tester) async {
      await tester.pumpWidget(host(habits: const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habits-create')), findsNothing);
    });

    testWidgets('对话框收集主题/执行方式/时间/重复，产出 draft', (tester) async {
      final drafts = <HabitDraft>[];
      await tester.pumpWidget(
        host(
          habits: const [],
          onCreate: (d) async {
            drafts.add(d);
            return 'hp-new';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('habit-editor-topic')),
        'preference.coffee',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('habit-editor-level-auto_run')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-editor-weekday-1')));
      await tester.tap(find.byKey(const ValueKey('habit-editor-weekday-3')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-editor-save')));
      await tester.pumpAndSettle();

      expect(drafts, hasLength(1));
      final d = drafts.single;
      expect(d.topicKey, 'preference.coffee');
      expect(d.acceptanceLevel, HabitAcceptanceLevel.autoRun);
      // 默认 9:00（与 webapp HabitPatternEditor 一致）。
      expect(d.triggerConfig!.time!.firstHour, 9);
      expect(d.triggerConfig!.time!.weekdays, [1, 3]);
    });

    testWidgets('主题为空时「创建」禁用', (tester) async {
      await tester.pumpWidget(
        host(habits: const [], onCreate: (_) async => ''),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('habit-editor-save')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('取消对话框不调用 onCreate', (tester) async {
      var created = 0;
      await tester.pumpWidget(
        host(
          habits: const [],
          onCreate: (_) async {
            created++;
            return '';
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(created, 0);
    });
  });

  group('加载失败', () {
    testWidgets('显示错误与重试按钮', (tester) async {
      await tester.pumpWidget(host(error: const NetworkError('连接失败')));
      await tester.pumpAndSettle();

      expect(find.text('连接失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('habits-retry')), findsOneWidget);
    });

    testWidgets('点重试会重新拉取', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          loadHabits: () async {
            calls++;
            if (calls == 1) throw const NetworkError('连接失败');
            return [habit()];
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habits-retry')));
      await tester.pumpAndSettle();

      expect(calls, greaterThan(1));
      expect(find.text('weekly report'), findsOneWidget);
    });
  });

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

  group('规则菜单：编辑与执行记录入口', () {
    testWidgets('未注入 onEdit / loadHabitRuns 时没有溢出菜单', (tester) async {
      await tester.pumpWidget(host(habits: [habit()]));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-menu-hp-1')), findsNothing);
    });

    testWidgets('注入后菜单里有「编辑」与「执行记录」', (tester) async {
      await tester.pumpWidget(
        host(
          habits: [habit()],
          onEdit: (h, patch) async {},
          loadHabitRuns: (_) async => const [],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-runs')), findsOneWidget);
    });

    testWidgets('只注入 onEdit 时菜单里只有「编辑」', (tester) async {
      await tester.pumpWidget(
        host(habits: [habit()], onEdit: (h, patch) async {}),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('habit-menu-hp-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('habit-edit')), findsOneWidget);
      expect(find.byKey(const ValueKey('habit-runs')), findsNothing);
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
