/// groupsync 待确认同步项的**跨 group 聚合**（纯逻辑，可无头单测）。
///
/// ## 为什么需要这一层
///
/// 服务端只有**按 group** 的列表端点（`GET /chat/groups/:gid/workspace-sync/
/// reviews`），没有跨 group 的聚合端点（对照 `/chat/confirmations` 那个扁平列表）。
/// 而设置页「交付物同步」标签是**没有 group 上下文**的入口：用户在那里配的是
/// 「同步哪些对话的交付物」，看到的待确认项也必须覆盖同一个范围。
///
/// 故聚合放在这里：给定 group 列表 + 单 group 取数函数，并发查询并拼成一份
/// 可直接渲染的快照。放在 domain 而不是 app 的好处是它能被纯单测覆盖
/// （不碰 Riverpod、不碰 Flutter），两端的装配层只负责给 group 列表。
///
/// ## 为什么要限制并发
///
/// 范围是「全部对话」时 group 可能有几十个，而轮询间隔是 15 秒。无限制地并发
/// 打出去会让网关在同一瞬间收到几十个请求（且每个都要过鉴权与路由）。
/// 4 路并发 + 顺序无关的结果归位（按下标回填，不按完成顺序）既控住了突发，
/// 又保证列表顺序稳定（同一条待确认项不会因为哪个请求先回来而上下跳）。
///
/// ## 单个 group 失败不拖垮整份快照
///
/// 待确认项是「解释为什么文件没下来」的辅助信息，不是同步本身。一个 group 的
/// 查询失败（已归档、被删、网关抖动）不该让其余 group 的待确认项一起消失——
/// 那会让用户失去唯一的线索。失败计入 [WorkspaceSyncReviewsSnapshot.failedGroups]
/// 并由 UI 用一句话说明。
library;

import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

/// 取单个 group 的待确认项（真实实现是 `ChatApi.listWorkspaceSyncReviews`）。
typedef WorkspaceSyncReviewsFetcher = Future<WorkspaceSyncReviewsPage> Function(
  String groupId,
);

/// 参与聚合的一个 group：id + 展示用标题。
///
/// 标题由装配层从 `GET /chat/groups` 取（客户端没有别的地方能拿到它）。
/// 取不到时用空串——UI 退化成只显示路径，而不是编造一个标题。
class WorkspaceSyncReviewGroup {
  const WorkspaceSyncReviewGroup({required this.id, this.title = ''});

  final String id;
  final String title;
}

/// 一条「属于某个 group」的待确认项（渲染单元）。
class WorkspaceSyncReviewEntry {
  const WorkspaceSyncReviewEntry({
    required this.groupId,
    required this.groupTitle,
    required this.review,
  });

  /// 所属 group id（resolve 路径需要它，见 [WorkspaceSyncReview.groupId]）。
  final String groupId;

  /// 所属 group 标题（空串表示取不到，UI 不展示这一行）。
  final String groupTitle;

  /// 服务端返回的挂起项。
  final WorkspaceSyncReview review;
}

/// 一次聚合的结果。
class WorkspaceSyncReviewsSnapshot {
  const WorkspaceSyncReviewsSnapshot({
    this.entries = const [],
    this.failedGroups = 0,
    this.enabled = false,
    this.queriedGroupIds = const {},
  });

  /// 待确认项（按传入的 group 顺序、组内按服务端给的路径顺序）。
  final List<WorkspaceSyncReviewEntry> entries;

  /// 查询失败的 group 数（0 表示全部成功）。
  final int failedGroups;

  /// 是否**有** group 报告文件同步已启用。
  ///
  /// 任一 group 返回 `enabled: true` 即为 true：全部 group 都未启用时才说明
  /// 服务端没跑 groupsync（此时候 UI 应整块隐藏，见 `WorkspaceSyncReviewsPage`）。
  final bool enabled;

