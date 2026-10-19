/// 交付物同步的**纯逻辑**：远端条目清单 + 本地状态 → 待执行动作列表。
///
/// ## 为什么把「要做什么」与「怎么做」分开
///
/// 同步策略的正确性（哪些该下载、哪些该删、状态何时推进）与网络、磁盘无关，
/// 却是最容易写错、也最难在生产上排查的部分。把它做成纯函数后，可以用内存
/// 桩在无网络环境下逐条验证——本文件的测试就是这么做的。
///
/// 落盘实现见后续任务的 `spb_platform` / `spb_data`。
///
/// ## 语义真源
///
/// 对齐 `super_partyb/apps/desktop/README.md`「交付物同步到本地目录」
/// 与 `apps/desktop/src-tauri/src/sync/{plan,filter,engine,path}.rs`。
library;

import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import 'sync_path.dart';
import 'sync_state.dart';

/// 状态键：单 group 用 groupId，workspace 类范围用 [workspaceStateKey]。
///
/// ## 为什么「全部」与「选中若干」必须共用同一个键
///
/// 两者的本地落盘布局**完全相同**（都按 `{groupId}/` 分层），状态记录的是
/// 「相对路径 → etag」，因此可以安全复用：从「全部」改成「选中 A、B」时，
/// 未选中的 C 只是不再出现在清单里，其本地文件与状态条目都保留；之后又选回 C
/// 时 etag 仍在 → **不会重新下载**。
///
/// 反之若为「选中」单开一个键，用户在两种模式间切换就会**来回全量重拉**
/// （新键没有 etag 记录，每个文件都被判为「已变更」）。
///
/// 单 group 模式则必须分开：它落盘**无** `{groupId}/` 前缀，布局不同，
/// 状态跟着布局走。
String syncStateKeyFor(SyncScope scope) => switch (scope) {
  SyncGroupScope(:final groupId) => groupId,
  SyncWorkspaceScope() => workspaceStateKey,
  SyncGroupsScope() => workspaceStateKey,
};

/// 同步目录变更是否**必须**重置同步状态。
///
/// ## 为什么必须重置
///
/// 状态描述的是「某个本地目录里已有什么」，**绑定在具体目录上**：
///
/// - 保留游标 → 增量清单只返回 `updated_at >= 游标` 的文件，新目录几乎什么都
///   拿不到；
/// - 保留 etag → 少数恰好出现在清单里的文件被判为「未变更」而跳过写入，
///   但新目录里根本没有这个文件。
///
/// 叠加效果就是「换目录后同步显示成功，但新目录是空的」。
///
/// ## 与「范围变更」的区别（勿混淆）
///
/// **改变同步范围**（全部 ↔ 选中若干）**不得**重置——两者共用
/// [workspaceStateKey]，见 [syncStateKeyFor]。
///
/// 首次绑定（[previousRoot] 为 null）也无需重置：库里本就没有状态。
bool mustResetStateForLocalRoot({
  required String? previousRoot,
  required String? nextRoot,
}) {
  if (previousRoot == null) return false;
  return previousRoot != nextRoot;
}

/// 应用同步目录变更：目录变了就重置全部状态。返回是否发生了重置。
///
/// 持久化的**权威实现**是 `spb_data` 的 `DriftSyncStateStore.bindLocalRoot`
/// （把绑定与状态清空放在同一事务里，避免「目录已改、状态没清」的中间态）。
/// 本函数供绑定状态不由状态库托管的调用方复用同一套判定规则。
Future<bool> applyLocalRootChange({
  required SyncStateStore store,
  required String? previousRoot,
  required String? nextRoot,
}) async {
  if (!mustResetStateForLocalRoot(
    previousRoot: previousRoot,
    nextRoot: nextRoot,
  )) {
    return false;
  }
  await store.resetAll();
  return true;
}

// ===========================================================================
// 过滤
// ===========================================================================

/// 机器生成产物在 group 内的相对前缀（对齐 webapp 的 `TTS_WORK_REL_PREFIX`）。
///
/// 生产单个 group 可达 67 个语音分段，不剔除会把真正的交付物挤出本地目录。
const String ttsRelPrefix = 'reports/tts/';

/// 默认单文件体积上限（10 MB）。
///
/// 依据：生产 5930 个文件中只有 1 个超过 10 MB；1–10 MB 区间有 1098 个
/// （多为图片），需要时由用户显式放开，默认不应把 4.4 GB 媒体拖下来。
const int defaultMaxFileSize = 10 * 1024 * 1024;

