import 'package:spb_api/spb_api.dart';
import 'package:spb_models/spb_models.dart';

/// 一个 turn 的详情：元数据 + 事件列表。
///
/// ## 为什么单独建一个值类型而不是用 record
///
/// 它是**跨层契约**（装配层构造、面板消费、测试断言）。命名类型让签名可读
/// （`Future<TurnDetail>` vs `Future<({ChatTurn turn, List<ChatEvent> events})>`），
/// 也便于将来加字段（如 `derivedSource`）而不动所有调用点。
class TurnDetail {
  const TurnDetail({required this.turn, required this.events});

  final ChatTurn turn;

  /// 该 turn 的事件，**已按 [ChatEvent.seq] 升序**（见
  /// [LoadTurnDetailUseCase.call] 的排序说明）。
  final List<ChatEvent> events;

  /// 是否没取到任何事件（调用方据此展示空提示而非空白）。
  bool get hasNoEvents => events.isEmpty;
}

/// 加载某个 turn 的完整详情（meta + 事件）。
///
/// ## 为什么需要它：上游 `GET /chat/turns/:id` 不返回 events
///
/// `chat.go` 的 `getTurn` 只回 `turnToDict(turn)`，**没有 `events`**
/// （见 issue `dever/super_partyb#56`）。而 webapp 的
/// `ChatTurnDetailResponse` 声称有 `events` —— 这是服务端与 webapp 的既有
/// 契约漂移，不是本仓库的缺口。
///
/// 受「Go API 一行不改」约束，客户端只能自己凑：
///
/// ```
/// GET /chat/turns/:turn_id                    → meta
/// GET /chat/groups/:group_id/timeline         → 群级事件流，本地按 turnId 过滤
/// ```
///
/// ## 上游 #56 若补了 events，这里改什么
///
/// 本类的 `call` 退化为单次 `getTurn`（groupTimeline 那段删掉），**签名不变**
/// ——调用方与测试都不必改。把「需要几个请求」挡在这一层，是它存在的另一半理由。
///
/// ## 为什么分页
///
/// timeline 是**群级**、按 `global_seq` 倒序（最新在前）分页的。若目标 turn 的
/// 事件已被挤出一页窗口（老 turn、或群里近期活动极多），单页过滤会得到空列表
/// ——表现为「详情页什么都没有」而真相是「没翻到」。故按 [maxPages] 向后翻页，
/// 直到找到该 turn 的事件或翻完。
///
/// 停止条件（任一命中）：
/// - 已找到该 turn 的事件（**最早一条**即可停：`global_seq` 倒序翻页，一旦某页
///   出现该 turn，其全部事件都在这一页或更早的页里——但更早的页只会更早，
///   不会再有该 turn 的事件，故命中即停是对的）；
/// - 翻满 [maxPages]（防止老 turn 把用户拖进几十次请求）；
/// - 某页为空（已到最早）。
///
/// [maxPages] 默认 3（× 每页 200 = 最多 600 条事件）：覆盖「最近轮次」页面上
/// 绝大多数可点的 turn（该页面按 `created_at DESC` 排序，用户点的是最近的），
/// 又不至于让一次点击发出十几轮请求。
class LoadTurnDetailUseCase {
  LoadTurnDetailUseCase(this._api, {this.pageLimit = 200, this.maxPages = 3});

  final ChatApi _api;

  /// 每页拉取条数（服务端 `parseLimit(c.Query("limit"), 200, 500)`，上限 500）。
  final int pageLimit;

  /// 最多翻几页（见类文档「为什么分页」的停止条件）。
  final int maxPages;

  /// 加载详情。
  ///
  /// 返回的 [TurnDetail.events] 已按 [ChatEvent.seq] 升序排好——`seq` 是
  /// **每轮从 1 重来**的轮内序，正是详情页要的「这一轮内部的先后」。
  ///
  /// ## 为什么排序放在这里而不是面板里
  ///
  /// 过滤路径天然得到的是 `global_seq` 序，而展示要的是 `seq` 序，两者未必一致。
  /// 放在这里意味着面板拿到的就是可直接渲染的列表；面板侧再排一次是无害的幂等
  /// 操作（它也做，作为对直接构造 [TurnDetail] 的调用方的防御）。
  Future<TurnDetail> call(String groupId, String turnId) async {
    final turn = await _api.getTurn(turnId);

    final found = <ChatEvent>[];
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final result = await _api.groupTimeline(
        groupId,
        limit: pageLimit,
        beforeGlobalSeq: cursor,
      );
      final items = result.items;
      if (items.isEmpty) break;

      found.addAll(items.where((e) => e.turnId == turnId));

      // 命中即停（见类文档：更早的页不会再有该 turn 的事件）。
      if (found.isNotEmpty) break;

      // 本页不足一页说明已到最早，不必再翻。
      if (items.length < pageLimit) break;

      cursor = result.nextCursor;
      // 服务端没给游标就无从继续（防御：不能拿 null 去请求「最新一页」，
      // 那会无限循环拉同一页）。
      if (cursor == null || cursor.isEmpty) break;
    }

    found.sort((a, b) {
      final bySeq = a.seq.compareTo(b.seq);
      if (bySeq != 0) return bySeq;
      // seq 相同（异常载荷或全 0）时退到 globalSeq，再退到 createdAt。
      final byGlobal = (a.globalSeq ?? 0).compareTo(b.globalSeq ?? 0);
      if (byGlobal != 0) return byGlobal;
      return a.createdAt.compareTo(b.createdAt);
    });

    return TurnDetail(turn: turn, events: found);
  }
}
