/// 分页与游标。
///
/// Go API 的分页有两套约定，客户端必须都支持：
/// 1. **offset 分页**：`?limit=&offset=`，响应 `{items: [...]}`（如 `GET /chat/groups`）
/// 2. **游标分页**：`?before_global_seq=`，响应含 `next_cursor`（如 timeline）
///
/// timeline 还有**新旧双游标**：新游标 `before_global_seq`（推荐），
/// 旧游标 `before_time` + `before_seq`（兼容保留）。客户端一律用新游标。
library;

/// 列表响应（`{items: [...]}` 形态）。
///
/// WHY 单独建类而非直接返回 `List<T>`：服务端未来可能加 `total` / `has_more`
/// 字段，返回裸 List 时无法扩展。这里的 `unwrapItems` 也顺带吞掉「服务端返回
/// 裸数组而非包装对象」的历史差异。
class ListResponse<T> {
  const ListResponse({required this.items, this.total, this.hasMore});

  final List<T> items;
  final int? total;
  final bool? hasMore;

  factory ListResponse.fromJson(
    Object? json,
    T Function(Map<String, dynamic>) fromItem,
  ) {
    // 兼容两种形态：`{items: [...]}` 与裸 `[...]`。
    final raw = json is List ? json : (json is Map ? json['items'] : null);
    final items = <T>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) items.add(fromItem(Map<String, dynamic>.from(e)));
      }
    }
    final meta = json is Map ? json : const <String, dynamic>{};
    return ListResponse(
      items: items,
      total: meta['total'] is num ? (meta['total'] as num).toInt() : null,
      hasMore: meta['has_more'] is bool ? meta['has_more'] as bool : null,
    );
  }
}

/// timeline 的游标分页结果。
///
/// `nextCursor` 为 null 表示已到最早一条（无更多历史）。
class CursorPage<T> {
  const CursorPage({required this.items, this.nextCursor});

  final List<T> items;

  /// 传给下一次请求的 `before_global_seq` 值。
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory CursorPage.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromItem,
  ) {
    final raw = json['items'] ?? json['events'];
    final items = <T>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) items.add(fromItem(Map<String, dynamic>.from(e)));
      }
    }
    final cursor = json['next_cursor'] ?? json['nextCursor'];
    return CursorPage(
      items: items,
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
    );
  }
}

/// SSE 断线重连的续接游标。
///
/// 服务端语义：`GET /users/:uid/chat/stream?cursor=<最后收到的 eventId>`，
/// 回放该事件之后落库的事件（上限 500 条）。超出窗口时返回空，
/// 客户端应改走 timeline API 做整段回填。
class StreamCursor {
  const StreamCursor(this.lastEventId);

  /// 最后收到的 `ChatEvent.eventId`（= chat_events.id）。
  final String lastEventId;

  /// 服务端单次回放上限，超出说明断线过久。
  static const int replayLimit = 500;

  /// 拼接到 URL 的 query 值；为空时不带 cursor（首次连接）。
  String? get queryValue => lastEventId.isEmpty ? null : lastEventId;
}
