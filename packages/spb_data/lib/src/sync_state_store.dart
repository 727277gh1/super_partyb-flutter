import 'package:drift/drift.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';

import 'database.dart';

/// 基于 drift 的 [SyncStateStore] 实现。
///
/// ## 语义对齐（与 Tauri 端的 JSON 实现一致）
///
/// - `load` 对未写入过的键返回 [SyncState.empty]（= 首次同步、下轮全量），
///   **不抛异常**：状态缺失是正常状态，不是错误；
/// - `save` 是**整体替换**：先删该键的全部文件记录再插入新记录。若只做
///   upsert 而不删，远端已删除的文件会永远留在表里，`contains()` 会一直
///   返回 true，导致「远端删了但本地没删」；
/// - `save`/`reset`/`resetAll` 在**同一个事务**里完成多步写入，避免中途
///   崩溃留下「游标已推进但 etag 没写」的半截状态——那会让下一轮漏更新
///   一批文件。
class DriftSyncStateStore implements SyncStateStore {
  DriftSyncStateStore(this._db);

  final AppDatabase _db;

  @override
  Future<SyncState> load(String key) async {
    try {
      final cursorRows = await (_db.select(
        _db.syncCursors,
      )..where((t) => t.stateKey.equals(key))).get();

      final fileRows = await (_db.select(
        _db.syncedFiles,
      )..where((t) => t.stateKey.equals(key))).get();

      return SyncState(
        cursor: cursorRows.isEmpty ? null : cursorRows.first.cursor,
        files: {for (final row in fileRows) row.relPath: row.toDomain()},
      );
    } on SpbError {
      rethrow;
    } catch (e) {
      // 读失败（库损坏 / 磁盘错误）按「首次同步」处理，而不是让整个同步功能
      // 不可用——与 Tauri 端 `load` 在解析失败时返回默认值一致。
      SpbLog.warn('读取同步状态失败，按首次同步处理', {'key': key, 'error': e.toString()});
      return SyncState.empty;
    }
  }

  @override
  Future<void> save(String key, SyncState state) async {
    try {
      await _db.transaction(() async {
        // 先清掉该键的旧记录：save 是整体替换语义（见类文档）。
        await (_db.delete(
          _db.syncedFiles,
        )..where((t) => t.stateKey.equals(key))).go();

        await _db
            .into(_db.syncCursors)
            .insertOnConflictUpdate(
              SyncCursorsCompanion.insert(
                stateKey: key,
                cursor: Value(state.cursor),
              ),
            );

        for (final entry in state.files.entries) {
          await _db
              .into(_db.syncedFiles)
              .insertOnConflictUpdate(entry.value.toCompanion(key, entry.key));
        }
      });
    } catch (e) {
      throw StorageError('写入同步状态失败：$e', cause: e);
    }
  }

  @override
  Future<void> reset(String key) async {
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.syncedFiles,
        )..where((t) => t.stateKey.equals(key))).go();
        await (_db.delete(
          _db.syncCursors,
        )..where((t) => t.stateKey.equals(key))).go();
      });
    } catch (e) {
      throw StorageError('清除同步状态失败：$e', cause: e);
    }
  }

  @override
  Future<void> resetAll() async {
    try {
      await _db.transaction(() async {
        await _db.delete(_db.syncedFiles).go();
        await _db.delete(_db.syncCursors).go();
      });
    } catch (e) {
      throw StorageError('清除全部同步状态失败：$e', cause: e);
    }
  }

  /// 当前绑定的同步目录（null = 尚未选过）。
  Future<String?> boundLocalRoot() async {
    final rows = await _db.select(_db.syncBindings).get();
    return rows.isEmpty ? null : rows.first.localRoot;
  }

  /// 绑定同步目录；**目录变了就清空全部状态**。
  ///
  /// 返回是否发生了重置（true = 目录变更，已清空）。
  ///
  /// ## 为什么目录变更必须清状态
  ///
  /// 状态描述的是「某个本地目录里已有什么」，绑定在具体目录上：
  ///
  /// - 保留游标 → 增量清单只返回 `updated_at >= 游标` 的文件，新目录几乎
  ///   什么都拿不到；
  /// - 保留 etag → 少数恰好出现在清单里的文件被判为「未变更」而跳过写入，
  ///   但新目录里根本没有这个文件。
  ///
  /// 叠加效果就是「换目录后同步显示成功，但新目录是空的」。
  ///
  /// ## 为什么与范围变更区分
  ///
  /// **改变同步范围**（全量 ↔ 选中若干 group）**不得**调用本方法：两种范围
  /// 的落盘布局相同，共用 [workspaceStateKey]，清掉会让所有文件全量重下。
  ///
  /// 绑定与状态在同一事务里更新，避免「目录已改、状态没清」的中间态——
  /// 那个中间态正是上面那个 bug。
  Future<bool> bindLocalRoot(String? localRoot) async {
    try {
      return await _db.transaction(() async {
        final current = await _db.select(_db.syncBindings).get();
        final previous = current.isEmpty ? null : current.first.localRoot;
        if (current.isNotEmpty && previous == localRoot) return false;

        await _db
            .into(_db.syncBindings)
            .insertOnConflictUpdate(
              SyncBindingsCompanion.insert(
                id: const Value(1),
                localRoot: Value(localRoot),
              ),
            );

        // 首次绑定（previous == null）时库里本就没有状态，清一遍无害；
        // 换目录时这里是关键步骤。
        if (previous != null) {
          await _db.delete(_db.syncedFiles).go();
          await _db.delete(_db.syncCursors).go();
        }
        return previous != null;
      });
    } catch (e) {
      throw StorageError('绑定同步目录失败：$e', cause: e);
    }
  }
}
