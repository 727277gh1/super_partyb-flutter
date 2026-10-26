import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

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

      const state = SyncState(
        cursor: '2026-03-01T00:00:00Z',
        files: {
          'grp_1/reports/a.md': SyncedFile(
            etag: 'W/"1"',
            size: 100,
            updatedAt: '2026-03-01T00:00:00Z',
          ),
          'grp_1/reports/b.md': SyncedFile(etag: null, size: 42),
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

      // 4) 同一次升级还必须建出 v3 的新表（cached_groups，issue #26）。
      //
      // ⚠️ 这条测试现在是**跳版升级**（v1 → v3，中间跨过 v2）。它同时守着
      // `onUpgrade` 里必须写 `from < N` 而不是 `from == N-1`：若写
      // `if (from == 2) await m.createTable(cachedGroups)`，v1 用户升到 v3 后
      // 就没有这张表，而 drift 不会在升级时报错——直到列表页第一次查缓存才炸。
      //
      // ## 为什么必须直接查表，不能通过 `DriftGroupCacheStore`
      //
      // 缓存是**可丢弃数据**，故 store 的每一处失败都静默降级（读失败返回空
      // 列表、写失败只记日志）。于是「表不存在」在 store 层表现为**空列表**，
      // `expect(await cache.load(...), isEmpty)` 会**无条件通过**——这条断言
      // 对「迁移漏建表」完全无效（实测：把 `from < 3` 改成 `from == 2` 后
      // 测试仍全绿，日志里只有 `no such table: cached_groups` 的 warn）。
      //
      // 故直接走 SQL 查 `sqlite_master`：这是唯一能区分「表不存在」与「表存在
      // 但没有行」的检查。
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='cached_groups'",
          )
          .get();
      expect(
        tables.map((r) => r.data['name']),
        contains('cached_groups'),
        reason: 'v3 新表必须存在（跳版升级 v1→v3 也要建）',
      );

      // 再确认它**可读写**（建了表但列不对同样是坏的）。
      final cache = DriftGroupCacheStore(db);
      await cache.save('usr_1', [
        ChatGroup.fromJson({
          'id': 'g1',
          'user_id': 'usr_1',
          'title': 't',
          'status': 'active',
          'created_at': '2024-03-05T08:00:00Z',
          'updated_at': '2024-03-05T08:09:10Z',
        }),
      ]);
      expect((await cache.load('usr_1')).map((e) => e.id), [
        'g1',
      ], reason: 'v3 新表必须可读写');
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

  group('写失败不静默（StorageError 路径）', () {
    /// 造一个「能读、不能写」的库。
    ///
    /// ## 为什么不用 `db.close()`
    ///
    /// 内存执行器的写是**缓冲**的：`close()` 之后 `save()` 可能仍然「成功」
    /// 返回（只是没落盘），会让用例以错误的原因变绿。`PRAGMA query_only = 1`
    /// 是 SQLite 层面的只读开关，任何写语句都会报 `SQLITE_READONLY`（code 8）。
    ///
    /// ⚠️ 必须先真正打开过库（跑一次查询），否则 PRAGMA 作用在未打开的连接上。
    Future<AppDatabase> readOnlyDb() async {
      final db = _memoryDb();
      await db.customSelect('SELECT 1').get();
      await db.customStatement('PRAGMA query_only = 1');
      return db;
    }

    test('sync save 失败抛 StorageError（不假装游标已推进）', () async {
      // 若静默吞掉，下一轮同步会以为「游标已到 X」而**跳过** X 之前的全部
      // 变更——用户看到「同步成功」但文件永远不来。
      final db = await readOnlyDb();
      addTearDown(db.close);

      await expectLater(
        DriftSyncStateStore(db).save(
          workspaceStateKey,
          const SyncState(cursor: '2026-03-01T00:00:00Z'),
        ),
        throwsA(isA<StorageError>()),
      );
    });

    test('sync reset 失败抛 StorageError（不假装已清空）', () async {
      final db = await readOnlyDb();
      addTearDown(db.close);

      await expectLater(
        DriftSyncStateStore(db).reset(workspaceStateKey),
        throwsA(isA<StorageError>()),
      );
    });

    test('sync resetAll 失败抛 StorageError（换目录时的全量清理）', () async {
      final db = await readOnlyDb();
      addTearDown(db.close);

      await expectLater(
        DriftSyncStateStore(db).resetAll(),
        throwsA(isA<StorageError>()),
      );
    });

    test('bindLocalRoot 失败抛 StorageError（绑定失败不能让目录「看起来已换」）', () async {
      // 若静默吞掉，调用方会以为目录已切换，而实际绑定仍是旧目录——
      // 下轮同步会往**旧目录**写文件。
      final db = await readOnlyDb();
      addTearDown(db.close);

      await expectLater(
        DriftSyncStateStore(db).bindLocalRoot('/home/u/deliverables'),
        throwsA(isA<StorageError>()),
      );
    });

    test('prefs setString 失败抛 StorageError（不假装设置已保存）', () async {
      final db = await readOnlyDb();
      addTearDown(db.close);

      await expectLater(
        PreferencesStore(db).setString('local_root', '/home/u/deliverables'),
        throwsA(isA<StorageError>()),
      );
    });

    test('StorageError 的 message 指得出是哪一层（便于日志定位）', () async {
      final db = await readOnlyDb();
      addTearDown(db.close);
      try {
        await DriftSyncStateStore(db)
            .save(workspaceStateKey, const SyncState());
        fail('应当抛出');
      } on StorageError catch (e) {
        expect(e.message, contains('同步状态'));
      }
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

  group('DriftGroupCacheStore（issue #26 切片 A）', () {
    /// 造一个 `ChatGroup`（走 fromJson，与服务端形态一致）。
    ChatGroup g(String id, {String title = 't', String? updatedAt}) =>
        ChatGroup.fromJson({
          'id': id,
          'user_id': 'usr_1',
          'title': title,
          'status': 'active',
          'created_at': '2024-03-05T08:00:00Z',
          'updated_at': updatedAt ?? '2024-03-05T08:09:10Z',
        });

    test('无缓存返回空列表（不是抛异常）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      expect(await cache.load('usr_never'), isEmpty);
      expect(await cache.lastFetchedAt('usr_never'), isNull);
    });

    test('写入后读回：字段完整（含嵌套 metadata / current_goal）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      final group = ChatGroup.fromJson({
        'id': 'g1',
        'user_id': 'usr_1',
        'title': '带 metadata 的对话',
        'status': 'active',
        'metadata': {
          'tts': {'enabled': true, 'narration_mode': 'summary'},
          'goal_gate': {'enabled': true, 'continue_until_done': true},
        },
        'active_session': {'agent_id': 'agt_1', 'session_id': 'ses_1'},
        'created_at': '2024-03-05T08:00:00Z',
        'updated_at': '2024-03-05T08:09:10Z',
      });

      await cache.save('usr_1', [group]);
      final back = await cache.load('usr_1');

      expect(back, hasLength(1));
      expect(back.first.title, '带 metadata 的对话');
      // 嵌套字段必须活着——它们是界面状态的来源（tts 开关、goal gate）。
      expect(back.first.ttsEnabled, isTrue);
      expect(back.first.ttsNarrationMode, 'summary');
      expect(back.first.goalGateEnabled, isTrue);
      expect(back.first.activeSession?.agentId, 'agt_1');
      expect(back.first.activeSession?.sessionId, 'ses_1');
    });

    test('整表替换：服务端删掉的 group 不残留（不能只 upsert）', () async {
      // 这是本实现最容易写错的地方（见 GroupCacheStore.save 文档）：
      // 若只 upsert，服务端删掉的 group 会永远显示，用户点进去得到 404。
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_1', [g('g1'), g('g2'), g('g3')]);
      expect(await cache.load('usr_1'), hasLength(3));

      // 服务端删掉了 g2。
      await cache.save('usr_1', [g('g1'), g('g3')]);
      final back = await cache.load('usr_1');
      expect(back.map((e) => e.id), ['g1', 'g3']);
      expect(
        back.any((e) => e.id == 'g2'),
        isFalse,
        reason: '整表替换：g2 必须消失，否则用户点进去 404',
      );
    });

    test('save 空列表 = 清空该用户缓存', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_1', [g('g1')]);
      await cache.save('usr_1', const []);
      expect(await cache.load('usr_1'), isEmpty);
    });

    test('按 user_id 隔离：换账号不串号', () async {
      // 这条守着 CachedGroups.userId 列的存在意义：若查询不过滤 user_id，
      // A 账号会看到 B 账号的对话列表。
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_A', [g('gA')]);
      await cache.save('usr_B', [g('gB1'), g('gB2')]);

      expect((await cache.load('usr_A')).map((e) => e.id), ['gA']);
      expect((await cache.load('usr_B')).map((e) => e.id), ['gB1', 'gB2']);
    });

    test('clear 只清该用户，不影响别人', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_A', [g('gA')]);
      await cache.save('usr_B', [g('gB')]);

      await cache.clear('usr_A');
      expect(await cache.load('usr_A'), isEmpty);
      expect((await cache.load('usr_B')).map((e) => e.id), ['gB']);
    });

    test('按 updated_at 降序（与服务端列表排序一致）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_1', [
        g('old', updatedAt: '2024-03-01T00:00:00Z'),
        g('newest', updatedAt: '2024-03-09T00:00:00Z'),
        g('mid', updatedAt: '2024-03-05T00:00:00Z'),
      ]);

      expect((await cache.load('usr_1')).map((e) => e.id), [
        'newest',
        'mid',
        'old',
      ]);
    });

    test('lastFetchedAt：写入后有值，未写过为 null', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      expect(await cache.lastFetchedAt('usr_1'), isNull);
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await cache.save('usr_1', [g('g1')]);
      final at = await cache.lastFetchedAt('usr_1');
      // 不用 `isNotNull`：drift 的 query_builder 也导出了同名符号（这里已
      // `hide isNull`，但 isNotNull 未 hide），会报「imported from both」。
      expect(at, isA<DateTime>());
      expect(at!.isAfter(before), isTrue);
    });

    test('坏行被跳过，其余行照常返回（不因一行坏而整份作废）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.save('usr_1', [g('good1'), g('good2')]);
      // 手工把一行 payload 改坏（模拟截断 / 手工改库）。
      await db.customStatement(
        "UPDATE cached_groups SET payload = '{not json' WHERE id = 'good1'",
      );

      final back = await cache.load('usr_1');
      expect(back.map((e) => e.id), ['good2']);
    });

    // ── 静默降级：可丢弃数据的核心语义（issue #26）────────────────────
    //
    // 这四条覆盖的是「库坏了会怎样」。它们不是凑覆盖率：`GroupCacheStore` 的
    // 设计前提就是**每一处失败都静默**（与 `SyncStateStore` 相反），若某天有人
    // 把某个 `catch` 改成 `rethrow`，对话列表会从「能用但无缓存」变成「整页报错」
    // ——而缓存的存在意义恰恰是在坏环境下让应用可用。
    //
    // ## 手法：`DROP TABLE cached_groups`
    //
    // 制造一个「查询必然失败」的环境。为什么不用「关掉数据库」：实测
    // `await db.close()` 之后 drift 的查询**不抛**（静默返回空 / 无操作），
    // 于是那组用例会**无条件通过**——对「catch 有没有被改成 rethrow」毫无
    // 鉴别力（踩过一次，覆盖率报告显示 catch 行根本没被命中才发现的）。
    //
    // 删表则稳定触发 `SqliteException: no such table: cached_groups`。
    Future<AppDatabase> dbWithDroppedCacheTable() async {
      final db = _memoryDb();
      await db.customStatement('DROP TABLE cached_groups');
      return db;
    }

    test('表不可用时 load 返回空列表（不抛异常）', () async {
      final db = await dbWithDroppedCacheTable();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      expect(await cache.load('usr_1'), isEmpty);
    });

    test('表不可用时 save 静默（不抛，主流程不受影响）', () async {
      final db = await dbWithDroppedCacheTable();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      // 不抛 = 通过。若这里抛了，列表页的「网络成功 → 写缓存」会把一次正常的
      // 列表加载变成错误页。
      await cache.save('usr_1', [g('g1')]);
    });

    test('表不可用时 clear 静默（不抛）', () async {
      final db = await dbWithDroppedCacheTable();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      await cache.clear('usr_1');
    });

    test('表不可用时 lastFetchedAt 返回 null（不抛）', () async {
      final db = await dbWithDroppedCacheTable();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);

      expect(await cache.lastFetchedAt('usr_1'), isNull);
    });

    test('清同步状态不得动缓存（resetAll 与缓存生命周期分离）', () async {
      // docs/offline-cache-design.md §6.3：换同步目录与「对话缓存」无关，
      // 清了只会让用户下次断网又白屏。
      final db = _memoryDb();
      addTearDown(db.close);
      final cache = DriftGroupCacheStore(db);
      final sync = DriftSyncStateStore(db);

      await cache.save('usr_1', [g('g1')]);
      await sync.save(workspaceStateKey, const SyncState(cursor: 'c1'));
      await sync.resetAll();

      expect((await cache.load('usr_1')).map((e) => e.id), ['g1']);
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