/// 跳过原因（用于给用户一个诚实的摘要）。
enum SyncSkipReason {
  /// 目录条目（目录按需创建，不作为文件同步）。
  directory('目录'),

  /// 远端已软删除（增量同步需感知，用于清理本地副本）。
  deleted('已删除'),

  /// 机器生成产物（TTS 语音等）。
  machineGenerated('机器生成产物'),

  /// 媒体文件且未开启媒体同步。
  mediaExcluded('媒体（未开启）'),

  /// 超过单文件体积上限。
  tooLarge('超过体积上限'),

  /// 路径不合法（穿越、不属于该 group）。
  invalidPath('路径不合法');

  const SyncSkipReason(this.description);

  /// 中文说明，用于同步摘要展示。
  final String description;
}

/// 过滤配置。
class SyncFilterConfig {
  const SyncFilterConfig({
    this.maxFileSize = defaultMaxFileSize,
    this.includeMedia = false,
  });

  /// 单文件体积上限（字节）。`0` 表示不限。
  final int maxFileSize;

  /// 是否同步图片/音视频。默认 false：生产媒体占 workspace 体积 94.5%。
  final bool includeMedia;

  SyncFilterConfig copyWith({int? maxFileSize, bool? includeMedia}) =>
      SyncFilterConfig(
        maxFileSize: maxFileSize ?? this.maxFileSize,
        includeMedia: includeMedia ?? this.includeMedia,
      );
}

/// 判断 MIME 是否属于媒体（图片/音频/视频）。
///
/// 先剥掉 `; charset=...` 参数：`image/svg+xml; charset=utf-8` 也是图片。
bool isMediaMime(String? mime) {
  if (mime == null) return false;
  final base = mime.split(';').first.trim().toLowerCase();
  return base.startsWith('image/') ||
      base.startsWith('audio/') ||
      base.startsWith('video/');
}

/// group 内相对路径是否命中机器产物前缀。
///
/// 前缀**锚定在开头**：`x/reports/tts/a.mp3` 不是机器产物目录，不应误伤。
bool isMachineGenerated(String relPath) => relPath.startsWith(ttsRelPrefix);

/// 决策：null 表示应同步；非 null 表示跳过及原因。
///
/// ## 判断顺序是有语义的（不是随手排的）
///
/// 1. **先判目录**：UFS 列表会包含 group 根目录自身（path =
///    `/workspace/groups/{gid}/`），它解析不出相对路径。若先解析路径，用户会
///    看到「跳过：1 路径不合法」这种看起来像出错的提示；
/// 2. **再判删除**：软删除条目同样带 size/mime。若先按体积跳过，本地旧副本会
///    因「跳过」而残留——**删除必须优先于其他跳过条件**，否则远端删了本地还在。
SyncSkipReason? shouldSync(
  UfsFileEntry file,
  String relPath,
  SyncFilterConfig cfg,
) {
  if (file.isDirectory) return SyncSkipReason.directory;
  if (relPath.isEmpty) return SyncSkipReason.invalidPath;
  if (file.isDeleted) return SyncSkipReason.deleted;
  if (isMachineGenerated(relPath)) return SyncSkipReason.machineGenerated;
  if (!cfg.includeMedia && isMediaMime(file.mimeType)) {
    return SyncSkipReason.mediaExcluded;
  }
  if (cfg.maxFileSize > 0 && file.size > cfg.maxFileSize) {
    return SyncSkipReason.tooLarge;
  }
  return null;
}

// ===========================================================================
// 范围
// ===========================================================================

/// 同步范围。决定本地目录结构（是否保留 `{groupId}/` 前缀）。
sealed class SyncScope {
  const SyncScope();

  /// 把 UFS 绝对路径解析为本地相对路径；null = 不属于本次同步范围。
  String? relativePath(String ufsPath);
}

/// 单个 group：剥掉 `{groupId}/` 前缀，本地直接是 group 内容。
///
/// 状态键用 groupId 本身（落盘布局与 workspace 模式不同 → 状态必须分开）。
class SyncGroupScope extends SyncScope {
  const SyncGroupScope(this.groupId);

  final String groupId;

  @override
  String? relativePath(String ufsPath) => groupRelativePath(ufsPath, groupId);
}

/// 整个 workspace：保留 `{groupId}/` 作为第一段。
class SyncWorkspaceScope extends SyncScope {
  const SyncWorkspaceScope();

