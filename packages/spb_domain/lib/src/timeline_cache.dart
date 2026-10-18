import 'package:spb_models/spb_models.dart';

/// 对话 timeline 只读缓存（issue #26 切片 B / issue #29）。
///
/// ## 它解决什么
///
/// 切片 A（[GroupCacheStore]）消除了「断网启动白屏」，但**点进任何对话仍是
/// 错误页**——timeline 只有网络来源。本契约补上那一层：断网时用缓存的事件
/// 渲染历史。
///
/// ## 语义总纲：**可丢弃数据**（同 [GroupCacheStore]）
///
/// | | `SyncStateStore` | `TimelineCacheStore` |
/// |---|---|---|
/// | 数据性质 | 不可丢（丢了会全量重下文件） | **可丢弃**（丢了只是断网看不到历史） |
/// | 读失败 | 返回 `SyncState.empty` | 返回**空列表** |
/// | 写失败 | 抛 `StorageError` | **不抛**（记日志即可） |
///
/// ## 与 `GroupCacheStore` 的三点不同
///
/// | | `GroupCacheStore` | `TimelineCacheStore` |
/// |---|---|---|
/// | 写入语义 | **整表替换**（服务端删了 group 要能消失） | **增量 upsert**（分页只来一段，替换会丢掉别的页） |
/// | 键 | `userId` | `groupId`（group id 本身全局唯一） |
/// | 内容 | group 元数据 | **落库事件**（不含 transient / diagnostic） |
///
/// 设计依据见 `docs/offline-cache-design.md` §3.5（表结构）、§4.3（写路径）、
/// §5.2（三层体积上限）、§4bis.3（为什么只在网络不可用时读）。
abstract interface class TimelineCacheStore {
  /// 读该 group 缓存的事件（按 `globalSeq` **升序**，与归约器的输入顺序一致）。
  ///
  /// [limit] 为 null 时返回全部（受实现层的每 group 上限约束）。
  /// **无缓存 / 读失败一律返回空列表，不抛异常**。
  ///
  /// 升序是硬要求：`EventReducer.reduce` 假定输入按时间正序（见
  /// `ChatStreamController._backfill` 的显式排序）。返回降序会让归约结果
  /// 错乱——而且不会报错，只是渲染顺序颠倒。
  Future<List<ChatEvent>> load(String groupId, {int? limit});

  /// 追加（upsert）该 group 的事件。
  ///
  /// ## 为什么是 upsert 而不是「先删后插」
  ///
  /// 与 [GroupCacheStore.save] 的整表替换**刚好相反**：timeline 是分页拉取的，
  /// 首屏只来最新一页（`_backfill`）、向上翻页再来更早的一页（`loadOlder`）。
  /// 若整表替换，翻页会把上一页删掉——用户下次断网只能看到最后一页。
  ///
  /// 去重靠主键 `(groupId, globalSeq)` 的 `insertOnConflictUpdate`：同一事件
  /// 被重复拉取（分页重叠）时**覆盖**而非插两行。
  ///
  /// ## 实现必须施加的三层上限（§5.2）
  ///
  /// 1. 每 group 事件条数上限（默认 2000，对齐 `ChatStreamController.maxBufferEvents`）；
  /// 2. 单事件 payload 上限（默认 64 KiB）——**超过则不缓存该事件**，不截断；
  /// 3. 全库总字节上限（默认 64 MiB）——超出按 `lastAccessedAt` 升序淘汰**整 group**。
  ///
  /// [events] 中的不可缓存项（transient / diagnostic / `goal_updated` / 无
  /// `globalSeq`）由实现层按 [isCacheableEvent] 过滤，调用方无需自己筛。
  Future<void> save(String groupId, List<ChatEvent> events);

  /// 清空该 group 的缓存（group 被删除时调用）。
  Future<void> clear(String groupId);
}

/// 一条事件是否可以进缓存。
///
/// ## 为什么放在领域层（纯函数，而不是埋进 drift 实现）
///
/// 它是**正确性核心**：把不该缓存的项写进去不会报错，只会让「断网时看到的历史」
/// 与服务端不一致（多出一些服务端没有的行）。做成纯函数才能在 `dart test` 里
/// 逐条断言，不依赖数据库。
///
/// ## 排除的五类（`docs/offline-cache-design.md` §2.3）
///
/// | 排除 | 理由 |
/// |---|---|
/// | `transient` | 服务端**不落库**，`_backfill` 永远拿不回来——缓存会永远「多出」这些行 |
/// | `diagnostic` | 默认不广播、不进时间线（AGENTS.md §5.4），缓存只是白占体积 |
/// | `goal_updated` | 服务端漏设 `transient` 且**不落库**（见 `ChatStreamController` 的分流注释）。它的真源是业务表，缓存它会污染 timeline |
/// | `globalSeq == null` | 本地乐观回显（`local-<micros>`），服务端无对应物 |
/// | `globalSeq <= 0` | 未落库事件（服务端从不给它分配 global_seq） |
bool isCacheableEvent(ChatEvent event) {
  if (event.transient) return false;
  if (event.diagnostic) return false;
  if (event.eventType == EventTypes.goalUpdated) return false;
  final g = event.globalSeq;
  if (g == null || g <= 0) return false;
  return true;
}
