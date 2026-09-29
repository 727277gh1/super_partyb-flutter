import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 内存下载桩：记录调用，按 fileId 返回内容/304/错误。
///
/// [notModifiedIds] 默认无条件返回 304（用于验证引擎对 304 的处理）。
/// 若打开 [conditionalOnly]，则只在本轮**确实带了** `If-None-Match` 时返回 304
/// —— 那才是真实服务端的行为，用于验证「引擎该不该带 etag」这类判据。
class _StubDownloader implements FileDownloader {
  _StubDownloader({this.notModifiedIds = const {}, this.conditionalOnly = false});

  final Set<String> notModifiedIds;

  /// true = 只在带条件头时返回 304（模拟真实服务端）。
  final bool conditionalOnly;

  final calls = <(String, String?)>[];
  final errors = <String, String>{};

  @override
  Future<SyncDownloadResult> download(String fileId, {String? ifNoneMatch}) async {
    calls.add((fileId, ifNoneMatch));
    final err = errors[fileId];
    if (err != null) throw Exception(err);
    final should304 =
        notModifiedIds.contains(fileId) &&
        (!conditionalOnly || (ifNoneMatch != null && ifNoneMatch.isNotEmpty));
    if (should304) {
      return const SyncDownloadResult.notModified();
    }
    return SyncDownloadResult.downloaded([1, 2, 3, 4, 5]);
  }
}

/// 内存落盘桩：记录写入/删除，可注入失败。
///
/// [exists] 默认按「`written` 里有没有」回答，另外可用 [preExisting] 模拟
/// 「状态里有记录但磁盘上没有 / 上有」这两种真实场景。
class _StubSink implements FileSink {
  _StubSink({Set<String>? preExisting})
    : preExisting = preExisting ?? const <String>{};

  final written = <String, List<int>>{};
  final deleted = <String>[];
  final failWrite = <String>{};
  final failDelete = <String>{};

  /// 额外视为「磁盘上已存在」的路径（模拟上次同步留下的文件）。
  final Set<String> preExisting;

  @override
  Future<void> write(String relPath, List<int> bytes) async {
    if (failWrite.contains(relPath)) throw Exception('磁盘满了');
    written[relPath] = bytes;
  }

  @override
  Future<void> delete(String relPath) async {
    if (failDelete.contains(relPath)) throw Exception('权限不足');
    deleted.add(relPath);
    written.remove(relPath);
  }

  @override
  Future<bool> exists(String relPath) async =>
      written.containsKey(relPath) || preExisting.contains(relPath);
}

/// 内存状态库（`SyncStateStore` 的最小实现，用于范围/目录变更语义）。
class _MemoryStateStore implements SyncStateStore {
  final _data = <String, SyncState>{};
  int resetAllCount = 0;

  @override
  Future<SyncState> load(String key) async => _data[key] ?? SyncState.empty;

  @override
  Future<void> save(String key, SyncState state) async => _data[key] = state;

  @override
  Future<void> reset(String key) async => _data.remove(key);

  @override
  Future<void> resetAll() async {
    resetAllCount++;
    _data.clear();
  }
}

const _gid = 'g1';

/// 构造远端条目。
///
/// `path` 默认带**尾斜杠**——这是 UFS 实测行为（`buildMaterializedPath`
/// 无条件拼 `name + '/'`），不带的话测试会掩盖真实场景。
UfsFileEntry _remote(
  String rel, {
  String? id,
  int size = 10,
  String? mime = 'text/markdown',
  String? etag = 'W/"1"',
  String updatedAt = '2026-01-01T00:00:00Z',
  bool deleted = false,
  bool directory = false,
}) => UfsFileEntry.fromJson({
  'id': id ?? 'id-$rel',
  'path': '/workspace/groups/$_gid/$rel/',
  'name': rel.split('/').last,
  'size': size,
  'mime_type': mime,
  'is_directory': directory,
  if (etag != null) 'etag': etag,
  'updated_at': updatedAt,
  if (deleted) 'deleted_at': '2026-02-01T00:00:00Z',
});

SyncState _stateWith(Map<String, SyncedFile> files, {String? cursor}) =>
    SyncState(cursor: cursor, files: files);

const _permissive = SyncFilterConfig(maxFileSize: 0, includeMedia: true);

