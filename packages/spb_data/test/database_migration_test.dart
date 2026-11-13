import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';

/// schema 迁移的**跳版**路径 + 两个 `openAppDatabase*` 工厂测试。
///
/// ## 为什么单独一个文件
///
/// `database_test.dart` 的迁移用例是 **v1 → 当前**（只造 v1 库）。本文件补：
///
/// 1. **从每一个历史版本（v2 / v3 / v4）升到当前**——`onUpgrade` 的四个分支
///    （`from < 2` / `< 3` / `< 4` / `< 5`）必须逐个被走到。若写成
///    `from == N-1`，只有「相邻版本」能过，跳版会**静默缺表/缺列**——drift 不在
///    升级时报错，直到某个查询碰到那一列才炸（报错信息指不到迁移）。
/// 2. **`openAppDatabaseAt` / `openAppDatabaseLazy`**：此前零覆盖。它们负责
///    建目录 + 懒开 + 后台 isolate，而 `openAppDatabaseLazy` 的「首次查询才
///    解析路径」语义对 widget test 很重要（不 override provider 时会触发
///    `MissingPluginException`）。
///
/// ## 造历史版本库的手法
///
/// 用 `NativeDatabase` + 一个只声明 `schemaVersion` 的 `QueryExecutorUser`
/// 开库（不跑 drift 的建表），再手写该版本的建表 SQL，最后
/// `PRAGMA user_version = N`。这样 `AppDatabase` 打开时会走 `onUpgrade`。
void main() {
  /// 一个不跑任何迁移的「哑」用户，用于把库开在指定版本上。
  QueryExecutorUser vUser(int version) => _RawVersionUser(version);

  /// 造一个指定版本的库文件（含各版本应有的表与列），并写入一行可验证的数据。
  ///
  /// [version] 1..4。当前 schemaVersion 是 5，故 5 不该被传入。
  Future<File> makeVersionedDb(int version) async {
    final dir = await Directory.systemTemp.createTemp('spb_data_mig_v$version');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/state.db');

    final raw = NativeDatabase(file);
    await raw.ensureOpen(vUser(version));

    // v1 就有的四张表。
    await raw.runCustom(
      'CREATE TABLE sync_cursors (state_key TEXT NOT NULL, cursor TEXT NULL, '
      'PRIMARY KEY (state_key))',
    );
    // v2 起 synced_files 有 content_hash 列。
    final contentHashCol = version >= 2 ? ', content_hash TEXT NULL' : '';
    await raw.runCustom(
      'CREATE TABLE synced_files (state_key TEXT NOT NULL, rel_path TEXT NOT NULL, '
      'etag TEXT NULL, size INTEGER NOT NULL, updated_at TEXT NULL'
      '$contentHashCol, PRIMARY KEY (state_key, rel_path))',
    );
    await raw.runCustom(
      'CREATE TABLE sync_bindings (id INTEGER NOT NULL, local_root TEXT NULL, '
      'PRIMARY KEY (id))',
    );
    await raw.runCustom(
      'CREATE TABLE preferences (key TEXT NOT NULL, value TEXT NOT NULL, '
      'PRIMARY KEY (key))',
    );
    if (version >= 3) {
      await raw.runCustom(
        'CREATE TABLE cached_groups (id TEXT NOT NULL, user_id TEXT NOT NULL, '
        'payload TEXT NOT NULL, updated_at TEXT NULL, fetched_at INTEGER NOT NULL, '
        'PRIMARY KEY (id))',
      );
    }
    if (version >= 4) {
      await raw.runCustom(
        'CREATE TABLE cached_events (group_id TEXT NOT NULL, '
        'global_seq INTEGER NOT NULL, payload TEXT NOT NULL, cached_at INTEGER NOT NULL, '
        'last_accessed_at INTEGER NOT NULL, PRIMARY KEY (group_id, global_seq))',
      );
    }

    // 每个版本都写一行可验证的旧数据（守「升级不得丢数据」）。
    await raw.runCustom(
      "INSERT INTO sync_cursors (state_key, cursor) "
      "VALUES ('$workspaceStateKey', '2026-03-01T00:00:00Z')",
    );
    await raw.runCustom(
      "INSERT INTO synced_files (state_key, rel_path, etag, size, updated_at) "
      "VALUES ('$workspaceStateKey', 'g1/a.md', 'W/\"1\"', 100, "
      "'2026-03-01T00:00:00Z')",
    );
    if (version >= 3) {
      await raw.runCustom(
        "INSERT INTO cached_groups (id, user_id, payload, updated_at, fetched_at) "
        "VALUES ('g1', 'usr_1', '{\"id\":\"g1\"}', NULL, 1)",
      );
    }
    if (version >= 4) {
      await raw.runCustom(
        "INSERT INTO cached_events (group_id, global_seq, payload, cached_at, "
        "last_accessed_at) VALUES ('g1', 7, '{\"a\":1}', 1, 1)",
      );
    }

    await raw.runCustom('PRAGMA user_version = $version');
    await raw.close();
    return file;
  }

  /// 查某个表是否存在（唯一能区分「表不存在」与「表存在但没有行」的检查）。
  Future<bool> tableExists(AppDatabase db, String name) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='$name'",
        )
        .get();
    return rows.isNotEmpty;
  }

  group('跳版升级：从每个历史版本升到当前 schemaVersion', () {
    for (final from in [1, 2, 3, 4]) {
      test('v$from → v5：保留旧数据，且补齐后续版本的表/列', () async {
        final file = await makeVersionedDb(from);
        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        // 1) 旧数据必须原样保留（onUpgrade 只加列/建表，绝不重建表）。
        final state = await DriftSyncStateStore(db).load(workspaceStateKey);
        expect(state.cursor, '2026-03-01T00:00:00Z', reason: 'v$from 升级不得丢游标');
        expect(state.files, hasLength(1), reason: 'v$from 升级不得丢文件记录');
        expect(state.files['g1/a.md']?.etag, 'W/"1"');
        expect(
          state.files['g1/a.md']?.contentHash,
          isNull,
          reason: '旧行新列默认 null → 脏检测降级为「无法检测」',
        );

        // 2) v3 起应有 cached_groups；v5 应始终有 cached_events 与 outbox_entries。
        if (from < 3) {
          expect(
            await tableExists(db, 'cached_groups'),
            isTrue,
            reason: 'v$from 升到 v5 必须建出 cached_groups',
          );
        }
        expect(
          await tableExists(db, 'cached_events'),
          isTrue,
          reason: 'v$from 升到 v5 必须建出 cached_events',
        );
        expect(
          await tableExists(db, 'outbox_entries'),
          isTrue,
          reason: 'v$from 升到 v5 必须建出 outbox_entries',
        );

        // 3) v2 起应有 content_hash 列（v1 升级时由 `from < 2` 补上）。
        //    用「写 hash 再读回」验证列真的可读写（建了表但列不对同样是坏的）。
        final store = DriftSyncStateStore(db);
        await store.save(
          workspaceStateKey,
          state.markSynced(
            'g1/a.md',
            etag: 'W/"1"',
            size: 100,
            contentHash: 'abc123',
          ),
        );
        expect(
          (await store.load(workspaceStateKey)).files['g1/a.md']?.contentHash,
          'abc123',
          reason: 'content_hash 列必须可写（v$from 升级后）',
        );

        // 4) v3 起已有的 cached_groups 行必须还在；v4 起 cached_events 同理。
        if (from >= 3) {
          final groups = await db
              .customSelect('SELECT id FROM cached_groups')
              .get();
          expect(
            groups.map((r) => r.data['id']),
            contains('g1'),
            reason: 'v$from 升级不得丢 cached_groups 行',
          );
        }
        if (from >= 4) {
          final events = await db
              .customSelect('SELECT global_seq FROM cached_events')
              .get();
          expect(
            events.map((r) => r.data['global_seq']),
            contains(7),
            reason: 'v$from 升级不得丢 cached_events 行',
          );
        }
      });
    }

    test('onUpgrade 条件必须是 `from < N`（反向验证：跳版不丢中间版本）', () async {
      // v1 直接升到 v5：四个分支都得跑。若有人把任一条改成 `from == N-1`，
      // v1 用户会缺对应的表/列——这条会失败（而 drift 自己不报错）。
      final file = await makeVersionedDb(1);
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // content_hash（v2 分支）
      final cols = await db
          .customSelect('PRAGMA table_info(synced_files)')
          .get();
      expect(
        cols.map((r) => r.data['name']),
        contains('content_hash'),
        reason: 'v2 分支（from < 2）必须在跳版时也执行',
      );
      // cached_groups（v3 分支）
      expect(await tableExists(db, 'cached_groups'), isTrue);
      // cached_events（v4 分支）
      expect(await tableExists(db, 'cached_events'), isTrue);
      // outbox_entries（v5 分支）
      expect(await tableExists(db, 'outbox_entries'), isTrue);
    });
  });

  group('openAppDatabaseAt（同步路径）', () {
    test('目录不存在时自动创建（recursive）', () async {
      final base = await Directory.systemTemp.createTemp('spb_data_open');
      addTearDown(() => base.delete(recursive: true));
      // 三层嵌套，确保 recursive: true 生效。
      final file = File('${base.path}/a/b/c/state.db');
      expect(file.parent.existsSync(), isFalse);

      final db = openAppDatabaseAt(file);
      addTearDown(db.close);

      // 懒开：构造时不建目录；首次查询才建。
      final store = DriftSyncStateStore(db);
      expect(await store.load(workspaceStateKey), SyncState.empty);
      expect(file.parent.existsSync(), isTrue, reason: '首次查询应建出目录');
      expect(file.existsSync(), isTrue, reason: '首次查询应建出库文件');
    });

    test('目录已存在时不报错（幂等）', () async {
      final dir = await Directory.systemTemp.createTemp('spb_data_open2');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.db');

      final db = openAppDatabaseAt(file);
      addTearDown(db.close);
      expect(await DriftSyncStateStore(db).load('k'), SyncState.empty);
    });

    test('建目录失败不抛（记 warn，由下游以「打开失败」暴露）', () async {
      // 用一个「父路径是文件」的路径制造 FileSystemException。
      final dir = await Directory.systemTemp.createTemp('spb_data_open3');
      addTearDown(() => dir.delete(recursive: true));
      final blocker = File('${dir.path}/blocker');
      await blocker.writeAsString('x');
      // blocker/state.db 的父目录是 blocker（一个文件）→ createSync 失败。
      final file = File('${blocker.path}/state.db');

      // 捕获日志：建目录失败必须记 warn（否则用户只看到「同步没反应」）。
      final sink = _CapturingSink();
      final old = SpbLog.configure(sink: sink);
      addTearDown(() => SpbLog.configure(sink: old));

      // 构造本身不该抛（懒开）。
      final db = openAppDatabaseAt(file);
      addTearDown(db.close);

      // `DriftSyncStateStore.load` 对**读失败**静默降级为 empty（可丢弃数据语义），
      // 故这里不会抛——但 warn 必须记下（建目录失败不能无声无息）。
      expect(
        await DriftSyncStateStore(db).load(workspaceStateKey),
        SyncState.empty,
      );
      expect(
        sink.messages.any((m) => m.contains('创建数据库目录失败')),
        isTrue,
        reason: '建目录失败必须记 warn',
      );
    });

    test('库打不开时直接查询会抛（不被 load 的静默降级掩盖）', () async {
      final dir = await Directory.systemTemp.createTemp('spb_data_open4');
      addTearDown(() => dir.delete(recursive: true));
      final blocker = File('${dir.path}/blocker');
      await blocker.writeAsString('x');
      final file = File('${blocker.path}/state.db');

      final old = SpbLog.configure(sink: const NullLogSink());
      addTearDown(() => SpbLog.configure(sink: old));

      final db = openAppDatabaseAt(file);
      addTearDown(db.close);

      // 绕过 store 的 catch，直接查——证明「打不开」是真的失败。
      await expectLater(
        db.customSelect('SELECT 1').get(),
        throwsA(isA<Object>()),
      );
    });
  });

  group('openAppDatabaseLazy（异步解析路径）', () {
    test('resolve 只在首次查询时被调用（懒开语义）', () async {
      final dir = await Directory.systemTemp.createTemp('spb_data_lazy');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/nested/state.db');

      var calls = 0;
      final db = openAppDatabaseLazy(() async {
        calls++;
        return file;
      });
      addTearDown(db.close);

      // 构造 AppDatabase 不应触发平台通道（对 widget test 很重要）。
      expect(calls, 0, reason: 'resolve 必须推迟到首次查询');

      expect(
        await DriftSyncStateStore(db).load(workspaceStateKey),
        SyncState.empty,
      );
      expect(calls, greaterThan(0), reason: '首次查询才解析路径');
      expect(file.parent.existsSync(), isTrue, reason: '应建出目录');
      expect(file.existsSync(), isTrue, reason: '应建出库文件');
    });

    test('resolve 抛错时不被 store 的静默降级掩盖（直接查询会抛）', () async {
      final old = SpbLog.configure(sink: const NullLogSink());
      addTearDown(() => SpbLog.configure(sink: old));

      final db = openAppDatabaseLazy(
        () async => throw StateError('no app dir'),
      );
      // ⚠️ 不用 addTearDown(db.close)：drift 的 `LazyDatabase.close()` 会 await
      // 那个已失败的 completer 并把 StateError 重抛，而 tearDown 里抛错会被记成
      // 「测试失败」——掩盖真正的断言。故在用例末尾自行吞掉。

      // `load` 会把读失败降级为 empty（可丢弃数据语义），故直接查以证明
      // 「resolve 抛错」不会被吞掉。
      // 用回调形式：抛错是**同步**发生在 `.get()` 求值时，直接传 Future 的
      // `expectLater` 接不住（测试会在那行就炸）。
      await expectLater(
        () => db.customSelect('SELECT 1').get(),
        throwsA(isA<StateError>()),
      );
      await _closeIgnoringOpenError(db);
    });

    test('resolve 抛错时 load 静默降级 + 记 warn', () async {
      final sink = _CapturingSink();
      final old = SpbLog.configure(sink: sink);
      addTearDown(() => SpbLog.configure(sink: old));

      final db = openAppDatabaseLazy(
        () async => throw StateError('no app dir'),
      );

      expect(
        await DriftSyncStateStore(db).load(workspaceStateKey),
        SyncState.empty,
      );
      expect(
        sink.messages.any((m) => m.contains('读取同步状态失败')),
        isTrue,
        reason: '读失败必须记 warn（否则无声无息）',
      );
      await _closeIgnoringOpenError(db);
    });

    test('建目录失败记 warn，且不拖垮「打开」（与同步版同形）', () async {
      // 与 `openAppDatabaseAt` 的对应用例对称：两条路径各有一份建目录代码，
      // 只测其一会让另一条的错误处理成为无覆盖分支。
      final dir = await Directory.systemTemp.createTemp('spb_data_lazy2');
      addTearDown(() => dir.delete(recursive: true));
      final blocker = File('${dir.path}/blocker');
      await blocker.writeAsString('x');
      final file = File('${blocker.path}/state.db');

      final sink = _CapturingSink();
      final old = SpbLog.configure(sink: sink);
      addTearDown(() => SpbLog.configure(sink: old));

      final db = openAppDatabaseLazy(() async => file);
      addTearDown(db.close);

      // 建目录失败不抛（错误推迟到查询）。
      expect(
        await DriftSyncStateStore(db).load(workspaceStateKey),
        SyncState.empty,
      );
      expect(
        sink.messages.any((m) => m.contains('创建数据库目录失败')),
        isTrue,
        reason: '建目录失败必须记 warn',
      );
    });
  });
}

/// 关闭库，吞掉「首次打开失败」在 close 时的重抛。
///
/// `LazyDatabase.close()` 会 await 已失败的 opener future 并重抛——若走
/// `addTearDown(db.close)`，该错误会被记成测试失败，掩盖真正的断言结果。
Future<void> _closeIgnoringOpenError(AppDatabase db) async {
  try {
    await db.close();
  } catch (_) {
    // 打开失败的库，关闭时的重抛无意义。
  }
}

/// 把 `NativeDatabase` 开在指定版本上且不跑任何迁移。
///
/// `beforeOpen` 必须不碰库体；`PRAGMA user_version` 由 drift 在迁移结束后写回
/// [schemaVersion]，故这里天然留下我们设定的版本号。
class _RawVersionUser implements QueryExecutorUser {
  _RawVersionUser(this.schemaVersion);

  @override
  final int schemaVersion;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// 捕获日志文本的 sink（断言 warn 是否记下）。
class _CapturingSink implements LogSink {
  final messages = <String>[];

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    messages.add(message);
  }
}
