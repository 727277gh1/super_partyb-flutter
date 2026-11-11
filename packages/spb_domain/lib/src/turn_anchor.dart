/// 「跳到某一轮（turn）」的锚点契约（纯逻辑，无 IO、无 Flutter）。
///
/// ## 为什么要单独一层
///
/// 对齐 webapp / 小程序 2026-11 的 `?turn=` 深链（`super_partyb/apps/webapp/src/lib/
/// miniapp/turn-anchor.ts`）：客户端要回答同一组问题——URL 里那个 turn 是哪个、
/// 它在时间线上排第几、该落到哪一行。答案错一边的表现都是「点了没反应 / 跳错轮」，
/// 而这**最难查**（没有异常、没有日志、界面还活着）。抽成纯函数后，这些判据在
/// 无 Flutter 引擎的环境里逐条钉住。
///
/// 落位原语（Web 端 `Virtuoso.scrollToIndex`、小程序 `scrollIntoView`、本端
/// 「搬 `CustomScrollView.center`」）是平台差异，**刻意不放进本文件**。
///
/// ## 作用域约定（v1）
///
/// **只在调用方已加载的轮次内定位**。目标轮不在已加载区间时返回 -1 / null，
/// 由调用方给出可见提示，不做补页。为什么先不补页（与 webapp v0 同一取舍）：
/// 补页会和「首屏滚到底 + 滚到顶自动翻页 + 锚点定位」三方抢滚动位置，而
/// Flutter 侧的翻页位置保持依赖两个 Sliver 的固定分界——把它与一次外部定位
/// 混在同一帧里，出错方式是「位置莫名偏移几百像素」，比不做更难查。
///
/// ## 锚点键必须是 turnId，不能是「第 N 轮」
///
/// `GET /chat/groups/:gid/turns` 是 `ORDER BY created_at DESC LIMIT ?` 且**无游标**，
/// 枚举不出全量轮次：序号既不稳定（每来一轮就整体后移）也不可解析（URL 里带
/// `?turn=3` 的含义随加载范围漂移）。
library;

import 'conversation_item.dart';

/// 深链查询参数名：`/chat/{groupId}?turn={turnId}`。
///
/// 与 webapp 的 `TURN_ANCHOR_PARAM` **逐字相同**：同一个链接在两端的语义一致，
/// 分享出去的 URL 不会因为「用哪个端打开」而失效。
const String kTurnAnchorParam = 'turn';

/// turnId 的合法形态。
///
/// ## 为什么不限死在「32 位 hex」
///
/// 服务端生成的是 `chatid.NewID()` = `uuid4().hex`（32 位小写 hex），但本端拿到的
/// turnId 也来自**历史数据 / 离线缓存 / 未来的生成器**。把归一化写成「32 位 hex
/// 否则 null」会把任何未预料到的形态变成**完全静默**的失效（`normalizeTurnAnchor`
/// 返回 null ⇒ 页面什么都不做 ⇒ 用户看到「点了没反应」），而这正是本仓库最反复
/// 强调要避免的失败方式。
///
/// webapp 之所以卡死 hex，是因为它要把锚点拼进 CSS 选择器
/// （`[data-turn-id="..."]`）——注入风险在那里，本端没有。故这里只做
/// 「**适合当键**」的形态校验：小写字母/数字/下划线，长度受限，不接受引号、
/// 空格、斜杠、点号等会破坏日志/URL/键比较的字符。
final RegExp _turnAnchorShape = RegExp(r'^[0-9a-z][0-9a-z_]{0,63}$');

/// 归一化外部传入的锚点值。
///
/// **非法值一律视为「没有锚点」而不是抛异常**：锚点来自 URL / 深链，任何人都能改。
///
/// 归一化动作：`trim` → 小写 → 去连字符（兼容 `8-4-4-4-12` 的 uuid 写法）→
/// 形态校验。去连字符后 `01234567-89ab-…` 与 `0123456789ab…` 归一为同一个值，
/// 不因写法差异而静默失效。
String? normalizeTurnAnchor(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim().toLowerCase().replaceAll('-', '');
  if (trimmed.isEmpty) return null;
  if (!_turnAnchorShape.hasMatch(trimmed)) return null;
  return trimmed;
}