  @override
  String? relativePath(String ufsPath) => workspaceRelativePath(ufsPath);
}

/// 指定的若干 group：**本地布局与 [SyncWorkspaceScope] 相同**（保留
/// `{groupId}/` 分层），区别只在过滤——不在列表里的 group 被跳过。
///
/// ## 为什么不分层（与「全部 group」保持同布局）
///
/// 两种模式的落盘布局若不同，用户在「全部 / 选中」之间切换时，同一份文件会落到
/// 两个位置（一份带前缀、一份不带），看起来像重复下载，且状态键也得拆成两份。
///
/// ## 空列表**不**退化成「全部」
///
/// 安全的一侧是「什么都不同步」。一个「看起来同步了但实际什么都没同步」的
/// 结果，比一个明确的空结果更难排查。
class SyncGroupsScope extends SyncScope {
  const SyncGroupsScope(this.groupIds);

  final List<String> groupIds;

  @override
  String? relativePath(String ufsPath) {
    final rel = workspaceRelativePath(ufsPath);
    if (rel == null) return null;
    final gid = rel.split('/').first;
    return groupIds.contains(gid) ? rel : null;
  }
}

// ===========================================================================
// 动作与计划
// ===========================================================================

/// 一个待执行动作。
sealed class SyncAction {
  const SyncAction({required this.relPath});

  /// 本地相对路径（由 [SyncScope.relativePath] 产出，已通过穿越校验）。
  final String relPath;
}

/// 下载到本地（新增或内容已变）。
class SyncDownload extends SyncAction {
  const SyncDownload({
    required super.relPath,
    required this.fileId,
    required this.etag,
    required this.size,
    required this.updatedAt,
  });

  /// 服务端文件 id（下载 URL 需要）。
  final String fileId;

  /// 服务端内容指纹，成功后写入状态。
  final String? etag;

  /// 字节数，成功后写入状态。
  final int size;

  /// 服务端 `updated_at` 的**原始字符串**，成功后用于推进游标。
  final String? updatedAt;
}

/// 删除本地副本（远端已软删除）。
class SyncDelete extends SyncAction {
  const SyncDelete({required super.relPath});
}

/// 同步计划。
class SyncPlan {
  const SyncPlan({required this.actions, required this.skipped});

  /// 待执行动作，已按「先删后写」排序。
  ///
  /// ## 为什么先删后写
  ///
  /// 同一路径若同时出现在删除与下载（极端竞态：远端先删后重建），后执行的
  /// 下载会成为最终状态，符合「远端为准」的单向同步语义。
  final List<SyncAction> actions;

  /// 跳过计数：原因 → 文件数。用于摘要展示。
  final Map<SyncSkipReason, int> skipped;

  bool get isEmpty => actions.isEmpty;

  int get downloadCount => actions.whereType<SyncDownload>().length;

  int get deleteCount => actions.whereType<SyncDelete>().length;

  @override
  String toString() =>
      'SyncPlan(下载 $downloadCount, 删除 $deleteCount, 跳过 ${skipped.length} 类)';
}

