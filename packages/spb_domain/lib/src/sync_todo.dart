/// 「工作区待处理」待办项的纯逻辑（与 webapp `lib/workbench/workspace-sync-todo.ts`
/// 逐条对齐）。
///
/// ## 为什么单独一个文件
///
/// 待办面板有两个来源：对话确认卡（阻塞，挂在 turn 上）与工作区同步事项
/// （不阻塞，没有 turn）。两者**共用一套展示契约**（徽标、`stale` 态、归因），
/// 但真源与动作完全不同。把纯逻辑放在这里，UI 只渲染，两端（桌面/移动）复用同一份
/// 判据，不各写一遍。
///
/// ## 红线
///
/// 不返回可调用 URL、不伪造 turn、不把同步项写进 `chat_confirmations`。
library;

import 'package:spb_models/spb_models.dart';

/// 待办项的状态。
enum SyncTodoItemState {
  /// 真源里确实存在，等用户动作。
  pending,

  /// 用户点过、但服务端说快照已变（409）。需要按最新列表重看。
  ///
  /// 没有 `queued` 态：review 一被 resolve 就从 worker 的 `Holds` 里消失，
  /// 「已批准但还没上传」属于 `local-files.sync_state`，不是待办。
  stale,
}

/// 待办面板里的一条「工作区待处理」。
class WorkspaceSyncTodoItem {
  const WorkspaceSyncTodoItem({
    required this.refId,
    required this.state,
    required this.review,
  });

  /// 稳定引用 `reviewId:revision`。
  ///
  /// 列表刷新后只有 revision 变了才应视为「已变化」——用它做 key 与 stale 判据，
  /// 而不是 review id：同一路径的文件集合可能被 agent 改写（id 不变、revision 变）。
  final String refId;

  final SyncTodoItemState state;

  /// 服务端挂起项（唯一真源，本类不复制它的字段）。
  final WorkspaceSyncReview review;
}

/// `refId = <id>:<revision>`（revision 是 sha256 hex，不含冒号，可安全 split）。
String syncTodoRefId(WorkspaceSyncReview review) =>
    '${review.id}:${review.revision}';

/// 构建待办项：`stale` 排最后，其余按路径排序。
///
/// ## 为什么 stale 排最后
///
/// 用户刚点过的那一条，服务端说「集合变了」。它此刻的路径/原因已经不可信，
/// 把它留在原位会让用户以为「刚才那一下点空了」。挪到末尾 + 一句「已变化」，
/// 用户的视线自然回到**新的**那几条上（与 webapp 同一排序）。
///
/// [staleRefIds] 由 UI 维护：刷新后若该 revision 已不在列表里，条目自然消失
/// ——这正是期望行为（真源已经不同意它存在）。
List<WorkspaceSyncTodoItem> buildWorkspaceSyncTodos(
  List<WorkspaceSyncReview> reviews, {
  Set<String> staleRefIds = const {},
}) {
  final items = [
    for (final review in reviews)
      WorkspaceSyncTodoItem(
        refId: syncTodoRefId(review),
        state: staleRefIds.contains(syncTodoRefId(review))
            ? SyncTodoItemState.stale
            : SyncTodoItemState.pending,
        review: review,
      ),
  ];
  items.sort((a, b) {
    if (a.state != b.state) {
      return a.state == SyncTodoItemState.stale ? 1 : -1;
    }
    return a.review.path.compareTo(b.review.path);
  });
  return items;
}

/// 待办 tab 的徽标文案：两类待办**分别计数**，合并显示 `3+1` 而不是 `4`。
///
/// ## 为什么不合并成总数
///
/// 确认卡是阻塞的（不答复就跑不下去），同步事项不是。相加会让用户以为有 4 件事
/// 在等他，实际只有 3 件必须处理——徽标是「有多少事在等我」的唯一信号，虚报
/// 会让它失去意义（与 webapp `todoBadgeLabel` 同一判据）。
///
/// 返回 null 表示不显示徽标（两类都为 0）。负数按 0 处理（防御脏数据）。
String? todoBadgeLabel(int blocking, int actionable) {
  final b = blocking < 0 ? 0 : blocking;
  final a = actionable < 0 ? 0 : actionable;
  if (b == 0 && a == 0) return null;
  if (b == 0) return '$a';
  if (a == 0) return '$b';
  return '$b+$a';
}

/// 徽标旁边的解释文案（悬停 / 长按 / 读屏用）：`3+1` 本身没有语义。
///
/// ## 为什么必须有它
///
/// `3+1` 是**故意的非加法**（确认卡阻塞、同步事项不阻塞，见 [todoBadgeLabel]），
/// 但用户第一眼看到的只是两个数字。没有一句「3 项要答复、1 项只是文件在等确认」，
/// 这个徽标就变成谜语——比合并成 `4` 更糟，因为它暗示了一件不存在的事。
/// 文案同时说明阻塞性差异，用户才知道「可以不理会那 1」。
///
/// 返回 null 表示没有徽标（也就没有可解释的东西）。
String? todoBadgeHint(int blocking, int actionable) {
  final b = blocking < 0 ? 0 : blocking;
  final a = actionable < 0 ? 0 : actionable;
  if (b == 0 && a == 0) return null;
  if (b == 0) return '$a 项工作区待处理（文件等确认，不影响对话继续）';
  if (a == 0) return '$b 项待确认（不答复对话不会继续）';
  return '$b 项待确认（不答复对话不会继续）· $a 项工作区待处理（不影响对话继续）';
}

/// 归因展示：`title` = 查到了轮次标题；`id` = 只有短 id。
enum SyncTodoAttributionKind { title, id }

/// 一条归因（由 [describeSyncTodoAttribution] 产出）。
class SyncTodoAttribution {
  const SyncTodoAttribution({required this.kind, required this.text});

  final SyncTodoAttributionKind kind;
  final String text;
}

/// 归因分级：能在已加载的 turns 里查到标题就显示标题，查不到才退化为短 id。
///
/// ## 为什么不退化成「最近一轮」
///
/// `turn_id` 来自扫描时的观察，本来就可能是空——空表示「这批文件不归属任何
/// 一轮」。编一个标题等于说谎；短 id 至少是真实、可对照的线索（与 webapp
/// `describeTurnAttribution` 同一取向）。
///
/// 返回 null 表示不显示这一行（没有归因）。
SyncTodoAttribution? describeSyncTodoAttribution(
  String turnId,
  Map<String, String> turnLabels, {
  int maxIdLength = 8,
}) {
  final trimmed = turnId.trim();
  if (trimmed.isEmpty) return null;
  final title = turnLabels[trimmed]?.trim() ?? '';
  if (title.isNotEmpty) {
    return SyncTodoAttribution(
      kind: SyncTodoAttributionKind.title,
      text: title,
    );
  }
  final text = trimmed.length > maxIdLength
      ? '${trimmed.substring(0, maxIdLength)}…'
      : trimmed;
  return SyncTodoAttribution(kind: SyncTodoAttributionKind.id, text: text);
}
