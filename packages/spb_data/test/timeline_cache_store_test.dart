import 'dart:io';

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 建一个内存库（每个用例独立，互不干扰）。
AppDatabase _memoryDb() => AppDatabase(NativeDatabase.memory());

/// 造一条可缓存事件（落库事件：非 transient / 非 diagnostic / 有 globalSeq）。
ChatEvent _event(
  int globalSeq, {
  String groupId = 'grp_1',
  String type = EventTypes.message,
  Map<String, dynamic>? payload,
  String? eventId,
  bool transient = false,
  bool diagnostic = false,
  int seq = 1,
  String turnId = 'turn_1',
}) {
  return ChatEvent(
    eventId: eventId ?? 'evt_$globalSeq',
    userId: 'usr_1',
    groupId: groupId,
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: globalSeq,
    source: 'agent',
    createdAt: DateTime.utc(2026, 3, 1).add(Duration(seconds: globalSeq)),
    payload: payload ?? {'text': 'msg $globalSeq'},
    transient: transient,
    diagnostic: diagnostic,
  );
}

void main() {
  group('isCacheableEvent：哪些事件能进缓存（issue #29）', () {
    test('落库事件可缓存', () {
      expect(isCacheableEvent(_event(1)), isTrue);
    });

    test('transient 事件不可缓存（服务端不落库，_backfill 拿不回来）', () {
      // 反向验证：去掉 `if (event.transient) return false;` → 本用例失败。
      expect(isCacheableEvent(_event(1, transient: true)), isFalse);
    });

    test('diagnostic 事件不可缓存（默认不进时间线）', () {
      // 反向验证：去掉 `if (event.diagnostic) return false;` → 本用例失败。
      expect(isCacheableEvent(_event(1, diagnostic: true)), isFalse);
    });

    test('goal_updated 不可缓存（服务端漏设 transient 但不落库）', () {
      // 这是**唯一**按 eventType 排除的一类：服务端 `emitGoalUpdated` 漏设
      // Transient，故 `transient` 判据咬不到它，必须显式排除。
      //
      // 反向验证：去掉 eventType 判据 → 本用例失败。
      expect(
        isCacheableEvent(
          _event(1, type: EventTypes.goalUpdated, transient: false),
        ),
        isFalse,
      );
    });

    test('globalSeq 为 null（本地乐观回显）不可缓存', () {
      final local = ChatEvent(
        eventId: 'local-123',
        userId: 'usr_1',
        groupId: 'grp_1',
        turnId: 'turn_1',
        eventType: EventTypes.userMessage,
        seq: 0,
        source: 'user',
        createdAt: DateTime.utc(2026, 3, 1),
        transient: true,
      );
      expect(isCacheableEvent(local), isFalse);
    });

    test('globalSeq <= 0 不可缓存（未落库事件）', () {
      // 反向验证：把 `g <= 0` 放宽为 `g < 0` → 本用例失败。
      expect(isCacheableEvent(_event(0)), isFalse);
      expect(isCacheableEvent(_event(-1)), isFalse);
    });
  });

  group('DriftTimelineCacheStore：round-trip', () {
    test('写入后读回：字段与 payload 原文一致', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [
        _event(1, payload: {'text': '你好'}),
        _event(2, type: EventTypes.thought, payload: {'text': '想想'}),
      ]);

      final back = await store.load('grp_1');
      expect(back, hasLength(2));
      expect(back[0].globalSeq, 1);
      expect(back[0].eventType, EventTypes.message);
      expect(back[0].payload?['text'], '你好');
      expect(back[1].globalSeq, 2);
      expect(back[1].eventType, EventTypes.thought);
      expect(back[1].payload?['text'], '想想');
    });

    test('无缓存返回空列表（**不抛异常**）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);
      expect(await store.load('never'), isEmpty);
    });

    test('group 之间互相隔离', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1)]);
      await store.save('grp_2', [_event(1, groupId: 'grp_2')]);

      expect((await store.load('grp_1')).single.payload?['text'], 'msg 1');
      expect(await store.load('grp_3'), isEmpty);
    });

    test('load 按 globalSeq **升序**返回（归约器的硬要求）', () async {
      // 反向验证：去掉 `orderBy(asc(globalSeq))` → SQLite 按 rowid 返回，
      // 乱序写入时顺序错乱，本用例失败。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      // 故意乱序写入：若实现依赖插入顺序（rowid）而不是显式排序，这里就会
      // 返回 5,1,3 —— 归约器会把它当时间正序处理，渲染顺序颠倒且**不报错**。
      await store.save('grp_1', [_event(5), _event(1), _event(3)]);

      expect((await store.load('grp_1')).map((e) => e.globalSeq), [1, 3, 5]);
    });

    test('load(limit) 取**最新**的 N 条且仍升序', () async {
      // 若实现写成「升序取前 N 条」，拿到的是最旧的 N 条——用户打开对话
      // 看到的是最早的历史，而不是最近的。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [for (var i = 1; i <= 10; i++) _event(i)]);

      final back = await store.load('grp_1', limit: 3);
      expect(back.map((e) => e.globalSeq), [8, 9, 10]);
    });

    test('save 是 **upsert**：重复 globalSeq 覆盖而非插两行', () async {
      // 反向验证：把 `insertOrReplace` 改成 `insert` → 主键冲突抛异常，
      // 被 catch 吞掉，第二次写入整批丢失，本用例失败。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [
        _event(1, payload: {'text': '旧'}),
      ]);
      await store.save('grp_1', [
        _event(1, payload: {'text': '新'}),
      ]);

      final back = await store.load('grp_1');
      expect(back, hasLength(1), reason: '同一 globalSeq 必须去重');
      expect(back.single.payload?['text'], '新', reason: '后写覆盖先写');
    });

    test('save 是**增量**：新页追加不丢旧页（与 GroupCacheStore 相反）', () async {
      // 反向验证：把 save 改成「先删后插」（照抄 GroupCacheStore）→ 第一页
      // 被删掉，本用例失败。timeline 是分页拉取的，整表替换会让用户断网时
      // 只能看到最后一页。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1), _event(2)]);
      await store.save('grp_1', [_event(3), _event(4)]);

      expect((await store.load('grp_1')).map((e) => e.globalSeq), [1, 2, 3, 4]);
    });

    test('clear 只清该 group', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1)]);
      await store.save('grp_2', [_event(1, groupId: 'grp_2')]);
      await store.clear('grp_1');

      expect(await store.load('grp_1'), isEmpty);
      expect(await store.load('grp_2'), hasLength(1));
    });

    test('不可缓存事件被实现层过滤掉（调用方无需自己筛）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [
        _event(1),
        _event(2, transient: true),
        _event(3, diagnostic: true),
        _event(4, type: EventTypes.goalUpdated),
      ]);

      expect((await store.load('grp_1')).map((e) => e.globalSeq), [1]);
    });

    test('全部不可缓存时不写入（不留空行）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1, transient: true)]);
      expect(await store.load('grp_1'), isEmpty);
    });
  });

  group('DriftTimelineCacheStore：三层体积上限（§5.2）', () {
    // 体积上限是**字节**数，而一条事件的序列化长度随字段变化。硬编码
    // 预算很容易因 `ChatEvent.toJson` 增删一个字段就失效（且失效方向不确定：
    // 可能变成「上限根本没触发」，用例静默变成空转）。故按真实序列化长度算。
    int bytesOf(List<ChatEvent> events) => events
        .map((e) => utf8.encode(jsonEncode(e.toJson())).length)
        .fold(0, (a, b) => a + b);

    test('每 group 条数上限：超出丢弃**最旧**的', () async {
      // 反向验证：去掉 `_trimGroup` → 全部 10 条都在，本用例失败。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventsPerGroup: 4);

      await store.save('grp_1', [for (var i = 1; i <= 10; i++) _event(i)]);

      final back = await store.load('grp_1');
      expect(back, hasLength(4));
      expect(back.map((e) => e.globalSeq), [
        7,
        8,
        9,
        10,
      ], reason: '丢最旧、留最新——时间线以最新为焦点');
    });

    test('每 group 上限是**分次写入累计**的（不是只看单次）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventsPerGroup: 3);

      await store.save('grp_1', [_event(1), _event(2)]);
      await store.save('grp_1', [_event(3), _event(4)]);
      await store.save('grp_1', [_event(5)]);

      expect((await store.load('grp_1')).map((e) => e.globalSeq), [3, 4, 5]);
    });

    test('每 group 上限不跨 group 误删', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventsPerGroup: 2);

      await store.save('grp_1', [for (var i = 1; i <= 5; i++) _event(i)]);
      await store.save('grp_2', [
        for (var i = 1; i <= 5; i++) _event(i, groupId: 'grp_2'),
      ]);

      expect(await store.load('grp_1'), hasLength(2));
      expect(await store.load('grp_2'), hasLength(2));
    });

    test('单 payload 上限：超限事件**不缓存**（不截断）', () async {
      // 反向验证：去掉 payload 长度检查 → 超大事件被缓存，本用例失败。
      //
      // 断言「不缓存」而不是「被截断」：截断会产生一个「看起来完整但内容
      // 缺失」的事件，比缺席更糟——归约器会把它当权威帧（§5.2）。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventPayloadBytes: 200);

      final huge = 'x' * 5000;
      await store.save('grp_1', [
        _event(1, payload: {'text': '小'}),
        _event(2, payload: {'text': huge}),
        _event(3, payload: {'text': '也小'}),
      ]);

      final back = await store.load('grp_1');
      expect(back.map((e) => e.globalSeq), [1, 3], reason: '超限的 2 号跳过，其余照常缓存');
      expect(
        back.every((e) => !(e.payload?['text'] as String).startsWith('xxx')),
        isTrue,
      );
    });

    test('单 payload 上限：其余事件不受影响（跳过而非整批放弃）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventPayloadBytes: 200);

      await store.save('grp_1', [
        _event(1, payload: {'text': 'y' * 5000}),
      ]);
      expect(await store.load('grp_1'), isEmpty);

      // 同一 store 的下一次写入仍正常（没有把连接/事务弄坏）。
      await store.save('grp_1', [_event(2)]);
      expect((await store.load('grp_1')).map((e) => e.globalSeq), [2]);
    });

    test('全库总字节上限：超出按 lastAccessedAt 升序淘汰**整 group**', () async {
      // 反向验证：去掉 `_evictIfOversized` → 全部 group 都在，本用例失败。
      final db = _memoryDb();
      addTearDown(db.close);

      final groupA = [
        for (var i = 1; i <= 4; i++) _event(i, groupId: 'grp_old'),
      ];
      final groupB = [
        for (var i = 1; i <= 4; i++) _event(i, groupId: 'grp_new'),
      ];
      final oneGroup = bytesOf(groupA);
      // 预算 = 一个 group 多一点点：装得下一个、装不下两个。
      final store = DriftTimelineCacheStore(
        db,
        maxTotalBytes: oneGroup + oneGroup ~/ 2,
      );

      await store.save('grp_old', groupA);
      // 显式推进时间，保证 lastAccessedAt 不同（同一毫秒内排序不确定）。
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.save('grp_new', groupB);

      final old = await store.load('grp_old');
      final fresh = await store.load('grp_new');
      // 关键不变式：**整 group** 淘汰——不允许出现「半截历史」。
      expect(
        old.isEmpty || old.length == 4,
        isTrue,
        reason: '要么整份保留、要么整份淘汰；不允许留下半截',
      );
      expect(
        fresh.isEmpty || fresh.length == 4,
        isTrue,
        reason: '要么整份保留、要么整份淘汰；不允许留下半截',
      );
      expect(old.isEmpty, isTrue, reason: '最久未访问的 grp_old 应被淘汰');
      expect(fresh, hasLength(4), reason: '刚写入的 grp_new 应完整保留');
    });

    test('全库淘汰按「最久未访问」优先', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      final groupA = [for (var i = 1; i <= 3; i++) _event(i, groupId: 'grp_a')];
      final groupB = [for (var i = 1; i <= 3; i++) _event(i, groupId: 'grp_b')];
      final groupC = [for (var i = 1; i <= 3; i++) _event(i, groupId: 'grp_c')];
      final one = bytesOf(groupA);
      // 预算 = 两个 group 多一点点：装得下两个、装不下三个。
      final store = DriftTimelineCacheStore(
        db,
        maxTotalBytes: one * 2 + one ~/ 2,
      );

      await store.save('grp_a', groupA);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.save('grp_b', groupB);
      // 读一下 a（刷新它的 lastAccessedAt），再写入让总量超限。
      expect(await store.load('grp_a'), hasLength(3));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.save('grp_c', groupC);

      // b 最久未访问 → 应被优先淘汰；a 刚读过 → 应保留。
      expect(await store.load('grp_b'), isEmpty, reason: '最久未访问的 group 先被淘汰');
      expect(
        await store.load('grp_a'),
        hasLength(3),
        reason: '刚访问过的 group 不应被淘汰',
      );
      expect(await store.load('grp_c'), hasLength(3));
    });

    test('淘汰不影响其他 group 的完整历史', () async {
      final db = _memoryDb();
      addTearDown(db.close);

      final groupA = [for (var i = 1; i <= 3; i++) _event(i, groupId: 'grp_1')];
      final groupB = [for (var i = 1; i <= 3; i++) _event(i, groupId: 'grp_2')];
      final one = bytesOf(groupA);
      final store = DriftTimelineCacheStore(db, maxTotalBytes: one + one ~/ 2);

      await store.save('grp_1', groupA);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.save('grp_2', groupB);

      // grp_1 被淘汰（整份），grp_2 完整保留——不允许出现半截。
      expect(await store.load('grp_1'), isEmpty);
      expect(await store.load('grp_2'), hasLength(3));
    });
  });

  group('DriftTimelineCacheStore：健壮性', () {
    test('坏 payload 行被跳过，其余行照常返回', () async {
      // 单行损坏（截断 / 手工改库）不能让整份缓存作废。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1), _event(2)]);
      // 手工把 1 号写成非法 JSON。
      await db.customStatement(
        "UPDATE cached_events SET payload = '{bad' "
        "WHERE group_id = 'grp_1' AND global_seq = 1",
      );

      final back = await store.load('grp_1');
      expect(back.map((e) => e.globalSeq), [2]);
    });

    test('payload 是合法 JSON 但不是对象 → 跳过该行', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1), _event(2)]);
      await db.customStatement(
        "UPDATE cached_events SET payload = '[1,2,3]' "
        "WHERE group_id = 'grp_1' AND global_seq = 1",
      );

      expect((await store.load('grp_1')).map((e) => e.globalSeq), [2]);
    });

    test('表被删掉后 load 返回空列表（**不抛**，与 GroupCacheStore 同取向）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await store.save('grp_1', [_event(1)]);
      await db.customStatement('DROP TABLE cached_events');

      // 关键：抛异常会让对话页在断网时**再崩一次**（回填 catch 里再抛）。
      expect(await store.load('grp_1'), isEmpty);
    });

    test('表被删掉后 save 静默失败（**不抛**）', () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db);

      await db.customStatement('DROP TABLE cached_events');
      await expectLater(store.save('grp_1', [_event(1)]), completes);

      // 库仍可用：后续查询正常。
      expect(await store.load('grp_1'), isEmpty);
    });

    test('payload 以 UTF-8 字节计（不是字符数）', () async {
      // 中文在 UTF-8 里占 3 字节。若按 `String.length` 判上限，一个
      // 25k 汉字的事件（25k 字符 / 75KB 字节）会被误判为「未超限」而写入。
      final db = _memoryDb();
      addTearDown(db.close);
      final store = DriftTimelineCacheStore(db, maxEventPayloadBytes: 1000);

      final cjk = '中' * 500; // 500 字符 = 1500 字节 > 1000
      expect(utf8.encode(jsonEncode({'text': cjk})).length, greaterThan(1000));
      expect(jsonEncode({'text': cjk}).length, lessThan(1500));

      await store.save('grp_1', [
        _event(1, payload: {'text': cjk}),
      ]);
      expect(await store.load('grp_1'), isEmpty, reason: '按字节计才拦住');
    });
  });

  group('schemaVersion 3 → 4 迁移（issue #29）', () {
    test('v3 库升级后 cached_events 表存在且可读写', () async {
      final dir = await Directory.systemTemp.createTemp('spb_tl_mig');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.db');

      // 造一个 v3 库：先按当前 schema 建，再手工降 user_version 到 3 并删表。
      //
      // ## 为什么不用 _V3User 直接开在 v3
      //
      // 那样得手写全部 6 张表的建表 SQL，任何 schema 变动都会让测试与实现
      // 脱节。这里反过来：先用真实 schema 建好（onCreate 走 createAll），
      // 再把 cached_events 删掉 + 版本号回退到 3——得到的库与「v3 时代」
      // 结构上等价，且不需要维护 SQL 副本。
      final setup = AppDatabase(NativeDatabase(file));
      await setup.customStatement('DROP TABLE cached_events');
      await setup.customStatement('PRAGMA user_version = 3');
      // 留一行 v3 时代的数据（cached_groups，切片 A 的表）。
      await setup.customStatement(
        "INSERT INTO cached_groups (id, user_id, payload, fetched_at) "
        "VALUES ('g1', 'usr_1', '{\"id\":\"g1\"}', 1000)",
      );
      await setup.close();

      // 用当前版本打开：onUpgrade 3→4 应建表。
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // ⚠️ 必须直接查 sqlite_master，不能通过 store.load 断言。
      // store 的失败是**静默降级**的（读失败返回空列表），故
      // `expect(await store.load(...), isEmpty)` 对「迁移漏建表」完全无效
      // ——「表不存在」与「表存在但没有行」在 store 层无法区分。
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='cached_events'",
          )
          .get();
      expect(
        tables.map((r) => r.data['name']),
        contains('cached_events'),
        reason: 'v4 新表必须存在',
      );

      // 再确认可读写（建了表但列不对同样是坏的）。
      final store = DriftTimelineCacheStore(db);
      await store.save('grp_1', [_event(1)]);
      expect((await store.load('grp_1')).map((e) => e.globalSeq), [1]);

      // 既有表数据不得丢。
      final rows = await db.customSelect('SELECT id FROM cached_groups').get();
      expect(rows.map((r) => r.data['id']), contains('g1'));
    });

    test('v1 库**跳版**升到 v4：三张新表都建出来（from < N 而不是 ==）', () async {
      // 反向验证：把 `if (from < 4)` 改成 `if (from == 3)` → v1 用户升到 v4
      // 后没有 cached_events，本用例失败。drift 不会在升级时报错，直到某次
      // 查询碰到那张表才炸（且报错信息指不到迁移）。
      final dir = await Directory.systemTemp.createTemp('spb_tl_jump');
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
      await raw.runCustom(
        "INSERT INTO sync_cursors (state_key, cursor) "
        "VALUES ('$workspaceStateKey', '2026-03-01T00:00:00Z')",
      );
      await raw.runCustom('PRAGMA user_version = 1');
      await raw.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('cached_groups', 'cached_events')",
          )
          .get();
      final names = tables.map((r) => r.data['name']).toSet();
      expect(names, contains('cached_groups'), reason: 'v1→v4 必须建 v3 的表');
      expect(names, contains('cached_events'), reason: 'v1→v4 必须建 v4 的表');

      // v2 的加列也要跑。
      final cols = await db
          .customSelect("PRAGMA table_info('synced_files')")
          .get();
      expect(
        cols.map((r) => r.data['name']),
        contains('content_hash'),
        reason: 'v1→v4 必须补上 v2 的列',
      );
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