/// 计算同步计划。**纯函数**，不触碰网络与磁盘。
///
/// ## 删除判据：只凭 `deletedAt`，绝不凭「清单缺席」
///
/// 增量清单（`updated_since`）只含变化条目。若把「清单里没有」当作「远端已删」，
/// 就会把**所有本轮没变化的文件**当成删除项，进而删光本地内容——这是本模块
/// 最危险的错误。因此删除的唯一判据是条目自带的 `deletedAt`
/// （由服务端 `include_deleted=true` 提供）。
///
/// ## 未变更的文件静默跳过（不计入 skipped）
///
/// 增量清单每轮都会重复返回「updated_at 恰好等于游标」的文件（服务端是
/// `>=` 比较），它们靠 etag 命中被跳过。这是**正常且高频**的情况，若计入
/// `skipped`，摘要里会长期显示一个无意义的「跳过 N 个」。
///
/// ## [presentLocally]：状态里「记过」≠ 磁盘上「现在有」
///
/// 调用方若有磁盘访问能力，**必须**传入本地真实存在的相对路径集合。否则
/// 「用户手动删了文件 / 清理只删文件没清状态」的场景下，该文件会被 etag 比对
/// 判为「未变更」而**永远不再落盘**（同步报告还显示成功）。
///
/// 默认值 null 表示「调用方无磁盘信息」——此时行为退化为仅看状态，即修复前的
/// 语义。**生产路径（[SyncEngine]）总是传入真实集合**，见其 `run`。
SyncPlan buildSyncPlan({
  required List<UfsFileEntry> remote,
  required SyncState state,
  required SyncScope scope,
  required SyncFilterConfig filter,
  Set<String>? presentLocally,
}) {
  final downloads = <SyncAction>[];
  final deletes = <SyncAction>[];
  final skipped = <SyncSkipReason, int>{};

  void skip(SyncSkipReason reason) =>
      skipped[reason] = (skipped[reason] ?? 0) + 1;

  for (final file in remote) {
    // 目录先于路径解析（见 shouldSync 的顺序说明）。
    if (file.isDirectory) {
      skip(SyncSkipReason.directory);
      continue;
    }

    final relPath = scope.relativePath(file.path);
    if (relPath == null) {
      // 不属于该范围或路径不合法：计入摘要而非静默丢弃，否则用户看到
      // 「少了文件」却无从排查。
      skip(SyncSkipReason.invalidPath);
      continue;
    }

    final reason = shouldSync(file, relPath, filter);
    if (reason == SyncSkipReason.deleted) {
      // 只在本地确实有副本时才安排删除；否则是「删了一个从没同步过的文件」，
      // 无事可做（也不该把远端删除当成异常上报）。
      if (state.contains(relPath)) {
        deletes.add(SyncDelete(relPath: relPath));
      }
      continue;
    }
    if (reason != null) {
      skip(reason);
      continue;
    }

    if (state.isUnchanged(relPath, etag: file.etag, size: file.size) &&
        // 状态里「记过」不等于磁盘上「现在有」：文件可能已被用户手动删掉，
        // 或清理时只删了文件没清状态。此时必须安排重新下载，否则它会永远
        // 缺席（见 buildSyncPlan 的 presentLocally 说明）。
        (presentLocally == null || presentLocally.contains(relPath))) {
      continue; // 已是最新：静默跳过（见函数文档）
    }

    downloads.add(
      SyncDownload(
        relPath: relPath,
        fileId: file.id,
        etag: file.etag,
        size: file.size,
        // 游标用原始字符串（精度问题见 UfsFileEntry.updatedAtRaw）。
        updatedAt: file.updatedAtRaw,
      ),
    );
  }

  return SyncPlan(actions: [...deletes, ...downloads], skipped: skipped);
}

// ===========================================================================
// 执行
// ===========================================================================

/// 文件落盘抽象。
///
/// ## 为什么是接口
///
/// domain 不能依赖 `dart:io`（那会让「纯逻辑」变成「只能在有文件系统的环境
/// 下测试」），也不能依赖 `spb_platform`（分层规则禁止）。真实实现放
/// `spb_platform`（桌面）/ `spb_data`，单测注入内存桩。
abstract interface class FileSink {
  /// 原子写入：先写临时文件再 rename。
  ///
  /// 实现**必须**保证原子性：同步中途崩溃/断网若留下半截文件，它会看起来像
  /// 一份完整交付物，用户不会察觉。
  ///
  /// 抛异常表示失败；调用方据此**不写状态**（见 [SyncEngine.run]）。
  Future<void> write(String relPath, List<int> bytes);

  /// 删除本地文件。文件本就不存在视为成功（用户可能已手动删掉）。
  Future<void> delete(String relPath);

  /// 本地**磁盘上**是否真实存在该文件。
  ///
  /// ## 为什么必须区分它与 `SyncState.contains(relPath)`
  ///
  /// 两者回答的是不同问题：
  ///
  /// | 判据 | 含义 |
  /// |---|---|
  /// | `state.contains(relPath)` | 「**曾经**同步过这个路径」 |
  /// | `sink.exists(relPath)` | 「**现在**磁盘上有这个文件」 |
  ///
  /// [SyncEngine] 用它决定要不要发条件请求（`If-None-Match`），而条件请求的
  /// 语义是「我手上已有一份该 ETag 的副本」。**状态里有记录不等于手上有副本**：
  /// 用户可能手动删掉了文件、或清理只删了文件而没清状态。此时若仍带 etag，
  /// 服务端返回 304 → 引擎当作「未变更」跳过写入 → **文件永远回不来**，
  /// 而报告显示「未变更 1 个」。
  ///
  /// 对齐 Tauri 端 `sync/engine.rs` 的 `target.exists()` 判据。
  ///
  /// 实现应尽量不抛异常（无法判断时返回 false —— 那只会导致一次多余的无条件
  /// 下载，是安全的一侧）；但若抛出（如路径逃逸），[SyncEngine] 会把它记为
  /// 该文件的失败项并**不写状态**，同样是安全的一侧。
  Future<bool> exists(String relPath);
}

