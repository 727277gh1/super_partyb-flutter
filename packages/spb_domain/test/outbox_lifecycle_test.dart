import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/outbox_harness.dart';

/// OutboxQueue 的连通性恢复 / 加载 / 并发与生命周期
///
/// ⚠️ 本文件由 `outbox_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/outbox_harness.dart`。
void main() {
  group('OutboxQueue.onConnectivityRestored', () {
    test('把所有**非 failed** 条目的 nextAttemptAt 拉到现在', () async {
      final store = FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final future = DateTime.now().add(const Duration(hours: 1));
      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        queuedFixture(
          id: 'a',
          attempts: 1,
          lastError: '断网',
          nextAttemptAt: future,
          createdAt: base,
        ),
      );
      await store.upsert(
        queuedFixture(
          id: 'b',
          attempts: 1,
          lastError: '断网',
          nextAttemptAt: future,
          createdAt: base.add(const Duration(minutes: 1)),
        ),
      );
      await queue.load('u1');

      // load 会自己 drain 一次（此时都在退避窗口内 → 什么都不投）。
      order.clear();
      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      expect(order, ['a', 'b'], reason: '恢复网络后应立即重试');
    });

    test('failed 条目**不**被提前（重试权在用户手里）', () async {
      final store = FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      // ⚠️ `nextAttemptAt` 必须**在将来**，且要比 `createdAt` 晚。
      //
      // 这条用例最初只看「投递顺序为空」，而那是个**抓不住改动**的判据：
      // 去掉 `if (e.status == failed) continue;` 后条目会被提前到 `now`，
      // 但 `drain` 随后仍然跳过 `failed` 条目——投递顺序一样是空的（实测：
      // 去掉那行后本用例仍绿）。故必须断言**可观察的状态本身**。
      final future = DateTime.now().add(const Duration(hours: 1));
      await store.upsert(
        queuedFixture(
          id: 'a',
          attempts: 10,
          lastError: '超时',
          createdAt: base,
          nextAttemptAt: future,
        ),
      );
      await queue.load('u1');
      order.clear();

      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      // 自动重试失败过的条目会让「用户手动重试」这个入口失去意义，
      // 也会在弱网下反复骚扰服务端。
      expect(order, isEmpty);
      expect(
        queue.snapshot.single.nextAttemptAt,
        future,
        reason: 'failed 条目的退避时刻被改动了——去掉 continue 后它会变成 now',
      );
    });

    test('空队列时是 no-op（不抛、不排定时器）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => result());
      addTearDown(queue.dispose);
      await queue.onConnectivityRestored();
    });
  });

  group('OutboxQueue.load', () {
    test('恢复存储里的条目并按 createdAt 排序', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        queuedFixture(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await store.upsert(queuedFixture(id: 'a', createdAt: base));

      await queue.load('u1');

      expect(queue.snapshot.map((e) => e.id), ['a', 'b']);
      expect(queue.userId, 'u1');
    });

    test('load 失败**不抛**（只记 warn）——启动期没有可展示错误的上下文', () async {
      final store = FakeStore()..failWith = const StorageError('库损坏');
      final queue = OutboxQueue(store: store, send: (e) async => result());
      addTearDown(queue.dispose);

      // 与 submit 路径的关键差异：这里没有 UI 可提示，抛出去会让 App 启动崩。
      // 后续每次 submit 都会重新尝试存储。
      await queue.load('u1');
      expect(queue.snapshot, isEmpty);
    });

    test('重新 load 会替换内存视图（换账号）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a', userId: 'u1'));
      await store.upsert(queuedFixture(id: 'b', userId: 'u2'));

      await queue.load('u1');
      expect(queue.snapshot.map((e) => e.id), ['a']);

      await queue.load('u2');
      expect(queue.snapshot.map((e) => e.id), ['b']);
    });
  });

  group('OutboxQueue：并发与生命周期', () {
    test('并发 drain 不会把同一队首投两次', () async {
      final store = FakeStore();
      final calls = <String>[];
      final gate = Completer<void>();
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          calls.add(e.id);
          await gate.future;
          return result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');

      // load 已启动一轮 drain（卡在 send 里）。再并发调两次。
      final d1 = queue.drain();
      final d2 = queue.drain();
      gate.complete();
      await Future.wait([d1, d2]);
      await Future<void>.delayed(Duration.zero);

      expect(calls, ['a'], reason: '重复投递会产生重复 turn（虽有幂等键兜底）');
    });

    test('dispose 后 drain 是 no-op（定时器不会在释放后触发）', () async {
      final store = FakeStore();
      final calls = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          calls.add(e.id);
          return result(requestId: e.id);
        },
      );

      await store.upsert(queuedFixture(id: 'a'));
      await queue.dispose();
      await queue.drain();

      expect(calls, isEmpty);
    });

    test('dispose 后再 dispose 不抛（幂等）', () async {
      final queue = OutboxQueue(
        store: FakeStore(),
        send: (e) async => result(),
      );
      await queue.dispose();
      await queue.dispose();
    });

    group('存储故障时留痕（issue #45）', () {
      // 这三处原先都是 `catch (_) {}`——**完全静默**。后果不是数据丢失（内存里
      // 是对的），而是「重启后的行为」与「用户看到的」不一致，且开发者无从知晓。
      // 这组用例钉住「每条静默路径都留下了日志」。

      /// 从环形缓冲里找 message 等于给定串的记录。
      Iterable<LogRecord> recordsWith(String message) =>
          SpbLog.recentLogs.where((r) => r.message == message);

      setUp(() {
        SpbLog.clearRecentLogs();
        SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
      });

      test('退避时间未落盘 → 记 debug（重启后首次投递可能偏早）', () async {
        final store = FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
          policy: const OutboxRetryPolicy(maxAttempts: 5, jitterRatio: 0),
        );
        addTearDown(queue.dispose);

        await store.upsert(queuedFixture(id: 'a'));
        await queue.load('u1');
        await settle();

        // 之后所有 upsert 都失败。
        store.failUpsertWith = const StorageError('磁盘满', cause: 'no space');
        await queue.onConnectivityRestored();
        await settle();

        final rec = recordsWith('离线队列退避时间未落盘（重启后首次投递时刻可能偏早）');
        expect(rec, hasLength(1));
        expect(rec.single.fields['request_id'], 'a');
        expect(rec.single.fields['error'], contains('磁盘满'));
      });

      test('条目状态未落盘（重试耗尽）→ 记 warn（重启后可能仍按 pending 重试）', () async {
        final store = FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
          policy: const OutboxRetryPolicy(maxAttempts: 1, jitterRatio: 0),
        );
        addTearDown(queue.dispose);

        await store.upsert(queuedFixture(id: 'a', maxAttempts: 1));
        // ⚠️ 必须在 load 之前置故障：`load` 内部会 unawaited(drain())，那轮就把
        // 条目打到 failed 了。若晚于它，`failed` 已落盘，且
        // `onConnectivityRestored` 会**跳过** failed 条目（重试权在用户手里）
        // → 什么都不发生，用例测不到目标分支。
        store.failUpsertWith = const StorageError('磁盘满');
        await queue.load('u1');
        await settle();

        expect(queue.snapshot.single.status, OutboxStatus.failed);
        final rec = recordsWith('离线队列条目状态未落盘（重启后可能仍按 pending 重试）');
        expect(rec, hasLength(1), reason: '这是「重启后与用户所见不一致」的真实来源');
        expect(rec.single.level, LogLevel.warn);
        expect(rec.single.fields['status'], 'failed');
        expect(rec.single.fields['request_id'], 'a');
      });

      test('终态条目删除失败 → 记 debug（幂等键兜底，故不是 warn）', () async {
        final store = FakeStore();
        final queue = OutboxQueue(
          store: store,
          // 终态错误（不可重试）→ 走 delete 分支。
          send: (e) async => throw const AuthError('会话失效'),
        );
        addTearDown(queue.dispose);

        await store.upsert(queuedFixture(id: 'a'));
        // 同上：终态判定发生在 load 那轮 drain 里，故障要提前置。
        store.failDeleteWith = const StorageError('库损坏');
        await queue.load('u1');
        await settle();

        final rec = recordsWith('离线队列终态条目删除失败（重启后可能重复投递，幂等键兜底）');
        expect(rec, hasLength(1));
        expect(rec.single.level, LogLevel.debug);
        expect(rec.single.fields['request_id'], 'a');
      });

      test('onConnectivityRestored 的落盘循环失败 → 每条都有日志', () async {
        final store = FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
        );
        addTearDown(queue.dispose);

        await store.upsert(queuedFixture(id: 'a'));
        await store.upsert(queuedFixture(id: 'b'));
        await queue.load('u1');
        await settle();

        store.failUpsertWith = const StorageError('磁盘满');
        await queue.onConnectivityRestored();
        await settle();

        final rec = recordsWith('离线队列提前重试时间未落盘（重启后首次投递时刻可能偏后）');
        expect(rec.map((r) => r.fields['request_id']), containsAll(['a', 'b']));
      });
    });

    test('entries 流推全量快照（同 items 的取向）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      final emissions = <List<OutboxEntry>>[];
      queue.entries.listen(emissions.add);

      await queue.submit(userId: 'u1', input: 'a');
      await queue.submit(userId: 'u1', input: 'b');
      await Future<void>.delayed(Duration.zero);

      expect(emissions.last, hasLength(2));
      expect(emissions.last.map((e) => e.input), ['a', 'b']);
    });
  });
}
