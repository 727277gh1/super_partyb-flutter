/// 交付物**回传**（本地改动 → agent）的纯逻辑与抽象。
///
/// ## 与 `deliverable_sync.dart`（下行同步）的分工
///
/// | 文件 | 方向 | 内容 |
/// |---|---|---|
/// | `deliverable_sync.dart` | UFS → 本地 | 计划/执行/过滤，`FileSink`/`FileDownloader` |
/// | 本文件 | 本地 → UFS | 脏检测、etag 预检、`LocalFileReader` |
///
/// 两者共用同一份状态（`SyncState`）与同一套过滤规则（`SyncFilterConfig`），
/// 但方向相反，故分文件而不混在一起——混在一起会让「哪条路径会写远端」变得
/// 需要通读全文才能判断。
///
/// ## 为什么同步本身仍是单向的
///
/// 自动同步（`SyncEngine`）**不会**上传本地改动，本文件提供的是一条**显式**的
/// 回传通道：用户在同步页逐文件确认后才上传。设计理由见
/// `docs/deliverable-upload-and-conflict.md` §4.1（反向自动同步会造成
/// `agent.file.*` 归因错乱与 IM 推送额度消耗）。
///
/// 本文件是**纯 Dart**：只定义接口与纯函数，任何 `dart:io` 访问都由上层注入
/// 实现（`tools/check_layering.sh` 会强制这一点）。
library;

import 'package:spb_models/spb_models.dart';

import 'deliverable_sync.dart';
import 'sync_path.dart';
import 'sync_prune.dart';
import 'sync_state.dart';

/// 读取本地文件内容（回传链路用）。
///
/// ## 为什么与 `FileSink` 分开而不是给它加一个 `read`
///
/// `FileSink` 是**同步引擎**的落盘契约，它刻意只有 `write`/`delete`/`exists`
/// ——引擎只需要「写下去、删掉、问在不在」。回传链路需要的是「把本地内容读出
/// 来」，是另一条路径上的另一种能力。合成一个接口会让只想注入落盘桩的测试
/// 被迫实现读取（或反之），也让「谁有权限读用户目录」这件事失去边界。
///
/// ## 实现必须保证
///
/// - **路径穿越防御**：`relPath` 来自状态表（相对路径形态），但实现仍须独立
///   校验并解析符号链接后确认落在同步目录内——与 `LocalFileSink` 同一套
///   `resolveWithinRoot` 语义。这是纵深防御：第一层（domain 的路径校验）只
///   看字符串形态，看不见软链。
/// - **不存在的文件抛错**，不要返回空列表：空列表会被上层当成「一个 0 字节
///   的文件」，进而算出与记录不同的 hash → 误判为「用户改动过」并触发一次
///   覆盖上传（把远端文件写成空文件）。
abstract interface class LocalFileReader {
  /// 读取 [relPath]（相对同步目录）的全部字节。
  ///
  /// 路径非法、文件不存在或读取失败时抛错。
  Future<List<int>> readBytes(String relPath);
}

// ===========================================================================
// 回传目标解析
// ===========================================================================

/// 一次回传的目标：落到**哪个 group**、**组内相对路径**是什么。
class UploadTarget {
  const UploadTarget({required this.groupId, required this.groupRelPath});

  /// 目标 group（`workspace/groups/{gid}/` 里的那一段）。
  final String groupId;

  /// **组内**相对路径（已剥掉 workspace 布局的 `{gid}/` 前缀）。
  ///
  /// 服务端 `ufs-upload` 自己拼 `workspace/groups/{groupId}/`，故这里必须是
  /// 组内路径；若带着 `{gid}/` 前缀上传，文件会落到
  /// `workspace/groups/{gid}/{gid}/...` 下——不报错，只是位置不对，且下轮
  /// 同步会在两个位置各出现一份。
  final String groupRelPath;

  @override
  bool operator ==(Object other) =>
      other is UploadTarget &&
      other.groupId == groupId &&
      other.groupRelPath == groupRelPath;

  @override
  int get hashCode => Object.hash(groupId, groupRelPath);

  @override
  String toString() => 'UploadTarget($groupId, $groupRelPath)';
}