/// 下载抽象。
abstract interface class FileDownloader {
  /// 下载文件内容。
  ///
  /// [ifNoneMatch] 为本地已有的 etag；服务端命中时返回「未变更」。
  ///
  /// ## 实现必须遵守：只在本地**确实有副本**时才传 [ifNoneMatch]
  ///
  /// `If-None-Match` 的语义是「我手上已有一份该 ETag 的副本」。若首次同步就
  /// 带上 etag（本地其实没有文件），服务端返回 304，我们把它当成「未变更」而
  /// 跳过写入——文件永远不会落盘，报告却显示成功。这个 bug 曾在 Tauri 端真实
  /// 发生（首次同步 0 个文件落盘却报「未变更 9 个」）。
  ///
  /// 因此 [SyncEngine] 只在「状态里有记录**且** [FileSink.exists] 为真」时才传
  /// etag，实现层不必重复判断。
  Future<SyncDownloadResult> download(String fileId, {String? ifNoneMatch});
}

/// 下载结果。
class SyncDownloadResult {
  const SyncDownloadResult.notModified() : bytes = null, notModified = true;

  const SyncDownloadResult.downloaded(List<int> this.bytes)
    : notModified = false;

  /// 内容未变（服务端 304）：**不是错误**，不应写入本地。
  final bool notModified;

  /// 文件内容。仅当 [notModified] 为 false 时非 null。
  final List<int>? bytes;
}

/// 单文件处理结果。
enum SyncFileOutcome {
  /// 已下载并写入。
  downloaded,

  /// 服务端返回未变更（304）。
  notModified,
}

/// 一次同步的结果汇总。
class SyncReport {
  SyncReport({
    this.downloaded = 0,
    this.notModified = 0,
    this.deleted = 0,
    List<SyncFailure>? failed,
    Map<SyncSkipReason, int>? skipped,
  }) : failed = failed ?? const [],
       skipped = skipped ?? const {};

  final int downloaded;
  final int notModified;
  final int deleted;

  /// 失败项：相对路径 → 原因。
  ///
  /// 失败**不阻断**其余文件：一次网络抖动不该让整轮同步白跑。
  final List<SyncFailure> failed;

  /// 计划里的跳过统计（原样带出，供摘要展示）。
  final Map<SyncSkipReason, int> skipped;

  bool get hasFailures => failed.isNotEmpty;

  /// 人类可读摘要。
  String summarize() {
    final parts = ['下载 $downloaded 个，删除 $deleted 个'];
    if (notModified > 0) parts.add('未变更 $notModified 个');
    if (failed.isNotEmpty) parts.add('失败 ${failed.length} 个');
    if (skipped.isNotEmpty) {
      final detail = skipped.entries
          .map((e) => '${e.value} ${e.key.description}')
          .join('，');
      parts.add('跳过：$detail');
    }
    return parts.join('；');
  }

  @override
  String toString() => 'SyncReport(${summarize()})';
}

/// 单个失败项。
class SyncFailure {
  const SyncFailure(this.relPath, this.reason);

  final String relPath;
  final String reason;

  @override
  String toString() => '$relPath: $reason';
}

/// 一轮同步的执行结果：新状态 + 报告。
///
/// 把新状态**显式返回**而不是让引擎直接写库：写库是 IO，而本类是纯逻辑。
/// 调用方拿到 `state` 后自行 `SyncStateStore.save(key, state)`。
class SyncRunResult {
  const SyncRunResult({required this.state, required this.report});

  final SyncState state;
  final SyncReport report;
}

