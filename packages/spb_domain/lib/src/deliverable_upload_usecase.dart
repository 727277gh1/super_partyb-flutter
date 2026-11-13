/// 交付物**回传**用例：把「脏检测 → etag 预检 → 上传/冲突物化 → 通知 agent」
/// 串起来。
///
/// ## 为什么需要它（而不是让 UI 直接调各层）
///
/// 单文件回传涉及四步，且**顺序不可换**：
///
/// 1. 读本地字节（[LocalFileReader]）→ 算内容 hash 与状态记录比对（脏检测）；
/// 2. 取远端当前 etag 与记录比对（[precheckUpload]）→ 决定走直传还是冲突分支；
/// 3. 上传（[UploadSender]），413 时改走 quick-capture 附件链兜底；
/// 4. 发一条聊天消息让 agent 知道（[UploadNotifier]）——ufs-upload 不建 turn，
///    没有消息 agent 就没有「知道」的时机。
///
/// 其中第 4 步依赖第 3 步成功（没上传成功就通知 agent「我改了」会让它读到旧
/// 内容），第 2 步依赖第 1 步（不脏就不该传）。这些约束散在 UI 里必然会写错。
///
/// ## 为什么第 2 步必须由客户端做
///
/// PartyB 的 `ufs.Client` 上传**不传 `If-Match`**
/// （`super_partyb/apps/go-api/internal/ufs/client.go:339` 只写
/// `conflict_strategy`），UFS 的 412 乐观锁在代理这条路上拿不到。所以预检不是
/// 「错误处理」而是**正常流程的一个分支**：不一致就走冲突物化。
///
/// ## 依赖全是窄接口（不是 `ChatApi` / `UfsApi`）
///
/// | 接口 | 真实实现 | 为什么不用具体类 |
/// |---|---|---|
/// | [UploadSender] | `ChatApi.uploadWorkspaceFile` | 只用到 1 个方法，注入 `ChatApi` 会牵进 dio |
/// | [QuickCaptureSender] | `ChatApi` 的附件两方法 | 同上 |
/// | [UploadNotifier] | `ChatApi.sendMessage` | 同上 |
/// | [RemoteWorkspace] | `UfsApi` 的 list/download | 同上 |
///
/// 窄接口让单测只写几十行内存桩（见 `test/deliverable_upload_usecase_test.dart`），
/// 且**编译期就能看出**用例依赖了服务端的哪些能力——新增依赖必须先改接口。
///
/// ## 关于「重试」与幂等
///
/// 每个文件在**本轮内**只尝试一次，失败记进 [UploadReport.failed] 由用户决定
/// 是否重跑。但「通知消息」的 `requestId` 在同一文件上**必须稳定**（见
/// [DeliverableUploadUseCase._notifyMessage] 的说明），否则重跑会在对话里留下
/// 重复消息。
library;

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:uuid/uuid.dart';

import 'conflict_path.dart';
import 'deliverable_sync.dart';
import 'deliverable_upload.dart';
import 'local_file_reader.dart';
import 'sync_cursor.dart';
import 'sync_memory.dart';
import 'sync_path.dart';
import 'sync_state.dart';

// ===========================================================================
// 窄接口
// ===========================================================================

/// 上传一个文件到 group workspace（唯一实现：`ChatApi.uploadWorkspaceFile`）。
///
/// ## 为什么参数与 `ChatApi` 的方法逐字对齐
///
/// 接口是**适配层**不是抽象层：多一层「语义化包装」只会让「接口上说的」与
/// 「实际发的请求」产生漂移空间。这里逐字对齐后，实现体就是一次转发。
///
/// [relativePath] 是**组内**相对路径（服务端自己拼 `workspace/groups/{gid}/`）。
abstract interface class UploadSender {
  Future<WorkspaceFileUpload> uploadWorkspaceFile({
    required String groupId,
    required String relativePath,
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  });
}

/// quick-capture 附件链（413 兜底路径）。
///
/// ## 为什么兜底走这条而不是「提示用户文件太大」
///
/// 服务端 ufs-upload 的上限默认 1 MiB（`WorkbenchFileContextMaxBytes`），而
/// quick-capture 附件链上限 50 MiB。超过 1 MiB 的交付物（图片、PDF）完全正常，
/// 直接拒绝回传会让「agent 永远不知道用户改了这个文件」。
///
/// 代价：附件落到 `_attachments/{turnID}/`，**路径与用户改的路径不同**，需要
/// agent 自己搬过去。因此 [enqueueQuickCapture] 的 input 里必须写清目标路径
/// （见 [DeliverableUploadUseCase] 的兜底分支）。
abstract interface class QuickCaptureSender {
  Future<QuickCaptureUpload> uploadQuickCaptureAttachment({
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  });