  /// 本轮**实际查询过**的 group id 集合（空 id 已剔除）。
  ///
  /// ## 为什么快照要带上它
  ///
  /// 待确认项可以靠 `todo.changed` 即时失效（设置页的
  /// `WorkspaceSyncReviewsSection` 收到事件就重拉），而事件是**群级**的：
  /// 一条通知对应一个 group，但本区块查的是「同步范围」里的一批 group。
  ///
  /// 没有这个集合，区块只能两种选：全部事件都重拉（范围是全部对话时，
  /// 一次无关 group 的变更就要发 1 + N 个 GET），或全部不重拉（等于没接）。
  /// 带上它，判据变成「这个 group 上一轮是否在查询集里」——不在则
  /// **重拉也不可能多出内容**（区域范围的缺口另见装配层注释），故可以安全跳过。
  ///
  /// 取值来自 [collectWorkspaceSyncReviews] 的入参：它是**上次查询**的范围，
  /// 不是当前设置的最新值。故消费方**不得**用它做权限/范围判据，只用于
  /// 「这次通知是否可能改变本快照」的短路。
  final Set<String> queriedGroupIds;

  bool get isEmpty => entries.isEmpty;
}

/// 并发查询 [groups] 的待确认项并聚合。
///
/// [concurrency] 小于 1 时按 1 处理；为 0 个 group 时返回空快照且 `enabled: false`。
///
/// 顺序保证：结果按下标回填，故 [WorkspaceSyncReviewsSnapshot.entries] 与
/// [groups] 的顺序一致（同 group 内保持服务端返回顺序）。
Future<WorkspaceSyncReviewsSnapshot> collectWorkspaceSyncReviews({
  required List<WorkspaceSyncReviewGroup> groups,
  required WorkspaceSyncReviewsFetcher fetch,
  int concurrency = 4,
}) async {
  if (groups.isEmpty) return const WorkspaceSyncReviewsSnapshot();

  final pages = List<WorkspaceSyncReviewsPage?>.filled(groups.length, null);
  var failed = 0;
  var next = 0;
  final workers = concurrency < 1 ? 1 : concurrency;

  Future<void> worker() async {
    while (true) {
      // Dart 单线程模型：自增与取下标之间没有 await，故不会有两个 worker
      // 抢到同一个下标。
      final index = next++;
      if (index >= groups.length) return;
      final group = groups[index];
      if (group.id.trim().isEmpty) {
        // 空 id 会把路径拼成 `/chat/groups//workspace-sync/reviews`（404），
        // 直接当失败计——静默跳过会让「某个对话的待确认项从来没出现」无从排查。
        failed++;
        continue;
      }
      try {
        pages[index] = await fetch(group.id);
      } on Object catch (e) {
        failed++;
        SpbLog.warn('待确认同步项查询失败', {'group': group.id, 'error': e.toString()});
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < workers && i < groups.length; i++) worker(),
  ]);

  final entries = <WorkspaceSyncReviewEntry>[];
  final queriedGroupIds = <String>{};
  var enabled = false;
  for (var i = 0; i < groups.length; i++) {
    final page = pages[i];
    // 只把**真的查过**的 group 记进来（空 id 在上面已按失败跳过）。
    // 存原值（不 trim）：与 [WorkspaceSyncReviewEntry.groupId] 逐字一致，
    // 消费方拿事件里的 groupId 做 contains 时不会因为两侧归一化不同而错判。
    if (groups[i].id.trim().isNotEmpty) {
      queriedGroupIds.add(groups[i].id);
    }
    if (page == null || !page.enabled) continue;
    enabled = true;
    for (final review in page.items) {
      entries.add(
        WorkspaceSyncReviewEntry(
          groupId: groups[i].id,
          groupTitle: groups[i].title,
          review: review,
        ),
      );
    }
  }

  return WorkspaceSyncReviewsSnapshot(
    entries: entries,
    failedGroups: failed,
    enabled: enabled,
    queriedGroupIds: queriedGroupIds,
  );
}