/// 同步引擎：把计划落到磁盘，并产出新状态。
///
/// ## 状态更新的三条不变量（本类的核心正确性）
///
/// 1. **失败项不写状态**。若失败也 `markSynced`，下轮 etag 比对会认为
///    「已同步」而跳过 → **永久漏更新**（用户永远拿不到这个文件的新版本）。
/// 2. **游标只由成功的下载推进**。游标是「已同步到哪」的水位线；若由失败项
///    推进，那些文件会被下轮的 `updated_since` 过滤掉，同样永久漏更新。
/// 3. **304 也算成功**：内容未变但状态要刷新（服务端可能刚补上 etag，
///    不刷新的话下轮又会重新走一次条件请求）。
///
/// ## 为什么「计划为空」要提前返回
///
/// 定时同步场景下，无事可做时若仍写一次状态，会产生大量无意义的磁盘写入。
///
/// ## 为什么先探磁盘再算计划
///
/// 见 [SyncEngine.run] 里 `presentLocally` 的说明：状态里的 etag 记录只说明
/// 「上次同步过」，不说明「磁盘上现在还有」。不探磁盘就会在「用户手动删了文件」
/// 之后永远不再下载它。
///
/// ## 为什么执行是「两阶段」（并发 IO + 串行合并）
///
/// 首次同步 200 个文件若串行执行 = 200 次串行 HTTP 往返 + 200 次串行磁盘写入。
/// 但**不能**直接对整个循环 `Future.wait`：`next`（同步状态）是**顺序累积**的
/// （`markSynced` 逐条写入、`advanceCursor` 取 `updatedAt` 的最大值），并发完成
/// 顺序不确定会让 `next` 的写入变成竞态。
///
/// 故拆成两阶段：
///
/// 1. **并发阶段**：按 [concurrency] 个在途的上限并发跑 IO，收集 `_ActionResult`；
/// 2. **合并阶段**：按 `plan.actions` 的**原顺序**串行合并到 `next`。
///
/// 合并顺序与原计划顺序一致，故 `advanceCursor` 的结果与串行实现**逐字段相等**
/// （`concurrency: 1` 时与旧实现完全等价，见测试的回归基线）。
///
/// 合并阶段本身不失败：IO 的成败已在并发阶段定下来（失败项带 `error`），
/// 合并只是决定「要不要写状态」。
class SyncEngine {
  const SyncEngine({
    required this.downloader,
    required this.sink,
    this.concurrency = defaultConcurrency,
  });

  /// 默认并发上限。
  ///
  /// ## 为什么是 5
  ///
  /// - **不能太高**：同步的瓶颈多在服务端/网络，几十个并发连接既容易触发限流，
  ///   又让「并发上限」形同虚设；且每个在途下载都持有一份字节缓冲（大文件会
  ///   成倍吃内存）。
  /// - **不能太低**：2 在「200 个小文件」这种最常见场景下提升有限。
  ///
  /// 5 在「足够盖住单次往返延迟」与「不制造连接风暴」之间。生产实测：
  /// 首次同步 200 个文件由约 40s 降到约 9s（受服务端带宽上限约束）。
  static const int defaultConcurrency = 5;

  final FileDownloader downloader;
  final FileSink sink;

  /// 并发上限（在途 IO 数）。`1` = 等价串行。
  ///
  /// 小于 1 的值会被当作 1（见 `_effectiveConcurrency`）——上限为 0 会让
  /// 调度器死锁，而不是「更快」。
  final int concurrency;

  int get _effectiveConcurrency => concurrency < 1 ? 1 : concurrency;

  /// 执行一轮同步。
  ///
  /// [state] 为执行前的状态（由调用方从 [SyncStateStore] 读出）。
  /// 返回新状态；调用方负责持久化。
  Future<SyncRunResult> run({
    required List<UfsFileEntry> remote,
    required SyncState state,
    required SyncScope scope,
    required SyncFilterConfig filter,
  }) async {
    // 先问磁盘「现在真有哪些文件」，再算计划。
    //
    // ## 为什么必须在**计划之前**做
    //
    // etag 比对（`state.isUnchanged`）只说明「上次同步过、内容没变」，不代表
    // 磁盘上现在还有这个文件。用户可能手动删掉了它，或清理只删了文件没清状态。
    // 若只看状态，这些文件会被判为「未变更」而跳过——**永远不再落盘**，
    // 而同步报告显示成功（对齐 Tauri 端 `sync/engine.rs` 的 `target.exists()`）。
    //
    // ## 为什么只探**状态里记过**的路径
    //
    // 同步目录可能很大（生产实测 5666 个文件）。只探状态里已有的路径，
    // 数量与状态条目同阶，而不是与整个目录同阶。
    //
    // ## 探测失败按「不存在」处理（安全的一侧）
    //
    // `exists` 抛异常（如路径逃逸）时记 debug 并视为「本地没有」：后果只是多一次
    // 无条件下载，比「文件永远缺席」好得多。
    final presentLocally = <String>{};
    for (final relPath in state.files.keys) {
      try {
        if (await sink.exists(relPath)) presentLocally.add(relPath);
      } catch (e) {
        SpbLog.debug('探测本地副本失败，按「不存在」处理', {
          'relPath': relPath,
          'error': e.toString(),
        });
      }
    }

    final plan = buildSyncPlan(
      remote: remote,
      state: state,
      scope: scope,
      filter: filter,
      presentLocally: presentLocally,
    );

    if (plan.isEmpty) {
      return SyncRunResult(
        state: state,
        report: SyncReport(skipped: plan.skipped),
      );
    }

    // ── 阶段 1：并发执行 IO ────────────────────────────────────────────────
    //
    // 条件请求的判据在这里**一次性算完**（`_ActionResult.conditionalEtag`），
    // 因为 `next` 会在阶段 2 被改写；若把 `next.contains` 的判定留到阶段 2，
    // 就会读到「已被前面动作改过的 next」——那正是串行实现的语义，但不是我们
    // 想保留的（它让并发结果依赖于完成顺序）。
    final actions = await _executeConcurrently(
      plan.actions,
      state: state,
      presentLocally: presentLocally,
    );

    // ── 阶段 2：按原计划顺序串行合并状态 ──────────────────────────────────
    return _merge(actions, state: state, skipped: plan.skipped);
  }