  Future<void> enqueueQuickCapture({String input, List<String> attachments});
}

/// 发聊天消息（唯一实现：`ChatApi.sendMessage`）。
///
/// 返回类型刻意是 `void`：本用例不关心 agent 怎么回答（那走 SSE），只关心
/// 「通知已发出」。若返回 [SendMessageResult]，用例就会有人忍不住去读
/// `turnId` 做后续编排——那是另一个用例的事。
///
/// ## 为什么叫 `UploadNotifier` 而不是 `Notifier`
///
/// 后者与 Riverpod 的 `Notifier`（`flutter_riverpod`）**同名**。两者都会出现在
/// app 的装配文件里（一边是 provider 基类，一边是本用例的依赖），同名会让
/// `dart analyze` 直接报 `ambiguous_import`——实测确实如此。改成本名后两边
/// 可以共存，且名字本身也更明确（它是**回传**链路的通知器）。
abstract interface class UploadNotifier {
  Future<void> sendMessage({
    required String userId,
    required String input,
    String? groupId,
    String? requestId,
  });
}

/// 远端 workspace 清单与下载（唯一实现：`UfsApi`）。
///
/// ## 为什么是「清单 + 下载」两个方法而不是一个「取某路径的条目」
///
/// UFS 没有「按路径查单个文件」的端点（只有 `path_prefix` 前缀列表）。
/// 故预检要拿**该 group 的全量清单**再本地匹配——这带来一条硬性约束：
/// 调用方**不得**传 `updatedSince`，否则未变化的远端文件会缺席，被误判成
/// 「远端已删」（见 [precheckUpload] 的文档）。
abstract interface class RemoteWorkspace {
  /// 列出 [pathPrefix] 下的全部条目（**必须拉完所有页**）。
  ///
  /// [includeDeleted] 为 true 时包含软删除条目——预检需要它来区分
  /// 「远端删了」与「远端没有过这个文件」。
  Future<List<UfsFileEntry>> listAll({
    required String pathPrefix,
    bool includeDeleted = true,
  });

  /// 下载文件字节（用于取 agent 版本物化到 `_conflict/`）。
  Future<List<int>> downloadBytes(String fileId);
}

// ===========================================================================
// 报告
// ===========================================================================

/// 单个文件的回传终态。
enum UploadOutcome {
  /// 直传成功（预检 clean）。
  uploaded('已回传'),

  /// 冲突：人类版本传到目标路径，agent 版本物化到 `_conflict/`。
  conflictMaterialized('冲突已物化'),

  /// 超过服务端上限，改走 quick-capture 附件链投递。
  fallbackQuickCapture('已改走附件通道'),

  /// 远端已删除该文件：跳过（不覆盖，也不通知）。
  skippedRemoteDeleted('远端已删除，已跳过'),

  /// 文件不在回传范围内（机器产物 / 媒体 / 超限），或无法检测（缺 hash）。
  skipped('已跳过'),

  /// 失败（读取、上传、通知任一步）。
  failed('失败');

  const UploadOutcome(this.description);

  final String description;
}

/// 单个文件的回传结果。
/// 上传成功后的新同步基线（issue #53 缺陷②）。
class UploadSyncedRecord {
  const UploadSyncedRecord({
    required this.etag,
    required this.size,
    required this.contentHash,
    this.updatedAt,
  });

  /// 上传后远端的 etag（`WorkspaceFileUpload.etag`）。旧服务端不回时为
  /// null——预检退回「缺 etag 归入冲突」的保守语义（多一次物化，不丢数据）。
  final String? etag;

  /// 上传字节数。
  final int size;

  /// 上传字节的 SHA256（脏检测基准，与下行 SyncDownloaded 同一算法）。
  final String contentHash;

  /// 服务端 `updated_at`（若有，仅展示用；游标由下行同步推进，这里不动它）。
  final String? updatedAt;
}

class UploadItemResult {
  const UploadItemResult({
    required this.relPath,
    required this.groupId,
    required this.outcome,
    this.reason,
    this.conflictPath,
    this.notified = false,
    this.syncedRecord,
  });

  /// 本地相对路径（同步目录内，可能含 `{gid}/` 前缀）。
  final String relPath;

  final String groupId;

  final UploadOutcome outcome;

  /// 失败原因或跳过说明（UI 直接展示）。
  final String? reason;

