import 'package:dio/dio.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

class _Ufs extends UfsApi {
  _Ufs(this.files) : super(Dio());
  final List<UfsFileEntry> files;
  final lowerBounds = <String?>[];

  @override
  Future<UfsFilePage> listFiles({
    String? pathPrefix,
    String? updatedSince,
    bool includeDeleted = false,
    List<String> excludePrefix = const [],
    int page = 1,
    int pageSize = 20,
    String ownerType = 'user',
  }) async {
    lowerBounds.add(updatedSince);
    final selected = files.where(
      (f) =>
          f.path.startsWith(pathPrefix!) &&
          (updatedSince == null ||
              f.updatedAtRaw!.compareTo(updatedSince) >= 0),
    );
    return UfsFilePage(
      items: selected.skip((page - 1) * pageSize).take(pageSize).toList(),
      total: selected.length,
    );
  }
}

void main() {
  const early = '2026-01-01T00:00:00Z';
  const late = '2026-02-01T00:00:00Z';
  const filter = SyncFilterConfig();

  for (final scope in <SyncScope>[
    const SyncSingleGroupScope('g1'),
    const SyncWorkspaceScope(),
  ]) {
    test('${scope.runtimeType}: 较旧失败项在下一轮重试，较新成功项不重下', () async {
      final ufs = _Ufs([
        remoteFixture('old.md', id: 'old', updatedAt: early),
        remoteFixture('new.md', id: 'new', updatedAt: late),
      ]);
      final store = MemoryStateStore();
      final sink = StubSink();
      final downloader = StubDownloader()..errors['old'] = 'temporary failure';
      final useCase = DeliverableSyncUseCase(
        ufs: ufs,
        stateStore: store,
        sink: sink,
        downloader: downloader,
      );

      final first = await useCase.run(scope: scope, filter: filter);
      expect(first.failed.map((f) => f.relPath), ['g1/old.md']);
      final afterFirst = await store.load(workspaceStateKey);
      expect(afterFirst.cursor, isNull, reason: '不能让新成功项的时间越过旧失败项');
      expect(afterFirst.contains('g1/new.md'), isTrue);

      downloader.errors.clear();
      downloader.calls.clear();
      final second = await useCase.run(scope: scope, filter: filter);
      expect(second.hasFailures, isFalse);
      expect(second.downloaded, 1);
      expect(downloader.calls.map((c) => c.$1), ['old']);
      expect(sink.written.keys, containsAll(['g1/old.md', 'g1/new.md']));
      expect((await store.load(workspaceStateKey)).files.length, 2);
    });
  }

  test('定向同步修复历史遗漏：旧失败项早于已有最大成功时间', () async {
    final store = MemoryStateStore();
    await store.save(
      workspaceStateKey,
      const SyncState(
        cursor: late,
        files: {
          'g1/new.md': SyncedFile(size: 10, etag: 'W/"1"', updatedAt: late),
        },
      ),
    );
    final sink = StubSink(preExisting: {'g1/new.md'});
    final downloader = StubDownloader();
    final ufs = _Ufs([
      remoteFixture('old.md', id: 'old', updatedAt: early),
      remoteFixture('new.md', id: 'new', updatedAt: late),
    ]);
    final report = await DeliverableSyncUseCase(
      ufs: ufs,
      stateStore: store,
      sink: sink,
      downloader: downloader,
    ).run(scope: const SyncSingleGroupScope('g1'), filter: filter);
    expect(ufs.lowerBounds.single, isNull);
    expect(report.downloaded, 1);
    expect(downloader.calls.map((c) => c.$1), ['old']);
    expect((await store.load(workspaceStateKey)).cursor, late);
  });

  test('已有游标时整轮有失败就保留原游标，同时保存成功记录', () async {
    final store = MemoryStateStore();
    const before = '2025-12-01T00:00:00Z';
    await store.save(workspaceStateKey, const SyncState(cursor: before));
    final report = await DeliverableSyncUseCase(
      ufs: _Ufs([
        remoteFixture('old.md', id: 'old', updatedAt: early),
        remoteFixture('new.md', id: 'new', updatedAt: late),
      ]),
      stateStore: store,
      sink: StubSink(),
      downloader: StubDownloader()..errors['old'] = 'offline',
    ).run(scope: const SyncWorkspaceScope(), filter: filter);
    expect(report.hasFailures, isTrue);
    final state = await store.load(workspaceStateKey);
    expect(state.cursor, before);
    expect(state.contains('g1/new.md'), isTrue);
  });

  test('定向完整扫描仍遵守 sinceDays，而不取最大成功时间', () async {
    final ufs = _Ufs([
      remoteFixture('old.md', updatedAt: early),
      remoteFixture('recent.md', updatedAt: late),
    ]);
    final store = MemoryStateStore();
    await store.save(
      workspaceStateKey,
      const SyncState(
        cursor: late,
        files: {'g1/other.md': SyncedFile(size: 1, updatedAt: late)},
      ),
    );
    final report =
        await DeliverableSyncUseCase(
          ufs: ufs,
          stateStore: store,
          sink: StubSink(),
          downloader: StubDownloader(),
        ).run(
          scope: const SyncSingleGroupScope('g1'),
          filter: filter,
          sinceDays: 30,
          nowUnixOverride:
              DateTime.utc(2026, 2, 2).millisecondsSinceEpoch ~/ 1000,
        );
    expect(ufs.lowerBounds.single, '2026-01-03T00:00:00Z');
    expect(report.downloaded, 1);
  });
}
