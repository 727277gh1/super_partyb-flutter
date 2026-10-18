import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 回传编排用例测试（内存桩，无网络无磁盘）。
///
/// ## 用例覆盖的核心正确性
///
/// 1. **clean 直传**：预检一致 → 只传一次 → 发通知；
/// 2. **conflict 双写**：人类版本到目标路径、agent 版本到 `_conflict/`，
///    且**先取 agent 字节再写目标**（顺序错了会把 agent 版本弄丢）；
/// 3. **413 兜底**：改走附件链，消息里写明目标路径；
/// 4. **通知幂等**：同文件重跑 requestId 不变（服务端靠它去重）；
/// 5. **不误报**：缺 hash 不进脏列表、远端已删不覆盖、通知失败不回滚上传。

/// 内存读取桩。
class _Reader implements LocalFileReader {
  _Reader(this.files);

  final Map<String, List<int>> files;

  @override
  Future<List<int>> readBytes(String relPath) async {
    final bytes = files[relPath];
    if (bytes == null) throw PlatformError('本地文件不存在：$relPath');
    return bytes;
  }
}

/// 内存状态库。
class _Store implements SyncStateStore {
  final data = <String, SyncState>{};

  @override
  Future<SyncState> load(String key) async => data[key] ?? SyncState.empty;

  @override
  Future<void> save(String key, SyncState state) async => data[key] = state;

  @override
  Future<void> reset(String key) async => data.remove(key);

  @override
  Future<void> resetAll() async => data.clear();
}

/// 一次上传调用。
class UploadCall {
  UploadCall({
    required this.groupId,
    required this.relativePath,
    required this.bytes,
    required this.filename,
  });

  final String groupId;
  final String relativePath;
  final List<int> bytes;
  final String filename;

  @override
  String toString() =>
      'UploadCall($groupId, $relativePath, ${bytes.length}B, $filename)';
}

/// 上传桩：记录调用，可按 relativePath 注入错误。
class _Uploader implements UploadSender {
  final calls = <UploadCall>[];
  final errors = <String, Object Function(UploadCall)>{};

  @override
  Future<WorkspaceFileUpload> uploadWorkspaceFile({
    required String groupId,
    required String relativePath,
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) async {
    final call = UploadCall(
      groupId: groupId,
      relativePath: relativePath,
      bytes: bytes ?? const [],
      filename: filename,
    );
    calls.add(call);
    final err = errors[relativePath];
    if (err != null) throw err(call);
    return WorkspaceFileUpload(
      groupId: groupId,
      relativePath: relativePath,
      fileId: 'ufs-1',
      syncStatus: 'local_synced',
      sizeBytes: call.bytes.length,
    );
  }
}

/// 一次通知消息。
class NotifyCall {
  NotifyCall({
    required this.userId,
    required this.input,
    required this.groupId,
    required this.requestId,
  });

  final String userId;
  final String input;
  final String groupId;
  final String requestId;

  @override
  String toString() => 'NotifyCall($groupId, $requestId, $input)';
}

/// 通知桩。
class _Notifier implements UploadNotifier {
  final calls = <NotifyCall>[];
  Object? error;

  @override
  Future<void> sendMessage({
    required String userId,
    required String input,
    String? groupId,
    String? requestId,
  }) async {
    if (error != null) throw error!;
    calls.add(
      NotifyCall(
        userId: userId,
        input: input,
        groupId: groupId!,
        requestId: requestId!,
      ),
    );
  }
}

/// 附件链桩。
class _QuickCapture implements QuickCaptureSender {
  final uploads = <String, List<int>>{};
  final enqueues = <({String input, List<String> attachments})>[];
  Object? uploadError;
  Object? enqueueError;
  bool omitFileId = false;

  @override
  Future<QuickCaptureUpload> uploadQuickCaptureAttachment({
    List<int>? bytes,
    String? path,
    required String filename,
    String? contentType,
  }) async {
    if (uploadError != null) throw uploadError!;
    uploads[filename] = bytes ?? const [];
    return QuickCaptureUpload(
      fileId: omitFileId ? '' : 'qc-1',
      fileName: filename,
      size: (bytes ?? const []).length,
    );
  }

