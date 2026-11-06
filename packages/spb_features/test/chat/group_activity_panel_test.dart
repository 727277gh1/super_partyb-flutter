import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 「动态」面板（`GroupActivityPanel`）测试。
///
/// ## 这个文件防的是什么
///
/// 面板刻意**只收原始状态**（items / activities / staleTurnIds /
/// executionStatus），自己派生「工具调用列表」与「当前轮次状态」。
/// 这是有意的：若由装配层各自算，就会出现「页面说还在跑、面板说已结束」
/// （AGENTS.md §6.17 同一失败模式，只是发生在数据侧）。故这里的断言全部
/// 从**原始状态**出发，覆盖三处会互相矛盾的地方：
///
/// 1. 面板的状态行与页面底部细条同判据（stale 时不能还说「已调 N 个工具」）；
/// 2. 没有进行中的轮次时必须明说，而不是留一条陈旧的「执行中」；
/// 3. `decisions == null`（本端不订阅）与 `decisions == []`（真的没有）
///    必须是两种渲染——后者会被读成「这一轮确实没有决策」。
class _Items {
  static ToolCallItem tool(
    String id, {
    String turnId = 'turn_1',
    String name = 'Read',
    String? output = 'ok',
  }) => ToolCallItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    name: name,
    turnId: turnId,
    output: output,
    isComplete: output != null,
  );

  static AssistantMessageItem text(
    String id, {
    String turnId = 'turn_1',
    String body = 'x',
    bool isStreaming = true,
  }) => AssistantMessageItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    text: body,
    turnId: turnId,
    isStreaming: isStreaming,
  );

  static UserMessageItem user(String id, {String turnId = 'turn_1'}) =>
      UserMessageItem(
        id: id,
        createdAt: DateTime.utc(2026, 1, 1),
        text: '问',
        turnId: turnId,
      );
}

GateDecision _decision(String id) => GateDecision(
  id: id,
  createdAt: DateTime.utc(2026, 1, 1),
  kind: GateDecisionKind.autoContinue,
  source: GateSourceKind.llmGate,
  rawSource: 'llm_gate',
  turnId: 'turn_1',
);

TurnActivitySnapshot _activity({
  String turnId = 'turn_1',
  int elapsedMs = 4000,
  String? lastEventType = 'thought',
}) => TurnActivitySnapshot(
  turnId: turnId,
  elapsedMs: elapsedMs,
  at: DateTime.utc(2026, 1, 1),
  lastEventType: lastEventType,
);

ExecutionStatus _exec(ExecutionStatusKind kind, {int? attempt}) =>
    ExecutionStatus(
      turnId: 'turn_1',
      kind: kind,
      attempt: attempt,
      at: DateTime.utc(2026, 1, 1),
    );

