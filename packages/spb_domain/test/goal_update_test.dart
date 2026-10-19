import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [GoalUpdate] 的契约测试。
///
/// ## 为什么这些断言重要
///
/// `goal_updated` 的 payload 由 Go `emitGoalUpdated` 生成，与 `GET /goals/current`
/// **共用同一套 DTO 函数**（`goalToDTO` / `taskToDTO` / `progressFromTasks`）。
/// 服务端这么做是刻意的防漂移设计，故客户端只需一套解析逻辑。
///
/// 但它有一个**服务端缺陷**必须在此钉住：`emitGoalUpdated` 注释写「不落库」，
/// 却漏设 `Transient: true`（对比同族的 `PublishGroupUpdated` 可见是漏设）。
/// 后果不是「丢这一条」，而是「整个断线回放窗口丢失」——详见
/// `chat_stream_controller_test.dart` 里那条游标断言。
void main() {
  /// 造一个 `goal_updated` 事件。
  ///
  /// ⚠️ 默认 `transient: false`——**刻意如此**，因为服务端实际就是漏设了该标志。
  /// 用 `transient: true` 造事件会让「游标不得推进」的断言在假数据上假通过。
  ChatEvent goalEvent({
    String id = 'evt_goal_1',
    String groupId = 'grp_1',
    String op = 'goal_create',
    String source = 'user',
    Map<String, dynamic>? goal,
    List<Map<String, dynamic>>? tasks,
    Map<String, dynamic>? progress,
    String? taskId,
    bool transient = false,
    int globalSeq = 0,
  }) => ChatEvent.fromJson({
    'eventId': id,
    'userId': 'usr_1',
    'groupId': groupId,
    'turnId': '',
    'eventType': EventTypes.goalUpdated,
    'seq': 0,
    'globalSeq': globalSeq,
    'source': source,
    'payload': {
      'op': op,
      if (goal != null) 'goal': goal,
      if (tasks != null) 'tasks': tasks,
      if (progress != null) 'progress': progress,
      if (taskId != null) 'task_id': taskId,
    },
    'createdAt': '2026-09-28T10:11:12.345Z',
    if (transient) 'transient': true,
  });

  Map<String, dynamic> goalDto({String text = '把同步做稳'}) => {
    'id': 'goal_1',
    'group_id': 'grp_1',
    'goal_text': text,
    'status': 'active',
    'tasks_source': 'agent',
  };

  group('GoalUpdate.fromEvent', () {
    test('非 goal_updated 事件返回 null', () {
      final other = ChatEvent.fromJson({
        'eventId': 'e1',
        'groupId': 'grp_1',
        'eventType': EventTypes.groupUpdated,
        'payload': {'op': 'created'},
        'createdAt': '2026-09-28T10:11:12.345Z',
      });

      expect(GoalUpdate.fromEvent(other), isNull);
    });

    test('groupId 为空时丢弃（无法定位要刷新哪个对话）', () {
      expect(GoalUpdate.fromEvent(goalEvent(groupId: '')), isNull);
    });

    test('归一 op / groupId / source / 快照', () {
      final u = GoalUpdate.fromEvent(
        goalEvent(
          op: 'task_status',
          taskId: 't2',
          goal: goalDto(),
          tasks: [
            {'task_id': 't1', 'status': 'completed'},
            {'task_id': 't2', 'status': 'in_progress'},
          ],
          progress: {'total': 2, 'completed': 1},
        ),
      );

      expect(u, isNotNull);
      expect(u!.op, 'task_status');
      expect(u.groupId, 'grp_1');
      expect(u.source, 'user');
      expect(u.taskId, 't2');
      expect(u.tasks, hasLength(2));
      expect(u.progress?['total'], 2);
      expect(u.goalText, '把同步做稳');
      expect(u.goalStatus, 'active');
      expect(u.fromAgent, isFalse);
    });

    test('source=agent 时 fromAgent 为真（pigo 经 X-API-Key 改的任务）', () {
      final u = GoalUpdate.fromEvent(goalEvent(source: 'agent'));

      expect(u!.fromAgent, isTrue);
    });

    test('未知 op 不丢弃（服务端新增 op 时仍要刷新）', () {
      final u = GoalUpdate.fromEvent(goalEvent(op: 'task_something_new'));

      expect(u, isNotNull);
      expect(u!.op, 'task_something_new');
    });
  });

  group('GoalUpdate.snapshot（套进 ChatGroup.currentGoal）', () {
    test('形状为 {goal, tasks, progress}，与 GET /goals/current 同构', () {
      final u = GoalUpdate.fromEvent(
        goalEvent(
          goal: goalDto(),
          tasks: [
            {'task_id': 't1', 'status': 'completed'},
          ],
          progress: {'total': 1, 'completed': 1},
        ),
      )!;

      final snap = u.snapshot!;
      expect(snap.keys, containsAll(['goal', 'tasks', 'progress']));
      expect((snap['goal'] as Map)['goal_text'], '把同步做稳');
    });

    test('补 current_task_id：优先第一个 in_progress', () {
      // 服务端的 goalSnapshotDTO（group DTO 路径）会补该字段，但
      // emitGoalUpdated 走 goalToDTO 直出、不带它。不补会让「当前任务」
      // 高亮在事件刷新后消失。
      final u = GoalUpdate.fromEvent(
        goalEvent(
          goal: goalDto(),
          tasks: [
            {'task_id': 't1', 'status': 'pending'},
            {'task_id': 't2', 'status': 'in_progress'},
          ],
        ),
      )!;

      expect((u.snapshot!['goal'] as Map)['current_task_id'], 't2');
    });

    test('无 in_progress 时退到第一个 pending（对齐 goalSnapshotDTO）', () {
      final u = GoalUpdate.fromEvent(
        goalEvent(
          goal: goalDto(),
          tasks: [
            {'task_id': 't1', 'status': 'completed'},
            {'task_id': 't2', 'status': 'pending'},
            {'task_id': 't3', 'status': 'pending'},
          ],
        ),
      )!;

      expect((u.snapshot!['goal'] as Map)['current_task_id'], 't2');
    });

    test('无 in_progress 也无 pending 时不补该键', () {
      final u = GoalUpdate.fromEvent(
        goalEvent(
          goal: goalDto(),
          tasks: [
            {'task_id': 't1', 'status': 'completed'},
          ],
        ),
      )!;

      expect(
        (u.snapshot!['goal'] as Map).containsKey('current_task_id'),
        isFalse,
      );
    });

    test('goal 缺失时 snapshot 为 null（不得用空快照覆盖现有目标）', () {
      final u = GoalUpdate.fromEvent(goalEvent(tasks: const []))!;

      expect(u.snapshot, isNull);
    });

    test('progress 缺失时不硬塞 null 值', () {
      final u = GoalUpdate.fromEvent(goalEvent(goal: goalDto()))!;

      expect(u.snapshot!.containsKey('progress'), isFalse);
    });

    test('snapshot 不改动原始 goal map（不可变语义）', () {
      final dto = goalDto();
      final u = GoalUpdate.fromEvent(goalEvent(goal: dto, tasks: const []))!;

      u.snapshot;
      expect(dto.containsKey('current_task_id'), isFalse, reason: '不应就地修改事件载荷');
    });
  });

  group('ChatGroup.withCurrentGoal', () {
    ChatGroup base() => ChatGroup.fromJson({
      'id': 'grp_1',
      'user_id': 'usr_1',
      'title': '测试对话',
      'status': 'active',
      'goal': '旧列目标',
      'metadata': {
        'tts': {'enabled': true},
        'goal_gate': {'enabled': true, 'continue_until_done': true},
      },
      'created_at': '2024-03-05T08:09:10Z',
      'updated_at': '2024-03-05T08:09:10Z',
    });

    test('只替换 currentGoal，其余字段原样保留', () {
      final g = base();
      final next = g.withCurrentGoal({
        'goal': {'goal_text': '新目标'},
        'tasks': <Map<String, dynamic>>[],
      });

      expect(g.currentGoalText, '旧列目标', reason: '原对象不可变');
      expect(next.currentGoalText, '新目标');
      expect(next.id, 'grp_1');
      expect(next.title, '测试对话');
      expect(next.status, 'active');
      expect(next.ttsEnabled, isTrue, reason: '事件不携带 metadata，替换时不得丢失');
      expect(next.goalGateEnabled, isTrue, reason: '同上');
      expect(next.createdAt, g.createdAt);
    });

    test('传 null 可清空 goal（对齐服务端删除语义）', () {
      final g = base().withCurrentGoal({
        'goal': {'goal_text': 'x'},
      });
      expect(g.currentGoalText, 'x');

      final cleared = g.withCurrentGoal(null);
      expect(cleared.currentGoal, isNull);
      expect(
        cleared.currentGoalText,
        '旧列目标',
        reason: '结构化 goal 清空后退回旧列（与 currentGoalText 的优先级一致）',
      );
    });
  });
}
