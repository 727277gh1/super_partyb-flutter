import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// [GroupSettingsPanel] 的交互测试。
///
/// ## 这个测试防的是什么
///
/// 面板有三类容易出错的「本地守卫」，它们都**只在客户端存在**（服务端不拦）：
///
/// 1. **无目标时开 goal gate**：服务端会回 400 `goal_required`。不本地禁用就是
///    让用户点一个必然失败的开关。
/// 2. **最大轮次越界**：服务端对越界值是**夹取而非报错**，不本地 clamp 就会留下
///    「用户填 0 / 界面显示 0 / 服务端存 1」的不一致。
/// 3. **总开关关闭时的子开关**：服务端只做「按提交的键写入」，不会拒绝。若面板
///    在总开关关闭时仍允许操作子开关，就会写出「tts 未开启但 narrate_thinking
///    已打开」的畸形配置。
///
/// 另外还断言**只发变化的那一个键**：webapp 提交的是合并后的完整配置，本面板
/// 刻意只发意图字段（见 [SaveGroupTts] 的说明），若退化成整包提交，并发场景下
/// 会把另一台设备的改动回滚。
void main() {
  /// `groupToDict` + `loadGroupGoalSnapshot` 的真实输出形状。
  Map<String, dynamic> groupJson({
    String? goal,
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? currentGoal,
  }) => {
    'id': 'grp_1',
    'user_id': 'usr_1',
    'title': '某个对话',
    'status': 'active',
    'goal': goal,
    'metadata': metadata,
    'current_goal': currentGoal,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
  };

  /// 结构化 goal 快照（`goalSnapshotDTO`）。
  Map<String, dynamic> goalSnapshot(String text, {String id = 'goal_1'}) => {
    'goal': {
      'id': id,
      'group_id': 'grp_1',
      'goal_text': text,
      'status': 'active',
      'tasks_source': 'manual',
    },
    'tasks': <dynamic>[],
    'progress': <String, dynamic>{},
  };

  late List<String> savedGoals;
  late List<bool> goalGateToggles;
  late List<int> savedMaxTurns;
  late List<bool> followUpToggles;
  late List<bool> habitToggles;
  late List<Map<String, dynamic>> ttsSaves;

  setUp(() {
    savedGoals = [];
    goalGateToggles = [];
    savedMaxTurns = [];
    followUpToggles = [];
    habitToggles = [];
    ttsSaves = [];
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    required ChatGroup group,
    bool busy = false,
    bool withGoalGate = true,
    bool withFollowUp = true,
    bool withHabitSuggest = true,
    bool withTts = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupSettingsPanel(
            group: group,
            busy: busy,
            onSaveGoal: (text) async => savedGoals.add(text),
            onToggleGoalGate: withGoalGate
                ? (v) async => goalGateToggles.add(v)
                : null,
            onSaveMaxAutoTurns: withGoalGate
                ? (v) async => savedMaxTurns.add(v)
                : null,
            onToggleFollowUpSuggest: withFollowUp
                ? (v) async => followUpToggles.add(v)
                : null,
            onToggleHabitSuggest: withHabitSuggest
                ? (v) async => habitToggles.add(v)
                : null,
            onSaveTts: withTts
                ? ({
                    enabled,
                    narrateThinking,
                    narrationMode,
                    fileSummary,
                  }) async => ttsSaves.add({
                    if (enabled != null) 'enabled': enabled,
                    if (narrateThinking != null)
                      'narrate_thinking': narrateThinking,
                    if (narrationMode != null) 'narration_mode': narrationMode,
                    if (fileSummary != null) 'file_summary': fileSummary,
                  })
                : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 读某个 `SwitchListTile` 的开关值。
  bool switchValue(WidgetTester tester, String key) {
    final tile = tester.widget<SwitchListTile>(
      find.byKey(ValueKey<String>(key)),
    );
    return tile.value;
  }

  /// 读某个 `SwitchListTile` 是否可操作。
  bool switchEnabled(WidgetTester tester, String key) {
    final tile = tester.widget<SwitchListTile>(
      find.byKey(ValueKey<String>(key)),
    );
    return tile.onChanged != null;
  }

  /// 滚动到目标再点击。
  ///
  /// 面板是 `ListView`，测试窗口只有 800×600：语音回复区块在折叠线以下，
  /// 直接 `tap` 会命中外面的 `RenderView`（Flutter 会打印 hit-test 警告、
  /// 回调静默不触发）。所有点击都先 `ensureVisible`，与真实用户滚动一致。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('目标文本', () {
    testWidgets('初值来自结构化 goal（优先于 group.goal 旧列）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(goal: '旧列目标', currentGoal: goalSnapshot('结构化目标')),
        ),
      );

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-goal-field')),
      );
      expect(field.controller!.text, '结构化目标');
    });

    testWidgets('无结构化 goal 时回退到 group.goal 旧列（迁移 0022 前的存量）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson(goal: '只有旧列')),
      );

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-goal-field')),
      );
      expect(field.controller!.text, '只有旧列');
    });

    testWidgets('未修改时保存按钮禁用（避免双击留下重复 goal 版本）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(currentGoal: goalSnapshot('把同步做稳')),
        ),
      );

      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('group-goal-save')),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('修改后保存回调收到 trim 过的文本', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(currentGoal: goalSnapshot('把同步做稳')),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('group-goal-field')),
        '  新的目标  ',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('group-goal-save')));

      expect(savedGoals, ['新的目标']);
    });

    testWidgets('清空后保存 → 回调收到空串（语义是「清除目标」）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(currentGoal: goalSnapshot('把同步做稳')),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('group-goal-field')),
        '',
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('group-goal-save')));

      expect(savedGoals, ['']);
    });
  });

  group('自动实现目标', () {
    testWidgets('无目标时开关禁用并提示「请先设置目标」', (tester) async {
      // 服务端 enable 时校验非空 goal，空则 400 goal_required。
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(
        find.byKey(const ValueKey('group-goal-gate-needs-goal')),
        findsOneWidget,
      );
      expect(find.text('请先设置目标'), findsOneWidget);
      expect(switchEnabled(tester, 'group-goal-gate-switch'), isFalse);
    });

    testWidgets('有目标时开关可用，点击回调带意图值', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(currentGoal: goalSnapshot('把同步做稳')),
        ),
      );

      expect(
        find.byKey(const ValueKey('group-goal-gate-needs-goal')),
        findsNothing,
      );
      expect(switchEnabled(tester, 'group-goal-gate-switch'), isTrue);
      expect(switchValue(tester, 'group-goal-gate-switch'), isFalse);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-goal-gate-switch')),
      );

      expect(goalGateToggles, [true]);
    });

    testWidgets('草稿里的目标不算数（未保存仍禁用开关）', (tester) async {
      // 用户在输入框里打了字但没点保存时，服务端仍然没有目标。
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      await tester.enterText(
        find.byKey(const ValueKey('group-goal-field')),
        '刚打的目标',
      );
      await tester.pumpAndSettle();

      expect(switchEnabled(tester, 'group-goal-gate-switch'), isFalse);
    });

    testWidgets('enabled 与 continue_until_done 都需为 true 才显示已开启', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            currentGoal: goalSnapshot('目标'),
            // 服务端接管判定是 Enabled && ContinueUntilDone。
            metadata: {
              'goal_gate': {'enabled': true, 'continue_until_done': false},
            },
          ),
        ),
      );

      expect(switchValue(tester, 'group-goal-gate-switch'), isFalse);
    });

    testWidgets('两者都为 true 时显示已开启', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            currentGoal: goalSnapshot('目标'),
            metadata: {
              'goal_gate': {'enabled': true, 'continue_until_done': true},
            },
          ),
        ),
      );

      expect(switchValue(tester, 'group-goal-gate-switch'), isTrue);
    });

    testWidgets('最大轮次越界 clamp 到 1..200（服务端是夹取而非报错）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson(currentGoal: goalSnapshot('目标'))),
      );

      // 上界：输入 999 → 发 200。
      await tester.enterText(
        find.byKey(const ValueKey('group-max-turns-field')),
        '999',
      );
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-max-turns-save')),
      );
      expect(savedMaxTurns, [200]);

      // 下界：输入 0 → 发 1。
      await tester.enterText(
        find.byKey(const ValueKey('group-max-turns-field')),
        '0',
      );
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-max-turns-save')),
      );
      expect(savedMaxTurns, [200, 1]);
    });

    testWidgets('clamp 后输入框显示夹取结果（不留「填 999 显示 999」的假象）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson(currentGoal: goalSnapshot('目标'))),
      );

      await tester.enterText(
        find.byKey(const ValueKey('group-max-turns-field')),
        '999',
      );
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-max-turns-save')),
      );

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-max-turns-field')),
      );
      expect(field.controller!.text, '200');
    });

    testWidgets('值未变化时不发请求（避免无意义的 CAS 写）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            currentGoal: goalSnapshot('目标'),
            metadata: {
              'goal_gate': {'max_auto_turns': 20},
            },
          ),
        ),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-max-turns-save')),
      );

      expect(savedMaxTurns, isEmpty);
    });

    testWidgets('非法输入回退到当前生效值，不发请求', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            currentGoal: goalSnapshot('目标'),
            metadata: {
              'goal_gate': {'max_auto_turns': 20},
            },
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('group-max-turns-field')),
        '',
      );
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-max-turns-save')),
      );

      expect(savedMaxTurns, isEmpty);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-max-turns-field')),
      );
      expect(field.controller!.text, '20');
    });

    testWidgets('metadata 缺失 max_auto_turns 时显示服务端默认值 20', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson(currentGoal: goalSnapshot('目标'))),
      );

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-max-turns-field')),
      );
      expect(field.controller!.text, '20');
    });
  });

  group('后续提问建议', () {
    testWidgets('键缺失 = 关闭，点击回调带意图值', (tester) async {
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(switchValue(tester, 'group-follow-up-switch'), isFalse);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-follow-up-switch')),
      );
      expect(followUpToggles, [true]);
    });

    testWidgets('metadata 标记已开启时显示已开启', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'follow_up_suggest': {'enabled': true},
            },
          ),
        ),
      );

      expect(switchValue(tester, 'group-follow-up-switch'), isTrue);
    });

    testWidgets('如实说明是双层开关（不承诺已生效）', (tester) async {
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(find.text('这是对话级开关，还需服务端已启用该能力才会生效'), findsOneWidget);
    });
  });

  group('习惯建议', () {
    testWidgets('键缺失 = 关闭，点击回调带意图值', (tester) async {
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(switchValue(tester, 'group-habit-suggest-switch'), isFalse);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-habit-suggest-switch')),
      );
      expect(habitToggles, [true]);
    });

    testWidgets('metadata 标记已开启时显示已开启', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'habit_suggest': {'enabled': true},
            },
          ),
        ),
      );

      expect(switchValue(tester, 'group-habit-suggest-switch'), isTrue);
    });

    testWidgets('与 goal gate 无关：无目标时仍可操作', (tester) async {
      // 历史上习惯引导嵌在 goal 约定尾部，未开 goal gate 的群组永远拿不到。
      // 拆出后本开关独立生效，面板不得因无目标而禁用它。
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(switchEnabled(tester, 'group-habit-suggest-switch'), isTrue);
      expect(switchEnabled(tester, 'group-goal-gate-switch'), isFalse);
    });

    testWidgets('如实说明是双层开关且与目标无关', (tester) async {
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(find.text('这是对话级开关，还需服务端已启用该能力才会生效，与「自动实现目标」无关'), findsOneWidget);
    });

    testWidgets('未注入 onToggleHabitSuggest 时该 section 不渲染', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson()),
        withHabitSuggest: false,
      );

      expect(
        find.byKey(const ValueKey('group-habit-suggest-switch')),
        findsNothing,
      );
    });
  });

  group('语音回复', () {
    testWidgets('总开关关闭时三个子开关全部禁用', (tester) async {
      await pumpPanel(tester, group: ChatGroup.fromJson(groupJson()));

      expect(switchEnabled(tester, 'group-tts-switch'), isTrue);
      expect(switchEnabled(tester, 'group-tts-narrate-switch'), isFalse);
      expect(switchEnabled(tester, 'group-tts-file-switch'), isFalse);
      final mode = tester.widget<SegmentedButton<String>>(
        find.byKey(const ValueKey('group-tts-mode')),
      );
      expect(mode.onSelectionChanged, isNull);
    });

    testWidgets('总开关开启后子开关可用', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true, 'narrate_thinking': true},
            },
          ),
        ),
      );

      expect(switchEnabled(tester, 'group-tts-narrate-switch'), isTrue);
      expect(switchEnabled(tester, 'group-tts-file-switch'), isTrue);
    });

    testWidgets('总开关关闭时子开关恒为 false（即便 metadata 有残留键）', (tester) async {
      // 存量配置：历史上先开子开关、后关总开关，metadata 会残留 narrate_thinking。
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'narrate_thinking': true, 'file_summary': true},
            },
          ),
        ),
      );

      expect(switchValue(tester, 'group-tts-switch'), isFalse);
      expect(switchValue(tester, 'group-tts-narrate-switch'), isFalse);
      expect(switchValue(tester, 'group-tts-file-switch'), isFalse);
    });

    testWidgets('总开关回调只发 enabled（不夹带子开关）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true, 'narrate_thinking': true},
            },
          ),
        ),
      );

      await tapVisible(tester, find.byKey(const ValueKey('group-tts-switch')));

      expect(ttsSaves, [
        {'enabled': false},
      ]);
    });

    testWidgets('思考播报回调只发 narrate_thinking', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true},
            },
          ),
        ),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-tts-narrate-switch')),
      );

      expect(ttsSaves, [
        {'narrate_thinking': true},
      ]);
    });

    testWidgets('文件播报回调只发 file_summary', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true},
            },
          ),
        ),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('group-tts-file-switch')),
      );

      expect(ttsSaves, [
        {'file_summary': true},
      ]);
    });

    testWidgets('播报模式回调只发 narration_mode', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true, 'narrate_thinking': true},
            },
          ),
        ),
      );

      await tapVisible(tester, find.text('中文摘要'));

      expect(ttsSaves, [
        {'narration_mode': 'summary'},
      ]);
    });

    testWidgets('思考播报未开启时播报模式不可选（避免畸形配置）', (tester) async {
      // 服务端只在 narrate_thinking 已开启时才写 narration_mode。
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {'enabled': true},
            },
          ),
        ),
      );

      final mode = tester.widget<SegmentedButton<String>>(
        find.byKey(const ValueKey('group-tts-mode')),
      );
      expect(mode.onSelectionChanged, isNull);
    });

    testWidgets('未知 narration_mode 归一为 filler', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(
          groupJson(
            metadata: {
              'tts': {
                'enabled': true,
                'narrate_thinking': true,
                'narration_mode': 'weird',
              },
            },
          ),
        ),
      );

      final mode = tester.widget<SegmentedButton<String>>(
        find.byKey(const ValueKey('group-tts-mode')),
      );
      expect(mode.selected, {'filler'});
    });
  });

  group('busy 与装配降级', () {
    testWidgets('busy 时全部控件禁用（防并发提交把 CAS 打成 409）', (tester) async {
      await pumpPanel(
        tester,
        busy: true,
        group: ChatGroup.fromJson(
          groupJson(
            currentGoal: goalSnapshot('目标'),
            metadata: {
              'tts': {'enabled': true},
            },
          ),
        ),
      );

      expect(switchEnabled(tester, 'group-goal-gate-switch'), isFalse);
      expect(switchEnabled(tester, 'group-follow-up-switch'), isFalse);
      expect(switchEnabled(tester, 'group-tts-switch'), isFalse);
      expect(switchEnabled(tester, 'group-tts-narrate-switch'), isFalse);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('group-goal-save')),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('未注入回调的区块不渲染（侧边栏可退化为部分可用）', (tester) async {
      await pumpPanel(
        tester,
        group: ChatGroup.fromJson(groupJson()),
        withGoalGate: false,
        withFollowUp: false,
        withHabitSuggest: false,
        withTts: false,
      );

      expect(
        find.byKey(const ValueKey('group-goal-gate-switch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('group-follow-up-switch')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('group-habit-suggest-switch')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('group-tts-switch')), findsNothing);
      // 目标输入始终渲染（onSaveGoal 是必填参数）。
      expect(find.byKey(const ValueKey('group-goal-field')), findsOneWidget);
    });

    testWidgets('权威值变化时对齐草稿（写成功后 reload 的场景）', (tester) async {
      final before = ChatGroup.fromJson(
        groupJson(currentGoal: goalSnapshot('旧目标', id: 'goal_1')),
      );
      await pumpPanel(tester, group: before);

      final after = ChatGroup.fromJson(
        groupJson(currentGoal: goalSnapshot('新目标', id: 'goal_2')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupSettingsPanel(
              group: after,
              onSaveGoal: (_) async {},
              onToggleGoalGate: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('group-goal-field')),
      );
      expect(field.controller!.text, '新目标');
    });
  });

  // Goal Gate 自动停用后的状态错显。
  //
  // ## 这个测试防的是什么（事实性错误）
  //
  // Goal Gate 达成目标（`chatgate/goal_gate.go:440`）或达到 max_auto_turns
  // 熔断（`:555`）时，服务端自己把 `metadata.goal_gate.enabled` 改成 false
  // （`markGoalGateCompleted`）。这是**后台 worker** 的动作，没有 HTTP 响应
  // 回到客户端。
  //
  // 不消费 `group_metadata_updated` 的后果：面板继续显示「自动实现目标：开」，
  // 用户以为还会自动续跑，实际已停——**事实性错误**，比不显示更糟。
  //
  // 本组用真实链路断言：`ChatEvent`（服务端载荷）→ `GroupUpdate.fromEvent`
  // → `applyTo` → 面板渲染。不是在测试里重写一遍套用逻辑。
  group('group_metadata_updated 纠正 goal gate 自动停用后的错显', () {
    /// 服务端 `emitEvent(EventGroupMetadataUpdated, {reason, metadata})` 的载荷。
    ///
    /// metadata 是**完整**的 `chat_groups.metadata`（Go `updateGroupMetadata`
    /// 返回整个 map，不是子树），故这里带上 tts 以验证「整体替换不丢其它键」。
    ChatEvent metadataUpdatedEvent({
      String reason = 'goal_completed',
      bool gateEnabled = false,
      bool ttsEnabled = true,
    }) => ChatEvent.fromJson({
      'eventId': 'evt_gm_1',
      'userId': 'usr_1',
      'groupId': 'grp_1',
      'turnId': 'turn_1',
      'eventType': EventTypes.groupMetadataUpdated,
      'seq': 1,
      'globalSeq': 10,
      'source': 'system',
      'payload': {
        'reason': reason,
        'metadata': {
          'goal_gate': {
            'enabled': gateEnabled,
            'continue_until_done': gateEnabled,
            'state': {'status': 'completed'},
          },
          'tts': {'enabled': ttsEnabled, 'narration_mode': 'summary'},
        },
      },
      'createdAt': '2026-09-28T10:11:12.345Z',
    });

    /// gate 开启的初始 group（模拟用户之前开了「自动实现目标」）。
    ChatGroup gateOnGroup() => ChatGroup.fromJson(
      groupJson(
        metadata: {
          'goal_gate': {'enabled': true, 'continue_until_done': true},
          'tts': {'enabled': false},
        },
        currentGoal: goalSnapshot('把同步做稳'),
      ),
    );

    testWidgets('初始状态：开关为「开」', (tester) async {
      await pumpPanel(tester, group: gateOnGroup());

      expect(
        switchValue(tester, 'group-goal-gate-switch'),
        isTrue,
        reason: '前置条件：用户之前开了自动实现目标',
      );
    });

    testWidgets('收到 goal_completed 事件后，开关变为「关」', (tester) async {
      final group = gateOnGroup();
      expect(group.goalGateEnabled, isTrue, reason: '前置条件');

      // 真实链路：服务端事件 → 领域模型归一 → 套用到 group。
      final update = GroupUpdate.fromEvent(metadataUpdatedEvent())!;
      expect(update.op, GroupUpdateOp.metadata);
      final updated = update.applyTo(group);

      expect(
        updated.goalGateEnabled,
        isFalse,
        reason: '服务端已自动停用，客户端必须跟着关——否则是事实性错误',
      );

      await pumpPanel(tester, group: updated);

      expect(
        switchValue(tester, 'group-goal-gate-switch'),
        isFalse,
        reason: '面板必须显示「关」（修复前这里仍是 true）',
      );
    });

    testWidgets('熔断（max_auto_turns_reached）同样纠正为「关」', (tester) async {
      final update = GroupUpdate.fromEvent(
        metadataUpdatedEvent(reason: 'max_auto_turns_reached'),
      )!;
      final updated = update.applyTo(gateOnGroup());

      await pumpPanel(tester, group: updated);

      expect(switchValue(tester, 'group-goal-gate-switch'), isFalse);
    });

    testWidgets('整体替换不丢其它 metadata 键（tts 仍为开）', (tester) async {
      final update = GroupUpdate.fromEvent(
        metadataUpdatedEvent(gateEnabled: false, ttsEnabled: true),
      )!;
      final updated = update.applyTo(gateOnGroup());

      expect(
        updated.ttsEnabled,
        isTrue,
        reason: '事件带的是完整 metadata，tts 键不得因套用而丢失',
      );
      expect(updated.ttsNarrationMode, 'summary');

      await pumpPanel(tester, group: updated);
      expect(switchValue(tester, 'group-tts-switch'), isTrue);
    });

    testWidgets('只替换 metadata，标题与 goal 快照保留', (tester) async {
      final group = gateOnGroup();
      final updated = GroupUpdate.fromEvent(metadataUpdatedEvent())!
          .applyTo(group);

      expect(updated.id, 'grp_1');
      expect(updated.title, '某个对话');
      expect(updated.currentGoalText, '把同步做稳', reason: '该事件不携带 goal，不得丢失');
    });

    testWidgets('别的 group 的事件不套用（SSE 是 user 级订阅）', (tester) async {
      final group = gateOnGroup();
      final other = ChatEvent.fromJson({
        'eventId': 'e2',
        'groupId': 'grp_other',
        'eventType': EventTypes.groupMetadataUpdated,
        'payload': {
          'reason': 'goal_completed',
          'metadata': {
            'goal_gate': {'enabled': false, 'continue_until_done': false},
          },
        },
        'createdAt': '2026-09-28T10:11:12.345Z',
      });

      final update = GroupUpdate.fromEvent(other)!;
      expect(
        identical(update.applyTo(group), group),
        isTrue,
        reason: 'groupId 不匹配时返回原对象，调用方据此跳过 setState',
      );
      expect(group.goalGateEnabled, isTrue);
    });

    testWidgets('metadata 缺失时返回原对象（不得清空现有开关）', (tester) async {
      final group = gateOnGroup();
      final ev = ChatEvent.fromJson({
        'eventId': 'e3',
        'groupId': 'grp_1',
        'eventType': EventTypes.groupMetadataUpdated,
        'payload': {'reason': 'goal_completed'},
        'createdAt': '2026-09-28T10:11:12.345Z',
      });

      final update = GroupUpdate.fromEvent(ev)!;
      expect(update.metadata, isNull);
      expect(identical(update.applyTo(group), group), isTrue);
      expect(group.goalGateEnabled, isTrue, reason: '异常载荷不得把开关全清成关（那会制造另一种错显）');
    });

    testWidgets('非 metadata 分支的 group 变更不影响设置面板', (tester) async {
      final group = gateOnGroup();
      final titleEvent = ChatEvent.fromJson({
        'eventId': 'e4',
        'groupId': 'grp_1',
        'eventType': EventTypes.groupTitleUpdated,
        'payload': {'new_title': '改了名'},
        'createdAt': '2026-09-28T10:11:12.345Z',
      });

      final update = GroupUpdate.fromEvent(titleEvent)!;
      expect(update.op, GroupUpdateOp.title);
      expect(
        identical(update.applyTo(group), group),
        isTrue,
        reason: '本页不渲染标题，不应因标题变更重建设置面板',
      );
      expect(group.goalGateEnabled, isTrue);
    });
  });
}