  /// 冲突副本的**组内**路径（仅 [UploadOutcome.conflictMaterialized] 非空）。
  final String? conflictPath;

  /// 上传成功后的新基线（issue #53 缺陷②）。非 null 时调用方（[run]）把它
  /// markSynced 进状态并持久化——没有它，状态里记的还是上传前的旧 etag，
  /// 第二次回传（文件未再改）会因 `remoteEtag != recordedEtag` 误判冲突，
  /// 物化假 `_conflict/` 副本 + 再发一条冲突通知。
  ///
  /// 只在「目标路径的内容已是本地这份」时非 null：直传成功、冲突物化（人类
  /// 版本上到目标路径）。413 兜底走附件链的**不是**——文件没落到目标路径。
  final UploadSyncedRecord? syncedRecord;

  /// 是否已发出通知消息。
  ///
  /// ## 为什么单独一个字段而不是「outcome == uploaded 就说明通知了」
  ///
  /// 上传成功但通知失败是**真实可达**的状态（网络抖动、429 限流）。此时文件
  /// 已经在 workspace 里，agent 只是不知道——UI 必须能把这个区别讲出来，否则
  /// 用户会以为「agent 已经知道了」而不再处理。
  final bool notified;

  bool get isSuccess =>
      outcome == UploadOutcome.uploaded ||
      outcome == UploadOutcome.conflictMaterialized ||
      outcome == UploadOutcome.fallbackQuickCapture;

  @override
  String toString() =>
      'UploadItemResult($relPath → ${outcome.name}'
      '${notified ? ', 已通知' : ''}${reason != null ? ', $reason' : ''})';
}

/// 一次回传的完整报告。
class UploadReport {
  const UploadReport({
    this.items = const [],
    this.scanned = 0,
    this.unchanged = 0,
    this.undetectable = 0,
    this.filtered = const {},
    this.scanFailures = const [],
  });

  final List<UploadItemResult> items;

  /// 脏检测的统计（原样带出，供摘要展示）。
  final int scanned;
  final int unchanged;
  final int undetectable;
  final Map<SyncSkipReason, int> filtered;
  final List<LocalScanFailure> scanFailures;

  List<UploadItemResult> byOutcome(UploadOutcome o) =>
      items.where((i) => i.outcome == o).toList();

  int count(UploadOutcome o) => byOutcome(o).length;

  bool get isEmpty => items.isEmpty;
  bool get hasFailures => count(UploadOutcome.failed) > 0;

  /// 上传成功但没能通知 agent 的条目（需要用户手动告知或重试）。
  List<UploadItemResult> get notifiedFailed =>
      items.where((i) => i.isSuccess && !i.notified).toList();

  /// 人类可读摘要。
  String summarize() {
    if (items.isEmpty) {
      if (scanned == 0) return '没有可回传的本地改动';
      final extra = undetectable > 0 ? '，$undetectable 个无法检测' : '';
      return '没有本地改动（已比对 $unchanged 个$extra）';
    }
    final parts = <String>[];
    void add(UploadOutcome o) {
      final n = count(o);
      if (n > 0) parts.add('${o.description} $n 个');
    }

    add(UploadOutcome.uploaded);
    add(UploadOutcome.conflictMaterialized);
    add(UploadOutcome.fallbackQuickCapture);
    add(UploadOutcome.skippedRemoteDeleted);
    add(UploadOutcome.failed);

    final notNotified = notifiedFailed.length;
    if (notNotified > 0) parts.add('已上传但未通知 $notNotified 个');
    return parts.join('；');
  }

  @override
  String toString() => 'UploadReport(${summarize()})';
}

// ===========================================================================
// 用例
// ===========================================================================

/// 交付物回传编排。
class DeliverableUploadUseCase {
  DeliverableUploadUseCase({
    required this.reader,
    required this.stateStore,
    required this.remote,
    required this.uploader,
    required this.quickCapture,
    required this.notifier,
    required this.userId,
    this.nowUnix = _defaultNowUnix,
    this.requestIdFor,
  });

  final LocalFileReader reader;
  final SyncStateStore stateStore;
  final RemoteWorkspace remote;
  final UploadSender uploader;
  final QuickCaptureSender quickCapture;
  final UploadNotifier notifier;

  /// 当前用户 id（`GET /api/auth/me` 拿到的那个）。
  ///
  /// 发消息的路径是 `/users/{userId}/chat/messages`，故必须由调用方提供。
  /// 本用例不去查它——那会把一次 HTTP 调用藏进一个可能被反复调用的方法里。
  final String userId;

