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

  /// EventReducer 的派生查询（超时兜底与 B1b 结构推断）
  ///
  /// ⚠️ 本文件由 `event_reducer_test.dart` 按 **group 边界**拆出（issue #48）——
  /// 纯移动，**未改动任何断言**。`ev(...)` 辅助函数在每份文件里各带一份
  /// （同 `chat_stream_controller_stale_test.dart` 的既有先例：Dart 的测试
  /// 辅助无法跨文件共享，除非进 `lib/`——那会让测试代码进生产产物）。

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

  /// [EventReducer.lastTurnRunState] / [EventReducer.lastTurnMayBeRunning] 的测试。
  ///
  /// 它们回答的是「重开一个对话时，服务端的 turn 是不是还在跑」（issue #9 / AGENTS.md
  /// §5.8 的「B1b」）。判据是**结构推断**（最后一个 turn 有无 agent 产物 / 终态），
  /// 与 [EventReducer.inFlightTurnIds] 的「流式标记」不同。
  ///
  /// 两个方向都要防：算漏一个（仍在跑的 turn 不武装看门狗）会让界面静止骗人；
  /// 算多一个（已完成的 turn 被判成在跑）会让每个历史对话都转圈。
  group('lastTurnRunState / lastTurnMayBeRunning', () {
    test('只有权威帧、无 done 的 turn → streaming（重开对话的主场景）', () {
      // 这是 B1b 缺口的核心用例：全非 Transient，故 inFlightTurnIds 为空。
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': '帮我看看'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '完整回复'}, globalSeq: 2),
      ]);

      expect(
        EventReducer.inFlightTurnIds(r.items),
        isEmpty,
        reason: '流式标记看不到权威帧——这正是 B1b 缺口的成因',
      );
      expect(
        EventReducer.lastTurnRunState(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        LastTurnRunState.streaming,
      );
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isTrue,
      );
      expect(
        EventReducer.lastRunningTurnId(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        'turn_1',
      );
    });

    test('权威帧 + done → terminal，不武装看门狗', () {
      // 反向防线：若不做终态记录，本用例与上一条在 items 上完全一致，
      // 会把每个已结束的历史对话都判成「仍在跑」。
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': '帮我看看'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '完整回复'}, globalSeq: 2),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 3),
      ]);

      expect(r.terminalTurnIds, contains('turn_1'));
      expect(
        EventReducer.lastTurnRunState(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        LastTurnRunState.terminal,
      );
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isFalse,
        reason: '已终结 turn 不得武装计时器',
      );
      expect(
        EventReducer.lastRunningTurnId(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isEmpty,
      );
    });

    test('error 也算终态（超时/执行异常先发 error 再发 done）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': '开头'}, globalSeq: 1),
        ev(EventTypes.error, payload: {'content': '执行超时'}, globalSeq: 2),
      ]);

      expect(r.terminalTurnIds, contains('turn_1'));
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isFalse,
      );
    });

    test('只有用户消息（agent 尚未产出）→ preparing，同样武装看门狗', () {
      // 排队/起跑空窗期最需要兜底：服务端可能已崩且永远不会发 done。
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': '刚发出'}, globalSeq: 1),
      ]);

      expect(
        EventReducer.lastTurnRunState(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        LastTurnRunState.preparing,
      );
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isTrue,
      );
    });

    test('preparing 与 streaming 可区分（agent 侧项的出现是分界）', () {
      final preparing = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': 'x'}, globalSeq: 1),
      ]);
      final streaming = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': 'x'}, globalSeq: 1),
        ev(
          EventTypes.toolCall,
          payload: {'tool_call_id': 'c1', 'name': 'bash'},
          globalSeq: 2,
        ),
      ]);

      expect(
        EventReducer.lastTurnRunState(
          preparing.items,
          terminalTurnIds: preparing.terminalTurnIds,
        ),
        LastTurnRunState.preparing,
      );
      expect(
        EventReducer.lastTurnRunState(
          streaming.items,
          terminalTurnIds: streaming.terminalTurnIds,
        ),
        LastTurnRunState.streaming,
      );
    });

    test('空时间线 → idle，不武装', () {
      expect(EventReducer.lastTurnRunState(const []), LastTurnRunState.idle);
      expect(EventReducer.lastTurnMayBeRunning(const []), isFalse);
      expect(EventReducer.lastRunningTurnId(const []), isEmpty);
    });

    test('turnId 为空的项目被跳过 → idle', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, turnId: '', payload: {'text': '异常载荷'}),
      ]);

      expect(
        EventReducer.lastTurnRunState(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        LastTurnRunState.idle,
      );
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isFalse,
      );
    });

    test('router 伪 turn 被跳过（不代表一次执行）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'router',
          payload: {'input': '归属判定'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.message,
          turnId: 'turn_real',
          payload: {'text': '回复'},
          globalSeq: 2,
        ),
      ]);

      expect(
        EventReducer.lastRunningTurnId(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        'turn_real',
        reason: '最后一个可归属的 turn 是 turn_real，router 不参与',
      );
    });

    test('多 turn 时只看最后一个（同 group 串行执行，旧的漏 done 不该永远挂住）', () {
      // turn_old 没有 done（历史上丢过终态），turn_new 已完成。
      // 若把「所有 turn」都算上，本对话会被永远判成在跑。
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'turn_old',
          payload: {'input': '旧的'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.message,
          turnId: 'turn_old',
          payload: {'text': '旧的回复'},
          globalSeq: 2,
        ),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_new',
          payload: {'input': '新的'},
          globalSeq: 3,
        ),
        ev(
          EventTypes.message,
          turnId: 'turn_new',
          payload: {'text': '新的回复'},
          globalSeq: 4,
        ),
        ev(
          EventTypes.done,
          turnId: 'turn_new',
          payload: {'status': 'completed'},
          globalSeq: 5,
        ),
      ]);

      expect(
        EventReducer.lastRunningTurnId(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isEmpty,
        reason: '最后一个 turn 已终结，旧的漏 done 不该让它永远显示成运行中',
      );
      expect(
        EventReducer.lastTurnMayBeRunning(
          r.items,
          terminalTurnIds: r.terminalTurnIds,
        ),
        isFalse,
      );
    });

    test('不传 terminalTurnIds 时把历史 turn 判成可能在跑（说明为何生产必须传）', () {
      // 记录这个陷阱：终态不在 items 里，省略参数会丢掉「已结束」这个事实。
      final r = EventReducer.reduce([
        ev(EventTypes.userMessage, payload: {'input': 'x'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '回复'}, globalSeq: 2),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 3),
      ]);

      expect(
        EventReducer.lastTurnMayBeRunning(r.items),
        isTrue,
        reason: '不传终态集合时无法区分——这正是必须由归约器派生的理由',
      );
    });
  });
}
