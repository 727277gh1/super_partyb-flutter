import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// [GoalHistoryPanel] 的渲染与交互测试。
///
/// ## 这个测试防的是什么
///
/// 1. **「切回」被写成「恢复」**：`switchGoal` 只改 `chat_groups.current_goal_id`
///    指针，**不改任何 goal 内容**（见 `goal_api.dart` 的方法文档）。若文案
///    写成「恢复」，用户会以为「内容被还原了」——而真相是可以反复来回切，
///    且旧目标的内容从未变过。本测试锁定「切回」这个字。
/// 2. **当前项仍可点「切回」**：它是空操作（服务端把指针指向它自己），但会让
///    用户以为「刚才那次切换没生效」从而反复点。故当前项**不渲染**该按钮。
/// 3. **归档当前项**：会让 `current_goal_id` 指向一个已归档目标。故当前项
///    不渲染「归档」。
/// 4. **完成/归档回调传错 id**：端点路径里的 `:goal_id` 是行 id。传错会 404
///    或改错目标，而 UI 只会显示「操作失败」，看起来像网络问题。
/// 5. **加载失败静默成空列表**：用户会以为「确实没有历史目标」，而真相是
///    请求失败了——历史明明存在却看不到，正好是这个面板要解决的问题。
void main() {
  /// `goalToDTO`（Go `goal_api.go`）的形状。
  Goal goal(
    String id, {
    String goalText = '把 CI 修绿',
    String status = 'active',
    String tasksSource = 'manual',
    String createdAt = '2024-03-05T08:00:00Z',
    String? gitCommit,
  }) => Goal.fromJson({
    'id': id,
    'group_id': 'grp_1',
    'goal_text': goalText,
    'status': status,
    'tasks_source': tasksSource,
    'created_at': createdAt,
    'updated_at': createdAt,
    if (gitCommit != null) 'git_commit': gitCommit,
  });

  late List<Goal> items;
  late int loadCalls;
  late List<String> switched;
  late List<(String, GoalStatus)> statusChanges;
  late List<String> created;
  SpbError? loadError;

  void useStubs({List<Goal>? initial, SpbError? error}) {
    items = initial ?? const [];
    loadError = error;
    loadCalls = 0;
    switched = [];
    statusChanges = [];
    created = [];
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    String? currentGoalId,
    bool wireSwitch = true,
    bool wireSetStatus = true,
    bool wireCreate = false,
    bool busy = false,
    Object? reloadToken = 'grp_1',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GoalHistoryPanel(
            load: () async {
              loadCalls++;
              if (loadError != null) throw loadError!;
              return items;
            },
            onSwitch: wireSwitch ? (id) async => switched.add(id) : null,
            onSetStatus: wireSetStatus
                ? (id, status) async => statusChanges.add((id, status))
                : null,
            onCreate: wireCreate ? (text) async => created.add(text) : null,
            currentGoalId: currentGoalId,
            busy: busy,
            reloadToken: reloadToken,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('目标历史：渲染', () {
    testWidgets('展示目标文本 / 状态徽标 / tasks_source / 创建时间', (tester) async {
      useStubs(
        initial: [
          goal(
            'goal_1',
            goalText: '把 CI 修绿',
            tasksSource: 'llm_expand',
            createdAt: '2024-03-05T08:09:00Z',
          ),
        ],
      );
      await pumpPanel(tester, currentGoalId: 'goal_1');

      expect(find.text('把 CI 修绿'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget, reason: '状态徽标用中文标签');
      expect(
        find.text('llm_expand'),
        findsOneWidget,
        reason: 'tasks_source 用 wire 值：它与 reset-for-expand 的可覆盖判定直接对应',
      );
      // 时间按本地时区格式化（只断言年份前缀，避免测试机时区差异）。
      expect(find.textContaining('2024-03-0'), findsOneWidget);
    });

    testWidgets('当前项高亮并显示「当前」徽标', (tester) async {
      useStubs(
        initial: [
          goal('goal_1'),
          goal('goal_2', goalText: '旧目标'),
        ],
      );
      await pumpPanel(tester, currentGoalId: 'goal_2');

      expect(
        find.byKey(const ValueKey('goal-current-goal_2')),
        findsOneWidget,
        reason: '长列表里用户要能一眼找到「我现在在哪」',
      );
      expect(find.byKey(const ValueKey('goal-current-goal_1')), findsNothing);
    });

    testWidgets('git_commit 截断为 8 位（完整 sha 会撑爆这一行）', (tester) async {
      useStubs(
        initial: [
          goal('goal_1', gitCommit: 'abcdef1234567890abcdef1234567890abcdef12'),
        ],
      );
      await pumpPanel(tester);

      expect(find.text('abcdef12'), findsOneWidget);
      expect(find.textContaining('abcdef1234567890'), findsNothing);
    });

    testWidgets('空列表占位（不渲染空列表）', (tester) async {
      useStubs(initial: const []);
      await pumpPanel(tester);

      expect(find.byKey(const ValueKey('goal-history-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-history-list')), findsNothing);
    });
  });

  group('目标历史：切回', () {
    testWidgets('非当前项渲染「切回」并回调对应 goal id', (tester) async {
      useStubs(initial: [goal('goal_1'), goal('goal_2')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      // 文案必须是「切回」：switchGoal 只改指针、不改内容，写成「恢复」是错的。
      expect(find.text('切回'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('goal-switch-goal_2')));
      await tester.pump();
      await tester.pump();

      expect(switched, [
        'goal_2',
      ], reason: '传的必须是行 id（:goal_id 是 chat_goals.id）');
    });

    testWidgets('当前项**不渲染**「切回」（它是空操作）', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      expect(
        find.byKey(const ValueKey('goal-switch-goal_1')),
        findsNothing,
        reason: '留着会让用户以为「上次切换没生效」从而反复点',
      );
      expect(find.text('切回'), findsNothing);
    });

    testWidgets('currentGoalId 为空时没有任何条目被判为当前（不误标）', (tester) async {
      useStubs(initial: [goal('goal_1'), goal('goal_2')]);
      await pumpPanel(tester, currentGoalId: null);

      // 权威快照未就绪时，宁可所有条目都可切，也不误标一个错的为当前。
      expect(find.byKey(const ValueKey('goal-current-goal_1')), findsNothing);
      expect(find.byKey(const ValueKey('goal-current-goal_2')), findsNothing);
      expect(find.text('切回'), findsNWidgets(2));
    });

    testWidgets('切回成功后重新加载（否则旧高亮不会被清掉）', (tester) async {
      useStubs(initial: [goal('goal_1'), goal('goal_2')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');
      expect(loadCalls, 1);

      await tester.tap(find.byKey(const ValueKey('goal-switch-goal_2')));
      await tester.pump();
      await tester.pump();

      expect(loadCalls, 2, reason: '不回读会留下「两个条目同时高亮」的列表');
    });

    testWidgets('未注入 onSwitch 时不渲染「切回」（不是禁用）', (tester) async {
      useStubs(initial: [goal('goal_1'), goal('goal_2')]);
      await pumpPanel(tester, currentGoalId: 'goal_1', wireSwitch: false);

      expect(find.text('切回'), findsNothing);
    });
  });

  group('目标历史：完成与归档', () {
    testWidgets('active 项渲染「标记完成」，点击回调 completed', (tester) async {
      useStubs(initial: [goal('goal_1', status: 'active')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      await tester.tap(find.byKey(const ValueKey('goal-complete-goal_1')));
      await tester.pump();
      await tester.pump();

      expect(statusChanges, [('goal_1', GoalStatus.completed)]);
    });

    testWidgets('非 active 项不渲染「标记完成」（再标一次是空操作）', (tester) async {
      useStubs(initial: [goal('goal_1', status: 'completed')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      expect(find.byKey(const ValueKey('goal-complete-goal_1')), findsNothing);
      expect(find.text('已完成'), findsOneWidget);
    });

    testWidgets('非当前项渲染「归档」，点击回调 archived', (tester) async {
      useStubs(
        initial: [
          goal('goal_1'),
          goal('goal_2', goalText: '旧目标'),
        ],
      );
      await pumpPanel(tester, currentGoalId: 'goal_1');

      await tester.tap(find.byKey(const ValueKey('goal-archive-goal_2')));
      await tester.pump();
      await tester.pump();

      expect(statusChanges, [('goal_2', GoalStatus.archived)]);
    });

    testWidgets('当前项**不渲染**「归档」（否则指针会指向已归档目标）', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      expect(find.byKey(const ValueKey('goal-archive-goal_1')), findsNothing);
    });

    testWidgets('已归档项不再渲染「归档」', (tester) async {
      useStubs(initial: [goal('goal_1', status: 'archived')]);
      await pumpPanel(tester, currentGoalId: 'goal_2');

      expect(find.byKey(const ValueKey('goal-archive-goal_1')), findsNothing);
      expect(find.text('已归档'), findsOneWidget);
    });

    testWidgets('未注入 onSetStatus 时不渲染完成/归档（不是禁用）', (tester) async {
      useStubs(
        initial: [
          goal('goal_1'),
          goal('goal_2', goalText: '旧目标'),
        ],
      );
      await pumpPanel(tester, currentGoalId: 'goal_1', wireSetStatus: false);

      expect(find.text('标记完成'), findsNothing);
      expect(find.text('归档'), findsNothing);
      // 「切回」仍可用（两个回调独立）。
      expect(find.text('切回'), findsOneWidget);
    });
  });

  group('目标历史：新建（issue #17）', () {
    testWidgets('未注入 onCreate 时不渲染「新建目标」（不是禁用）', (tester) async {
      // 与 onSwitch / onSetStatus 同一约定：不渲染一个点了没反应的入口。
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1');

      expect(find.byKey(const ValueKey('goal-create')), findsNothing);
      expect(find.text('新建目标'), findsNothing);
    });

    testWidgets('未注入 onCreate 时，空列表也不渲染入口', (tester) async {
      // 空态是**唯一**能看到「还没有历史目标」的场景，很容易被漏掉。
      useStubs(initial: const []);
      await pumpPanel(tester);

      expect(find.byKey(const ValueKey('goal-history-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('goal-create')), findsNothing);
    });

    testWidgets('注入后空列表也渲染入口（没有历史时最需要新建）', (tester) async {
      useStubs(initial: const []);
      await pumpPanel(tester, wireCreate: true);

      expect(find.byKey(const ValueKey('goal-create')), findsOneWidget);
    });

    testWidgets('点击入口 → 填文本 → 提交，回调收到目标文本', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1', wireCreate: true);

      await tester.tap(find.byKey(const ValueKey('goal-create')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('goal-create-dialog')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('goal-create-field')),
        '把 CI 修绿并补上回归测试',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('goal-create-submit')));
      await tester.pumpAndSettle();

      expect(created, ['把 CI 修绿并补上回归测试']);
      // 新建会改变列表（新行 + 旧 active 被归档），必须回读。
      expect(loadCalls, 2, reason: '不回读会留下与真相不符的列表');
    });

    testWidgets('空文本时确定按钮禁用（服务端对空 goal_text 返回 400）', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1', wireCreate: true);

      await tester.tap(find.byKey(const ValueKey('goal-create')));
      await tester.pumpAndSettle();

      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('goal-create-submit')),
      );
      expect(submit.onPressed, isNull, reason: '空文本必然 400，不该让用户白跑一次');

      // 只输空白也不算（服务端会 trim）。
      await tester.enterText(
        find.byKey(const ValueKey('goal-create-field')),
        '   ',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('goal-create-submit')),
            )
            .onPressed,
        isNull,
      );

      // 填了有效内容才可提交。
      await tester.enterText(
        find.byKey(const ValueKey('goal-create-field')),
        '有效目标',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('goal-create-submit')),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('取消对话框不调回调', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1', wireCreate: true);

      await tester.tap(find.byKey(const ValueKey('goal-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goal-create-field')),
        '写了但不提交',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('goal-create-cancel')));
      await tester.pumpAndSettle();

      expect(created, isEmpty);
      expect(loadCalls, 1, reason: '没提交就不该回读');
    });

    testWidgets('busy 时新建入口禁用（并发提交会互相覆盖）', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(
        tester,
        currentGoalId: 'goal_1',
        wireCreate: true,
        busy: true,
      );

      final btn = tester.widget<TextButton>(
        find.byKey(const ValueKey('goal-create')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('提交文本被 trim（前后空白不发给服务端）', (tester) async {
      useStubs(initial: [goal('goal_1')]);
      await pumpPanel(tester, currentGoalId: 'goal_1', wireCreate: true);

      await tester.tap(find.byKey(const ValueKey('goal-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goal-create-field')),
        '  两端有空白  ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('goal-create-submit')));
      await tester.pumpAndSettle();

      expect(created, ['两端有空白']);
    });
  });

  group('目标历史：并发与失败', () {
    testWidgets('busy 时全部操作禁用（并发提交会互相覆盖）', (tester) async {
      useStubs(
        initial: [
          goal('goal_1'),
          goal('goal_2', goalText: '旧目标'),
        ],
      );
      await pumpPanel(tester, currentGoalId: 'goal_1', busy: true);

      final switchBtn = tester.widget<TextButton>(
        find.byKey(const ValueKey('goal-switch-goal_2')),
      );
      expect(switchBtn.onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('goal-complete-goal_1')),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('加载失败展示错误与重试（不能静默成「没有历史目标」）', (tester) async {
      useStubs(error: const NetworkError('连接超时'));
      await pumpPanel(tester);

      expect(find.byKey(const ValueKey('goal-history-error')), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('goal-history-empty')),
        findsNothing,
        reason: '显示空列表会让用户以为历史确实不存在，而真相是请求失败',
      );

      // 重试：清掉错误后应恢复出列表。
      loadError = null;
      items = [goal('goal_1')];
      await tester.tap(find.byKey(const ValueKey('goal-history-retry')));
      await tester.pump();
      await tester.pump();

      expect(loadCalls, 2);
      expect(find.byKey(const ValueKey('goal-history-list')), findsOneWidget);
      expect(find.text('把 CI 修绿'), findsOneWidget);
    });

    testWidgets('切换对话（reloadToken 变化）重新加载并先清空旧 group 的历史', (tester) async {
      // Flutter 会复用本组件的 State（widget 类型与位置都没变），initState
      // 不会重跑。若不处理，列表会一直显示上一个 group 的目标——而那些 id
      // 在新 group 里不存在，点「切回」会得到 400「goal 不属于该 group」。
      useStubs(initial: [goal('goal_g1', goalText: 'g1 的目标')]);
      await pumpPanel(tester, reloadToken: 'grp_1');
      expect(find.text('g1 的目标'), findsOneWidget);

      items = [goal('goal_g2', goalText: 'g2 的目标')];
      await pumpPanel(tester, reloadToken: 'grp_2');

      expect(find.text('g2 的目标'), findsOneWidget);
      expect(find.text('g1 的目标'), findsNothing);
      expect(loadCalls, 2);
    });
  });
}