  /// 取当前 Unix 秒（冲突副本命名用）。测试可注入固定值。
  final int Function() nowUnix;

  /// 幂等键生成器（同一 [UploadItemResult.relPath] 必须稳定，见
  /// [_notifyMessage]）。默认用 uuid v4。
  final String Function(String relPath)? requestIdFor;

  static int _defaultNowUnix() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 执行一次回传。
  ///
  /// [scope] 决定状态键与本地布局（见 [syncStateKeyFor] /
  /// [uploadTargetFor]）。
  ///
  /// [only] 非空时只回传这些**本地相对路径**（UI 让用户逐文件勾选）。
  /// 路径必须与状态表里的键完全一致——不做模糊匹配，避免「勾了 a.md 却传了
  /// a.md.bak」这种错位。
  ///
  /// [conflictTimestamp] 冲突副本命名用的时间戳（RFC3339 UTC）。测试注入
  /// 固定值；生产不传，由 [nowUnix] 推出。
  Future<UploadReport> run({
    required SyncScope scope,
    required SyncFilterConfig filter,
    Set<String>? only,
    String? conflictTimestamp,
  }) async {
    final stateKey = syncStateKeyFor(scope);
    final state = await stateStore.load(stateKey);

    final scan = await scanLocalDirtyFiles(
      reader: reader,
      state: state,
      filter: filter,
      stateKey: stateKey,
    );

    // 用户勾选的子集：不在 `only` 里的脏文件本轮不动。
    final candidates = only == null
        ? scan.dirty
        : scan.dirty.where((d) => only.contains(d.relPath)).toList();

    if (candidates.isEmpty) {
      return UploadReport(
        scanned: scan.scanned,
        unchanged: scan.unchanged,
        undetectable: scan.undetectable,
        filtered: scan.filtered,
        scanFailures: scan.failed,
      );
    }

    // 预检需要「远端当前有哪些文件」。按 group 分组拉一次清单，避免每个文件
    // 都拉一遍全量清单（生产单 group 可达数千条）。
    //
    // ⚠️ 必须传 includeDeleted: true 且**不传** updatedSince：增量清单里
    // 未变化的远端文件会缺席，从而被误判成「远端已删」。
    final groupIds = {for (final d in candidates) d.groupId};
    final remoteByGroup = <String, Map<String, UfsFileEntry>>{};
    final listFailures = <String, String>{};
    for (final gid in groupIds) {
      try {
        final entries = await remote.listAll(
          pathPrefix: '$workspaceGroupsPrefix$gid/',
          includeDeleted: true,
        );
        remoteByGroup[gid] = {
          for (final e in entries)
            if (_groupRelPathOf(e.path, gid) case final rel?) rel: e,
        };
      } catch (e) {
        // 拉清单失败：该 group 的全部候选文件都记为失败，不静默跳过。
        listFailures[gid] = '$e';
      }
    }

    final items = <UploadItemResult>[];
    // 上传成功的新基线累积到 next（初始为执行前状态）；identical 判断「本轮
    // 是否真的写过」，避免无谓落盘。
    var next = state;
    for (final dirty in candidates) {
      final target = uploadTargetFor(dirty.relPath, stateKey: stateKey);
      if (target == null) {
        // 脏检测已解析过一次；这里为 null 说明状态在两步之间被改过。
        items.add(
          UploadItemResult(
            relPath: dirty.relPath,
            groupId: dirty.groupId,
            outcome: UploadOutcome.skipped,
            reason: '路径无法解析为回传目标',
          ),
        );
        continue;
      }

      final listError = listFailures[target.groupId];
      if (listError != null) {
        items.add(
          UploadItemResult(
            relPath: dirty.relPath,
            groupId: target.groupId,
            outcome: UploadOutcome.failed,
            reason: '拉取远端清单失败：$listError',
          ),
        );
        continue;
      }

      final record = state.files[dirty.relPath];
      if (record == null) {
        items.add(
          UploadItemResult(
            relPath: dirty.relPath,
            groupId: target.groupId,
            outcome: UploadOutcome.skipped,
            reason: '状态记录已消失',
          ),
        );
        continue;
      }

      final remoteEntry = remoteByGroup[target.groupId]?[target.groupRelPath];
      final check = precheckUpload(remote: remoteEntry, recorded: record);

      final result = await _handleOne(
        dirty: dirty,
        target: target,
        check: check,
        remoteEntry: remoteEntry,
        conflictTimestamp: conflictTimestamp,
      );
      items.add(result);

      // 新基线写回（issue #53 缺陷②）：上传成功 → markSynced + 失败记录清零
      // （与下行 SyncDownloaded 同一口径）。上传失败/跳过不动状态。
      final synced = result.syncedRecord;
      if (synced != null) {
        next = next
            .markSynced(
              dirty.relPath,
              etag: synced.etag,
              size: synced.size,
              contentHash: synced.contentHash,
            )
            .clearFailure(dirty.relPath);
      }
    }

    // 每轮一次持久化（无新基线则不写，与 SyncEngine「无事不写」同一取向）。
    if (!identical(next, state)) {
      await stateStore.save(stateKey, next);
    }

    return UploadReport(
      items: items,
      scanned: scan.scanned,
      unchanged: scan.unchanged,
      undetectable: scan.undetectable,
      filtered: scan.filtered,
      scanFailures: scan.failed,
    );
  }

