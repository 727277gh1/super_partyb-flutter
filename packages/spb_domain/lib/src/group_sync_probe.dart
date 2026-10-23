/// 「进入对话时判定是否需要同步」的纯逻辑。
///
/// ## 为什么需要它
///
/// 同步此前只有两种触发方式：手动（托盘 / 同步页）与周期定时（§6.42）。
/// 两者都缺一个东西——**用户的注意力落点**：
///
/// - 手动：用户得记得去点别处；
/// - 定时：只覆盖「人不在 app 里、但目录要被外部工具读」的那一段。
///
/// 而最常见的场景恰恰是「我正在看这个对话，它的交付物应该已经在本地了」。
/// 本文件把「这个 group 有没有未同步的内容」抽成一个可无头单测的判据。
///
/// ## 判定命中后同步的是**这个 group**（不是全范围）
///
/// 定向同步是安全的——前提是**不推进共享游标**（`SyncSingleGroupScope.
/// advancesCursor` 为 false，见 `deliverable_sync.dart`）。故判据必须建在
/// 「本 group 已同步到哪个时间点」上，而不是建在 workspace 游标上（那个
/// 游标跨 group 共享，定向同步时不会动）。
library;

import 'sync_state.dart';

/// 进入某个 group 时的同步判定结果。
enum GroupSyncNeed {
  /// 本地已覆盖该 group 的最新内容，无事可做。
  upToDate,

  /// 该 group 有本地还没有（或本地版本更旧）的文件。
  stale,

  /// 无法判定（未配置同步目录 / 该 group 根本没有交付物）。
  ///
  /// ## 为什么「没有交付物」也算不可判定而不是 [upToDate]
  ///
  /// 两者的**用户可见后果相同**（不提示、不同步），但语义不同：
  /// [upToDate] 表示「比对过了，本地是最新的」，而这里根本没东西可比。
  /// 分开是为了让调用方在需要时能区分（例如将来做「本对话没有交付物」的
  /// 空态提示），而不是为了当前行为。
  unknown,
}

/// 某个 group 在本地状态里的「已同步水位」。
///
/// ## 为什么不用共享游标
///
/// workspace 类范围（全部 / 勾选若干）共用 [workspaceStateKey] 下的**单个**
/// 游标。而定向同步（只拉一个 group）**不得**推进那个游标——否则它会越过
/// 其它 group 里从未同步过的文件，它们此后再也不出现在增量清单里
/// （`updated_since` 过滤掉，**永久漏下载而报告显示成功**）。
///
/// 游标不动，则「游标 vs 远端最晚时间」这种判据在定向同步后会**永远命中**
/// （远端最晚时间总大于没动过的游标），于是每次进对话都提示一遍。故判据必须
/// 换成「本 group 已同步记录里最晚的 `updated_at`」——它与同步进度同步前进，
/// 两种同步方式都适用。
class GroupSyncWatermark {
  const GroupSyncWatermark({this.latestUpdatedAt, this.fileCount = 0});

  /// 本 group 已同步记录里最晚的 `updated_at`（RFC3339）。
  ///
  /// null 有两种含义，用 [isEmpty] 区分：
  /// - [isEmpty] 为真：**没有**该 group 的任何已同步记录；
  /// - [isEmpty] 为假：有记录但都没带 `updated_at`（服务端未返回，极少见），
  ///   此时无从比较。
  final String? latestUpdatedAt;

  /// 本 group 已同步记录条数。
  final int fileCount;

  /// 是否完全没有该 group 的已同步记录。
  bool get isEmpty => fileCount == 0;

  /// 「什么都没有」：从未同步过这个 group。
  static const GroupSyncWatermark none = GroupSyncWatermark();

  @override
  String toString() =>
      'GroupSyncWatermark(latest: $latestUpdatedAt, files: $fileCount)';
}