/// 由**本地相对路径 + 状态键**解析回传目标；null = 无法确定，不该进脏列表。
///
/// ## 布局由**状态键**决定，不靠猜路径形状
///
/// | 范围 | 状态键 | 本地相对路径 | groupId 来源 |
/// |---|---|---|---|
/// | 全部 / 选中若干 | [workspaceStateKey] | `{gid}/reports/a.md` | 路径**首段** |
/// | 单个 group | 该 group 的 id | `reports/a.md` | 状态键本身 |
///
/// 判据必须是状态键（它才是「这份状态属于哪个范围」的真源）。若改成「首段
/// 是不是 group_id 形状就剥」，单 group 模式里用户自己的
/// `reports/<32位hex>/a.md` 会被误剥前缀，上传到错误的路径——而 group_id 形状
/// 与普通目录名在字符串上无法区分。
///
/// ## 为什么必须剥前缀
///
/// 见 [UploadTarget.groupRelPath]。这是「同一份文件在两种布局下路径不同」的
/// 唯一转换点，故做成纯函数并单测。
UploadTarget? uploadTargetFor(String relPath, {required String stateKey}) {
  if (relPath.isEmpty) return null;

  final segments = relPath.split('/');
  // 与下载侧同一套路径校验（纵深防御：状态表里的路径当初已校验过，但这里
  // 是写**远端**的入口，宁严不宽）。
  if (segments.any((s) => !isValidPathSegment(s))) return null;

  if (stateKey == workspaceStateKey) {
    // workspace 布局：首段必须是 groupId。只有一段 → 它是目录，不是文件。
    if (!isGroupId(segments.first)) return null;
    if (segments.length < 2) return null;
    return UploadTarget(
      groupId: segments.first,
      groupRelPath: segments.skip(1).join('/'),
    );
  }

  // 单 group 布局：状态键即 group id（见 syncStateKeyFor），路径无前缀。
  if (stateKey.isEmpty) return null;
  return UploadTarget(groupId: stateKey, groupRelPath: relPath);
}

// ===========================================================================
// 脏检测
// ===========================================================================

/// 本地内容与同步记录不一致的文件（回传的候选）。
class LocalDirtyFile {
  const LocalDirtyFile({
    required this.relPath,
    required this.groupId,
    required this.localSize,
  });

  /// 本地相对路径（同步目录内的完整相对路径，**含** `{gid}/` 前缀的可能）。
  final String relPath;

  /// 该文件所属 group（由 [uploadTargetFor] 解析）。
  final String groupId;

  /// 本地当前字节数。
  ///
  /// 来自**实际读到的字节**，不是状态里的 `SyncedFile.size`——后者是下载时的
  /// 大小，用户改过之后它已经不反映现状，而服务端的体积上限要按**要上传的
  /// 字节**判（见 `docs/deliverable-upload-and-conflict.md` §2.1③）。
  final int localSize;

  @override
  bool operator ==(Object other) =>
      other is LocalDirtyFile &&
      other.relPath == relPath &&
      other.groupId == groupId &&
      other.localSize == localSize;

  @override
  int get hashCode => Object.hash(relPath, groupId, localSize);

  @override
  String toString() =>
      'LocalDirtyFile($relPath, group=$groupId, $localSize 字节)';
}

/// 读取失败的文件（多为「状态里有记录，磁盘上已没有」）。
class LocalScanFailure {
  const LocalScanFailure(this.relPath, this.reason);

  final String relPath;
  final String reason;

  @override
  String toString() => 'LocalScanFailure($relPath: $reason)';
}

/// 一次本地脏检测的结果。
class LocalDirtyScanResult {
  const LocalDirtyScanResult({
    required this.dirty,
    required this.unchanged,
    required this.undetectable,
    required this.filtered,
    required this.failed,
  });

  /// 内容确实变了、可回传的文件。
  final List<LocalDirtyFile> dirty;

  /// 内容一致的文件数。
  ///
  /// **只比内容，不看 mtime**：用户 `touch` 一下、或同步器刚写过一遍，时间戳
  /// 都会变而内容不变；拿时间戳当判据会把「什么都没改」报成一堆改动。
  final int unchanged;