  @override
  Future<void> enqueueQuickCapture({
    String input = '',
    List<String> attachments = const [],
  }) async {
    if (enqueueError != null) throw enqueueError!;
    enqueues.add((input: input, attachments: attachments));
  }
}

/// 远端清单 + 下载桩。
class _Remote implements RemoteWorkspace {
  _Remote(this.entries);

  final List<UfsFileEntry> entries;
  final downloads = <String, int>{};
  Object? downloadError;

  @override
  Future<List<UfsFileEntry>> listAll({
    required String pathPrefix,
    bool includeDeleted = true,
  }) async =>
      // 真实实现按 pathPrefix 过滤；桩直接给全量，让用例依赖它自己匹配
      // ——但为了验证「用例按 group 前缀过滤」这件事，这里做个粗过滤。
      entries.where((e) => e.path.startsWith(pathPrefix)).toList();

  @override
  Future<List<int>> downloadBytes(String fileId) async {
    if (downloadError != null) throw downloadError!;
    downloads[fileId] = (downloads[fileId] ?? 0) + 1;
    // agent 版本（与人类版本字节不同）。
    return [11, 22, 33];
  }
}

const _gid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

/// workspace 布局下状态表里的完整相对路径。
const _rel = '$_gid/reports/x.md';

/// 人类版本字节。
const _human = [1, 2, 3];

/// 远端条目（UFS 绝对路径形态，带尾斜杠）。
UfsFileEntry _remoteEntry({
  String groupRel = 'reports/x.md',
  String etag = 'W/"2"',
  bool deleted = false,
}) => UfsFileEntry.fromJson({
  'id': 'ufs-agent',
  'path': '/workspace/groups/$_gid/$groupRel/',
  'name': groupRel.split('/').last,
  'size': 3,
  'mime_type': 'text/markdown',
  'etag': etag,
  'updated_at': '2026-09-30T00:00:00Z',
  if (deleted) 'deleted_at': '2026-09-30T01:00:00Z',
});

SyncState _state({String? recordEtag = 'W/"1"'}) => SyncState(
  files: {
    _rel: SyncedFile(
      etag: recordEtag,
      size: _human.length,
      contentHash: contentHashOf(_human),
    ),
  },
);

DeliverableUploadUseCase _useCase({
  required _Reader reader,
  required _Store store,
  required _Remote remote,
  required _Uploader uploader,
  required _Notifier notifier,
  required _QuickCapture quickCapture,
  Map<String, String> requestIds = const {},
}) => _useCaseRaw(
  reader: reader,
  store: store,
  remote: remote,
  uploader: uploader,
  notifier: notifier,
  quickCapture: quickCapture,
  requestIds: requestIds,
);

/// 接受任意 [RemoteWorkspace] 实现的装配（测试特殊桩用）。
DeliverableUploadUseCase _useCaseRaw({
  required LocalFileReader reader,
  required SyncStateStore store,
  required RemoteWorkspace remote,
  required UploadSender uploader,
  required UploadNotifier notifier,
  required QuickCaptureSender quickCapture,
  Map<String, String> requestIds = const {},
}) => DeliverableUploadUseCase(
  reader: reader,
  stateStore: store,
  remote: remote,
  uploader: uploader,
  quickCapture: quickCapture,
  notifier: notifier,
  userId: 'usr_1',
  nowUnix: () => 1791000000,
  requestIdFor: (rel) => requestIds[rel] ?? 'req-fixed-$rel',
);

/// 默认装配（clean 直传的基线）。
(_Reader, _Store, _Remote, _Uploader, _Notifier, _QuickCapture) _defaults({
  SyncState? state,
  List<UfsFileEntry> remoteEntries = const [],
  Map<String, List<int>> localFiles = const {},
}) {
  final store = _Store();
  store.data[workspaceStateKey] = state ?? _state();
  final reader = _Reader(localFiles);
  final remote = _Remote(remoteEntries);
  return (reader, store, remote, _Uploader(), _Notifier(), _QuickCapture());
}

void main() {
  group('回传编排：clean 直传', () {
    test('预检一致 → 传一次、通知一次，消息带 group_id 与稳定 requestId', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        // 远端 etag 与记录一致 → clean。
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {
          _rel: [9, 9, 9],
        }, // 本地被改过
      );
      final uc = _useCase(
        reader: reader,
        store: store,
        remote: remote,
        uploader: uploader,
        notifier: notifier,
        quickCapture: quick,
      );

      final report = await uc.run(
        scope: const SyncWorkspaceScope(),
        filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
      );

      // 上传：剥掉 {gid}/ 前缀（服务端自己拼 workspace/groups/{gid}/）。
      expect(uploader.calls, hasLength(1));
      final up = uploader.calls.single;
      expect(up.groupId, _gid);
      expect(up.relativePath, 'reports/x.md', reason: '必须剥掉 {gid}/ 前缀');
      expect(up.bytes, [9, 9, 9], reason: '上传的是本地现字节');

      // 通知：group 固定归属 + requestId（幂等）。
      expect(notifier.calls, hasLength(1));
      final n = notifier.calls.single;
      expect(n.groupId, _gid);
      expect(n.userId, 'usr_1');
      expect(n.requestId, 'req-fixed-$_rel');
      expect(n.input, contains('reports/x.md'));
      expect(n.input, contains('请基于新版本继续'));

      // 附件链不该被触发。
      expect(quick.uploads, isEmpty);
      expect(quick.enqueues, isEmpty);

      expect(report.count(UploadOutcome.uploaded), 1);
      expect(report.items.single.notified, isTrue);
      expect(report.items.single.isSuccess, isTrue);
    });

    test('同一文件重跑：requestId 不变（服务端幂等去重，不产生重复消息）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final uc = _useCase(
        reader: reader,
        store: store,
        remote: remote,
        uploader: uploader,
        notifier: notifier,
        quickCapture: quick,
      );
      final args = {
        'scope': const SyncWorkspaceScope(),
        'filter': const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
      };

      // 通知失败两次都发生：requestId 由 relPath 稳定推出，与重试次数无关。
      notifier.error = const HttpError(429, '限流');
      final r1 = await uc.run(
        scope: args['scope'] as SyncScope,
        filter: args['filter'] as SyncFilterConfig,
      );
      final r2 = await uc.run(
        scope: args['scope'] as SyncScope,
        filter: args['filter'] as SyncFilterConfig,
      );

      expect(r1.items.single.notified, isFalse);
      expect(r2.items.single.notified, isFalse);
      expect(
        notifier.calls.map((c) => c.requestId).toSet(),
        isEmpty,
        reason: '两次都失败，没有成功通知',
      );

      // 第三次成功：发出的 requestId 与前两次构造的相同（同 relPath）。
      notifier.error = null;
      final r3 = await uc.run(
        scope: args['scope'] as SyncScope,
        filter: args['filter'] as SyncFilterConfig,
      );
      expect(r3.items.single.notified, isTrue);
      expect(
        notifier.calls.single.requestId,
        'req-fixed-$_rel',
        reason: '同文件重试的幂等键必须稳定',
      );
    });

    test('不脏的文件不传不通知（contentHash 一致）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {_rel: _human}, // 与记录的 hash 一致
      );
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );

      expect(report.items, isEmpty);
      expect(report.unchanged, 1);
      expect(uploader.calls, isEmpty);
      expect(notifier.calls, isEmpty);
      expect(report.summarize(), contains('没有本地改动'));
    });

    test('记录缺 contentHash → 不进脏列表（降级不误报）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        state: const SyncState(
          files: {
            _rel: SyncedFile(etag: 'W/"1"', size: 3), // 无 hash
          },
        ),
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );

      expect(report.items, isEmpty);
      expect(report.undetectable, 1);
      expect(uploader.calls, isEmpty);
    });
  });

  group('回传编排：冲突物化', () {
    test('预检不一致 → 双写：人类版本到目标路径，agent 版本到 _conflict/', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        // 远端 etag 已变（agent 写过）→ conflict。
        remoteEntries: [_remoteEntry(etag: 'W/"2"')],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final uc = _useCase(
        reader: reader,
        store: store,
        remote: remote,
        uploader: uploader,
        notifier: notifier,
        quickCapture: quick,
      );

      final report = await uc.run(
        scope: const SyncWorkspaceScope(),
        filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
        conflictTimestamp: '2026-09-30T12:00:00Z',
      );

      final item = report.items.single;
      expect(item.outcome, UploadOutcome.conflictMaterialized);
      expect(item.conflictPath, '_conflict/2026-09-30T12-00-00Z-x.md.conflict');
      expect(item.notified, isTrue);

      // 两次上传：顺序 + 内容 + 路径都要对。
      expect(uploader.calls, hasLength(2));

      final human = uploader.calls[0];
      expect(
        human.relativePath,
        'reports/x.md',
        reason: '人类版本 → 目标路径（默认裁决：人类优先）',
      );
      expect(human.bytes, [9, 9, 9]);

      final agent = uploader.calls[1];
      expect(
        agent.relativePath,
        '_conflict/2026-09-30T12-00-00Z-x.md.conflict',
        reason: 'agent 版本 → _conflict/，.conflict 后缀避开 include globs',
      );
      expect(agent.bytes, [11, 22, 33], reason: 'agent 版本字节来自远端下载');

      // agent 字节被下载过一次。
      expect(remote.downloads['ufs-agent'], 1);

      // 通知消息给出两个路径。
      expect(notifier.calls, hasLength(1));
      expect(notifier.calls.single.input, contains('_conflict/'));
      expect(notifier.calls.single.input, contains('reports/x.md'));
    });

    test('agent 版本下载失败 → 不写目标路径（防止弄丢 agent 版本）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"2"')],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      remote.downloadError = const NetworkError('超时');
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );

      expect(report.items.single.outcome, UploadOutcome.failed);
      expect(report.items.single.reason, contains('下载 agent 版本失败'));
      expect(uploader.calls, isEmpty, reason: '目标路径不能先写：否则 agent 新版本就丢了');
      expect(notifier.calls, isEmpty);
    });

    test('副本上传失败 → 报部分成功状态（人类版本已上去）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"2"')],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      uploader.errors['_conflict/2026-09-30T12-00-00Z-x.md.conflict'] = (
        call,
      ) => const HttpError(500, '存储故障');
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
            conflictTimestamp: '2026-09-30T12:00:00Z',
          );

      expect(report.items.single.outcome, UploadOutcome.failed);
      expect(report.items.single.reason, contains('人类版本已上传'));
      // 两次调用都发生了（第二次抛 500），但只有第一次成功上传。
      expect(uploader.calls, hasLength(2));
      expect(uploader.calls[0].relativePath, 'reports/x.md');
      expect(uploader.calls[1].relativePath, contains('_conflict/'));
      expect(notifier.calls, isEmpty, reason: '冲突消息需要两个路径都在才发');
    });
  });

  group('回传编排：413 兜底', () {
    test('413 → 走附件链：上传 + enqueue，input 写明目标路径', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {_rel: List.filled(2 * 1024 * 1024, 7)},
      );
      uploader.errors['reports/x.md'] = (call) =>
          const HttpError(413, '文件超过 workspace 同步大小上限');
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );

      final item = report.items.single;
      expect(item.outcome, UploadOutcome.fallbackQuickCapture);
      expect(item.notified, isTrue, reason: 'enqueue 本身就是通知');

      // ufs-upload 试过一次（被 413 拒）。
      expect(uploader.calls, hasLength(1));

      // 附件上传的字节与本地一致。
      expect(quick.uploads['x.md'], hasLength(2 * 1024 * 1024));

      // enqueue 带上 file_id 与目标路径说明。
      expect(quick.enqueues, hasLength(1));
      final e = quick.enqueues.single;
      expect(e.attachments, ['qc-1']);
      expect(e.input, contains('reports/x.md'), reason: '必须写明目标路径');
      expect(e.input, contains('x.md'));

      // 不应再走 sendMessage（enqueue 已建 turn）。
      expect(notifier.calls, isEmpty);
    });

    test('413 且附件上传也失败 → failed（如实报两层原因）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {_rel: List.filled(2 * 1024 * 1024, 7)},
      );
      uploader.errors['reports/x.md'] = (call) => const HttpError(413, '超限');
      quick.uploadError = const NetworkError('断网');
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );
      expect(report.items.single.outcome, UploadOutcome.failed);
      expect(report.items.single.reason, contains('附件通道上传失败'));
    });

    test('413 且 enqueue 失败 → failed（附件已在服务端但不该假装成功）', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(etag: 'W/"1"')],
        localFiles: {_rel: List.filled(2 * 1024 * 1024, 7)},
      );
      uploader.errors['reports/x.md'] = (call) => const HttpError(413, '超限');
      quick.enqueueError = const NetworkError('断网');
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );
      expect(report.items.single.outcome, UploadOutcome.failed);
      expect(report.items.single.reason, contains('投递失败'));
    });
  });

  group('回传编排：远端已删与其他跳过', () {
    test('远端已软删除 → skippedRemoteDeleted，不覆盖不通知', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: [_remoteEntry(deleted: true)],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );

      expect(report.items.single.outcome, UploadOutcome.skippedRemoteDeleted);
      expect(uploader.calls, isEmpty);
      expect(notifier.calls, isEmpty);
    });

    test('远端清单里没有该条目 → 同样按 remoteDeleted 处理', () async {
      final (reader, store, remote, uploader, notifier, quick) = _defaults(
        remoteEntries: const [], // 清单为空
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );
      expect(report.items.single.outcome, UploadOutcome.skippedRemoteDeleted);
    });

    test('远端清单拉取失败 → 该 group 全部候选记为失败（不静默跳过）', () async {
      final (reader, store, _, uploader, notifier, quick) = _defaults(
        remoteEntries: const [],
        localFiles: {
          _rel: [9, 9, 9],
        },
      );
      final brokenRemote = _BrokenRemote();
      final report =
          await _useCaseRaw(
            reader: reader,
            store: store,
            remote: brokenRemote,
            uploader: uploader,
            notifier: notifier,
            quickCapture: quick,
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
          );
      expect(report.items.single.outcome, UploadOutcome.failed);
      expect(report.items.single.reason, contains('拉取远端清单失败'));
    });

    test('only 限定子集：没勾的文件不动', () async {
      const rel2 = '$_gid/reports/y.md';
      final store = _Store();
      store.data[workspaceStateKey] = SyncState(
        files: {
          _rel: SyncedFile(
            etag: 'W/"1"',
            size: 1,
            contentHash: contentHashOf(_human),
          ),
          rel2: SyncedFile(
            etag: 'W/"1"',
            size: 1,
            contentHash: contentHashOf([5]),
          ),
        },
      );
      final reader = _Reader({
        _rel: [9, 9, 9],
        rel2: [6, 6, 6],
      });
      final remote = _Remote([
        _remoteEntry(etag: 'W/"1"'),
        _remoteEntry(groupRel: 'reports/y.md', etag: 'W/"1"'),
      ]);
      final uploader = _Uploader();
      final report =
          await _useCase(
            reader: reader,
            store: store,
            remote: remote,
            uploader: uploader,
            notifier: _Notifier(),
            quickCapture: _QuickCapture(),
          ).run(
            scope: const SyncWorkspaceScope(),
            filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
            only: {rel2},
          );

      expect(report.items, hasLength(1));
      expect(report.items.single.relPath, rel2);
      expect(uploader.calls.single.relativePath, 'reports/y.md');
    });
  });

  group('buildConflictPath', () {
    test('格式：_conflict/<RFC3339>-<原名>.conflict，冒号替换成 -', () {
      // 冒号在 Windows 上非法，而副本会落到用户的同步目录。
      expect(
        buildConflictPath('reports/a.md', '2026-09-30T12:00:00Z'),
        '_conflict/2026-09-30T12-00-00Z-a.md.conflict',
      );
    });

    test('多层原路径只取文件名；原名带 glob 敏感扩展名也被 .conflict 钝化', () {
      final p = buildConflictPath(
        'specs/feature.spec.json',
        '2026-09-30T12:00:00Z',
      );
      expect(p, '_conflict/2026-09-30T12-00-00Z-feature.spec.json.conflict');
      expect(
        p.endsWith('.conflict'),
        isTrue,
        reason: 'include globs 是全目录模式，必须靠末尾后缀避开',
      );
    });
  });
}

/// 清单必失败的远端桩。
class _BrokenRemote implements RemoteWorkspace {
  @override
  Future<List<UfsFileEntry>> listAll({
    required String pathPrefix,
    bool includeDeleted = true,
  }) async => throw const NetworkError('清单接口超时');

  @override
  Future<List<int>> downloadBytes(String fileId) async =>
      throw UnimplementedError();
}