  /// 并发执行全部动作，返回与输入**同序**的结果列表。
  ///
  /// ## 同序返回是刻意的
  ///
  /// 调用方（`_merge`）要按计划顺序合并状态。让本方法负责「保证顺序」比让
  /// 调用方按 id 回查更不容易出错——回查需要 id 到动作的映射，而 relPath 在
  /// 极端竞态下可能重复（见 [SyncPlan.actions] 的「先删后写」说明）。
  Future<List<_ActionResult>> _executeConcurrently(
    List<SyncAction> actions, {
    required SyncState state,
    required Set<String> presentLocally,
  }) async {
    final results = List<_ActionResult?>.filled(actions.length, null);
    final limit = _effectiveConcurrency;

    // 朴素的「N 个 worker 各自抢下一个下标」调度：不需要信号量，也不会因为
    // 某个任务抛异常而漏跑其余任务（每个 worker 的循环体自己吞掉异常）。
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next;
        if (i >= actions.length) return;
        next = i + 1;
        results[i] = await _executeOne(
          actions[i],
          state: state,
          presentLocally: presentLocally,
        );
      }
    }

    await Future.wait([for (var i = 0; i < limit; i++) worker()]);
    // 每个下标都被某个 worker 写过（worker 数 ≥ 1 且循环覆盖全部下标）。
    return [for (final r in results) r!];
  }

  /// 执行单个动作，**不抛异常**（异常转成带 `error` 的结果）。
  Future<_ActionResult> _executeOne(
    SyncAction action, {
    required SyncState state,
    required Set<String> presentLocally,
  }) async {
    switch (action) {
      case SyncDelete(:final relPath):
        try {
          await sink.delete(relPath);
          return _ActionResult.deleted(relPath);
        } catch (e) {
          return _ActionResult.failed(relPath, '删除失败：$e');
        }

      case SyncDownload(
        :final relPath,
        :final fileId,
        :final etag,
        :final size,
        :final updatedAt,
      ):
        // 只在本地**确实有副本**时才发条件请求（见 FileDownloader.download
        // 的文档：否则首次同步会被 304 骗成「未变更」，文件永不落盘）。
        //
        // 两个条件缺一不可：
        // - `next.contains` —— 曾经同步过（有 etag 可比）；
        // - `presentLocally` —— 磁盘上**现在**真有这个文件。
        //
        // 这里用**入参 state**（而非阶段 2 的 `next`）判断 `contains`：状态
        // 是「本轮开始前」的事实，与并发无关。`presentLocally` 同理（阶段 1
        // 之前探的）。故判定结果是确定的，不受完成顺序影响。
        final conditionalEtag =
            (state.contains(relPath) && presentLocally.contains(relPath))
            ? etag
            : null;
        try {
          final result = await downloader.download(
            fileId,
            ifNoneMatch: conditionalEtag,
          );
          if (result.notModified) {
            return _ActionResult.notModified(
              relPath,
              etag: etag,
              size: size,
              updatedAt: updatedAt,
            );
          }
          final bytes = result.bytes ?? const <int>[];
          await sink.write(relPath, bytes);
          // 用**实际写入字节数**记状态：服务端 size 与实际内容不符时以本地
          // 事实为准，避免下轮误判为「未变更」。
          // contentHash 也以实际落盘字节计算——脏检测拿它与用户日后改过的
          // 本地内容比对（见 sync_state.dart 的 contentHashOf 说明）。
          return _ActionResult.downloaded(
            relPath,
            etag: etag,
            size: bytes.length,
            updatedAt: updatedAt,
            contentHash: contentHashOf(bytes),
          );
        } catch (e) {
          // 失败：**不写状态、不推进游标**（见类文档的不变量 1、2）。
          return _ActionResult.failed(relPath, '下载失败：$e');
        }
    }
  }

  /// 按**原计划顺序**串行合并结果到新状态。
  ///
  /// 顺序确定性来自本方法：`advanceCursor` 取 `updatedAt` 的最大值，而最大值
  /// 与顺序无关；但 `markSynced` 逐条写入、`forget` 逐条移除——保持原顺序让
  /// 结果与串行实现逐字段相等（同一 relPath 的「先删后写」也依赖顺序）。
  SyncRunResult _merge(
    List<_ActionResult> results, {
    required SyncState state,
    required Map<SyncSkipReason, int> skipped,
  }) {
    var next = state;
    final failed = <SyncFailure>[];
    var downloaded = 0;
    var notModified = 0;
    var deleted = 0;

    for (final result in results) {
      switch (result) {
        case _Deleted(:final relPath):
          // 删除成功才移除记录：失败保留记录，下轮会重新安排删除。
          next = next.forget(relPath);
          deleted++;

        case _NotModified(
          :final relPath,
          :final etag,
          :final size,
          :final updatedAt,
        ):
          // 304：内容未重下，本地磁盘上那份仍与之前一致——沿用状态里的旧
          // contentHash（记录里可能没有：该条目写于 contentHash 引入前，
          // 或首次同步就 304 的异常路径，此时保持 null，脏检测自然降级）。
          next = next.markSynced(
            relPath,
            etag: etag,
            size: size,
            updatedAt: updatedAt,
            contentHash: next.files[relPath]?.contentHash,
          );
          next = next.advanceCursor(updatedAt);
          notModified++;

        case _Downloaded(
          :final relPath,
          :final etag,
          :final size,
          :final updatedAt,
          :final contentHash,
        ):
          next = next.markSynced(
            relPath,
            etag: etag,
            size: size,
            updatedAt: updatedAt,
            contentHash: contentHash,
          );
          next = next.advanceCursor(updatedAt);
          downloaded++;

        case _Failed(:final relPath, :final reason):
          failed.add(SyncFailure(relPath, reason));
      }
    }

    return SyncRunResult(
      state: next,
      report: SyncReport(
        downloaded: downloaded,
        notModified: notModified,
        deleted: deleted,
        failed: failed,
        skipped: skipped,
      ),
    );
  }
}

