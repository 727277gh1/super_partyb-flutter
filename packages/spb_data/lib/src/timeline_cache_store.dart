import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'database.dart';

/// 基于 drift 的 [TimelineCacheStore] 实现（issue #26 切片 B / issue #29）。
///
/// ## 语义总纲：**可丢弃数据**
///
/// 每一处失败都**静默降级**（记日志 + 返回空 / 不抛），与 [DriftSyncStateStore]
/// 相反，理由见 [TimelineCacheStore] 的类文档。
class DriftTimelineCacheStore implements TimelineCacheStore {
  DriftTimelineCacheStore(
    this._db, {
    this.maxEventsPerGroup = 2000,
    this.maxEventPayloadBytes = 64 * 1024,
    this.maxTotalBytes = 64 * 1024 * 1024,
  });

  final AppDatabase _db;

  /// 每 group 事件条数上限（§5.2）。对齐 `ChatStreamController.maxBufferEvents`
  /// ——缓存比内存缓冲区多没有意义（多出来的部分归约器根本不会用）。
  final int maxEventsPerGroup;

  /// 单事件 payload 上限（§5.2）。超过则**不缓存该事件**（不截断）。
  final int maxEventPayloadBytes;

  /// 全库总字节上限（§5.2）。超出按 `lastAccessedAt` 升序淘汰**整 group**。
  final int maxTotalBytes;

  @override
  Future<List<ChatEvent>> load(String groupId, {int? limit}) async {
    try {
      // 读取即视为「访问」：LRU 淘汰依赖它。放在 try 内，失败不阻断读取。
      unawaited(_touch(groupId));

      var query = _db.select(_db.cachedEvents)
        ..where((t) => t.groupId.equals(groupId))
        // 升序：归约器假定输入按时间正序（见 `ChatStreamController._backfill`
        // 的显式排序）。返回降序会让渲染顺序颠倒，且**不会报错**。
        ..orderBy([(t) => OrderingTerm.asc(t.globalSeq)]);
      if (limit != null && limit > 0) {
        // 取**最新的** limit 条（用户最可能想看的是近期历史），故按降序取
        // 再反转，而不是「升序取前 limit 条」（那会拿到最旧的 limit 条）。
        query = _db.select(_db.cachedEvents)
          ..where((t) => t.groupId.equals(groupId))
          ..orderBy([(t) => OrderingTerm.desc(t.globalSeq)])
          ..limit(limit);
      }

      final rows = await query.get();
      final ordered = limit != null && limit > 0
          ? rows.reversed.toList(growable: false)
          : rows;

      final out = <ChatEvent>[];
      for (final row in ordered) {
        final decoded = _decode(row.payload);
        if (decoded == null) {
          // 单行 payload 坏了（截断 / 手工改过）：跳过它，保留其余行。
          // 不能因为一行坏就返回空——那等于整份缓存作废。
          SpbLog.warn('timeline 缓存行解析失败，跳过该行', {
            'group_id': row.groupId,
            'global_seq': row.globalSeq,
          });
          continue;
        }
        out.add(decoded);
      }
      return out;
    } catch (e) {
      SpbLog.warn('读取 timeline 缓存失败，按无缓存处理', {
        'group_id': groupId,
        'error': e.toString(),
      });
      return const [];
    }
  }

