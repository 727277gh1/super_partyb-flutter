import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

/// 交付物同步范围 / 状态键 / 状态值类型 / contentHash
///
/// ⚠️ 本文件由 `deliverable_sync_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/deliverable_sync_harness.dart`。
void main() {
  group('同步范围与状态键', () {
    test('单 group 剥掉前缀，workspace 保留 groupId 段', () {
      expect(
        const SyncGroupScope(gidFixture)
            .relativePath('/workspace/groups/g1/a.md/'),
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
        filter: permissiveFixture,
      );
      final paths = plan.actions.map((a) => a.relPath).toSet();
      expect(paths, {'ga/README.md', 'gb/README.md'});
    });

    test('选中若干 group：保留前缀但过滤未选中的', () {
      const scope = SyncGroupsScope(['ga', 'gc']);
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
        filter: permissiveFixture,
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
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
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
        filter: permissiveFixture,
      );
      expect(first.report.downloaded, 2);

      // 切到「只选 ga」——同一状态键，同一状态对象
      final second = await engine.run(
        remote: remoteAll,
        state: first.state,
        scope: const SyncGroupsScope(['ga']),
        filter: permissiveFixture,
      );
      expect(second.report.downloaded, 0, reason: '范围切换不该触发重新下载');
      expect(
        second.state.contains('gb/b.md'),
        isTrue,
        reason: '未选中 group 的状态条目必须保留，否则选回来时会全量重拉',
      );
    });
  });
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
      final store = MemoryStateStore();
      await store.save(
        workspaceStateKey,
        const SyncState(cursor: '2026-03-01T00:00:00Z')
            .markSynced('g1/a.md', etag: 'W/"1"', size: 10),
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
      final store = MemoryStateStore();
      await store.save(
        workspaceStateKey,
        const SyncState(cursor: '2026-03-01T00:00:00Z'),
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
  group('同步状态值类型', () {
    test('markSynced / forget 是不可变的（不改自身）', () {
      const base = SyncState.empty;
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
  group('同步状态：contentHash（脏检测基准）', () {
    test('contentHashOf 是稳定的 SHA256 十六进制小写', () {
      // 与 dart 的 crypto 包输出对齐：同一内容重复计算必须一致（否则脏检测
      // 会把全部文件判成脏的）。
      expect(contentHashOf([1, 2, 3, 4, 5]), contentHashOf([1, 2, 3, 4, 5]));
      // 已知向量：sha256('hello') = 2cf24dba5fb0a30e26e83b2ac5b9e29e...
      expect(
        contentHashOf('hello'.codeUnits),
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
      );
    });

    test('下载成功后记录含 contentHash（对实际写入字节计算）', () async {
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [remoteFixture('a.md')],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(
        result.state.files['a.md']!.contentHash,
        contentHashOf([1, 2, 3, 4, 5]),
      );
    });

    test('304 后沿用旧 contentHash（内容未重下，本地仍是那一份）', () async {
      final oldHash = contentHashOf([1, 2, 3, 4, 5]);
      final sink = StubSink(preExisting: {'a.md'});
      final engine = SyncEngine(
        downloader: StubDownloader(notModifiedIds: {'id-a.md'}),
        sink: sink,
      );
      final result = await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"2"', size: 10)],
        state: stateWith({
          'a.md': SyncedFile(etag: 'W/"1"', size: 5, contentHash: oldHash),
        }),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.notModified, 1);
      expect(sink.written, isEmpty);
      expect(
        result.state.files['a.md']!.contentHash,
        oldHash,
        reason: '304 意味着内容没重下，hash 若被清空会让脏检测永久降级',
      );
    });

    test('旧状态（无 hash）roundtrip 不报错且保持 null', () async {
      // 304 分支对「记录里本来就没有 hash」的条目也不得崩溃（升级前已同步的
      // 文件都长这样）。
      final sink = StubSink(preExisting: {'a.md'});
      final engine = SyncEngine(
        downloader: StubDownloader(notModifiedIds: {'id-a.md'}),
        sink: sink,
      );
      final result = await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        // etag 不同 → 进下载计划（否则会被 isUnchanged 直接跳过，走不到 304
        // 分支）；而记录里没有 contentHash（升级前同步的文件就是这样）。
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"0"', size: 5)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.notModified, 1);
      expect(result.state.files['a.md']!.contentHash, isNull);
    });
  });
}
