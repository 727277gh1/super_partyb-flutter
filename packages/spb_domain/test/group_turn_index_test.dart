import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 27);
  ChatTurnSummary row(String turnId, String status, {int minute = 0}) =>
      ChatTurnSummary.fromJson({
        'turn_id': turnId,
        'group_id': 'g1',
        'status': status,
        'created_at': at.add(Duration(minutes: minute)).toIso8601String(),
      });

  ChatEvent event(
    String turnId,
    String type,
    int sequence, {
    Map<String, dynamic>? payload,
  }) => ChatEvent(
    eventId: 'evt_$sequence',
    userId: 'u1',
    groupId: 'g1',
    turnId: turnId,
    eventType: type,
    seq: sequence,
    source: 'system',
    createdAt: at.add(Duration(minutes: sequence)),
    payload: payload,
  );

  test('旧轮次终态和新轮次执行可同时展示，滞后快照不会覆盖 done', () {
    final index = GroupTurnIndex()
      ..applySnapshot([row('turn_1', 'running')], since: 0);
    index.applyEvent(event('turn_2', EventTypes.start, 2));
    index.applyEvent(
      event('turn_1', EventTypes.done, 3, payload: {'status': 'failed'}),
    );
    final since = index.revision;
    expect(index.summaries['g1']?.activeStatus, GroupTurnStatus.running);
    expect(index.summaries['g1']?.latestFinished, (
      id: 'turn_1',
      status: GroupTurnStatus.failed,
    ));
    index.applySnapshot([
      row('turn_1', 'running'),
      row('turn_2', 'running', minute: 2),
    ], since: since);
    expect(
      index.summaries['g1']?.latestFinished?.status,
      GroupTurnStatus.failed,
    );
    expect(index.applyEvent(event('turn_1', EventTypes.start, 1)), isFalse);
  });

  test('快照终态优先于在途旧起跑事件，普通 error 不等于失败', () {
    final index = GroupTurnIndex();
    index.applyEvent(event('turn_1', EventTypes.start, 1));
    expect(index.applyEvent(event('turn_1', EventTypes.error, 2)), isFalse);
    index.applySnapshot([row('turn_1', 'cancelled')], since: 0);
    expect(
      index.summaries['g1']?.latestFinished?.status,
      GroupTurnStatus.cancelled,
    );
    expect(index.summaries['g1']?.activeStatus, isNull);
    index.markUnverified();
    expect(index.summaries['g1']?.isVerified, isFalse);
    index.applySnapshot([], since: index.revision);
    expect(index.summaries, isEmpty);
  });
}
