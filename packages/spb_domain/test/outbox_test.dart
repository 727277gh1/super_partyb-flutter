import 'dart:async';
import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 内存版 [OutboxStore]。
///
/// ## 为什么不用 `DriftOutboxStore`
///
/// 本文件测的是**队列逻辑**（FIFO / 退避 / 终态处理），不是 SQL。用内存
/// 实现让每条用例只关心行为，且能在 `dart test`（无 Flutter 引擎）里跑。
/// 持久化本身由 `spb_data/test/outbox_store_test.dart` 覆盖。
class _FakeStore implements OutboxStore {
  final Map<String, OutboxEntry> rows = {};

  /// 让下一次调用抛错（测「存储故障不静默降级」）。
  SpbError? failWith;

  /// 只让 `upsert` 抛错（issue #45：测「状态未落盘」的日志）。
  ///
  /// ## 为什么需要它而不是复用 [failWith]
  ///
  /// [failWith] 会让 `load` 也失败——而「退避时间未落盘」的场景里 `load`
  /// 必须是好的（队列已经装好了），只有后续的 `upsert` 坏掉。
  SpbError? failUpsertWith;

  /// 只让 `delete` 抛错（同上，测终态条目删除失败）。
  SpbError? failDeleteWith;

  int loadCalls = 0;
  int upsertCalls = 0;
  int deleteCalls = 0;

