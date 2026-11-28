import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [GroupGatePanel] 的 widget 测试。
///
/// 面板是纯展示（无回调、无网络），故测试只需喂数据 + 断言渲染。
void main() {
  GateDecision decision(
    String id, {
    GateDecisionKind kind = GateDecisionKind.autoContinue,
    GateSourceKind source = GateSourceKind.llmGate,
    String rawSource = 'llm_gate',
    double? confidence,
    String? reason,
    String? nextInputPreview,
    String? stopReason,
    String turnId = 'turn_1',
  }) => GateDecision(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    kind: kind,
    source: source,
    rawSource: rawSource,
    confidence: confidence,
    reason: reason,
    nextInputPreview: nextInputPreview,
    stopReason: stopReason,
    turnId: turnId,
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required List<GateDecision> decisions,
    bool showHeader = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupGatePanel(decisions: decisions, showHeader: showHeader),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('空态', () {
    testWidgets('无决策时显示空提示', (tester) async {
      await pumpPanel(tester, decisions: const []);

      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);
      expect(find.text('这一轮还没有 gate 决策'), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-list')), findsNothing);
    });

    testWidgets('可自定义空提示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GroupGatePanel(decisions: [], emptyHint: '暂无诊断数据'),
          ),
        ),
      );
      expect(find.text('暂无诊断数据'), findsOneWidget);
    });
  });

  group('渲染', () {
    testWidgets('显示决策标签与来源徽标', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision(
            'g1',
            kind: GateDecisionKind.autoContinue,
            source: GateSourceKind.llmGate,
            reason: '任务未完成',
          ),
        ],
      );

      expect(find.text('继续'), findsOneWidget);
      expect(find.text('LLM 判定'), findsOneWidget);
      expect(find.text('任务未完成'), findsOneWidget);
    });

    testWidgets('默认显示头部与计数', (tester) async {
      await pumpPanel(tester, decisions: [decision('g1'), decision('g2')]);

      expect(find.text('Gate 决策'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('showHeader=false 时不渲染标题行', (tester) async {
      await pumpPanel(tester, decisions: [decision('g1')], showHeader: false);

      expect(find.text('Gate 决策'), findsNothing);
      // 决策本身仍然渲染。
      expect(find.text('继续'), findsOneWidget);
    });

    testWidgets('最新决策排在最上（倒序）', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision('old', kind: GateDecisionKind.stop),
          decision('new', kind: GateDecisionKind.goalCompleted),
        ],
      );

      // 取两个决策标签的纵向位置，新的应在上（y 更小）。
      final newY = tester.getTopLeft(find.text('目标达成')).dy;
      final oldY = tester.getTopLeft(find.text('停止')).dy;
      expect(newY, lessThan(oldY));
    });

    testWidgets('goal gate 显示「目标」来源徽标', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision(
            'g1',
            kind: GateDecisionKind.goalCompleted,
            source: GateSourceKind.goalGate,
            rawSource: 'tasks_completed',
          ),
        ],
      );

      expect(find.text('目标'), findsOneWidget);
      expect(find.text('目标达成'), findsOneWidget);
    });

    testWidgets('need_confirmation 显示待确认标签', (tester) async {
      await pumpPanel(
        tester,
        decisions: [decision('g1', kind: GateDecisionKind.needConfirmation)],
      );

      expect(find.text('待确认'), findsOneWidget);
    });
  });

  group('详情展开', () {
    testWidgets('展开后显示来源、置信度、轮次', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision('g1', confidence: 0.85, reason: '继续下一轮', turnId: 'turn_abc'),
        ],
      );

      // 默认折叠：详情不可见。
      expect(find.text('85%'), findsNothing);

      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      expect(find.text('来源'), findsOneWidget);
      expect(find.text('llm_gate'), findsOneWidget);
      expect(find.text('置信度'), findsOneWidget);
      expect(find.text('85%'), findsOneWidget);
      expect(find.text('turn_abc'), findsOneWidget);
    });

    testWidgets('无置信度时不显示该行（goal gate 无置信度概念）', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision(
            'g1',
            kind: GateDecisionKind.goalCompleted,
            source: GateSourceKind.goalGate,
            rawSource: 'tasks_completed',
          ),
        ],
      );

      await tester.tap(find.text('目标达成'));
      await tester.pumpAndSettle();

      expect(find.text('置信度'), findsNothing);
      expect(find.text('来源'), findsOneWidget);
    });

    testWidgets('stop 决策展开后显示停止原因', (tester) async {
      await pumpPanel(
        tester,
        decisions: [
          decision(
            'g1',
            kind: GateDecisionKind.stop,
            source: GateSourceKind.goalGate,
            stopReason: 'task_blocked',
          ),
        ],
      );

      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();

      expect(find.text('停止原因'), findsOneWidget);
      expect(find.text('task_blocked'), findsOneWidget);
    });

    testWidgets('有 nextInputPreview 时展开显示', (tester) async {
      await pumpPanel(
        tester,
        decisions: [decision('g1', nextInputPreview: '继续写第三章')],
      );

      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();

      expect(find.text('下一步输入预览'), findsOneWidget);
      expect(find.text('继续写第三章'), findsOneWidget);
    });

    testWidgets('unknown 决策不崩溃且显示未知标签', (tester) async {
      await pumpPanel(
        tester,
        decisions: [decision('g1', kind: GateDecisionKind.unknown)],
      );

      expect(find.text('未知'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
