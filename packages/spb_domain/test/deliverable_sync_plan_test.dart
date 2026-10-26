import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

/// 交付物同步计划：增量游标 / 删除语义 / 过滤规则
///
/// ⚠️ 本文件由 `deliverable_sync_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/deliverable_sync_harness.dart`。
void main() {
  group('同步计划：增量与游标', () {
    test('首次同步（空状态）为每个文件安排下载', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('a.md'), remoteFixture('b.md')],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.downloadCount, 2);
      expect(plan.deleteCount, 0);
      expect(plan.skipped, isEmpty);
    });

    test('etag 相同则跳过（未变更不计入 skipped，避免摘要噪音）', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped, isEmpty);
    });

    test('etag 变即重新下载，即使 size 相同（改一个字不改 size）', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('a.md', etag: 'W/"2"', size: 10)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.downloadCount, 1);
    });

    test('任一侧缺 etag 时退化为 size 比对（宁可多下一次，不可漏更新）', () {
      // 服务端 etag 缺失
      final plan = buildSyncPlan(
        remote: [remoteFixture('a.md', etag: null, size: 10)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.isEmpty, isTrue);

      // size 不同 → 变更
      final plan2 = buildSyncPlan(
        remote: [remoteFixture('a.md', etag: null, size: 11)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan2.downloadCount, 1);
    });

    test('未知路径一律视为已变更（否则新文件永不落盘）', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('never.md', etag: 'W/"1"', size: 10)],
        state: stateWith({
          'other.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.downloadCount, 1);
    });

    test('游标只前进不回退（单调性）', () {
      const s = SyncState(cursor: '2026-03-01T00:00:00Z');
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
      expect(identical(s.advanceCursor('2026-03-01T00:00:00Z'), s), isTrue);
      // null / 空串不推进（无 updated_at 的条目不该污染水位线）
      expect(s.advanceCursor(null).cursor, '2026-03-01T00:00:00Z');
      expect(s.advanceCursor('').cursor, '2026-03-01T00:00:00Z');
    });

    test('同步成功后游标推进到本批最大 updated_at，且状态记录写入', () async {
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [
          remoteFixture('a.md', updatedAt: '2026-05-01T00:00:00Z'),
          remoteFixture('b.md', updatedAt: '2026-05-03T00:00:00Z'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
      final entry = remoteFixture('a.md', updatedAt: nanos);
      expect(entry.updatedAtRaw, nanos);
      expect(
        entry.updatedAt!.toUtc().toIso8601String(),
        isNot(contains('123456789')),
        reason: 'Dart DateTime 精度不足，这正是不能用它当游标的原因',
      );

      final plan = buildSyncPlan(
        remote: [entry],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      final dl = plan.actions.whereType<SyncDownload>().single;
      expect(dl.updatedAt, nanos);
    });

    test('服务端 updated_since 是含等号比较：游标处文件每轮重复出现，靠 etag 跳过', () async {
      // 这是增量同步的稳态：同一批文件连续同步两轮，第二轮必须 0 下载。
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final remote = [remoteFixture('a.md', updatedAt: '2026-05-01T00:00:00Z')];

      final first = await engine.run(
        remote: remote,
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(first.report.downloaded, 1);

      // 第二轮：游标推进后清单仍含该文件（>= 语义），etag 命中 → 不再下载
      final second = await engine.run(
        remote: remote,
        state: first.state,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(second.report.downloaded, 0);
      expect(second.report.notModified, 0);
      expect(sink.written, hasLength(1));
    });
  });
  group('同步计划：删除语义', () {
    test('只凭 deleted_at 判删除：清单缺席绝不删除', () {
      // 增量清单只含变化条目。「清单里没有」≠「远端已删」。
      // 若用缺席推断，会把所有本轮没变化的文件当成删除项，删光本地内容。
      final plan = buildSyncPlan(
        remote: [remoteFixture('new.md', etag: 'W/"9"')],
        state: stateWith({'old.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.deleteCount, 0);
      expect(plan.downloadCount, 1);
    });

    test('deleted_at 非空且本地有副本 → 安排删除', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('a.md', deleted: true)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.deleteCount, 1);
      expect((plan.actions.single as SyncDelete).relPath, 'a.md');
    });

    test('deleted_at 非空但本地从无副本 → 无事可做（不是错误）', () {
      final plan = buildSyncPlan(
        remote: [remoteFixture('never.md', deleted: true)],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped, isEmpty, reason: '远端删除不该被当成异常上报');
    });

    test('删除优先于体积/媒体等跳过条件（否则本地旧副本残留）', () {
      // 软删除条目同样带 size/mime。若先按体积跳过，本地旧副本会因
      // 「跳过」而残留 —— 远端删了本地还在。
      final plan = buildSyncPlan(
        remote: [
          remoteFixture('big.md', deleted: true, size: 99_999_999),
          remoteFixture('pic.png', deleted: true, mime: 'image/png'),
        ],
        state: stateWith({
          'big.md': const SyncedFile(etag: 'W/"1"', size: 10),
          'pic.png': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(gidFixture),
        filter: const SyncFilterConfig(), // 默认：10MB 上限 + 不同步媒体
      );
      expect(plan.deleteCount, 2);
      expect(plan.skipped, isEmpty);
    });

    test('先删后写：同一路径同时出现删除与下载时下载胜出（远端为准）', () {
      // 极端竞态：远端先删后重建。删除动作排在下载之前，最终状态是下载。
      final plan = buildSyncPlan(
        remote: [
          remoteFixture('a.md', etag: 'W/"1"'),
          remoteFixture('gone.md', deleted: true),
        ],
        state: stateWith({
          'gone.md': const SyncedFile(etag: 'W/"1"', size: 10),
        }),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.actions.first, isA<SyncDelete>());
      expect(plan.actions.last, isA<SyncDownload>());
    });

    test('删除成功后移除记录，失败则保留（下轮重试）', () async {
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final state = stateWith({
        'ok.md': const SyncedFile(etag: 'W/"1"', size: 10),
        'bad.md': const SyncedFile(etag: 'W/"1"', size: 10),
      });
      sink.failDelete.add('bad.md');

      final result = await engine.run(
        remote: [
          remoteFixture('ok.md', deleted: true),
          remoteFixture('bad.md', deleted: true),
        ],
        state: state,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
  group('同步计划：过滤规则', () {
    test('跳过 reports/tts/** 机器产物', () {
      final plan = buildSyncPlan(
        remote: [
          remoteFixture('reports/tts/turn1/speech_1.mp3', mime: 'audio/mpeg'),
          remoteFixture('reports/ok.md'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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

    test('workspace 布局下 TTS 同样被跳过（不靠落盘路径判）', () {
      // ## 为什么这条必须存在
      //
      // 曾经 `shouldSync` 拿的是**落盘相对路径**（`{gid}/reports/tts/a.mp3`），
      // 而 `isMachineGenerated` 的前缀锚定在开头 → 永远命中不了。于是同一份
      // TTS 语音在 `SyncGroupScope` 下被跳过、在定向/全范围同步下却被拖下来
      // （生产实测 312 个 TTS 文件）。
      //
      // 现在判据改从 `file.path` 派生 group 内路径，两种布局结论一致。
      final plan = buildSyncPlan(
        remote: [
          remoteFixture('reports/tts/turn1/speech_1.mp3', mime: 'audio/mpeg'),
          remoteFixture('reports/ok.md'),
        ],
        state: SyncState.empty,
        scope: const SyncWorkspaceScope(),
        filter: permissiveFixture,
      );
      expect(plan.downloadCount, 1, reason: '只有 reports/ok.md 该下载');
      expect(plan.skipped[SyncSkipReason.machineGenerated], 1);
      expect(
        plan.actions.whereType<SyncDownload>().map((a) => a.relPath),
        contains('g1/reports/ok.md'),
      );
    });

    test('.archive / _attachments 按**任意层级段**跳过', () {
      // 按段相等而非子串：`.archivex` / `_attachments_bak` 不该误伤。
      expect(isMachineGenerated('.archive/v1/manifest.json'), isTrue);
      expect(isMachineGenerated('reports/.archive/v1/x.md'), isTrue);
      expect(isMachineGenerated('_attachments/turn1/a.png'), isTrue);
      expect(isMachineGenerated('sub/_attachments/a.png'), isTrue);
      expect(isMachineGenerated('.archivex/a.md'), isFalse);
      expect(isMachineGenerated('_attachments_bak/a.png'), isFalse);
      expect(isMachineGenerated('reports/a.md'), isFalse);

      final plan = buildSyncPlan(
        remote: [
          remoteFixture('.archive/v1/snapshot.md'),
          remoteFixture('.archive/v1/manifest.json'),
          remoteFixture('reports/ok.md'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.downloadCount, 1, reason: '只同步 reports/ok.md');
      expect(plan.skipped[SyncSkipReason.machineGenerated], 2);
    });

    test('媒体默认不同步，开启后放行', () {
      final strict = buildSyncPlan(
        remote: [remoteFixture('pic.png', mime: 'image/png')],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: const SyncFilterConfig(),
      );
      expect(strict.skipped[SyncSkipReason.mediaExcluded], 1);

      final permissive = buildSyncPlan(
        remote: [remoteFixture('pic.png', mime: 'image/png')],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
          remoteFixture('big.pdf', size: 2048, mime: 'application/pdf'),
          remoteFixture('edge.pdf', size: 1024, mime: 'application/pdf'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: const SyncFilterConfig(maxFileSize: 1024, includeMedia: true),
      );
      expect(limited.downloadCount, 1, reason: '1024 恰好等于上限，应放行');
      expect(limited.skipped[SyncSkipReason.tooLarge], 1);

      final unlimited = buildSyncPlan(
        remote: [
          remoteFixture('huge.pdf', size: 1 << 40, mime: 'application/pdf'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: const SyncFilterConfig(maxFileSize: 0, includeMedia: true),
      );
      expect(unlimited.downloadCount, 1);
    });

    test('目录归类为 directory，不报「路径不合法」', () {
      // UFS 列表会包含 group 根目录自身，它解析不出相对路径。
      // 若先解析路径再判目录，用户会看到「跳过：1 路径不合法」这种像出错的提示。
      final root = UfsFileEntry.fromJson({
        'id': 'root',
        'path': '/workspace/groups/$gidFixture/',
        'name': gidFixture,
        'size': 0,
        'is_directory': true,
      });
      final plan = buildSyncPlan(
        remote: [root, remoteFixture('reports', directory: true)],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
}
