import 'package:drift/drift.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

import 'database.dart';

/// 基于 drift 的 [OutboxStore] 实现（issue #26 切片 C / issue #30）。
///
/// ## 与另外两个 store **相反**：不静默降级
///
/// `DriftGroupCacheStore` / `DriftTimelineCacheStore` 是可丢弃数据，每一处失败
/// 都静默降级（读失败返回空、写失败只记日志）。本 store 装的是**用户输入的
/// 文本**，静默降级等于「假装排队成功、其实什么都没存」——用户会以为消息发出去
/// 了（设计文档 §7bis.9）。
///
/// 故读写失败一律抛 [StorageError]，由调用方降级为「发送失败提示」（即修复前
/// 的行为，诚实）。
class DriftOutboxStore implements OutboxStore {
  DriftOutboxStore(this._db);

  final AppDatabase _db;

  @override
  Future<List<OutboxEntry>> load(String userId) async {
    try {
      final rows =
          await (_db.select(_db.outboxEntries)
                ..where((t) => t.userId.equals(userId))
                // FIFO：按入队时刻升序。严格全局顺序是硬要求（设计文档
                // §7bis.5）——两条消息调换顺序会改变语义。
                ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
              .get();
      return rows.map(_toEntry).toList(growable: false);
    } catch (e) {
      throw StorageError('读取离线队列失败：$e', cause: e);
    }
  }

  @override
  Future<void> upsert(OutboxEntry entry) async {
    try {
      await _db
          .into(_db.outboxEntries)
          .insertOnConflictUpdate(_toCompanion(entry));
    } catch (e) {
      throw StorageError('写入离线队列失败：$e', cause: e);
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await (_db.delete(_db.outboxEntries)..where((t) => t.id.equals(id))).go();
    } catch (e) {
      throw StorageError('删除离线队列条目失败：$e', cause: e);
    }
  }

  @override
  Future<void> clear(String userId) async {
    try {
      await (_db.delete(
        _db.outboxEntries,
      )..where((t) => t.userId.equals(userId))).go();
    } catch (e) {
      throw StorageError('清空离线队列失败：$e', cause: e);
    }
  }

  OutboxEntry _toEntry(OutboxRow row) => OutboxEntry(
    id: row.id,
    userId: row.userId,
    input: row.input,
    groupId: row.groupId,
    agentId: row.agentId,
    routingMode: row.routingMode,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    attempts: row.attempts,
    nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(row.nextAttemptAt),
    lastError: row.lastError,
    maxAttempts: row.maxAttempts,
  );

  OutboxEntriesCompanion _toCompanion(OutboxEntry e) =>
      OutboxEntriesCompanion.insert(
        id: e.id,
        userId: e.userId,
        input: e.input,
        // `Value.absent()` 与 `Value(null)` 的区别在这里是**语义性的**：
        // absent 表示「不改这一列」，null 表示「写 NULL」。我们要的是后者
        // ——`groupId` 为 null 是「无归属入口」这个真实状态，不是「不更新」。
        groupId: Value(e.groupId),
        agentId: Value(e.agentId),
        routingMode: e.routingMode,
        createdAt: e.createdAt.millisecondsSinceEpoch,
        attempts: e.attempts,
        nextAttemptAt: e.nextAttemptAt.millisecondsSinceEpoch,
        lastError: Value(e.lastError),
        maxAttempts: Value(e.maxAttempts),
      );
}
