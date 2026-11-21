import 'dart:math';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/outbox_harness.dart';

/// Outbox 的重试策略与条目派生
///
/// ⚠️ 本文件由 `outbox_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/outbox_harness.dart`。
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
      expect(queuedFixture().status, OutboxStatus.pending);
    });

    test('attempts>0 且未达上限 → retrying', () {
      expect(queuedFixture(attempts: 1).status, OutboxStatus.retrying);
      expect(queuedFixture(attempts: 9).status, OutboxStatus.retrying);
    });

    test('达上限且有 lastError → failed', () {
      expect(
        queuedFixture(attempts: 10, lastError: '超时').status,
        OutboxStatus.failed,
      );
    });

    test('达上限但**没有** lastError → 不是 failed（状态从证据派生）', () {
      // 若不判 lastError，「已成功但 attempts 恰好是 10」的条目会被误标失败。
      expect(queuedFixture(attempts: 10).status, OutboxStatus.retrying);
    });

    test('copyWith(clearLastError: true) 能清空 lastError（失败 → retrying）', () {
      final failed = queuedFixture(attempts: 10, lastError: '超时');
      expect(failed.status, OutboxStatus.failed);
      final revived = failed.copyWith(attempts: 0, clearLastError: true);
      expect(revived.lastError, isNull);
      expect(revived.status, OutboxStatus.pending);
    });
  });

  group('OutboxEntry.toRequestFields', () {
    test('id 映射为 request_id（幂等键与主键合一）', () {
      final f = queuedFixture(id: 'req-xyz').toRequestFields();
      // ⚠️ 这一条是切片 C 的**幂等性根基**：服务端按 `(user_id, request_id)`
      // 去重，故重试必须带同一个 request_id。若这里漏了它，重试会创建重复 turn。
      expect(f['request_id'], 'req-xyz');
    });

    test('groupId 为 null 时不发 group_id（无归属入口）', () {
      final f = queuedFixture().toRequestFields();
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
}
