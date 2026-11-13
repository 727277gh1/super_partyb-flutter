/// 习惯页 的共享夹具（issue #48 从 `habits_page_test.dart` 抽出）。
///
/// ⚠️ 文件私有的 `_Xxx` 移到共享库后必须去掉下划线（跨库不可见），
/// 故拆分时引用它们的调用点同步改名（纯重命名，无行为变化）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
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
  String triggerConfigJson = '{"weekday":[1],"times":[{"hour":9,"minute":0}]}',
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
    'by_topic': const <dynamic>[],
    'by_hour': const <dynamic>[],
    'by_weekday': const <dynamic>[],
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
    'by_user_day': const <dynamic>[],
    'by_group_day': const <dynamic>[],
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
HabitRunsResult runsResult({List<HabitRun>? items, HabitDailyBudget? daily}) =>
    HabitRunsResult(items: items ?? const <HabitRun>[], dailyBudget: daily);

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
