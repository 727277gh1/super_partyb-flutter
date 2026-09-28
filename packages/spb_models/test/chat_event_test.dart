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
}