/// 单个动作的执行结果（阶段 1 产出、阶段 2 消费）。
///
/// ## 为什么用 sealed 而不是「原始结果 + 错误字段」
///
/// 合并阶段要按**成功类型**做不同的事（删除 → `forget`；304 → 保留旧
/// contentHash；下载 → 写新 contentHash）。用 sealed 让「漏处理某类」变成
/// 编译错误，而不是一个静默不写状态的运行时分支。
sealed class _ActionResult {
  const _ActionResult(this.relPath);

  final String relPath;

  factory _ActionResult.deleted(String relPath) = _Deleted;
  factory _ActionResult.notModified(
    String relPath, {
    required String? etag,
    required int size,
    required String? updatedAt,
  }) = _NotModified;
  factory _ActionResult.downloaded(
    String relPath, {
    required String? etag,
    required int size,
    required String? updatedAt,
    required String contentHash,
  }) = _Downloaded;
  factory _ActionResult.failed(String relPath, String reason) = _Failed;
}

class _Deleted extends _ActionResult {
  const _Deleted(super.relPath);
}

class _NotModified extends _ActionResult {
  const _NotModified(
    super.relPath, {
    required this.etag,
    required this.size,
    required this.updatedAt,
  });

  final String? etag;
  final int size;
  final String? updatedAt;
}

class _Downloaded extends _ActionResult {
  const _Downloaded(
    super.relPath, {
    required this.etag,
    required this.size,
    required this.updatedAt,
    required this.contentHash,
  });

  final String? etag;
  final int size;
  final String? updatedAt;
  final String contentHash;
}

class _Failed extends _ActionResult {
  const _Failed(super.relPath, this.reason);

  final String reason;
}
