import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `TodoChange.fromEvent` 的容错矩阵（`todo.changed` 载荷只保证 `op`）。
///
/// 与通道测试（`chat_stream_controller_channels_test.dart`）的分工：
/// 那边钉「分流位置/游标/缓冲」这些控制器侧不变式，这里钉「字段解析」。
void main() {
  /// 造一个 `todo.changed` 事件（服务端形态：无 turn、Transient）。
  ChatEvent event({
    String type = EventTypes.todoChanged,
    String groupId = 'grp_1',
    Map<String, dynamic>? payload,
  }) => ChatEvent.fromJson({
    'eventId': 'evt_1',
    'userId': 'usr_1',
    'groupId': groupId,
    // 服务端信封没有 turn（groupsync 的拦截与轮次无关）。
    'turnId': '',
    'eventType': type,
    'seq': 0,
    'source': 'system',
    'createdAt': '2026-11-23T08:00:00Z',
    'transient': true,
    if (payload != null) 'payload': payload,
  });

  group('TodoChange.fromEvent', () {
    test('非 todo.changed 返回 null', () {
      expect(
        TodoChange.fromEvent(
          event(type: EventTypes.groupUpdated, payload: {'op': 'created'}),
        ),
        isNull,
      );
    });

    test('识别 created、resolved 与 removed', () {
      expect(
        TodoChange.fromEvent(event(payload: {'op': 'created'}))!.op,
        TodoChangeOp.created,
      );
      expect(
        TodoChange.fromEvent(event(payload: {'op': 'resolved'}))!.op,
        TodoChangeOp.resolved,
      );
      expect(
        TodoChange.fromEvent(event(payload: {'op': 'removed'}))!.op,
        TodoChangeOp.removed,
      );
    });

    test('op 缺失或未知 → unknown，但通知**不丢**', () {
      final missing = TodoChange.fromEvent(event(payload: const {}));
      final unknown = TodoChange.fromEvent(event(payload: {'op': 'archived'}));

      expect(missing, isNotNull, reason: '缺 op 也要送达：消费方照样重拉一次');
      expect(missing!.op, TodoChangeOp.unknown);
      expect(unknown, isNotNull);
      expect(unknown!.op, TodoChangeOp.unknown);
    });

    test('payload 整个缺失时仍返回一条通知', () {
      final change = TodoChange.fromEvent(event());

      expect(change, isNotNull);
      expect(change!.op, TodoChangeOp.unknown);
      expect(change.groupId, 'grp_1', reason: 'groupId 取自信封');
    });

    test('groupId 信封优先，其次 payload 的 group_id', () {
      expect(
        TodoChange.fromEvent(
          event(payload: {'op': 'created', 'group_id': 'grp_payload'}),
        )!.groupId,
        'grp_1',
        reason: '信封的 group_id 是 broker 的扇出键，比 payload 更可信',
      );
      expect(
        TodoChange.fromEvent(
          event(groupId: '', payload: {'op': 'created', 'group_id': 'grp_p2'}),
        )!.groupId,
        'grp_p2',
      );
      expect(
        TodoChange.fromEvent(event(groupId: '', payload: {'op': 'created'}))!
            .groupId,
        '',
        reason: '两处都没有时留空串，由 matchesGroup 保守刷新',
      );
    });

    test('可选字段缺失即 null（客户端不得依赖）', () {
      final change = TodoChange.fromEvent(event(payload: {'op': 'created'}))!;

      expect(change.reviewId, isNull);
      expect(change.path, isNull);
      expect(change.directory, isFalse);
      expect(change.reason, isNull);
      expect(change.turnId, isNull);
    });

    test('可选字段齐备时逐项解析（resolved 的载荷也带原路径与原因）', () {
      final change = TodoChange.fromEvent(
        event(
          payload: {
            'op': 'resolved',
            'group_id': 'grp_1',
            'review_id': 'rev_1',
            'path': 'reports/2026/weekly.md',
            'directory': true,
            'reason': 'batch_too_large',
            'turn_id': 'turn_abc',
          },
        ),
      )!;

      expect(change.op, TodoChangeOp.resolved);
      expect(change.reviewId, 'rev_1');
      expect(change.path, 'reports/2026/weekly.md');
      expect(change.directory, isTrue);
      expect(change.reason, WorkspaceSyncReviewReason.batchTooLarge);
      expect(change.turnId, 'turn_abc');
    });

    test('空串的可选字段当缺失（服务端 omitempty 的反面）', () {
      final change = TodoChange.fromEvent(
        event(payload: {'op': 'created', 'review_id': '', 'path': ''}),
      )!;

      expect(change.reviewId, isNull);
      expect(change.path, isNull);
    });

    test('directory 只在 true 时为真（"true" 字符串不算）', () {
      expect(
        TodoChange.fromEvent(
          event(payload: {'op': 'created', 'directory': 'true'}),
        )!.directory,
        isFalse,
      );
      expect(
        TodoChange.fromEvent(
          event(payload: {'op': 'created', 'directory': true}),
        )!.directory,
        isTrue,
      );
    });

    test('未知 reason 退化为 unknown 而不是 null（不得丢信息）', () {
      final change = TodoChange.fromEvent(
        event(payload: {'op': 'created', 'reason': 'rate_limited'}),
      )!;

      expect(change.reason, WorkspaceSyncReviewReason.unknown);
      expect(
        WorkspaceSyncReviewReason.unknown.label,
        isNotEmpty,
        reason: 'UI 要能对未知原因说一句人话',
      );
    });
  });

  group('TodoChange.matchesGroup', () {
    test('同 group → true', () {
      expect(
        const TodoChange(
          groupId: 'grp_1',
          op: TodoChangeOp.created,
        ).matchesGroup('grp_1'),
        isTrue,
      );
    });

    test('不同 group → false', () {
      expect(
        const TodoChange(
          groupId: 'grp_1',
          op: TodoChangeOp.created,
        ).matchesGroup('grp_2'),
        isFalse,
      );
    });

    test('groupId 缺失（空串/空白）→ true（不确定范围时保守刷新）', () {
      const op = TodoChangeOp.created;
      expect(
        const TodoChange(groupId: '', op: op).matchesGroup('grp_1'),
        isTrue,
      );
      expect(
        const TodoChange(groupId: '  ', op: op).matchesGroup('grp_1'),
        isTrue,
      );
    });
  });

  group('TodoChange.matchesAnyGroup', () {
    test('命中集合中任一项 → true', () {
      expect(
        const TodoChange(
          groupId: 'g2',
          op: TodoChangeOp.created,
        ).matchesAnyGroup(['g1', 'g2', 'g3']),
        isTrue,
      );
    });

    test('不在集合里 → false（范围外的 group 重拉也查不到东西）', () {
      expect(
        const TodoChange(
          groupId: 'g9',
          op: TodoChangeOp.created,
        ).matchesAnyGroup(['g1', 'g2']),
        isFalse,
      );
    });

    test('空集合 → false（没查过任何对话）', () {
      expect(
        const TodoChange(
          groupId: 'g1',
          op: TodoChangeOp.created,
        ).matchesAnyGroup(const []),
        isFalse,
      );
    });

    test('groupId 缺失 → true（不确定范围时保守刷新）', () {
      expect(
        const TodoChange(
          groupId: '',
          op: TodoChangeOp.created,
        ).matchesAnyGroup(['g1']),
        isTrue,
      );
    });

    test('两侧空白不影响匹配', () {
      expect(
        const TodoChange(
          groupId: ' g1 ',
          op: TodoChangeOp.created,
        ).matchesAnyGroup(['g1 ']),
        isTrue,
      );
    });
  });
}