/// 该轮第一项在 [items] 里的下标；不在已加载区间返回 -1。
///
/// [items] 按时间正序（与 `ChatStreamController.snapshot` 一致），故「首次出现」
/// 即该轮的第一条事件（通常是用户消息）。
int findTurnIndex(List<ConversationItem> items, String? turnId) {
  final target = normalizeTurnAnchor(turnId);
  if (target == null) return -1;
  for (var i = 0; i < items.length; i++) {
    if (normalizeTurnAnchor(items[i].turnId) == target) return i;
  }
  return -1;
}

/// 该轮**首个可定位的行主键**（= [ConversationItem.id]）；不可定位时返回 null。
///
/// ## 为什么返回「某一项的 id」而不是轮次对象
///
/// 本端时间线是**行级** Sliver，没有 turn 级容器：落位原语需要的是一个能算出
/// 几何的行。而 `RowLocateRegistry` 的别名表让「批量卡内的任一成员 id」都能定位
/// 到它所在的那一行，故取该轮任意一条带 id 的项都能落到位。
///
/// ## 为什么要跳过空 id 与「发送中」的本地回显
///
/// - 空 id 的行没有稳定键，拿它定位等于静默失败；
/// - `pending` 的本地回显（issue #52）随后会被服务端的权威 `user_message` 原位
///   替换，行键可能更换。只在**已确认**的项上定位，落点才是最终的。
///   先记住候选，全部都不合格时才退回候选。
String? turnAnchorItemId(List<ConversationItem> items, String? turnId) {
  final target = normalizeTurnAnchor(turnId);
  if (target == null) return null;
  String? fallback;
  for (final item in items) {
    if (normalizeTurnAnchor(item.turnId) != target) continue;
    if (item.id.isEmpty) continue;
    final pending = item is UserMessageItem && item.pending;
    if (!pending) return item.id;
    fallback ??= item.id;
  }
  return fallback;
}

/// 目标轮是否就是**最后一轮**。
///
/// ## 为什么这条要单独判（而不是「落位后看位置」）
///
/// 两端同一取舍：定位到最后一轮 ≡「跟随最新」。若仍进锚点态（钉住滚动 + 高亮），
/// 用户跳回最新之后还得手动滚到底才能继续看新消息——而「跟随最新」正是他想要的。
///
/// 空 `turnId` 的项（无归属的确认卡等）**不参与判定**：它们既不属于任何轮次，
/// 也不代表「后面还有别的轮次」。把它们算成「不是最后一轮」会让每一次「跳到最新」
/// 都意外进入锚点态。
bool isLatestTurn(List<ConversationItem> items, String? turnId) {
  final start = findTurnIndex(items, turnId);
  if (start < 0) return false;
  final target = normalizeTurnAnchor(turnId);
  for (var i = start; i < items.length; i++) {
    final itemTurn = normalizeTurnAnchor(items[i].turnId);
    if (itemTurn == null) continue; // 无归属项：不参与判定
    if (itemTurn != target) return false;
  }
  return true;
}

/// 锚点定位的结果（调用方据此提示 / 清理地址栏 / 统计）。
enum TurnAnchorOutcome {
  /// 已定位到目标轮，并进入锚点态（关掉自动跟随、高亮该轮）。
  jumped,

  /// 目标轮不在已加载区间：**没有**移动视口，调用方应给出可见提示。
  ///
  /// 不写「已处理」标记同理：用户向上翻页把目标轮载入后应该自动补跳。
  missing,

  /// 目标轮就是最后一轮：按「跟随最新」处理（不高亮、继续跟随新事件）。
  followingLatest,
}
