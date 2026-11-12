import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// 对话页缩略图缓存的条目上限（安全上界，不是实测最优值）。
///
/// ## 为什么要有这条线
///
/// `_thumbnailMemo` 曾按 `ufsFileId` 无界记忆化（docs/memory-audit.md G8 /
/// issue #70）：桌面端主窗口常驻，用户在一个大对话里滚过上千个图片交付物，
/// 每张都留一份**已下载的缩略图字节**，直到切对话。生产实测单对话可有上千个
/// 交付物（服务端 256px 缩略图仍几 KB～几十 KB），线性增长可达几十 MB。
///
/// 512 是**保守上界**（512 × ~30KB ≈ 15MB，与 16MB 字节线基本重合），不是
/// 「实测峰值」——真实峰值靠 [MemoryLedger] 的 `conversation.thumbnails`
/// 读数从用户机器上回收后再校准。**先有界、再调参**：无界是结构缺陷，参数
/// 不理想只是取舍。
const int kThumbnailMemoMaxEntries = 512;

/// 缩略图缓存的总字节上限（估算口径：已解析条目的字节长度之和）。
///
/// 与 [kThumbnailMemoMaxEntries] 同时生效，谁先到线谁触发淘汰。单独设字节线
/// 是因为条目大小差两个量级（256px 缩略图几 KB，个别原图回退可几十 KB），
/// 只按条目数限会让「几十张大图」与「512 张缩略图」占用差一个数量级。
const int kThumbnailMemoMaxBytes = 16 * 1024 * 1024;

/// [ThumbnailMemo] 的累计统计（诊断/测试用；不参与淘汰决策）。
///
/// 计数器**只在会话内累积**（[ThumbnailMemo.clear] 不清零），故 `peak*` 是
/// 「本页生命周期内的峰值」——正是校准上限需要的那两个数。
@immutable
class ThumbnailMemoStats {
  const ThumbnailMemoStats({
    required this.entries,
    required this.bytes,
    required this.hits,
    required this.misses,
    required this.evictions,
    required this.invalidations,
    required this.peakEntries,
    required this.peakBytes,
  });

  /// 当前条目数。
  final int entries;

  /// 当前已解析条目字节数之和。
  final int bytes;

  /// 命中次数（同一版本再次请求，未发网络请求）。
  final int hits;

  /// 未命中次数（真正发起了加载）。
  final int misses;

  /// 因容量（条目数/字节数）被淘汰的次数。
  final int evictions;

  /// 因**版本变化**或显式逐出（文件被删）失效的次数——与容量淘汰分开计，
  /// 因为前者是正确性事件，后者是内存换请求的取舍。
  final int invalidations;

  /// 生命周期内条目数峰值。
  final int peakEntries;

  /// 生命周期内字节数峰值。
  final int peakBytes;
}

/// 按「文件 id + 版本」记忆化的**有界**缩略图缓存。
///
/// ## 两个问题，两种修法（不要混为一谈）
///
/// 1. **无界增长**（容量问题）→ 容量淘汰：条目数与字节数双上限，淘汰
///    「最旧写入」（`LinkedHashMap` 插入序，与仓库其余缓存同一取向）。
/// 2. **版本覆盖后不刷新**（正确性问题）→ **版本令牌**：键仍是 `ufsFileId`
///    （UFS 覆盖写不换 id），但调用方必须给出随文件内容变化的 `version`
///    （对话页用 `action + modifiedAt + deletedAt + sizeBytes + mimeType`）。
///    令牌变了就逐出旧条目、重新加载。
///
/// ## 为什么不把版本并进 map 的键
///
/// 并进键（`'$id@$version'`）会让同一文件的历史版本各留一份，且无法在
/// 「文件被删除」时按 id 逐出。分开存 `_versions` 后，逐出是按 id 的
/// 单点操作，字节账也能逐项扣减。
///
/// ## 失败项同样缓存（有意保留）
///
/// `load()` 返回 null / 抛错的条目照样留到淘汰（与旧实现一致）：失败通常是
/// 永久性的（无缩略图能力 / 已删除），重试只是白跑。失败项不计字节。
class ThumbnailMemo {
  ThumbnailMemo({
    this.maxEntries = kThumbnailMemoMaxEntries,
    this.maxBytes = kThumbnailMemoMaxBytes,
  });

  /// 条目数上限（见 [kThumbnailMemoMaxEntries]）。
  final int maxEntries;

  /// 字节数上限（见 [kThumbnailMemoMaxBytes]）。
  final int maxBytes;

  /// 按插入序排列，`keys.first` 即「最旧写入」。Dart `LinkedHashMap`
  /// **重复赋值不移动位置**，故淘汰语义是「最旧写入」而不是 LRU——
  /// 与 `GroupTitleCache` / `GroupSyncThrottle` 一致（见 AGENTS.md §6.59）。
  final LinkedHashMap<String, Future<List<int>?>> _entries =
      LinkedHashMap<String, Future<List<int>?>>();

