import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [Goal] / [GoalTask] / [GoalProgress] 的解析契约测试。
///
/// ## 这个测试防的是什么
///
/// 1. **枚举白名单漂移**：`validGoalStatus` / `validTaskStatus` /
///    `validTaskOrigin` / `validTasksSource` / `validCompletionSemantics`
///    是服务端的校验白名单（Go `goal_api.go:1057-1097`）。客户端枚举写错一个
///    词（`cancelled` vs `canceled` 那类）就会把合法响应解析成 `unknown`，
///    界面显示「未知」而**不报错**。
/// 2. **`skipped` 计入完成**：`CountChatGoalTasks` 的口径是
///    `status IN ('completed','skipped')`。按 `status == 'completed'` 数会
///    少算，进度条永远差一截。
/// 3. **两个 id 不是同一个东西**：`:goal_id` 是行 id，`:task_id` 是 `TASK-NNN`。
///    `GoalTask` 同时持有 `id` 与 `taskId`，解析时串了就会拿行 id 去拼路径。
/// 4. **无 goal 是 200 不是错误**：服务端回 `{"goal": null, "tasks": [], ...}`。
void main() {
  /// `goalToDTO`（Go `goal_api.go:76`）的输出形状。
  Map<String, dynamic> goalJson({
    String status = 'active',
    String tasksSource = 'manual',
    Map<String, dynamic> extra = const {},
  }) => {
    'id': 'goal_1',
    'group_id': 'grp_1',
    'goal_text': '把 CI 修绿',
    'status': status,
    'tasks_source': tasksSource,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
    ...extra,
  };

  /// `taskToDTO`（Go `goal_api.go:125`）的输出形状。
  Map<String, dynamic> taskJson({
    String taskId = 'TASK-001',
    String status = 'pending',
    String origin = 'llm',
    bool editedByUser = false,
    Map<String, dynamic> extra = const {},
  }) => {
    'id': 'row_1',
    'goal_id': 'goal_1',
    'task_id': taskId,
    'order_index': 0,
    'title': '第一步',
    'description': '说明',
    'status': status,
    'origin': origin,
    'edited_by_user': editedByUser,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
    ...extra,
  };

  group('Goal 解析', () {
    test('基本字段与 snake_case 键名', () {
      final g = Goal.fromJson(goalJson());

      expect(g.id, 'goal_1');
      expect(g.groupId, 'grp_1');
      expect(g.goalText, '把 CI 修绿');
      expect(g.status, GoalStatus.active);
      expect(g.tasksSource, GoalTasksSource.manual);
      expect(g.createdAt.isUtc, isFalse, reason: '解析后转本地时区展示');
    });

    test('四种 goal 状态全部识别（服务端 validGoalStatus 白名单）', () {
      // 写成 GoalStatus.unknown 会让界面显示「未知」，且不报错。
      for (final (wire, expected) in [
        ('active', GoalStatus.active),
        ('completed', GoalStatus.completed),
        ('paused', GoalStatus.paused),
        ('archived', GoalStatus.archived),
      ]) {
        expect(
          Goal.fromJson(goalJson(status: wire)).status,
          expected,
          reason: 'status=$wire 未被识别',
        );
      }
    });

    test('认不出的 goal 状态落到 unknown（向前兼容，不抛）', () {
      expect(
        Goal.fromJson(goalJson(status: 'weird')).status,
        GoalStatus.unknown,
      );
    });

    test('三种 tasks_source 全部识别', () {
      for (final (wire, expected) in [
        ('llm_expand', GoalTasksSource.llmExpand),
        ('manual', GoalTasksSource.manual),
        ('imported', GoalTasksSource.imported),
      ]) {
        expect(
          Goal.fromJson(goalJson(tasksSource: wire)).tasksSource,
          expected,
          reason: 'tasks_source=$wire 未被识别',
        );
      }
    });

    test('可空字段缺失时为 null（服务端只在 Valid 时才写键）', () {
      final g = Goal.fromJson(goalJson());

      expect(g.sourceMarkdown, isNull);
      expect(g.gitCommit, isNull);
      expect(g.gitCommitAt, isNull);
      expect(g.expandedAt, isNull);
      expect(g.completedAt, isNull);
      expect(g.archivedAt, isNull);
      expect(g.currentTaskId, isNull);
    });

    test('可空字段存在时解析（含 UTC 时间戳转本地）', () {
      final g = Goal.fromJson(
        goalJson(
          extra: {
            'source_markdown': '# 计划',
            'git_commit': 'abc123',
            'git_commit_at': '2024-03-05T08:00:00Z',
            'expanded_at': '2024-03-05T09:00:00Z',
            'completed_at': '2024-03-06T09:00:00Z',
            'current_task_id': 'TASK-002',
          },
        ),
      );

      expect(g.sourceMarkdown, '# 计划');
      expect(g.gitCommit, 'abc123');
      expect(g.gitCommitAt, isNotNull);
      expect(g.expandedAt, isNotNull);
      expect(g.completedAt, isNotNull);
      expect(g.currentTaskId, 'TASK-002');
    });

    test('空串可空字段归一成 null（服务端 nullString 不写空串）', () {
      final g = Goal.fromJson(
        goalJson(extra: {'source_markdown': '', 'git_commit': ''}),
      );

      expect(g.sourceMarkdown, isNull);
      expect(g.gitCommit, isNull);
    });

    test('isActive 只在 active 时为真（paused/completed 都不推进）', () {
      expect(Goal.fromJson(goalJson()).isActive, isTrue);
      expect(Goal.fromJson(goalJson(status: 'paused')).isActive, isFalse);
      expect(Goal.fromJson(goalJson(status: 'completed')).isActive, isFalse);
      expect(Goal.fromJson(goalJson(status: 'archived')).isActive, isFalse);
    });

    test('缺 id / 时间戳时不崩（服务端异常响应兜底）', () {
      final g = Goal.fromJson(const {});

      expect(g.id, '');
      expect(g.goalText, '');
      expect(g.status, GoalStatus.unknown);
      // 时间戳缺失回落到 now()，不抛。
      expect(g.createdAt, isNotNull);
    });
  });

  group('GoalTask 解析', () {
    test('两个 id 分别落在 id 与 taskId（串了会拿行 id 去拼路径）', () {
      final t = GoalTask.fromJson(taskJson(taskId: 'TASK-007'));

      expect(t.id, 'row_1', reason: 'id 是 chat_goal_tasks.id（行 id）');
      expect(t.taskId, 'TASK-007', reason: 'taskId 是路径里要用的 TASK-NNN');
      expect(t.goalId, 'goal_1');
    });

    test('六种任务状态全部识别（服务端 validTaskStatus 白名单）', () {
      for (final (wire, expected) in [
        ('pending', GoalTaskStatus.pending),
        ('in_progress', GoalTaskStatus.inProgress),
        ('completed', GoalTaskStatus.completed),
        ('skipped', GoalTaskStatus.skipped),
        ('error_stopped', GoalTaskStatus.errorStopped),
        ('blocked', GoalTaskStatus.blocked),
      ]) {
        expect(
          GoalTask.fromJson(taskJson(status: wire)).status,
          expected,
          reason: 'status=$wire 未被识别',
        );
      }
    });

    test('认不出的任务状态落到 unknown', () {
      expect(
        GoalTask.fromJson(taskJson(status: 'weird')).status,
        GoalTaskStatus.unknown,
      );
    });

    test('三种 origin 全部识别', () {
      for (final (wire, expected) in [
        ('llm', GoalTaskOrigin.llm),
        ('manual', GoalTaskOrigin.manual),
        ('imported', GoalTaskOrigin.imported),
      ]) {
        expect(
          GoalTask.fromJson(taskJson(origin: wire)).origin,
          expected,
          reason: 'origin=$wire 未被识别',
        );
      }
    });

    test('edited_by_user 是布尔（服务端把 !=0 展平）', () {
      expect(GoalTask.fromJson(taskJson()).editedByUser, isFalse);
      expect(
        GoalTask.fromJson(taskJson(editedByUser: true)).editedByUser,
        isTrue,
      );
    });

    test('skipped 与 completed 都算完成（服务端口径，少算会让进度条差一截）', () {
      expect(GoalTaskStatus.completed.countsAsCompleted, isTrue);
      expect(GoalTaskStatus.skipped.countsAsCompleted, isTrue);
      expect(GoalTaskStatus.pending.countsAsCompleted, isFalse);
      expect(GoalTaskStatus.inProgress.countsAsCompleted, isFalse);
      expect(GoalTaskStatus.blocked.countsAsCompleted, isFalse);
      expect(GoalTaskStatus.errorStopped.countsAsCompleted, isFalse);
    });

    test('isOpen 是 countsAsCompleted 的补集', () {
      for (final s in GoalTaskStatus.values) {
        expect(s.isOpen, !s.countsAsCompleted, reason: '$s 的 isOpen 不自洽');
      }
    });

    test('removable = origin 为 llm 且未被人工编辑（resetForExpand 的判定）', () {
      // 服务端：if t.Origin == "llm" && t.EditedByUser == 0 → removable。
      expect(
        GoalTaskOrigin.llm.removable(editedByUser: false),
        isTrue,
        reason: 'LLM 产出且未编辑 → 可被覆盖',
      );
      expect(
        GoalTaskOrigin.llm.removable(editedByUser: true),
        isFalse,
        reason: '人工编辑过 → 必须保留',
      );
      expect(
        GoalTaskOrigin.manual.removable(editedByUser: false),
        isFalse,
        reason: '手工任务永不被覆盖',
      );
      expect(GoalTaskOrigin.imported.removable(editedByUser: false), isFalse);
    });

    test('completion_semantics 缺失 = null（不是 unknown）', () {
      // 服务端 NULL 表示「一次性」，但语义上与显式 one_shot 不同：
      // 客户端要能区分「没设」与「设成一次性」。
      expect(GoalTask.fromJson(taskJson()).completionSemantics, isNull);
    });

    test('completion_semantics 存在时解析两种值', () {
      expect(
        GoalTask.fromJson(taskJson(extra: {'completion_semantics': 'one_shot'}))
            .completionSemantics,
        GoalCompletionSemantics.oneShot,
      );
      expect(
        GoalTask.fromJson(taskJson(extra: {'completion_semantics': 'ongoing'}))
            .completionSemantics,
        GoalCompletionSemantics.ongoing,
      );
    });

    test('not_before 解析为本地时间，缺失为 null', () {
      final t = GoalTask.fromJson(
        taskJson(extra: {'not_before': '2024-03-05T08:00:00Z'}),
      );

      expect(t.notBefore, isNotNull);
      expect(t.notBefore!.isUtc, isFalse);
      expect(GoalTask.fromJson(taskJson()).notBefore, isNull);
    });

    test('isScheduledAfter 按时间锚点判定（未来才推迟）', () {
      final t = GoalTask.fromJson(
        taskJson(extra: {'not_before': '2024-03-05T08:00:00Z'}),
      );

      expect(t.isScheduledAfter(DateTime.utc(2024, 3, 5, 7)), isTrue);
      expect(t.isScheduledAfter(DateTime.utc(2024, 3, 5, 9)), isFalse);
      // 无锚点 = 立即可开始，永不被推迟。
      expect(
        GoalTask.fromJson(taskJson()).isScheduledAfter(DateTime.now()),
        isFalse,
      );
    });

    test('error_reason / blocked_by 缺失为 null，存在时原样保留', () {
      final plain = GoalTask.fromJson(taskJson());
      expect(plain.errorReason, isNull);
      expect(plain.blockedBy, isNull);

      final blocked = GoalTask.fromJson(
        taskJson(extra: {'error_reason': '编译失败', 'blocked_by': 'TASK-009'}),
      );
      expect(blocked.errorReason, '编译失败');
      // 服务端不校验引用是否存在，可能是已删任务。
      expect(blocked.blockedBy, 'TASK-009');
    });

    test('isCompleted / isBlocked / hasError 三个派生判定', () {
      expect(
        GoalTask.fromJson(taskJson(status: 'skipped')).isCompleted,
        isTrue,
      );
      expect(GoalTask.fromJson(taskJson(status: 'blocked')).isBlocked, isTrue);
      expect(
        GoalTask.fromJson(taskJson(status: 'error_stopped')).hasError,
        isTrue,
      );
      // 不互相串。
      expect(GoalTask.fromJson(taskJson(status: 'blocked')).hasError, isFalse);
      expect(
        GoalTask.fromJson(taskJson(status: 'blocked')).isCompleted,
        isFalse,
      );
    });

    test('order_index 容忍字符串形态（sqlite 有时给字符串）', () {
      expect(
        GoalTask.fromJson(taskJson(extra: {'order_index': '3'})).orderIndex,
        3,
      );
    });

    test('缺字段时不崩', () {
      final t = GoalTask.fromJson(const {});

      expect(t.id, '');
      expect(t.taskId, '');
      expect(t.orderIndex, 0);
      expect(t.status, GoalTaskStatus.unknown);
    });
  });

  group('GoalProgress 解析', () {
    Map<String, dynamic> progressJson({
      int total = 4,
      int completed = 1,
      int inProgress = 1,
      int blocked = 1,
      int errorStopped = 1,
      Map<String, dynamic> extra = const {},
    }) => {
      'total': total,
      'completed': completed,
      'in_progress': inProgress,
      'blocked': blocked,
      'error_stopped': errorStopped,
      'pending': total - completed - inProgress - blocked - errorStopped,
      'percent': total == 0 ? 0 : (completed * 100 / total).floor(),
      ...extra,
    };

    test('全字段解析', () {
      final p = GoalProgress.fromJson(progressJson());

      expect(p.total, 4);
      expect(p.completed, 1);
      expect(p.inProgress, 1);
      expect(p.blocked, 1);
      expect(p.errorStopped, 1);
      expect(p.pending, 0);
      expect(p.percent, 25);
    });

    test('completed 已含 skipped（服务端 COUNT 把两者合并，客户端不再加）', () {
      // 2 个 completed + 1 个 skipped 在服务端算 completed=3。
      final p = GoalProgress.fromJson(
        progressJson(
          total: 3,
          completed: 3,
          inProgress: 0,
          blocked: 0,
          errorStopped: 0,
        ),
      );

      expect(p.completed, 3);
      expect(p.percent, 100);
    });

    test('pending 缺失时客户端自行派生（口径与 CountChatGoalTasks 一致）', () {
      final p = GoalProgress.fromJson({
        'total': 5,
        'completed': 2,
        'in_progress': 1,
        'blocked': 1,
        'error_stopped': 0,
        // pending 故意不给。
      });

      expect(p.pending, 1, reason: '5-2-1-1-0 = 1');
    });

    test('空任务时 total=0、ratio=0（不做除零）', () {
      final p = GoalProgress.fromJson(const {});

      expect(p.total, 0);
      expect(p.isEmpty, isTrue);
      expect(p.ratio, 0);
    });

    test('ratio 是 0.0–1.0 的浮点（进度条用）', () {
      final p = GoalProgress.fromJson(progressJson());

      expect(p.ratio, 0.25);
    });

    test('needsAttention 在 blocked 或 error_stopped 时亮（要人工介入）', () {
      expect(
        GoalProgress.fromJson(progressJson(blocked: 0, errorStopped: 0))
            .needsAttention,
        isFalse,
      );
      expect(
        GoalProgress.fromJson(progressJson(errorStopped: 0)).needsAttention,
        isTrue,
        reason: 'blocked=1',
      );
      expect(
        GoalProgress.fromJson(progressJson(blocked: 0)).needsAttention,
        isTrue,
        reason: 'error_stopped=1',
      );
    });

    test('GoalProgress.empty 是零值', () {
      expect(GoalProgress.empty.total, 0);
      expect(GoalProgress.empty.isEmpty, isTrue);
      expect(GoalProgress.empty.needsAttention, isFalse);
    });
  });

  group('GoalSnapshot：无 goal 是正常状态（200），不是错误', () {
    test('goal:null + tasks:[] + progress:null 解析成空快照', () {
      final snap = GoalSnapshot.fromJson(const {
        'goal': null,
        'tasks': <dynamic>[],
        'progress': null,
      });

      expect(snap.hasGoal, isFalse);
      expect(snap.goal, isNull);
      expect(snap.tasks, isEmpty);
      expect(snap.progress, isNull);
      // 调用方不得用 hasGoal 判「请求是否成功」。
      expect(snap.hasNoTasks, isTrue);
    });

    test('三段齐全时逐段解析', () {
      final snap = GoalSnapshot.fromJson({
        'goal': goalJson(),
        'tasks': [
          taskJson(),
          taskJson(taskId: 'TASK-002', status: 'completed'),
        ],
        'progress': {
          'total': 2,
          'completed': 1,
          'in_progress': 0,
          'blocked': 0,
          'error_stopped': 0,
          'pending': 1,
          'percent': 50,
        },
      });

      expect(snap.hasGoal, isTrue);
      expect(snap.goal!.goalText, '把 CI 修绿');
      expect(snap.tasks, hasLength(2));
      expect(snap.tasks.last.status, GoalTaskStatus.completed);
      expect(snap.progress!.percent, 50);
      expect(snap.hasNoTasks, isFalse);
    });

    test('有 goal 但任务未展开时 hasNoTasks 为真（不是「无 goal」）', () {
      final snap = GoalSnapshot.fromJson({
        'goal': goalJson(),
        'tasks': <dynamic>[],
        'progress': null,
      });

      expect(snap.hasGoal, isTrue);
      expect(snap.hasNoTasks, isTrue);
    });

    test('tasks 里有非 map 元素时跳过（不崩）', () {
      final snap = GoalSnapshot.fromJson({
        'goal': goalJson(),
        'tasks': [taskJson(), 'garbage', 42],
        'progress': <String, dynamic>{},
      });

      expect(snap.tasks, hasLength(1));
    });

    test('GoalSnapshot.empty 是常量零值', () {
      expect(GoalSnapshot.empty.hasGoal, isFalse);
      expect(GoalSnapshot.empty.tasks, isEmpty);
      expect(GoalSnapshot.empty.progress, isNull);
    });

    test('完全空的 json 不崩', () {
      final snap = GoalSnapshot.fromJson(const {});

      expect(snap.hasGoal, isFalse);
      expect(snap.tasks, isEmpty);
    });
  });

  group('GoalResetForExpandResult 解析', () {
    test('removed / preserved / note 三段', () {
      final r = GoalResetForExpandResult.fromJson(const {
        'removed': ['TASK-001', 'TASK-002'],
        'preserved': ['TASK-003'],
        'note': 'preserved 任务必须原样保留',
      });

      expect(r.removed, ['TASK-001', 'TASK-002']);
      expect(r.preserved, ['TASK-003']);
      expect(r.note, contains('原样保留'));
    });

    test('两份清单缺失时为空列表（不是 null）', () {
      final r = GoalResetForExpandResult.fromJson(const {});

      expect(r.removed, isEmpty);
      expect(r.preserved, isEmpty);
      expect(r.note, isNull);
    });

    test('清单里的非字符串元素被跳过（不崩）', () {
      final r = GoalResetForExpandResult.fromJson(const {
        'removed': ['TASK-001', 42, null, 'TASK-002'],
      });

      expect(r.removed, ['TASK-001', 'TASK-002']);
    });

    test('全删时 preserved 为空（人工任务一个都没有）', () {
      final r = GoalResetForExpandResult.fromJson(const {
        'removed': ['TASK-001'],
        'preserved': <dynamic>[],
      });

      expect(r.removed, hasLength(1));
      expect(r.preserved, isEmpty);
    });
  });

  group('枚举 label 与 wire 的自洽性', () {
    test('每个非 unknown 枚举都有非空 wire 与 label', () {
      for (final v in GoalStatus.values) {
        if (v == GoalStatus.unknown) continue;
        expect(v.wire, isNotEmpty, reason: '$v 缺 wire');
        expect(v.label, isNotEmpty, reason: '$v 缺 label');
      }
      for (final v in GoalTaskStatus.values) {
        if (v == GoalTaskStatus.unknown) continue;
        expect(v.wire, isNotEmpty);
        expect(v.label, isNotEmpty);
      }
      for (final v in GoalTaskOrigin.values) {
        if (v == GoalTaskOrigin.unknown) continue;
        expect(v.wire, isNotEmpty);
        expect(v.label, isNotEmpty);
      }
      for (final v in GoalTasksSource.values) {
        if (v == GoalTasksSource.unknown) continue;
        expect(v.wire, isNotEmpty);
        expect(v.label, isNotEmpty);
      }
      for (final v in GoalCompletionSemantics.values) {
        if (v == GoalCompletionSemantics.unknown) continue;
        expect(v.wire, isNotEmpty);
        expect(v.label, isNotEmpty);
      }
    });

    test('unknown 的 wire 是空串（调用方据此跳过写请求）', () {
      expect(GoalStatus.unknown.wire, '');
      expect(GoalTaskStatus.unknown.wire, '');
      expect(GoalTaskOrigin.unknown.wire, '');
      expect(GoalTasksSource.unknown.wire, '');
      expect(GoalCompletionSemantics.unknown.wire, '');
    });

    test('fromServer 与 wire 互逆（每个非 unknown 值）', () {
      for (final v in GoalStatus.values) {
        if (v == GoalStatus.unknown) continue;
        expect(GoalStatus.fromServer(v.wire), v, reason: '$v 不互逆');
      }
      for (final v in GoalTaskStatus.values) {
        if (v == GoalTaskStatus.unknown) continue;
        expect(GoalTaskStatus.fromServer(v.wire), v, reason: '$v 不互逆');
      }
      for (final v in GoalTaskOrigin.values) {
        if (v == GoalTaskOrigin.unknown) continue;
        expect(GoalTaskOrigin.fromServer(v.wire), v, reason: '$v 不互逆');
      }
      for (final v in GoalTasksSource.values) {
        if (v == GoalTasksSource.unknown) continue;
        expect(GoalTasksSource.fromServer(v.wire), v, reason: '$v 不互逆');
      }
      for (final v in GoalCompletionSemantics.values) {
        if (v == GoalCompletionSemantics.unknown) continue;
        expect(GoalCompletionSemantics.fromServer(v.wire), v, reason: '$v 不互逆');
      }
    });

    test('null / 空串 / 认不出的值都落到 unknown（不抛）', () {
      expect(GoalStatus.fromServer(null), GoalStatus.unknown);
      expect(GoalStatus.fromServer(''), GoalStatus.unknown);
      expect(GoalTaskStatus.fromServer('nope'), GoalTaskStatus.unknown);
      expect(GoalTaskOrigin.fromServer(null), GoalTaskOrigin.unknown);
      expect(GoalTasksSource.fromServer(''), GoalTasksSource.unknown);
      expect(
        GoalCompletionSemantics.fromServer('sometimes'),
        GoalCompletionSemantics.unknown,
      );
    });
  });

  group('与轮次状态值域不混用（两套「已完成」拼写相同、集合不同）', () {
    test('任务状态没有 queued/running/cancelled（那是轮次的值域）', () {
      final wires = GoalTaskStatus.values.map((v) => v.wire).toSet();

      expect(wires.contains('queued'), isFalse);
      expect(wires.contains('running'), isFalse);
      // 轮次那边是英式 cancelled，任务这边根本没有取消态。
      expect(wires.contains('cancelled'), isFalse);
      expect(wires.contains('canceled'), isFalse);
    });

    test('两套枚举都有 completed，但含义各自独立', () {
      expect(GoalTaskStatus.completed.wire, 'completed');
      expect(GoalTaskStatus.fromServer('completed'), GoalTaskStatus.completed);
    });
  });
}
