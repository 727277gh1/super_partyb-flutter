import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';

/// 建一个内存库（每个用例独立，互不干扰）。
///
/// 用 `NativeDatabase.memory()` 而不是临时文件：测试不需要落盘，
/// 且内存库天然保证用例之间不串状态。
AppDatabase _memoryDb() => AppDatabase(NativeDatabase.memory());

void main() {
  group('AppDatabase 建表', () {
    test('四张表都能建出来并空读', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      final store = DriftSyncStateStore(db);
      expect(await store.load(workspaceStateKey), SyncState.empty);

      final prefs = PreferencesStore(db);
      expect(await prefs.getString('nope'), isNull);
    });
  });

  group('DriftSyncStateStore：cursor/etag round-trip', () {
    test('写入后读回：游标与 etag 记录一致', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      final state = SyncState(
        cursor: '2026-03-01T00:00:00Z',
        files: {
          'grp_1/reports/a.md': const SyncedFile(
            etag: 'W/"1"',
            size: 100,
            updatedAt: '2026-03-01T00:00:00Z',
          ),
          'grp_1/reports/b.md': const SyncedFile(etag: null, size: 42),
        },
      );

      await store.save(workspaceStateKey, state);
      final back = await store.load(workspaceStateKey);

      expect(back.cursor, '2026-03-01T00:00:00Z');
      expect(back.files, hasLength(2));
      expect(back.files['grp_1/reports/a.md']?.etag, 'W/"1"');
      expect(back.files['grp_1/reports/a.md']?.size, 100);
      expect(
        back.files['grp_1/reports/a.md']?.updatedAt,
        '2026-03-01T00:00:00Z',
      );
      // etag 为 null 也要原样读回 null（不能变成空串，否则 is_unchanged
      // 的「任一侧缺 etag」分支永远走不到）。
      expect(back.files['grp_1/reports/b.md']?.etag, isNull);
      expect(back.files['grp_1/reports/b.md']?.size, 42);
    });

    test('contentHash round-trip（含 null：升级前记录 / 计算失败）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      const hash =
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
      await store.save(
        workspaceStateKey,
        const SyncState(
          files: {
            'g1/with-hash.md': SyncedFile(
              etag: 'W/"1"',
              size: 5,
              contentHash: hash,
            ),
            // 旧记录（本列引入前写入）：必须读回 null，而不是空串——空串会
            // 让脏检测把它当成一个「有效的 hash」而永远判为脏。
            'g1/no-hash.md': SyncedFile(etag: 'W/"1"', size: 5),
          },
        ),
      );

      final back = await store.load(workspaceStateKey);
      expect(back.files['g1/with-hash.md']?.contentHash, hash);
      expect(back.files['g1/no-hash.md']?.contentHash, isNull);
      // 相等性必须把 contentHash 算进去（否则「hash 变了」会被判成同一状态）
      expect(
        back.files['g1/with-hash.md'],
        isNot(const SyncedFile(etag: 'W/"1"', size: 5)),
      );
    });

    test('v1 库升级到 v2：既有行保留，新列可读写', () async {
      // 回归防线：onUpgrade 必须只 ALTER 加列。若用 m.createAll() 兑底会重建
      // 表，用户已同步的 etag/游标全部丢失 → 下一轮全量重拉（生产 5666 文件）。
      final dir = await Directory.systemTemp.createTemp('spb_data_mig');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.db');

      // 1) 用原始 SQL 造一个 schemaVersion = 1 的库（无 content_hash 列）。
      //
      // 用 _V1User 把库开在版本 1 上（不跑任何迁移），再手写 v1 的建表语句与
      // 一行既有数据。之所以不用 AppDatabase 建：它现在的 schemaVersion 是 2。
      final raw = NativeDatabase(file);
      await raw.ensureOpen(_V1User());
      await raw.runCustom(
        'CREATE TABLE sync_cursors (state_key TEXT NOT NULL, cursor TEXT NULL, '
        'PRIMARY KEY (state_key))',
      );
      await raw.runCustom(
        'CREATE TABLE synced_files (state_key TEXT NOT NULL, rel_path TEXT NOT NULL, '
        'etag TEXT NULL, size INTEGER NOT NULL, updated_at TEXT NULL, '
        'PRIMARY KEY (state_key, rel_path))',
      );
      await raw.runCustom(
        'CREATE TABLE sync_bindings (id INTEGER NOT NULL, local_root TEXT NULL, '
        'PRIMARY KEY (id))',
      );
      await raw.runCustom(
        'CREATE TABLE preferences (key TEXT NOT NULL, value TEXT NOT NULL, '
        'PRIMARY KEY (key))',
      );
      await raw.runCustom(
        "INSERT INTO sync_cursors (state_key, cursor) "
        "VALUES ('$workspaceStateKey', '2026-03-01T00:00:00Z')",
      );
      await raw.runCustom(
        "INSERT INTO synced_files (state_key, rel_path, etag, size, updated_at) "
        "VALUES ('$workspaceStateKey', 'g1/a.md', 'W/\"1\"', 100, "
        "'2026-03-01T00:00:00Z')",
      );
      await raw.runCustom('PRAGMA user_version = 1');
      await raw.close();

      // 2) 用当前版本打开：onUpgrade 1→2 应执行 ALTER 加列。
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      final back = await store.load(workspaceStateKey);
      expect(back.cursor, '2026-03-01T00:00:00Z', reason: '升级不得丢游标');
      expect(back.files, hasLength(1), reason: '升级不得丢既有文件记录');
      expect(back.files['g1/a.md']?.etag, 'W/"1"');
      expect(back.files['g1/a.md']?.size, 100);
      expect(
        back.files['g1/a.md']?.contentHash,
        isNull,
        reason: '旧行新列默认 null → 脏检测降级为「无法检测」，不是「未变更」',
      );

      // 3) 新列可写：升级后的库必须能存 hash。
      await store.save(
        workspaceStateKey,
        back.markSynced(
          'g1/a.md',
          etag: 'W/"1"',
          size: 100,
          contentHash: 'abc123',
        ),
      );
      final after = await store.load(workspaceStateKey);
      expect(after.files['g1/a.md']?.contentHash, 'abc123');
    });

    test('未写入过的键返回 empty（不是抛异常）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      final s = await store.load('never_written');
      expect(s.cursor, isNull);
      expect(s.files, isEmpty);
      expect(s.isEmpty, isTrue);
    });

    test('save 是整体替换：远端已删除的文件不得残留', () async {
      // 回归防线：若 save 只做 upsert 而不删旧记录，远端已删除的文件会永远
      // 留在表里，contains() 一直为 true → 「远端删了但本地没删」。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.save(
        workspaceStateKey,
        const SyncState(
          files: {
            'a.md': SyncedFile(etag: 'e1', size: 1),
            'b.md': SyncedFile(etag: 'e2', size: 2),
          },
        ),
      );
      await store.save(
        workspaceStateKey,
        const SyncState(files: {'a.md': SyncedFile(etag: 'e1', size: 1)}),
      );

      final back = await store.load(workspaceStateKey);
      expect(back.files.keys, ['a.md']);
      expect(back.files.containsKey('b.md'), isFalse);
    });

    test('同一路径重复写入是覆盖（etag 必须更新）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.save(
        workspaceStateKey,
        const SyncState(files: {'a.md': SyncedFile(etag: 'old', size: 1)}),
      );
      await store.save(
        workspaceStateKey,
        const SyncState(files: {'a.md': SyncedFile(etag: 'new', size: 9)}),
      );

      final back = await store.load(workspaceStateKey);
      expect(back.files['a.md']?.etag, 'new');
      expect(back.files['a.md']?.size, 9);
    });

    test('不同状态键互不干扰（单 group 与 workspace 分开）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.save(
        'grp_1',
        const SyncState(
          cursor: 'c1',
          files: {'a.md': SyncedFile(etag: 'e1', size: 1)},
        ),
      );
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: 'cw',
          files: {'grp_2/b.md': SyncedFile(etag: 'e2', size: 2)},
        ),
      );

      final g1 = await store.load('grp_1');
      final ws = await store.load(workspaceStateKey);
      expect(g1.cursor, 'c1');
      expect(g1.files.keys, ['a.md']);
      expect(ws.cursor, 'cw');
      expect(ws.files.keys, ['grp_2/b.md']);
    });

    test('reset 只清指定键', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.save(
        'grp_1',
        const SyncState(cursor: 'c1', files: {'a.md': SyncedFile(size: 1)}),
      );
      await store.save(
        'grp_2',
        const SyncState(cursor: 'c2', files: {'b.md': SyncedFile(size: 2)}),
      );

      await store.reset('grp_1');

      expect(await store.load('grp_1'), SyncState.empty);
      expect((await store.load('grp_2')).cursor, 'c2');
    });

    test('resetAll 清空全部键', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.save('grp_1', const SyncState(cursor: 'c1'));
      await store.save(workspaceStateKey, const SyncState(cursor: 'cw'));

      await store.resetAll();

      expect(await store.load('grp_1'), SyncState.empty);
      expect(await store.load(workspaceStateKey), SyncState.empty);
    });
  });

  group('换同步目录会重置状态', () {
    test('首次绑定目录：不重置（此时本就没有状态）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      final didReset = await store.bindLocalRoot('/home/u/deliverables');
      expect(didReset, isFalse);
      expect(await store.boundLocalRoot(), '/home/u/deliverables');
    });

    test('换目录 → 游标与 etag 记录全部清空', () async {
      // 回归防线：保留游标会让新目录「几乎什么都拿不到」（增量清单只返回
      // updated_at >= 游标的文件）；保留 etag 会让少数文件被判为「未变更」
      // 而跳过写入。叠加效果是「同步显示成功，但新目录是空的」。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.bindLocalRoot('/home/u/dir-a');
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: '2026-03-01T00:00:00Z',
          files: {'grp_1/a.md': SyncedFile(etag: 'e1', size: 1)},
        ),
      );
      // 确认状态确实写进去了，否则下面的断言可能是「本来就是空的」而假通过。
      expect((await store.load(workspaceStateKey)).files, isNotEmpty);

      final didReset = await store.bindLocalRoot('/home/u/dir-b');

      expect(didReset, isTrue);
      expect(await store.boundLocalRoot(), '/home/u/dir-b');
      final after = await store.load(workspaceStateKey);
      expect(after.cursor, isNull, reason: '换目录必须清游标（否则新目录拿不到文件）');
      expect(after.files, isEmpty, reason: '换目录必须清 etag（否则会跳过写入）');
    });

    test('绑定同一个目录 → 不重置（幂等，不得误清）', () async {
      // 回归防线：若这里误清，用户每次打开设置页保存一次就会全量重下。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.bindLocalRoot('/home/u/dir-a');
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: 'c1',
          files: {'a.md': SyncedFile(etag: 'e1', size: 1)},
        ),
      );

      final didReset = await store.bindLocalRoot('/home/u/dir-a');

      expect(didReset, isFalse);
      final after = await store.load(workspaceStateKey);
      expect(after.cursor, 'c1');
      expect(after.files, hasLength(1));
    });

    test('改同步范围（不换目录）不得重置状态', () async {
      // 全量 ↔ 选中若干 group 共用 workspaceStateKey，本地布局相同，
      // 状态必须跨范围复用；清掉会让所有文件在下一轮全量重下。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftSyncStateStore(db);

      await store.bindLocalRoot('/home/u/dir-a');
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: 'c1',
          files: {'grp_1/a.md': SyncedFile(etag: 'e1', size: 1)},
        ),
      );

      // 范围变化只写偏好，**不碰** bindLocalRoot / reset。
      final prefs = PreferencesStore(db);
      await prefs.setBool('scope.all_groups', value: false);
      await prefs.setString('scope.group_ids', '["grp_1"]');

      final after = await store.load(workspaceStateKey);
      expect(after.cursor, 'c1', reason: '范围变更不得重置游标');
      expect(after.files, hasLength(1), reason: '范围变更不得重置 etag 记录');
    });
  });

  group('PreferencesStore', () {
    test('字符串 round-trip 与覆盖', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final prefs = PreferencesStore(db);

      expect(await prefs.getString('local_root'), isNull);
      await prefs.setString('local_root', '/home/u/deliverables');
      expect(await prefs.getString('local_root'), '/home/u/deliverables');
      await prefs.setString('local_root', '/home/u/other');
      expect(await prefs.getString('local_root'), '/home/u/other');
    });

    test('bool round-trip；未设置时返回默认值', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final prefs = PreferencesStore(db);

      // 媒体默认关（生产实测图片占 94.5% 体积）。
      expect(
        await prefs.getBool('include_media', defaultValue: false),
        isFalse,
      );
      await prefs.setBool('include_media', value: true);
      expect(await prefs.getBool('include_media', defaultValue: false), isTrue);
      await prefs.setBool('include_media', value: false);
      expect(await prefs.getBool('include_media', defaultValue: true), isFalse);
    });

    test('int round-trip；未设置时返回默认值', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final prefs = PreferencesStore(db);

      expect(await prefs.getInt('since_days', defaultValue: 30), 30);
      await prefs.setInt('since_days', value: 7);
      expect(await prefs.getInt('since_days', defaultValue: 30), 7);
    });

    test('坏值不抛异常，返回默认值（配置损坏不该让应用起不来）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final prefs = PreferencesStore(db);

      await prefs.setString('include_media', 'not-a-bool');
      expect(
        await prefs.getBool('include_media', defaultValue: false),
        isFalse,
      );

      await prefs.setString('since_days', 'abc');
      expect(await prefs.getInt('since_days', defaultValue: 30), 30);
    });

    test('remove 删除单个键', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final prefs = PreferencesStore(db);

      await prefs.setString('k', 'v');
      await prefs.remove('k');
      expect(await prefs.getString('k'), isNull);
    });
  });

  group('SyncState 值类型', () {
    test('workspaceStateKey 是固定值（与 Tauri 端一致）', () {
      expect(workspaceStateKey, '__workspace__');
    });

    test('== 按内容比较（不是身份）', () {
      const a = SyncState(
        cursor: 'c',
        files: {'x': SyncedFile(etag: 'e', size: 1)},
      );
      const b = SyncState(
        cursor: 'c',
        files: {'x': SyncedFile(etag: 'e', size: 1)},
      );
      const c = SyncState(
        cursor: 'c',
        files: {'x': SyncedFile(etag: 'DIFFERENT', size: 1)},
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });
}

/// 把 NativeDatabase 开在 schemaVersion 1 上且不跑任何迁移（用于造 v1 库）。
///
/// beforeOpen 必须不碰库体；PRAGMA user_version 由 drift 在迁移结束后写回
/// [schemaVersion]，故这里天然留下 user_version = 1。
class _V1User implements QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
