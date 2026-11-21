import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 契约漂移的两条可见出口（issue #116 / #117）。
///
/// ## 这组用例守的是什么
///
/// 本仓的归约器按**类型** `switch`，`default:` 兜住一切。历史上这种形状已经
/// 吞过两次真事件（`agent.file.*` 2927 条、`goal_gate_stopped`）——两次都是
/// 「常量/目录说它该出现，实现里没有分支」，两次都是用户先发现、测试后知后觉。
///
/// 本文件钉住两条新增出口：
///
/// | 出口 | 触发条件 | 错误实现的后果 |
/// |---|---|---|
/// | [UnknownEventItem] | 服务端新增、本仓不认识、会落库、非诊断类 | 静默丢帧（今天的样子） |
/// | [HabitRecalibrationItem] | `habit_pattern_recalibrated` | 用户只知道「它突然不提醒了」，没有解释 |
///
/// 同时钉住**不该触发**的三种情形（增量、诊断类、已登记的控制类）——否则修正
/// 「静默丢」会一路滑向「每次执行都冒一串未知事件行」，那比丢帧更糟。
void main() {
  ChatEvent ev(
    String type, {
    String id = '',
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    bool diagnostic = false,
    int seq = 1,
    int globalSeq = 1,
  }) => ChatEvent(
    eventId: id.isEmpty ? '${type}_$globalSeq' : id,
    userId: 'usr_1',
    groupId: 'grp_1',
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: transient ? null : globalSeq,
    source: 'test',
    createdAt: DateTime.utc(2024, 3, 5, 8, 9, globalSeq.clamp(0, 59)),
    payload: payload,
    transient: transient,
    diagnostic: diagnostic,
  );

  ReductionResult reduce(List<ChatEvent> events) => EventReducer.reduce(events);

  group('未知事件类型 → 一行可见的「未知事件」', () {
    test('不认识 + 落库 + 非诊断 ⇒ 产出 UnknownEventItem', () {
      final result = reduce([
        ev('brand_new_timeline_event', id: 'e1', payload: {'x': 1}),
      ]);

      expect(result.items, hasLength(1));
      final item = result.items.single as UnknownEventItem;
      expect(item.eventType, 'brand_new_timeline_event');
      expect(item.count, 1);
      expect(item.turnId, 'turn_1');
      // 不透传 payload（可能含工作区路径 / stderr / session id，见 #115）。
      expect(item.id, 'unknown:turn_1:brand_new_timeline_event');
    });

    test('同类型多条合并计数，且保留首次的 id / createdAt（列表不跳）', () {
      final result = reduce([
        ev('brand_new_timeline_event', id: 'e1', globalSeq: 1),
        ev('brand_new_timeline_event', id: 'e2', globalSeq: 2),
        ev('brand_new_timeline_event', id: 'e3', globalSeq: 3),
      ]);

      expect(result.items, hasLength(1));
      final item = result.items.single as UnknownEventItem;
      expect(item.count, 3);
      expect(item.createdAt, DateTime.utc(2024, 3, 5, 8, 9, 1));
    });

    test('同一条事件被重放（cursor 与 timeline 重叠）不虚增计数', () {
      final result = reduce([
        ev('brand_new_timeline_event', id: 'e1', globalSeq: 1),
        ev('brand_new_timeline_event', id: 'e1', globalSeq: 1),
      ]);

      expect((result.items.single as UnknownEventItem).count, 1);
    });

    test('不同类型的未知事件各成一行（类型名是唯一可归因线索）', () {
      final result = reduce([
        ev('brand_new_a', id: 'e1', globalSeq: 1),
        ev('brand_new_b', id: 'e2', globalSeq: 2),
      ]);

      expect(result.items, hasLength(2));
      expect(
        result.items.whereType<UnknownEventItem>().map((i) => i.eventType),
        ['brand_new_a', 'brand_new_b'],
      );
    });
  });

  group('不该冒泡的三种情形（否则每次执行都刷未知事件行）', () {
    test('增量帧（transient）不产出项', () {
      final result = reduce([ev('brand_new_delta', id: 'e1', transient: true)]);

      expect(result.items, isEmpty);
    });

    test('服务端标了 diagnostic 的事件不产出项', () {
      final result = reduce([
        ev('brand_new_diagnostic', id: 'e1', diagnostic: true),
      ]);

      expect(result.items, isEmpty);
    });

    test('登记在 EventTypes.diagnosticOnly 里的控制类不产出项', () {
      // 这些是服务端**已经在发**的控制事件（`executor_startup` 等），本仓没有
      // 渲染分支也不该有——把它们显示成「未知事件」才是回归。
      final types = [
        'executor_startup',
        'executor_fallback',
        'retry_push_done',
        'session_rotated',
        'session_summary',
        'turn_reminder_injected',
      ];
      for (final type in types) {
        final result = reduce([ev(type, id: 'e_$type')]);
        expect(result.items, isEmpty, reason: '$type 不该渲染');
      }
    });

    test('已认识但不渲染的控制事件照旧静默（本次改动不扩大到它们）', () {
      final result = reduce([
        ev(EventTypes.heartbeat, id: 'e1', transient: true),
        ev(EventTypes.gateEvaluated, id: 'e2'),
      ]);

      expect(result.items, isEmpty);
    });
  });

  group('habit_pattern_recalibrated（目录对拍抓到的第一个真 bug）', () {
    HabitRecalibrationItem recalibrated(String type, Map<String, dynamic> p) {
      final result = reduce([ev(type, id: 'e1', payload: p)]);
      expect(result.items, hasLength(1), reason: '$type 此前落到 default 分支被静默丢弃');
      return result.items.single as HabitRecalibrationItem;
    }

    test('blocking_feedback → 降级 + 阻塞比例', () {
      final item = recalibrated(EventTypes.habitPatternRecalibrated, {
        'topic_key': 'deep_work',
        'reason': 'blocking_feedback',
        'previous_acceptance_level': 'auto_run',
        'next_acceptance_level': 'confirm_required',
        'blocking_ratio': 0.55,
      });

      expect(item.topicLabel, 'deep work');
      expect(
        item.summary,
        '习惯规则已降级 · deep work · auto run → confirm required（阻塞 55%）',
      );
    });

    test('acceptance_feedback → 升级 + 接受比例', () {
      final item = recalibrated(EventTypes.habitPatternRecalibrated, {
        'topic_key': 'weekly-report',
        'reason': 'acceptance_feedback',
        'previous_acceptance_level': 'confirm_required',
        'next_acceptance_level': 'auto_run',
        'acceptance_ratio': 0.8,
      });

      expect(item.summary, contains('已升级'));
      expect(item.summary, contains('接受 80%'));
    });

    test('其他 reason → 「重新校准」且不带比例', () {
      final item = recalibrated(EventTypes.habitPatternRecalibrated, {
        'topic_key': 'standup',
        'reason': 'manual',
      });

      expect(item.summary, contains('已重新校准'));
      expect(item.summary, isNot(contains('（')));
    });

    test('载荷缺字段也不丢事件（无 topic 渲染「未命名习惯」）', () {
      // 与 HabitAutoRunItem 同一取向：身份不靠 topic，缺它只影响文案。
      final item = recalibrated(EventTypes.habitPatternRecalibrated, const {});
      expect(item.topicLabel, '未命名习惯');
      expect(item.summary, contains('未知级别'));
    });

    test('重放同一条不重复产出（按 eventId 幂等）', () {
      final p = {'topic_key': 'deep_work', 'reason': 'blocking_feedback'};
      final result = reduce([
        ev(EventTypes.habitPatternRecalibrated, id: 'e1', payload: p),
        ev(EventTypes.habitPatternRecalibrated, id: 'e1', payload: p),
      ]);

      expect(result.items, hasLength(1));
    });
  });
}
