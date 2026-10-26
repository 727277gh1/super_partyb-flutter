/// 同步时间下限（`updated_since`）的计算：纯函数，可无头单测。
///
/// ## 为什么需要它
///
/// 交付物同步是增量的：本轮只拉「上次同步之后变动过的」条目。这个「上次」就是
/// 游标。但除了游标之外，用户还可以配置一个**时间下限**（`since_days`）——
/// 「我不需要历史交付物，只拉最近 7 天的」。两者要合并成一个 `updated_since`。
///
/// 对齐 `super_partyb/apps/desktop/src-tauri/src/sync/runtime.rs` 的
/// `effective_cursor`：取**更晚**的那个。
///
/// ## 为什么取更晚而非更早
///
/// - 游标更晚 → 继续正常增量，不重复拉已同步的区间；
/// - 下限更晚（如用户刚把 `since_days` 设成 7，而游标是半年前的）→ 从下限
///   开始，跳过历史交付物，这正是用户设置该值想要的。
///
/// 取更早的那个会让 `since_days` **完全失效**（游标总是把区间拉回去）。
library;

/// 一天的秒数。
const int secondsPerDay = 86400;

/// Unix 秒 → RFC3339 UTC 字符串（`YYYY-MM-DDTHH:MM:SSZ`）。
///
/// ## 为什么手写格式化而不用 `DateTime.toIso8601String()`
///
/// `toIso8601String()` 在秒后带 `.000` 毫秒段（`2026-06-18T08:26:57.000Z`）。
/// UFS 的 `updated_at` 是 Go `time.Time` 序列化的结果，秒级时为
/// `2026-06-18T08:26:57Z`（无毫秒段）。游标要与服务端值做**字符串比较**
/// （`updated_since` 是 `>=` 语义，服务端按字符串比较），格式不一致会让
/// 字典序比较失效。
///
/// ## 为什么字典序即时序是前提
///
/// 本函数输出固定宽度、补零、同一 `Z` 时区，因此 `a < b`（字典序）等价于
/// `a` 早于 `b`。同步的游标单调推进（[SyncState.advanceCursor]）依赖这一点。
/// 缺零会破坏它——故有专门的用例守这个性质。
String unixToRfc3339(int secs) {
  final t = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
  String p2(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${p2(t.month)}-${p2(t.day)}'
      'T${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}Z';
}

/// 「当前时刻往前 [days] 天」的 RFC3339 时间戳。
///
/// `days = 0` 返回 `now` 本身（而非 1970），保持「下限 = 此刻」的直观语义。
/// 注意 `0` 在**语义上**表示「不限历史」（见 [effectiveCursor]），本函数只做
/// 算术，不做语义解释。
String cutoffDaysAgo(int nowUnix, int days) =>
    unixToRfc3339(nowUnix - days * secondsPerDay);

/// 当前 Unix 秒。
int nowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// 算出本轮同步的时间下限（`updated_since`）。
///
/// 返回 null 表示**不加**该参数（首次全量）。
///
/// ## 为什么首次必须全量
///
/// 游标为空时若发增量请求，服务端只会返回「近期变化」的文件，本地会漏掉
/// 全部历史交付物，而用户以为同步完成了。唯一的例外是用户显式配了
/// `since_days`——那时跳过历史是他明确要求的取舍。
///
/// ## `sinceDays` 为 0 / null 都表示不限
///
/// 对齐 Tauri 端 `cutoff` 只在 `days > 0` 时生效。把 `0` 解释成「下限 = 此刻」
/// 会让 `updated_since = now`，进而**什么都同步不到**——而 UI 上「0」与「不限」
/// 是同一个选项，两者行为必须一致。
String? effectiveCursor({String? saved, int? sinceDays, required int nowUnix}) {
  final days = sinceDays;
  final floor = (days != null && days > 0)
      ? cutoffDaysAgo(nowUnix, days)
      : null;

  final s = (saved != null && saved.trim().isNotEmpty) ? saved.trim() : null;

  if (s == null) return floor;
  if (floor == null) return s;
  // 字典序即时序（见 unixToRfc3339 说明）。
  return s.compareTo(floor) >= 0 ? s : floor;
}
