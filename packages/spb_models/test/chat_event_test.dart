import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [ChatEvent] 的契约测试。
///
/// ## 为什么两种命名形态都要测
///
/// 服务端有**两个**事件序列化点，字段命名不同：
///
/// | 来源 | 序列化点 | 命名 |
/// |---|---|---|
/// | SSE 实时流 | `chatbus.Event` 的结构体 JSON tag | camelCase |
/// | timeline / search | `server/chat.go` 的 `eventToDict` | **snake_case** |
///
/// 客户端只支持 camelCase 时，timeline 整段解析抛 [FormatException]，而该异常会被
/// `ChatStreamController._backfill` 的 `catch (e)` 吞掉——表现为「历史回填永久
/// 静默为空」，没有任何显式报错。故必须显式断言 snake_case 也能解析。
void main() {
  /// `eventToDict` 的真实输出形状（`internal/server/chat.go`）。
  ///
  /// 逐字对齐服务端键名与类型：`agent_id`/`session_id` 由 Go 的 `nullStr` 产出，
  /// 空值时是 JSON `null`；`global_seq` 是 int64（`omitempty` 但此处为真实值）。
  Map<String, dynamic> eventToDictShape() => {
    'event_id': 'evt_01HZX',
    'turn_id': 'turn_01HZY',
    'group_id': 'grp_01HZZ',
    'user_id': 'usr_01HZW',
    'agent_id': 'agt_01HZV',
    'session_id': null,
    'event_type': 'message',
    'seq': 3,
    'global_seq': 12345,
    'source': 'pigo',
    'payload': {'text': '你好', 'status': 'streaming'},
    'created_at': '2024-03-05T08:09:10.345Z',
  };

  /// SSE 实时流的形状（`chatbus.Event` 的 JSON tag）。
  Map<String, dynamic> sseShape() => {
    'eventId': 'evt_sse_1',
    'userId': 'usr_1',
    'groupId': 'grp_1',
    'turnId': 'turn_1',
    'sessionId': 'ses_1',
    'agentId': 'agt_1',
    'eventType': 'message',
    'seq': 1,
    'globalSeq': 999,
    'source': 'pigo',
    'payload': {'text': '流式增量'},
    'createdAt': '2026-09-28T10:11:12.345Z',
    'transient': true,
  };

  group('snake_case（timeline / search 形状）', () {
    test('snake_case 的 eventToDict 输出能被解析且字段非空', () {
      final ev = ChatEvent.fromJson(eventToDictShape());

      expect(ev.eventId, 'evt_01HZX');
      expect(ev.eventType, 'message');
      expect(ev.turnId, 'turn_01HZY');
      expect(ev.groupId, 'grp_01HZZ');
      expect(ev.userId, 'usr_01HZW');
      expect(ev.agentId, 'agt_01HZV');
      expect(ev.sessionId, isNull, reason: 'Go 侧 nullStr 产出 JSON null');
      expect(ev.seq, 3);
      expect(ev.globalSeq, 12345);
      expect(ev.source, 'pigo');
      expect(ev.text, '你好');
    });

    test('snake_case 的 created_at 被解析为 UTC 时间（非「现在」兜底）', () {
      final ev = ChatEvent.fromJson(eventToDictShape());

      expect(ev.createdAt, DateTime.utc(2024, 3, 5, 8, 9, 10, 345));
      expect(ev.createdAt.isUtc, isTrue);
      // 兜底路径会给出「现在」。用「与现在的距离」反证 created_at 真被读到了：
      // 固定日期（2024-03）与当前时间相差必然远超 30 天，而兜底值为 0。
      expect(
        ev.createdAt.difference(DateTime.now().toUtc()).inDays.abs(),
        greaterThan(30),
      );
    });

    test('snake_case 缺 event_id 时抛 FormatException（契约破坏不静默）', () {
      final json = eventToDictShape()..remove('event_id');
      expect(() => ChatEvent.fromJson(json), throwsFormatException);
    });

    test('snake_case 缺 event_type 时抛 FormatException', () {
      final json = eventToDictShape()..remove('event_type');
      expect(() => ChatEvent.fromJson(json), throwsFormatException);
    });

    test('snake_case 的 global_seq 缺失时 globalSeq 为 null（不误判为 0）', () {
      final json = eventToDictShape()..remove('global_seq');
      final ev = ChatEvent.fromJson(json);
      expect(ev.globalSeq, isNull);
    });

    test('snake_case 的 timeline 事件按 isTimelineVisible 判定可见', () {
      final ev = ChatEvent.fromJson(eventToDictShape());
      expect(ev.isKnown, isTrue);
      expect(ev.isTimelineVisible, isTrue);
    });
  });

  group('camelCase（SSE 形状）', () {
    test('camelCase 仍优先，且 transient 被识别', () {
      final ev = ChatEvent.fromJson(sseShape());

      expect(ev.eventId, 'evt_sse_1');
      expect(ev.globalSeq, 999);
      expect(ev.sessionId, 'ses_1');
      expect(ev.transient, isTrue);
      expect(ev.isIncremental, isTrue, reason: 'transient message 是增量帧');
    });

    test('camelCase 与 snake_case 同时存在时 camelCase 胜出', () {
      final json = eventToDictShape()
        ..['eventId'] = 'evt_camel'
        ..['globalSeq'] = 777;
      final ev = ChatEvent.fromJson(json);

      expect(ev.eventId, 'evt_camel');
      expect(ev.globalSeq, 777);
    });
  });

  test('toJson 保持 camelCase（本地缓存与 SSE 同形）', () {
    final out = ChatEvent.fromJson(eventToDictShape()).toJson();

    expect(out['eventId'], 'evt_01HZX');
    expect(out['eventType'], 'message');
    expect(out['globalSeq'], 12345);
    expect(out.containsKey('event_id'), isFalse);
    expect(out.containsKey('event_type'), isFalse);
  });

  test('round-trip：toJson 的输出可再次被 fromJson 解析', () {
    final first = ChatEvent.fromJson(eventToDictShape());
    final second = ChatEvent.fromJson(first.toJson());

    expect(second.eventId, first.eventId);
    expect(second.eventType, first.eventType);
    expect(second.globalSeq, first.globalSeq);
    expect(second.text, first.text);
  });

  test('未知事件类型不抛异常（向前兼容），但 isKnown 为 false', () {
    final json = eventToDictShape()..['event_type'] = 'brand_new_event_type';
    final ev = ChatEvent.fromJson(json);

    expect(ev.eventType, 'brand_new_event_type');
    expect(ev.isKnown, isFalse);
    expect(ev.isTimelineVisible, isFalse);
  });

  test('user_message 是已知且 timeline 可见的事件类型', () {
    final json = eventToDictShape()
      ..['event_type'] = EventTypes.userMessage
      ..['payload'] = {'input': '帮我看看这个', 'status': 'queued'};
    final ev = ChatEvent.fromJson(json);

    expect(ev.isKnown, isTrue);
    expect(ev.isTimelineVisible, isTrue);
  });

  group('归属反馈访问器（routing_feedback_request / routing_feedback）', () {
    /// 造一个 routing_feedback_request 事件（Go feedbackRequestPayload 真实形状，
    /// 见 classify_feedback_request.go / BuildClassifyFeedbackRequest）。
    // ⚠️ extra 必须用 `...` 并入 payload 字面量，不能写 `..['payload'] = {...}..addAll(extra)`：
    // 级联 `..` 的目标是**最左操作数**（这里的事件 map），第二个 `..addAll` 会并到
    // 事件对象而非 payload——表现为「覆盖了却没生效」，且编译期无任何提示。
    ChatEvent feedbackRequest([Map<String, dynamic> extra = const {}]) =>
        ChatEvent.fromJson(
          eventToDictShape()
            ..['event_type'] = EventTypes.routingFeedbackRequest
            ..['payload'] = <String, dynamic>{
              'question': '这条消息我归到了「团队周报」，准确吗？',
              'options': [
                {'label': '准确', 'reply': '反馈#正确'},
                {'label': '不准确', 'reply': '反馈#错误'},
              ],
              'token': 'evt_01HZX',
              'evaluated_turn_id': 'turn_01HZY',
              'chosen_group_id': 'grp_01HZZ',
              'candidate_ids': ['grp_01HZZ', 'grp_other'],
              ...extra,
            },
        );

    test('读 question / token / evaluated_turn_id / chosen_group_id', () {
      final ev = feedbackRequest({});

      expect(ev.feedbackQuestion, '这条消息我归到了「团队周报」，准确吗？');
      expect(ev.feedbackToken, 'evt_01HZX', reason: 'token = 事件自身 id（服务端约定）');
      expect(ev.feedbackEvaluatedTurnId, 'turn_01HZY');
      expect(ev.feedbackChosenGroupId, 'grp_01HZZ');
    });

    test('options 取每项的 label（语义真源），非 reply', () {
      final ev = feedbackRequest({});

      expect(ev.feedbackOptions, ['准确', '不准确']);
    });

    test('options 容忍字符串数组与空缺字段（payload 是 map[string]any）', () {
      expect(
        feedbackRequest({
          'options': ['准确', '不准确'],
        }).feedbackOptions,
        ['准确', '不准确'],
      );
      expect(
        feedbackRequest({
          'options': [
            {'reply': '反馈#正确'},
          ],
        }).feedbackOptions,
        isEmpty,
        reason: '无 label 的项不该产出空串选项',
      );
      expect(feedbackRequest({'options': null}).feedbackOptions, isEmpty);
    });

    test('spec 字段存在时被忽略（设计内路径：语义真源在 options）', () {
      final ev = feedbackRequest({
        'spec': {
          'root': 'r1',
          'elements': {
            'r1': {
              'id': 'r1',
              'type': 'card',
              'children': ['b1'],
            },
            'b1': {
              'id': 'b1',
              'type': 'button',
              'props': {'label': '准确'},
            },
          },
        },
      });

      // 访问器照常工作，spec 不产生任何影响。
      expect(ev.feedbackOptions, ['准确', '不准确']);
      expect(ev.feedbackToken, 'evt_01HZX');
    });

    test('token 缺失返回空串（异常载荷，UI 据此禁用按钮）', () {
      final ev = feedbackRequest({'token': null});

      expect(ev.feedbackToken, '');
    });

    test('question 缺失时给默认问句（不渲染空文案）', () {
      expect(feedbackRequest({'question': null}).feedbackQuestion, isNotEmpty);
    });

    test('routing_feedback：correct 容忍 bool 与字符串', () {
      ChatEvent feedback(Object? correct) => ChatEvent.fromJson(
        eventToDictShape()
          ..['event_type'] = EventTypes.routingFeedback
          ..['payload'] = {'correct': correct, 'chosen_index': 1},
      );

      expect(feedback(true).feedbackCorrect, isTrue);
      expect(feedback(false).feedbackCorrect, isFalse);
      expect(feedback('true').feedbackCorrect, isTrue);
      expect(feedback('false').feedbackCorrect, isFalse);
      expect(
        feedback(null).feedbackCorrect,
        isNull,
        reason: '「没标注」不能被当成「标注为错」（null ≠ false）',
      );
    });
  });

  group('turn_activity 访问器', () {
    /// 造一个 turn_activity 事件（Go `upgradeHeartbeatToActivity` 真实形状）。
    ChatEvent activity([Map<String, dynamic> extra = const {}]) =>
        ChatEvent.fromJson(
          eventToDictShape()
            ..['event_type'] = EventTypes.turnActivity
            ..['transient'] = true
            ..['payload'] = <String, dynamic>{
              'elapsed_ms': 45000,
              'last_event_type': 'tool_call',
              'since_last_event_ms': 3200,
              'content': '（pigo 执行中…）',
              ...extra,
            },
        );

    test('turn_activity 是已知事件，但不进时间线（进度提示非正文）', () {
      final ev = activity();

      expect(ev.isKnown, isTrue, reason: '漂移会让 isKnown=false 而静默丢弃');
      expect(ev.isTimelineVisible, isFalse, reason: '它是空窗期进度提示，不应污染时间线正文');
      expect(ev.transient, isTrue, reason: '服务端标为 Transient，不落库不回放');
    });

    test('读 elapsed_ms / last_event_type / since_last_event_ms', () {
      final ev = activity();

      expect(ev.turnActivityElapsedMs, 45000);
      expect(ev.turnActivityLastEventType, 'tool_call');
      expect(ev.turnActivitySinceLastEventMs, 3200);
    });

    test('数值字段容忍字符串（payload 是 map[string]any）', () {
      final ev = activity({
        'elapsed_ms': '45000',
        'since_last_event_ms': '3200',
      });

      expect(ev.turnActivityElapsedMs, 45000);
      expect(ev.turnActivitySinceLastEventMs, 3200);
    });

    test('首个活动（尚无上一步事件）时上一步字段为 null，而非 0/空串', () {
      final ev = activity({
        'last_event_type': null,
        'since_last_event_ms': null,
      });

      expect(ev.turnActivityElapsedMs, 45000, reason: 'elapsed_ms 总在');
      expect(ev.turnActivityLastEventType, isNull);
      expect(
        ev.turnActivitySinceLastEventMs,
        isNull,
        reason: 'null ≠ 0：「没有上一步」与「上一步就在此刻」不同',
      );
    });

    test('非 turn_activity 事件的访问器返回 null', () {
      final ev = ChatEvent.fromJson(
        eventToDictShape()
          ..['event_type'] = EventTypes.message
          ..['payload'] = {'text': 'hi', 'elapsed_ms': 999},
      );

      expect(ev.turnActivityElapsedMs, isNull);
      expect(ev.turnActivityLastEventType, isNull);
      expect(ev.turnActivitySinceLastEventMs, isNull);
    });
  });

  group('group_updated 访问器', () {
    /// 造一个 group_updated 事件（Go `PublishGroupUpdated` 真实形状）。
    ChatEvent groupUpdated([Map<String, dynamic> extra = const {}]) =>
        ChatEvent.fromJson(
          eventToDictShape()
            ..['event_type'] = EventTypes.groupUpdated
            ..['transient'] = true
            ..['payload'] = <String, dynamic>{
              'op': 'created',
              'group': {'id': 'grp_new', 'title': '新对话', 'status': 'active'},
              ...extra,
            },
        );

    test('group_updated 是已知事件，但不进时间线（驱动列表刷新）', () {
      final ev = groupUpdated();

      expect(ev.isKnown, isTrue, reason: '漂移会让 isKnown=false 而静默丢弃');
      expect(ev.isTimelineVisible, isFalse);
      expect(ev.transient, isTrue);
    });

    test('读 op 与 group 快照', () {
      final ev = groupUpdated();

      expect(ev.groupUpdateOp, 'created');
      expect(ev.groupUpdateSnapshot, {
        'id': 'grp_new',
        'title': '新对话',
        'status': 'active',
      });
    });

    test('六种 op 都能原样读出（值域由服务端定义，客户端不枚举）', () {
      for (final op in [
        'created',
        'deleted',
        'archived',
        'active',
        'title',
        'metadata',
      ]) {
        expect(groupUpdated({'op': op}).groupUpdateOp, op);
      }
    });

    test('未知 op 不被当异常（服务端可新增），原样返回供调用方忽略', () {
      expect(groupUpdated({'op': 'renamed'}).groupUpdateOp, 'renamed');
    });

    test('group 缺失或类型异常时快照为 null', () {
      expect(groupUpdated({'group': null}).groupUpdateSnapshot, isNull);
      expect(groupUpdated({'group': 'grp_x'}).groupUpdateSnapshot, isNull);
      expect(groupUpdated({'op': null}).groupUpdateOp, isNull);
    });

    test('非 group_updated 事件的访问器返回 null', () {
      final ev = ChatEvent.fromJson(
        eventToDictShape()
          ..['event_type'] = EventTypes.goalUpdated
          ..['payload'] = {'op': 'created'},
      );

      expect(ev.groupUpdateOp, isNull);
      expect(ev.groupUpdateSnapshot, isNull);
    });
  });

  group('gate 决策访问器', () {
    /// 造一个 adaptive_decision 事件（Go 现行扁平 payload）。
    ChatEvent adaptive(Map<String, dynamic> payload) => ChatEvent.fromJson(
      eventToDictShape()
        ..['event_type'] = EventTypes.adaptiveDecision
        ..['payload'] = payload,
    );

    /// 造一个 goal_gate_decision 事件。
    ChatEvent goalGate(Map<String, dynamic> payload) => ChatEvent.fromJson(
      eventToDictShape()
        ..['event_type'] = EventTypes.goalGateDecision
        ..['payload'] = payload,
    );

    test('adaptive_decision：读 action / gate_source / confidence / reason', () {
      final ev = adaptive({
        'action': 'auto_continue',
        'gate_source': 'llm_gate',
        'confidence': 0.72,
        'reason': '任务未完成',
        'next_input': '继续写',
      });

      expect(ev.gateAction, 'auto_continue');
      expect(ev.gateSource, 'llm_gate');
      expect(ev.gateConfidence, 0.72);
      expect(ev.gateReason, '任务未完成');
      expect(ev.gateNextInputPreview, '继续写');
    });

    test('confidence 容忍整数与字符串（payload 是 map[string]any）', () {
      expect(adaptive({'confidence': 1}).gateConfidence, 1.0);
      expect(adaptive({'confidence': '0.5'}).gateConfidence, 0.5);
      expect(adaptive({'confidence': null}).gateConfidence, isNull);
    });

    test('goal_gate_decision：读 goal_achieved / stopped / stop_reason', () {
      final ev = goalGate({
        'goal_achieved': false,
        'stopped': true,
        'stop_reason': 'task_blocked',
        'source': 'task_blocked',
        'decision_reason': '有任务受阻',
      });

      expect(ev.goalAchieved, isFalse);
      expect(ev.goalStopped, isTrue);
      expect(ev.goalStopReason, 'task_blocked');
      // goal_gate_decision 用 `source`（adaptive 用 `gate_source`），
      // 访问器要两者都认。
      expect(ev.gateSource, 'task_blocked');
      // goal gate 用 `decision_reason`（adaptive 用 `reason`）。
      expect(ev.gateReason, '有任务受阻');
      // goal gate 没有 action / confidence。
      expect(ev.gateAction, isNull);
      expect(ev.gateConfidence, isNull);
    });

    test('goal_achieved/stopped 缺失时默认为 false（不误判为真）', () {
      final ev = goalGate({});
      expect(ev.goalAchieved, isFalse);
      expect(ev.goalStopped, isFalse);
    });

    test('goal_achieved 只认布尔 true，字符串 "true" 不算', () {
      // 服务端 payload 是 map[string]any，JSON 反序列化后布尔就是布尔；
      // 若有人把它写成字符串，应显式不认，避免把「假」当「真」。
      final ev = goalGate({'goal_achieved': 'true'});
      expect(ev.goalAchieved, isFalse);
    });

    test('非 gate 事件的 gate 访问器返回 null/默认值', () {
      final ev = ChatEvent.fromJson(
        eventToDictShape()
          ..['event_type'] = EventTypes.message
          ..['payload'] = {'text': 'hi'},
      );

      expect(ev.gateAction, isNull);
      expect(ev.gateSource, isNull);
      expect(ev.gateReason, isNull);
      expect(ev.gateConfidence, isNull);
      expect(ev.goalAchieved, isFalse);
      expect(ev.goalStopped, isFalse);
    });
  });
}
