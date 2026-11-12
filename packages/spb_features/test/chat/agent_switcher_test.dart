import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// `AgentSwitcher` 的 widget 测试。
///
/// ## 这个测试防的是什么
///
/// 选 agent 是**纯本地**动作（对齐 webapp 的 `setAgentForGroup`）：点选不弹确认、
/// 不发请求，选中的 agent 随**下一条消息**的 `agent_id` 交给服务端，由入队事务
/// 里的 `ReplaceBinding` 归档旧绑定。故：
/// - 点选必须**只回调** `selectAgent`，不得有 HTTP 请求、不得再要求二次确认；
/// - 「自动路由」是唯一能把本地选择清回 null 的入口（webapp / 小程序都有）：
///   清成 null 后下一条消息发 `routing.mode=auto`，服务端按内容挑执行者；
/// - 菜单里**没有任何会发请求的项**：「清空上下文」（旧名「同 Agent 开新会话」）
///   已搬到输入栏的 `MessageComposer.onNewSession`（那里才能弹确认框、才能提示
///   完成），它的测试在 `message_composer_test.dart`。
///
/// 另外两条降级约定（与仓库其余可选注入一致）：
/// - 列表为空 / 加载失败 → **隐藏入口**，不报错、不弹横幅（AppBar 上的附属
///   控件为它弹错误会打断用户当前在做的事）；
/// - 当前 agent 不在列表里（归档/删除）→ 标签回退 id 并给警告标记，不显示
///   空白（否则用户不知道当前绑的是谁）。
void main() {
  Agent agent(String id, String name, {String status = 'active'}) =>
      Agent(id: id, name: name, status: status);

  /// 最近一次本地选择（`null` = 没有选择发生**或**选了自动路由，故配合
  /// [selectCalls] 区分——自动路由本身就是一个合法选择）。
  late String? lastSelected;

  /// `selectAgent` 被调用的次数（区分「没选」与「选了自动路由」）。
  late int selectCalls;

  /// 把入口放进最小可用的 MaterialApp。
  Future<void> pumpSwitcher(
    WidgetTester tester, {
    List<Agent>? agents,
    Object? loadError,
    String? currentAgentId,
  }) async {
    lastSelected = null;
    selectCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('对话'),
            actions: [
              AgentSwitcher(
                loadAgents: () async {
                  if (loadError != null) throw loadError;
                  return agents ?? [agent('a1', '写作助手')];
                },
                selectAgent: (agentId) {
                  lastSelected = agentId;
                  selectCalls++;
                },
                currentAgentId: currentAgentId,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开菜单。
  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('agent-switcher')));
    await tester.pumpAndSettle();
  }

  group('标签显示', () {
    testWidgets('显示当前 agent 的名称（不是 id）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a2',
      );

      expect(
        find.byKey(const ValueKey('agent-switcher-label')),
        findsOneWidget,
      );
      expect(find.text('代码助手'), findsOneWidget);
    });

    testWidgets('当前 agent 不在列表里时回退显示 id 并给出警告标记', (tester) async {
      // agent 被归档/删除后，group.activeSession.agentId 仍指向它，而列表只含
      // active。显示空白会让用户不知道当前绑的是谁。
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手')],
        currentAgentId: 'a_gone',
      );

      expect(find.text('a_gone'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    });

    testWidgets('未绑定时显示「自动路由」（不是「未绑定」）', (tester) async {
      await pumpSwitcher(tester, currentAgentId: null);

      // null 的语义是「让平台挑」（`routing.mode=auto`），不是「没有」——
      // webapp 的 `selectedName || t("autoRouting")` 同此。
      expect(find.text('自动路由'), findsOneWidget);
      expect(find.text('未绑定'), findsNothing);
      // 菜单里不再有任何会发请求的项（「清空上下文」已搬到输入栏）。
      await openMenu(tester);
      expect(find.byKey(const ValueKey('agent-new-session')), findsNothing);
    });

    testWidgets('agent 名为空时回退 id（不显示空白）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '')],
        currentAgentId: 'a1',
      );

      expect(find.text('a1'), findsOneWidget);
    });
  });

  group('降级：隐藏入口而非报错', () {
    testWidgets('列表为空时不渲染入口', (tester) async {
      await pumpSwitcher(tester, agents: const []);

      expect(find.byKey(const ValueKey('agent-switcher')), findsNothing);
    });

    testWidgets('加载失败时不渲染入口，且不弹错误横幅', (tester) async {
      await pumpSwitcher(tester, loadError: Exception('boom'));

      expect(find.byKey(const ValueKey('agent-switcher')), findsNothing);
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'AppBar 上的附属控件为它弹错误会打断用户当前在做的事',
      );
    });

    testWidgets('加载失败后父级 rebuild 不会反复重试（防请求风暴）', (tester) async {
      // ## 这是本文件里最重要的一条回归防线
      //
      // 失败时 `_agents` 永远为 null。若 `didUpdateWidget` 的条件写成
      // 「`_agents == null` 就重试」，则父级**每次** rebuild（SSE 事件、
      // 时间线更新、任意 setState）都会再发一次请求。
      //
      // 实测后果不是「多几个请求」而是测试直接失败：每个失败请求都带 15s
      // 连接超时 Timer，`pumpAndSettle` 时留下大量未结算 Timer，报
      // 「A Timer is still pending even after the widget tree was disposed」
      // （desktop 的 `widget_test.dart` 有 2 个用例因此挂掉）。
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                AgentSwitcher(
                  loadAgents: () async {
                    calls++;
                    throw Exception('boom');
                  },
                  selectAgent: (_) {},
                  currentAgentId: 'a1',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      // 连续多次强制重建（模拟父级因 SSE/时间线更新而重建）。
      for (var i = 0; i < 3; i++) {
        tester.element(find.byType(AgentSwitcher)).markNeedsBuild();
        await tester.pumpAndSettle();
      }

      expect(calls, 1, reason: 'currentAgentId 未变时不应重试，否则会变成请求风暴');
    });

    testWidgets('换对话（currentAgentId 变化）时失败会再给一次机会', (tester) async {
      // 反面：也不能「永不重试」——用户从加载失败的对话切到另一个对话时，
      // 入口应当有机会重新出现。
      var calls = 0;
      Future<List<Agent>> loader() async {
        calls++;
        if (calls == 1) throw Exception('boom');
        return [agent('a1', '写作助手')];
      }

      Widget build(String? currentAgentId) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            actions: [
              AgentSwitcher(
                loadAgents: loader,
                selectAgent: (_) {},
                currentAgentId: currentAgentId,
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(build('a1'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('agent-switcher')), findsNothing);

      await tester.pumpWidget(build('a2'));
      await tester.pumpAndSettle();

      expect(calls, 2, reason: '换了对话应当重试一次');
      expect(find.byKey(const ValueKey('agent-switcher')), findsOneWidget);
    });
  });

  group('点选即本地生效：不弹确认、不发请求', () {
    testWidgets('点菜单项直接回调 selectAgent（无确认框）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('agent-option-a2')));
      await tester.pumpAndSettle();

      expect(lastSelected, 'a2');
      expect(
        find.byKey(const ValueKey('agent-switch-confirm')),
        findsNothing,
        reason: '选择是本地动作（不归档任何绑定），弹确认只会变成形式主义',
      );
    });

    testWidgets('选当前 agent 不产生回调（点了也不该有任何变化）', (tester) async {
      // 当前项已 `enabled: false`，这里兼底“外部重建导致 currentAgentId 变化”的窗口。
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);
      final current = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(current.enabled, isFalse);
      expect(selectCalls, 0);
    });

    testWidgets('点「自动路由」把本地选择清回 null（唯一回退入口）', (tester) async {
      // 选过 agent 之后服务端绑定不会自动回退，只有清成 null 才会让下一条
      // 消息重新走 auto_agent 匹配。webapp 的「自动路由（AI 选择）」首项、
      // 小程序的 null 项都是这个作用。
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('agent-option-auto')));
      await tester.pumpAndSettle();

      expect(selectCalls, 1);
      expect(lastSelected, isNull, reason: 'null = 自动路由');
    });

    testWidgets('菜单头部说明“随下一条消息生效”（而不是要求确认）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);

      // 服务端换 agent 时继承当前 session（顶替归属、不顶替对话），故这里不再
      // 提「上下文会断开」——只有「同 Agent 开新会话」才会断开。
      expect(find.textContaining('随下一条消息生效'), findsOneWidget);
      expect(find.textContaining('沿用当前对话上下文'), findsOneWidget);
    });
  });

  group('菜单内容', () {
    testWidgets('currentAgentId 在同一页内变化后，菜单勾选与禁用跟着重建', (tester) async {
      // ## 这个用例钉住什么（issue #87 的选 agent 半边）
      //
      // 选 agent 是纯本地的，但 AppBar 的 rebuild 由**父页**驱动：路由里
      // `selectAgent` 后 setState，把新的 `currentAgentId` 传下来。State 若
      // 不在 `didUpdateWidget` 里同步派生状态，菜单就会拿初始化时的旧值——
      // 「agent_a → 自动 → 再点 agent_a」的第三步静默失败（项仍禁用，
      // `_select` 的同值短路再把二次点选丢弃，下一条消息仍按 auto 发）。
      // StateSetter 只为拿到外层 setState；ignore 否则分析器报未使用。
      // ignore: unused_local_variable
      late StateSetter setOuter;
      String? current = 'a1';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                StatefulBuilder(
                  builder: (context, setState) {
                    setOuter = setState;
                    return AgentSwitcher(
                      loadAgents: () async => [
                        agent('a1', '写作助手'),
                        agent('a2', '代码助手'),
                      ],
                      selectAgent: (agentId) =>
                          setState(() => current = agentId),
                      currentAgentId: current,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 选 a2：本地值经回调变为 a2，外层重建。
      await openMenu(tester);
      await tester.tap(find.byKey(const ValueKey('agent-option-a2')));
      await tester.pumpAndSettle();
      expect(current, 'a2');

      // 再开菜单：勾选与禁用必须反映**新**值（a2 勾选禁用，a1 可点）。
      await openMenu(tester);
      final a2 = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a2')),
      );
      final a1 = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(a2.checked, isTrue, reason: '菜单重建后勾选跟着 currentAgentId 走');
      expect(a2.enabled, isFalse);
      expect(a1.enabled, isTrue);
      await tester.tap(find.byKey(const ValueKey('agent-option-auto')));
      await tester.pumpAndSettle();
      expect(current, isNull);

      // 自动 → 再选回 a1：修复前 a1 的菜单项仍禁用（读了初始快照），点击
      // 被吞，本地值停在 null——下一条消息依旧 auto。
      await openMenu(tester);
      final a1Again = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(
        a1Again.enabled,
        isTrue,
        reason: 'currentAgentId 变化后菜单不得再用旧快照禁用其它项',
      );
      await tester.tap(find.byKey(const ValueKey('agent-option-a1')));
      await tester.pumpAndSettle();
      expect(current, 'a1');
    });

    testWidgets('当前 agent 被勾选', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);

      final item = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(item.checked, isTrue);

      final other = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a2')),
      );
      expect(other.checked, isFalse);
    });

    testWidgets('当前 agent 的菜单项不可选（选了也不会有任何变化）', (tester) async {
      // 选择是纯本地的：选到当前值既不会改本地值、也不会发请求，
      // 留着可点只会让用户怀疑「点了没反应」。webapp 的 `AgentSelector.tsx`
      // 用 `disabled={isCurrent}` 做了同一件事。
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);

      final current = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(current.enabled, isFalse, reason: '当前 agent 不应可点');

      final other = tester.widget<CheckedPopupMenuItem<Object?>>(
        find.byKey(const ValueKey('agent-option-a2')),
      );
      expect(other.enabled, isTrue, reason: '其他 agent 必须可点');
    });

    testWidgets('按 group_name 分节展示（组头 + 组内顺序）', (tester) async {
      // Agent.groupName 的文档写着「用于下拉里分节展示」（agent.dart），
      // 服务端 agentDTO 也真的返回了它（agents.go 的 group_name）——
      // 此前 Flutter 侧完全没用，导致 32 个 agent 平铺成一个长列表。
      await pumpSwitcher(
        tester,
        agents: const [
          Agent(id: 'a1', name: '法务合规助手', groupName: '助手'),
          Agent(id: 'a2', name: '营销策略长', groupName: '营销'),
          Agent(id: 'a3', name: '财务记账助手', groupName: '助手'),
        ],
        currentAgentId: 'a1',
      );

      await openMenu(tester);

      expect(find.byKey(const ValueKey('agent-group-助手')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-group-营销')), findsOneWidget);

      // 组间按组名 code-unit 升序：「助手」(U+4F50) 在「营销」(U+8425) 之前。
      final helperY = tester
          .getTopLeft(find.byKey(const ValueKey('agent-group-助手')))
          .dy;
      final marketingY = tester
          .getTopLeft(find.byKey(const ValueKey('agent-group-营销')))
          .dy;
      expect(helperY, lessThan(marketingY));

      // 组内保持服务端顺序（a1 在 a3 之前），且 a3 在「助手」组头之后、
      // 「营销」组头之前。
      final a1Y = tester
          .getTopLeft(find.byKey(const ValueKey('agent-option-a1')))
          .dy;
      final a3Y = tester
          .getTopLeft(find.byKey(const ValueKey('agent-option-a3')))
          .dy;
      expect(a1Y, greaterThan(helperY));
      expect(a3Y, greaterThan(a1Y));
      expect(a3Y, lessThan(marketingY));
    });

    testWidgets('全未分组时不显示「未分组」组头（那只是噪音）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [agent('a1', '写作助手'), agent('a2', '代码助手')],
        currentAgentId: 'a1',
      );

      await openMenu(tester);

      expect(find.byKey(const ValueKey('agent-group-未分组')), findsNothing);
    });
  });

  group('大列表：搜索弹层（issue: 32 个 agent 平铺不可用）', () {
    /// 生产实测形状：5 个分组、超过 searchThreshold 的数量。
    List<Agent> manyAgents() => const [
      Agent(id: 'a1', name: '研究助手', groupName: '助手'),
      Agent(id: 'a2', name: '编程助手', groupName: '助手'),
      Agent(
        id: 'a3',
        name: '法务合规助手',
        groupName: '助手',
        description: '合同审查与风险提示',
      ),
      Agent(id: 'a4', name: '营销策略长', groupName: '营销'),
      Agent(id: 'a5', name: '增长与留任运营', groupName: '营销'),
      Agent(id: 'a6', name: '金融助手', groupName: '1.助手'),
      Agent(id: 'a7', name: '图片创作', groupName: '多媒体'),
      Agent(id: 'a8', name: '音乐创作', groupName: '多媒体'),
      Agent(id: 'a9', name: '小说创作', groupName: '文学'),
    ];

    testWidgets('超过阈值时不再用 PopupMenu（itemBuilder 塞不进输入框）', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      // ⚠️ 不能用 `find.byType(PopupMenuButton<Object?>)`：`byType` 比较的是
      // `widget.runtimeType == T`，而实际运行时类型是
      // `PopupMenuButton<_SwitcherAction>`（私有泛型），两者不相等。
      expect(find.byWidgetPredicate((w) => w is PopupMenuButton), findsNothing);
      // 标签仍在（compact=false 时的既有行为）。
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-switcher-label')))
            .data,
        '研究助手',
      );
    });

    testWidgets('未超阈值时仍是 PopupMenu（小列表不引入搜索负担）', (tester) async {
      await pumpSwitcher(
        tester,
        agents: [
          for (var i = 0; i < AgentSwitcher.searchThreshold; i++)
            agent('a$i', '助手$i'),
        ],
        currentAgentId: 'a0',
      );

      expect(
        find.byWidgetPredicate((w) => w is PopupMenuButton),
        findsOneWidget,
      );
    });

    testWidgets('点开弹层：搜索框自动聚焦、分组分节、数量正确', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agent-picker')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-picker-search')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-picker-count')))
            .data,
        '9',
      );

      // 弹层是固定高度的 ListView（惰性建元素），后面的分组一开始不在树上
      // ——那正是用户真实看到的情形（需要滚动）。组间按 code-unit 序：
      // `1.助手 < 助手 < 多媒体 < 文学 < 营销`，故「营销」在最后。
      expect(
        find.byKey(const ValueKey('agent-picker-group-1.助手')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-picker-group-助手')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-picker-group-营销')),
        findsNothing,
        reason: '最后一个分组初始在视口外（惰性构建），需滚动才可见',
      );

      await tester.dragUntilVisible(
        find.byKey(const ValueKey('agent-picker-group-营销')),
        find.byType(ListView),
        const Offset(0, -80),
      );
      await tester.pumpAndSettle();

      for (final g in ['多媒体', '文学', '营销']) {
        expect(
          find.byKey(ValueKey('agent-picker-group-$g')),
          findsOneWidget,
          reason: '滚动后应能看到分组「$g」的组头',
        );
      }
    });

    testWidgets('输入即过滤，无命中显示空状态', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('agent-picker-search')),
        '法务',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agent-option-a3')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-option-a1')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-picker-count')))
            .data,
        '1',
      );

      await tester.enterText(
        find.byKey(const ValueKey('agent-picker-search')),
        '不存在的词',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agent-picker-empty')), findsOneWidget);
    });

    testWidgets('可搜描述（用户记得的是能力而不是名字）', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('agent-picker-search')),
        '合同',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agent-option-a3')), findsOneWidget);
    });

    testWidgets('当前 agent 在弹层里置灰且不可点', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();

      final current = tester.widget<ListTile>(
        find.byKey(const ValueKey('agent-option-a1')),
      );
      expect(current.enabled, isFalse);
      expect(current.onTap, isNull);
      expect(find.text('当前'), findsOneWidget);
    });

    testWidgets('点选其他 agent 后仍直接回调（换了载体也不弹确认框）', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-option-a2')));
      await tester.pumpAndSettle();

      // 弹层已关闭，且没有确认框——选择就是本地动作。
      expect(find.byKey(const ValueKey('agent-picker')), findsNothing);
      expect(find.byKey(const ValueKey('agent-switch-confirm')), findsNothing);
      expect(lastSelected, 'a2');
    });

    testWidgets('弹层首行也是自动路由（大列表同样能清回 null）', (tester) async {
      await pumpSwitcher(tester, agents: manyAgents(), currentAgentId: 'a1');

      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-option-auto')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('agent-option-auto')));
      await tester.pumpAndSettle();

      expect(selectCalls, 1);
      expect(lastSelected, isNull);
      expect(find.byKey(const ValueKey('agent-picker')), findsNothing);
    });
  });
}
