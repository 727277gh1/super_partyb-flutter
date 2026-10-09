import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [EventReducer] 的归约正确性测试。
///
/// 归约是对话 UI 的正确性核心，且是纯函数——所有状态显式传入，故可无头单测。
void main() {
  /// 造一个事件。默认 transient=false（落库事件），便于用 `globalSeq` 排序。
  ChatEvent ev(
    String type, {
    String id = '',
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    int seq = 1,
    int globalSeq = 1,
    String groupId = 'grp_1',
    String? agentId,
  }) => ChatEvent(
    eventId: id.isEmpty ? '${type}_$globalSeq' : id,
    userId: 'usr_1',
    groupId: groupId,
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: transient ? null : globalSeq,
    source: 'test',
    createdAt: DateTime.utc(2024, 3, 5, 8, 9, globalSeq.clamp(0, 59)),
    payload: payload,
    transient: transient,
    agentId: agentId,
  );

  group('user_message → UserMessageItem', () {
    test('正文取自 payload[input]，而非 payload[text]', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          payload: {'input': '帮我看看这个报错', 'status': 'queued'},
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<UserMessageItem>());
      expect((item as UserMessageItem).text, '帮我看看这个报错');
      expect(item.turnId, 'turn_1');
    });

    test('payload[input] 缺失时回退 payload[text]', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'text': '兜底文本'}),
      ]);

      expect((r.items.single as UserMessageItem).text, '兜底文本');
    });

    test('payload 为 null 时产出空文本项被跳过（不渲染空气泡）', () {
      final r = EventReducer.reduce([ev(EventTypes.userMessage)]);
      expect(r.items, isEmpty);
    });

    test('id 取事件 eventId，供列表 diff 使用', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, id: 'evt_user_1', payload: {'input': 'hi'}),
      ]);

      expect(r.items.single.id, 'evt_user_1');
    });

    test('落库的 user_message 推进 lastEventId（可作 SSE 游标）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, id: 'evt_user_9', payload: {'input': 'hi'}),
      ]);

      expect(r.lastEventId, 'evt_user_9');
    });
  });

  group('user_message 去重（乐观回显 + 服务端广播）', () {
    test('同一 turnId 的两条只产出一个气泡', () {
      final r = EventReducer.reduce([
        // 客户端乐观回显（transient，无 globalSeq）。
        ev(
          EventTypes.userMessage,
          id: 'local-1',
          turnId: 'turn_7',
          payload: {'input': '你好'},
          transient: true,
        ),
        // 服务端随后广播的真实事件（同一 turnId）。
        ev(
          EventTypes.userMessage,
          id: 'evt_real',
          turnId: 'turn_7',
          payload: {'input': '你好'},
          globalSeq: 42,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as UserMessageItem;
      expect(item.text, '你好');
      // 服务端事件胜出：id 换成真实 eventId，游标才有意义。
      expect(item.id, 'evt_real');
      expect(r.lastEventId, 'evt_real');
    });

    test('不同 turnId 的用户消息各自成项（不误合并）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, turnId: 'turn_a', payload: {'input': 'A'}),
        ev(EventTypes.userMessage, turnId: 'turn_b', payload: {'input': 'B'}),
      ]);

      expect(r.items, hasLength(2));
      expect(r.items.whereType<UserMessageItem>().map((e) => e.text), [
        'A',
        'B',
      ]);
    });

    test('去重后用户气泡仍排在 assistant 流式段落之前', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'turn_7',
          payload: {'input': '你好'},
          transient: true,
        ),
        ev(
          EventTypes.message,
          turnId: 'turn_7',
          payload: {'text': '你好，有什么'},
          transient: true,
        ),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_7',
          payload: {'input': '你好'},
          globalSeq: 42,
        ),
      ]);

      expect(r.items.first, isA<UserMessageItem>());
      expect(r.items.last, isA<AssistantMessageItem>());
      expect(r.items, hasLength(2));
    });

    test('turnId 为空时不参与去重（无法判定归属）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, turnId: '', payload: {'input': 'A'}),
        ev(EventTypes.userMessage, turnId: '', payload: {'input': 'B'}),
      ]);

      expect(r.items, hasLength(2));
    });
  });

  group('流式增量 vs 权威帧', () {
    test('transient message 追加到同一段', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '你好'}, transient: true),
        ev(
          EventTypes.message,
          payload: {'text': '，世界'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AssistantMessageItem;
      expect(item.text, '你好，世界');
      expect(item.isStreaming, isTrue);
    });

    test('权威帧替换累积的增量（防断线残缺）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '你好'}, transient: true),
        ev(
          EventTypes.message,
          payload: {'text': '，世界'},
          transient: true,
          globalSeq: 2,
        ),
        // 权威帧：段级完整文本，应替换而非追加。
        ev(EventTypes.message, payload: {'text': '你好，世界！'}, globalSeq: 3),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AssistantMessageItem;
      expect(item.text, '你好，世界！');
      expect(item.isStreaming, isFalse);
    });

    test('非流式 message 在同一段内替换（对齐「同 turn 权威帧拼接」不变式）', () {
      // 无工具轮分隔时，同 turn 的权威帧属同一段——后到的替换先前的，
      // 这是「权威帧是段级完整快照」的直接推论。
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '完整回答'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '完整回答（修订）'}, globalSeq: 2),
      ]);

      expect(r.items, hasLength(1));
      expect((r.items.single as AssistantMessageItem).text, '完整回答（修订）');
    });

    test('多轮工具调用的权威帧各自成段（tool_call 是段落边界）', () {
      // 回归：Go 侧 `pigo_core.go` 约定「最终回复 = 同 turn 全部 message 权威帧
      // 拼接」，而 `segmentFlushed` 在 turn_start/turn_end 重置，故 N 个工具轮
      // 会产生 N 份完整权威帧。若不在 tool_call 处闭合段落，第二轮的权威帧会走
      // 「替换」分支把第一轮文本整个覆盖——多轮工具调用只剩最后一段。
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '我先读参考材料'}, globalSeq: 1),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c1', 'name': 'read_file'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'c1', 'output': '...'},
          globalSeq: 3,
        ),
        ev(EventTypes.message, payload: {'text': '结论如下'}, globalSeq: 4),
      ]);

      final texts = r.items
          .whereType<AssistantMessageItem>()
          .map((e) => e.text)
          .toList();
      expect(texts, ['我先读参考材料', '结论如下']);
      expect(r.items, hasLength(3), reason: '两段回答 + 一个工具调用');
    });

    test('工具轮之间的流式增量不会跨轮追加到上一段', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '第一轮'}, transient: true),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c1', 'name': 'x'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.message,
          payload: {'text': '第二轮'},
          transient: true,
          globalSeq: 3,
        ),
      ]);

      final texts = r.items
          .whereType<AssistantMessageItem>()
          .map((e) => e.text)
          .toList();
      expect(texts, ['第一轮', '第二轮'], reason: '不应拼成「第一轮第二轮」');
    });

    test('thought 增量同样追加，且与 assistant 段落互不干扰', () {
      final r = EventReducer.reduce([
        ev(EventTypes.thought, payload: {'text': '想'}, transient: true),
        ev(
          EventTypes.thought,
          payload: {'text': '一下'},
          transient: true,
          globalSeq: 2,
        ),
        ev(
          EventTypes.message,
          payload: {'text': '答案'},
          transient: true,
          globalSeq: 3,
        ),
      ]);

      expect(r.items, hasLength(2));
      expect((r.items[0] as ThoughtItem).text, '想一下');
      expect((r.items[1] as AssistantMessageItem).text, '答案');
    });

    test('start 只闭合流式状态、不产生 item', () {
      final r = EventReducer.reduce([
        ev(EventTypes.start, payload: {'status': 'running'}),
      ]);
      expect(r.items, isEmpty);
    });
  });

  group('tool_call / tool_result 配对', () {
    test('按 tool_call_id 合并为一项', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.toolCall,
          payload: {
            'tool_call_id': 'call_1',
            'name': 'read_file',
            'args': {'p': 'a.txt'},
          },
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'call_1', 'output': '文件内容'},
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as ToolCallItem;
      expect(item.name, 'read_file');
      expect(item.output, '文件内容');
      expect(item.isComplete, isTrue);
      expect(item.args?['p'], 'a.txt');
    });

    test('result 先于 call 到达时独立成项，不丢信息', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'call_x', 'output': '孤儿结果'},
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as ToolCallItem;
      expect(item.output, '孤儿结果');
      expect(item.isComplete, isTrue);
    });

    test('工具轮之间的权威帧不会覆盖前一工具轮的文本（多轮拼接）', () {
      // 与「多轮工具调用的权威帧各自成段」同源：这里验证工具轮全带权威帧的形态。
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '过渡语一'}, globalSeq: 1),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c1', 'name': 'a'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'c1', 'output': 'ra'},
          globalSeq: 3,
        ),
        ev(EventTypes.message, payload: {'text': '过渡语二'}, globalSeq: 4),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c2', 'name': 'b'},
          globalSeq: 5,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'c2', 'output': 'rb'},
          globalSeq: 6,
        ),
        ev(EventTypes.message, payload: {'text': '最终结论'}, globalSeq: 7),
      ]);

      final texts = r.items
          .whereType<AssistantMessageItem>()
          .map((e) => e.text)
          .toList();
      expect(texts, ['过渡语一', '过渡语二', '最终结论']);
    });

    test('两个 call 各自配对（不串味）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.toolCall, payload: {'tool_call_id': 'c1', 'name': 'a'}),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c2', 'name': 'b'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'c1', 'output': 'ra'},
          globalSeq: 3,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'c2', 'output': 'rb'},
          globalSeq: 4,
        ),
      ]);

      expect(r.items, hasLength(2));
      expect((r.items[0] as ToolCallItem).output, 'ra');
      expect((r.items[1] as ToolCallItem).output, 'rb');
    });
  });

  group('确认卡状态', () {
    test('confirmation_required 产出未解决卡片', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          payload: {
            'question': '继续吗？',
            'options': ['继续', '停止'],
          },
        ),
      ]);

      final card = r.items.single as ConfirmationItem;
      expect(card.question, '继续吗？');
      expect(card.options, ['继续', '停止']);
      expect(card.resolved, isFalse);
    });

    test('confirmation_required 带上 groupId（resolve 路径需要它，issue #1）', () {
      // 真实写端点：POST /api/chat/groups/:group_id/confirmations/:id/resolve
      // 只凭 confirmation_id 拼不出该路径，故归约时必须把事件里的 group 带上。
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          groupId: 'grp_abc',
          payload: {'question': '继续吗？', 'confirmation_id': 'cf_row_1'},
        ),
      ]);

      final card = r.items.single as ConfirmationItem;
      expect(card.groupId, 'grp_abc');
      expect(card.confirmationId, 'cf_row_1');
      expect(card.canResolve, isTrue);
    });

    test('缺 confirmation_id 或 groupId 时 canResolve 为 false', () {
      // 两个 id 都必须齐备：缺 group_id 拼不出真实路径，缺 confirmation_id
      // 服务端 0 行受影响。
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          payload: {'question': '只有 question'},
        ),
      ]);
      expect((r.items.single as ConfirmationItem).canResolve, isFalse);
    });

    test('confirmation_resolved 把对应卡片标为已解决', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          turnId: 'turn_1',
          payload: {'question': '继续吗？'},
        ),
        ev(EventTypes.confirmationResolved, turnId: 'turn_1', globalSeq: 2),
      ]);

      expect(r.items, hasLength(1));
      expect((r.items.single as ConfirmationItem).resolved, isTrue);
    });

    test('confirmation_expired 复用同一段标记逻辑（卡片置为已解决）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          turnId: 'turn_1',
          payload: {'question': '继续吗？'},
        ),
        ev(
          EventTypes.confirmationExpired,
          turnId: 'turn_1',
          payload: {'expired_at': '2024-03-05T08:10:00Z'},
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      final card = r.items.single as ConfirmationItem;
      expect(card.resolved, isTrue);
      // 标记已解决后仍必须保留 groupId（resolve 路径需要它）。
      expect(card.groupId, 'grp_1');
      // 卡片本身保留在时间线上（呈现「确认已失效」而非凭空消失）。
      expect(card.question, '继续吗？');
    });

    test('按 turnId 匹配：A 的过期不会误标 B 的卡片', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          turnId: 'turn_A',
          payload: {'question': 'A?'},
        ),
        ev(
          EventTypes.confirmationRequired,
          turnId: 'turn_B',
          payload: {'question': 'B?'},
          globalSeq: 2,
        ),
        ev(EventTypes.confirmationExpired, turnId: 'turn_A', globalSeq: 3),
      ]);

      expect(r.items, hasLength(2));
      final a = r.items[0] as ConfirmationItem;
      final b = r.items[1] as ConfirmationItem;
      expect(a.resolved, isTrue, reason: 'A 自己过期');
      expect(b.resolved, isFalse, reason: 'B 不该被 A 的过期事件波及');
    });

    test('无对应卡片时静默忽略（不抛异常）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.confirmationExpired, turnId: 'turn_none'),
      ]);

      expect(r.items, isEmpty);
    });

    test('已解决的卡片不会被再次标记（幂等）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.confirmationRequired,
          turnId: 'turn_1',
          payload: {'question': 'Q'},
        ),
        ev(EventTypes.confirmationResolved, turnId: 'turn_1', globalSeq: 2),
        ev(EventTypes.confirmationExpired, turnId: 'turn_1', globalSeq: 3),
      ]);

      expect(r.items, hasLength(1));
      expect((r.items.single as ConfirmationItem).resolved, isTrue);
    });
  });

  group('终态与游标', () {
    test('done 闭合所有流式段落', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '回答'}, transient: true),
        ev(
          EventTypes.thought,
          payload: {'text': '想法'},
          transient: true,
          globalSeq: 2,
        ),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 3),
      ]);

      expect((r.items[0] as AssistantMessageItem).isStreaming, isFalse);
      expect((r.items[1] as ThoughtItem).isStreaming, isFalse);
    });

    test('done 给未完成的工具调用补「无输出」提示（避免永远转圈）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c1', 'name': 'slow'},
        ),
        ev(EventTypes.done, payload: {'status': 'failed'}, globalSeq: 2),
      ]);

      final item = r.items.single as ToolCallItem;
      expect(item.isComplete, isTrue);
      expect(item.output, '(无输出)');
    });

    test('transient 事件不推进 lastEventId（否则重连会跳过权威帧）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          id: 'real_1',
          payload: {'text': 'x'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.message,
          id: 'inc_2',
          payload: {'text': 'y'},
          transient: true,
        ),
      ]);

      expect(r.lastEventId, 'real_1');
    });

    test('error 事件产出 ErrorItem', () {
      final r = EventReducer.reduce([
        ev(EventTypes.error, payload: {'error': '执行失败'}),
      ]);

      expect((r.items.single as ErrorItem).message, '执行失败');
    });

    test('follow_up_suggested 产出建议项；空建议不产出', () {
      final withItems = EventReducer.reduce([
        ev(
          EventTypes.followUpSuggested,
          payload: {
            'suggestions': ['再问一句'],
          },
        ),
      ]);
      expect((withItems.items.single as FollowUpSuggestionItem).suggestions, [
        '再问一句',
      ]);

      final empty = EventReducer.reduce([
        ev(EventTypes.followUpSuggested, payload: {'suggestions': <String>[]}),
      ]);
      expect(empty.items, isEmpty);
    });

    test('控制/诊断事件不进对话列表', () {
      final r = EventReducer.reduce([
        ev(EventTypes.heartbeat, payload: {}),
        ev(EventTypes.queueState, payload: {'status': 'queued'}, globalSeq: 2),
        ev(EventTypes.executorStarted, payload: {}, globalSeq: 3),
        ev(EventTypes.goalUpdated, payload: {}, globalSeq: 4),
      ]);

      expect(r.items, isEmpty);
    });

    test('goal_updated 即使带完整快照也不进对话列表', () {
      // 归约器的 default 丢弃是**有意**的：目标快照走 `goalUpdates` 通道
      // （见 `ChatStreamController._onFrame` 的提前分流），时间线里不该出现
      // 「目标已更新」气泡。上面的用例用空 payload，这里用真实形态钉住。
      final r = EventReducer.reduce([
        ev(
          EventTypes.goalUpdated,
          payload: {
            'op': 'task_status',
            'goal': {'id': 'goal_1', 'goal_text': '把同步做稳'},
            'tasks': [
              {'task_id': 't1', 'status': 'in_progress'},
            ],
            'progress': {'total': 1, 'completed': 0},
          },
          globalSeq: 1,
        ),
      ]);

      expect(r.items, isEmpty);
      expect(r.gateDecisions, isEmpty);
      expect(r.activities, isEmpty);
    });

    test('未知事件类型被静默忽略（向前兼容）', () {
      final r = EventReducer.reduce([
        ev('brand_new_event', payload: {'text': 'x'}),
      ]);

      expect(r.items, isEmpty);
    });

    test('空输入产出空结果', () {
      final r = EventReducer.reduce(const <ChatEvent>[]);
      expect(r.items, isEmpty);
      expect(r.lastEventId, isEmpty);
    });
  });

  group('端到端：一个完整 turn 的归约', () {
    test('user_message → start → 增量 → 权威帧 → tool → done 的最终形态', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 't1',
          payload: {'input': '读一下 a.txt'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.start,
          turnId: 't1',
          payload: {'status': 'running'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.message,
          turnId: 't1',
          payload: {'text': '好的'},
          transient: true,
        ),
        ev(
          EventTypes.message,
          turnId: 't1',
          payload: {'text': '，我看'},
          transient: true,
          globalSeq: 3,
        ),
        ev(
          EventTypes.message,
          turnId: 't1',
          payload: {'text': '好的，我看一下'},
          globalSeq: 4,
        ),
        ev(
          EventTypes.toolCall,
          turnId: 't1',
          payload: {
            'tool_call_id': 'c1',
            'name': 'read_file',
            'args': {'p': 'a.txt'},
          },
          globalSeq: 5,
        ),
        ev(
          EventTypes.toolResult,
          turnId: 't1',
          payload: {'tool_call_id': 'c1', 'output': '...'},
          globalSeq: 6,
        ),
        ev(
          EventTypes.done,
          turnId: 't1',
          payload: {'status': 'completed'},
          globalSeq: 7,
        ),
      ]);

      expect(r.items, hasLength(3));
      expect(r.items[0], isA<UserMessageItem>());
      expect((r.items[0] as UserMessageItem).text, '读一下 a.txt');
      expect(r.items[1], isA<AssistantMessageItem>());
      expect((r.items[1] as AssistantMessageItem).text, '好的，我看一下');
      expect((r.items[1] as AssistantMessageItem).isStreaming, isFalse);
      expect((r.items[2] as ToolCallItem).name, 'read_file');

      expect(r.lastEventId, 'done_7');
    });
  });

  group('归属反馈卡状态', () {
    /// routing_feedback_request 事件（payload 照 Go feedbackRequestPayload）。
    ChatEvent request({
      String id = 'req_1',
      String turnId = 'turn_1',
      String evaluatedTurnId = 'turn_1',
      String token = 'tok_1',
      List<Map<String, dynamic>>? options,
      String question = '这条消息我归到了「团队周报」，准确吗？',
      int globalSeq = 1,
    }) => ev(
      EventTypes.routingFeedbackRequest,
      id: id,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: {
        'question': question,
        'options':
            options ??
            [
              {'label': '准确', 'reply': '反馈#正确'},
              {'label': '不准确', 'reply': '反馈#错误'},
            ],
        'token': token,
        'evaluated_turn_id': evaluatedTurnId,
        'chosen_group_id': 'grp_1',
      },
    );

    test('产出 FeedbackRequestItem（token/question/options 到位）', () {
      final r = EventReducer.reduce([request()]);

      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<FeedbackRequestItem>());
      final fb = item as FeedbackRequestItem;
      expect(fb.token, 'tok_1', reason: 'token 是回执锚点，缺它无法提交');
      expect(fb.question, contains('准确吗'));
      expect(fb.options, ['准确', '不准确']);
      expect(fb.evaluatedTurnId, 'turn_1');
      expect(fb.resolved, isFalse);
      expect(fb.canResolve, isTrue);
    });

    test('同 turn 重复请求只保留一条（对齐服务端 partial unique index）', () {
      // 客户端会看到重放：SSE cursor 回放与 timeline 回填存在交叠窗口。
      // 不幂等则同一次登录出现两张同问题卡片。
      final r = EventReducer.reduce([
        request(id: 'req_1', globalSeq: 1),
        request(id: 'req_2', globalSeq: 2),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items, hasLength(1), reason: '同一 turn 只应有一张反馈卡');
      expect(items.single.id, 'req_1');
    });

    test('不同 turn 的请求各自成卡', () {
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        request(
          id: 'req_2',
          turnId: 'turn_2',
          evaluatedTurnId: 'turn_2',
          globalSeq: 2,
        ),
      ]);

      expect(r.items.whereType<FeedbackRequestItem>(), hasLength(2));
    });

    test('重放先到无 token 载荷时，后到的完整载荷补上 token', () {
      // 降级路径：历史回填可能先给出无 token 的载荷。补全而非新增，
      // 且 createdAt/身份沿用原卡（排序不应因重放漂移）。
      final r = EventReducer.reduce([
        request(id: 'req_1', token: '', globalSeq: 1),
        request(id: 'req_2', token: 'tok_real', globalSeq: 2),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items, hasLength(1));
      expect(items.single.token, 'tok_real', reason: '补全后必须可提交回执');
      expect(items.single.id, 'req_1', reason: '身份沿用原卡');
    });

    test('token 缺失时不可 resolve（UI 据此禁用按钮）', () {
      final r = EventReducer.reduce([request(token: '')]);

      expect((r.items.single as FeedbackRequestItem).canResolve, isFalse);
    });

    test('routing_feedback 到达后标记已解决（按被评价的 turn 匹配）', () {
      // routing_feedback 的 payload 里**没有** token/事件 id，唯一可靠匹配键
      // 是 turnId（事件附在被评价的 turn 上）。
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_1',
          globalSeq: 2,
          payload: {'correct': true},
        ),
      ]);

      final fb = r.items.whereType<FeedbackRequestItem>().single;
      expect(fb.resolved, isTrue);
      expect(fb.canResolve, isFalse, reason: '已答的卡不得重复提交');
      expect(fb.token, 'tok_1', reason: '标记已解决不得丢失 token');
    });

    test('routing_feedback 不误标其他 turn 的卡', () {
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        request(
          id: 'req_2',
          turnId: 'turn_2',
          evaluatedTurnId: 'turn_2',
          globalSeq: 2,
        ),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_2',
          globalSeq: 3,
          payload: {'correct': false},
        ),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items[0].resolved, isFalse, reason: 'turn_1 的卡未被作答');
      expect(items[1].resolved, isTrue);
    });

    test('evaluated_turn_id 与事件 turnId 不同时，按 evaluated_turn_id 匹配', () {
      // 请求事件挂在完成它的 turn 上，而标注写回被评价的 turn。语义不同，
      // 归约以 payload 的 evaluated_turn_id 为准。
      final r = EventReducer.reduce([
        request(
          id: 'req_1',
          turnId: 'turn_current',
          evaluatedTurnId: 'turn_evaluated',
        ),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_evaluated',
          globalSeq: 2,
        ),
      ]);

      expect(r.items.whereType<FeedbackRequestItem>().single.resolved, isTrue);
    });
  });

  group('agent.file.* → AgentFileItem', () {
    Map<String, dynamic> filePayload({
      String rel = 'QWEN.md',
      String? fileId = 'ufs_001',
      String mime = 'text/markdown; charset=utf-8',
      int size = 3585,
    }) => {
      'relative_path': rel,
      'metadata': {'relative_path': rel},
      'mime_type': mime,
      'size_bytes': size,
      if (fileId != null) 'ufs_file_id': fileId,
    };

    test('created 产出文件卡，字段映射正确', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'created');
      expect(item.ufsFileId, 'ufs_001');
      expect(item.sizeBytes, 3585);
      expect(item.mimeType, 'text/markdown; charset=utf-8');
      expect(item.fileName, 'QWEN.md');
      expect(item.relativePath, 'QWEN.md');
      expect(item.isDeleted, isFalse);
    });

    test('created → modified 合并为同一卡且 action 升级', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
        ev(
          EventTypes.agentFileModified,
          payload: filePayload(size: 4000),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'modified');
      expect(item.sizeBytes, 4000);
      expect(item.modifiedAt, isNotNull);
      expect(item.deletedAt, isNull);
    });

    test('created → modified → deleted 合并为一张置灰卡，保留创建时的 fileId', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
        ev(
          EventTypes.agentFileModified,
          payload: filePayload(size: 4000),
          globalSeq: 2,
        ),
        ev(
          EventTypes.agentFileDeleted,
          payload: {
            // 删除事件实测无 ufs_file_id / size_bytes / metadata。
            'relative_path': 'QWEN.md',
            'mime_type': 'application/octet-stream',
            'deleted_from_ufs': true,
          },
          globalSeq: 3,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'deleted');
      expect(item.isDeleted, isTrue);
      // 创建时的 fileId 不应被删除事件冲掉。
      expect(item.ufsFileId, 'ufs_001');
      expect(item.deletedAt, isNotNull);
    });

    test('created 无 fileId 被跳过（对齐 webapp）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(fileId: null),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, isEmpty);
    });

    test('deleted 无 fileId 仍然出卡（服务端删除事件不带 fileId）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileDeleted,
          payload: {
            'relative_path': 'gone.md',
            'mime_type': 'application/octet-stream',
          },
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.isDeleted, isTrue);
      expect(item.ufsFileId, isNull);
    });

    test('reports/tts/ 下但无合法 turn 目录（如直接放文件）回落为普通文件卡', () {
      // `reports/tts/abc.mp3` 没有 {turn_id}/ 子目录，turn 段含 '.' 非法，
      // parseTTSAudioPath 返回 null → ttsKind=null，渲染为普通文件卡（不丢弃）。
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(rel: 'reports/tts/abc.mp3', mime: 'audio/mpeg'),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, isNull);
      expect(item.fileName, 'abc.mp3');
    });

    test('合法 TTS 路径设置 ttsKind（message_ → reply）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(
            rel: 'reports/tts/c7ad0b62/message_6.mp3',
            mime: 'audio/mpeg',
            size: 53079,
          ),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, TtsStreamKind.reply);
      expect(item.sizeBytes, 53079);
    });

    test('合法 TTS 路径设置 ttsKind（narration_ → narration）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(
            rel: 'reports/tts/turn-1/narration_turn-1_2.mp3',
            mime: 'audio/mpeg',
          ),
          globalSeq: 1,
        ),
      ]);

      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, TtsStreamKind.narration);
    });

    test('nice_name 优先作为展示名（预留字段，生产实测从未出现）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload()..['nice_name'] = '我的配置笔记',
          globalSeq: 1,
        ),
      ]);

      final item = r.items.single as AgentFileItem;
      expect(item.displayName, '我的配置笔记');
      expect(item.fileName, 'QWEN.md');
    });
  });

  group('turn_activity → activities 通道（不进时间线）', () {
    /// 造一个 turn_activity 事件（Transient，不落库）。
    ChatEvent activity({
      String turnId = 'turn_1',
      int? elapsedMs = 45000,
      String? lastEventType = 'tool_call',
      int? sinceLastEventMs = 3200,
      int globalSeq = 1,
    }) => ev(
      EventTypes.turnActivity,
      turnId: turnId,
      transient: true,
      globalSeq: globalSeq,
      payload: {
        if (elapsedMs != null) 'elapsed_ms': elapsedMs,
        if (lastEventType != null) 'last_event_type': lastEventType,
        if (sinceLastEventMs != null) 'since_last_event_ms': sinceLastEventMs,
      },
    );

    test('产出 activities，但不产生任何 items', () {
      final r = EventReducer.reduce([activity()]);

      expect(r.items, isEmpty, reason: '进度提示不是对话正文');
      expect(r.activities, hasLength(1));
      final a = r.activities['turn_1']!;
      expect(a.turnId, 'turn_1');
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, 'tool_call');
      expect(a.sinceLastEventMs, 3200);
    });

    test('同一 turn 两条只保留最新（越新越准）', () {
      final r = EventReducer.reduce([
        activity(elapsedMs: 15000, lastEventType: 'thought', globalSeq: 1),
        activity(elapsedMs: 45000, lastEventType: 'tool_call', globalSeq: 2),
      ]);

      expect(r.activities, hasLength(1), reason: '同 turn 只留一条');
      expect(r.activities['turn_1']!.elapsedMs, 45000);
      expect(r.activities['turn_1']!.lastEventType, 'tool_call');
    });

    test('不同 turn 各自独立', () {
      final r = EventReducer.reduce([
        activity(turnId: 'turn_a', elapsedMs: 1000, globalSeq: 1),
        activity(turnId: 'turn_b', elapsedMs: 2000, globalSeq: 2),
      ]);

      expect(r.activities.keys, containsAll(['turn_a', 'turn_b']));
      expect(r.activities['turn_a']!.elapsedMs, 1000);
      expect(r.activities['turn_b']!.elapsedMs, 2000);
    });

    test('首帧无上一步事件时 lastEventType/sinceLastEventMs 为 null', () {
      final r = EventReducer.reduce([
        activity(lastEventType: null, sinceLastEventMs: null),
      ]);

      final a = r.activities['turn_1']!;
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, isNull);
      expect(a.sinceLastEventMs, isNull);
    });

    test('elapsed_ms 缺失时退化为 0（异常载荷不产出 null）', () {
      final r = EventReducer.reduce([activity(elapsedMs: null)]);

      expect(r.activities['turn_1']!.elapsedMs, 0);
    });

    test('turnId 为空的 turn_activity 被丢弃（无法按 turn 归并）', () {
      final r = EventReducer.reduce([activity(turnId: '')]);

      expect(r.activities, isEmpty);
    });

    test('turn_activity 不推进 SSE 游标（Transient 无有效 ID）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          id: 'evt_msg',
          payload: {'text': 'hi'},
          globalSeq: 1,
        ),
        activity(globalSeq: 2),
      ]);

      expect(r.lastEventId, 'evt_msg', reason: 'Transient 事件不得作游标');
    });

    test('activity 与同 turn 的正文共存：items 有正文、activities 有进度', () {
      final r = EventReducer.reduce([
        activity(elapsedMs: 30000, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '正在分析…'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.items.single, isA<AssistantMessageItem>());
      expect(r.activities['turn_1']!.elapsedMs, 30000);
    });
  });

  group('context_update → contextUsage 通道（不进时间线）', () {
    /// 造一个 context_update 事件。
    ///
    /// 默认 transient=false：Go 侧它走 `flushEvent`（**落库**）而非
    /// `flushEventTransient`，故会带有效 eventId/globalSeq 并推进游标。
    ChatEvent ctx(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.contextUpdate,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    test('Go telemetry 形状：产出 contextUsage，但不产生任何 items', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {
            'turns': 3,
            'truncation_count': 0,
            'compaction_count': 1,
            'context_utilization': 0.25,
            'context_tokens': 50000,
            'context_window': 200000,
          },
        }),
      ]);

      expect(r.items, isEmpty, reason: '用量是诊断读数，不是对话正文');
      final u = r.contextUsage;
      expect(u, isNotNull);
      expect(u!.used, 50000, reason: 'context_tokens → used');
      expect(u.size, 200000, reason: 'context_window → size');
      expect(u.remaining, 150000, reason: '未显式给出时由 size - used 推出');
      expect(u.cost, isNull, reason: 'Go 从不发射 cost，不得伪造');
      expect(u.hasData, isTrue);
    });

    test('Go compaction 形状：tokens_after 优先于 tokens_before', () {
      final r = EventReducer.reduce([
        ctx({
          'compaction': {
            'status': 'completed',
            'reason': 'auto',
            'tokens_before': 180000,
            'tokens_after': 42000,
            'summarized_count': 12,
            'kept_count': 3,
          },
        }),
      ]);

      expect(r.items, isEmpty);
      final u = r.contextUsage!;
      expect(u.used, 42000, reason: '压缩完成后以 tokens_after 为准');
      expect(u.size, isNull, reason: '压缩事件不带窗口大小');
    });

    test('compaction_started 只有 tokens_before 时也能取到用量', () {
      final r = EventReducer.reduce([
        ctx({
          'compaction': {'status': 'started', 'tokens_before': 190000},
        }),
      ]);

      expect(r.contextUsage!.used, 190000);
    });

    test('遗留 context 形状（webapp 解析的那份）也支持，含 cost', () {
      final r = EventReducer.reduce([
        ctx({
          'context': {
            'used': 1234,
            'size': 8000,
            'remaining': 6766,
            'cost': {'amount': 0.0123, 'currency': 'USD'},
          },
        }),
      ]);

      final u = r.contextUsage!;
      expect(u.used, 1234);
      expect(u.size, 8000);
      expect(u.remaining, 6766);
      expect(u.cost!.amount, 0.0123);
      expect(u.cost!.currency, 'USD');
    });

    test('同 turn 多条合并：telemetry 的窗口与 compaction 的用量互不覆盖', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 10000, 'context_window': 200000},
        }, globalSeq: 1),
        ctx({
          'compaction': {'status': 'completed', 'tokens_after': 3000},
        }, globalSeq: 2),
      ]);

      final u = r.contextUsage!;
      expect(u.used, 3000, reason: '新的 used 覆盖旧值');
      expect(u.size, 200000, reason: '窗口大小沿用上一条 telemetry');
      expect(u.remaining, 197000, reason: 'used 更新后 remaining 必须重算');
    });

    test('context_update 推进 SSE 游标（Go 侧落库，不是 Transient）', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 100, 'context_window': 1000},
        }, globalSeq: 7),
      ]);

      expect(
        r.lastEventId,
        'context_update_7',
        reason: 'flushEvent 落库事件带有效 ID，可作游标',
      );
    });

    test('无法解析的异常载荷不产出快照（也不清空已有值）', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 500, 'context_window': 1000},
        }, globalSeq: 1),
        // 只带 compaction 状态、无任何 token 字段：fromEventPayload 返回 null。
        ctx({
          'compaction': {'status': 'started'},
        }, globalSeq: 2),
      ]);

      expect(r.contextUsage!.used, 500, reason: '异常载荷不得清空已知用量');
      expect(r.contextUsage!.size, 1000);
    });

    test('用量与同 turn 的正文共存：items 有正文、contextUsage 有读数', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 2000, 'context_window': 8000},
        }, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '好了'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.contextUsage!.used, 2000);
    });

    test('无 context_update 时 contextUsage 为 null', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': 'hi'}),
      ]);

      expect(r.contextUsage, isNull, reason: '无数据应隐藏而非显示 0');
    });
  });

  group('queue_state / retry_scheduled → executionStatus 通道（不进时间线）', () {
    /// 造一个 queue_state 事件。
    ///
    /// ⚠️ 默认 transient=false：Go 侧五个发射点**全部未设 Transient**
    /// （`enqueue.go` 走 persistEventAtomic、`turn_worker.go` / `gate_impls.go`
    /// 走 w.emit 的落库分支），故它们是落库事件、会推进游标。
    ChatEvent qs(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.queueState,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    ChatEvent retry(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.retryScheduled,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    test('queue_state(queued) 产出 executionStatus，但不产生任何 items', () {
      final r = EventReducer.reduce([
        qs({
          'state': 'queued',
          'reason': 'session_busy',
          'queue_total': 7,
          'queue_user': 2,
        }),
      ]);

      expect(r.items, isEmpty, reason: '等待提示不是对话正文');
      final s = r.executionStatus;
      expect(s, isNotNull);
      expect(s!.turnId, 'turn_1');
      expect(s.kind, ExecutionStatusKind.queued);
      expect(s.reason, 'session_busy');
      expect(s.queueTotal, 7);
      expect(s.queueUser, 2);
    });

    test(
      'retry_scheduled 产出 executionStatus（attempt / max_retries / delay_ms）',
      () {
        final r = EventReducer.reduce([
          retry({
            'attempt': 2,
            'max_retries': 3,
            'delay_ms': 5000,
            'reason': 'stderr 原文不应被当文案',
          }),
        ]);

        expect(r.items, isEmpty);
        final s = r.executionStatus!;
        expect(s.kind, ExecutionStatusKind.retryScheduled);
        expect(s.attempt, 2);
        expect(s.maxRetries, 3);
        expect(s.delayMs, 5000);
      },
    );

    test('start 清除同一 turn 的等待状态（起跑即等待结束）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        ev(EventTypes.start, payload: {'status': 'running'}, globalSeq: 2),
      ]);

      expect(r.executionStatus, isNull, reason: '已起跑，不该再显示「排队中」');
    });

    test('message 正文到达后清除等待状态', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '回复来了'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.executionStatus, isNull, reason: '已有正文，等待显然结束');
    });

    test('done / error 终态也清除等待状态', () {
      final done = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 2),
      ]);
      expect(done.executionStatus, isNull);

      final failed = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.error, payload: {'message': 'boom'}, globalSeq: 2),
      ]);
      expect(failed.executionStatus, isNull);
    });

    test('清除只作用于同一 turn（别的 turn 的正文不抹掉本 turn 的等待）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, turnId: 'turn_1', globalSeq: 1),
        ev(
          EventTypes.message,
          turnId: 'turn_2',
          payload: {'text': '另一个 turn'},
          globalSeq: 2,
        ),
      ]);

      expect(r.executionStatus, isNotNull, reason: 'turn_2 的正文与 turn_1 是否在等无关');
      expect(r.executionStatus!.turnId, 'turn_1');
    });

    test('queue_state(state=cancelled) 是终态而非等待，且会清除已有等待', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        qs({'state': 'cancelled', 'reason': 'cancelled'}, globalSeq: 2),
      ]);

      expect(
        r.executionStatus,
        isNull,
        reason: 'cancelled 是等待结束（EmitCanceled），不是新的等待',
      );
    });

    test('同 turn 多条等待只留最后一条（越新越准）', () {
      final r = EventReducer.reduce([
        qs({
          'state': 'queued',
          'reason': 'global_concurrency_limit',
        }, globalSeq: 1),
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 2),
      ]);

      expect(r.executionStatus!.reason, 'session_busy');
    });

    test('retry_scheduled 覆盖先前的 queue_state（后到的等待原因胜出）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        retry({'attempt': 2}, globalSeq: 2),
      ]);

      expect(r.executionStatus!.kind, ExecutionStatusKind.retryScheduled);
      expect(r.executionStatus!.attempt, 2);
    });

    test('state 缺失或非 queued 的 queue_state 不产出状态', () {
      expect(EventReducer.reduce([qs(const {})]).executionStatus, isNull);
      expect(
        EventReducer.reduce([
          qs({'state': 'running'}),
        ]).executionStatus,
        isNull,
      );
    });

    test('turnId 为空的等待事件被丢弃（无法定位 turn）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, turnId: ''),
      ]);

      expect(r.executionStatus, isNull);
    });

    test('两类事件均推进 SSE 游标（Go 侧落库，非 Transient）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 5),
        retry({'attempt': 1}, globalSeq: 6),
      ]);

      expect(
        r.lastEventId,
        'retry_scheduled_6',
        reason: '落库事件带有效 ID，应作游标（与 turn_activity 相反）',
      );
    });

    test('等待与同 turn 正文共存：等待在 message 前有效、之后被清', () {
      final before = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
      ]);
      expect(before.executionStatus, isNotNull);

      final after = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '好了'}, globalSeq: 2),
      ]);
      expect(after.items, hasLength(1));
      expect(after.executionStatus, isNull);
    });
  });

  group('tts_* → ttsStatus 通道（不进时间线）', () {
    /// 造一个 TTS 生命周期事件。
    ///
    /// ⚠️ `tts_started` 默认 transient=true（Go `main.go:715` 只对它设 Transient）；
    /// 两个终态事件是**落库**的，故用 transient=false。
    ChatEvent tts(
      String type,
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      type,
      turnId: turnId,
      globalSeq: globalSeq,
      transient: type == EventTypes.ttsStarted,
      payload: payload,
    );

    test('tts_started 产出 ttsStatus(started)，但不产生任何 items', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'message', 'seq': 1}),
      ]);

      expect(r.items, isEmpty, reason: '播报状态不是对话正文');
      final s = r.ttsStatus;
      expect(s.turnId, 'turn_1');
      expect(s.phase, TtsPhase.started);
      expect(s.mode, 'message');
      expect(s.hasStatus, isTrue);
      expect(s.isTerminal, isFalse);
    });

    test('stream 模式的 tts_started 带 reason=first_delta', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream', 'reason': 'first_delta'}),
      ]);

      expect(r.ttsStatus.mode, 'stream');
      expect(r.ttsStatus.reason, 'first_delta');
    });

    test('tts_completed 产出 ttsStatus(completed) 并记下段数', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
        tts(EventTypes.ttsCompleted, {
          'parts': 3,
          'bytes': 1024,
          'duration_ms': 2500,
        }, globalSeq: 2),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.completed);
      expect(s.parts, 3);
      expect(s.isTerminal, isTrue);
    });

    test('tts_failed 产出 ttsStatus(failed) 并保留服务端文案与诊断字段', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsFailed, {
          'reason': 'synthesize_failed',
          'seq': 1,
          'message': '语音生成失败，本次文本回复不受影响。',
        }),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.failed);
      expect(s.message, '语音生成失败，本次文本回复不受影响。');
      expect(s.reason, 'synthesize_failed');
      expect(s.isTerminal, isTrue);
    });

    test('stream 终态失败：completed_parts 作为 parts，并带 failed_part/lost_chars', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsFailed, {
          'parts': 5,
          'bytes': 900,
          'duration_ms': 1000,
          'reason': 'provider_error',
          'failed_part': 3,
          'completed_parts': 2,
          'lost_chars': 42,
          'message': '语音生成未完全成功，已生成的部分仍可播放。',
        }),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.failed);
      expect(s.parts, 2, reason: '失败时 parts 取 completed_parts（已完成数）');
      expect(s.failedPart, 3);
      expect(s.lostChars, 42);
    });

    test('started → completed 按顺序覆盖（回放也得到终态）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.completed,
        reason: '终态落库且顺序在后，回放历史不应停在「合成中」',
      );
    });

    test('started → failed 按顺序覆盖', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'message'}, globalSeq: 1),
        tts(EventTypes.ttsFailed, {'message': '失败了'}, globalSeq: 2),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.failed);
    });

    test('新 turn 的 user_message 清除上一轮播报状态（不粘在新一轮上）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 1),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_2',
          payload: {'input': '下一个问题'},
          globalSeq: 2,
        ),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle, reason: '上一轮的「语音已生成」不该粘在新一轮上');
      expect(r.ttsStatus.hasStatus, isFalse);
      expect(r.items, hasLength(1), reason: 'user_message 仍正常进时间线');
    });

    test('同 turn 重放的 user_message 不清掉本 turn 的播报状态', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'turn_1',
          payload: {'input': '问题'},
          globalSeq: 1,
        ),
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_1',
          payload: {'input': '问题'},
          globalSeq: 3,
        ),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.completed,
        reason: '同 turn 的重复 user_message 不应误清本 turn 状态',
      );
    });

    test('turnId 为空的 tts 事件被丢弃（无法按 turn 归并）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, turnId: ''),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle);
    });

    test('非 TTS 事件的通用键不被误读为播报字段', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.error,
          payload: {'message': '这不是语音失败', 'reason': 'boom'},
          globalSeq: 1,
        ),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.idle,
        reason: 'error 事件的 message 不是播报文案',
      );
    });

    test('tts_started 不推进游标，终态事件推进游标', () {
      final started = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
      ]);
      expect(started.lastEventId, isEmpty, reason: 'Transient 无有效 ID');

      final completed = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
      ]);
      expect(
        completed.lastEventId,
        'tts_completed_2',
        reason: '终态落库，应推进游标（与 started 相反）',
      );
    });

    test('无 tts 事件时 ttsStatus 为 idle（非 null）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': 'hi'}),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle);
      expect(r.ttsStatus.hasStatus, isFalse, reason: 'UI 据此不渲染状态条');
    });

    test('四态齐备：idle 是显式态而非 null', () {
      // 需求列出 idle/started/completed/failed 四态。idle 不是「null 的别名」，
      // 而是可穷举的一个分支（UI 的 switch 能无 default 地覆盖它）。
      const idle = TtsStatus.idle();
      expect(idle.phase, TtsPhase.idle);
      expect(idle.turnId, isEmpty);
      expect(idle.hasStatus, isFalse);
      expect(idle.isTerminal, isFalse);
      expect(idle.at, isNull, reason: '空闲不是事件，没有时间戳');

      expect(TtsPhase.values, hasLength(4));
      expect(TtsPhase.values.map((p) => p.wire).toList(), [
        'idle',
        'started',
        'completed',
        'failed',
      ]);
    });

    test('默认归约结果就是 idle（调用方无需判空）', () {
      final r = EventReducer.reduce(const []);

      expect(r.ttsStatus.phase, TtsPhase.idle);
    });
  });

  /// 习惯建议事件（`habit_suggestion_created` / `habit_suggestion_resolved`）。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 这两个事件不在 `chatbus/broker.go` 里（由 `habit.TimelineEmitter` 用字面量
  /// 直接广播），若只对着 broker.go 做镜像就会漏掉它们，于是事件落到归约器的
  /// `default:` 分支被**静默丢弃**——用户永远看不到建议卡，且没有任何报错
  /// （与 `agent.file.*` 曾被吞 2927 条是同一类缺陷）。
  group('habit 建议 → HabitSuggestionItem', () {
    /// `BuildSuggestionCreatedPayload` 的真实形状。
    Map<String, dynamic> createdPayload({String id = 'run-sugg-1'}) => {
      'suggestion_id': id,
      'habit_pattern_id': null,
      'status': 'pending',
      'trigger_type': 'time_based',
      'recommendation': {
        'action': 'accept_rule',
        'confidence': 0.72,
        'reasons': ['每周一你都会让我写周报'],
      },
      'rule_draft': {
        'topic_key': 'weekly-report',
        'trigger_type': 'time_based',
        'trigger_config': {
          'hour': 9,
          'weekday': [1],
        },
        'preferred_agent_id': 'agt-1',
        'delivery_group_id': 'grp-1',
        'target_acceptance_level': 'suggest_only',
      },
      'evidence': {'occurrences': 3},
      'editable_fields': ['topic_key', 'trigger_config'],
    };

    test('created 产出建议卡（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<HabitSuggestionItem>());
      final s = item as HabitSuggestionItem;
      expect(s.suggestionId, 'run-sugg-1');
      expect(s.topicKey, 'weekly-report');
      expect(s.triggerType, HabitTriggerType.timeBased);
      expect(s.triggerConfig!.time!.firstHour, 9);
      expect(s.preferredAgentId, 'agt-1');
      expect(s.targetAcceptanceLevel, HabitAcceptanceLevel.suggestOnly);
      expect(s.confidence, 0.72);
      expect(s.reasons, hasLength(1));
      expect(s.canResolve, isTrue, reason: '未反馈时应可操作');
      expect(s.isAccepted, isFalse);
    });

    test('缺 suggestion_id 的载荷不产出项（无身份键不可操作）', () {
      final payload = createdPayload()..remove('suggestion_id');
      final r = EventReducer.reduce([
        ev(EventTypes.habitSuggestionCreated, payload: payload),
      ]);
      expect(r.items, isEmpty);
    });

    test('resolved 就地更新同一张卡（按 suggestionId 而非 turnId）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionResolved,
          // 同一 turn：服务端 resolve 时重新取该 group 最近一条 turn。
          payload: {
            'suggestion_id': 'run-sugg-1',
            'status': 'resolved',
            'action': 'accept',
            'user_feedback': 'accepted',
            'resolved_pattern_id': 'hp-new',
            'snooze_until': null,
            'topic_key': 'weekly-report',
          },
          globalSeq: 2,
        ),
      ]);

      // 关键：仍然只有一张卡（不是 created 一张 + resolved 一张）。
      expect(r.items, hasLength(1));
      final s = r.items.single as HabitSuggestionItem;
      expect(s.userFeedback, HabitUserFeedback.accepted);
      expect(s.resolvedPatternId, 'hp-new');
      expect(s.canResolve, isFalse, reason: '已处理应禁用按钮');
      expect(s.isAccepted, isTrue);
      // 草稿信息不应因 resolved 而丢失。
      expect(s.topicKey, 'weekly-report');
      expect(s.triggerConfig!.time!.firstHour, 9);
    });

    test('resolved 无对应 created 时不新建空白卡', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionResolved,
          payload: {
            'suggestion_id': 'run-orphan',
            'action': 'dismiss',
            'user_feedback': 'dismissed',
          },
        ),
      ]);
      // resolved 不带 rule_draft，凭它建卡会得到一张没有 topic_key 的空白卡。
      expect(r.items, isEmpty);
    });

    test('snooze 记下 snooze_until', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionResolved,
          payload: {
            'suggestion_id': 'run-sugg-1',
            'action': 'snooze',
            'user_feedback': 'snoozed',
            'snooze_until': '2026-10-05T00:00:00Z',
          },
          globalSeq: 2,
        ),
      ]);

      final s = r.items.single as HabitSuggestionItem;
      expect(s.userFeedback, HabitUserFeedback.snoozed);
      expect(s.snoozeUntil, isNotNull);
      expect(s.snoozeUntil!.toUtc().day, 5);
    });

    test('重放同一事件不产生重复卡（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.habitSuggestionCreated,
        payload: createdPayload(),
        globalSeq: 1,
      );
      final r = EventReducer.reduce([e, e]);
      expect(r.items, hasLength(1));
    });

    test('同一 turn 上两条不同建议各自成卡（不能按 turnId 合并）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(id: 'run-a'),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(id: 'run-b'),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      final ids = r.items.cast<HabitSuggestionItem>().map(
        (s) => s.suggestionId,
      );
      expect(ids, containsAll(['run-a', 'run-b']));
    });

    test('watch 候选按 watch 形状渲染（不显示凌晨 0 点）', () {
      final payload = createdPayload();
      payload['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_config'] = {
        'cadence': {'initial_seconds': 3600},
      };

      final r = EventReducer.reduce([
        ev(EventTypes.habitSuggestionCreated, payload: payload),
      ]);

      final s = r.items.single as HabitSuggestionItem;
      expect(s.triggerType, HabitTriggerType.watch);
      expect(s.triggerConfig!.time, isNull);
      expect(s.triggerConfig!.summary, isNot(contains('00:00')));
    });
  });

  /// 习惯自动执行完成（`habit_auto_run_completed`）——习惯回环的 Reward 环。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 同 [habitSuggestionCreated]：该事件**不在** `chatbus/broker.go` 的常量表里，
  /// 只对着 broker.go 做镜像必然漏掉，于是落到归约器的 `default:` 分支被静默
  /// 丢弃——用户永远看不到「服务端帮你跑了一轮习惯」的回执。
  ///
  /// ## ⚠️ 契约来源说明
  ///
  /// Go 侧当前**不产出**本事件（`workers/habit/turn_terminal.go:35` 明说不做），
  /// 载荷形状取自 Python 的 `build_habit_auto_run_completed_payload` 与 webapp 的
  /// 解析器。这里钉住的是「事件一旦补齐，客户端能正确渲染」——即验收要求的
  /// 「事件产出对话项」。
  group('habit 自动执行 → HabitAutoRunItem', () {
    /// `build_habit_auto_run_completed_payload` 的真实形状。
    Map<String, dynamic> autoRunPayload({
      String topicKey = 'daily_review',
      String runId = 'run-1',
    }) => {
      'habit_pattern_id': 'hp-1',
      'habit_run_id': runId,
      'turn_id': 'turn_1',
      'delivery_group_id': 'grp_1',
      'topic_key': topicKey,
      'summary': 'daily review 习惯提醒已成功送达，完成本轮强化。',
    };

    test('产出习惯强化项（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.habitAutoRunCompleted, payload: autoRunPayload()),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<HabitAutoRunItem>());
      final h = item as HabitAutoRunItem;
      expect(h.topicKey, 'daily_review');
      expect(h.topicLabel, 'daily review', reason: '下划线应换成空格');
      expect(h.runId, 'run-1');
      expect(h.patternId, 'hp-1');
      expect(h.turnId, 'turn_1');
    });

    test('缺 topic_key 仍产出项（身份键不是它，渲染为未命名）', () {
      final payload = autoRunPayload()..remove('topic_key');
      final r = EventReducer.reduce([
        ev(EventTypes.habitAutoRunCompleted, payload: payload),
      ]);

      // 与建议卡不同：建议卡缺 suggestion_id 必须丢弃（无身份键不可操作），
      // 本项是纯通知，没有可操作性，不应因缺展示字段而消失。
      expect(r.items, hasLength(1));
      expect((r.items.single as HabitAutoRunItem).topicLabel, '未命名习惯');
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(EventTypes.habitAutoRunCompleted, payload: autoRunPayload());
      final r = EventReducer.reduce([e, e]);
      expect(r.items, hasLength(1));
    });

    test('同一 turn 上两次不同执行各自成项（不能按 turnId 合并）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitAutoRunCompleted,
          id: 'evt-a',
          payload: autoRunPayload(topicKey: 'daily_review', runId: 'run-a'),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitAutoRunCompleted,
          id: 'evt-b',
          payload: autoRunPayload(topicKey: 'weekly_report', runId: 'run-b'),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      final labels = r.items.cast<HabitAutoRunItem>().map((h) => h.topicLabel);
      expect(labels, containsAll(['daily review', 'weekly report']));
    });
  });

  /// 自动续跑排程（`schedule_created`）——Goal Gate「即将继续」的唯一可见信号。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 与 `goal_gate_stopped` 同型：`EventTypes.timelineVisible` 收录了它，而
  /// 归约器曾把它落在 `default:` 静默丢弃。后果是用户看到界面静止，无法区分
  /// 「在等一会儿接着跑」与「已经停了」——而这两个结论正是由
  /// `schedule_created` 与 `goal_gate_stopped` 分别表达的。
  ///
  /// ⚠️ 服务端**不发**绝对时间（`scheduled_at` / `next_run_at` / `run_at` 都
  /// 没有），只发相对秒数 `delay_seconds`。故断言必须落在秒数上，不能去断言
  /// 某个时间戳字段。
  group('schedule_created → ScheduleCreatedItem', () {
    test('产出排程项并带上秒数与轮次（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.scheduleCreated,
          payload: {
            'schedule_id': 'sched_1',
            'reason': 'done',
            'status': 'pending',
            'delay_seconds': 30,
            'source': 'goal_gate',
            'auto_turn_count': 2,
            'max_auto_turns': 5,
          },
        ),
      ]);

      final item = r.items.single as ScheduleCreatedItem;
      expect(item.delaySeconds, 30);
      expect(item.reason, 'done');
      expect(item.autoTurnCount, 2);
      expect(item.maxAutoTurns, 5);
      expect(item.userText, '将在 30 秒后自动继续（第 2/5 轮）');
    });

    test('缺 delay_seconds 时仍产出，且**不编造秒数**', () {
      // 异常载荷（字段缺失）不该让整条事件消失——但也不能兜底成「30 秒」：
      // 一个编造的时间会让用户真的去等它，而实际触发时刻无人知道。
      final r = EventReducer.reduce([
        ev(EventTypes.scheduleCreated, payload: {'reason': 'done'}),
      ]);

      final item = r.items.single as ScheduleCreatedItem;
      expect(item.delaySeconds, isNull);
      expect(item.userText, '已排入下一轮自动继续');
      expect(item.userText, isNot(contains('秒')));
    });

    test('缺轮次计数时只报秒数（不显示残缺的「第 /轮」）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.scheduleCreated, payload: {'delay_seconds': 45}),
      ]);

      expect((r.items.single as ScheduleCreatedItem).userText, '将在 45 秒后自动继续');
    });

    test('只有上限没有已推进数时退化为「上限 N 轮」', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.scheduleCreated,
          payload: {'delay_seconds': 10, 'max_auto_turns': 5},
        ),
      ]);

      expect(
        (r.items.single as ScheduleCreatedItem).userText,
        '将在 10 秒后自动继续（上限 5 轮）',
      );
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.scheduleCreated,
        id: 'evt_sched_1',
        payload: {'delay_seconds': 30},
      );
      // 本项不按身份键 upsert（与 GoalGateStoppedItem 同取向：排程通知是
      // 一次性事件，没有天然身份键），但控制器层的 seen 去重会滤掉同一
      // eventId——故这里只断言「单条输入产出单项」。
      //
      // 不在归约器层做 eventId 去重是有意的：`reduce` 是纯函数，同一个事件
      // 对象被传两次时按 id 去重需要维护跨调用状态，而真正会重复输入的路径
      //（SSE 回放 + timeline 回填交叠）已在控制器用 seen 集合滤掉。
      final r = EventReducer.reduce([e]);
      expect(r.items, hasLength(1));
    });
  });

  /// 目标自动推进停止（`goal_gate_stopped`）——Goal Gate 终止的唯一可见信号。
  ///
  /// ## 这个测试防的是什么
  ///
  /// `EventTypes.timelineVisible` **早已**收录 `goalGateStopped`，但归约器没有
  /// 对应 case，事件落到 `default:` 被静默丢弃——即「集合说它可见、实现却把它
  /// 丢了」。用户看到 agent 不再自动续跑却没有任何解释。
  ///
  /// 文案映射必须与 miniapp `goalGateStoppedContent()` 逐条一致，否则同一个
  /// 停止原因在手机与桌面上显示不同结论。
  group('goal_gate_stopped → GoalGateStoppedItem', () {
    test('产出停止项（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.goalGateStopped,
          payload: {'reason': 'goal_completed', 'auto_turn_count': 3},
        ),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      final item = r.items.single;
      expect(item, isA<GoalGateStoppedItem>());
      final s = item as GoalGateStoppedItem;
      expect(s.reason, 'goal_completed');
      expect(s.message, '目标已实现，自动推进已停用');
      expect(s.turnCountLabel, '已自动推进 3 轮');
    });

    test('五种 reason 的文案与 miniapp 逐条一致', () {
      // 取值来源：Go chatgate/goal_gate.go 的三处 emit（:416 停止态、:435 目标
      // 达成、:549 熔断）与 miniapp normalize.ts:146 的映射表。
      const expected = {
        'goal_completed': '目标已实现，自动推进已停用',
        'max_auto_turns_reached': '已达自动推进轮次上限，发送新消息后可继续',
        'no_tasks': '目标尚无任务列表，请先拆解任务后再启用自动推进',
        'task_blocked': '存在受阻任务，自动推进已暂停，需人工介入',
        'task_error_stopped': '存在出错停止的任务，自动推进已暂停，需人工介入',
      };
      for (final entry in expected.entries) {
        final r = EventReducer.reduce([
          ev(EventTypes.goalGateStopped, payload: {'reason': entry.key}),
        ]);
        expect(
          (r.items.single as GoalGateStoppedItem).message,
          entry.value,
          reason: 'reason=${entry.key} 的文案漂移了',
        );
      }
    });

    test('未知 reason 走兜底但保留结论（不静默消失）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.goalGateStopped, payload: {'reason': 'brand_new_reason'}),
      ]);

      expect(r.items, hasLength(1));
      expect(
        (r.items.single as GoalGateStoppedItem).message,
        '自动推进已停止',
        reason: '服务端新增原因时不能什么都不显示',
      );
    });

    test('payload 完全缺失时仍产出项（兜底文案）', () {
      final r = EventReducer.reduce([ev(EventTypes.goalGateStopped)]);

      expect(r.items, hasLength(1));
      final s = r.items.single as GoalGateStoppedItem;
      expect(s.reason, '');
      expect(s.message, '自动推进已停止');
      expect(s.turnCountLabel, isNull, reason: '无计数时不渲染轮次行');
    });

    test('轮次文案覆盖「只有计数」「只有上限」「两者都有」', () {
      String? label(Map<String, dynamic> payload) =>
          (EventReducer.reduce([
                    ev(EventTypes.goalGateStopped, payload: payload),
                  ]).items.single
                  as GoalGateStoppedItem)
              .turnCountLabel;

      expect(label({'auto_turn_count': 2}), '已自动推进 2 轮');
      expect(label({'max_auto_turns': 10}), '上限 10 轮');
      expect(
        label({'auto_turn_count': 2, 'max_auto_turns': 10}),
        '已自动推进 2/10 轮',
      );
      expect(label({}), isNull);
    });

    test('detail 与 sessionId 类字段：空白串归 null（不渲染空白行）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.goalGateStopped,
          payload: {'reason': 'task_blocked', 'detail': '   '},
        ),
      ]);
      expect((r.items.single as GoalGateStoppedItem).detail, isNull);
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.goalGateStopped,
        id: 'evt_stop_1',
        payload: {'reason': 'goal_completed'},
      );
      // 本项不按身份键 upsert（与 HabitAutoRunItem 同取向：终态通知），
      // 但控制器层的 seen 去重会滤掉同一 eventId，故归约器只保证「有产出」。
      final r = EventReducer.reduce([e]);
      expect(r.items, hasLength(1));
    });
  });

  /// 会话绑定失效（`pigo_session_missing`）——诊断事件，但解释了用户可感知的
  /// 「上下文莫名丢失」。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 该常量只在 `EventTypes` 声明（`pigoSessionMissing`），全仓零消费——事件
  /// 落到 `default:` 被静默丢弃。它虽标 `Diagnostic: true`（默认不广播、只落库），
  /// 但**会在拉 timeline 历史时到达**，那时它是唯一能解释「这段对话为什么断了
  /// 上下文」的线索。
  group('pigo_session_missing → DiagnosticNoticeItem', () {
    test('产出诊断项并原样透传服务端说明', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.pigoSessionMissing,
          payload: {
            'content': '检测到失效的会话绑定（历史会话文件未落盘），本次将新建会话继续',
            'session_id': 'sess-ghost-1',
            'expected_path': '/home/u/.pigo/sessions/sess-ghost-1.jsonl',
          },
        ),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      final item = r.items.single;
      expect(item, isA<DiagnosticNoticeItem>());
      final d = item as DiagnosticNoticeItem;
      expect(d.content, contains('失效的会话绑定'));
      expect(d.sessionId, 'sess-ghost-1');
    });

    test('content 缺失时用兜底文案仍产出（结论不丢）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.pigoSessionMissing, payload: {'session_id': 's1'}),
      ]);

      expect(r.items, hasLength(1));
      final d = r.items.single as DiagnosticNoticeItem;
      expect(d.content, '检测到失效的会话绑定，本次将新建会话继续');
      expect(d.sessionId, 's1');
    });

    test('payload 完全缺失时不编造 session_id', () {
      final r = EventReducer.reduce([ev(EventTypes.pigoSessionMissing)]);

      expect(r.items, hasLength(1));
      final d = r.items.single as DiagnosticNoticeItem;
      expect(d.sessionId, isNull);
      expect(d.content, isNotEmpty);
    });

    test('诊断事件不污染时间线顺序（与用户消息共存且各成一项）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          id: 'evt_u',
          payload: {'input': '继续'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.pigoSessionMissing,
          id: 'evt_d',
          payload: {'content': '会话已重建'},
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      expect(r.items[0], isA<UserMessageItem>());
      expect(r.items[1], isA<DiagnosticNoticeItem>());
    });
  });

  /// [EventReducer.inFlightTurnIds] 的测试。
  ///
  /// 它是「超时兜底」的判据来源：算漏一个 turn，那个 turn 卡死时 UI 就不会被
  /// 兜底；算多一个，已完成的 turn 会被误标成「无进展」。
  group('inFlightTurnIds', () {
    test('流式助手段落算进行中', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '正在生成'}, transient: true),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), {'turn_1'});
    });

    test('流式思考段落算进行中（长思考期没有任何正文）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.thought, payload: {'text': '想想'}, transient: true),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), {'turn_1'});
    });

    test('未配对的 tool_call 算进行中（长工具静默期）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'call_1', 'name': 'bash'},
        ),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), {
        'turn_1',
      }, reason: '只看 isStreaming 会漏掉这一段——而它最容易长时间静默');
    });

    test('已配对的 tool_call 不算进行中', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'call_1', 'name': 'bash'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.toolResult,
          payload: {'tool_call_id': 'call_1', 'output': 'ok'},
          globalSeq: 2,
        ),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), isEmpty);
    });

    test('done 之后不算进行中', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          payload: {'text': '回复'},
          transient: true,
          globalSeq: 1,
        ),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 2),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), isEmpty);
    });

    test('多个 turn 并存时都被列出（per-turn 计时器的前提）', () {
      // 第二个 turn 必须带 `start`：归约器靠它重置「当前累积段落」的索引
      // （`currentAssistantIdx`），否则增量帧会被**追加进上一个 turn 的段落**
      // ——这是归约层的既有语义，不是本函数的问题。
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          id: 'evt_a',
          turnId: 'turn_a',
          payload: {'text': 'A'},
          transient: true,
          globalSeq: 1,
        ),
        ev(EventTypes.start, id: 'evt_start_b', turnId: 'turn_b', globalSeq: 2),
        ev(
          EventTypes.message,
          id: 'evt_b',
          turnId: 'turn_b',
          payload: {'text': 'B'},
          transient: true,
          globalSeq: 3,
        ),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), {
        'turn_a',
        'turn_b',
      }, reason: '两者都要在集合里，控制器才能各自武装计时器');
    });

    test('done 闭合全部流式段落（归约层的既有语义，按 turn 无关）', () {
      // ⚠️ 归约层的 `_sealStreaming` 是**全局**的（一个 done 闭合所有流式段），
      // 不是按 turnId 闭合。这在实践中不咬人：同一 group 的 turn 是排队串行
      // 执行的（见 Go `chat/queue_state` 语义），不会有两个 turn 同时在跑。
      // 记录在此是为了让「per-turn 计时器」的后来者知道：本函数与归约层的
      // 闭合粒度**不同**，不要据此以为归约层也按 turn 处理。
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          id: 'evt_a',
          turnId: 'turn_a',
          payload: {'text': 'A'},
          transient: true,
          globalSeq: 1,
        ),
        ev(
          EventTypes.message,
          id: 'evt_b',
          turnId: 'turn_b',
          payload: {'text': 'B'},
          transient: true,
          globalSeq: 2,
        ),
        ev(
          EventTypes.done,
          id: 'evt_done_a',
          turnId: 'turn_a',
          payload: {'status': 'completed'},
          globalSeq: 3,
        ),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), isEmpty);
    });

    test('turnId 为空的项目被跳过（无法关联到任何 turn）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          turnId: '',
          payload: {'text': '异常载荷'},
          transient: true,
        ),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), isEmpty);
    });

    test('非流式的权威帧不算进行中（历史回填场景）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '完整回复'}),
      ]);

      expect(EventReducer.inFlightTurnIds(r.items), isEmpty);
    });
  });
}