/// 从同步状态里取出某个 group 的已同步水位。
///
/// [stateKey] 必须是**读状态时用的那个键**：
///
/// | 状态键 | 本地相对路径形状 | 归属判定 |
/// |---|---|---|
/// | [workspaceStateKey] | `{gid}/reports/a.md` | 首段 == groupId |
/// | `groupId`（单 group 布局） | `reports/a.md` | 全部条目 |
///
/// ## 为什么要区分两种布局
///
/// `syncStateKeyFor` 让单 group 模式用 groupId 作状态键、且落盘**无**
/// `{gid}/` 前缀（见 `SyncGroupScope`）。若一律按「首段 == gid」判定，单 group
/// 布局下**一条都匹配不上**，水位恒为空 → 判定永远 stale。
GroupSyncWatermark groupSyncWatermark({
  required SyncState state,
  required String stateKey,
  required String groupId,
}) {
  if (stateKey.isEmpty || groupId.isEmpty) return GroupSyncWatermark.none;
  final isWorkspaceLayout = stateKey == workspaceStateKey;
  // 单 group 布局下状态键必须**就是**这个 group；否则这份状态与它无关。
  if (!isWorkspaceLayout && stateKey != groupId) return GroupSyncWatermark.none;

  var count = 0;
  String? latest;
  for (final entry in state.files.entries) {
    if (isWorkspaceLayout) {
      // `{gid}/...`：首段必须精确等于 groupId（`g1` 不能命中 `g10/x`）。
      final slash = entry.key.indexOf('/');
      if (slash <= 0) continue;
      if (entry.key.substring(0, slash) != groupId) continue;
    }
    count++;
    final at = _normalize(entry.value.updatedAt);
    if (at == null) continue;
    if (latest == null || at.compareTo(latest) > 0) latest = at;
  }
  return GroupSyncWatermark(latestUpdatedAt: latest, fileCount: count);
}

/// 探测一个 group 是否有未同步内容的判据。
///
/// ## 输入只有两个，且都来自现有接口
///
/// 1. [remoteLatestUpdatedAt]：`GET /api/files?path_prefix=…&page_size=1`
///    返回的**最晚** `updated_at`（RFC3339 字符串）；
/// 2. [local]：本 group 的已同步水位（[GroupSyncWatermark]）。
///
/// ## 为什么这个判据是可靠的
///
/// 同步引擎的语义是：**只有成功下载（或 304 未变更）才 `markSynced`**。
/// 而 `markSynced` 记录的是服务端那条记录的 `updated_at`。于是有不变式：
///
/// > 任何 `updated_at > 本 group 已同步水位` 的文件，都**不可能**是已成功同步的。
///
/// 反向不成立（水位以下的文件也可能没同步过——例如被体积/媒体过滤跳过的），
/// 但那不影响本判据的用途：它是**触发条件**而非正确性条件。漏判的代价是
/// 「这次不提示」，用户可以手动点；误判的代价只是多跑一轮（引擎会算出空计划）。
GroupSyncNeed groupSyncNeed({
  required String? remoteLatestUpdatedAt,
  required GroupSyncWatermark local,
}) {
  final remote = _normalize(remoteLatestUpdatedAt);
  if (remote == null) return GroupSyncNeed.unknown;

  // 从未同步过这个 group → 只要远端有文件就是 stale。
  //
  // ## 为什么这里不能用「首轮可能很大」为由跳过
  //
  // 那是**节流**要解决的问题（见 [GroupSyncThrottle]），不是判定要解决的问题。
  // 判定若在这里返回 upToDate，用户开了自动同步却永远等不到第一次。
  if (local.isEmpty) return GroupSyncNeed.stale;

  final mine = _normalize(local.latestUpdatedAt);
  // 有记录但都没有 `updated_at`：无从比较。
  //
  // ## 为什么是 unknown 而不是 stale
  //
  // 说 stale 会让这个 group 每轮都提示、每轮都下载不到东西（永远无法
  // 「追上」）。说 unknown 只是「不打扰」——与 [GroupSyncNeed.unknown] 的
  // 语义（无法判定）一致。
  if (mine == null) return GroupSyncNeed.unknown;

  // 字典序即时序：RFC3339 的 UTC 形式（`2026-10-21T08:00:00Z`）按字典序比较
  // 与按时刻比较等价（见 `sync_cursor.dart` 的 `unixToRfc3339` 说明）。
  //
  // 严格大于：等于水位说明那份文件本身已同步过（它可能就是抬升水位的那个）。
  return remote.compareTo(mine) > 0
      ? GroupSyncNeed.stale
      : GroupSyncNeed.upToDate;
}

