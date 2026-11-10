import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// `HabitSuggestionItem.fromSuggestion` 的字段映射测试。
///
/// ## 为什么值得单独测
///
/// 「建议收件箱」页拿的是**列表端点**的 `HabitSuggestion`，卡片渲染的是归约后的
/// `HabitSuggestionItem`。映射错一个字段不会报错，只会让卡片静默变成
/// 「未命名 / 无理由 / 已延后（没有时刻）」——比 500 更难发现。
///
/// 尤其要钉住的是：列表端点把 `resolved_pattern_id` / `snooze_until` 埋在
/// `feedback_payload` 里，而不是顶层。
void main() {
  HabitSuggestion suggestion({
    String id = 'run-1',
    String topicKey = 'weekly-report',
    String? feedback,
    Map<String, dynamic>? feedbackPayload,
    String? createdAt = '2026-10-04T01:30:00Z',
  }) => HabitSuggestion.fromListItem({
    'id': id,
    'habit_pattern_id': null,
    'user_id': 'usr-1',
    'origin_group_id': 'grp-1',
    'delivery_group_id': 'grp-1',
    'trigger_reason': 'candidate_detected',
    'outcome': 'suggested',
    'trigger_context_json':
        '{"topic_key":"$topicKey","hour":9,"minute":0,'
        '"weekday":[1],"reasons":["每周一你都会让我写周报"],'
        '"confidence":0.72}',
    'user_feedback': feedback,
    'feedback_payload': feedbackPayload,
    'created_at': createdAt,
  });

  test('基本字段直通', () {
    final item = HabitSuggestionItem.fromSuggestion(suggestion());

    expect(item.suggestionId, 'run-1');
    expect(item.topicKey, 'weekly-report');
    // trigger_context 里没有 `trigger_type` 键（服务端检测器不写它）→ 枚举落到
    // unknown。这是既有行为：卡片的节奏文案优先用 triggerConfig.summary，只有
    // 配置为空时才用 triggerType 区分「持续盯梢」与「未配置」。
    expect(item.triggerType, HabitTriggerType.unknown);
    expect(item.triggerConfig?.summary, '每周一 09:00');
    expect(item.confidence, 0.72);
    expect(item.reasons, ['每周一你都会让我写周报']);
    expect(item.createdAt, DateTime.utc(2026, 10, 4, 1, 30).toLocal());
  });

  test('id 用 suggestionId 兜底（列表项没有 eventId）', () {
    final item = HabitSuggestionItem.fromSuggestion(suggestion(id: 'run-7'));
    expect(item.id, 'run-7');
    expect(item.turnId, '');
  });

  test('createdAt 缺失时不抛，退到 epoch', () {
    final item = HabitSuggestionItem.fromSuggestion(
      suggestion(createdAt: null),
    );
    expect(item.createdAt.millisecondsSinceEpoch, 0);
  });

  test('editableFields 为空 → canEdit=false（列表端点不下发白名单）', () {
    final item = HabitSuggestionItem.fromSuggestion(suggestion());
    expect(item.editableFields, isEmpty);
    expect(item.canEdit, isFalse);
  });

  test('trigger_context 里的 trigger_type 存在时被采纳', () {
    final item = HabitSuggestionItem.fromSuggestion(
      HabitSuggestion.fromListItem({
        'id': 'run-w',
        'trigger_reason': 'candidate_detected',
        'outcome': 'suggested',
        'trigger_context_json':
            '{"topic_key":"standup","trigger_type":"watch","cadence":"daily"}',
        'created_at': '2026-10-04T01:30:00Z',
      }),
    );

    expect(item.triggerType, HabitTriggerType.watch);
    expect(item.triggerConfig?.triggerType, HabitTriggerType.watch);
  });

  test('trigger_context 为对象（habitRunToMap 形状）也能解析', () {
    // ⚠️ 回归锁：候选建议列表下发的是 `trigger_context` **对象**，而不是执行记录
    // 那种 `trigger_context_json` **字符串**。旧实现用 `habitStr` 读它，得到的是
    // `{topic_key: weekly-report}`（键无引号的 Map.toString()）——不是合法 JSON，
    // `jsonDecode` 抛 FormatException 后被当成「无上下文」静默吃掉：卡片显示
    // 「未命名」、无理由。
    final item = HabitSuggestionItem.fromSuggestion(
      HabitSuggestion.fromListItem({
        'id': 'run-obj',
        'trigger_reason': 'candidate_detected',
        'outcome': 'suggested',
        'trigger_context': const {
          'topic_key': 'weekly-report',
          'hour': 9,
          'reasons': ['每周一你都会让我写周报'],
        },
        'feedback_payload': const {
          'action': 'accept',
          'resolved_pattern_id': 'hp-obj',
        },
        'user_feedback': 'accepted',
        'created_at': '2026-10-04T01:30:00Z',
      }),
    );

    expect(item.topicKey, 'weekly-report');
    expect(item.reasons, ['每周一你都会让我写周报']);
    expect(item.resolvedPatternId, 'hp-obj');
  });

  test('未处理：canResolve=true，无 resolvedPatternId / snoozeUntil', () {
    final item = HabitSuggestionItem.fromSuggestion(suggestion());
    expect(item.userFeedback, isNull);
    expect(item.canResolve, isTrue);
    expect(item.resolvedPatternId, isNull);
    expect(item.snoozeUntil, isNull);
  });

  test('已采纳：resolved_pattern_id 从 feedback_payload 里挖出来', () {
    final item = HabitSuggestionItem.fromSuggestion(
      suggestion(
        feedback: 'accepted',
        feedbackPayload: const {
          'action': 'accept',
          'resolved_at': '2026-10-04T02:00:00Z',
          'resolved_pattern_id': 'hp-9',
        },
      ),
    );

    expect(item.userFeedback, HabitUserFeedback.accepted);
    expect(item.canResolve, isFalse);
    expect(item.resolvedPatternId, 'hp-9');
  });

  test('已延后：snooze_until 从 feedback_payload 里挖出来并转本地时区', () {
    final item = HabitSuggestionItem.fromSuggestion(
      suggestion(
        feedback: 'snoozed',
        feedbackPayload: const {
          'action': 'snooze',
          'snooze_until': '2026-10-05T00:00:00Z',
        },
      ),
    );

    expect(item.snoozeUntil, DateTime.utc(2026, 10, 5).toLocal());
  });

  test('dismiss 写的是 cooldown_until —— 不是 snoozeUntil', () {
    // 服务端 dismiss 写 `cooldown_until`、snooze 写 `snooze_until`
    // （`misc_extra.go` 的 feedbackPayload 构造）。把前者读成后者会让「已忽略」
    // 的卡片显示一个用户从未选择的延后时刻。
    final item = HabitSuggestionItem.fromSuggestion(
      suggestion(
        feedback: 'dismissed',
        feedbackPayload: const {
          'action': 'dismiss',
          'cooldown_until': '2026-10-05T00:00:00Z',
        },
      ),
    );

    expect(item.userFeedback, HabitUserFeedback.dismissed);
    expect(item.snoozeUntil, isNull);
  });

  test('feedback_payload 为 null / 空串时不抛', () {
    final a = HabitSuggestionItem.fromSuggestion(
      suggestion(feedback: 'accepted'),
    );
    final b = HabitSuggestionItem.fromSuggestion(
      suggestion(
        feedback: 'accepted',
        feedbackPayload: const {'resolved_pattern_id': ''},
      ),
    );

    expect(a.resolvedPatternId, isNull);
    // 空串等同「没有」——否则结果行会显示「已采纳，习惯已生效」而 pattern 不存在。
    expect(b.resolvedPatternId, isNull);
  });
}
