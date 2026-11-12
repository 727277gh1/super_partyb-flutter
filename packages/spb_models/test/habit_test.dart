import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 习惯（habit）契约的解析测试。
///
/// ## 这个测试防的是什么
///
/// 习惯是本仓库唯一**双形态命名**最严重的领域：
///
/// | 形状 | 来源 | 命名 |
/// |---|---|---|
/// | `queries.HabitPattern`（sqlc） | `GET /api/habits` | camelCase |
/// | `habitRunsWithReply`（手写 gin.H） | `GET /api/habits/runs` | snake_case + `run_id` |
/// | `habitRunToMap`（手写 gin.H） | `GET /api/chat/habit-suggestions` | snake_case + `id` |
/// | `BuildSuggestionCreatedPayload` | `habit_suggestion_created` 事件 | snake_case + 嵌套 |
///
/// 而 `sql.NullTime` **没有** `MarshalJSON`，序列化成
/// `{"Time":"...","Valid":true}` 而非裸字符串——`DateTime.tryParse` 直接拿到
/// `Map` 会失败，若写成 `?? now` 之类兜底就会把「无下次触发」显示成某个具体时间。
///
/// 故这里用**服务端真实产出的 fixture**（含实测的 NullTime 形态）钉住解析行为。
void main() {
  group('UserHabit（GET /api/habits，sqlc camelCase）', () {
    /// `queries.HabitPattern` 的 JSON 输出（字段名逐字取自 models.go 的 tag）。
    ///
    /// `nextFireAt` 用 Go 实测的 `sql.NullTime` 形态。
    Map<String, dynamic> patternJson() => {
      'id': 'hp-1',
      'userId': 'usr-1',
      'originGroupId': 'grp-1',
      'deliveryGroupId': {'String': '', 'Valid': false},
      'preferredAgentId': {'String': 'agt-9', 'Valid': true},
      'routeStrategy': '',
      'triggerType': 'time_based',
      'triggerConfigJson': '{"weekday":[1],"times":[{"hour":9,"minute":30}]}',
      'topicKey': 'weekly-report',
      'topicId': 'topic-1',
      'promptStrategy': '',
      'promptContractJson': '',
      'sourceType': 'manual',
      'learnedFromEvents': 0,
      'confidence': 0.8,
      'acceptanceLevel': 'suggest_only',
      'status': 'active',
      'nextFireAt': {'Time': '2026-10-05T01:30:00Z', 'Valid': true},
      'cooldownUntil': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
      'lastTriggeredAt': {'Time': '2026-10-04T01:30:00Z', 'Valid': true},
      'triggerCount': 3,
      'lastErrorNotifiedAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
      'createdAt': '2026-10-01T00:00:00Z',
      'updatedAt': '2026-10-04T01:30:00Z',
    };

    test('camelCase 键与 sql.NullTime 嵌套形态都能读', () {
      final h = UserHabit.fromJson(patternJson());

      expect(h.id, 'hp-1');
      expect(h.userId, 'usr-1');
      expect(h.topicKey, 'weekly-report');
      expect(h.triggerType, HabitTriggerType.timeBased);
      expect(h.acceptanceLevel, HabitAcceptanceLevel.suggestOnly);
      expect(h.status, HabitPatternStatus.active);
      expect(h.sourceType, HabitSourceType.manual);
      expect(h.confidence, 0.8);
      expect(h.triggerCount, 3);
      // NullString：Valid:false 必须归一成 null，而不是空串。
      expect(h.deliveryGroupId, isNull);
      expect(h.preferredAgentId, 'agt-9');
    });

    test('sql.NullTime 的 Valid:false 归一成 null（不是 0001 年）', () {
      final h = UserHabit.fromJson(patternJson());

      // 若实现写成 DateTime.tryParse(map) ?? 兜底，这里会拿到 0001-01-01
      // 或某个「现在」，两者都会让 UI 显示一个用户从未配置的触发时刻。
      expect(h.cooldownUntil, isNull);
      expect(h.lastErrorNotifiedAt, isNull);
      expect(h.nextFireAt, isNotNull);
      expect(h.nextFireAt!.toUtc().year, 2026);
      expect(h.lastTriggeredAt, isNotNull);
    });

    test('triggerConfigJson 是字符串，需解出对象（不是直接读 map）', () {
      final h = UserHabit.fromJson(patternJson());

      expect(h.triggerConfig.triggerType, HabitTriggerType.timeBased);
      // 写入侧已归一为单数 weekday，times 优先。
      expect(h.triggerConfig.time!.firstHour, 9);
      expect(h.triggerConfig.time!.firstMinute, 30);
      expect(h.triggerConfig.time!.weekdays, [1]);
    });

    test('weekdays 复数（未归一的历史数据）也能读，且单数优先', () {
      final plural = UserHabit.fromJson({
        ...patternJson(),
        'triggerConfigJson': '{"weekdays":[3,5],"hour":8,"minute":0}',
      });
      expect(plural.triggerConfig.time!.weekdays, [3, 5]);
      // times 为空时回退顶层 hour/minute 影子字段。
      expect(plural.triggerConfig.time!.firstHour, 8);

      final both = UserHabit.fromJson({
        ...patternJson(),
        'triggerConfigJson': '{"weekday":[1],"weekdays":[6],"hour":8}',
      });
      // 显式单数优先（NormalizeTriggerConfig 的规则：显式优于兜底）。
      expect(both.triggerConfig.time!.weekdays, [1]);
    });

    test('triggerConfigJson 非法 JSON 不抛，按「无配置」处理', () {
      final h = UserHabit.fromJson({
        ...patternJson(),
        'triggerConfigJson': '{这不是 JSON',
      });
      expect(h.triggerConfig.isEmpty, isTrue);
      expect(h.triggerConfig.summary, '未配置触发条件');
    });

    test('status 决定动作可用性（服务端只允许特定迁移）', () {
      final active = UserHabit.fromJson(patternJson());
      expect(active.canPause, isTrue);
      expect(active.canResume, isFalse);
      expect(active.canTrigger, isTrue);

      final paused = UserHabit.fromJson({...patternJson(), 'status': 'paused'});
      expect(paused.canPause, isFalse);
      expect(paused.canResume, isTrue);
      // 服务端 trigger 要求 active，paused 触发会 409。
      expect(paused.canTrigger, isFalse);

      final archived = UserHabit.fromJson({
        ...patternJson(),
        'status': 'archived',
      });
      // 归档是终态：没有 unarchive 端点。
      expect(archived.canArchive, isFalse);
    });

    test('未知 status / acceptance_level 不抛，归一成 unknown', () {
      final h = UserHabit.fromJson({
        ...patternJson(),
        'status': 'brand_new_state',
        'acceptanceLevel': 'nope',
      });
      expect(h.status, HabitPatternStatus.unknown);
      expect(h.acceptanceLevel, HabitAcceptanceLevel.unknown);
    });

    test('watch 形状（cadence/stop）按 watch 分派，不误当 time_based', () {
      final h = UserHabit.fromJson({
        ...patternJson(),
        'triggerType': 'watch',
        'triggerConfigJson':
            '{"cadence":{"initial_seconds":600,"factor":3,"max_seconds":7200},'
            '"stop":{"max_no_change":0,"expires_at":"2026-11-01T00:00:00Z"}}',
      });

      expect(h.triggerConfig.triggerType, HabitTriggerType.watch);
      expect(h.triggerConfig.time, isNull);
      final w = h.triggerConfig.watch!;
      expect(w.initialSeconds, 600);
      expect(w.factor, 3);
      expect(w.maxSeconds, 7200);
      // ⚠️ 显式 0 是合法值（第一次无变化就停），不能走 `?? default(10)`。
      expect(w.maxNoChange, 0);
      expect(w.expiresAt, '2026-11-01T00:00:00Z');
    });

    test('watch 配置缺字段时套用服务端默认值', () {
      final h = UserHabit.fromJson({
        ...patternJson(),
        'triggerType': 'watch',
        'triggerConfigJson': '{"cadence":{"initial_seconds":60}}',
      });
      final w = h.triggerConfig.watch!;
      expect(w.initialSeconds, 60);
      expect(w.factor, 2.0);
      expect(w.maxSeconds, 86400);
      expect(w.maxNoChange, 10);
    });
  });

  group('HabitRun（/api/habits/runs 与 habitRunToMap 两种形状）', () {
    test('habitRunsWithReply 形状：主键是 run_id，含 reply_text/is_manual', () {
      final r = HabitRun.fromJson({
        'run_id': 'run-1',
        'pattern_id': 'hp-1',
        'topic_key': 'weekly-report',
        'trigger_reason': 'due_rule',
        'outcome': 'completed',
        'created_at': '2026-10-04T01:30:00Z',
        'executed_at': '2026-10-04T01:30:05Z',
        'feedback_at': '',
        'user_feedback': '',
        'turn_id': 'turn-9',
        'delivery_group_id': 'grp-1',
        'delivery_group_title': '团队周报',
        'reply_text': '已生成周报草稿。',
        'is_manual': false,
      });

      expect(r.id, 'run-1');
      expect(r.habitPatternId, 'hp-1');
      expect(r.topicKey, 'weekly-report');
      expect(r.triggerReason, HabitTriggerReason.dueRule);
      expect(r.outcome, HabitRunOutcome.completed);
      expect(r.scheduledTurnId, 'turn-9');
      expect(r.deliveryGroupTitle, '团队周报');
      expect(r.replyText, '已生成周报草稿。');
      expect(r.userFeedback, isNull);
      expect(r.feedbackAt, isNull);
      expect(r.hasTurn, isTrue);
    });

    test('habitRunToMap 形状：主键是 id，pattern 键名是 habit_pattern_id', () {
      final r = HabitRun.fromJson({
        'id': 'run-2',
        'habit_pattern_id': null,
        'user_id': 'usr-1',
        'origin_group_id': 'grp-1',
        'delivery_group_id': null,
        'trigger_reason': 'candidate_detected',
        'outcome': 'suggested',
        'user_feedback': null,
        'feedback_at': '',
        'scheduled_turn_id': null,
        'created_at': '2026-10-04T02:00:00Z',
        'executed_at': '',
      });

      expect(r.id, 'run-2');
      // 候选建议没有 pattern——null 不能被归一成空串后当成「有 pattern」。
      expect(r.habitPatternId, isNull);
      expect(r.triggerReason, HabitTriggerReason.candidateDetected);
      expect(r.outcome, HabitRunOutcome.suggested);
      expect(r.isPendingSuggestion, isTrue);
      expect(r.hasTurn, isFalse);
      // 该端点不返回 reply_text。
      expect(r.replyText, '');
    });

    test('用户反馈值映射（accepted/dismissed/snoozed）', () {
      HabitRun withFeedback(String? fb) => HabitRun.fromJson({
        'id': 'r',
        'trigger_reason': 'candidate_detected',
        'outcome': 'suggested',
        'user_feedback': fb,
      });

      expect(withFeedback('accepted').userFeedback, HabitUserFeedback.accepted);
      expect(
        withFeedback('dismissed').userFeedback,
        HabitUserFeedback.dismissed,
      );
      expect(withFeedback('snoozed').userFeedback, HabitUserFeedback.snoozed);
      expect(withFeedback('').userFeedback, isNull);
      // 已反馈的建议不再 pending。
      expect(withFeedback('dismissed').isPendingSuggestion, isFalse);
    });

    test('未知 outcome / trigger_reason 不抛', () {
      final r = HabitRun.fromJson({
        'id': 'r',
        'outcome': 'brand_new',
        'trigger_reason': 'brand_new',
      });
      expect(r.outcome, HabitRunOutcome.unknown);
      expect(r.triggerReason, HabitTriggerReason.unknown);
    });
  });

  group('HabitRunsResult / HabitDailyBudget（daily_budget 不能被丢掉）', () {
    test('解析 items + daily_budget', () {
      final r = HabitRunsResult.fromJson({
        'items': [
          {'run_id': 'run-1', 'trigger_reason': 'due_rule'},
        ],
        'daily_budget': {'limit': 20, 'used_today': 3},
      });

      expect(r.items.single.id, 'run-1');
      expect(r.dailyBudget!.limit, 20);
      expect(r.dailyBudget!.usedToday, 3);
      expect(r.dailyBudget!.hasLimit, isTrue);
      expect(r.dailyBudget!.remaining, 17);
      expect(r.dailyBudget!.exhausted, isFalse);
    });

    test('daily_budget 缺失 → null（不造 0/0）', () {
      final r = HabitRunsResult.fromJson({'items': <dynamic>[]});
      expect(r.dailyBudget, isNull);
    });

    test('daily_budget 不是对象时也当 null（不抛）', () {
      expect(HabitDailyBudget.fromJson('nope'), isNull);
      expect(HabitDailyBudget.fromJson(null), isNull);
      expect(
        HabitRunsResult.fromJson({'items': <dynamic>[], 'daily_budget': 3})
            .dailyBudget,
        isNull,
      );
    });

    test('裸数组形态也能吃（与 unwrapItems 同口径）', () {
      final r = HabitRunsResult.fromJson([
        {'run_id': 'run-9', 'trigger_reason': 'manual'},
      ]);
      expect(r.items.single.id, 'run-9');
      expect(r.dailyBudget, isNull);
    });

    test('used_today 超上限时 remaining 不为负，且判定为用尽', () {
      const b = HabitDailyBudget(limit: 5, usedToday: 8);
      expect(b.remaining, 0);
      expect(b.exhausted, isTrue);
    });

    test('limit=0（服务端未给上限）→ hasLimit=false 且不判定用尽', () {
      // 若把 0 当成「上限 0」，usedToday=0 会算出 exhausted=true，
      // 页面就会说「额度已用尽」——而真相是「服务端没给上限」。
      const b = HabitDailyBudget(limit: 0, usedToday: 0);
      expect(b.hasLimit, isFalse);
      expect(b.exhausted, isFalse);
      expect(b.remaining, 0);
    });

    test('恰用尽（used == limit）算 exhausted', () {
      const b = HabitDailyBudget(limit: 5, usedToday: 5);
      expect(b.exhausted, isTrue);
      expect(b.remaining, 0);
    });
  });

  group('HabitSuggestion（事件 payload vs 列表项）', () {
    /// `BuildSuggestionCreatedPayload` 的真实输出（timeline_events.go）。
    Map<String, dynamic> createdPayload() => {
      'suggestion_id': 'run-sugg-1',
      'habit_pattern_id': null,
      'status': 'pending',
      'trigger_type': 'time_based',
      'recommendation': {
        'action': 'accept_rule',
        'confidence': 0.72,
        'reasons': ['每周一你都会让我写周报', '已连续 3 周'],
      },
      'rule_draft': {
        'topic_key': 'weekly-report',
        'trigger_type': 'time_based',
        'trigger_config': {
          'hour': 9,
          'weekday': [1],
        },
        'preferred_agent_id': 'agt-1',
        'delivery_group_id': 'grp-1',
        'target_acceptance_level': 'suggest_only',
      },
      'evidence': {'occurrences': 3},
      'editable_fields': [
        'topic_key',
        'trigger_config',
        'preferred_agent_id',
        'delivery_group_id',
      ],
    };

    test('事件 payload：草稿字段全在 rule_draft 里', () {
      final s = HabitSuggestion.fromEventPayload(
        createdPayload(),
        groupId: 'grp-1',
        userId: 'usr-1',
      )!;

      expect(s.id, 'run-sugg-1');
      // 候选建议的 habit_pattern_id 是 null，不是空串。
      expect(s.habitPatternId, isNull);
      expect(s.isPending, isTrue);
      expect(s.topicKey, 'weekly-report');
      expect(s.triggerType, HabitTriggerType.timeBased);
      expect(s.preferredAgentId, 'agt-1');
      expect(s.targetAcceptanceLevel, HabitAcceptanceLevel.suggestOnly);
      expect(s.confidence, 0.72);
      expect(s.reasons, hasLength(2));
      expect(s.evidence['occurrences'], 3);
      expect(s.canEdit, isTrue);
      expect(s.triggerConfig!.time!.firstHour, 9);
      expect(s.triggerConfig!.time!.weekdays, [1]);
    });

    test('缺 suggestion_id 时返回 null（无身份键不可操作）', () {
      final payload = createdPayload()..remove('suggestion_id');
      expect(HabitSuggestion.fromEventPayload(payload), isNull);
    });

    test('watch 候选：trigger_config 是 cadence/stop，卡片须按类型渲染', () {
      final payload = createdPayload();
      payload['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_config'] = {
        'cadence': {'initial_seconds': 3600},
      };

      final s = HabitSuggestion.fromEventPayload(payload)!;
      expect(s.triggerType, HabitTriggerType.watch);
      expect(s.triggerConfig!.triggerType, HabitTriggerType.watch);
      // 若把 watch 当 time_based 渲染，卡片会显示「凌晨 0 点」——一个用户
      // 从未表达过的时刻。
      expect(s.triggerConfig!.time, isNull);
      expect(s.triggerConfig!.summary, contains('小时'));
    });

    test('列表项形状：topic_key 只能从 trigger_context_json 还原', () {
      // `habitRunToMap` 不含 topic_key 键——这是列表端点的真实缺口。
      final s = HabitSuggestion.fromListItem({
        'id': 'run-sugg-2',
        'habit_pattern_id': null,
        'user_id': 'usr-1',
        'origin_group_id': 'grp-1',
        'delivery_group_id': null,
        'trigger_reason': 'candidate_detected',
        'outcome': 'suggested',
        'user_feedback': null,
        'feedback_at': '',
        'scheduled_turn_id': null,
        'created_at': '2026-10-04T02:00:00Z',
        'executed_at': '',
        'trigger_context_json':
            '{"topic_key":"daily-standup","trigger_config":{"hour":9},'
            '"confidence":0.6}',
      });

      expect(s.id, 'run-sugg-2');
      expect(s.topicKey, 'daily-standup');
      expect(s.confidence, 0.6);
      expect(s.isPending, isTrue);
      expect(s.triggerConfig!.time!.firstHour, 9);
    });

    test('列表项兼容 Python 旧形态 candidate.topic_key', () {
      final s = HabitSuggestion.fromListItem({
        'id': 'run-old',
        'outcome': 'suggested',
        'trigger_reason': 'candidate_detected',
        'trigger_context_json': '{"candidate":{"topic_key":"legacy-topic"}}',
      });
      expect(s.topicKey, 'legacy-topic');
    });

    test('列表项的 trigger_context_json 非法 JSON 不抛', () {
      final s = HabitSuggestion.fromListItem({
        'id': 'run-bad',
        'outcome': 'suggested',
        'trigger_reason': 'candidate_detected',
        'trigger_context_json': 'not json',
      });
      expect(s.topicKey, '');
      expect(s.triggerConfig, isNull);
    });

    test('action → user_feedback 的映射（三个都不等于请求体 action）', () {
      // 请求体用 accept/dismiss/snooze，服务端写库用 accepted/dismissed/snoozed
      // （mapFeedbackValue，misc_extra.go:553）。两种都能反查回同一枚举。
      expect(
        HabitSuggestionAction.from('accept'),
        HabitSuggestionAction.accept,
      );
      expect(
        HabitSuggestionAction.from('accepted'),
        HabitSuggestionAction.accept,
      );
      expect(
        HabitSuggestionAction.from('edit_and_accept'),
        HabitSuggestionAction.editAndAccept,
      );
      expect(HabitSuggestionAction.accept.createsPattern, isTrue);
      expect(HabitSuggestionAction.editAndAccept.createsPattern, isTrue);
      expect(HabitSuggestionAction.dismiss.createsPattern, isFalse);
      expect(HabitSuggestionAction.snooze.createsPattern, isFalse);
      expect(HabitSuggestionAction.accept.feedback, 'accepted');
      expect(HabitSuggestionAction.editAndAccept.feedback, 'accepted');
      expect(HabitSuggestionAction.dismiss.feedback, 'dismissed');
      expect(HabitSuggestionAction.snooze.feedback, 'snoozed');
      // `accept_rule` 是 recommendation.action，不是 user_feedback——
      // 早期实现把它当成反馈值，导致 snooze/dismiss 也错位。
      expect(HabitSuggestionAction.from('accept_rule'), isNull);
    });
  });

  group('HabitSnoozeOption（必须产 UTC，对齐 webapp computeSnoozeUntil）', () {
    test('相对时长按 UTC 加小时', () {
      final now = DateTime.utc(2026, 10, 4, 10, 0, 0);
      expect(HabitSnoozeOption.oneHour.untilIso(now), '2026-10-04T11:00:00Z');
      expect(HabitSnoozeOption.fourHours.untilIso(now), '2026-10-04T14:00:00Z');
      expect(HabitSnoozeOption.oneDay.untilIso(now), '2026-10-05T10:00:00Z');
    });

    test('tomorrow 是 UTC 次日 00:00（不是本地时区，也不是 +24h）', () {
      final now = DateTime.utc(2026, 10, 4, 23, 30, 0);
      expect(HabitSnoozeOption.tomorrow.untilIso(now), '2026-10-05T00:00:00Z');
    });

    test('本地时间输入会先转 UTC 再算（不产生带偏移的串）', () {
      final local = DateTime(2026, 10, 4, 10, 0, 0);
      final iso = HabitSnoozeOption.oneHour.untilIso(local);
      expect(iso, endsWith('Z'));
      expect(DateTime.parse(iso), local.toUtc().add(const Duration(hours: 1)));
    });

    test('产出的串无毫秒（与 webapp 形态一致，服务端能解析）', () {
      final iso = HabitSnoozeOption.oneHour.untilIso(
        DateTime.utc(2026, 10, 4, 10, 0, 0),
      );
      expect(iso.contains('.'), isFalse);
      expect(iso, '2026-10-04T11:00:00Z');
    });
  });
}