  /// 每个条目对应的版本令牌（仅对 `_entries` 中存在的 id 有值）。
  final Map<String, Object> _versions = <String, Object>{};

  /// 已解析条目的字节数（未解析/失败条目不出现在这里）。
  final Map<String, int> _bytesById = <String, int>{};

  int _bytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _evictions = 0;
  int _invalidations = 0;
  int _peakEntries = 0;
  int _peakBytes = 0;

  /// 当前条目数。
  int get length => _entries.length;

  /// 当前已解析字节数之和。
  int get bytes => _bytes;

  /// 是否已缓存该 id（任意版本；测试用）。
  @visibleForTesting
  bool contains(String id) => _entries.containsKey(id);

  /// 累计统计（诊断用）。
  ThumbnailMemoStats get stats => ThumbnailMemoStats(
    entries: _entries.length,
    bytes: _bytes,
    hits: _hits,
    misses: _misses,
    evictions: _evictions,
    invalidations: _invalidations,
    peakEntries: _peakEntries,
    peakBytes: _peakBytes,
  );

  /// 取（或加载）某文件的缩略图。
  ///
  /// [version] 变化 ⇒ 旧条目立即逐出并重新 [load]；否则命中直接返回同一个
  /// `Future`（卡片 `FutureBuilder` 的 `future` 不变，不会闪 loading）。
  ///
  /// 注意 [load] 抛**同步**异常时不写入任何状态（与旧 `putIfAbsent` 语义
  /// 一致）：调用方拿到异常，缓存保持原样。
  Future<List<int>?> resolve(
    String id,
    Object version,
    Future<List<int>?> Function() load,
  ) {
    final existing = _entries[id];
    if (existing != null && _versions[id] == version) {
      _hits++;
      return existing;
    }

    _misses++;
    final future = load();
    // load 可能同步抛错：取得 Future 后再替换，避免留下没有条目的版本键，
    // 也避免加载新版本失败时提前销毁仍可供旧版本请求使用的缓存。
    if (existing != null) {
      _drop(id);
      _invalidations++;
    }
    _versions[id] = version;
    _entries[id] = future;
    if (_entries.length > maxEntries) _trimEntries();
    if (_entries.length > _peakEntries) _peakEntries = _entries.length;

    // 解析后记账并做字节淘汰。用 `identical` 判据而不是「id 还在」：该条目
    // 可能在解析期间被版本更新/容量淘汰换掉，此时旧 Future 的字节不该入账。
    unawaited(
      future.then<void>(
        (data) => _onResolved(id, future, data),
        // 失败项不占字节（见类文档「失败项同样缓存」）。这里必须兜住：
        // `then` 若不处理错误会派生一个未处理的 Future 错误（调用方那份
        // 仍会收到错误，行为不变）。
        onError: (Object _, StackTrace _) {},
      ),
    );
    return future;
  }

  /// 显式逐出（文件被删除等生命周期事件）。
  ///
  /// 与容量淘汰分开计数（[ThumbnailMemoStats.invalidations]）：这是**正确性**
  /// 事件，不是「内存不够了」。
  void evict(String id) {
    if (!_entries.containsKey(id)) return;
    _drop(id);
    _invalidations++;
  }

  /// 清空（切换对话时调用）。累计统计与峰值保留，便于诊断看整页生命周期。
  void clear() {
    _entries.clear();
    _versions.clear();
    _bytesById.clear();
    _bytes = 0;
  }

  void _onResolved(String id, Future<List<int>?> future, List<int>? data) {
    if (!identical(_entries[id], future)) return;
    final size = data?.length ?? 0;
    _bytesById[id] = size;
    _bytes += size;
    if (_bytes > _peakBytes) _peakBytes = _bytes;
    _trimBytes(keepId: id);
  }

  void _drop(String id) {
    _entries.remove(id);
    _versions.remove(id);
    final size = _bytesById.remove(id);
    if (size != null) _bytes -= size;
  }

  /// 条目数淘汰：从最旧写入开始丢，直到回到线内。
  void _trimEntries() {
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      _drop(oldest);
      _evictions++;
    }
  }

  /// 字节淘汰：从最旧写入开始丢，但**不丢刚解析的那一条**——否则单张略超
  /// 预算的图会陷入「每次 build 都重拉」的循环（比多占几 MB 糟得多）。
  void _trimBytes({required String keepId}) {
    while (_bytes > maxBytes) {
      String? victim;
      for (final key in _bytesById.keys) {
        if (key != keepId && _bytesById[key]! > 0) {
          victim = key;
          break;
        }
      }
      if (victim == null) return;
      _drop(victim);
      _evictions++;
    }
  }
}