  /// 记录缺 `contentHash`、**无法判定**是否被改过的文件数。
  ///
  /// 这些记录写于 `contentHash` 引入之前（升级前已同步的文件），或计算失败。
  /// 一律**不算脏**——宁可漏报也不误报：误报会让用户看到一堆自己没动过的
  /// 文件，然后可能顺手「确认回传」，把 agent 的版本覆盖掉。
  final int undetectable;

  /// 不在回传范围内的文件数（原因 → 条数，与 `SyncPlan.skipped` 同一形态）。
  final Map<SyncSkipReason, int> filtered;

  /// 读取失败的文件明细。
  final List<LocalScanFailure> failed;

  bool get isEmpty => dirty.isEmpty;

  /// 本轮检查过的状态条目总数（各分支之和，用于「状态里有 N 条」这类展示）。
  int get scanned =>
      dirty.length +
      unchanged +
      undetectable +
      failed.length +
      filtered.values.fold(0, (a, b) => a + b);

  /// 一行摘要（UI 直接可用）。
  String summarize() {
    if (scanned == 0) return '本地没有已同步的文件';
    if (dirty.isEmpty) {
      final extra = undetectable > 0 ? '，$undetectable 个无法检测' : '';
      return '没有本地改动（已比对 $unchanged 个$extra）';
    }
    final buf = StringBuffer('本地改动 ${dirty.length} 个');
    if (undetectable > 0) buf.write('，$undetectable 个无法检测');
    if (failed.isNotEmpty) buf.write('，${failed.length} 个读取失败');
    return buf.toString();
  }

  @override
  String toString() => 'LocalDirtyScanResult(${summarize()})';
}

/// 本地侧的回传准入判定；null = 可回传，非 null = 跳过及原因。
///
/// [groupRelPath] 必须是**组内**路径（已剥掉 workspace 布局的 `{gid}/` 前缀）。
/// [ttsRelPrefix] 的文档就写着它是「group 内相对前缀」，传完整 relPath 的话
/// workspace 布局下 `{gid}/reports/tts/x.mp3` 不以 `reports/tts/` 开头，机器产物
/// 永远判不中——而 TTS 语音正是最不该回传的一类。
///
/// ## 检查顺序沿用 [shouldSync]（下载侧）
///
/// 机器产物先于媒体与体积：`reports/tts/` 里的音频**本身**就是媒体，若先判
/// 媒体，原因会显示成「媒体（未开启）」而不是「机器生成产物」，用户会以为
/// 「打开媒体同步就能回传语音」，但它永远不该回传。
///
/// ## 与 [shouldSync] 的口径已经一致（两边都按 group 内路径判）
///
/// 本函数直接收组内路径；[shouldSync] 收的是落盘相对路径，但它内部会先经
/// `groupScopedRelativePath(file.path)` 剥掉 workspace 布局的 `{gid}/` 段
/// 再判。故两端对**同一份文件**得出同样的结论（曾经不一致——下载侧把 TTS
/// 语音拖到本地，回传侧却拒绝回传）。
///
/// ## 唯一的信息损失：MIME
///
/// 远端条目带服务端算出的 `mime_type`；本地文件只有路径，故媒体判定退化为
/// **按扩展名推断**（[_looksLikeMedia]）。差异出现在两端判断不一致时（服务端
/// 把无扩展名文件识别成 `image/png`，本地推断不出来）。方向是可接受的：
/// 多列出的条目用户可以不选，漏列出的会让用户觉得「我的改动没出现」。
/// 因此推断**只用于排除**明确带媒体扩展名的文件。
SyncSkipReason? shouldUploadLocalFile({
  required String groupRelPath,
  required int size,
  required SyncFilterConfig filter,
}) {
  if (groupRelPath.isEmpty) return SyncSkipReason.invalidPath;
  if (isMachineGenerated(groupRelPath)) return SyncSkipReason.machineGenerated;
  if (!filter.includeMedia && _looksLikeMedia(groupRelPath)) {
    return SyncSkipReason.mediaExcluded;
  }
  if (filter.maxFileSize > 0 && size > filter.maxFileSize) {
    return SyncSkipReason.tooLarge;
  }
  return null;
}

