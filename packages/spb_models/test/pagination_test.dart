import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 分页契约测试。
///
/// 重点是 timeline 的**游标取值**：服务端 `chat.go` 的响应同时给出
/// `next_cursor`（最旧事件的 **event id**）与 `next_before_global_seq`
/// （最旧事件的 global_seq）。只有后者能回传作 `before_global_seq`；
/// 误用前者会让服务端 `strconv.ParseInt` 失败、游标归零、每页返回最新一批，
/// **翻页死循环且无任何报错**。这里的断言就是钉死这个区分。
void main() {
  Map<String, dynamic> item(int globalSeq) => {
    'event_id': 'evt_$globalSeq',
    'event_type': 'message',
    'global_seq': globalSeq,
    'seq': 1,
    'source': 'pigo',
    'created_at': '2026-09-28T10:11:12.345Z',
    'payload': {'text': 'msg $globalSeq'},
  };

  group('CursorPage（timeline 游标分页）', () {
    test('nextCursor 取自 next_before_global_seq，且不等于 next_cursor', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(300), item(200), item(100)],
        'next_cursor': 'evt_100', // 最旧事件的 event id —— 不是游标
        'next_before_global_seq': 100, // 真正的游标（int64）
        'next_before_time': '2026-09-28T10:11:12.345Z',
        'next_before_seq': '1',
      }, ChatEvent.fromJson);

      expect(page.nextCursor, '100');
      expect(page.nextCursor, isNot('evt_100'));
      expect(page.hasMore, isTrue);
      expect(page.items, hasLength(3));
      expect(page.items.first.globalSeq, 300);
    });

    test('next_before_global_seq 为字符串时同样被接受', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(50)],
        'next_cursor': 'evt_50',
        'next_before_global_seq': '50',
      }, ChatEvent.fromJson);

      expect(page.nextCursor, '50');
    });

    test('同时存在时 next_before_global_seq 优先于 next_cursor', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(42)],
        'next_cursor': 'evt_42',
        'next_before_global_seq': 42,
      }, ChatEvent.fromJson);

      expect(page.nextCursor, '42');
      expect(page.nextCursor, isNot('evt_42'));
    });

    test('服务端只给 next_cursor 时降级使用（不丢游标）', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(7)],
        'next_cursor': 'evt_7',
      }, ChatEvent.fromJson);

      expect(page.nextCursor, 'evt_7');
    });

    test('驼峰 nextBeforeGlobalSeq 也被接受', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(11)],
        'nextBeforeGlobalSeq': 11,
      }, ChatEvent.fromJson);

      expect(page.nextCursor, '11');
    });

    test('无游标字段时 nextCursor 为 null，hasMore 为 false', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(1)],
      }, ChatEvent.fromJson);

      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
    });

    test('空串游标视为无游标（服务端无更多历史时会给空串）', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': <Map<String, dynamic>>[],
        'next_before_global_seq': '',
      }, ChatEvent.fromJson);

      expect(page.nextCursor, isNull);
      expect(page.hasMore, isFalse);
      expect(page.items, isEmpty);
    });

    test('events 键（另一种服务端形态）同样被识别', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'events': [item(9)],
        'next_before_global_seq': 9,
      }, ChatEvent.fromJson);

      expect(page.items, hasLength(1));
      expect(page.items.single.globalSeq, 9);
    });

    test('items 里非 Map 元素被跳过，不抛异常', () {
      final page = CursorPage<ChatEvent>.fromJson({
        'items': [item(5), 'not-a-map', 42, null],
        'next_before_global_seq': 5,
      }, ChatEvent.fromJson);

      expect(page.items, hasLength(1));
    });
  });

  group('ListResponse（offset 分页）', () {
    test('裸数组形态与 {items:[...]} 形态都被兼容', () {
      final wrapped = ListResponse<ChatEvent>.fromJson({
        'items': [item(1)],
        'total': 1,
        'has_more': false,
      }, ChatEvent.fromJson);
      expect(wrapped.items, hasLength(1));
      expect(wrapped.total, 1);
      expect(wrapped.hasMore, isFalse);

      final bare = ListResponse<ChatEvent>.fromJson([
        item(2),
      ], ChatEvent.fromJson);
      expect(bare.items, hasLength(1));
      expect(bare.items.single.globalSeq, 2);
    });
  });

  group('StreamCursor', () {
    test('空 eventId 时不带 cursor（首次连接）', () {
      expect(const StreamCursor('').queryValue, isNull);
    });

    test('非空 eventId 时作为 cursor 值', () {
      expect(const StreamCursor('evt_abc').queryValue, 'evt_abc');
    });

    test('回放上限常量与服务端一致（500 条）', () {
      expect(StreamCursor.replayLimit, 500);
    });
  });
}
