/// Outbox 队列 的共享夹具（issue #48 从 `outbox_test.dart` 抽出）。
///
/// ⚠️ 文件私有的 `_Xxx` 移到共享库后必须去掉下划线（跨库不可见），
/// 故拆分时引用它们的调用点同步改名（纯重命名，无行为变化）。
library;

import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

/// 内存版 [OutboxStore]。
///
/// ## 为什么不用 `DriftOutboxStore`
///
/// 本文件测的是**队列逻辑**（FIFO / 退避 / 终态处理），不是 SQL。用内存
/// 实现让每条用例只关心行为，且能在 `dart test`（无 Flutter 引擎）里跑。
/// 持久化本身由 `spb_data/test/outbox_store_test.dart` 覆盖。
class FakeStore implements OutboxStore {
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
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SendMessageResult result({
  String turnId = 't1',
  String groupId = 'g1',
  String? requestId,
}) => SendMessageResult(
  turnId: turnId,
  groupId: groupId,
  status: 'queued',
  requestId: requestId,
);

OutboxEntry queuedFixture({
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