  @override
  Future<List<OutboxEntry>> load(String userId) async {
    loadCalls++;
    if (failWith != null) throw failWith!;
    final mine = rows.values.where((e) => e.userId == userId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return mine;
  }

  @override
  Future<void> upsert(OutboxEntry entry) async {
    upsertCalls++;
    if (failWith != null) throw failWith!;
    if (failUpsertWith != null) throw failUpsertWith!;
    rows[entry.id] = entry;
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls++;
    if (failWith != null) throw failWith!;
    if (failDeleteWith != null) throw failDeleteWith!;
    rows.remove(id);
  }

  @override
  Future<void> clear(String userId) async {
    rows.removeWhere((_, e) => e.userId == userId);
  }
}

/// 让 `load` 触发的那轮 `drain` 跑完。
///
/// ## 为什么需要它
///
/// `load` 内部 `unawaited(drain())`（真实场景下不该阻塞启动）。故 `await
/// queue.load(...)` 返回时投递可能**还在飞**：`_inFlight` 里还挂着队首，
/// 此时 `cancel` 会正确地拒绝。测试若不先等它跑完，断言的就是一个竞态。
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SendMessageResult _result({
  String turnId = 't1',
  String groupId = 'g1',
  String? requestId,
}) => SendMessageResult(
  turnId: turnId,
  groupId: groupId,
  status: 'queued',
  requestId: requestId,
);

OutboxEntry _queued({
  String id = 'r1',
  String userId = 'u1',
  int attempts = 0,
  String? lastError,
  DateTime? nextAttemptAt,
  DateTime? createdAt,
  int maxAttempts = OutboxRetryPolicy.defaultMaxAttempts,
}) {
  final t = createdAt ?? DateTime.utc(2026, 1, 1, 12);
  return OutboxEntry(
    id: id,
    userId: userId,
    input: 'hi-$id',
    createdAt: t,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt ?? t,
    lastError: lastError,
    maxAttempts: maxAttempts,
  );
}

void main() {
  group('OutboxRetryPolicy.delayFor', () {
    test('指数退避：2s → 4s → 8s → 16s（无抖动）', () {
      const p = OutboxRetryPolicy(jitterRatio: 0);
      expect(p.delayFor(1), const Duration(seconds: 2));
      expect(p.delayFor(2), const Duration(seconds: 4));
      expect(p.delayFor(3), const Duration(seconds: 8));
      expect(p.delayFor(4), const Duration(seconds: 16));
    });

    test('封顶在 maxDelay（5 分钟），不会无限增长', () {
      const p = OutboxRetryPolicy(jitterRatio: 0);
      // 2^20 × 2s 会是天文数字——若没有封顶，Duration 溢出成负数，
      // `_scheduleRetry` 会立刻重投（变成忙循环）。
      expect(p.delayFor(20), const Duration(minutes: 5));
      expect(p.delayFor(100), const Duration(minutes: 5));
      expect(p.delayFor(1000), const Duration(minutes: 5));
    });

    test('attempts <= 0 退化为 baseDelay（不抛、不返回负值）', () {
      const p = OutboxRetryPolicy(jitterRatio: 0);
      expect(p.delayFor(0), const Duration(seconds: 2));
      expect(p.delayFor(-5), const Duration(seconds: 2));
    });

    test('抖动落在 ±20% 区间内', () {
      const p = OutboxRetryPolicy(); // jitterRatio 默认 0.2
      // 用固定种子的 Random，让边界可复现。
      final r = Random(42);
      for (var i = 0; i < 200; i++) {
        final d = p.delayFor(1, random: r);
        // 2s ± 20% = 1.6s ～ 2.4s
        expect(
          d.inMilliseconds,
          inInclusiveRange(1600, 2400),
          reason: '第 $i 次抖动越界',
        );
      }
    });

    test('抖动确实在变（不是常量）', () {
      const p = OutboxRetryPolicy();
      final r = Random(7);
      final seen = <int>{};
      for (var i = 0; i < 50; i++) {
        seen.add(p.delayFor(1, random: r).inMilliseconds);
      }
      // 若忘了用 random（或 scale 恒为 1），这里只有 1 个值。
      expect(seen.length, greaterThan(10));
    });
  });

  group('OutboxRetryPolicy.isRetryable', () {
    test('可重试：断网 / 5xx / 429 / 408', () {
      expect(OutboxRetryPolicy.isRetryable(const NetworkError('断网')), isTrue);
      expect(
        OutboxRetryPolicy.isRetryable(
          const NetworkError('断网', retryable: true),
        ),
        isTrue,
      );
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(500, 'boom')),
        isTrue,
      );
      expect(OutboxRetryPolicy.isRetryable(const HttpError(502, 'gw')), isTrue);
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(429, 'slow')),
        isTrue,
      );
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(408, 'timeout')),
        isTrue,
      );
    });

    test('不可重试：明确标记的 NetworkError（如 TLS 证书错）', () {
      expect(
        OutboxRetryPolicy.isRetryable(
          const NetworkError('证书无效', retryable: false),
        ),
        isFalse,
      );
    });

    test('不可重试：4xx（400/404/409）——重试一万次还是 400', () {
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(400, 'bad')),
        isFalse,
      );
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(404, 'gone')),
        isFalse,
      );
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(409, 'dup')),
        isFalse,
      );
    });

    test('不可重试：401/403（需重新登录，不是网络问题）', () {
      expect(OutboxRetryPolicy.isRetryable(const AuthError('过期')), isFalse);
      expect(
        OutboxRetryPolicy.isRetryable(const HttpError(401, 'unauth')),
        isFalse,
      );
    });

    test('不可重试：ParseError / ValidationError / StorageError', () {
      expect(OutboxRetryPolicy.isRetryable(const ParseError('契约漂移')), isFalse);
      expect(
        OutboxRetryPolicy.isRetryable(const ValidationError('空输入')),
        isFalse,
      );
      expect(OutboxRetryPolicy.isRetryable(const StorageError('磁盘满')), isFalse);
    });
  });

  group('OutboxEntry 状态派生', () {
    test('attempts=0 → pending', () {
      expect(_queued().status, OutboxStatus.pending);
    });

    test('attempts>0 且未达上限 → retrying', () {
      expect(_queued(attempts: 1).status, OutboxStatus.retrying);
      expect(_queued(attempts: 9).status, OutboxStatus.retrying);
    });

    test('达上限且有 lastError → failed', () {
      expect(
        _queued(attempts: 10, lastError: '超时').status,
        OutboxStatus.failed,
      );
    });

    test('达上限但**没有** lastError → 不是 failed（状态从证据派生）', () {
      // 若不判 lastError，「已成功但 attempts 恰好是 10」的条目会被误标失败。
      expect(_queued(attempts: 10).status, OutboxStatus.retrying);
    });

    test('copyWith(clearLastError: true) 能清空 lastError（失败 → retrying）', () {
      final failed = _queued(attempts: 10, lastError: '超时');
      expect(failed.status, OutboxStatus.failed);
      final revived = failed.copyWith(attempts: 0, clearLastError: true);
      expect(revived.lastError, isNull);
      expect(revived.status, OutboxStatus.pending);
    });
  });

  group('OutboxEntry.toRequestFields', () {
    test('id 映射为 request_id（幂等键与主键合一）', () {
      final f = _queued(id: 'req-xyz').toRequestFields();
      // ⚠️ 这一条是切片 C 的**幂等性根基**：服务端按 `(user_id, request_id)`
      // 去重，故重试必须带同一个 request_id。若这里漏了它，重试会创建重复 turn。
      expect(f['request_id'], 'req-xyz');
    });

    test('groupId 为 null 时不发 group_id（无归属入口）', () {
      final f = _queued().toRequestFields();
      // 空串是**无效值**，null 才是「让服务端判定」。故必须整键缺席。
      expect(f.containsKey('group_id'), isFalse);
    });

    test('groupId 非 null 时原样发出', () {
      final e = OutboxEntry(
        id: 'r',
        userId: 'u',
        input: 'x',
        groupId: 'g9',
        createdAt: DateTime.utc(2026),
        nextAttemptAt: DateTime.utc(2026),
      );
      expect(e.toRequestFields()['group_id'], 'g9');
    });
  });

  group('OutboxQueue.submit：三分支', () {
    test('网络可用 → 立即投递，**不入队**', () async {
      final store = _FakeStore();
      final sent = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          sent.add(e.id);
          return _result(requestId: e.id);
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
      final store = _FakeStore();
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
      final store = _FakeStore();
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
      final store = _FakeStore()
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
      final store = _FakeStore();
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
      final store = _FakeStore();
      final seen = <String>[];
      var fail = true;
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          seen.add(e.id);
          if (fail) throw const NetworkError('断网');
          return _result(requestId: e.id);
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
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        _queued(id: 'c', createdAt: base.add(const Duration(minutes: 2))),
      );
      await store.upsert(_queued(id: 'a', createdAt: base));
      await store.upsert(
        _queued(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await _settle();

      expect(order, ['a', 'b', 'c']);
    });

    test('队首可重试失败 → **停下**，不跳过它投后面的（队首阻塞）', () async {
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          // 第一条永远失败。
          if (e.id == 'a') throw const NetworkError('断网');
          return _result(requestId: e.id);
        },
        // 抖动关闭，让退避确定。
        policy: const OutboxRetryPolicy(jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(_queued(id: 'a', createdAt: base));
      await store.upsert(
        _queued(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await _settle();

      // ## 为什么必须阻塞（而不是「跳过失败的发下一条」）
      //
      // 两条消息调换顺序会改变对话语义（「先做 A 再做 B」vs 反过来）。
      // 跳过 a 先发 b，服务端会先处理 b——语义被静默篡改。
      expect(order, ['a'], reason: 'b 不该在 a 成功前被投递');
    });

    test('队首成功 → 继续投后面的（不因一条失败就永久停摆）', () async {
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(_queued(id: 'a', createdAt: base));
      await store.upsert(
        _queued(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await _settle();

      expect(order, ['a', 'b']);
      expect(queue.snapshot, isEmpty);
    });

    test('未到 nextAttemptAt 的队首不被投递（退避生效）', () async {
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final now = DateTime.now();
      await store.upsert(
        _queued(
          id: 'a',
          attempts: 1,
          lastError: '断网',
          nextAttemptAt: now.add(const Duration(minutes: 5)),
        ),
      );
      await queue.load('u1');
      await _settle();

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
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a', attempts: 10, lastError: '超时'));
      await queue.load('u1');

      await queue.drain().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('drain 未终止：failed 条目被反复投递'),
      );

      expect(order, isEmpty, reason: 'failed 的重试权在用户手里');
      expect(queue.snapshot, hasLength(1), reason: '不自动删除（那是用户的文本）');
    });

    test('failed 条目被跳过（重试权在用户手里，不阻塞后面的）', () async {
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        _queued(id: 'a', attempts: 10, lastError: '超时', createdAt: base),
      );
      await store.upsert(
        _queued(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await queue.load('u1');
      await _settle();

      // 若 failed 也算「队首」并阻塞，用户手动重试前整条队列就死了。
      expect(order, ['b']);
    });
  });

  group('OutboxQueue：重试用尽与终态失败', () {
    test('重试用尽 → 条目**保留**在队列里并标 failed（不自动删除）', () async {
      final store = _FakeStore();
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
      await store.upsert(_queued(id: 'a', maxAttempts: 3));
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
      final store = _FakeStore();
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
      await store.upsert(_queued(id: 'a', maxAttempts: 1));
      await queue.load('u1');
      await _settle();
      await queue.onConnectivityRestored();
      await _settle();

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
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const HttpError(400, '输入不合法'),
        policy: const OutboxRetryPolicy(jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      final failures = <OutboxFailure>[];
      queue.failures.listen(failures.add);

      await store.upsert(_queued(id: 'a'));
      await queue.load('u1');
      await queue.onConnectivityRestored();
      await Future<void>.delayed(Duration.zero);

      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
      expect(failures.single.exhausted, isFalse, reason: '不是用尽，是终态');
    });

    test('投递成功 → 推 delivered（控制器据此注入乐观回显）', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => _result(turnId: 'turn-9', requestId: e.id),
      );
      addTearDown(queue.dispose);

      final delivered = <OutboxDelivered>[];
      queue.delivered.listen(delivered.add);

      await store.upsert(_queued(id: 'a'));
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
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a'));
      await queue.load('u1');
      await _settle();

      expect(await queue.cancel('a'), isTrue);
      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
    });

    test('取消不存在的 id → false（不抛）', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => _result());
      addTearDown(queue.dispose);
      expect(await queue.cancel('不存在'), isFalse);
    });

    test('存储删除失败 → 回滚内存状态（两份状态不一致比取消没生效更糟）', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        // 投递必须**失败**（可重试），否则 load 那轮 drain 会直接把条目投出去。
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a'));
      await queue.load('u1');
      await _settle();
      store.failWith = const StorageError('磁盘故障');

      expect(await queue.cancel('a'), isFalse);
      // 若内存删了而库里还在，重启后条目「复活」——用户会以为见鬼了。
      expect(queue.snapshot, hasLength(1));
    });

    test('retryNow 重置 attempts 并清 lastError（failed → 立刻可投）', () async {
      final store = _FakeStore();
      var fail = true;
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          if (fail) throw const NetworkError('断网');
          return _result(requestId: e.id);
        },
        policy: const OutboxRetryPolicy(maxAttempts: 1, jitterRatio: 0),
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a', maxAttempts: 1));
      await queue.load('u1');
      await _settle();
      await queue.onConnectivityRestored();
      await _settle();
      expect(queue.snapshot.single.status, OutboxStatus.failed);

      fail = false;
      expect(await queue.retryNow('a'), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(queue.snapshot, isEmpty, reason: '手动重试成功后应出队');
      expect(store.rows, isEmpty);
    });

    test('retryNow 不存在的 id → false', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => _result());
      addTearDown(queue.dispose);
      expect(await queue.retryNow('不存在'), isFalse);
    });

    test('remove 等价于 cancel（用户丢弃）', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => _result());
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a'));
      await queue.load('u1');
      await _settle();
      await queue.remove('a');

      expect(queue.snapshot, isEmpty);
      expect(store.rows, isEmpty);
    });
  });

  group('OutboxQueue.onConnectivityRestored', () {
    test('把所有**非 failed** 条目的 nextAttemptAt 拉到现在', () async {
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      final future = DateTime.now().add(const Duration(hours: 1));
      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        _queued(
          id: 'a',
          attempts: 1,
          lastError: '断网',
          nextAttemptAt: future,
          createdAt: base,
        ),
      );
      await store.upsert(
        _queued(
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
      final store = _FakeStore();
      final order = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          order.add(e.id);
          return _result(requestId: e.id);
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
        _queued(
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
      final store = _FakeStore();
      final queue = OutboxQueue(store: store, send: (e) async => _result());
      addTearDown(queue.dispose);
      await queue.onConnectivityRestored();
    });
  });

  group('OutboxQueue.load', () {
    test('恢复存储里的条目并按 createdAt 排序', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      final base = DateTime.utc(2026, 1, 1, 12);
      await store.upsert(
        _queued(id: 'b', createdAt: base.add(const Duration(minutes: 1))),
      );
      await store.upsert(_queued(id: 'a', createdAt: base));

      await queue.load('u1');

      expect(queue.snapshot.map((e) => e.id), ['a', 'b']);
      expect(queue.userId, 'u1');
    });

    test('load 失败**不抛**（只记 warn）——启动期没有可展示错误的上下文', () async {
      final store = _FakeStore()..failWith = const StorageError('库损坏');
      final queue = OutboxQueue(store: store, send: (e) async => _result());
      addTearDown(queue.dispose);

      // 与 submit 路径的关键差异：这里没有 UI 可提示，抛出去会让 App 启动崩。
      // 后续每次 submit 都会重新尝试存储。
      await queue.load('u1');
      expect(queue.snapshot, isEmpty);
    });

    test('重新 load 会替换内存视图（换账号）', () async {
      final store = _FakeStore();
      final queue = OutboxQueue(
        store: store,
        send: (e) async => throw const NetworkError('断网'),
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a', userId: 'u1'));
      await store.upsert(_queued(id: 'b', userId: 'u2'));

      await queue.load('u1');
      expect(queue.snapshot.map((e) => e.id), ['a']);

      await queue.load('u2');
      expect(queue.snapshot.map((e) => e.id), ['b']);
    });
  });

  group('OutboxQueue：并发与生命周期', () {
    test('并发 drain 不会把同一队首投两次', () async {
      final store = _FakeStore();
      final calls = <String>[];
      final gate = Completer<void>();
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          calls.add(e.id);
          await gate.future;
          return _result(requestId: e.id);
        },
      );
      addTearDown(queue.dispose);

      await store.upsert(_queued(id: 'a'));
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
      final store = _FakeStore();
      final calls = <String>[];
      final queue = OutboxQueue(
        store: store,
        send: (e) async {
          calls.add(e.id);
          return _result(requestId: e.id);
        },
      );

      await store.upsert(_queued(id: 'a'));
      await queue.dispose();
      await queue.drain();

      expect(calls, isEmpty);
    });

    test('dispose 后再 dispose 不抛（幂等）', () async {
      final queue = OutboxQueue(
        store: _FakeStore(),
        send: (e) async => _result(),
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
        final store = _FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
          policy: const OutboxRetryPolicy(maxAttempts: 5, jitterRatio: 0),
        );
        addTearDown(queue.dispose);

        await store.upsert(_queued(id: 'a'));
        await queue.load('u1');
        await _settle();

        // 之后所有 upsert 都失败。
        store.failUpsertWith = const StorageError('磁盘满', cause: 'no space');
        await queue.onConnectivityRestored();
        await _settle();

        final rec = recordsWith('离线队列退避时间未落盘（重启后首次投递时刻可能偏早）');
        expect(rec, hasLength(1));
        expect(rec.single.fields['request_id'], 'a');
        expect(rec.single.fields['error'], contains('磁盘满'));
      });

      test('条目状态未落盘（重试耗尽）→ 记 warn（重启后可能仍按 pending 重试）', () async {
        final store = _FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
          policy: const OutboxRetryPolicy(maxAttempts: 1, jitterRatio: 0),
        );
        addTearDown(queue.dispose);

        await store.upsert(_queued(id: 'a', maxAttempts: 1));
        // ⚠️ 必须在 load 之前置故障：`load` 内部会 unawaited(drain())，那轮就把
        // 条目打到 failed 了。若晚于它，`failed` 已落盘，且
        // `onConnectivityRestored` 会**跳过** failed 条目（重试权在用户手里）
        // → 什么都不发生，用例测不到目标分支。
        store.failUpsertWith = const StorageError('磁盘满');
        await queue.load('u1');
        await _settle();

        expect(queue.snapshot.single.status, OutboxStatus.failed);
        final rec = recordsWith('离线队列条目状态未落盘（重启后可能仍按 pending 重试）');
        expect(rec, hasLength(1), reason: '这是「重启后与用户所见不一致」的真实来源');
        expect(rec.single.level, LogLevel.warn);
        expect(rec.single.fields['status'], 'failed');
        expect(rec.single.fields['request_id'], 'a');
      });

      test('终态条目删除失败 → 记 debug（幂等键兜底，故不是 warn）', () async {
        final store = _FakeStore();
        final queue = OutboxQueue(
          store: store,
          // 终态错误（不可重试）→ 走 delete 分支。
          send: (e) async => throw const AuthError('会话失效'),
        );
        addTearDown(queue.dispose);

        await store.upsert(_queued(id: 'a'));
        // 同上：终态判定发生在 load 那轮 drain 里，故障要提前置。
        store.failDeleteWith = const StorageError('库损坏');
        await queue.load('u1');
        await _settle();

        final rec = recordsWith('离线队列终态条目删除失败（重启后可能重复投递，幂等键兜底）');
        expect(rec, hasLength(1));
        expect(rec.single.level, LogLevel.debug);
        expect(rec.single.fields['request_id'], 'a');
      });

      test('onConnectivityRestored 的落盘循环失败 → 每条都有日志', () async {
        final store = _FakeStore();
        final queue = OutboxQueue(
          store: store,
          send: (e) async => throw const NetworkError('断网'),
        );
        addTearDown(queue.dispose);

        await store.upsert(_queued(id: 'a'));
        await store.upsert(_queued(id: 'b'));
        await queue.load('u1');
        await _settle();

        store.failUpsertWith = const StorageError('磁盘满');
        await queue.onConnectivityRestored();
        await _settle();

        final rec = recordsWith('离线队列提前重试时间未落盘（重启后首次投递时刻可能偏后）');
        expect(rec.map((r) => r.fields['request_id']), containsAll(['a', 'b']));
      });
    });

    test('entries 流推全量快照（同 items 的取向）', () async {
      final store = _FakeStore();
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
