import 'package:spb_models/spb_models.dart';

enum GroupTurnStatus {
  pending,
  queued,
  running,
  completed,
  failed,
  cancelled;

  bool get isTerminal =>
      this == completed || this == failed || this == cancelled;

  static GroupTurnStatus? parse(Object? value) =>
      values.where((status) => status.name == value).firstOrNull;
}

typedef GroupTurn = ({String id, GroupTurnStatus status});

typedef GroupTurnSummary = ({
  GroupTurnStatus? activeStatus,
  GroupTurn? latestFinished,
  bool isVerified,
});

typedef _TurnKey = ({String groupId, String turnId});
typedef _TurnEntry = ({
  DateTime createdAt,
  GroupTurnStatus status,
  int revision,
  int eventSeq,
});

/// 每次列表刷新只接收一页用户轮次。实时状态覆盖同一轮次的滞后快照。
class GroupTurnIndex {
  final _turns = <_TurnKey, _TurnEntry>{};
  int _revision = 0;
  bool _isVerified = true;

  int get revision => _revision;

  void markUnverified() => _isVerified = false;

  void applySnapshot(Iterable<ChatTurnSummary> items, {required int since}) {
    final snapshot = <_TurnKey, _TurnEntry>{};
    for (final item in items) {
      final status = GroupTurnStatus.parse(item.status);
      if (status == null || item.groupId.isEmpty || item.turnId.isEmpty) {
        continue;
      }
      final key = (groupId: item.groupId, turnId: item.turnId);
      final observed = _turns[key];
      // 已知终态不能回退，还要保留请求发出之后收到的事件。
      final preserveEvent =
          observed != null &&
          observed.revision > 0 &&
          (observed.status.isTerminal == status.isTerminal
              ? observed.revision > since
              : observed.status.isTerminal);
      snapshot[key] = (
        createdAt: item.createdAt,
        status: preserveEvent ? observed.status : status,
        revision: preserveEvent ? observed.revision : 0,
        eventSeq: observed?.eventSeq ?? 0,
      );
    }
    // 请求在途期间收到的新轮次可能尚未进入服务端返回窗口。
    for (final entry in _turns.entries) {
      if (entry.value.revision > since) {
        snapshot.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _turns
      ..clear()
      ..addAll(snapshot);
    _trim();
    _isVerified = true;
  }

  bool applyEvent(ChatEvent event) {
    if (event.groupId.isEmpty || event.turnId.isEmpty) return false;
    final status = switch (event.eventType) {
      EventTypes.start => GroupTurnStatus.running,
      EventTypes.queueState => switch (event.queueStateValue) {
        'queued' => GroupTurnStatus.queued,
        'cancelled' => GroupTurnStatus.cancelled,
        _ => null,
      },
      EventTypes.done => _terminalStatus(event.payload?['status']),
      EventTypes.error => _terminalStatus(event.payload?['turn_status']),
      _ => null,
    };
    if (status == null) return false;
    final key = (groupId: event.groupId, turnId: event.turnId);
    final previous = _turns[key];
    final sequence = event.globalSeq ?? event.seq;
    if (previous != null) {
      if (sequence > 0 && sequence <= previous.eventSeq) return false;
      if (previous.status.isTerminal && !status.isTerminal) return false;
    }
    _turns[key] = (
      createdAt: previous?.createdAt ?? event.createdAt,
      status: status,
      revision: ++_revision,
      eventSeq: sequence > 0 ? sequence : previous?.eventSeq ?? 0,
    );
    // 与 REST 窗口同为有界数据，避免长时间开着首页时积累所有历史轮次。
    _trim();
    return true;
  }

  void _trim() {
    if (_turns.length <= 400) return;
    final oldest = _turns.entries.toList()
      ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));
    for (final entry in oldest.take(_turns.length - 400)) {
      _turns.remove(entry.key);
    }
  }

  Map<String, GroupTurnSummary> get summaries {
    final latest = <String, MapEntry<_TurnKey, _TurnEntry>>{};
    final active = <String, GroupTurnStatus>{};
    for (final entry in _turns.entries) {
      final groupId = entry.key.groupId;
      final turn = entry.value;
      if (turn.status.isTerminal) {
        final previous = latest[groupId]?.value;
        if (previous == null ||
            turn.createdAt.isAfter(previous.createdAt) ||
            (turn.createdAt == previous.createdAt &&
                turn.revision > previous.revision)) {
          latest[groupId] = entry;
        }
      } else if (turn.status.index > (active[groupId]?.index ?? -1)) {
        active[groupId] = turn.status;
      }
    }
    return {
      for (final groupId in {...active.keys, ...latest.keys})
        groupId: (
          activeStatus: active[groupId],
          latestFinished: switch (latest[groupId]) {
            final entry? => (id: entry.key.turnId, status: entry.value.status),
            null => null,
          },
          isVerified: _isVerified,
        ),
    };
  }

  static GroupTurnStatus? _terminalStatus(Object? value) {
    final status = GroupTurnStatus.parse(value);
    return status?.isTerminal == true ? status : null;
  }
}
