import 'dart:convert';
import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `GoalApi` 的契约测试。
///
/// ## 为什么真起一个本地 HTTP server 而不是用 mock 适配器
///
/// 本组端点有**三类只靠 mock 抓不到的错**：
///
/// 1. **前缀漂移**：同目录的 `HabitApi` 走 `/api/habits*`，顺手把 goal 写成
///    `/api/chat/goals/...` 完全符合「直觉」，而该路径不存在。mock 适配器按
///    注册路径匹配，写错路径的测试照样「通过」（断言的是同一个错值）。
/// 2. **静态段 vs 参数段**：`POST /chat/goals/:id/tasks/reorder` 与
///    `POST /chat/goals/:id/tasks`、以及 `PUT .../tasks/:tid/status` 三者同层。
///    路径拼错不会解析失败，只会 404 或命中另一个端点。
/// 3. **HTTP 方法**：`switchGoal` 与 `setTaskStatus` 服务端注册的是 **PUT**，
///    写成 PATCH 会 404。mock 适配器要分别注册 onPut/onPatch 才能发现，
///    真 server 直接看 `req.method`。
///
/// 真起 server 能一次确认「路径 + 方法 + body」三者，且断言的就是服务端会
/// 收到的那串字节。
///
/// ## 两个 id 的坑（本文件反复锁）
///
/// `:goal_id` 是 `chat_goals.id`（行 id），`:task_id` 是
/// `chat_goal_tasks.task_id`（`TASK-NNN`）。两者**不同列**，传错 404。
void main() {
  late HttpServer server;
  late GoalApi api;
  late List<String> paths;
  late List<String> methods;
  late List<String> bodies;

  /// 下一个响应体（默认 200 + 空对象）。
  late Object? nextBody;
  late int nextStatus;

  setUp(() async {
    paths = [];
    methods = [];
    bodies = [];
    nextBody = const <String, dynamic>{};
    nextStatus = 200;
    // 端口 0 = 内核分配空闲端口（避免 CI 上固定端口冲突）。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = GoalApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
    server.listen((req) async {
      paths.add(req.uri.path);
      methods.add(req.method);
      bodies.add(await utf8.decodeStream(req));
      req.response
        ..statusCode = nextStatus
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(nextBody));
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  /// 断言「只发了一次请求」并返回解码后的 body。
  Map<String, dynamic> onlyBody() {
    expect(paths, hasLength(1));
    final raw = bodies.single;
    return raw.isEmpty
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  group('goal：路径、方法与前缀（前缀是 /chat 不是 /api）', () {
    test('createGoal → POST /chat/groups/:id/goals，body 带 goal_text', () async {
      nextStatus = 201;
      nextBody = {
        'goal': {
          'id': 'goal_1',
          'group_id': 'grp_1',
          'goal_text': '把 CI 修绿',
          'status': 'active',
          'tasks_source': 'manual',
          'created_at': '2024-03-05T08:00:00Z',
          'updated_at': '2024-03-05T08:00:00Z',
        },
      };

      final goal = await api.createGoal('grp_1', goalText: '把 CI 修绿');

      expect(methods, ['POST']);
      expect(paths, ['/chat/groups/grp_1/goals']);
      expect(onlyBody(), {'goal_text': '把 CI 修绿'});
      expect(goal.id, 'goal_1');
      expect(goal.goalText, '把 CI 修绿');
      expect(goal.status, GoalStatus.active);
    });

    test('前缀不是 /api（同目录 HabitApi 是 /api/habits，别顺手照抄）', () async {
      await api.getCurrentGoal('grp_1');

      expect(paths.single, startsWith('/chat/'));
      expect(paths.single, isNot(startsWith('/api/')));
    });

    test('createGoal 只在显式传入时下发 tasks_source（缺省交给服务端）', () async {
      nextStatus = 201;
      nextBody = {'goal': <String, dynamic>{}};

      await api.createGoal('grp_1', goalText: 'x');

      expect(onlyBody().containsKey('tasks_source'), isFalse);
    });

    test('createGoal 显式传 tasksSource 时发 wire 值 llm_expand', () async {
      nextStatus = 201;
      nextBody = {'goal': <String, dynamic>{}};

      await api.createGoal(
        'grp_1',
        goalText: 'x',
        tasksSource: GoalTasksSource.llmExpand,
      );

      expect(onlyBody()['tasks_source'], 'llm_expand');
    });

    test('listGoals → GET /chat/groups/:id/goals?limit=，解析 items', () async {
      nextBody = {
        'items': [
          {
            'id': 'goal_1',
            'group_id': 'grp_1',
            'goal_text': 'A',
            'status': 'active',
            'tasks_source': 'manual',
          },
          {
            'id': 'goal_2',
            'group_id': 'grp_1',
            'goal_text': 'B',
            'status': 'archived',
            'tasks_source': 'llm_expand',
          },
        ],
      };

      final goals = await api.listGoals('grp_1');

      expect(methods, ['GET']);
      expect(paths, ['/chat/groups/grp_1/goals']);
      expect(goals.map((g) => g.id), ['goal_1', 'goal_2']);
      expect(goals.last.status, GoalStatus.archived);
      expect(goals.last.tasksSource, GoalTasksSource.llmExpand);
    });

    test('getCurrentGoal → GET .../goals/current，无 goal 时返回空快照不抛', () async {
      // 服务端无 current goal 时回 200 + goal:null（正常状态，不是错误）。
      nextBody = {'goal': null, 'tasks': <dynamic>[], 'progress': null};

      final snap = await api.getCurrentGoal('grp_1');

      expect(paths, ['/chat/groups/grp_1/goals/current']);
      expect(snap.hasGoal, isFalse);
      expect(snap.goal, isNull);
      expect(snap.tasks, isEmpty);
      expect(snap.progress, isNull);
    });

    test('getCurrentGoal 解析 goal + tasks + progress 三段', () async {
      nextBody = {
        'goal': {
          'id': 'goal_1',
          'group_id': 'grp_1',
          'goal_text': '目标',
          'status': 'active',
          'tasks_source': 'manual',
        },
        'tasks': [
          {
            'id': 'row_1',
            'goal_id': 'goal_1',
            'task_id': 'TASK-001',
            'order_index': 0,
            'title': '第一步',
            'description': '',
            'status': 'pending',
            'origin': 'llm',
            'edited_by_user': false,
          },
        ],
        'progress': {
          'total': 1,
          'completed': 0,
          'in_progress': 0,
          'blocked': 0,
          'error_stopped': 0,
          'pending': 1,
          'percent': 0,
        },
      };

      final snap = await api.getCurrentGoal('grp_1');

      expect(snap.goal!.id, 'goal_1');
      expect(snap.tasks.single.taskId, 'TASK-001');
      expect(snap.tasks.single.status, GoalTaskStatus.pending);
      expect(snap.progress!.total, 1);
      expect(snap.progress!.pending, 1);
    });

    test(
      'switchGoal → PUT .../goals/current（不是 PATCH），body 只有 goal_id',
      () async {
        nextBody = {
          'goal': {
            'id': 'goal_9',
            'group_id': 'grp_1',
            'goal_text': '切回来的',
            'status': 'active',
            'tasks_source': 'manual',
          },
        };

        final goal = await api.switchGoal('grp_1', 'goal_9');

        // 写成 PATCH 会 404：服务端注册的是 PUT。
        expect(methods, ['PUT']);
        expect(paths, ['/chat/groups/grp_1/goals/current']);
        // 只传 goal_id：切指针不改内容。
        expect(onlyBody(), {'goal_id': 'goal_9'});
        expect(goal.id, 'goal_9');
      },
    );

    test('updateGoalStatus → PATCH /chat/goals/:goal_id（无 group_id）', () async {
      nextBody = {
        'goal': {
          'id': 'goal_1',
          'group_id': 'grp_1',
          'goal_text': 'x',
          'status': 'completed',
          'tasks_source': 'manual',
        },
      };

      final goal = await api.updateGoalStatus('goal_1', GoalStatus.completed);

      // 服务端注释：goal 状态变更不需要 group_id，与任务路由保持同一形状。
      expect(methods, ['PATCH']);
      expect(paths, ['/chat/goals/goal_1']);
      expect(onlyBody(), {'status': 'completed'});
      expect(goal.status, GoalStatus.completed);
    });

    test('updateGoalStatus 拒绝 unknown（服务端 validGoalStatus 会 400）', () async {
      await expectLater(
        api.updateGoalStatus('goal_1', GoalStatus.unknown),
        throwsA(isA<ArgumentError>()),
      );
      // 拦在客户端：不该发请求。
      expect(paths, isEmpty);
    });
  });

  group('task：路径与两个 id（行 id vs TASK-NNN）', () {
    test('listTasks → GET /chat/goals/:id/tasks，同时拿到 progress', () async {
      nextBody = {
        'items': [
          {
            'id': 'row_1',
            'goal_id': 'goal_1',
            'task_id': 'TASK-001',
            'order_index': 0,
            'title': 'A',
            'description': '',
            'status': 'completed',
            'origin': 'llm',
            'edited_by_user': false,
          },
          {
            'id': 'row_2',
            'goal_id': 'goal_1',
            'task_id': 'TASK-002',
            'order_index': 1,
            'title': 'B',
            'description': '',
            'status': 'skipped',
            'origin': 'llm',
            'edited_by_user': false,
          },
        ],
        'progress': {
          'total': 2,
          'completed': 2,
          'in_progress': 0,
          'blocked': 0,
          'error_stopped': 0,
          'pending': 0,
          'percent': 100,
        },
      };

      final r = await api.listTasks('goal_1');

      expect(paths, ['/chat/goals/goal_1/tasks']);
      expect(r.items, hasLength(2));
      // skipped 计入完成（服务端 CountChatGoalTasks 的口径）。
      expect(r.progress!.completed, 2);
      expect(r.progress!.percent, 100);
      expect(r.progress!.needsAttention, isFalse);
    });

    test('listTasks 的 progress 不被 unwrapItems 丢掉', () async {
      nextBody = {
        'items': <dynamic>[],
        'progress': {
          'total': 3,
          'completed': 1,
          'in_progress': 1,
          'blocked': 1,
          'error_stopped': 0,
          'pending': 0,
          'percent': 33,
        },
      };

      final r = await api.listTasks('goal_1');

      expect(r.items, isEmpty);
      expect(r.progress, isNotNull, reason: '裸 List 返回会丢掉 progress');
      expect(r.progress!.blocked, 1);
      expect(r.progress!.needsAttention, isTrue);
    });

    test('createTask → POST /chat/goals/:id/tasks，body 字段名逐字对齐', () async {
      nextStatus = 201;
      nextBody = {
        'task': {
          'id': 'row_1',
          'goal_id': 'goal_1',
          'task_id': 'TASK-003',
          'order_index': 2,
          'title': '新任务',
          'description': '说明',
          'status': 'pending',
          'origin': 'manual',
          'edited_by_user': false,
        },
      };

      final task = await api.createTask(
        'goal_1',
        title: '新任务',
        description: '说明',
        origin: GoalTaskOrigin.manual,
        status: GoalTaskStatus.pending,
        orderIndex: 2,
        phase: 'P1',
      );

      expect(methods, ['POST']);
      expect(paths, ['/chat/goals/goal_1/tasks']);
      expect(onlyBody(), {
        'title': '新任务',
        'description': '说明',
        'origin': 'manual',
        'status': 'pending',
        'order_index': 2,
        'phase': 'P1',
      });
      expect(task.taskId, 'TASK-003');
    });

    test('createTask 缺省时不发 task_id（让服务端生成 TASK-NNN）', () async {
      nextStatus = 201;
      nextBody = {'task': <String, dynamic>{}};

      await api.createTask('goal_1', title: 'x');

      expect(onlyBody().containsKey('task_id'), isFalse);
    });

    test(
      'updateTask → PATCH /chat/goals/:id/tasks/:task_id（用 TASK-NNN）',
      () async {
        nextBody = {
          'task': {
            'id': 'row_1',
            'goal_id': 'goal_1',
            'task_id': 'TASK-007',
            'order_index': 0,
            'title': '改过',
            'description': '',
            'status': 'pending',
            'origin': 'llm',
            'edited_by_user': true,
          },
        };

        final task = await api.updateTask('goal_1', 'TASK-007', title: '改过');

        expect(methods, ['PATCH']);
        // 路径里是 TASK-NNN（task_id 列），不是行 id row_1。
        expect(paths, ['/chat/goals/goal_1/tasks/TASK-007']);
        expect(onlyBody(), {'title': '改过'});
        expect(task.editedByUser, isTrue);
      },
    );

    test('updateTask 空串 = 清除时间锚点（全量覆盖语义，与「不改」不同）', () async {
      nextBody = {'task': <String, dynamic>{}};

      await api.updateTask('goal_1', 'TASK-001', notBefore: '');

      // 必须发出空串（服务端据此转 NULL）；漏掉这个键就变成「不改」。
      expect(onlyBody().containsKey('not_before'), isTrue);
      expect(onlyBody()['not_before'], '');
    });

    test('deleteTask → DELETE /chat/goals/:id/tasks/:task_id', () async {
      nextBody = {'deleted': true};

      await api.deleteTask('goal_1', 'TASK-002');

      expect(methods, ['DELETE']);
      expect(paths, ['/chat/goals/goal_1/tasks/TASK-002']);
      // DELETE 无 body。
      expect(bodies.single, isEmpty);
    });

    test('deleteTask 对 404 抛错（4xx 不抛 DioException，必须补判）', () async {
      nextStatus = 404;
      nextBody = {'error': 'task 不存在'};

      await expectLater(
        api.deleteTask('goal_1', 'TASK-404'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('task 不存在')),
        ),
      );
    });

    test(
      'setTaskStatus → PUT .../tasks/:tid/status（不是 PATCH），回带 progress',
      () async {
        nextBody = {
          'task': {
            'id': 'row_1',
            'goal_id': 'goal_1',
            'task_id': 'TASK-001',
            'order_index': 0,
            'title': 'A',
            'description': '',
            'status': 'completed',
            'origin': 'llm',
            'edited_by_user': false,
          },
          'progress': {
            'total': 1,
            'completed': 1,
            'in_progress': 0,
            'blocked': 0,
            'error_stopped': 0,
            'pending': 0,
            'percent': 100,
          },
        };

        final r = await api.setTaskStatus(
          'goal_1',
          'TASK-001',
          GoalTaskStatus.completed,
        );

        // 写成 PATCH 会 404：服务端注册的是 PUT。
        expect(methods, ['PUT']);
        expect(paths, ['/chat/goals/goal_1/tasks/TASK-001/status']);
        expect(onlyBody(), {'status': 'completed'});
        expect(r.task.status, GoalTaskStatus.completed);
        // 服务端顺带回带更新后的进度，无需再拉一次列表。
        expect(r.progress!.percent, 100);
      },
    );

    test('setTaskStatus 的 error_reason 只在显式传入时下发', () async {
      nextBody = {'task': <String, dynamic>{}};

      await api.setTaskStatus(
        'goal_1',
        'TASK-001',
        GoalTaskStatus.errorStopped,
        errorReason: '编译失败',
      );

      expect(onlyBody(), {'status': 'error_stopped', 'error_reason': '编译失败'});
    });

    test('setTaskStatus 不传 errorReason 时不带该键（切到已完成时服务端会清空）', () async {
      nextBody = {'task': <String, dynamic>{}};

      await api.setTaskStatus('goal_1', 'TASK-001', GoalTaskStatus.completed);

      expect(onlyBody().containsKey('error_reason'), isFalse);
    });

    test('setTaskStatus 拒绝 unknown', () async {
      await expectLater(
        api.setTaskStatus('goal_1', 'TASK-001', GoalTaskStatus.unknown),
        throwsA(isA<ArgumentError>()),
      );
      expect(paths, isEmpty);
    });

    test(
      'reorderTasks → POST .../tasks/reorder，body 是 task_ids 完整清单',
      () async {
        nextBody = {
          'items': [
            {
              'id': 'row_2',
              'goal_id': 'goal_1',
              'task_id': 'TASK-002',
              'order_index': 0,
              'title': 'B',
              'description': '',
              'status': 'pending',
              'origin': 'llm',
              'edited_by_user': true,
            },
            {
              'id': 'row_1',
              'goal_id': 'goal_1',
              'task_id': 'TASK-001',
              'order_index': 1,
              'title': 'A',
              'description': '',
              'status': 'pending',
              'origin': 'llm',
              'edited_by_user': true,
            },
          ],
        };

        final items = await api.reorderTasks('goal_1', [
          'TASK-002',
          'TASK-001',
        ]);

        expect(methods, ['POST']);
        // 路径末段是静态 `reorder`，不是某个 task_id。
        expect(paths, ['/chat/goals/goal_1/tasks/reorder']);
        expect(onlyBody(), {
          'task_ids': ['TASK-002', 'TASK-001'],
        });
        // 服务端返回重排后的完整列表（按新 order_index）。
        expect(items.map((t) => t.taskId), ['TASK-002', 'TASK-001']);
      },
    );

    test('reorder 路径不含 task_id 段（静态段与参数段同层，拼错不报错只 404）', () async {
      nextBody = {'items': <dynamic>[]};

      await api.reorderTasks('goal_1', ['TASK-001']);

      expect(paths.single, endsWith('/tasks/reorder'));
      // 若把 reorder 当成 :task_id 会变成 .../tasks/reorder/status 之类。
      expect(paths.single, isNot(contains('/status')));
      // ['', 'chat', 'goals', 'goal_1', 'tasks', 'reorder'] —— 末段是静态段。
      expect(paths.single.split('/').length, 6);
    });

    test('reorderTasks 拒绝空清单（服务端 binding 对空数组放行，会白发一次）', () async {
      await expectLater(
        api.reorderTasks('goal_1', const []),
        throwsA(isA<ArgumentError>()),
      );
      expect(paths, isEmpty);
    });

    test('resetForExpand → POST .../tasks/reset-for-expand，解析两份清单', () async {
      nextBody = {
        'removed': ['TASK-001', 'TASK-002'],
        'preserved': ['TASK-003'],
        'note': 'preserved 任务必须原样保留',
      };

      final r = await api.resetForExpand('goal_1');

      expect(methods, ['POST']);
      expect(paths, ['/chat/goals/goal_1/tasks/reset-for-expand']);
      expect(r.removed, ['TASK-001', 'TASK-002']);
      expect(r.preserved, ['TASK-003']);
      expect(r.note, contains('原样保留'));
    });

    test('reset-for-expand 与 reorder 是两个不同的静态段（不能互相顶替）', () async {
      nextBody = {'removed': <dynamic>[], 'preserved': <dynamic>[]};

      await api.resetForExpand('goal_1');

      expect(paths.single, endsWith('/tasks/reset-for-expand'));
      expect(paths.single, isNot(endsWith('/tasks/reorder')));
    });
  });

  group('错误处理与请求体形状', () {
    test('createTask 的 409 抛错并带服务端原因（4xx 不抛 DioException）', () async {
      nextStatus = 409;
      nextBody = {'error': 'task_id 已存在: TASK-001'};

      await expectLater(
        api.createTask('goal_1', taskId: 'TASK-001', title: 'x'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.message, 'message', contains('已存在')),
        ),
      );
    });

    test('400 tasks_source 非法 会浮出为 HttpError（不静默成功）', () async {
      nextStatus = 400;
      nextBody = {'error': 'tasks_source 非法'};

      await expectLater(
        api.createGoal('grp_1', goalText: 'x'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });

    test('formatNotBefore 发 UTC RFC3339（服务端 parseNotBefore 接受该格式）', () {
      final s = GoalApi.formatNotBefore(DateTime.utc(2024, 3, 5, 8, 9, 10));

      expect(s, '2024-03-05T08:09:10Z');
    });

    test('formatNotBefore 把本地时间转成 UTC 再发（避免时区歧义）', () {
      final local = DateTime(2024, 3, 5, 8, 9, 10);
      final s = GoalApi.formatNotBefore(local);

      expect(s, endsWith('Z'));
      expect(
        DateTime.parse(s).isAtSameMomentAs(local),
        isTrue,
        reason: '转换必须保时刻，只改表示',
      );
    });

    test('createTask 的 not_before 原样下发调用方给的串', () async {
      nextStatus = 201;
      nextBody = {'task': <String, dynamic>{}};

      await api.createTask(
        'goal_1',
        title: 'x',
        notBefore: GoalApi.formatNotBefore(DateTime.utc(2024, 3, 5, 8, 9, 10)),
      );

      expect(onlyBody()['not_before'], '2024-03-05T08:09:10Z');
    });

    test('createTask 拒绝 unknown 枚举（不发请求）', () async {
      await expectLater(
        api.createTask('goal_1', title: 'x', status: GoalTaskStatus.unknown),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        api.createTask('goal_1', title: 'x', origin: GoalTaskOrigin.unknown),
        throwsA(isA<ArgumentError>()),
      );
      expect(paths, isEmpty);
    });
  });
}
