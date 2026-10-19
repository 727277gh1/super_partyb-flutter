import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 交付物回传的纯逻辑测试：目标解析、脏检测、etag 预检。
///
/// 三块都要覆盖「不误报」这一侧——误报的后果比漏报严重：
/// - 脏检测误报 → 用户看到一堆自己没动过的文件，顺手「确认回传」就把 agent
///   的版本覆盖了；
/// - 预检把「不知道」当成「没被写过」→ 静默覆盖 agent 的新版本。
///
/// 故每个「不算脏 / 不算干净」的分支都有一条用例。

/// 内存读取桩：按路径给字节，未登记的路径抛错（与真实实现一致）。
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

const _gid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const _otherGid = '0123456789abcdef0123456789abcdef';

/// 构造远端条目（path 带尾斜杠，对齐 UFS 实测行为）。
UfsFileEntry _remote(
  String groupRel, {
  String groupId = _gid,
  String? etag = 'W/"1"',
  int size = 10,
  bool deleted = false,
}) => UfsFileEntry.fromJson({
  'id': 'id-$groupRel',
  'path': '/workspace/groups/$groupId/$groupRel/',
  'name': groupRel.split('/').last,
  'size': size,
  'mime_type': 'text/markdown',
  if (etag != null) 'etag': etag,
  'updated_at': '2026-01-01T00:00:00Z',
  if (deleted) 'deleted_at': '2026-02-01T00:00:00Z',
});

/// 内容 → 记录（hash 由同一算法算，避免测试里手抄哈希）。
SyncedFile _record(
  List<int> bytes, {
  String? etag = 'W/"1"',
  String? contentHash,
}) => SyncedFile(
  etag: etag,
  size: bytes.length,
  contentHash: contentHash ?? contentHashOf(bytes),
);

/// 内容 → 记录（hash 由同一算法算，避免测试里手抄哈希）。

const _permissive = SyncFilterConfig(maxFileSize: 0, includeMedia: true);