/// 取一页远端条目里**最晚**的 `updated_at`；空列表返回 null。
///
/// ## 为什么在客户端取 max，而不是让服务端返回
///
/// UFS 的列表端点没有「只返回最大 updated_at」这种形态，且不改服务端
/// （见 AGENTS.md 的「Go API 一行不改」）。客户端用 `page_size=1` 拉一条
/// 就够了——因为列表**按 updated_at 倒序**（服务端默认排序），第一条即最晚。
///
/// 但本函数仍然对整页取 max 而不直接取 `first`：排序是服务端的实现细节，
/// 若将来改了排序（或某一页恰好乱序），直接取 first 会**静默给出错误结论**。
/// 取 max 对排序不敏感，代价是一次 O(n) 扫描（n ≤ page_size）。
String? latestUpdatedAtOf(Iterable<String?> rawValues) {
  String? best;
  for (final raw in rawValues) {
    final value = _normalize(raw);
    if (value == null) continue;
    if (best == null || value.compareTo(best) > 0) best = value;
  }
  return best;
}

/// 去掉首尾空白；空串视为「没有值」。
String? _normalize(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 每个 group 的「进对话触发同步」冷却闸。
///
/// ## 为什么必须有它
///
/// 判定（[groupSyncNeed]）会在**每一次**打开对话时跑。而下面两种情况会让
/// 判定**长期命中**，于是每次进对话都触发一轮同步：
///
/// 1. **被过滤掉的文件不推水位**。`SyncEngine._merge` 只在下载成功或 304 时
///    `markSynced`；媒体（默认不同步）、`reports/tts/**`、超体积文件都是
///    「跳过且不记录」。于是某个 group 里只要有一个 500 MB 的视频，它的
///    `updated_at` 就永远大于本 group 已同步水位 → 每次点进去都判 stale
///    → 每轮同步一轮却什么都不做。
/// 2. **首次同步体积很大**（生产实测 5666 条 / 4.7 GB）。用户连点两个对话
///    不该拉两遍。
///
/// 冷却期内的判定结果被**降级成 [GroupSyncNeed.upToDate]**（即「这次不触发」），
/// 而不是加一个第四种枚举值——调用方本来也只需回答「要不要现在同步」。///
/// ## 为什么是内存态而不是持久化
///
/// 它表达的是「刚刚试过」。重启后允许再试一次是**合理**的（那时用户重新
/// 表达了兴趣，且上一轮的失败原因可能已消失）。持久化反而会让「重启也治不好」
/// 的状态出现——与 §6.39 的教训同取向（不要把瞬态当持久态）。
class GroupSyncThrottle {
  /// [cooldown] 为每个 group 的冷却期；[now] 可注入以便无头测试。
  GroupSyncThrottle({
    this.cooldown = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 同一个 group 两次触发之间的最小间隔。
  ///
  /// ## 为什么默认 10 分钟
  ///
  /// 上限由「首次全量 4.7 GB」定：太短等于把周期同步变成「每次点对话都同步」。
  /// 下限由「用户来回切两个对话」定：短于几分钟就挡不住这种模式。
  /// 10 分钟既让误判的代价可忽略，又不至于让用户「改完配置回来发现没同步」。
  final Duration cooldown;

  final DateTime Function() _now;

  /// groupId → 上次触发时刻。
  final Map<String, DateTime> _lastTriggered = {};

  /// 是否允许为 [groupId] 触发同步（只查询，不记录）。
  bool allows(String groupId) {
    final last = _lastTriggered[groupId];
    if (last == null) return true;
    return _now().difference(last) >= cooldown;
  }

  /// 记录一次触发。
  ///
  /// 调用时机是「**即将**发起同步」而非「同步成功之后」：失败也进冷却。
  /// 否则一个必然失败的配置（如目录被删）会让每次进对话都重试一遍，
  /// 而失败原因不会因此变好。
  void markTriggered(String groupId) {
    _lastTriggered[groupId] = _now();
  }

  /// 清空（登出 / 换同步目录时调用：新目录下每个 group 都该重新判定）。
  void reset() => _lastTriggered.clear();
}
