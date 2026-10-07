import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// [GoalTasksPanel] 的渲染与交互测试。
///
/// ## 这个测试防的是什么
///
/// 1. **两个 id 传错**：`setTaskStatus` / `deleteTask` 的路径参数是
///    `TASK-NNN`（`task_id` 列），不是 `chat_goal_tasks.id` 行 id。传行 id
///    服务端 404——而面板会显示「操作失败」，看起来像网络问题。
/// 2. **重排只传增量**：服务端不校验清单完整性（`for i, tid := range
///    body.TaskIDs`），只传「移动了哪一条」会让未列出的任务保持旧
///    `order_index`，与已写的新值撞号，顺序变得不确定。故断言**整份顺序**。
/// 3. **未注入回调时仍渲染操作入口**：禁用按钮会让用户以为「本端支持但暂时
///    不可用」，而真相是这一端没装配该能力。
/// 4. **勾选语义**：勾选 = `completed`，取消 = `pending`（不是还原成
///    `skipped`——没有「上次是什么」的记录）。
void main() {
  /// `taskToDTO`（Go `goal_api.go:125`）的形状。
  GoalTask task(
    String taskId, {
    String title = '',
    String status = 'pending',
    String origin = 'llm',
    bool editedByUser = false,
    int orderIndex = 0,
    Map<String, dynamic> extra = const {},
  }) => GoalTask.fromJson({
    'id': 'row_$taskId',
    'goal_id': 'goal_1',
    'task_id': taskId,
    'order_index': orderIndex,
    'title': title.isEmpty ? '任务 $taskId' : title,
    'description': '',
    'status': status,
    'origin': origin,
    'edited_by_user': editedByUser,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:00:00Z',
    ...extra,
  });

  GoalSnapshot snapshot({
    List<GoalTask> tasks = const [],
    Map<String, dynamic>? progress,
    String? goalText = '把 CI 修绿',
  }) {
    // 进度总是给出（服务端两条路径都带它）。skipped 计入 completed、
    // blocked / error_stopped 不计——与 CountChatGoalTasks 同口径。
    final completed = tasks.where((t) => t.isCompleted).length;
    final blocked = tasks.where((t) => t.isBlocked).length;
    final errorStopped = tasks.where((t) => t.hasError).length;
    return GoalSnapshot(
      goal: goalText == null
          ? null
          : Goal.fromJson({
              'id': 'goal_1',
              'group_id': 'grp_1',
              'goal_text': goalText,
              'status': 'active',
              'tasks_source': 'manual',
              'created_at': '2024-03-05T08:00:00Z',
              'updated_at': '2024-03-05T08:00:00Z',
            }),
      tasks: tasks,
      progress: GoalProgress.fromJson({
        'total': tasks.length,
        'completed': completed,
        'in_progress': 0,
        'blocked': blocked,
        'error_stopped': errorStopped,
        'pending': tasks.length - completed - blocked - errorStopped,
        'percent': tasks.isEmpty ? 0 : completed * 100 ~/ tasks.length,
        ...?progress,
      }),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required GoalSnapshot snap,
    SetGoalTaskStatus? onSetStatus,
    CreateGoalTask? onCreate,
    UpdateGoalTask? onUpdateTask,
    DeleteGoalTask? onDelete,
    ReorderGoalTasks? onReorder,
    ResetGoalTasksForExpand? onResetForExpand,
    ReloadGoalTasks? onReload,
    bool busy = false,
    bool showHeader = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalTasksPanel(
            snapshot: snap,
            onSetStatus: onSetStatus,
            onCreate: onCreate,
            onUpdateTask: onUpdateTask,
            onDelete: onDelete,
            onReorder: onReorder,
            onResetForExpand: onResetForExpand,
            onReload: onReload,
            busy: busy,
            showHeader: showHeader,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('渲染：清单、状态、来源、进度', () {
    testWidgets('列出任务并按 TASK-NNN 建 key', (t) async {
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', title: '修编译'),
            task('TASK-002', title: '补测试'),
          ],
        ),
      );

      expect(find.byKey(const ValueKey('goal-tasks-list')), findsOneWidget);
      expect(find.text('修编译'), findsOneWidget);
      expect(find.text('补测试'), findsOneWidget);
      // task_id 显示出来便于与 API 日志对上。
      expect(find.text('TASK-001'), findsOneWidget);
      expect(find.text('TASK-002'), findsOneWidget);
    });

    testWidgets('展示状态与来源徽标', (t) async {
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', status: 'in_progress'),
            task('TASK-002', status: 'blocked', origin: 'manual'),
            task('TASK-003', status: 'completed', editedByUser: true),
          ],
        ),
      );

      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('阻塞'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      // 来源徽标（自动 / 手动）。
      expect(find.text('自动'), findsNWidgets(2));
      expect(find.text('手动'), findsOneWidget);
      // 编辑过的任务在重新展开时会被保留，值得显示。
      expect(find.text('已编辑'), findsOneWidget);
    });

    testWidgets('进度条用 ratio，文字用 percent（skipped 已并入 completed）', (t) async {
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', status: 'completed'),
            task('TASK-002', status: 'skipped'),
            task('TASK-003'),
            task('TASK-004'),
          ],
        ),
      );

      expect(
        find.byKey(const ValueKey('goal-tasks-progress-bar')),
        findsOneWidget,
      );
      final bar = t.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('goal-tasks-progress-bar')),
      );
      // 4 个里 2 个完成（completed + skipped）= 0.5。
      expect(bar.value, 0.5);
      expect(find.textContaining('已完成 2/4'), findsOneWidget);
      expect(find.textContaining('50%'), findsOneWidget);
    });

    testWidgets('阻塞/出错时显式提示需要人工处理', (t) async {
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', status: 'blocked'),
            task(
              'TASK-002',
              status: 'error_stopped',
              extra: {'error_reason': '编译失败'},
            ),
          ],
        ),
      );

      expect(
        find.byKey(const ValueKey('goal-tasks-attention')),
        findsOneWidget,
      );
      expect(find.textContaining('需要人工处理'), findsOneWidget);
      // 错误原因原样显示。
      expect(find.text('编译失败'), findsOneWidget);
    });

    testWidgets('无 goal 时给出空态且不渲染清单', (t) async {
      await pump(t, snap: snapshot(goalText: null));

      expect(find.byKey(const ValueKey('goal-tasks-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-tasks-list')), findsNothing);
    });

    testWidgets('有 goal 但无任务且不可新增时给出提示', (t) async {
      await pump(t, snap: snapshot());

      expect(find.byKey(const ValueKey('goal-tasks-no-tasks')), findsOneWidget);
      expect(find.text('还没有任务'), findsOneWidget);
    });

    testWidgets('showHeader=false 时不渲染目标文本与进度', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        showHeader: false,
      );

      expect(find.byKey(const ValueKey('goal-tasks-goal-text')), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-tasks-progress-bar')),
        findsNothing,
      );
      // 清单本身仍渲染。
      expect(find.text('TASK-001'), findsOneWidget);
    });
  });

  group('未注入回调 = 只读（不渲染操作入口，而不是禁用）', () {
    testWidgets('全部回调为 null：无勾选框、无菜单、无新增/删除/重排/展开', (t) async {
      await pump(t, snap: snapshot(tasks: [task('TASK-001')]));

      // 没有勾选框（连 leading 都不占位）。
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-task-check-TASK-001')),
        findsNothing,
      );
      // 没有状态菜单。
      expect(
        find.byKey(const ValueKey('goal-task-status-menu-TASK-001')),
        findsNothing,
      );
      // 没有上移/下移/删除。
      expect(find.byKey(const ValueKey('goal-task-up-TASK-001')), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-task-down-TASK-001')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('goal-task-delete-TASK-001')),
        findsNothing,
      );
      // 没有编辑。
      expect(
        find.byKey(const ValueKey('goal-task-edit-TASK-001')),
        findsNothing,
      );
      // 没有新增行与重新展开。
      expect(find.byKey(const ValueKey('goal-task-add-field')), findsNothing);
      expect(find.byKey(const ValueKey('goal-task-add-button')), findsNothing);
      expect(find.byKey(const ValueKey('goal-tasks-reset')), findsNothing);
      // 也没有刷新按钮（未注入 onReload）。
      expect(find.byKey(const ValueKey('goal-tasks-reload')), findsNothing);
    });

    testWidgets('只注入 onSetStatus：只有勾选框与状态菜单，无重排/删除', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onSetStatus: (_, _) async {},
      );

      expect(
        find.byKey(const ValueKey('goal-task-check-TASK-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goal-task-status-menu-TASK-001')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('goal-task-up-TASK-001')), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-task-delete-TASK-001')),
        findsNothing,
      );
    });

    testWidgets('只注入 onReorder：有上移/下移但无勾选框与删除', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001'), task('TASK-002')]),
        onReorder: (_) async {},
      );

      expect(
        find.byKey(const ValueKey('goal-task-up-TASK-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goal-task-down-TASK-001')),
        findsOneWidget,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.byKey(const ValueKey('goal-task-delete-TASK-001')),
        findsNothing,
      );
    });
  });

  group('勾选：调 status 端点，taskId 是 TASK-NNN 不是行 id', () {
    testWidgets('勾选未完成任务 → completed，参数是 TASK-NNN', (t) async {
      final calls = <(String, GoalTaskStatus)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-007', status: 'pending')]),
        onSetStatus: (id, s) async => calls.add((id, s)),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-check-TASK-007')));
      await t.pumpAndSettle();

      expect(calls, hasLength(1));
      // ⚠️ 回归锁：必须是 TASK-007（task_id 列），不是 row_TASK-007（行 id）。
      expect(calls.single.$1, 'TASK-007');
      expect(calls.single.$2, GoalTaskStatus.completed);
    });

    testWidgets('取消勾选已完成任务 → pending', (t) async {
      final calls = <(String, GoalTaskStatus)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', status: 'completed')]),
        onSetStatus: (id, s) async => calls.add((id, s)),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-check-TASK-001')));
      await t.pumpAndSettle();

      expect(calls.single.$2, GoalTaskStatus.pending);
    });

    testWidgets('skipped 也显示为已勾选（计入完成），取消后回 pending', (t) async {
      final calls = <(String, GoalTaskStatus)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', status: 'skipped')]),
        onSetStatus: (id, s) async => calls.add((id, s)),
      );

      final box = t.widget<Checkbox>(
        find.byKey(const ValueKey('goal-task-check-TASK-001')),
      );
      expect(box.value, isTrue, reason: 'skipped 在服务端口径里已算完成');

      await t.tap(find.byKey(const ValueKey('goal-task-check-TASK-001')));
      await t.pumpAndSettle();
      // 没有「上次是什么」的记录，用户表达了「重做」→ pending。
      expect(calls.single.$2, GoalTaskStatus.pending);
    });

    testWidgets('busy 时勾选框禁用', (t) async {
      final calls = <(String, GoalTaskStatus)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onSetStatus: (id, s) async => calls.add((id, s)),
        busy: true,
      );

      final box = t.widget<Checkbox>(
        find.byKey(const ValueKey('goal-task-check-TASK-001')),
      );
      expect(box.onChanged, isNull);
      expect(calls, isEmpty);
    });

    testWidgets('状态菜单可切到六种状态中的任意一种（除当前）', (t) async {
      final calls = <(String, GoalTaskStatus)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', status: 'pending')]),
        onSetStatus: (id, s) async => calls.add((id, s)),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-status-menu-TASK-001')));
      await t.pumpAndSettle();
      // 六种状态全部列出（unknown 不是可选项）。
      for (final s in [
        'in_progress',
        'completed',
        'skipped',
        'error_stopped',
        'blocked',
      ]) {
        expect(
          find.byKey(ValueKey('goal-task-status-TASK-001-$s')),
          findsOneWidget,
          reason: '缺少状态项 $s',
        );
      }
      expect(
        find.byKey(const ValueKey('goal-task-status-TASK-001-')),
        findsNothing,
        reason: 'unknown 不应出现在菜单里',
      );

      await t.tap(
        find.byKey(const ValueKey('goal-task-status-TASK-001-blocked')),
      );
      await t.pumpAndSettle();

      expect(calls.single.$2, GoalTaskStatus.blocked);
    });
  });

  group('重排：必须下发整份顺序（服务端不校验完整性）', () {
    testWidgets('上移中间项：body 是完整顺序且被移项前移一位', (t) async {
      final calls = <List<String>>[];
      await pump(
        t,
        snap: snapshot(
          tasks: [task('TASK-001'), task('TASK-002'), task('TASK-003')],
        ),
        onReorder: (ids) async => calls.add(ids),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-up-TASK-002')));
      await t.pumpAndSettle();

      expect(calls, hasLength(1));
      // ⚠️ 回归锁：三条都要在，不能只发 ['TASK-002']（增量会让 TASK-001 与
      // TASK-002 撞上同一个 order_index）。
      expect(calls.single, ['TASK-002', 'TASK-001', 'TASK-003']);
    });

    testWidgets('下移中间项：body 是完整顺序且被移项后移一位', (t) async {
      final calls = <List<String>>[];
      await pump(
        t,
        snap: snapshot(
          tasks: [task('TASK-001'), task('TASK-002'), task('TASK-003')],
        ),
        onReorder: (ids) async => calls.add(ids),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-down-TASK-002')));
      await t.pumpAndSettle();

      expect(calls.single, ['TASK-001', 'TASK-003', 'TASK-002']);
    });

    testWidgets('首位的上移禁用（置灰不隐藏，列表不跳动）', (t) async {
      final calls = <List<String>>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001'), task('TASK-002')]),
        onReorder: (ids) async => calls.add(ids),
      );

      final up = t.widget<IconButton>(
        find.byKey(const ValueKey('goal-task-up-TASK-001')),
      );
      expect(up.onPressed, isNull);
      // 按钮仍在（位置稳定）。
      expect(
        find.byKey(const ValueKey('goal-task-up-TASK-001')),
        findsOneWidget,
      );

      // 末位的下移同理。
      final down = t.widget<IconButton>(
        find.byKey(const ValueKey('goal-task-down-TASK-002')),
      );
      expect(down.onPressed, isNull);
      expect(calls, isEmpty);
    });

    testWidgets('只有一条任务时上下移都禁用', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onReorder: (_) async {},
      );

      expect(
        t
            .widget<IconButton>(
              find.byKey(const ValueKey('goal-task-up-TASK-001')),
            )
            .onPressed,
        isNull,
      );
      expect(
        t
            .widget<IconButton>(
              find.byKey(const ValueKey('goal-task-down-TASK-001')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('顺序以 snapshot 的 tasks 为准（服务端已按 order_index 排好）', (t) async {
      final calls = <List<String>>[];
      // 刻意用非字典序：若面板自己按 taskId 排序会得到不同结果。
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-003', orderIndex: 0),
            task('TASK-001', orderIndex: 1),
            task('TASK-002', orderIndex: 2),
          ],
        ),
        onReorder: (ids) async => calls.add(ids),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-up-TASK-001')));
      await t.pumpAndSettle();

      expect(calls.single, ['TASK-001', 'TASK-003', 'TASK-002']);
    });
  });

  group('新增任务', () {
    testWidgets('填标题点加号 → onCreate(title)，成功后清空输入框', (t) async {
      final created = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onCreate: ({required title, description}) async => created.add(title),
      );

      await t.enterText(
        find.byKey(const ValueKey('goal-task-add-field')),
        '  新任务  ',
      );
      await t.tap(find.byKey(const ValueKey('goal-task-add-button')));
      await t.pumpAndSettle();

      // 服务端会 trim，客户端也 trim 后再发（避免只发空白）。
      expect(created, ['新任务']);
      final field = t.widget<TextField>(
        find.byKey(const ValueKey('goal-task-add-field')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('回车即提交（单行输入的预期行为）', (t) async {
      final created = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onCreate: ({required title, description}) async => created.add(title),
      );

      await t.enterText(
        find.byKey(const ValueKey('goal-task-add-field')),
        '回车新增',
      );
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();

      expect(created, ['回车新增']);
    });

    testWidgets('空标题不提交，给出提示', (t) async {
      final created = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onCreate: ({required title, description}) async => created.add(title),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-add-button')));
      await t.pumpAndSettle();

      expect(created, isEmpty);
      expect(find.text('请先填写任务标题'), findsOneWidget);
    });

    testWidgets('只有空白字符也不提交', (t) async {
      final created = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onCreate: ({required title, description}) async => created.add(title),
      );

      await t.enterText(
        find.byKey(const ValueKey('goal-task-add-field')),
        '   ',
      );
      await t.tap(find.byKey(const ValueKey('goal-task-add-button')));
      await t.pumpAndSettle();

      expect(created, isEmpty);
    });

    testWidgets('有 goal 且无任务时新增行仍渲染（空清单不是死路）', (t) async {
      await pump(
        t,
        snap: snapshot(),
        onCreate: ({required title, description}) async {},
      );

      expect(find.byKey(const ValueKey('goal-task-add-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-tasks-no-tasks')), findsNothing);
    });
  });

  group('编辑：接线 updateTask（标题 + 描述）', () {
    /// 打开某行的编辑对话框并等它稳定。
    Future<void> openEditor(WidgetTester t, String taskId) async {
      await t.tap(find.byKey(ValueKey('goal-task-edit-$taskId')));
      await t.pumpAndSettle();
    }

    testWidgets('未注入 onUpdateTask 时不渲染编辑入口（不是禁用）', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onSetStatus: (_, _) async {},
      );

      // 有状态菜单（已注入 onSetStatus），但没有编辑。
      expect(
        find.byKey(const ValueKey('goal-task-status-menu-TASK-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goal-task-edit-TASK-001')),
        findsNothing,
        reason: '禁用按钮会让用户以为「本端支持但暂时不可用」，真相是没装配该能力',
      );
    });

    testWidgets('点编辑弹出对话框并预填当前标题', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', title: '修编译')]),
        onUpdateTask: (_, {title, description}) async {},
      );

      await openEditor(t, 'TASK-001');

      expect(
        find.byKey(const ValueKey('goal-task-edit-dialog')),
        findsOneWidget,
      );
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('goal-task-edit-title')),
            )
            .controller
            ?.text,
        '修编译',
      );
    });

    testWidgets('改标题后保存，回调收到新标题（taskId 是 TASK-NNN）', (t) async {
      final calls = <(String, String?, String?)>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-007', title: '旧标题')]),
        onUpdateTask: (taskId, {title, description}) async {
          calls.add((taskId, title, description));
        },
      );

      await openEditor(t, 'TASK-007');
      await t.enterText(
        find.byKey(const ValueKey('goal-task-edit-title')),
        '新标题',
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await t.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(
        calls.single.$1,
        'TASK-007',
        reason: '路径参数是 TASK-NNN，不是 chat_goal_tasks.id 行 id',
      );
      expect(calls.single.$2, '新标题');
      // 描述原为空 → 保存后仍传空串（服务端 '' = 清除），而不是 null（= 不改）。
      expect(calls.single.$3, '');
    });

    testWidgets('清空描述后保存传空串（不是 null——null 会被服务端当成「不修改」）', (t) async {
      final calls = <(String, String?, String?)>[];
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', title: '标题', extra: {'description': '原有描述'}),
          ],
        ),
        onUpdateTask: (taskId, {title, description}) async {
          calls.add((taskId, title, description));
        },
      );

      await openEditor(t, 'TASK-001');
      // 描述框预填了「原有描述」（与标题不同）。
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('goal-task-edit-description')),
            )
            .controller
            ?.text,
        '原有描述',
      );

      await t.enterText(
        find.byKey(const ValueKey('goal-task-edit-description')),
        '',
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await t.pumpAndSettle();

      expect(
        calls.single.$3,
        '',
        reason: '传 null 会让用户发现「描述还在」——服务端把 null 解释为「不改」',
      );
    });

    testWidgets('描述与标题相同时不预填（服务端常把 title 复制进 description）', (t) async {
      await pump(
        t,
        snap: snapshot(
          tasks: [
            task('TASK-001', title: '修编译', extra: {'description': '修编译'}),
          ],
        ),
        onUpdateTask: (_, {title, description}) async {},
      );

      await openEditor(t, 'TASK-001');

      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('goal-task-edit-description')),
            )
            .controller
            ?.text,
        '',
        reason: '预填会让用户以为描述本来就有一份内容，从而不敢清空',
      );
    });

    testWidgets('标题为空时确定按钮禁用（服务端不拦空标题）', (t) async {
      var called = 0;
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', title: '标题')]),
        onUpdateTask: (_, {title, description}) async => called++,
      );

      await openEditor(t, 'TASK-001');
      await t.enterText(
        find.byKey(const ValueKey('goal-task-edit-title')),
        '   ',
      );
      await t.pump();

      final save = t.widget<FilledButton>(
        find.byKey(const ValueKey('goal-task-edit-save')),
      );
      expect(save.onPressed, isNull);

      // 点也没用（onPressed 为 null）。
      await t.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await t.pumpAndSettle();
      expect(called, 0);
    });

    testWidgets('取消不提交（对话框关闭且无回调）', (t) async {
      var called = 0;
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', title: '标题')]),
        onUpdateTask: (_, {title, description}) async => called++,
      );

      await openEditor(t, 'TASK-001');
      await t.enterText(
        find.byKey(const ValueKey('goal-task-edit-title')),
        '改了但不保存',
      );
      await t.pump();
      await t.tap(find.byKey(const ValueKey('goal-task-edit-cancel')));
      await t.pumpAndSettle();

      expect(called, 0);
      expect(find.byKey(const ValueKey('goal-task-edit-dialog')), findsNothing);
    });

    testWidgets('busy 时编辑按钮禁用（并发提交会互相覆盖）', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onUpdateTask: (_, {title, description}) async {},
        busy: true,
      );

      expect(
        t
            .widget<IconButton>(
              find.byKey(const ValueKey('goal-task-edit-TASK-001')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('编辑失败时提示且对话框已关闭（面板仍可交互）', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001', title: '标题')]),
        onUpdateTask: (_, {title, description}) async =>
            throw StateError('网络断了'),
      );

      await openEditor(t, 'TASK-001');
      await t.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await t.pumpAndSettle();

      expect(find.textContaining('操作失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-tasks-list')), findsOneWidget);
    });
  });

  group('删除：先确认再提交', () {
    testWidgets('确认后调用 onDelete(taskId)', (t) async {
      final deleted = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-009', title: '要删的')]),
        onDelete: (id) async => deleted.add(id),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-delete-TASK-009')));
      await t.pumpAndSettle();
      // 确认弹窗先出现，此时还没调用。
      expect(deleted, isEmpty);
      expect(find.textContaining('不可撤销'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('goal-tasks-confirm-ok')));
      await t.pumpAndSettle();

      expect(deleted, ['TASK-009']);
    });

    testWidgets('取消确认则不调用（删除不可撤销，必须可退）', (t) async {
      final deleted = <String>[];
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-009')]),
        onDelete: (id) async => deleted.add(id),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-delete-TASK-009')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('goal-tasks-confirm-cancel')));
      await t.pumpAndSettle();

      expect(deleted, isEmpty);
    });
  });

  group('重新展开：破坏性操作先确认', () {
    testWidgets('确认后调用 onResetForExpand', (t) async {
      var called = 0;
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onResetForExpand: () async => called++,
      );

      await t.tap(find.byKey(const ValueKey('goal-tasks-reset')));
      await t.pumpAndSettle();
      expect(called, 0);
      // 文案必须说清「会删什么、保留什么」。
      expect(find.textContaining('人工新增或编辑过的任务会保留'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('goal-tasks-confirm-ok')));
      await t.pumpAndSettle();

      expect(called, 1);
    });

    testWidgets('取消则不调用', (t) async {
      var called = 0;
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onResetForExpand: () async => called++,
      );

      await t.tap(find.byKey(const ValueKey('goal-tasks-reset')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('goal-tasks-confirm-cancel')));
      await t.pumpAndSettle();

      expect(called, 0);
    });
  });

  group('刷新与错误处理', () {
    testWidgets('刷新按钮调 onReload', (t) async {
      var called = 0;
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onReload: () async => called++,
      );

      await t.tap(find.byKey(const ValueKey('goal-tasks-reload')));
      await t.pumpAndSettle();

      expect(called, 1);
    });

    testWidgets('写操作失败时提示且不崩（面板仍是可交互状态）', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onSetStatus: (_, _) async => throw StateError('网络断了'),
      );

      await t.tap(find.byKey(const ValueKey('goal-task-check-TASK-001')));
      await t.pumpAndSettle();

      expect(find.textContaining('操作失败'), findsOneWidget);
      expect(find.textContaining('网络断了'), findsOneWidget);
      // 面板仍在（没有把异常抛到 build 里）。
      expect(find.byKey(const ValueKey('goal-tasks-list')), findsOneWidget);
    });

    testWidgets('刷新失败也走同一提示路径', (t) async {
      await pump(
        t,
        snap: snapshot(tasks: [task('TASK-001')]),
        onReload: () async => throw StateError('500'),
      );

      await t.tap(find.byKey(const ValueKey('goal-tasks-reload')));
      await t.pumpAndSettle();

      expect(find.textContaining('操作失败'), findsOneWidget);
    });
  });

  group('gate 决策区块（复用只读诊断组件）', () {
    testWidgets('decisions 为空时整块不渲染', (t) async {
      await pump(t, snap: snapshot(tasks: [task('TASK-001')]));

      expect(find.byKey(const ValueKey('goal-tasks-decisions')), findsNothing);
    });
  });
}