/// 常见媒体扩展名（图片/音频/视频）。
const Set<String> _mediaExtensions = {
  // 图片
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico', 'tif', 'tiff',
  'heic', 'heif', 'avif',
  // 音频
  'mp3', 'wav', 'ogg', 'oga', 'm4a', 'flac', 'aac', 'opus', 'weba', 'wma',
  // 视频
  'mp4', 'm4v', 'webm', 'mov', 'avi', 'mkv', 'mpeg', 'mpg', 'wmv', '3gp',
};

/// 按扩展名判断是否媒体（只看**最后一段**的扩展名，大小写不敏感）。
bool _looksLikeMedia(String relPath) {
  final slash = relPath.lastIndexOf('/');
  final name = slash < 0 ? relPath : relPath.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  // dot <= 0：无扩展名，或以 `.` 开头的隐藏文件（`.gitignore` 不是扩展名）。
  if (dot <= 0 || dot == name.length - 1) return false;
  return _mediaExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 扫描本地改动。**纯逻辑**：内容由 [reader] 提供，本函数不碰磁盘。
///
/// ## 只遍历状态表，不递归扫目录
///
/// 候选集是 `state.files.keys`（与状态条目同阶）。生产实测同步目录有 5666 个
/// 文件，递归扫描要把整个目录读一遍；而**只有同步过的文件才可能被回传**
/// （没同步过的本地文件没有基准，无法知道它是不是「改动」）。
///
/// ## 每条都要读一遍内容
///
/// 判据是内容 SHA256 与记录里的 [SyncedFile.contentHash] 比对，故必须读字节
/// （不能只看 size：改一个字不改大小）。读失败（文件被手动删掉、权限不足）
/// 记入 [LocalDirtyScanResult.failed]，**不算脏**——那没有内容可上传。
///
/// ## [stateKey] 决定 groupId 的解析方式
///
/// 见 [uploadTargetFor]。传状态键而不是单独传 groupId，是为了避免「状态从键 A
/// 读出、group 却按键 B 解析」这种调用方可以犯的错。
Future<LocalDirtyScanResult> scanLocalDirtyFiles({
  required LocalFileReader reader,
  required SyncState state,
  required SyncFilterConfig filter,
  required String stateKey,
}) async {
  final dirty = <LocalDirtyFile>[];
  final failed = <LocalScanFailure>[];
  final filtered = <SyncSkipReason, int>{};
  var unchanged = 0;
  var undetectable = 0;

  void skip(SyncSkipReason reason) =>
      filtered[reason] = (filtered[reason] ?? 0) + 1;

  for (final entry in state.files.entries) {
    final relPath = entry.key;
    final record = entry.value;

    final target = uploadTargetFor(relPath, stateKey: stateKey);
    if (target == null) {
      skip(SyncSkipReason.invalidPath);
      continue;
    }

    // 先做**只看路径**的过滤（机器产物 / 媒体）：能省掉一次读盘。
    // 体积过滤需要真实字节数，只能读完再判（见下）。
    //
    // 传组内路径（target.groupRelPath）：ttsRelPrefix 是「group 内相对前缀」。
    final pathOnlyReason = shouldUploadLocalFile(
      groupRelPath: target.groupRelPath,
      // size 传 0：这一步不判体积（体积由下面读完后的那次判定负责），
      // 传 0 不会被 maxFileSize > 0 的条件命中。
      size: 0,
      filter: filter,
    );
    if (pathOnlyReason != null) {
      skip(pathOnlyReason);
      continue;
    }

    final List<int> bytes;
    try {
      bytes = await reader.readBytes(relPath);
    } catch (e) {
      failed.add(LocalScanFailure(relPath, '$e'));
      continue;
    }

    final sizeReason = shouldUploadLocalFile(
      groupRelPath: target.groupRelPath,
      size: bytes.length,
      filter: filter,
    );
    if (sizeReason != null) {
      skip(sizeReason);
      continue;
    }

    final baseline = record.contentHash;
    if (baseline == null) {
      // 无法检测：降级不误报（见 LocalDirtyScanResult.undetectable）。
      undetectable++;
      continue;
    }

    if (contentHashOf(bytes) == baseline) {
      unchanged++;
      continue;
    }

    dirty.add(
      LocalDirtyFile(
        relPath: relPath,
        groupId: target.groupId,
        localSize: bytes.length,
      ),
    );
  }

  return LocalDirtyScanResult(
    dirty: dirty,
    unchanged: unchanged,
    undetectable: undetectable,
    filtered: filtered,
    failed: failed,
  );
}

// ===========================================================================
// etag 预检
// ===========================================================================

/// 上传前的远端状态判定（三态）。
///
/// ## 为什么必须由客户端做（服务端没有这个保护）
///
/// PartyB 的 `ufs.Client` 上传**不传 `If-Match`**
/// （`super_partyb/apps/go-api/internal/ufs/client.go:339` 只写
/// `conflict_strategy`），所以 UFS 的 412 乐观锁在代理这条路上拿不到。预检因此
/// 不是「错误处理」，而是**正常流程的一个分支**：不一致就走冲突物化
/// （`docs/deliverable-upload-and-conflict.md` §2.1②）。
sealed class UploadPrecheck {
  const UploadPrecheck();
}

/// 远端记录自上次同步后没有被写过 → 直接上传是安全的。
class UploadClean extends UploadPrecheck {
  const UploadClean({required this.remoteEtag});

  /// 远端当前 etag（用于日志/展示）。
  final String? remoteEtag;

  @override
  String toString() => 'UploadClean(etag: $remoteEtag)';
}

/// 远端已被改过 → 必须走冲突分支（物化两份 + 交 agent 裁决）。
class UploadConflict extends UploadPrecheck {
  const UploadConflict({required this.remoteEtag, required this.recordedEtag});

  /// 远端**当前** etag。
  final String? remoteEtag;

  /// 上次同步时记下的 etag（本地改动的基准版本）。
  final String? recordedEtag;

  @override
  String toString() => 'UploadConflict(远端 $remoteEtag vs 记录 $recordedEtag)';
}

/// 远端已经没有这份文件了（软删除，或清单里不存在）。
///
/// 与 [UploadConflict] 分开：这里没有「agent 的新版本」可物化，也不需要
/// 下载比对，处理方式（提示用户 + 按新文件上传）与冲突完全不同。
class UploadRemoteDeleted extends UploadPrecheck {
  const UploadRemoteDeleted();

  @override
  String toString() => 'UploadRemoteDeleted()';
}

/// 用远端当前条目 + 本地同步记录判定上传前的状态。**纯函数**。
///
/// ## 判据是 etag（不是内容 hash）
///
/// 这里问的是「**远端记录**自上次同步后有没有被写过」，etag
/// （`W/"<file_id>:<updated_at_unix_nano>"`，`unified-file-service/internal/model/model.go:158`）
/// 正好回答这个问题。内容是否被本地改过是另一个问题，由
/// [scanLocalDirtyFiles] 用 `contentHash` 回答——两者**不可互换**。
///
/// ## 缺 etag 时归入 [UploadConflict]（而非「视为一致」）
///
/// 服务端 `etag` 是 `omitempty`，理论上可能缺失。此时无法证明「远端没被写过」，
/// 而把「不知道」说成「没被写过」就是在替用户做一个他不知情的覆盖决定。
/// 走冲突分支的代价有限（多一次下载 + 多一个副本），且两份内容都还在
/// （UFS overwrite 会把旧版存进 `file_versions`）。
///
/// ## [remote] 为 null 也算 [UploadRemoteDeleted]
///
/// ⚠️ **调用方必须传「该路径前缀的全量清单」**（不带 `updated_since`）：增量
/// 清单只含变化条目，未变化的远端文件会缺席，从而被误判成「远端已删」。
/// 全量清单下「条目不存在」才确实意味着该路径上没有这份文件。
UploadPrecheck precheckUpload({
  required UfsFileEntry? remote,
  required SyncedFile recorded,
}) {
  if (remote == null || remote.isDeleted) {
    return const UploadRemoteDeleted();
  }

  final remoteEtag = remote.etag;
  final recordedEtag = recorded.etag;
  if (remoteEtag != null &&
      recordedEtag != null &&
      remoteEtag == recordedEtag) {
    return UploadClean(remoteEtag: remoteEtag);
  }
  return UploadConflict(remoteEtag: remoteEtag, recordedEtag: recordedEtag);
}
