import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

// 真实增量帧的 eventId 为空、seq/globalSeq 为 0；不能用自动补 ID 的夹具。
ChatEvent event(
  String type, {
  String id = '',
  String turn = 'turn-1',
  String group = 'group-1',
  String text = '正文',
  bool transient = false,
  DateTime? at,
}) => ChatEvent(
  eventId: id,
  userId: 'user-1',
  groupId: group,
  turnId: turn,
  eventType: type,
  seq: transient ? 0 : 1,
  globalSeq: transient ? 0 : 1,
  source: 'agent',
  createdAt: at ?? DateTime.utc(2026, 11, 9),
  payload: {'content': text},
  transient: transient,
);

void main() {
  test('空 ID 增量产生的多轮回复，完成后仍各有独立且非空的 ID', () {
    final events = [
      for (var turn = 0; turn < 3; turn++) ...[
        event('start', id: 'start-$turn', turn: 'turn-$turn'),
        event('message', turn: 'turn-$turn', transient: true),
        event(
          'message',
          id: 'final-$turn',
          turn: 'turn-$turn',
          text: '完整 $turn',
        ),
        event('done', id: 'done-$turn', turn: 'turn-$turn'),
      ],
    ];
    final result = EventReducer.reduce(events);
    final replies = result.items.whereType<AssistantMessageItem>().toList();
    expect(replies.map((item) => item.text), ['完整 0', '完整 1', '完整 2']);
    expect(replies.every((item) => !item.isStreaming), isTrue);
    expect(replies.map((item) => item.id), everyElement(isNotEmpty));
    expect(replies.map((item) => item.id).toSet(), hasLength(3));
    expect(duplicateRowOwners(groupTimelineForDisplay(result.items)), isEmpty);
    expect(result.lastEventId, 'done-2');
  });

  test('同轮同时间戳的思考与工具前后正文也不共用 ID', () {
    final result = EventReducer.reduce([
      event('thought', transient: true),
      event('message', transient: true, text: '工具前'),
      event('tool_call', id: 'tool'),
      event('thought', transient: true),
      event('message', transient: true, text: '工具后'),
    ]);
    expect(result.items, hasLength(5));
    expect(result.items.map((item) => item.id), everyElement(isNotEmpty));
    expect(result.items.map((item) => item.id).toSet(), hasLength(5));
  });

  test('追加增量、权威帧和 done 均保留段落最初的 ID，游标只用落库 ID', () {
    final events = [
      event('start', id: 'start'),
      event('message', transient: true, text: '开头'),
    ];
    final first = EventReducer.reduce(events);
    final id = first.items.single.id;
    expect(id, isNotEmpty);
    expect(first.lastEventId, 'start');
    events.add(event('message', transient: true, text: '结尾'));
    final extended = EventReducer.reduce(events);
    expect(extended.items.single.id, id);
    expect((extended.items.single as AssistantMessageItem).text, '开头结尾');
    expect(extended.lastEventId, 'start');
    events.add(event('message', id: 'final', text: '权威完整正文'));
    final complete = EventReducer.reduce(events);
    expect(complete.items.single.id, id);
    expect((complete.items.single as AssistantMessageItem).text, '权威完整正文');
    expect(complete.lastEventId, 'final');
    events.add(event('done', id: 'done'));
    expect(EventReducer.reduce(events).items.single.id, id);
  });

  test('前插更早历史、重新解析同一批事件，不改变已有段落 ID', () {
    final events = [
      event('start', id: 'start'),
      event('message', transient: true),
    ];
    final id = EventReducer.reduce(events).items.single.id;
    final result = EventReducer.reduce([
      // 即使更早历史属于同一轮，也不能依赖列表下标或全局段落计数。
      event('message', transient: true, at: DateTime.utc(2026, 11, 8)),
      event('tool_call', id: 'older-tool'),
      ...events.map((item) => ChatEvent.fromJson(item.toJson())),
    ]);
    expect(result.items.last.id, id);
    expect(result.items.map((item) => item.id).toSet(), hasLength(3));
  });

  test('不同对话里的同轮同时间戳增量不共用本地 ID', () {
    final first = EventReducer.reduce([event('message', transient: true)]);
    final second = EventReducer.reduce([
      event('message', transient: true, group: 'group-2'),
    ]);
    expect(first.items.single.id, isNot(second.items.single.id));
  });

  test('已有 eventId 原样保留，历史回放与本地回显身份不变', () {
    final result = EventReducer.reduce([
      event('message', id: 'persisted'),
      event('done', id: 'done'),
      event('message', id: 'test-delta', transient: true),
    ]);
    expect(result.items.map((item) => item.id), ['persisted', 'test-delta']);
    expect(result.lastEventId, 'done');
  });
}
