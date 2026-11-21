import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';

/// 造一条待投递消息。
OutboxEntry _entry({
  String id = 'req-1',
  String userId = 'u1',
  String input = '你好',
  String? groupId,
  String? agentId,
  String routingMode = 'auto',
  int attempts = 0,
  DateTime? createdAt,
  DateTime? nextAttemptAt,
  String? lastError,
}) {
  final now = createdAt ?? DateTime.utc(2026, 1, 1, 12);
  return OutboxEntry(
    id: id,
    userId: userId,
    input: input,
    groupId: groupId,
    agentId: agentId,
    routingMode: routingMode,
    createdAt: now,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt ?? now,
    lastError: lastError,
  );
}

void main() {
  late AppDatabase db;
  late DriftOutboxStore store;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = DriftOutboxStore(db);
  });

  tearDown(() async => db.close());

  group('DriftOutboxStore 基本读写', () {
    test('upsert 后 load 能读回全部字段', () async {
      final entry = _entry(
        id: 'req-abc',
        userId: 'u1',
        input: '帮我写个测试',
        groupId: 'g1',
        agentId: 'a1',
        routingMode: 'pinned',
        attempts: 3,
        lastError: '连接超时',
      );
      await store.upsert(entry);

      final rows = await store.load('u1');
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.id, 'req-abc');
      expect(r.userId, 'u1');
      expect(r.input, '帮我写个测试');
      expect(r.groupId, 'g1');
      expect(r.agentId, 'a1');
      expect(r.routingMode, 'pinned');
      expect(r.attempts, 3);
      expect(r.lastError, '连接超时');
      // 时刻经 millisecondsSinceEpoch 往返：**不能断言 DateTime 对象相等**
      // （本地/UTC 的 isUtc 标志会丢），要比微秒值。
      expect(
        r.createdAt.millisecondsSinceEpoch,
        entry.createdAt.millisecondsSinceEpoch,
      );
      expect(
        r.nextAttemptAt.millisecondsSinceEpoch,
        entry.nextAttemptAt.millisecondsSinceEpoch,
      );
    });

    test('maxAttempts 往返（决定 status 何时变 failed）', () async {
      // 它是「自定义重试上限」能否生效的关键：若读回时丢了它，条目会退回
      // 默认 10，用户设的 maxAttempts=3 永远不生效（无限重试）。
      await store.upsert(_entry(id: 'r1'));
      expect((await store.load('u1')).single.maxAttempts, 10);

      final custom = OutboxEntry(
        id: 'r2',
        userId: 'u1',
        input: 'x',
        createdAt: DateTime.utc(2026),
        nextAttemptAt: DateTime.utc(2026),
        maxAttempts: 3,
      );
      await store.upsert(custom);
      final r2 = (await store.load('u1')).firstWhere((e) => e.id == 'r2');
      expect(r2.maxAttempts, 3);
    });

    test('groupId / agentId 为 null 时原样读回 null（无归属入口语义）', () async {
      // ⚠️ 这是本 store 最容易被写错的一处：`Value(null)` 与
      // `Value.absent()` 在 drift 里语义不同。若误用 absent，`groupId` 会
      // 保留旧值（或默认值），而「null = 让服务端判定归属」就被静默破坏。
      await store.upsert(_entry(id: 'req-null', groupId: null, agentId: null));

      final r = (await store.load('u1')).single;
      expect(r.groupId, isNull);
      expect(r.agentId, isNull);
    });

    test('null 覆盖非 null：同一 id 二次 upsert 能把 groupId 清成 null', () async {
      // 上一测试只验证「一开始就是 null」。真正区分 Value(null) 与
      // Value.absent() 的是**更新**路径：absent 会保留 'g1'。
      await store.upsert(_entry(id: 'req-x', groupId: 'g1'));
      await store.upsert(_entry(id: 'req-x', groupId: null));

      final r = (await store.load('u1')).single;
      expect(r.groupId, isNull, reason: 'absent 会让这里仍是 g1');
    });

    test('同一 id 二次 upsert 是更新而非插入（主键幂等）', () async {
      await store.upsert(_entry(id: 'req-1', attempts: 0));
      await store.upsert(_entry(id: 'req-1', attempts: 5, lastError: '失败'));

      final rows = await store.load('u1');
      expect(rows, hasLength(1), reason: '重试不该产生新行');
      expect(rows.single.attempts, 5);
      expect(rows.single.lastError, '失败');
    });

    test('load 按 createdAt 升序（FIFO 的依据）', () async {
      final base = DateTime.utc(2026, 1, 1, 12);
      // 故意乱序写入。
      await store.upsert(
        _entry(id: 'c', createdAt: base.add(const Duration(minutes: 2))),
      );
      await store.upsert(_entry(id: 'a', createdAt: base));
      await store.upsert(
        _entry(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );

      final ids = (await store.load('u1')).map((e) => e.id).toList();
      // 顺序是**语义性**的：两条消息调换顺序会改变对话含义（设计文档
      // §7bis.5 的「严格全局 FIFO」）。故这里钉住排序，而不只断言集合。
      expect(ids, ['a', 'b', 'c']);
    });

    test('load 只返回该 userId 的条目（多账号隔离）', () async {
      await store.upsert(_entry(id: 'r1', userId: 'u1'));
      await store.upsert(_entry(id: 'r2', userId: 'u2'));

      expect((await store.load('u1')).map((e) => e.id), ['r1']);
      expect((await store.load('u2')).map((e) => e.id), ['r2']);
      expect(await store.load('u3'), isEmpty);
    });
  });

  group('删除与清空', () {
    test('delete 只删指定 id', () async {
      await store.upsert(_entry(id: 'r1'));
      await store.upsert(_entry(id: 'r2'));

      await store.delete('r1');

      expect((await store.load('u1')).map((e) => e.id), ['r2']);
    });

    test('delete 不存在的 id 不抛（幂等）', () async {
      await store.upsert(_entry(id: 'r1'));
      await store.delete('不存在');
      expect(await store.load('u1'), hasLength(1));
    });

    test('clear 只清该用户（换账号登录不该删掉别人的未发送消息）', () async {
      await store.upsert(_entry(id: 'r1', userId: 'u1'));
      await store.upsert(_entry(id: 'r2', userId: 'u2'));

      await store.clear('u1');

      expect(await store.load('u1'), isEmpty);
      expect((await store.load('u2')).map((e) => e.id), ['r2']);
    });
  });

  group('存储失败**不**静默降级（与 A/B 两个 store 相反）', () {
    test('库关闭后 load 抛 StorageError 而不是返回空表', () async {
      await store.upsert(_entry(id: 'r1'));
      // 先成功读一次：drift 的 `close()` **不**会拦下已排队的写（内存执行器
      // 的写是缓冲的），故必须先真正打开过库，`close` 才会让后续操作失败。
      // 不加这一行，`upsert` 在关闭后「成功」返回——测试会以错误的原因变绿。
      expect(await store.load('u1'), hasLength(1));
      await db.close();

      // ## 为什么这条断言是切片 C 的核心
      //
      // `DriftGroupCacheStore` / `DriftTimelineCacheStore` 的读失败返回空
      // ——那是可丢弃数据，空表与真值无区别。本 store 装的是**用户敲进去、
      // 还没发出去的文本**：返回空表等于「假装队列是空的」，用户会以为
      // 消息丢了（或重打一遍，发两条）。
      await expectLater(store.load('u1'), throwsA(isA<StorageError>()));
    });

    test('库关闭后 upsert 抛 StorageError（而非假装排队成功）', () async {
      // 同上：必须先真正打开过库，`close` 才会让写失败。
      await store.load('u1');
      await db.close();

      await expectLater(
        store.upsert(_entry(id: 'r1')),
        throwsA(isA<StorageError>()),
      );
    });

    test('库关闭后 delete 抛 StorageError（而非静默以为删掉了）', () async {
      // ## 这条补的是一个「反向验证为 0」的缺口
      //
      // 设计文档 §7bis.11 曾记：`delete` 的失败路径无用例覆盖，去掉 try/catch
      // 也没有测试变红。但这条路径**真的有用户可见后果**——队列里删不掉的
      // 条目会被 `drain` 反复投递（`remove` 失败后内存回滚，条目还在），
      // 静默吞掉异常会让调用方以为「已丢弃」，实际上重启后它又回来了。
      //
      // 同前两条：必须先真正打开过库，`close` 才会让后续操作失败。
      await store.upsert(_entry(id: 'r1'));
      expect(await store.load('u1'), hasLength(1));
      await db.close();

      await expectLater(store.delete('r1'), throwsA(isA<StorageError>()));
    });

    test('库关闭后 clear 抛 StorageError（而非假装队列已清空）', () async {
      await store.load('u1');
      await db.close();

      await expectLater(store.clear('u1'), throwsA(isA<StorageError>()));
    });

    test('StorageError 的 message 指得出是队列的哪一步', () async {
      await store.load('u1');
      await db.close();
      try {
        await store.load('u1');
        fail('应当抛出');
      } on StorageError catch (e) {
        // 报错信息要能定位：只说「数据库错误」在日志里指不到是离线队列。
        expect(e.message, contains('离线队列'));
        expect(e.cause, isNotNull);
      }
    });
  });

  group('schema 迁移 v4 → v5', () {
    test('v4 库升级后 outbox_entries 表存在且可读写（旧数据不丢）', () async {
      final dir = await Directory.systemTemp.createTemp('spb_ob_mig');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.db');

      // 造一个 v4 库：先按当前 schema 建，再手工降 user_version 到 4 并删表。
      //
      // ## 为什么不用手写建表 SQL
      //
      // 那样得维护全部 6 张表的 SQL 副本，任何 schema 变动都会让测试与实现
      // 脱节。反过来做：先用真实 schema 建好（onCreate 走 createAll），再把
      // outbox_entries 删掉 + 版本号回退到 4——得到的库与「v4 时代」结构上
      // 等价，且不需要维护 SQL 副本。
      final setup = AppDatabase(NativeDatabase(file));
      await setup.customStatement('DROP TABLE outbox_entries');
      await setup.customStatement('PRAGMA user_version = 4');
      // 留一行 v4 时代的数据（cached_groups，切片 A 的表）。
      await setup.customStatement(
        "INSERT INTO cached_groups (id, user_id, payload, fetched_at) "
        "VALUES ('g1', 'usr_1', '{\"id\":\"g1\"}', 1000)",
      );
      await setup.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // ⚠️ 必须直接查 sqlite_master，不能通过 store 断言「表建出来了」。
      // 本 store 的失败**不**静默降级（那是它与 A/B 的关键差异），但「表
      // 不存在」与「表存在」在 SQL 层才可分辨——用 store 会把「迁移漏建表」
      // 报成一个存储错误，指不到迁移。
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='outbox_entries'",
          )
          .get();
      expect(tables, hasLength(1), reason: 'v5 新表必须存在');

      // 再确认可读写（建了表但列不对同样是坏的）。
      final store = DriftOutboxStore(db);
      await store.upsert(_entry(id: 'r1', userId: 'usr_1'));
      expect((await store.load('usr_1')).map((e) => e.id), ['r1']);

      // 既有表数据不得丢。
      final rows = await db.customSelect('SELECT id FROM cached_groups').get();
      expect(rows.map((r) => r.data['id']), contains('g1'));
    });

    test('v1 库**跳版**升到 v5：四张新表都建出来（from < N 而不是 ==）', () async {
      // 反向验证：把 `if (from < 5)` 改成 `if (from == 4)` → v1 用户升到 v5
      // 后没有 outbox_entries，本用例失败。drift 不会在升级时报错，直到某次
      // 查询碰到那张表才炸（且报错信息指不到迁移）。
      final dir = await Directory.systemTemp.createTemp('spb_ob_jump');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.db');

      final raw = NativeDatabase(file);
      await raw.ensureOpen(_V1User());
      await raw.runCustom(
        'CREATE TABLE sync_cursors (state_key TEXT NOT NULL, cursor TEXT NULL, '
        'PRIMARY KEY (state_key))',
      );
      await raw.runCustom(
        'CREATE TABLE synced_files (state_key TEXT NOT NULL, '
        'rel_path TEXT NOT NULL, etag TEXT NULL, size INTEGER NOT NULL, '
        'updated_at TEXT NULL, PRIMARY KEY (state_key, rel_path))',
      );
      await raw.runCustom(
        'CREATE TABLE sync_bindings (id INTEGER NOT NULL, local_root TEXT NULL, '
        'PRIMARY KEY (id))',
      );
      await raw.runCustom(
        'CREATE TABLE preferences (key TEXT NOT NULL, value TEXT NOT NULL, '
        'PRIMARY KEY (key))',
      );
      await raw.runCustom('PRAGMA user_version = 1');
      await raw.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final tableRows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('cached_groups', 'cached_events', 'outbox_entries')",
          )
          .get();
      final names = tableRows.map((r) => r.data['name']).toSet();
      expect(names, contains('cached_groups'), reason: 'v1→v5 必须建 v3 的表');
      expect(names, contains('cached_events'), reason: 'v1→v5 必须建 v4 的表');
      expect(names, contains('outbox_entries'), reason: 'v1→v5 必须建 v5 的表');

      // v2 的加列也要跑。
      final cols = await db
          .customSelect("PRAGMA table_info('synced_files')")
          .get();
      expect(
        cols.map((r) => r.data['name']),
        contains('content_hash'),
        reason: 'v1→v5 必须补上 v2 的列',
      );

      // v5 建表必须带 max_attempts 列（漏了它 status 永远判不出 failed）。
      final outboxCols = await db
          .customSelect("PRAGMA table_info('outbox_entries')")
          .get();
      expect(
        outboxCols.map((r) => r.data['name']),
        contains('max_attempts'),
        reason: 'v5 的 createTable 必须带上该列',
      );
    });
  });
}

/// v1 时代的空 schema 用户（只为拿到一个未迁移的 executor，见 `beforeOpen`）。
class _V1User extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
