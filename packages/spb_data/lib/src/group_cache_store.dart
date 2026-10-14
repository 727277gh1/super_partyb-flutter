import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'database.dart';

/// 基于 drift 的 [GroupCacheStore] 实现（issue #26 切片 A）。
///
/// ## 语义总纲：**可丢弃数据**
///
/// 每一处失败都**静默降级**（记日志 + 返回空 / 不抛），与 [DriftSyncStateStore]
/// 相反。理由见 [GroupCacheStore] 的类文档：缓存抛异常会把「对话列表能打开」
/// 变成「对话列表报错」，而它的存在意义是在坏环境下让应用可用。
class DriftGroupCacheStore implements GroupCacheStore {
  DriftGroupCacheStore(this._db);

  final AppDatabase _db;

  @override
  Future<List<ChatGroup>> load(String userId) async {
    try {
      final rows =
          await (_db.select(_db.cachedGroups)
                ..where((t) => t.userId.equals(userId))
                // 与服务端 `GET /chat/groups` 的默认排序一致（updated_at 降序）：
                // 顺序不一致会让「离线看到的第一条」与「在线看到的第一条」不同。
                //
                // 用 `updated_at` 的**文本**降序：服务端返回的是 RFC3339
                // （`2024-03-05T08:09:10Z`），同格式同长度的字符串按字典序排序
                // 等价于按时间排序。不用 `fetched_at`（那是本地写入时刻，同一次
                // 批量写入的行全相同，排序不稳定）。
                ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
              .get();

      final out = <ChatGroup>[];
      for (final row in rows) {
        final decoded = _decode(row.payload);
        if (decoded == null) {
          // 单行 payload 坏了（截断 / 手工改过）：跳过它，保留其余行。
          // 不能因为一行坏就返回空——那等于整份缓存作废。
          SpbLog.warn('缓存行 payload 解析失败，跳过该行', {'group_id': row.id});
          continue;
        }
        out.add(decoded);
      }
      return out;
    } catch (e) {
      // 读失败（库损坏 / 磁盘错误）按「无缓存」处理，而不是让列表页报错。
      SpbLog.warn('读取对话列表缓存失败，按无缓存处理', {
        'user_id': userId,
        'error': e.toString(),
      });
      return const [];
    }
  }

  @override
  Future<void> save(String userId, List<ChatGroup> groups) async {
    try {
      await _db.transaction(() async {
        // 整表替换：先删该 user 的全部行。见接口文档「为什么必须是先删后插」。
        await (_db.delete(
          _db.cachedGroups,
        )..where((t) => t.userId.equals(userId))).go();

        if (groups.isEmpty) return;

        final now = DateTime.now().millisecondsSinceEpoch;
        await _db.batch((b) {
          b.insertAll(
            _db.cachedGroups,
            groups.map(
              (g) => CachedGroupsCompanion.insert(
                id: g.id,
                userId: userId,
                payload: jsonEncode(g.toJson()),
                updatedAt: Value(g.updatedAt.toIso8601String()),
                fetchedAt: now,
              ),
            ),
            // 同一次批量里出现重复 id（服务端分页重叠）时**后者胜**：与
            // `GroupListPage._loadMore` 的「去重后追加」取向一致——列表里
            // 最后出现的那条是更靠后的分页结果。
            mode: InsertMode.insertOrReplace,
          );
        });
      });
    } catch (e) {
      // **不抛**：写失败只意味着下次断网看不到这份缓存，不影响主流程。
      // 与 `DriftSyncStateStore.save` 抛 `StorageError` 的取向相反——那个状态
      // 丢了会导致文件重复下载，是有后果的。
      SpbLog.warn('写入对话列表缓存失败（忽略）', {
        'user_id': userId,
        'count': groups.length,
        'error': e.toString(),
      });
    }
  }

  @override
  Future<void> clear(String userId) async {
    try {
      await (_db.delete(
        _db.cachedGroups,
      )..where((t) => t.userId.equals(userId))).go();
    } catch (e) {
      SpbLog.warn('清空对话列表缓存失败（忽略）', {'user_id': userId, 'error': e.toString()});
    }
  }

  @override
  Future<DateTime?> lastFetchedAt(String userId) async {
    try {
      // 只取一行算最大值，而不是 `SELECT MAX(fetched_at)`：drift 的类型化
      // 查询 API 里对聚合函数要另走 `customSelect`，而本表行数等于对话数
      // （几十到几百），取一行排序的代价可忽略。
      final row =
          await (_db.select(_db.cachedGroups)
                ..where((t) => t.userId.equals(userId))
                ..orderBy([(t) => OrderingTerm.desc(t.fetchedAt)])
                ..limit(1))
              .getSingleOrNull();
      if (row == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(row.fetchedAt);
    } catch (e) {
      SpbLog.warn('读取缓存写入时刻失败（忽略）', {'user_id': userId, 'error': e.toString()});
      return null;
    }
  }

  /// 解析一行 payload；失败返回 null（调用方跳过该行）。
  ///
  /// `ChatGroup.fromJson` 对缺失字段给默认值（不抛），故这里的失败模式主要是
  /// JSON 语法错误（截断）与「顶层不是对象」。
  ChatGroup? _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return ChatGroup.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // 静默返回 null：**调用方**（`load`）负责记日志（它能带上 group_id）。
      // 这里静默是因为本方法只有这一种失败形态（JSON 语法错），而调用方
      // 的日志已经能把「哪一行坏了」说清楚，在这里再记一次会重复。
      return null;
    }
  }
}