  /// 处理单个脏文件。
  Future<UploadItemResult> _handleOne({
    required LocalDirtyFile dirty,
    required UploadTarget target,
    required UploadPrecheck check,
    required UfsFileEntry? remoteEntry,
    String? conflictTimestamp,
  }) async {
    final filename = conflictBasename(target.groupRelPath);

    // 远端已删：不覆盖、不通知。本地这份可能是用户在远端删除后新建的，
    // 但「重建一个已删文件」应该是用户的显式决定（重新走 quick-capture 或
    // 上传），不该由回传通道替他做。
    if (check is UploadRemoteDeleted) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.skippedRemoteDeleted,
        reason: '远端已没有这个文件；如需重新上传请用「快速捕获」',
      );
    }

    // 读本地字节。脏检测阶段读过一次，但那是在算 hash；这里重新读是为了
    // 拿到**要上传的那份内容**（中间用户可能又改了——用旧字节上传会让
    // 服务端内容与本地内容不一致，下轮同步又把本地覆盖回去）。
    final List<int> localBytes;
    try {
      localBytes = await reader.readBytes(dirty.relPath);
    } catch (e) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '读取本地文件失败：$e',
      );
    }

    // 在途登记（`sync_memory.dart`）：从这一刻到上传/冲突物化结束，这份字节
    // 常驻内存。上传与脏检测不同：它**本来就必须**持有整份内容（要发出去），
    // 这里登记是为了让高水位日志的 `breakdown` 能指认它。
    SyncInFlightBytes.hold(localBytes.length);
    try {
      if (check is UploadConflict) {
        return await _materializeConflict(
          dirty: dirty,
          target: target,
          localBytes: localBytes,
          remoteEntry: remoteEntry,
          conflictTimestamp: conflictTimestamp,
        );
      }

      return await _uploadTarget(
        dirty: dirty,
        target: target,
        localBytes: localBytes,
        filename: filename,
        notifyKind: _NotifyKind.direct,
      );
    } finally {
      SyncInFlightBytes.release(localBytes.length);
    }
  }

  /// 冲突分支：人类版本 → 目标路径，agent 版本 → `_conflict/`。
  ///
  /// ## 为什么先传人类版本
  ///
  /// 工作副本 = 人类改动，这是默认裁决规则「人类优先」（设计文档 §3.3）。
  /// 顺序上先传谁不影响结果（两次独立上传），但先传人类版本能让「第二次上传
  /// 失败」时留下一个可接受的状态：目标路径已经是用户的新内容，只是缺一份
  /// agent 版本副本。
  Future<UploadItemResult> _materializeConflict({
    required LocalDirtyFile dirty,
    required UploadTarget target,
    required List<int> localBytes,
    required UfsFileEntry? remoteEntry,
    String? conflictTimestamp,
  }) async {
    final ts = conflictTimestamp ?? _rfc3339Utc(nowUnix());
    final conflictRelPath = buildConflictPath(target.groupRelPath, ts);

    // 1) 先把 agent 版本取下来（在写目标路径之前）。若这一步失败，直接记为
    //    失败并**不写**目标路径——否则会把 agent 的新版本静默丢掉（本地没有
    //    它的副本，UFS 虽然还有 file_versions，但用户不知道去哪找）。
    //
    //    `remoteEntry` 来自预检（它是 UfsFileEntry?）。为 null 只可能发生在
    //    「预检用 null 条目 + 缺 etag 的记录」这条路径上（见 precheckUpload
    //    的文档）：那时确实没有 file_id 可下载。
    final fileId = remoteEntry?.id;
    if (fileId == null || fileId.isEmpty) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '冲突处理需要远端文件 id，但清单里没有该条目',
      );
    }

    final List<int> agentBytes;
    try {
      agentBytes = await remote.downloadBytes(fileId);
    } catch (e) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '下载 agent 版本失败：$e',
      );
    }

    // 2) 人类版本 → 目标路径。
    final first = await _uploadTarget(
      dirty: dirty,
      target: target,
      localBytes: localBytes,
      filename: conflictBasename(target.groupRelPath),
      // 通知在两次上传都完成后再发（消息里要给出两个路径）。
      notifyKind: _NotifyKind.none,
    );
    if (!first.isSuccess) return first;
    // 目标路径已是本地这份内容（issue #53 缺陷②）：冲突也把新基线写回，
    // 否则第二次回传（内容未再改）会再次误判冲突，物化假副本。
    final targetRecord = first.syncedRecord;

    // 3) agent 版本 → `_conflict/<时间戳>-<原名>.conflict`。
    //
    //    `.conflict` 后缀是**必需**的：groupsync 的 include globs 含
    //    `**/*.spec.json` / `**/*.html` / `**/*.pdf` 等全目录模式，若副本保持
    //    原名（`_conflict/<ts>-foo.spec.json`）仍会命中白名单而被上传 UFS 并
    //    emit `agent.file.*`（归因错乱，且可能触发 IM 推送）。
    final conflictTarget = UploadTarget(
      groupId: target.groupId,
      groupRelPath: conflictRelPath,
    );
    final conflictDirty = LocalDirtyFile(
      relPath: dirty.relPath,
      groupId: target.groupId,
      localSize: agentBytes.length,
    );
    final second = await _uploadTarget(
      dirty: conflictDirty,
      target: conflictTarget,
      localBytes: agentBytes,
      filename: conflictBasename(conflictRelPath),
      notifyKind: _NotifyKind.none,
    );

    if (!second.isSuccess) {
      // 人类版本已经上去了，但 agent 版本没物化成功。这是**部分成功**：
      // 目标路径是用户的改动（符合默认裁决），只是缺副本。如实记为失败并
      // 把原因说清，用户可重跑（重跑时预检会发现远端 etag 已变成人类版本的，
      // 于是走 clean 直传——副本则需用户手动从 UFS 版本历史取）。
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '人类版本已上传，但 agent 版本副本上传失败：${second.reason}',
      );
    }

    final notified = await _notifyMessage(
      relPath: dirty.relPath,
      groupId: target.groupId,
      kind: _NotifyKind.conflict,
      conflictRelPath: conflictRelPath,
    );

    // 与直传分支同一取向（issue #53）：通知失败不写基线 —— 冲突虽已物化，
    // agent 尚不知道有副本可裁决。不写回 → 下轮仍 dirty → 重跑重新走冲突
    // 分支（agent 版本再下载一次，target 路径幂等覆盖）+ 重新通知。
    if (!notified) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.conflictMaterialized,
        conflictPath: conflictRelPath,
        notified: false,
      );
    }

    return UploadItemResult(
      relPath: dirty.relPath,
      groupId: target.groupId,
      outcome: UploadOutcome.conflictMaterialized,
      conflictPath: conflictRelPath,
      notified: true,
      syncedRecord: targetRecord,
    );
  }

  /// 上传一个文件到 [target]，必要时改走 quick-capture 兜底并通知。
  Future<UploadItemResult> _uploadTarget({
    required LocalDirtyFile dirty,
    required UploadTarget target,
    required List<int> localBytes,
    required String filename,
    required _NotifyKind notifyKind,
  }) async {
    final WorkspaceFileUpload uploaded;
    try {
      uploaded = await uploader.uploadWorkspaceFile(
        groupId: target.groupId,
        relativePath: target.groupRelPath,
        bytes: localBytes,
        filename: filename,
      );
    } on HttpError catch (e) {
      // 413：超过服务端上限（默认 1 MiB）。不做客户端预判（拿不到服务端实际
      // 生效值），按响应改走 quick-capture 附件链（上限 50 MiB）。
      if (e.statusCode == 413) {
        return _fallbackToQuickCapture(
          dirty: dirty,
          target: target,
          localBytes: localBytes,
          filename: filename,
        );
      }
      // 400（路径黑名单等）/ 404 / 其他：如实报失败。
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '上传失败（HTTP ${e.statusCode}）：${e.body ?? e.message}',
      );
    } on SpbError catch (e) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '上传失败：${e.message}',
      );
    }

    // 新基线（issue #53 缺陷②）：etag 来自上传响应（服务端须回 file.etag；
    // 旧版服务端缺失时为 null，预检退回保守冲突语义）。contentHash 对上传
    // 字节计算——脏检测拿它与用户日后改过的本地内容比对。
    final record = UploadSyncedRecord(
      etag: uploaded.etag,
      size: localBytes.length,
      contentHash: contentHashOf(localBytes),
    );

    if (notifyKind == _NotifyKind.none) {
      // 冲突分支：通知在两次上传后统一发（消息里要给出两个路径）。
      // 这里返回一个「已上传但未通知」的结果，由调用方替换。
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.uploaded,
        syncedRecord: record,
      );
    }

    final notified = await _notifyMessage(
      relPath: dirty.relPath,
      groupId: target.groupId,
      kind: notifyKind,
    );

    // 通知失败时**不**返回新基线（issue #53 的重试语义）：内容已上传，但
    // agent 还不知道。若把基线写回，用户重跑「回传」时脏检测判定「未变更」
    // → 连通知机会都没有，改动静默丢失。不写回 → 文件仍 dirty → 重跑会
    // 重新上传（服务端 overwrite）+ 重新通知；requestId 稳定（同 relPath），
    // 服务端幂等去重不会重复建 turn。上传本身可重入（幂等覆盖）。
    if (!notified) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.uploaded,
        notified: false,
      );
    }

    return UploadItemResult(
      relPath: dirty.relPath,
      groupId: target.groupId,
      outcome: UploadOutcome.uploaded,
      notified: true,
      syncedRecord: record,
    );
  }

  /// 413 兜底：附件走 quick-capture 链，消息里写明目标路径。
  ///
  /// ## 为什么不直接报「文件太大」
  ///
  /// 超过 1 MiB 的交付物（图片、PDF）完全正常，直接拒绝会让 agent 永远不知道
  /// 用户改了这个文件。附件链上限 50 MiB，覆盖绝大多数情况。
  ///
  /// ## 为什么 input 必须写目标路径
  ///
  /// 附件落到 workspace 的 `_attachments/{turnID}/`，**不是**用户改的那个路径。
  /// 不写清楚的话 agent 只会看到「一个叫 x.md 的附件」，不知道该覆盖谁。
  ///
  /// ## 为什么这里不提 `_conflict/` 副本（issue #62）
  ///
  /// 本函数曾收一个 `conflictRelPath` 并往文案里追加「另有一份 agent 版本副本
  /// 位于 …」。该参数**没有任何调用点传过非 null**：冲突分支由
  /// [_materializeConflict] 自己发通知（`_NotifyKind.conflict`，两次上传都成功
  /// 之后），而 413 兜底发生在人类版本首次上传时——那时副本还没物化。
  /// 于是那条文案连同它的插值 bug 一起是死代码。
  ///
  /// 顺带记录那个 bug 的形态（`tools/check_dollar_paren.sh` 现在会拦）：
  /// `'… $conflictBasename(conflictRelPath) …'` 插值的是**函数对象**，`$identifier`
  /// 只取标识符本身，后面的 `(conflictRelPath)` 是字面文本，产出
  /// `Closure: (String) => String from Function '_basename': static.(conflictRelPath)`。
  /// `dart analyze` 抓不到（插值函数合法、`Object.toString()` 存在）。
  ///
  /// 将来若真要在 413 兜底里提副本，得先让冲突分支在 413 之前就物化副本，
  /// 那是另一个设计（副本上传同样可能 413），不要靠复活这个参数解决。
  Future<UploadItemResult> _fallbackToQuickCapture({
    required LocalDirtyFile dirty,
    required UploadTarget target,
    required List<int> localBytes,
    required String filename,
  }) async {
    final QuickCaptureUpload uploaded;
    try {
      uploaded = await quickCapture.uploadQuickCaptureAttachment(
        bytes: localBytes,
        filename: filename,
      );
    } on SpbError catch (e) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '文件超过 workspace 上限，且附件通道上传失败：${e.message}',
      );
    }

    if (!uploaded.isValid) {
      // 2xx 但缺 file_id：契约漂移。当成失败，不把一个空标识带进投递
      // （那会 400 且错误信息指向附件标识，很难联想到是响应解析问题）。
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '附件通道未返回文件标识',
      );
    }

    try {
      await quickCapture.enqueueQuickCapture(
        input:
            '我修改了交付物 $filename，目标路径 ${target.groupRelPath}。'
            '该文件超过 workspace 同步上限，已作为附件发送，'
            '请把它落位到上述路径（覆盖旧版本）后继续。',
        attachments: [uploaded.fileId],
      );
    } on SpbError catch (e) {
      return UploadItemResult(
        relPath: dirty.relPath,
        groupId: target.groupId,
        outcome: UploadOutcome.failed,
        reason: '附件已上传，但投递失败：${e.message}',
      );
    }

    return UploadItemResult(
      relPath: dirty.relPath,
      groupId: target.groupId,
      outcome: UploadOutcome.fallbackQuickCapture,
      // 附件链的通知就是 enqueue 本身（它建 turn），不需要再发一条消息。
      // 副本路径同理留空：走到这里时副本尚未物化（见函数文档）。
      notified: true,
    );
  }

  /// 发一条通知消息；返回是否成功。
  ///
  /// ## 为什么 `requestId` 必须由 [relPath] 稳定推出
  ///
  /// 用户可能因为通知失败而重跑回传。若每次生成新的 uuid，服务端会把重跑当成
  /// 新消息再建一个 turn——对话里出现两条「我改了 x.md」，agent 可能处理两遍。
  /// 用稳定键后，同值 request_id 命中幂等（服务端返回已有 turn，不新建）。
  ///
  /// 注意「稳定」的范围是**同一个 relPath**：不同文件的消息本就该各自建 turn。
  Future<bool> _notifyMessage({
    required String relPath,
    required String groupId,
    required _NotifyKind kind,
    String? conflictRelPath,
  }) async {
    final path = _groupRelPathForMessage(relPath, groupId);
    final filename = conflictBasename(path);

    final String input;
    switch (kind) {
      case _NotifyKind.direct:
        input = '我修改了交付物 $filename（$path）。请基于新版本继续，旧内容已过时。';
      case _NotifyKind.conflict:
        input =
            '我修改了交付物 $filename（$path），同时你也有一个新版本，'
            '两者产生了冲突。你的版本已保留在 $conflictDirName/'
            '${conflictBasename(conflictRelPath ?? '')}。'
            '请比对两份内容：若我的改动小，请合并后写回 $path 并把差异讲清楚；'
            '若无法安全合并，请说明冲突点并等我确认。默认以我的版本为准。';
      case _NotifyKind.none:
        return false;
    }

    try {
      await notifier.sendMessage(
        userId: userId,
        groupId: groupId,
        input: input,
        requestId: _requestId(relPath, groupId),
      );
      return true;
    } on SpbError catch (e) {
      // 通知失败**不**回滚上传：文件已在 workspace 里，回滚反而会让用户的
      // 改动丢失。如实记录「已上传但未通知」，由 UI 提示。
      SpbLog.warn('交付物回传通知失败', {
        'rel_path': relPath,
        'group_id': groupId,
        'error': e.message,
      });
      return false;
    }
  }

  String _requestId(String relPath, String groupId) {
    if (requestIdFor != null) return requestIdFor!(relPath);
    // 稳定派生（issue #53 缺陷①）：uuid v5，namespace 取 groupId 的 v5
    // （URL namespace + groupId），name 取 relPath。同一 (groupId, relPath)
    // 永远得到同一 id → 服务端 (user_id, request_id) 幂等命中，重试不再
    // 重复建 turn。不再用 uuid v4 默认值：生产装配未注入 requestIdFor，
    // 随机 id 让「通知超时后重试」必产第二个 turn（重复 agent 成本）。
    // 内层 namespace 也是 v5：与 groupId 一一对应，且不要求 groupId 本身
    // 是合法 uuid。两层都用 URL namespace 作根。
    final groupNs = const Uuid().v5(Namespace.url.value, groupId);
    return const Uuid().v5(groupNs, relPath);
  }
}

/// 通知消息的种类。
enum _NotifyKind { none, direct, conflict }

/// 从 UFS 绝对路径取 group 内相对路径；null = 不属于该 group。
String? _groupRelPathOf(String ufsPath, String groupId) =>
    groupRelativePath(ufsPath, groupId);

/// 通知消息里展示的路径：剥掉 workspace 布局的 `{gid}/` 前缀（若在）。
///
/// 用**组内**路径展示给 agent：agent 的 workspace 视图就是组内布局，
/// 写 `{gid}/reports/x.md` 会让它去找一个不存在的目录。
String _groupRelPathForMessage(String relPath, String groupId) {
  final target = uploadTargetFor(relPath, stateKey: workspaceStateKey);
  if (target != null && target.groupId == groupId) return target.groupRelPath;
  return relPath;
}

/// Unix 秒 → RFC3339 UTC（复用同步游标的同一实现，保证格式一致）。
String _rfc3339Utc(int secs) => unixToRfc3339(secs);