  @override
  Future<void> save(String groupId, List<ChatEvent> events) async {
    // 过滤在实现层做（而不是要求调用方自己筛）：把不该缓存的项写进去**不会
    // 报错**，只会让「断网时看到的历史」与服务端不一致。放在这里等于给所有
    // 调用点兜底。
    final cacheable = events.where(isCacheableEvent).toList(growable: false);
    if (cacheable.isEmpty) return;

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = <CachedEventsCompanion>[];
      for (final e in cacheable) {
        final encoded = jsonEncode(e.toJson());
        // 单事件上限：超过则**不缓存**（不截断）。截断会产生一个「看起来完整
        // 但内容缺失」的事件，比缺席更糟——归约器会把它当权威帧（§5.2）。
        if (utf8.encode(encoded).length > maxEventPayloadBytes) {
          SpbLog.debug('timeline 事件超过单条上限，不缓存', {
            'group_id': groupId,
            'global_seq': e.globalSeq,
            'event_type': e.eventType,
          });
          continue;
        }
        rows.add(
          CachedEventsCompanion.insert(
            groupId: groupId,
            globalSeq: e.globalSeq!,
            payload: encoded,
            cachedAt: now,
            lastAccessedAt: now,
          ),
        );
      }
      if (rows.isEmpty) return;

      await _db.transaction(() async {
        await _db.batch((b) {
          // upsert：同一 `(groupId, globalSeq)` 重复拉取（分页重叠）时**覆盖**
          // 而非插两行。见接口文档「为什么是 upsert 而不是先删后插」。
          b.insertAll(_db.cachedEvents, rows, mode: InsertMode.insertOrReplace);
        });
        await _trimGroup(groupId);
        await _evictIfOversized();
      });
    } catch (e) {
      // **不抛**：写失败只意味着下次断网看不到这段历史，不影响主流程。
      SpbLog.warn('写入 timeline 缓存失败（忽略）', {
        'group_id': groupId,
        'count': cacheable.length,
        'error': e.toString(),
      });
    }
  }

  @override
  Future<void> clear(String groupId) async {
    try {
      await (_db.delete(
        _db.cachedEvents,
      )..where((t) => t.groupId.equals(groupId))).go();
    } catch (e) {
      SpbLog.warn('清空 timeline 缓存失败（忽略）', {
        'group_id': groupId,
        'error': e.toString(),
      });
    }
  }

  /// 标记该 group 被访问（LRU 淘汰依据）。
  Future<void> _touch(String groupId) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await (_db.update(_db.cachedEvents)
            ..where((t) => t.groupId.equals(groupId)))
          .write(CachedEventsCompanion(lastAccessedAt: Value(now)));
    } catch (_) {
      // 访问时间只影响淘汰顺序，失败无后果。
    }
  }

  /// 每 group 条数上限：超出则丢弃**最旧**的事件（§5.2）。
  ///
  /// ## 为什么丢最旧而不是最新
  ///
  /// 时间线以「最新」为焦点（打开即滚到底部、新事件从尾部追加），故丢最旧
  /// 对用户可感知的影响最小——与 `ChatStreamController._trimBuffer` 同一取向。
  Future<void> _trimGroup(String groupId) async {
    final count =
        await (_db.selectOnly(_db.cachedEvents)
              ..addColumns([_db.cachedEvents.globalSeq.count()])
              ..where(_db.cachedEvents.groupId.equals(groupId)))
            .map((r) => r.read(_db.cachedEvents.globalSeq.count()))
            .getSingleOrNull() ??
        0;
    final excess = count - maxEventsPerGroup;
    if (excess <= 0) return;

    // 找出要删的 globalSeq（最旧的 excess 条）。
    final victims =
        await (_db.select(_db.cachedEvents)
              ..where((t) => t.groupId.equals(groupId))
              ..orderBy([(t) => OrderingTerm.asc(t.globalSeq)])
              ..limit(excess))
            .get();
    final seqs = victims.map((r) => r.globalSeq).toList(growable: false);
    await (_db.delete(
      _db.cachedEvents,
    )..where((t) => t.groupId.equals(groupId) & t.globalSeq.isIn(seqs))).go();
    SpbLog.debug('timeline 缓存超出每 group 上限，丢弃最旧事件', {
      'group_id': groupId,
      'dropped': seqs.length,
      'limit': maxEventsPerGroup,
    });
  }

  /// 全库总字节上限：超出则按 `lastAccessedAt` 升序淘汰**整 group**（§5.3）。
  ///
  /// ## 为什么按 group 而不是按事件
  ///
  /// 按事件淘汰会让某 group 的历史出现「中间空洞」：用户向上翻页时看到
  /// `globalSeq` 跳跃，且无法判断是「被淘汰了」还是「服务端就没有」。
  /// 整 group 淘汰的语义是清晰的：**这个 group 没有缓存**。
  Future<void> _evictIfOversized() async {
    final total =
        await (_db.selectOnly(_db.cachedEvents)
              ..addColumns([_db.cachedEvents.payload.length.sum()]))
            .map((r) => r.read(_db.cachedEvents.payload.length.sum()) ?? 0)
            .getSingleOrNull() ??
        0;
    if (total <= maxTotalBytes) return;

    // 按 group 聚合「总字节 + 最近访问时刻」，最久未访问的整组先淘汰。
    final perGroup =
        await (_db.selectOnly(_db.cachedEvents)
              ..addColumns([
                _db.cachedEvents.groupId,
                _db.cachedEvents.payload.length.sum(),
                _db.cachedEvents.lastAccessedAt.max(),
              ])
              ..groupBy([_db.cachedEvents.groupId]))
            .get();

    final groups =
        perGroup
            .map(
              (r) => (
                groupId: r.read(_db.cachedEvents.groupId)!,
                bytes: r.read(_db.cachedEvents.payload.length.sum()) ?? 0,
                lastAccess: r.read(_db.cachedEvents.lastAccessedAt.max()) ?? 0,
              ),
            )
            .toList()
          ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));

    var remaining = total;
    final evicted = <String>[];
    for (final g in groups) {
      if (remaining <= maxTotalBytes) break;
      evicted.add(g.groupId);
      remaining -= g.bytes;
    }
    if (evicted.isEmpty) return;

    await (_db.delete(
      _db.cachedEvents,
    )..where((t) => t.groupId.isIn(evicted))).go();
    SpbLog.info('timeline 缓存超出全库上限，按 group 淘汰', {
      'evicted_groups': evicted.length,
      'before_bytes': total,
      'after_bytes': remaining,
      'limit': maxTotalBytes,
    });
  }

  /// 解析一行 payload；失败返回 null（调用方跳过该行）。
  ChatEvent? _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return ChatEvent.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      // 静默返回 null：**调用方**负责记日志（它能带上 group_id / global_seq）。
      // 同 `group_cache_store._decode`，在这里再记会重复。
      return null;
    }
  }
}
