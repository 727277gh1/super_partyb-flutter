import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [GroupDebugPanel] 的 widget 测试。
///
/// 本面板只是把 [GroupToolCallsPanel] 与 [GroupGatePanel] 上下堆叠，
/// 故只验证装配语义（两者都在、分栏可缩放、各自的空态不相互干扰）。
/// 子面板自身的渲染由各自测试覆盖。
void main() {
  ToolCallItem call(String id, {String name = 'bash'}) => ToolCallItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    name: name,
    output: 'done',
    isComplete: true,
  );

  GateDecision decision(String id) => GateDecision(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    kind: GateDecisionKind.autoContinue,
    source: GateSourceKind.llmGate,
    rawSource: 'llm_gate',
    reason: '任务未完成',
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<ToolCallItem> toolCalls = const [],
    List<GateDecision> decisions = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupDebugPanel(toolCalls: toolCalls, decisions: decisions),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('装配', () {
    testWidgets('两个子面板都挂载', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1')],
        decisions: [decision('g1')],
      );

      // 工具调用面板的计数与 Gate 面板的计数都渲染。
      expect(find.text('工具调用'), findsOneWidget);
      expect(find.text('Gate 决策'), findsOneWidget);
      // 分割线。
      expect(find.byType(Divider), findsOneWidget);
    });

    testWidgets('工具调用空态显示，Gate 空态也显示', (tester) async {
      await pumpPanel(tester);

      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);
    });

    testWidgets('一侧空一侧有时，两侧都不崩', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1', name: 'ls')],
        decisions: const [],
      );

      // 工具有内容、Gate 空态。
      expect(find.text('ls'), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);

      await pumpPanel(tester, toolCalls: const [], decisions: [decision('g1')]);

      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.text('任务未完成'), findsOneWidget);
    });
  });

  group('布局', () {
    testWidgets('上下分栏：工具在上、Gate 在下', (tester) async {
      await pumpPanel(
        tester,
        toolCalls: [call('t1', name: 'top_tool')],
        decisions: [decision('g1')],
      );

      final toolsY = tester.getTopLeft(find.text('top_tool')).dy;
      final gateY = tester.getTopLeft(find.text('任务未完成')).dy;
      expect(toolsY, lessThan(gateY));
    });

    testWidgets('Flex 比例可通过参数调整', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDebugPanel(
              toolCalls: [call('t1')],
              decisions: [decision('g1')],
              toolCallsFlex: 5,
              decisionsFlex: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toolsBox = tester.getSize(
        find.byKey(const ValueKey('toolcalls-list')),
      );
      final gateBox = tester.getSize(find.byKey(const ValueKey('gate-list')));
      // 工具区占比 5/(5+1) ≈ 0.833，gate 区 ≈ 0.167。
      expect(
        toolsBox.height,
        greaterThan(gateBox.height * 3),
        reason: 'flex 5:1 时工具区应远大于 gate 区',
      );
    });
  });
}
