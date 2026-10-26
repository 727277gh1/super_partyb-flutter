import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

/// 交付物同步执行：失败不变量 / 路径穿越防御 / 并发 IO
///
/// ⚠️ 本文件由 `deliverable_sync_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/deliverable_sync_harness.dart`。
void main() {
  group('同步执行：失败与状态不变量', () {
    test('失败项不写状态（否则永久漏更新）', () async {
      final sink = StubSink();
      final downloader = StubDownloader();
      downloader.errors['bad'] = '网络超时';
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [
          UfsFileEntry.fromJson({
            'id': 'ok',
            'path': '/workspace/groups/$gidFixture/ok.md/',
            'name': 'ok.md',
            'size': 5,
            'etag': 'W/"1"',
            'updated_at': '2026-05-01T00:00:00Z',
          }),
          UfsFileEntry.fromJson({
            'id': 'bad',
            'path': '/workspace/groups/$gidFixture/bad.md/',
            'name': 'bad.md',
            'size': 5,
            'etag': 'W/"2"',
            'updated_at': '2026-05-09T00:00:00Z',
          }),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
      final sink = StubSink();
      final downloader = StubDownloader();
      downloader.errors['bad'] = '网络超时';
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [
          UfsFileEntry.fromJson({
            'id': 'ok',
            'path': '/workspace/groups/$gidFixture/ok.md/',
            'name': 'ok.md',
            'size': 5,
            'updated_at': '2026-05-01T00:00:00Z',
          }),
          // 失败项的 updated_at 更晚：若用计划里最大时间推进游标，
          // 就会越过它，下轮再也拉不到这个文件。
          UfsFileEntry.fromJson({
            'id': 'bad',
            'path': '/workspace/groups/$gidFixture/bad.md/',
            'name': 'bad.md',
            'size': 5,
            'updated_at': '2026-05-09T00:00:00Z',
          }),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.failed, hasLength(1));
      expect(
        result.state.cursor,
        '2026-05-01T00:00:00Z',
        reason: '游标只能由成功项推进，否则失败文件会被增量过滤掉',
      );
    });

    test('写入失败同样不写状态、不推进游标', () async {
      final sink = StubSink()..failWrite.add('a.md');
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);

      final result = await engine.run(
        remote: [remoteFixture('a.md', updatedAt: '2026-05-01T00:00:00Z')],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.failed, hasLength(1));
      expect(result.state.contains('a.md'), isFalse);
      expect(result.state.cursor, isNull);
    });

    test('用实际写入字节数记状态（服务端 size 不符时以本地事实为准）', () async {
      final sink = StubSink();
      // 桩返回 5 字节，但清单声明 size = 999
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [remoteFixture('a.md', size: 999)],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(result.state.files['a.md']!.size, 5);
    });

    test('304 视为成功：刷新状态但不写入文件', () async {
      final sink = StubSink();
      final engine = SyncEngine(
        downloader: StubDownloader(notModifiedIds: {'id-a.md'}),
        sink: sink,
      );
      final result = await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
      final sink = StubSink();
      final downloader = StubDownloader(notModifiedIds: {'id-a.md'});
      final engine = SyncEngine(downloader: downloader, sink: sink);

      await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"')],
        state: SyncState.empty, // 本地无副本
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(downloader.calls.single.$2, isNull);
    });

    test('本地已有副本时带 If-None-Match（省流量）', () async {
      // 「本地有副本」= 磁盘上真有文件（preExisting），**不是**「状态里有记录」。
      final sink = StubSink(preExisting: {'a.md'});
      final downloader = StubDownloader();
      final engine = SyncEngine(downloader: downloader, sink: sink);

      await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        // 状态里有记录但 etag 不同 → 会下载，且本地「有副本」
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"0"', size: 9)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
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
      final sink = StubSink(); // 磁盘上没有文件
      // 模拟真实服务端：只有带了 If-None-Match 才会回 304。
      final downloader = StubDownloader(
        notModifiedIds: {'id-a.md'},
        conditionalOnly: true,
      );
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        // 状态里的 etag 与远端一致（看起来「已同步」），但文件不在磁盘上
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(
        downloader.calls.single.$2,
        isNull,
        reason: '本地无副本时必须发无条件请求，否则 304 会把文件判成「未变更」',
      );
      expect(result.report.downloaded, 1, reason: '文件应被真正重新写入，而不是记成「未变更」');
      expect(sink.written.containsKey('a.md'), isTrue);
    });

    test('计划为空时不产生任何写入（定时同步不刷无意义磁盘 IO）', () async {
      // 「无事可做」的前提是**磁盘上真有文件**：状态与远端一致**且**本地副本存在。
      // 只满足前者时本轮会重新下载（那正是「本地文件被删后必须能自愈」的行为）。
      final sink = StubSink(preExisting: {'a.md'});
      final downloader = StubDownloader();
      final engine = SyncEngine(downloader: downloader, sink: sink);

      final result = await engine.run(
        remote: [remoteFixture('a.md', etag: 'W/"1"', size: 10)],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"1"', size: 10)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.downloaded, 0);
      expect(downloader.calls, isEmpty);
      expect(sink.written, isEmpty);
    });

    test('报告摘要包含各计数与跳过原因', () async {
      final sink = StubSink();
      final engine = SyncEngine(downloader: StubDownloader(), sink: sink);
      final result = await engine.run(
        remote: [
          remoteFixture('a.md'),
          remoteFixture('pic.png', mime: 'image/png'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: const SyncFilterConfig(),
      );
      final summary = result.report.summarize();
      expect(summary, contains('下载 1 个'));
      expect(summary, contains('媒体（未开启）'));
      expect(result.report.hasFailures, isFalse);
    });
  });
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
      expect(groupRelativePath('/workspace/groups/g1/a.md///', 'g1'), 'a.md');
    });

    test('拒绝父目录逃逸 / 当前目录段 / 空段（含深层）', () {
      expect(groupRelativePath('/workspace/groups/g1/../secret', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/./x', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/a//b', 'g1'), isNull);
      expect(groupRelativePath('/workspace/groups/g1/a/../../x', 'g1'), isNull);
      // 剥尾斜杠不能变成绕过校验的捷径
      expect(
        groupRelativePath('/workspace/groups/g1/../secret/', 'g1'),
        isNull,
      );
    });

    test('拒绝 Windows 分隔符与 NUL（绕过段级校验的两种方式）', () {
      expect(
        groupRelativePath('/workspace/groups/g1/a\\..\\..\\x', 'g1'),
        isNull,
      );
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
        'path': '/workspace/groups/$gidFixture/../../etc/passwd/',
        'name': 'passwd',
        'size': 10,
        'updated_at': '2026-01-01T00:00:00Z',
      });
      final plan = buildSyncPlan(
        remote: [evil],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.skipped[SyncSkipReason.invalidPath], 1);
    });
  });
  group('同步执行：并发 IO + 串行合并（issue #20）', () {
    List<UfsFileEntry> manyRemote(int n) => [
      for (var i = 0; i < n; i++)
        remoteFixture('f$i.md', updatedAt: '2026-01-0${(i % 9) + 1}T00:00:00Z'),
    ];

    test('N 个文件真的并发发起（不是「调用 N 次」这种串行也满足的断言）', () async {
      final downloader = ConcurrencyProbeDownloader();
      final sink = OrderedSink();
      final engine = SyncEngine(
        downloader: downloader,
        sink: sink,
        concurrency: 4,
      );

      await engine.run(
        remote: manyRemote(12),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(downloader.maxInFlight, 4, reason: '上限 4 时应有 4 个同时在途');
      expect(downloader.started, hasLength(12));
    });

    test('并发上限生效（同时最多 N 个在途）', () async {
      final downloader = ConcurrencyProbeDownloader();
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 2,
      );

      await engine.run(
        remote: manyRemote(10),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(downloader.maxInFlight, 2);
    });

    test('并发上限为 1 时退化为串行（maxInFlight == 1）', () async {
      final downloader = ConcurrencyProbeDownloader();
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 1,
      );

      await engine.run(
        remote: manyRemote(6),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(downloader.maxInFlight, 1);
    });

    test('上限 < 1 被当作 1（而不是 0 个 worker 死锁）', () async {
      final downloader = ConcurrencyProbeDownloader();
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 0,
      );

      final result = await engine.run(
        remote: manyRemote(3),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.downloaded, 3);
      expect(downloader.maxInFlight, 1);
    });

    test('并发完成顺序乱序时，状态合并仍按计划顺序（游标取最大 updatedAt）', () async {
      // ## 这个测试防的是什么
      //
      // `advanceCursor` 取 `updatedAt` 的**最大值**，故结果与顺序无关；但
      // `markSynced` 逐条写入、`forget` 逐条移除——若合并顺序随完成顺序变化，
      // 同一 relPath 的「先删后写」等场景就会不确定。
      //
      // 这里刻意让**先发起的后完成**（f0 慢、f2 快），断言：
      // 1. 完成顺序确实是乱的（否则测试没测到东西）；
      // 2. 结果状态与串行实现逐字段相等。
      final downloader = ConcurrencyProbeDownloader()
        ..delays['id-f0.md'] = 40
        ..delays['id-f1.md'] = 20;
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 3,
      );

      final concurrent = await engine.run(
        remote: manyRemote(3),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      // 完成顺序被刻意打乱（f2 先于 f1 先于 f0）。
      expect(
        downloader.finished.first,
        'id-f2.md',
        reason: '若完成顺序没乱，本用例就没验证到「顺序无关」',
      );

      // 串行基线：同一份输入，concurrency = 1。
      final serial =
          await SyncEngine(
            downloader: ConcurrencyProbeDownloader(),
            sink: OrderedSink(),
            concurrency: 1,
          ).run(
            remote: manyRemote(3),
            state: SyncState.empty,
            scope: const SyncGroupScope(gidFixture),
            filter: permissiveFixture,
          );

      expect(concurrent.state, serial.state, reason: '状态必须逐字段相等');
      expect(concurrent.state.cursor, serial.state.cursor);
      expect(concurrent.state.files.keys, serial.state.files.keys);
      expect(concurrent.report.downloaded, serial.report.downloaded);
    });

    test('并发下单个失败不影响其余文件的状态写入（既有语义保持）', () async {
      final downloader = ConcurrencyProbeDownloader()
        ..errors['id-f3.md'] = '网络超时';
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 4,
      );

      final result = await engine.run(
        remote: manyRemote(8),
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.report.downloaded, 7);
      expect(result.report.failed, hasLength(1));
      expect(result.report.failed.single.relPath, 'f3.md');
      expect(result.state.contains('f3.md'), isFalse);
      expect(result.state.contains('f4.md'), isTrue, reason: '失败不阻断其余文件');
    });

    test('失败项不推进游标（并发下同样成立）', () async {
      // 失败项的 updated_at **最晚**：若游标由「计划里的最大时间」推进（而不是
      // 由成功项推进），就会越过它，下轮再也拉不到这个文件。
      final downloader = ConcurrencyProbeDownloader()
        ..errors['id-late.md'] = '网络超时';
      final engine = SyncEngine(
        downloader: downloader,
        sink: OrderedSink(),
        concurrency: 4,
      );

      final result = await engine.run(
        remote: [
          remoteFixture('ok.md', updatedAt: '2026-01-01T00:00:00Z'),
          remoteFixture('late.md', updatedAt: '2026-06-01T00:00:00Z'),
        ],
        state: SyncState.empty,
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      expect(result.state.cursor, '2026-01-01T00:00:00Z');
    });

    test('条件请求判据用本轮开始前的状态（并发下 If-None-Match 照常带上）', () async {
      // ## 这个测试防的是什么
      //
      // 并发化最容易犯的错是「把判据也一起并发掉」——即让每个动作在**自己的
      // 完成时刻**去读那个正在被改写的状态。`ifNoneMatch` 的判据是
      // 「状态里有记录 **且** 磁盘上有文件」，读错时机会让它变成 null（少一次
      // 条件请求，白下一份没变的文件）或误带（首次同步被 304 骗成「未变更」，
      // 文件永不落盘）。
      //
      // 构造：状态里**已有** a.md / b.md，磁盘上也真有（条件请求的两个前提都
      // 满足），远端给出新版本。b.md 先完成、a.md 慢——断言两者的请求都带上了
      // 自己的 etag，即判据取自「本轮开始前」的确定事实。
      final downloader = ConcurrencyProbeDownloader()..delays['id-a.md'] = 30;
      final sink = StubSink(preExisting: {'a.md', 'b.md'});
      final engine = SyncEngine(
        downloader: downloader,
        sink: sink,
        concurrency: 4,
      );

      final result = await engine.run(
        remote: [
          remoteFixture('a.md', id: 'id-a.md', etag: 'W/"2"'),
          remoteFixture('b.md', id: 'id-b.md', etag: 'W/"9"'),
        ],
        state: stateWith({
          'a.md': const SyncedFile(etag: 'W/"1"', size: 5),
          'b.md': const SyncedFile(etag: 'W/"8"', size: 5),
        }),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      // b.md 先完成（a.md 慢 30ms）——完成顺序与计划顺序相反。
      expect(downloader.finished.first, 'id-b.md');
      expect(
        downloader.conditionalEtags['id-a.md'],
        'W/"2"',
        reason: 'a.md 的 etag 来自本轮开始前的状态，不因 b.md 先完成而丢失',
      );
      expect(downloader.conditionalEtags['id-b.md'], 'W/"9"');
      expect(result.report.downloaded, 2);
    });

    test('同一路径「先删后写」时结果取决于计划顺序（并发不得打乱它）', () async {
      // ## 这个测试是「顺序确定性」唯一**可观测**的地方
      //
      // `markSynced` / `advanceCursor` 对不同 relPath 是可交换的，故「合并顺序」
      // 在大多数输入下看不出来。唯一暴露它的是**同一路径出现多次**——而
      // `buildSyncPlan` 的 `[...deletes, ...downloads]` 恰好能产出这种计划：
      // 同一 relPath 既被删（旧条目带 `deleted_at`）又被下（新条目）。
      //
      // 语义要求「远端为准」：下载在删除之后执行，最终状态必须是**已同步**。
      // 若合并按**完成顺序**而非计划顺序，删除就会盖掉下载（或反之），
      // 最终状态随网络快慢变化——不可复现。
      //
      // 这里让**删除比下载慢**：完成顺序与计划顺序**相反**（删除在计划里在前，
      // 却最后完成）。若合并按完成顺序，删除会盖掉下载。
      final downloader = ConcurrencyProbeDownloader();
      final sink = OrderedSink()..deleteDelays['a.md'] = 30;
      final engine = SyncEngine(
        downloader: downloader,
        sink: sink,
        concurrency: 4,
      );

      final result = await engine.run(
        remote: [
          // 软删除条目（旧版本）。
          remoteFixture('a.md', id: 'id-old.md', deleted: true),
          // 重建后的条目（新版本）。
          remoteFixture('a.md', id: 'id-new.md', etag: 'W/"new"'),
        ],
        state: stateWith({'a.md': const SyncedFile(etag: 'W/"old"', size: 5)}),
        scope: const SyncGroupScope(gidFixture),
        filter: permissiveFixture,
      );

      // 完成顺序确实被反转（删除慢、下载快）——否则本用例没测到东西。
      expect(sink.deletedOrder, ['a.md'], reason: '删除在计划里在前、却最后完成，正是要覆盖的乱序');

      // 计划顺序：删除在前、下载在后（见 SyncPlan.actions 的说明）。
      expect(result.report.deleted, 1);
      expect(result.report.downloaded, 1);
      expect(
        result.state.files['a.md']?.etag,
        'W/"new"',
        reason: '远端为准：下载在删除之后，最终状态必须是新版本（顺序被打乱就会变）',
      );
      expect(result.state.contains('a.md'), isTrue);
    });

    test('大量文件的并发结果与串行逐字段相等（回归基线）', () async {
      final remote = [
        for (var i = 0; i < 30; i++)
          remoteFixture(
            'f$i.md',
            etag: 'W/"$i"',
            updatedAt: '2026-01-${(i % 28) + 1}T00:00:00Z',
          ),
      ];

      final concurrent =
          await SyncEngine(
            downloader: StubDownloader(),
            sink: StubSink(),
            concurrency: 5,
          ).run(
            remote: remote,
            state: SyncState.empty,
            scope: const SyncGroupScope(gidFixture),
            filter: permissiveFixture,
          );

      final serial =
          await SyncEngine(
            downloader: StubDownloader(),
            sink: StubSink(),
            concurrency: 1,
          ).run(
            remote: remote,
            state: SyncState.empty,
            scope: const SyncGroupScope(gidFixture),
            filter: permissiveFixture,
          );

      expect(concurrent.state, serial.state);
      expect(concurrent.report.downloaded, serial.report.downloaded);
      expect(concurrent.report.failed, serial.report.failed);
    });
  });
}
