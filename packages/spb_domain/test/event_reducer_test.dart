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

  /// EventReducer 的归约正确性测试（时间线核心）
  ///
  /// ⚠️ 本文件由 `event_reducer_test.dart` 按 **group 边界**拆出（issue #48）——
  /// 纯移动，**未改动任何断言**。`ev(...)` 辅助函数在每份文件里各带一份
  /// （同 `chat_stream_controller_stale_test.dart` 的既有先例：Dart 的测试
  /// 辅助无法跨文件共享，除非进 `lib/`——那会让测试代码进生产产物）。

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

    test('agent_id 在权威帧到达后仍保留（供「重发」带上同一个 agent）', () {
      // 本地回显带 agent_id（客户端自己加的键），服务端事件不带。
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          id: 'local-1',
          turnId: 'turn_7',
          payload: {'input': '你好', 'agent_id': 'agt_x'},
          transient: true,
        ),
        ev(
          EventTypes.userMessage,
          id: 'evt_real',
          turnId: 'turn_7',
          payload: {'input': '你好'},
          globalSeq: 42,
        ),
      ]);

      expect((r.items.single as UserMessageItem).agentId, 'agt_x');
    });

    test('服务端事件自带 agent_id 时以它为准', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'turn_7',
          payload: {'input': '你好', 'agent_id': 'agt_server'},
        ),
      ]);

      expect((r.items.single as UserMessageItem).agentId, 'agt_server');
    });

    test('两边都没有 agent_id 时为 null（不编造）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, turnId: 'turn_7', payload: {'input': '你好'}),
      ]);

      expect((r.items.single as UserMessageItem).agentId, isNull);
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
}
