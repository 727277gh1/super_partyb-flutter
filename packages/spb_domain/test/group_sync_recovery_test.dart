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

  /// 模拟「服务端没带 total」（issue #65）：分页完整性无从判断。
  bool omitTotal = false;

  /// 模拟「total 被算成本页条数」：永远只报第一页的大小。
  bool totalEqualsPageSize = false;

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
    final items = selected.skip((page - 1) * pageSize).take(pageSize).toList();
    return UfsFilePage(
      items: items,
      total: omitTotal
          ? 0
          : totalEqualsPageSize
          ? pageSize
          : selected.length,
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

  test('total 缺失时按「本页满」兜底翻完，而不是静默只同步第一页（issue #65）', () async {
    final store = MemoryStateStore();
    // pageSize=2，4 个文件 → 2 个满页 + 1 个空页收尾。
    final ufs = _Ufs([
      remoteFixture('a.md', id: 'a', updatedAt: late),
      remoteFixture('b.md', id: 'b', updatedAt: late),
      remoteFixture('c.md', id: 'c', updatedAt: late),
      remoteFixture('d.md', id: 'd', updatedAt: late),
    ])..omitTotal = true;
    final sink = StubSink();

    final report = await DeliverableSyncUseCase(
      ufs: ufs,
      stateStore: store,
      sink: sink,
      downloader: StubDownloader(),
      pageSize: 2,
    ).run(scope: const SyncWorkspaceScope(), filter: filter);

    expect(report.hasFailures, isFalse);
    expect(
      sink.written.keys,
      containsAll(['g1/a.md', 'g1/b.md', 'g1/c.md', 'g1/d.md']),
      reason: 'total 缺失时旧实现只同步第一页就报成功 —— 剩余文件被 updated_since 永久过滤',
    );
    // 清单完整了，游标才可以推。
    expect((await store.load(workspaceStateKey)).cursor, late);
  });

  test('total 少报（等于本页条数）时靠「本页满」继续翻页，不丢文件（issue #65）', () async {
    // 服务端把 total 算成本页条数：旧判据 `page*pageSize < total` 在第一页就
    // 判「到底了」，第二页的文件永远同步不到，而报告说成功。
    final ufs = _Ufs([
      remoteFixture('a.md', id: 'a', updatedAt: late),
      remoteFixture('b.md', id: 'b', updatedAt: late),
      remoteFixture('c.md', id: 'c', updatedAt: late),
    ])..totalEqualsPageSize = true;
    final sink = StubSink();
    final useCase = DeliverableSyncUseCase(
      ufs: ufs,
      stateStore: MemoryStateStore(),
      sink: sink,
      downloader: StubDownloader(),
      pageSize: 2,
    );

    final report = await useCase.run(
      scope: const SyncWorkspaceScope(),
      filter: filter,
    );

    expect(report.hasFailures, isFalse);
    expect(
      sink.written.keys,
      containsAll(['g1/a.md', 'g1/b.md', 'g1/c.md']),
      reason: 'total 不可信时必须以「本页是否满」兜底继续翻页',
    );
  });
}
