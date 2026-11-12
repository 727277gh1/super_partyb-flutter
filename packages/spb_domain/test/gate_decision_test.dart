import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [collectGateDecisions] / [gateDecisionFrom] 与 [ReductionResult.gateDecisions] 的测试。
///
/// 纯领域函数，可在无头环境完整验证。归约是对话 UI 正确性核心（Gate 决策
/// 之前被 event_reducer 的 default 分支静默丢弃——这是修复它）。
void main() {
  /// 造一个事件。
  ChatEvent ev(
    String type, {
    String id = '',
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    int seq = 1,
    int globalSeq = 1,
  }) => ChatEvent(
    eventId: id.isEmpty ? '${type}_$globalSeq' : id,
    userId: 'usr_1',
    groupId: 'grp_1',
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: globalSeq,
    source: 'test',
    createdAt: DateTime.utc(2024, 3, 5, 8, 9, globalSeq.clamp(0, 59)),
    payload: payload,
  );

  group('collectGateDecisions', () {
    test('adaptive_decision：扁平 payload 解析 action/confidence/reason', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.adaptiveDecision,
          payload: {
            'action': 'auto_continue',
            'confidence': 0.85,
            'reason': '任务未完成',
            'gate_source': 'llm_gate',
            'chain_depth': 1,
          },
        ),
      ]);

      expect(decisions, hasLength(1));
      final d = decisions.single;
      expect(d.kind, GateDecisionKind.autoContinue);
      expect(d.source, GateSourceKind.llmGate);
      expect(d.rawSource, 'llm_gate');
      expect(d.confidence, 0.85);
      expect(d.reason, '任务未完成');
      expect(d.isGoalGate, isFalse);
      expect(d.turnId, 'turn_1');
    });

    test('adaptive_decision：fastpath 与 retry_gate 来源分类', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'auto_repeat', 'gate_source': 'fastpath'},
        ),
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'auto_continue', 'gate_source': 'retry_gate'},
        ),
      ]);

      expect(decisions[0].kind, GateDecisionKind.autoRepeat);
      expect(decisions[0].source, GateSourceKind.fastPath);
      expect(decisions[1].kind, GateDecisionKind.autoContinue);
      expect(decisions[1].source, GateSourceKind.retryGate);
    });

    test('adaptive_decision：need_confirmation 和 stop 是终态', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'need_confirmation', 'gate_source': 'llm_gate'},
        ),
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'stop', 'gate_source': 'llm_gate'},
        ),
      ]);

      expect(decisions[0].kind.isTerminal, isTrue);
      expect(decisions[1].kind.isTerminal, isTrue);
    });

    test('adaptive_decision：未知 action 归 unknown 而非丢弃或抛异常', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'new_future_action', 'gate_source': 'llm_gate'},
        ),
      ]);

      expect(decisions, hasLength(1));
      expect(decisions.single.kind, GateDecisionKind.unknown);
      expect(decisions.single.kind.isTerminal, isFalse);
    });

    test('goal_gate_decision：goal_achieved=true → goal_completed', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.goalGateDecision,
          payload: {
            'goal_achieved': true,
            'source': 'tasks_completed',
            'decision_reason': '所有任务完成',
          },
        ),
      ]);

      expect(decisions.single.kind, GateDecisionKind.goalCompleted);
      expect(decisions.single.isGoalGate, isTrue);
      expect(decisions.single.source, GateSourceKind.goalGate);
      expect(decisions.single.rawSource, 'tasks_completed');
      expect(
        decisions.single.confidence,
        isNull,
        reason: 'goal gate 是确定性判定，无置信度',
      );
    });

    test('goal_gate_decision：stopped=true 且 goal_achieved=false → stop', () {
      final decisions = collectGateDecisions([
        ev(
          EventTypes.goalGateDecision,
          payload: {
            'goal_achieved': false,
            'stopped': true,
            'stop_reason': 'task_blocked',
            'source': 'task_blocked',
          },
        ),
      ]);

      expect(decisions.single.kind, GateDecisionKind.stop);
      expect(decisions.single.stopReason, 'task_blocked');
      expect(decisions.single.kind.isTerminal, isTrue);
    });

    test(
      'goal_gate_decision：goal_achieved=false 且无 stopped → auto_continue',
      () {
        final decisions = collectGateDecisions([
          ev(
            EventTypes.goalGateDecision,
            payload: {
              'goal_achieved': false,
              'source': 'task_in_progress',
              'next_input_preview': '继续写第三章',
            },
          ),
        ]);

        expect(decisions.single.kind, GateDecisionKind.autoContinue);
        expect(decisions.single.kind.isTerminal, isFalse);
        expect(decisions.single.nextInputPreview, '继续写第三章');
      },
    );

    test('goal_gate_decision：goal_gate_failed=true → goal_failed（优先于其他）', () {
      // 对齐 webapp isGoalGateFailed：goal_gate_failed 标记即使 goal_achieved
      // 为 true 也应判失败（LLM 判定失败但 goal_achieved 字段被错误填了）。
      final decisions = collectGateDecisions([
        ev(
          EventTypes.goalGateDecision,
          payload: {
            'goal_achieved': true,
            'goal_gate_failed': true,
            'source': 'task_error_stopped',
          },
        ),
      ]);

      expect(
        decisions.single.kind,
        GateDecisionKind.goalFailed,
        reason: 'goal_gate_failed 优先级最高',
      );
    });

    test('判定优先级：goal_failed > goal_completed > stop > continue', () {
      // 用四组独立事件验证优先级链。
      final cases = <String, Map<String, dynamic>>{
        'failed': {'goal_achieved': true, 'goal_gate_failed': true},
        'completed': {'goal_achieved': true},
        'stop': {'goal_achieved': false, 'stopped': true},
        'continue': {'goal_achieved': false},
      };

      final decisions = {
        for (final e in cases.entries)
          e.key: collectGateDecisions([
            ev(EventTypes.goalGateDecision, payload: e.value),
          ]).single.kind,
      };

      expect(decisions['failed'], GateDecisionKind.goalFailed);
      expect(decisions['completed'], GateDecisionKind.goalCompleted);
      expect(decisions['stop'], GateDecisionKind.stop);
      expect(decisions['continue'], GateDecisionKind.autoContinue);
    });
  });

  group('gateDecisionFrom（单个事件）', () {
    test('非 gate 事件返回 null', () {
      expect(
        gateDecisionFrom(ev(EventTypes.message, payload: {'text': 'hi'})),
        isNull,
      );
      expect(
        gateDecisionFrom(ev(EventTypes.toolCall, payload: {'name': 'read'})),
        isNull,
      );
      expect(
        gateDecisionFrom(ev(EventTypes.gateEvaluated)),
        isNull,
        reason: 'gate_evaluated 是诊断噪声，不进决策通道',
      );
    });

    test('与 collectGateDecisions 单条结果一致', () {
      final e = ev(
        EventTypes.adaptiveDecision,
        payload: {'action': 'stop', 'gate_source': 'llm_gate'},
      );
      final one = gateDecisionFrom(e);
      final batch = collectGateDecisions([e]);
      expect(one, isNotNull);
      expect(batch, hasLength(1));
      expect(one!.kind, batch.single.kind);
      expect(one.source, batch.single.source);
    });
  });

  group('EventReducer.reduce 集成', () {
    test('gate 事件既进 gateDecisions，又不进 items（修复静默丢弃）', () {
      final result = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': '继续'}),
        ev(EventTypes.message, payload: {'text': '好的'}, seq: 2, globalSeq: 2),
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'auto_continue', 'gate_source': 'llm_gate'},
          seq: 3,
          globalSeq: 3,
        ),
        ev(EventTypes.done, seq: 4, globalSeq: 4),
      ]);

      // items 不含 gate 决策（它走独立通道）。
      expect(
        result.items.map((i) => i.runtimeType.toString()),
        containsAll(['UserMessageItem', 'AssistantMessageItem']),
      );
      expect(
        result.items.length,
        2,
        reason: '只有 user message + assistant message；done 不成项',
      );

      // gateDecisions 捕获到了 adaptive_decision。
      expect(result.gateDecisions, hasLength(1));
      expect(result.gateDecisions.single.kind, GateDecisionKind.autoContinue);
    });

    test('多个 gate 决策保持事件顺序', () {
      final result = EventReducer.reduce([
        ev(
          EventTypes.adaptiveDecision,
          payload: {'action': 'auto_continue', 'gate_source': 'fastpath'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.goalGateDecision,
          payload: {'goal_achieved': true, 'source': 'tasks_completed'},
          globalSeq: 2,
        ),
      ]);

      expect(result.gateDecisions, hasLength(2));
      expect(result.gateDecisions[0].kind, GateDecisionKind.autoContinue);
      expect(result.gateDecisions[1].kind, GateDecisionKind.goalCompleted);
    });

    test('无 gate 事件时 gateDecisions 为空', () {
      final result = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': 'hi'}),
        ev(EventTypes.message, payload: {'text': '你好'}, globalSeq: 2),
      ]);

      expect(result.gateDecisions, isEmpty);
    });
  });

  group('GateSourceKind.fromWire', () {
    test('goal gate 的具体原因都归 goalGate', () {
      for (final raw in [
        'tasks_completed',
        'task_blocked',
        'no_tasks',
        'task_error_stopped',
      ]) {
        expect(
          GateSourceKind.fromWire(raw),
          GateSourceKind.goalGate,
          reason: raw,
        );
      }
    });

    test('空值归 unknown', () {
      expect(GateSourceKind.fromWire(null), GateSourceKind.unknown);
      expect(GateSourceKind.fromWire(''), GateSourceKind.unknown);
    });
  });
}
