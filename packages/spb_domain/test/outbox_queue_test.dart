import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/outbox_harness.dart';

/// OutboxQueue 的提交 / FIFO 投递 / 终态失败 / 取消重试
///
/// ⚠️ 本文件由 `outbox_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/outbox_harness.dart`。
void main() {
  group('OutboxQueue.submit：三分支', () {
    test('网络可用 → 立即投递，**不入队**', () async {
      final store = FakeStore();
      final sent = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          sent.add(e.id);
          return result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final outcome = await queue.submit(userId: 'u1', input: '你好');

      expect(outcome, isA<OutboxSubmittedNow>());
      expect(sent, hasLength(1));
      // 队列里出现一条已投递的行是纯噪声（重启后还会被重复投递）。
      expect(store.rows, isEmpty);
      expect(queue.snapshot, isEmpty);
    });

    test('可重试错误 → 入队，返回 OutboxQueuedOffline', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      final outcome = await queue.submit(userId: 'u1', input: '你好');

      expect(outcome, isA<OutboxQueuedOffline>());
      expect(queue.snapshot, hasLength(1));
      expect(store.rows, hasLength(1), reason: '必须落盘，否则重启即丢');
      // attempts 记为 1（这次已经试过了）。
      expect(queue.snapshot.single.attempts, 1);
      expect(queue.snapshot.single.lastError, '断网');
    });

    test('终态错误（400）→ **不**入队，直接上抛', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const HttpError(400, '输入不合法'),
      );
      addTearDown(queue.dispose);

      // 入队只会让用户在「待发送」里看到一条永远发不出去的消息。
      await expectLater(
        queue.submit(userId: 'u1', input: '你好'),
        throwsA(isA<HttpError>()),
      );
      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
    });

    test('入队时存储故障 → OutboxEnqueueFailed（**不**假装排队成功）', () async {
      final store = FakeStore()
        ..failWith = const StorageError('磁盘满', cause: 'no space');
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      final outcome = await queue.submit(userId: 'u1', input: '你好');

      // 关键：这不是 OutboxQueuedOffline。返回「已排队」而其实没存 = 用户
      // 以为消息发出去了、其实丢了。
      expect(outcome, isA<OutboxEnqueueFailed>());
      expect((outcome as OutboxEnqueueFailed).error, isA<StorageError>());
      expect(queue.snapshot, isEmpty);
    });

    test('入队保留 groupId=null（无归属入口不被改写成空串）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await queue.submit(userId: 'u1', input: '你好');

      expect(queue.snapshot.single.groupId, isNull);
      expect(store.rows.values.single.groupId, isNull);
    });

    test('重试复用同一个 request_id（幂等键不重新生成）', () async {
      final store = FakeStore();
      final seen = <String>[];
      var fail = true;
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          seen.add(e.id);
          if (fail) throw const NetworkError('断网');
          return result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      await queue.submit(userId: 'u1', input: '你好');
      final id = queue.snapshot.single.id;

      fail = false;
      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      // 两次调用必须带同一个 id —— 否则服务端会建两个 turn（用户发一条、
      // 收到两条回复）。
      expect(seen, hasLength(2));
      expect(seen.toSet(), {id});
    });
  });

  group('OutboxQueue.drain：严格全局 FIFO', () {
    test('按 createdAt 顺序投递', () async {
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
      await store.upsert(
        queuedFixture(id: 'c', createdAt: base.add(const Duration(minutes: 2))),
      );
      await store.upsert(queuedFixture(id: 'a', createdAt: base));
      await store.upsert(
        queuedFixture(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await settle();

      expect(order, ['a', 'b', 'c']);
    });

    test('队首可重试失败 → **停下**，不跳过它投后面的（队首阻塞）', () async {
      final store = FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          // 第一条永远失败。
          if (e.id == 'a') throw const NetworkError('断网');
          return result(requestId: e.id);
        },
        // 抖动关闭，让退避确定。
        policy: const OutboxRetryPolicy(jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(queuedFixture(id: 'a', createdAt: base));
      await store.upsert(
        queuedFixture(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await settle();

      // ## 为什么必须阻塞（而不是「跳过失败的发下一条」）
      //
      // 两条消息调换顺序会改变对话语义（「先做 A 再做 B」vs 反过来）。
      // 跳过 a 先发 b，服务端会先处理 b——语义被静默篡改。
      expect(order, ['a'], reason: 'b 不该在 a 成功前被投递');
    });

    test('队首成功 → 继续投后面的（不因一条失败就永久停摆）', () async {
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
      await store.upsert(queuedFixture(id: 'a', createdAt: base));
      await store.upsert(
        queuedFixture(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await settle();

      expect(order, ['a', 'b']);
      expect(queue.snapshot, isEmpty);
    });

    test('未到 nextAttemptAt 的队首不被投递（退避生效）', () async {
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

      final now = DateTime.now();
      await store.upsert(
        queuedFixture(
          id: 'a',
          attempts: 1,
          lastError: '断网',
          nextAttemptAt: now.add(const Duration(minutes: 5)),
        ),
      );
      await queue.load('u1');
      await settle();

      expect(order, isEmpty, reason: '还在退避窗口内');
      expect(queue.snapshot, hasLength(1));
    });

    test('failed 条目在场时 drain 仍然终止（不能忙循环）', () async {
      // ## 这条测的是什么（以及**不**测什么）
      //
      // 它断言 `drain` 在队列里只有 failed 条目时**会返回**（而不是转圈），
      // 且条目仍在队列里。它是回归护栏：`drain` 的 `while` 若被改成不跳过
      // failed，这条会以**超时**（而非断言失败）报错——实测过：去掉
      // `_nextSendable` 的 failed 跳过会让整个文件挂到超时。
      //
      // ⚠️ 它**不是** `drain` 里那个「进度哨兵」的反向验证：在正确代码上
      // 哨兵不可达（failed 被跳过 → 循环立刻 break）。哨兵是 fail-safe，
      // 见 `outbox.dart` 的注释；本用例覆盖的是「跳过 failed」这一行为。
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

      await store.upsert(queuedFixture(id: 'a', attempts: 10, lastError: '超时'));
      await queue.load('u1');

      await queue.drain().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('drain 未终止：failed 条目被反复投递'),
      );

      expect(order, isEmpty, reason: 'failed 的重试权在用户手里');
      expect(queue.snapshot, hasLength(1), reason: '不自动删除（那是用户的文本）');
    });

    test('failed 条目被跳过（重试权在用户手里，不阻塞后面的）', () async {
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
      await store.upsert(
        queuedFixture(id: 'a', attempts: 10, lastError: '超时', createdAt: base),
      );
      await store.upsert(
        queuedFixture(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await settle();

      // 若 failed 也算「队首」并阻塞，用户手动重试前整条队列就死了。
      expect(order, ['b']);
    });
  });

  group('OutboxQueue：重试用尽与终态失败', () {
    test('重试用尽 → 条目**保留**在队列里并标 failed（不自动删除）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
        policy: const OutboxRetryPolicy(maxAttempts: 3, jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      final failures = <OutboxFailure>[];
      queue.failures.listen(failures.add);

      // ⚠️ 条目的 maxAttempts 必须与队列策略一致：上限是**入队时快照**在
      // 条目上的（否则重启后改了策略会追溯生效），故队列不会用 `_policy`
      // 覆盖它。
      await store.upsert(queuedFixture(id: 'a', maxAttempts: 3));
      await queue.load('u1');

      // 手动推进三次（不等真实退避）。
      for (var i = 0; i < 3; i++) {
        await queue.onConnectivityRestored();
        await Future<void>.delayed(Duration.zero);
      }

      expect(queue.snapshot, hasLength(1));
      expect(queue.snapshot.single.status, OutboxStatus.failed);
      expect(queue.snapshot.single.attempts, 3);
      // 它是**用户输入的文本**——静默丢弃等于「打了字、弄丢了、还不告诉他」。
      expect(store.rows, hasLength(1));
      expect(failures.single.exhausted, isTrue);
    });

    test('上限取**条目上快照的** maxAttempts，不是队列当前的策略', () async {
      // ## 为什么这个区分必须被钉住
      //
      // 策略可能在两次启动之间被改（配置或代码升级）。一条在上限 1 下入队的
      // 条目，不该因为下次启动时队列策略是 10 就多试 9 次——用户并没有改过
      // 这条消息的重试意愿。反之，若判据用 `_policy`，`status`（用
      // `entry.maxAttempts`）与实际投递次数就会打架。
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
        // 队列策略是 10……
        policy: const OutboxRetryPolicy(maxAttempts: 10, jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      // 上报通道：`exhausted: true` 只在**用尽**分支产生（终态分支是 false）。
      final failures = <OutboxFailure>[];
      queue.failures.listen(failures.add);

      // ……但条目是上限 1 时入队的。
      await store.upsert(queuedFixture(id: 'a', maxAttempts: 1));
      await queue.load('u1');
      await settle();
      await queue.onConnectivityRestored();
      await settle();

      expect(queue.snapshot.single.status, OutboxStatus.failed);
      expect(queue.snapshot.single.attempts, 1, reason: '不该按队列策略试 10 次');
      // ⚠️ 这一条才是真正的判据：`status` 由 `entry.maxAttempts` 派生（两条
      // 路径都会得到 failed），只有**上报通道**能区分走了哪个分支。若
      // `_attempt` 里用 `_policy.maxAttempts`，这里会一条都没有（走的是退避
      // 重试路径），而 `status` 却已经是 failed——两处判据打架。
      expect(failures, hasLength(1));
      expect(failures.single.exhausted, isTrue);
    });

    test('终态错误 → 条目被**移除**并上报（重试无用）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const HttpError(400, '输入不合法'),
        policy: const OutboxRetryPolicy(jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      final failures = <OutboxFailure>[];
      queue.failures.listen(failures.add);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');
      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
      expect(failures.single.exhausted, isFalse, reason: '不是用尽，是终态');
    });

    test('投递成功 → 推 delivered（控制器据此注入乐观回显）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => result(turnId: 'turn-9', requestId: e.id),
      );
      addTearDown(queue.dispose);

      final delivered = <OutboxDelivered>[];
      queue.delivered.listen(delivered.add);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');
      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      expect(delivered, hasLength(1));
      // turnId 来自**服务端响应**（不是客户端编的）——只有这样服务端随后的
      // `user_message` 事件才能原位合并，不会出现两个气泡。
      expect(delivered.single.result.turnId, 'turn-9');
      expect(delivered.single.entry.input, 'hi-a');
    });
  });

  group('OutboxQueue.cancel / retryNow / remove', () {
    test('取消未投递条目 → 移出队列并从存储删除', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');
      await settle();

      expect(await queue.cancel('a'), isTrue);
      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
    });

    test('取消不存在的 id → false（不抛）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => result());
      addTearDown(queue.dispose);
      expect(await queue.cancel('不存在'), isFalse);
    });

    test('存储删除失败 → 回滚内存状态（两份状态不一致比取消没生效更糟）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(
        store: store,
        // 投递必须**失败**（可重试），否则 load 那轮 drain 会直接把条目投出去。
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');
      await settle();
      store.failWith = const StorageError('磁盘故障');

      expect(await queue.cancel('a'), isFalse);
      // 若内存删了而库里还在，重启后条目「复活」——用户会以为见鬼了。
      expect(queue.snapshot, hasLength(1));
    });

    test('retryNow 重置 attempts 并清 lastError（failed → 立刻可投）', () async {
      final store = FakeStore();
      var fail = true;
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          if (fail) throw const NetworkError('断网');
          return result(requestId: e.id);
        },
        policy: const OutboxRetryPolicy(maxAttempts: 1, jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a', maxAttempts: 1));
      await queue.load('u1');
      await settle();
      await queue.onConnectivityRestored();
      await settle();
      expect(queue.snapshot.single.status, OutboxStatus.failed);

      fail = false;
      expect(await queue.retryNow('a'), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(queue.snapshot, isEmpty, reason: '手动重试成功后应出队');
      expect(store.rows, isEmpty);
    });

    test('retryNow 不存在的 id → false', () async {
      final store = FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => result());
      addTearDown(queue.dispose);
      expect(await queue.retryNow('不存在'), isFalse);
    });

    test('remove 等价于 cancel（用户丢弃）', () async {
      final store = FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => result());
      addTearDown(queue.dispose);

      await store.upsert(queuedFixture(id: 'a'));
      await queue.load('u1');
      await settle();
      await queue.remove('a');

      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
    });
  });
}