void main() {
  // =========================================================================
  group('回传目标解析：两种落盘布局', () {
    test('workspace 布局：首段是 groupId，必须剥掉', () {
      // 不剥的话服务端会拼成 workspace/groups/{gid}/{gid}/... —— 不报错，
      // 只是文件落到错误的位置，且下轮同步在两个位置各出现一份。
      final t = uploadTargetFor(
        '$_gid/reports/a.md',
        stateKey: workspaceStateKey,
      );
      expect(t, isNotNull);
      expect(t!.groupId, _gid);
      expect(t.groupRelPath, 'reports/a.md');
    });

    test('单 group 布局：路径无前缀，groupId 来自状态键', () {
      final t = uploadTargetFor('reports/a.md', stateKey: _gid);
      expect(t, isNotNull);
      expect(t!.groupId, _gid);
      expect(t.groupRelPath, 'reports/a.md');
    });

    test('单 group 布局下路径首段恰好是 group 形状也不误剥', () {
      // 单 group 模式里用户可能真有 reports/<32位hex>/ 这种目录；判据是
      // 「状态键是 workspace 还是具体 group」，不是「首段像不像 groupId」。
      final t = uploadTargetFor('$_otherGid/a.md', stateKey: _gid);
      expect(t, isNotNull);
      expect(t!.groupId, _gid, reason: '单 group 模式下状态键才是 group');
      expect(t.groupRelPath, '$_otherGid/a.md', reason: '不得误剥用户目录');
    });

    test('workspace 布局下无前缀路径不猜 group（返回 null）', () {
      expect(
        uploadTargetFor('reports/a.md', stateKey: workspaceStateKey),
        isNull,
      );
      // 首段不像 group_id 也是异常状态（状态表被外部改动过），不猜。
      expect(
        uploadTargetFor('notagid/a.md', stateKey: workspaceStateKey),
        isNull,
      );
    });

    test('非法路径一律拒绝（写远端入口，宁严不宽）', () {
      expect(uploadTargetFor('../evil.md', stateKey: _gid), isNull);
      expect(uploadTargetFor('a/../b.md', stateKey: _gid), isNull);
      expect(uploadTargetFor('/etc/passwd', stateKey: _gid), isNull);
      expect(uploadTargetFor('a\\b.md', stateKey: _gid), isNull);
      expect(uploadTargetFor('', stateKey: _gid), isNull);
      expect(uploadTargetFor('a//b.md', stateKey: _gid), isNull);
    });

    test('workspace 布局下只有 groupId 一段 = group 根目录，不是文件', () {
      expect(uploadTargetFor(_gid, stateKey: workspaceStateKey), isNull);
    });
  });

  // =========================================================================
  group('脏检测', () {
    test('改一字节 → 进脏列表（size 可能相同，必须靠内容判）', () async {
      const rel = '$_gid/a.md';
      final reader = _Reader({
        rel: [1, 2, 3, 4],
      });
      final state = SyncState(
        files: {
          rel: _record([1, 2, 3, 9]),
        }, // 大小相同，内容不同
      );

      final result = await scanLocalDirtyFiles(
        reader: reader,
        state: state,
        filter: _permissive,
        stateKey: workspaceStateKey,
      );

      expect(result.dirty, hasLength(1));
      expect(result.dirty.single.relPath, rel);
      expect(result.dirty.single.groupId, _gid);
      expect(result.dirty.single.localSize, 4, reason: 'localSize 是实际读到的字节数');
      expect(result.unchanged, 0);
    });

    test('内容一致 → 不进脏列表', () async {
      const rel = '$_gid/a.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1, 2, 3],
        }),
        state: SyncState(
          files: {
            rel: _record([1, 2, 3]),
          },
        ),
        filter: _permissive,
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(result.unchanged, 1);
      expect(result.summarize(), contains('没有本地改动'));
    });

    test('仅 mtime 变（内容相同）→ 不进脏列表', () async {
      // 判据只有内容 hash，没有任何时间戳输入。用户 touch 一下、或同步器刚
      // 写过一遍，都不该被报成「改动」。
      const rel = '$_gid/a.md';
      final bytes = [7, 8, 9];
      final result = await scanLocalDirtyFiles(
        reader: _Reader({rel: bytes}),
        state: SyncState(files: {rel: _record(bytes)}),
        filter: _permissive,
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(result.unchanged, 1);
    });

    test('reports/tts/ 下的改动不进脏列表（机器产物）', () async {
      // 单 group 布局：relPath 就是组内路径，前缀锚定在开头 → 命中。
      // （workspace 布局下 relPath 是 `{gid}/reports/tts/...`，同步侧
      //  `shouldSync` 同样命中不了——两边行为一致，镜像关系成立。）
      const rel = 'reports/tts/a.mp3';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1],
        }),
        state: SyncState(
          files: {
            rel: _record([2, 2, 2]),
          },
        ),
        filter: _permissive,
        stateKey: _gid,
      );
      expect(result.dirty, isEmpty);
      expect(
        result.filtered[SyncSkipReason.machineGenerated],
        1,
        reason: '机器产物必须先于媒体判定，否则原因会显示成「媒体（未开启）」',
      );
    });

    test('tts 前缀只锚定在组内路径开头（x/reports/tts/ 不误伤）', () async {
      const rel = 'x/reports/tts/a.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1],
        }),
        state: SyncState(
          files: {
            rel: _record([2]),
          },
        ),
        filter: _permissive,
        stateKey: _gid,
      );
      expect(result.dirty, hasLength(1), reason: '不是机器产物目录，用户改动该回传');
    });

    test('媒体扩展名在未开启媒体时跳过（按扩展名推断）', () async {
      const rel = '$_gid/reports/pic.png';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1],
        }),
        state: SyncState(
          files: {
            rel: _record([2]),
          },
        ),
        filter: const SyncFilterConfig(), // includeMedia: false
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(result.filtered[SyncSkipReason.mediaExcluded], 1);
    });

    test('超过体积上限的不进脏列表（按本地实际大小判）', () async {
      const rel = '$_gid/big.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1, 2, 3, 4, 5],
        }),
        state: SyncState(
          files: {
            rel: _record([9]),
          },
        ),
        filter: const SyncFilterConfig(maxFileSize: 4, includeMedia: true),
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(
        result.filtered[SyncSkipReason.tooLarge],
        1,
        reason: '体积按要上传的字节判，不是记录里下载时的大小',
      );
    });

    test('记录缺 contentHash → 无法检测，不算脏（降级不误报）', () async {
      const rel = '$_gid/a.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1, 2, 3],
        }),
        state: const SyncState(
          // 升级前写入的记录：有 etag/size，没有 contentHash。
          files: {rel: SyncedFile(etag: 'W/"1"', size: 3)},
        ),
        filter: _permissive,
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(result.undetectable, 1);
      expect(result.unchanged, 0);
      expect(result.summarize(), contains('无法检测'));
    });

    test('本地文件已不在 → 记失败，不算脏（没有内容可上传）', () async {
      const rel = '$_gid/gone.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader(const {}), // 读不到
        state: SyncState(
          files: {
            rel: _record([1, 2]),
          },
        ),
        filter: _permissive,
        stateKey: workspaceStateKey,
      );
      expect(result.dirty, isEmpty);
      expect(result.failed, hasLength(1));
      expect(result.failed.single.relPath, rel);
    });

    test('只遍历状态表：磁盘上多出来的文件不参与', () async {
      // 状态里没有的路径根本没有比对基准，也无从知道它是不是「改动」。
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          '$_gid/untracked.md': [1, 2, 3],
        }),
        state: SyncState.empty,
        filter: _permissive,
        stateKey: workspaceStateKey,
      );
      expect(result.scanned, 0);
      expect(result.dirty, isEmpty);
      expect(result.summarize(), '本地没有已同步的文件');
    });

    test('单 group 布局：groupId 取状态键', () async {
      const rel = 'reports/a.md';
      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          rel: [1, 2, 3],
        }),
        state: SyncState(
          files: {
            rel: _record([9, 9, 9]),
          },
        ),
        filter: _permissive,
        stateKey: _gid,
      );
      expect(result.dirty.single.groupId, _gid);
      expect(result.dirty.single.relPath, rel);
    });

    test('scanned 覆盖各分支之和（供「状态里有 N 条」展示）', () async {
      // 用 workspace 布局，路径带真实 group 前缀，覆盖完整链路。
      const dirtyRel = '$_gid/dirty.md';
      const sameRel = '$_gid/same.md';
      const noHashRel = '$_gid/nohash.md';
      const ttsRel = '$_gid/reports/tts/x.mp3';
      const goneRel = '$_gid/gone.md';

      final result = await scanLocalDirtyFiles(
        reader: _Reader({
          dirtyRel: [1],
          sameRel: [2],
          noHashRel: [3],
        }),
        state: SyncState(
          files: {
            dirtyRel: _record([9]),
            sameRel: _record([2]),
            noHashRel: const SyncedFile(etag: 'W/"1"', size: 1),
            ttsRel: _record([5]),
            goneRel: _record([6]),
          },
        ),
        filter: _permissive,
        stateKey: workspaceStateKey,
      );

      expect(result.dirty, hasLength(1));
      expect(result.dirty.single.relPath, dirtyRel);
      expect(result.unchanged, 1);
      expect(result.undetectable, 1);
      expect(
        result.filtered[SyncSkipReason.machineGenerated],
        1,
        reason: 'workspace 布局下 tts 前缀命中不了（与下载侧 shouldSync 行为一致）',
      );
      expect(result.failed, hasLength(1));
      expect(result.scanned, 5);
    });
  });

  // =========================================================================
  group('etag 预检三态', () {
    test('etag 一致 → clean（远端自上次同步后没被写过）', () {
      final check = precheckUpload(
        remote: _remote('a.md', etag: 'W/"1"'),
        recorded: const SyncedFile(etag: 'W/"1"', size: 10),
      );
      expect(check, isA<UploadClean>());
      expect((check as UploadClean).remoteEtag, 'W/"1"');
    });

    test('etag 不一致 → conflict（携带两侧 etag 供 UI 说明）', () {
      final check = precheckUpload(
        remote: _remote('a.md', etag: 'W/"2"'),
        recorded: const SyncedFile(etag: 'W/"1"', size: 10),
      );
      expect(check, isA<UploadConflict>());
      final c = check as UploadConflict;
      expect(c.remoteEtag, 'W/"2"');
      expect(c.recordedEtag, 'W/"1"');
    });

    test('远端已软删除 → remoteDeleted', () {
      final check = precheckUpload(
        remote: _remote('a.md', deleted: true),
        recorded: const SyncedFile(etag: 'W/"1"', size: 10),
      );
      expect(check, isA<UploadRemoteDeleted>());
    });

    test('远端清单里没有该条目 → remoteDeleted（调用方须传全量清单）', () {
      final check = precheckUpload(
        remote: null,
        recorded: const SyncedFile(etag: 'W/"1"', size: 10),
      );
      expect(check, isA<UploadRemoteDeleted>());
    });

    test('任一侧缺 etag → conflict（不把「不知道」说成「没被写过」）', () {
      final missingRemote = precheckUpload(
        remote: _remote('a.md', etag: null),
        recorded: const SyncedFile(etag: 'W/"1"', size: 10),
      );
      expect(
        missingRemote,
        isA<UploadConflict>(),
        reason: '无法证明远端没变，替用户做覆盖决定是不对的',
      );

      final missingRecorded = precheckUpload(
        remote: _remote('a.md', etag: 'W/"1"'),
        recorded: const SyncedFile(size: 10),
      );
      expect(missingRecorded, isA<UploadConflict>());
    });

    test('两边都缺 etag 也是 conflict（不是 clean）', () {
      final check = precheckUpload(
        remote: _remote('a.md', etag: null),
        recorded: const SyncedFile(size: 10),
      );
      expect(check, isA<UploadConflict>());
    });
  });
}