void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    required List<ConversationItem> items,
    Map<String, TurnActivitySnapshot> activities = const {},
    List<GateDecision>? decisions = const [],
    Set<String> staleTurnIds = const {},
    ExecutionStatus? executionStatus,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 面板里两个子列表都是 ListView，必须有界高度。
          body: SizedBox(
            height: 800,
            child: GroupActivityPanel(
              items: items,
              activities: activities,
              decisions: decisions,
              staleTurnIds: staleTurnIds,
              executionStatus: executionStatus,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('面板结构', () {
    testWidgets('状态行固定在顶部 + 工具调用区 + gate 区（三者都有 key）', (tester) async {
      await pumpPanel(
        tester,
        items: [_Items.user('u1'), _Items.tool('t1')],
        decisions: [_decision('d1')],
      );

      expect(find.byKey(const ValueKey('activity-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-status')), findsOneWidget);
      expect(find.byKey(const ValueKey('toolcalls-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具调用从 items 派生，且**最新在上**（面板是倒序视图）', (tester) async {
      await pumpPanel(
        tester,
        items: [
          _Items.tool('t1', name: 'First'),
          _Items.tool('t2', name: 'Second'),
        ],
      );

      // 面板复用 `GroupToolCallsPanel`（倒序、最新在上），与时间线相反。
      final tileNames = tester
          .widgetList<ToolCallTile>(find.byType(ToolCallTile))
          .map((t) => t.name)
          .toList();
      expect(tileNames.first, 'Second');
    });

    testWidgets('非工具项不进列表（正文/用户消息不出现在这里）', (tester) async {
      await pumpPanel(tester, items: [_Items.user('u1'), _Items.text('m1')]);

      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.text('这一轮还没有工具调用'), findsOneWidget);
    });
  });

  /// 只在**状态行**范围内查找（工具卡自己也有转圈 / 文本，全局断言会把它们
  /// 算进来，测不出「状态行说的是什么」）。
  Finder statusFinder(Finder inner) => find.descendant(
    of: find.byKey(const ValueKey('activity-status')),
    matching: inner,
  );

  group('顶部状态行：与页面底部细条同判据', () {
    testWidgets('没有进行中的轮次 → 明说，且不转圈', (tester) async {
      await pumpPanel(tester, items: [_Items.text('m1', isStreaming: false)]);

      expect(find.text('当前没有进行中的轮次'), findsOneWidget);
      expect(find.byIcon(Icons.pause_circle_outline), findsOneWidget);
      expect(
        statusFinder(find.byType(CircularProgressIndicator)),
        findsNothing,
      );
    });

    testWidgets('有工具调用 → 「已调用 N 个工具」+ 最近工具名', (tester) async {
      await pumpPanel(
        tester,
        items: [
          _Items.text('m1'),
          _Items.tool('t1'),
          _Items.tool('t2', name: 'Bash', output: null),
        ],
      );

      // 「已调用 2 个工具」既是状态行文案也可能与卡片文案撞名 → 限定在状态行内。
      expect(statusFinder(find.text('已调用 2 个工具')), findsOneWidget);
      expect(statusFinder(find.text('最近：Bash')), findsOneWidget);
      // 状态行在转圈（工具卡里的未完成工具另有自己的指示器，不限定范围会是 2 个）。
      expect(
        statusFinder(find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
    });

    testWidgets('只有活动快照 → 保留既有「执行中 · 已运行 X」文案', (tester) async {
      await pumpPanel(
        tester,
        items: [_Items.text('m1')],
        activities: {'turn_1': _activity(elapsedMs: 5000)},
      );

      expect(find.text('执行中 · 已运行 5 秒'), findsOneWidget);
      expect(find.text('最近：思考'), findsOneWidget);
    });

    testWidgets('排队 / 重试状态优先显示', (tester) async {
      await pumpPanel(
        tester,
        items: [_Items.text('m1')],
        executionStatus: _exec(ExecutionStatusKind.retryScheduled, attempt: 2),
      );

      expect(find.text('正在安排第 2 次重试'), findsOneWidget);
    });

    testWidgets('⭐ stale 命中时说「长时间无进展」，不得再说「已调 N 个工具」', (tester) async {
      // 页面此时已经在时间线上挂了超时提示条；面板若继续显示「已调用 8 个
      // 工具 · 执行中」，两处就在互相矛盾。
      await pumpPanel(
        tester,
        items: [
          _Items.text('m1'),
          for (var i = 0; i < 8; i++) _Items.tool('t$i'),
        ],
        staleTurnIds: {'turn_1'},
      );

      expect(statusFinder(find.text('长时间无进展 · 可能仍在后台运行')), findsOneWidget);
      expect(statusFinder(find.textContaining('已调用')), findsNothing);
      expect(
        statusFinder(find.byType(CircularProgressIndicator)),
        findsNothing,
      );
    });

    testWidgets('面板按**最后一个**流式项判当前轮次（陈旧 turn 不复活）', (tester) async {
      // turn_1 很久以前丢了 done（无流式标记），当前在跑的是 turn_2。
      // 若面板遍历所有 turn，它会永远显示 turn_1 的状态（§5.8 同一理由）。
      await pumpPanel(
        tester,
        items: [
          _Items.tool('old', turnId: 'turn_1', name: 'OldTool'),
          _Items.text('m2', turnId: 'turn_2', body: '正在生成的正文'),
        ],
        activities: {'turn_1': _activity(turnId: 'turn_1')},
      );

      // 当前轮次 = turn_2：它没有工具、也没有自己的活动快照 → 状态行说明
      // 「没有进行中的轮次」（正文在流式但没有任何过程信号可报，细条本来也不画）。
      // ⚠️ 工具调用列表**照旧**显示 OldTool——那是历史事实，与「现在在跑谁」无关。
      expect(statusFinder(find.text('当前没有进行中的轮次')), findsOneWidget);
      // turn_1 的活动快照没有被误用（否则状态行会出现「最近：思考」）。
      expect(statusFinder(find.text('最近：思考')), findsNothing);
      expect(statusFinder(find.textContaining('已调用')), findsNothing);
      // 反向确认列表本身没有跟着隐藏。
      expect(find.text('OldTool'), findsOneWidget);
    });
  });

  group('gate 决策区：null（本端不订阅）与空列表（真的没有）必须可区分', () {
    testWidgets('decisions 为 null → 整块不渲染（不给出假的结论）', (tester) async {
      await pumpPanel(tester, items: [_Items.tool('t1')], decisions: null);

      expect(find.byKey(const ValueKey('gate-list')), findsNothing);
      expect(find.byKey(const ValueKey('gate-empty')), findsNothing);
      expect(find.text('这一轮还没有 gate 决策'), findsNothing);
    });

    testWidgets('decisions 为空列表 → 渲染空态（这是真的「没有」）', (tester) async {
      await pumpPanel(tester, items: [_Items.tool('t1')], decisions: const []);

      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);
      expect(find.text('这一轮还没有 gate 决策'), findsOneWidget);
    });

    testWidgets('有决策时列出（复用 GroupGatePanel）', (tester) async {
      await pumpPanel(
        tester,
        items: [_Items.tool('t1')],
        decisions: [_decision('d1')],
      );

      expect(find.byKey(const ValueKey('gate-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-empty')), findsNothing);
    });
  });
}