void main() {
  // =========================================================================
  group('同步计划：增量与游标', () {
    test('首次同步（空状态）为每个文件安排下载', () {
      final plan = buildSyncPlan(
        remote: [_remote('a.md'), _remote('b.md')],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.downloadCount, 2);
      expect(plan.deleteCount, 0);
      expect(plan.skipped, isEmpty);
    });

    test('etag 相同则跳过（未变更不计入 skipped，避免摘要噪音）', () {
      final plan = buildSyncPlan(
        remote: [_remote('a.md', etag: 'W/"1"', size: 10)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped, isEmpty);
    });

    test('etag 变即重新下载，即使 size 相同（改一个字不改 size）', () {
      final plan = buildSyncPlan(
        remote: [_remote('a.md', etag: 'W/"2"', size: 10)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.downloadCount, 1);
    });

    test('任一侧缺 etag 时退化为 size 比对（宁可多下一次，不可漏更新）', () {
      // 服务端 etag 缺失
      final plan = buildSyncPlan(
        remote: [_remote('a.md', etag: null, size: 10)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);

      // size 不同 → 变更
      final plan2 = buildSyncPlan(
        remote: [_remote('a.md', etag: null, size: 11)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan2.downloadCount, 1);
    });

    test('未知路径一律视为已变更（否则新文件永不落盘）', () {
      final plan = buildSyncPlan(
        remote: [_remote('never.md', etag: 'W/"1"', size: 10)],
        state: _stateWith({
          'other.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.downloadCount, 1);
    });

    test('游标只前进不回退（单调性）', () {
      final s = SyncState(cursor: '2026-03-01T00:00:00Z');
      expect(
        s.advanceCursor('2026-04-01T00:00:00Z').cursor,
        '2026-04-01T00:00:00Z',
      );
      // 更早的时间不得覆盖游标
      expect(
        s.advanceCursor('2026-01-01T00:00:00Z').cursor,
        '2026-03-01T00:00:00Z',
      );
      // 相等也不动（避免无意义的写库）
      expect(
        identical(s.advanceCursor('2026-03-01T00:00:00Z'), s),
        isTrue,
      );
      // null / 空串不推进（无 updated_at 的条目不该污染水位线）
      expect(s.advanceCursor(null).cursor, '2026-03-01T00:00:00Z');
      expect(s.advanceCursor('').cursor, '2026-03-01T00:00:00Z');
    });

    test('同步成功后游标推进到本批最大 updated_at，且状态记录写入', () async {
      final sink = _StubSink();
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [
          _remote('a.md', updatedAt: '2026-05-01T00:00:00Z'),
          _remote('b.md', updatedAt: '2026-05-03T00:00:00Z'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.downloaded, 2);
      expect(result.state.cursor, '2026-05-03T00:00:00Z');
      expect(result.state.contains('a.md'), isTrue);
      expect(result.state.contains('b.md'), isTrue);
      expect(sink.written.keys.toSet(), {'a.md', 'b.md'});
    });

    test('游标使用服务端原始字符串（不经过 DateTime 往返丢精度）', () {
      // Go 的 time.Time 序列化到纳秒；Dart DateTime 只到微秒。
      // 若用 DateTime 反格式化，游标会丢后三位 → 该文件每轮重复出现。
      const nanos = '2026-05-01T00:00:00.123456789Z';
      final entry = _remote('a.md', updatedAt: nanos);
      expect(entry.updatedAtRaw, nanos);
      expect(
        entry.updatedAt!.toUtc().toIso8601String(),
        isNot(contains('123456789')),
        reason: 'Dart DateTime 精度不足，这正是不能用它当游标的原因',
      );

      final plan = buildSyncPlan(
        remote: [entry],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      final dl = plan.actions.whereType<SyncDownload>().single;
      expect(dl.updatedAt, nanos);
    });

    test('服务端 updated_since 是含等号比较：游标处文件每轮重复出现，靠 etag 跳过', () async {
      // 这是增量同步的稳态：同一批文件连续同步两轮，第二轮必须 0 下载。
      final sink = _StubSink();
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final remote = [_remote('a.md', updatedAt: '2026-05-01T00:00:00Z')];

      final first = await engine.run(
        remote: remote,
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(first.report.downloaded, 1);

      // 第二轮：游标推进后清单仍含该文件（>= 语义），etag 命中 → 不再下载
      final second = await engine.run(
        remote: remote,
        state: first.state,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(second.report.downloaded, 0);
      expect(second.report.notModified, 0);
      expect(sink.written, hasLength(1));
    });
  });

  // =========================================================================
  group('同步计划：删除语义', () {
    test('只凭 deleted_at 判删除：清单缺席绝不删除', () {
      // 增量清单只含变化条目。「清单里没有」≠「远端已删」。
      // 若用缺席推断，会把所有本轮没变化的文件当成删除项，删光本地内容。
      final plan = buildSyncPlan(
        remote: [_remote('new.md', etag: 'W/"9"')],
        state: _stateWith({
          'old.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.deleteCount, 0);
      expect(plan.downloadCount, 1);
    });

    test('deleted_at 非空且本地有副本 → 安排删除', () {
      final plan = buildSyncPlan(
        remote: [_remote('a.md', deleted: true)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.deleteCount, 1);
      expect((plan.actions.single as SyncDelete).relPath, 'a.md');
    });

    test('deleted_at 非空但本地从无副本 → 无事可做（不是错误）', () {
      final plan = buildSyncPlan(
        remote: [_remote('never.md', deleted: true)],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped, isEmpty, reason: '远端删除不该被当成异常上报');
    });

    test('删除优先于体积/媒体等跳过条件（否则本地旧副本残留）', () {
      // 软删除条目同样带 size/mime。若先按体积跳过，本地旧副本会因
      // 「跳过」而残留 —— 远端删了本地还在。
      final plan = buildSyncPlan(
        remote: [
          _remote('big.md', deleted: true, size: 99_999_999),
          _remote('pic.png', deleted: true, mime: 'image/png'),
        ],
        state: _stateWith({
          'big.md': const SyncedFile(etag: 'W/"1"', size: 10),
          'pic.png': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: const SyncFilterConfig(), // 默认：10MB 上限 + 不同步媒体
      );
      expect(plan.deleteCount, 2);
      expect(plan.skipped, isEmpty);
    });

    test('先删后写：同一路径同时出现删除与下载时下载胜出（远端为准）', () {
      // 极端竞态：远端先删后重建。删除动作排在下载之前，最终状态是下载。
      final plan = buildSyncPlan(
        remote: [
          _remote('a.md', etag: 'W/"1"'),
          _remote('gone.md', deleted: true),
        ],
        state: _stateWith({
          'gone.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.actions.first, isA<SyncDelete>());
      expect(plan.actions.last, isA<SyncDownload>());
    });

    test('删除成功后移除记录，失败则保留（下轮重试）', () async {
      final sink = _StubSink();
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final state = _stateWith({
        'ok.md': const SyncedFile(etag: 'W/"1"', size: 10),
        'bad.md': const SyncedFile(etag: 'W/"1"', size: 10),
      });
      sink.failDelete.add('bad.md');

      final result = await engine.run(
        remote: [
          _remote('ok.md', deleted: true),
          _remote('bad.md', deleted: true),
        ],
        state: state,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.deleted, 1);
      expect(result.report.failed, hasLength(1));
      expect(result.state.contains('ok.md'), isFalse, reason: '删除成功应移除记录');
      expect(
        result.state.contains('bad.md'),
        isTrue,
        reason: '删除失败必须保留记录，否则本地残留文件永远无人清理',
      );
    });
  });

  // =========================================================================
  group('同步计划：过滤规则', () {
    test('跳过 reports/tts/** 机器产物', () {
      final plan = buildSyncPlan(
        remote: [
          _remote('reports/tts/turn1/speech_1.mp3', mime: 'audio/mpeg'),
          _remote('reports/ok.md'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.downloadCount, 1);
      expect(plan.skipped[SyncSkipReason.machineGenerated], 1);
    });

    test('tts 前缀锚定在开头（x/reports/tts/ 不误伤）', () {
      expect(isMachineGenerated('reports/tts/a.mp3'), isTrue);
      expect(isMachineGenerated('x/reports/tts/a.mp3'), isFalse);
      expect(isMachineGenerated('reports/ttsx/a.md'), isFalse);
      expect(isMachineGenerated('reports/a.md'), isFalse);
    });

    test('媒体默认不同步，开启后放行', () {
      final strict = buildSyncPlan(
        remote: [_remote('pic.png', mime: 'image/png')],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: const SyncFilterConfig(),
      );
      expect(strict.skipped[SyncSkipReason.mediaExcluded], 1);

      final permissive = buildSyncPlan(
        remote: [_remote('pic.png', mime: 'image/png')],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(permissive.downloadCount, 1);
    });

    test('媒体判定覆盖三类且忽略 charset 参数', () {
      expect(isMediaMime('image/png'), isTrue);
      expect(isMediaMime('audio/mpeg'), isTrue);
      expect(isMediaMime('video/mp4'), isTrue);
      expect(isMediaMime('IMAGE/PNG'), isTrue);
      expect(isMediaMime('image/svg+xml; charset=utf-8'), isTrue);
      expect(isMediaMime('text/markdown'), isFalse);
      expect(isMediaMime('application/pdf'), isFalse);
      expect(isMediaMime(null), isFalse);
    });

    test('单文件上限过滤，0 表示不限，边界含等号', () {
      final limited = buildSyncPlan(
        remote: [
          _remote('big.pdf', size: 2048, mime: 'application/pdf'),
          _remote('edge.pdf', size: 1024, mime: 'application/pdf'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: const SyncFilterConfig(maxFileSize: 1024, includeMedia: true),
      );
      expect(limited.downloadCount, 1, reason: '1024 恰好等于上限，应放行');
      expect(limited.skipped[SyncSkipReason.tooLarge], 1);

      final unlimited = buildSyncPlan(
        remote: [_remote('huge.pdf', size: 1 << 40, mime: 'application/pdf')],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
      );
      expect(unlimited.downloadCount, 1);
    });

    test('目录归类为 directory，不报「路径不合法」', () {
      // UFS 列表会包含 group 根目录自身，它解析不出相对路径。
      // 若先解析路径再判目录，用户会看到「跳过：1 路径不合法」这种像出错的提示。
      final root = UfsFileEntry.fromJson({
        'id': 'root',
        'path': '/workspace/groups/$_gid/',
        'name': _gid,
        'size': 0,
        'is_directory': true,
      });
      final plan = buildSyncPlan(
        remote: [root, _remote('reports', directory: true)],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped[SyncSkipReason.directory], 2);
      expect(plan.skipped.containsKey(SyncSkipReason.invalidPath), isFalse);
    });

    test('不属于该范围的路径计入 invalidPath（不静默丢弃）', () {
      final foreign = UfsFileEntry.fromJson({
        'id': 'x',
        'path': '/workspace/groups/other-group/a.md/',
        'name': 'a.md',
        'size': 1,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final plan = buildSyncPlan(
        remote: [foreign],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped[SyncSkipReason.invalidPath], 1);
    });

    test('跳过原因有中文说明（摘要可读）', () {
      for (final r in SyncSkipReason.values) {
        expect(r.description, isNotEmpty);
      }
    });
  });

  // =========================================================================
  group('同步范围与状态键', () {
    test('单 group 剥掉前缀，workspace 保留 groupId 段', () {
      expect(
        const SyncGroupScope(_gid).relativePath('/workspace/groups/g1/a.md/'),
        'a.md',
      );
      expect(
        const SyncWorkspaceScope().relativePath('/workspace/groups/g1/a.md/'),
        'g1/a.md',
      );
    });

    test('workspace 下不同 group 的同名文件落到不同路径（不互相覆盖）', () {
      final plan = buildSyncPlan(
        remote: [
          UfsFileEntry.fromJson({
            'id': 'a',
            'path': '/workspace/groups/ga/README.md/',
            'name': 'README.md',
            'size': 10,
            'updated_at': '2026-01-01T00:00:00Z',
          }),
          UfsFileEntry.fromJson({
            'id': 'b',
            'path': '/workspace/groups/gb/README.md/',
            'name': 'README.md',
            'size': 10,
            'updated_at': '2026-01-01T00:00:00Z',
          }),
        ],
        state: SyncState.empty,
        scope: const SyncWorkspaceScope(),
        filter: _permissive,
      );
      final paths = plan.actions.map((a) => a.relPath).toSet();
      expect(paths, {'ga/README.md', 'gb/README.md'});
    });

    test('选中若干 group：保留前缀但过滤未选中的', () {
      final scope = const SyncGroupsScope(['ga', 'gc']);
      expect(scope.relativePath('/workspace/groups/ga/a.md/'), 'ga/a.md');
      expect(scope.relativePath('/workspace/groups/gb/a.md/'), isNull);

      UfsFileEntry mk(String gid) => UfsFileEntry.fromJson({
        'id': 'id-$gid',
        'path': '/workspace/groups/$gid/README.md/',
        'name': 'README.md',
        'size': 10,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final plan = buildSyncPlan(
        remote: [mk('ga'), mk('gb'), mk('gc')],
        state: SyncState.empty,
        scope: scope,
        filter: _permissive,
      );
      final paths = plan.actions.map((a) => a.relPath).toList()..sort();
      expect(paths, ['ga/README.md', 'gc/README.md']);
      expect(
        plan.skipped[SyncSkipReason.invalidPath],
        1,
        reason: '未选中的 group 要计入摘要，便于用户理解「为什么少了文件」',
      );
    });

    test('选中列表为空则什么都不同步（不退化成为「全部」）', () {
      // 安全的一侧是「什么都不做」。
      const scope = SyncGroupsScope([]);
      expect(scope.relativePath('/workspace/groups/g1/a.md/'), isNull);
    });

    test('范围切换共用状态键：全部 ↔ 选中若干不重置状态', () {
      // 这是本任务的关键不变量：若为「选中」单开状态键，用户在两种模式间
      // 切换就会来回全量重拉。
      expect(syncStateKeyFor(const SyncWorkspaceScope()), workspaceStateKey);
      expect(
        syncStateKeyFor(const SyncGroupsScope(['a', 'b'])),
        workspaceStateKey,
      );
      // 单 group 模式落盘布局不同，必须分开
      expect(syncStateKeyFor(const SyncGroupScope('g1')), 'g1');
      expect(
        syncStateKeyFor(const SyncGroupScope('g1')),
        isNot(workspaceStateKey),
      );
    });

    test('范围切换后 etag 记录仍生效（不会重新下载）', () async {
      // 模拟：先「全部」同步 A、B，再切到「只选 A」同步。
      // A 因 etag 命中不重下，B 的文件与状态都保留。
      final sink = _StubSink();
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final remoteAll = [
        UfsFileEntry.fromJson({
          'id': 'a',
          'path': '/workspace/groups/ga/a.md/',
          'name': 'a.md',
          'size': 5,
          'etag': 'W/"1"',
          'updated_at': '2026-01-01T00:00:00Z',
        }),
        UfsFileEntry.fromJson({
          'id': 'b',
          'path': '/workspace/groups/gb/b.md/',
          'name': 'b.md',
          'size': 5,
          'etag': 'W/"1"',
          'updated_at': '2026-01-01T00:00:00Z',
        }),
      ];

      final first = await engine.run(
        remote: remoteAll,
        state: SyncState.empty,
        scope: const SyncWorkspaceScope(),
        filter: _permissive,
      );
      expect(first.report.downloaded, 2);

      // 切到「只选 ga」——同一状态键，同一状态对象
      final second = await engine.run(
        remote: remoteAll,
        state: first.state,
        scope: const SyncGroupsScope(['ga']),
        filter: _permissive,
      );
      expect(second.report.downloaded, 0, reason: '范围切换不该触发重新下载');
      expect(
        second.state.contains('gb/b.md'),
        isTrue,
        reason: '未选中 group 的状态条目必须保留，否则选回来时会全量重拉',
      );
    });
  });

  // =========================================================================
  group('同步目录变更重置状态', () {
    test('换目录必须重置；同目录与首次绑定不重置', () {
      expect(
        mustResetStateForLocalRoot(previousRoot: '/a', nextRoot: '/b'),
        isTrue,
      );
      // 首次绑定：库里本就没有状态，无需重置
      expect(
        mustResetStateForLocalRoot(previousRoot: null, nextRoot: '/a'),
        isFalse,
      );
      // 同目录重复保存（幂等）
      expect(
        mustResetStateForLocalRoot(previousRoot: '/a', nextRoot: '/a'),
        isFalse,
      );
      // 解除绑定：也视为变更
      expect(
        mustResetStateForLocalRoot(previousRoot: '/a', nextRoot: null),
        isTrue,
      );
    });

    test('换目录时清空全部状态（否则新目录同步显示成功却是空的）', () async {
      final store = _MemoryStateStore();
      await store.save(
        workspaceStateKey,
        SyncState(cursor: '2026-03-01T00:00:00Z').markSynced(
          'g1/a.md',
          etag: 'W/"1"',
          size: 10,
        ),
      );

      final reset = await applyLocalRootChange(
        store: store,
        previousRoot: '/old',
        nextRoot: '/new',
      );

      expect(reset, isTrue);
      expect(store.resetAllCount, 1);
      final after = await store.load(workspaceStateKey);
      expect(after.cursor, isNull, reason: '保留游标会让新目录几乎什么都拿不到');
      expect(after.files, isEmpty, reason: '保留 etag 会让文件被判未变更而跳过写入');
    });

    test('同目录重复保存不清状态（避免无谓全量重下）', () async {
      final store = _MemoryStateStore();
      await store.save(
        workspaceStateKey,
        SyncState(cursor: '2026-03-01T00:00:00Z'),
      );
      final reset = await applyLocalRootChange(
        store: store,
        previousRoot: '/a',
        nextRoot: '/a',
      );
      expect(reset, isFalse);
      expect(store.resetAllCount, 0);
      expect((await store.load(workspaceStateKey)).cursor, isNotNull);
    });
  });

  // =========================================================================
  group('同步执行：失败与状态不变量', () {
    test('失败项不写状态（否则永久漏更新）', () async {
      final sink = _StubSink();
      final downloader = _StubDownloader();
      downloader.errors['bad'] = '网络超时';
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [
          UfsFileEntry.fromJson({
            'id': 'ok',
            'path': '/workspace/groups/$_gid/ok.md/',
            'name': 'ok.md',
            'size': 5,
            'etag': 'W/"1"',
            'updated_at': '2026-05-01T00:00:00Z',
          }),
          UfsFileEntry.fromJson({
            'id': 'bad',
            'path': '/workspace/groups/$_gid/bad.md/',
            'name': 'bad.md',
            'size': 5,
            'etag': 'W/"2"',
            'updated_at': '2026-05-09T00:00:00Z',
          }),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.downloaded, 1);
      expect(result.report.failed, hasLength(1));
      expect(result.report.failed.single.relPath, 'bad.md');
      expect(
        result.state.contains('bad.md'),
        isFalse,
        reason: '失败项若写状态，下轮 etag 命中会被跳过 → 永久漏更新',
      );
      // 失败不阻断其余文件
      expect(result.state.contains('ok.md'), isTrue);
    });

    test('失败项不推进游标（否则该文件被下轮 updated_since 过滤掉）', () async {
      final sink = _StubSink();
      final downloader = _StubDownloader();
      downloader.errors['bad'] = '网络超时';
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [
          UfsFileEntry.fromJson({
            'id': 'ok',
            'path': '/workspace/groups/$_gid/ok.md/',
            'name': 'ok.md',
            'size': 5,
            'updated_at': '2026-05-01T00:00:00Z',
          }),
          // 失败项的 updated_at 更晚：若用计划里最大时间推进游标，
          // 就会越过它，下轮再也拉不到这个文件。
          UfsFileEntry.fromJson({
            'id': 'bad',
            'path': '/workspace/groups/$_gid/bad.md/',
            'name': 'bad.md',
            'size': 5,
            'updated_at': '2026-05-09T00:00:00Z',
          }),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.failed, hasLength(1));
      expect(
        result.state.cursor,
        '2026-05-01T00:00:00Z',
        reason: '游标只能由成功项推进，否则失败文件会被增量过滤掉',
      );
    });

    test('写入失败同样不写状态、不推进游标', () async {
      final sink = _StubSink()..failWrite.add('a.md');
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);

      final result = await engine.run(
        remote: [_remote('a.md', updatedAt: '2026-05-01T00:00:00Z')],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.failed, hasLength(1));
      expect(result.state.contains('a.md'), isFalse);
      expect(result.state.cursor, isNull);
    });

    test('用实际写入字节数记状态（服务端 size 不符时以本地事实为准）', () async {
      final sink = _StubSink();
      // 桩返回 5 字节，但清单声明 size = 999
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [_remote('a.md', size: 999)],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(result.state.files['a.md']!.size, 5);
    });

    test('304 视为成功：刷新状态但不写入文件', () async {
      final sink = _StubSink();
      final engine = SyncEngine(
        downloader: _StubDownloader(notModifiedIds: {'id-a.md'}),
        sink: sink,
      );
      final result = await engine.run(
        remote: [_remote('a.md', etag: 'W/"1"', size: 10)],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.notModified, 1);
      expect(result.report.downloaded, 0);
      expect(sink.written, isEmpty, reason: '304 不得写入本地（会覆盖成空文件）');
      expect(
        result.state.contains('a.md'),
        isTrue,
        reason: '304 仍要刷新状态（etag 可能刚被服务端补上）',
      );
    });

    test('首次同步绝不带 If-None-Match（否则 304 骗成「未变更」，文件永不落盘）', () async {
      // 这个 bug 曾在 Tauri 端真实发生：首次同步 0 个文件落盘却报「未变更 9 个」。
      final sink = _StubSink();
      final downloader = _StubDownloader(notModifiedIds: {'id-a.md'});
      final engine = SyncEngine(downloader: downloader, sink: sink);

      await engine.run(
        remote: [_remote('a.md', etag: 'W/"1"')],
        state: SyncState.empty, // 本地无副本
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(downloader.calls.single.$2, isNull);
    });

    test('本地已有副本时带 If-None-Match（省流量）', () async {
      // 「本地有副本」= 磁盘上真有文件（preExisting），**不是**「状态里有记录」。
      final sink = _StubSink(preExisting: {'a.md'});
      final downloader = _StubDownloader();
      final engine = SyncEngine(downloader: downloader, sink: sink);

      await engine.run(
        remote: [_remote('a.md', etag: 'W/"1"', size: 10)],
        // 状态里有记录但 etag 不同 → 会下载，且本地「有副本」
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"0"', size: 9),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(downloader.calls.single.$2, 'W/"1"');
    });

    test('状态里有记录但本地文件已被删 → 必须发无条件请求，文件重新落盘', () async {
      // ## 回归测试（真实 bug）
      //
      // 原实现用 `state.contains(relPath)` 决定是否带 If-None-Match，而它表达的是
      // 「曾经同步过」而非「磁盘上现在有」。用户手动删掉文件（或清理只删文件、
      // 没清状态）后，引擎仍带 etag → 服务端 304 → 当作「未变更」跳过写入 →
      // **文件永远回不来**，报告却显示「未变更 1 个」。
      //
      // 对齐 Tauri 端 `sync/engine.rs` 的 `target.exists()` 判据。
      final sink = _StubSink(); // 磁盘上没有文件
      // 模拟真实服务端：只有带了 If-None-Match 才会回 304。
      final downloader = _StubDownloader(
        notModifiedIds: {'id-a.md'},
        conditionalOnly: true,
      );
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [_remote('a.md', etag: 'W/"1"', size: 10)],
        // 状态里的 etag 与远端一致（看起来「已同步」），但文件不在磁盘上
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(
        downloader.calls.single.$2,
        isNull,
        reason: '本地无副本时必须发无条件请求，否则 304 会把文件判成「未变更」',
      );
      expect(
        result.report.downloaded,
        1,
        reason: '文件应被真正重新写入，而不是记成「未变更」',
      );
      expect(sink.written.containsKey('a.md'), isTrue);
    });

    test('计划为空时不产生任何写入（定时同步不刷无意义磁盘 IO）', () async {
      // 「无事可做」的前提是**磁盘上真有文件**：状态与远端一致**且**本地副本存在。
      // 只满足前者时本轮会重新下载（那正是「本地文件被删后必须能自愈」的行为）。
      final sink = _StubSink(preExisting: {'a.md'});
      final downloader = _StubDownloader();
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [_remote('a.md', etag: 'W/"1"', size: 10)],
        state: _stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );

      expect(result.report.downloaded, 0);
      expect(downloader.calls, isEmpty);
      expect(sink.written, isEmpty);
    });

    test('报告摘要包含各计数与跳过原因', () async {
      final sink = _StubSink();
      final engine = SyncEngine(downloader: _StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [
          _remote('a.md'),
          _remote('pic.png', mime: 'image/png'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: const SyncFilterConfig(),
      );
      final summary = result.report.summarize();
      expect(summary, contains('下载 1 个'));
      expect(summary, contains('媒体（未开启）'));
      expect(result.report.hasFailures, isFalse);
    });
  });

  // =========================================================================
  group('同步路径：穿越防御', () {
    test('剥尾斜杠（UFS 对文件也返回尾斜杠，不剥会让全部文件被判非法）', () {
      expect(
        groupRelativePath('/workspace/groups/g1/README.md/', 'g1'),
        'README.md',
      );
      expect(
        groupRelativePath('/workspace/groups/g1/reports/a/b.md/', 'g1'),
        'reports/a/b.md',
      );
      expect(
        groupRelativePath('/workspace/groups/g1/a.md///', 'g1'),
        'a.md',
      );
    });

    test('拒绝父目录逃逸 / 当前目录段 / 空段（含深层）', () {
      expect(groupRelativePath('/workspace/groups/g1/../secret', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/./x', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/a//b', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/a/../../x', 'g1'), isNull);
      // 剥尾斜杠不能变成绕过校验的捷径
      expect(groupRelativePath('/workspace/groups/g1/../secret/', 'g1'), isNull);
    });

    test('拒绝 Windows 分隔符与 NUL（绕过段级校验的两种方式）', () {
      expect(groupRelativePath('/workspace/groups/g1/a\\..\\..\\x', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/a\u0000b', 'g1'), isNull);
    });

    test('拒绝 group 根目录自身与空 groupId', () {
      expect(groupRelativePath('/workspace/groups/g1/', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups//x.md', ''), isNull);
    });

    test('拒绝不属于该 group / 前缀不符', () {
      expect(groupRelativePath('/workspace/groups/other/a.md', 'g1'), isNull);
      expect(groupRelativePath('/other/path.md', 'g1'), isNull);
      expect(groupRelativePath('', 'g1'), isNull);
    });

    test('workspace 路径拒绝 group 根目录与 groups 根', () {
      expect(workspaceRelativePath('/workspace/groups/g1/'), isNull);
      expect(workspaceRelativePath('/workspace/groups/'), isNull);
      expect(workspaceRelativePath('/workspace/groups'), isNull);
      expect(workspaceRelativePath('/other/x.md'), isNull);
    });

    test('workspace 路径同样拦截穿越（groupId 段与尾段）', () {
      expect(workspaceRelativePath('/workspace/groups/../etc/passwd/'), isNull);
      expect(workspaceRelativePath('/workspace/groups/./x/'), isNull);
      expect(workspaceRelativePath('/workspace/groups/g1/../secret/'), isNull);
      expect(workspaceRelativePath('/workspace/groups/g1/a//b/'), isNull);
      expect(workspaceRelativePath('/workspace/groups/a\\b/x/'), isNull);
    });

    test('非法路径不进入计划（落盘层拿到的 relPath 已被证明安全）', () {
      final evil = UfsFileEntry.fromJson({
        'id': 'evil',
        'path': '/workspace/groups/$_gid/../../etc/passwd/',
        'name': 'passwd',
        'size': 10,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final plan = buildSyncPlan(
        remote: [evil],
        state: SyncState.empty,
        scope: const SyncGroupScope(_gid),
        filter: _permissive,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped[SyncSkipReason.invalidPath], 1);
    });
  });

  // =========================================================================
  group('同步状态值类型', () {
    test('markSynced / forget 是不可变的（不改自身）', () {
      final base = SyncState.empty;
      final next = base.markSynced('a.md', etag: 'W/"1"', size: 10);
      expect(base.files, isEmpty, reason: '计划阶段必须基于执行前的事实');
      expect(next.files, hasLength(1));
      expect(next.forget('a.md').files, isEmpty);
      expect(next.files, hasLength(1));
    });

    test('isUnchanged 委托给 SyncedFile.matches', () {
      final s = SyncState.empty.markSynced('a.md', etag: 'W/"1"', size: 10);
      expect(s.isUnchanged('a.md', etag: 'W/"1"', size: 10), isTrue);
      expect(s.isUnchanged('a.md', etag: 'W/"2"', size: 10), isFalse);
      expect(s.isUnchanged('nope.md', etag: 'W/"1"', size: 10), isFalse);
    });

    test('SyncState 相等性按内容比较（含文件记录）', () {
      final a = SyncState.empty.markSynced('x.md', etag: 'W/"1"', size: 1);
      final b = SyncState.empty.markSynced('x.md', etag: 'W/"1"', size: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == SyncState.empty, isFalse);
    });
  });
}
