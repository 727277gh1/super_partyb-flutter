import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 习惯**洞察**（`habit-insights/summary`）与 `HabitRunOutcome.isTerminal` 测试。
///
/// ## 为什么需要它
///
/// `habit_run.dart` 的 `HabitInsightsSummary` 一族（suggestions / dueRules /
/// signalCoverage 及其嵌套分桶）此前**零覆盖**——它们的 `fromJson` 走的是
/// `habitMap` / `habitInt` / `habitDouble` 这套「camelCase 与 snake_case 双读」
/// 的辅助函数，字段名漂移时静默回落到 0，只在界面上表现为「统计全是 0」。
///
/// ## 两个必须钉住的语义
///
/// 1. **`byWeekday` 的 key 用 Go 的 `time.Weekday()`（0=周日）**，不是 1=周一。
///    按 ISO 周几渲染会整体错位一天。
/// 2. **`recalibration` 在 Go 版恒为 0**（服务端不产出
///    `habit_pattern_recalibrated` 事件）——解析正确但不该被渲染成「从未重校准」。
void main() {
  group('HabitRunOutcome.isTerminal', () {
    test('只有 completed / failed / cancelled 是终态', () {
      const terminal = [
        HabitRunOutcome.completed,
        HabitRunOutcome.failed,
        HabitRunOutcome.cancelled,
      ];
      for (final o in terminal) {
        expect(o.isTerminal, isTrue, reason: '${o.wire} 应为终态');
      }
      // pending/suggested/scheduled/confirmationRequired 还会变化；
      // 两个 skipped_* 是「跳过」，但服务端语义上也不是完成——保持与实现一致。
      for (final o in [
        HabitRunOutcome.pending,
        HabitRunOutcome.suggested,
        HabitRunOutcome.scheduled,
        HabitRunOutcome.confirmationRequired,
        HabitRunOutcome.skippedNoSuggestionService,
        HabitRunOutcome.skippedPendingExists,
        HabitRunOutcome.unknown,
      ]) {
        expect(o.isTerminal, isFalse, reason: '${o.wire} 不应是终态');
      }
    });

    test('from：未知 / null / 空串落到 unknown（不抛）', () {
      expect(HabitRunOutcome.from('brand_new'), HabitRunOutcome.unknown);
      expect(HabitRunOutcome.from(null), HabitRunOutcome.unknown);
      expect(HabitRunOutcome.from(''), HabitRunOutcome.unknown);
      expect(HabitRunOutcome.from('completed'), HabitRunOutcome.completed);
    });
  });

  group('HabitInsightsSummary（snake_case 嵌套 gin.H）', () {
    /// `habit_insights.go` 的 `summary` 真实形状。
    Map<String, dynamic> summaryJson({
      Object? window = const {
        'days': 30,
        'start_at': '2024-03-01T00:00:00Z',
        'end_at': '2024-03-31T00:00:00Z',
      },
      Object? suggestions,
      Object? dueRules,
      Object? signalCoverage,
    }) => {
      if (window != null) 'window': window,
      if (suggestions != null) 'suggestions': suggestions,
      if (dueRules != null) 'due_rules': dueRules,
      if (signalCoverage != null) 'signal_coverage': signalCoverage,
    };

    test('window 解析（days / start_at / end_at）', () {
      final s = HabitInsightsSummary.fromJson(summaryJson());
      expect(s.days, 30);
      expect(s.startAt, DateTime.parse('2024-03-01T00:00:00Z').toLocal());
      expect(s.endAt, DateTime.parse('2024-03-31T00:00:00Z').toLocal());
    });

    test('window 缺失 → days=0，时间为 null（不抛）', () {
      final s = HabitInsightsSummary.fromJson(summaryJson(window: null));
      expect(s.days, 0);
      expect(s.startAt, isNull);
      expect(s.endAt, isNull);
    });

    test('三个嵌套块各自可选（缺失 → null）', () {
      final s = HabitInsightsSummary.fromJson(summaryJson());
      expect(s.suggestions, isNull);
      expect(s.dueRules, isNull);
      expect(s.signalCoverage, isNull);

      final full = HabitInsightsSummary.fromJson(
        summaryJson(
          suggestions: const {'created_count': 3},
          dueRules: const {'trigger_count': 5},
          signalCoverage: const {'user_message_count': 10},
        ),
      );
      expect(full.suggestions?.createdCount, 3);
      expect(full.dueRules?.triggerCount, 5);
      expect(full.signalCoverage?.userMessageCount, 10);
    });

    test('嵌套块非 Map 时归一成 null（不抛）', () {
      final s = HabitInsightsSummary.fromJson(
        summaryJson(suggestions: 'x', dueRules: 42),
      );
      expect(s.suggestions, isNull);
      expect(s.dueRules, isNull);
    });

    test('raw 是不可修改的（Map.unmodifiable）', () {
      final s = HabitInsightsSummary.fromJson(summaryJson());
      expect(() => s.raw['x'] = 1, throwsUnsupportedError);
    });
  });

  group('HabitSuggestionInsights（feedback_counts 展开）', () {
    test('顶层计数 + feedback_counts 四个键', () {
      final s = HabitSuggestionInsights.fromJson(const {
        'created_count': 10,
        'accept_rate': 0.4,
        'feedback_counts': {
          'accepted': 4,
          'dismissed': 3,
          'snoozed': 2,
          'pending': 1,
        },
      });
      expect(s.createdCount, 10);
      expect(s.acceptRate, 0.4);
      expect(s.acceptedCount, 4);
      expect(s.dismissedCount, 3);
      expect(s.snoozedCount, 2);
      expect(s.pendingCount, 1);
    });

    test('by_topic / by_hour / by_weekday 列表解析', () {
      final s = HabitSuggestionInsights.fromJson(const {
        'by_topic': [
          {'topic_key': 't1', 'created_count': 3, 'accepted_count': 1},
        ],
        'by_hour': [
          {'hour': 9, 'created_count': 5},
        ],
        'by_weekday': [
          // ⚠️ 0=周日（Go time.Weekday），不是 1=周一。
          {'weekday': 0, 'created_count': 7},
        ],
      });
      expect(s.byTopic, hasLength(1));
      expect(s.byTopic.first.topicKey, 't1');
      expect(s.byHour.first.key, 9);
      expect(s.byWeekday.first.key, 0, reason: '0 表示周日（Go 口径）');
      expect(s.byWeekday.first.count, 7);
    });

    test('缺字段全回落 0 / 空列表', () {
      final s = HabitSuggestionInsights.fromJson(const {});
      expect(s.createdCount, 0);
      expect(s.acceptRate, 0);
      expect(s.byTopic, isEmpty);
      expect(s.byWeekday, isEmpty);
    });
  });

  group('HabitTopicMetrics', () {
    test('字段解析（含负反馈计数与比率）', () {
      final m = HabitTopicMetrics.fromJson(const {
        'topic_key': 'daily_standup',
        'created_count': 5,
        'accepted_count': 2,
        'dismissed_count': 1,
        'snoozed_count': 1,
        'pending_count': 1,
        'blocking_feedback_count': 2,
        'blocking_feedback_rate': 0.4,
      });
      expect(m.topicKey, 'daily_standup');
      expect(m.createdCount, 5);
      expect(m.blockingFeedbackCount, 2);
      expect(m.blockingFeedbackRate, 0.4);
    });

    test('topic_key 缺失回落 "unknown"（不是空串）', () {
      // 空串会让 UI 渲染出一个没有名字的分组。
      expect(HabitTopicMetrics.fromJson(const {}).topicKey, 'unknown');
    });
  });

  group('HabitCountBucket：hour 与 weekday 二选一', () {
    test('有 hour 用 hour，否则用 weekday', () {
      expect(
        HabitCountBucket.fromJson(const {'hour': 9, 'created_count': 3}).key,
        9,
      );
      expect(
        HabitCountBucket.fromJson(const {'weekday': 6, 'created_count': 2}).key,
        6,
      );
      // 两者都缺 → 0（不抛）。
      expect(HabitCountBucket.fromJson(const {}).key, 0);
    });

    test('hour 优先于 weekday（同一条目不应两者都有）', () {
      expect(HabitCountBucket.fromJson(const {'hour': 9, 'weekday': 3}).key, 9);
    });
  });

  group('HabitDueRuleInsights（continued_interaction / recalibration）', () {
    test('嵌套展开', () {
      final d = HabitDueRuleInsights.fromJson(const {
        'trigger_count': 20,
        'reward_count': 15,
        'continued_interaction': {
          'total_runs': 10,
          'continued_runs': 6,
          'continued_rate': 0.6,
        },
        'recalibration': {
          'total_count': 0,
          'reason_counts': {'acceptance_feedback': 0, 'blocking_feedback': 0},
        },
        'by_user_day': [
          {'user_id': 'u1', 'date': '2024-03-01', 'trigger_count': 3},
        ],
        'by_group_day': [
          {'group_id': 'g1', 'date': '2024-03-01', 'trigger_count': 2},
        ],
      });
      expect(d.triggerCount, 20);
      expect(d.rewardCount, 15);
      expect(d.totalRuns, 10);
      expect(d.continuedRuns, 6);
      expect(d.continuedRate, 0.6);
      expect(d.recalibrationTotal, 0);
      expect(d.byUserDay.first.userId, 'u1');
      expect(d.byUserDay.first.date, '2024-03-01');
      expect(d.byGroupDay.first.groupId, 'g1');
      expect(d.byGroupDay.first.triggerCount, 2);
    });

    test('缺嵌套块时全回落 0 / 空列表（不抛）', () {
      final d = HabitDueRuleInsights.fromJson(const {});
      expect(d.triggerCount, 0);
      expect(d.totalRuns, 0);
      expect(d.recalibrationTotal, 0);
      expect(d.byUserDay, isEmpty);
      expect(d.byGroupDay, isEmpty);
    });

    test('recalibration 恒为 0 是**服务端现状**，解析本身正确', () {
      // Go 侧不产出 habit_pattern_recalibrated 事件 → 恒 0。
      // 这里确认「服务端给了非零值时能读出来」，从而区分「解析错」与「服务端没产」。
      final d = HabitDueRuleInsights.fromJson(const {
        'recalibration': {
          'total_count': 7,
          'reason_counts': {'acceptance_feedback': 3, 'blocking_feedback': 4},
        },
      });
      expect(d.recalibrationTotal, 7);
      expect(d.recalibrationAcceptanceFeedback, 3);
      expect(d.recalibrationBlockingFeedback, 4);
    });
  });

  group('HabitSignalCoverage', () {
    test('字段解析', () {
      final c = HabitSignalCoverage.fromJson(const {
        'user_message_count': 100,
        'routing_selected_count': 80,
        'coverage_rate': 0.8,
      });
      expect(c.userMessageCount, 100);
      expect(c.routingSelectedCount, 80);
      expect(c.coverageRate, 0.8);
    });

    test('缺字段回落 0', () {
      final c = HabitSignalCoverage.fromJson(const {});
      expect(c.userMessageCount, 0);
      expect(c.coverageRate, 0);
    });
  });

  group('HabitDayCount / HabitGroupDayCount', () {
    test('缺字段回落空串 / 0', () {
      final u = HabitDayCount.fromJson(const {});
      expect(u.userId, '');
      expect(u.date, '');
      expect(u.triggerCount, 0);

      final g = HabitGroupDayCount.fromJson(const {});
      expect(g.groupId, '');
      expect(g.date, '');
      expect(g.triggerCount, 0);
    });
  });
}
