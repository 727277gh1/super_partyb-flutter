import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show imageCache;
import 'package:spb_core/spb_core.dart';

/// 内存高水位日志：把「涨到多少 + 花在谁身上」按低频、边沿触发的方式写进
/// [SpbLog]，供「导出诊断日志」取证（docs/memory-audit.md §四）。
///
/// ## 为什么不能只靠 `MemoryProbe`
///
/// [MemoryProbe] 的采样**不落日志**（一条/分钟会在 8 小时内冲干净 500 条
/// 环形缓冲——见其文件头）。它解决的是「用户导出报告时有没有曲线」，但
/// 回答不了「这台机器平时是不是已经到高水位了」：用户只在**出问题时**才
/// 导出，而「没导出」不等于「没出问题」。
///
/// 本模块补的是**边沿**：只在越过阈值时写一条，且带 [MemoryLedger] 的分解
/// （谁占的），使一条日志就能回答「是引擎基线、图片，还是时间线/清单」。
///
/// ## 三条触发线（任一满足即视为高水位）
///
/// 1. `imageCache` ≥ [imageCacheWarnBytes]（默认 24MB，硬上限是 32MB）——
///    接近上限意味着**马上要开始淘汰/重解码**，是解码位图这条路的直接信号；
/// 2. RSS 相对**本次运行首条采样**增长 ≥ [rssGrowthWarnBytes]（默认 256MB）——
///    RSS 不会回落到基线（Dart GC 不缩堆 + ANGLE 保留），故看「相对起点的
///    增量」而不是绝对值；
/// 3. 任一段 [MemoryLedger] 读数越过它自己声明的 `warnCount` / `warnBytes`。
///
/// ## 为什么必须去抖（两条闸门）
///
/// 阈值一旦越过就会长期保持（RSS 不回落），若每 [interval] 都写一条，
/// 500 条环形缓冲会被同一个读数冲掉——那正是 [MemoryProbe] 刻意不写日志的
/// 原因。故：
///
/// - **冷却时间** [cooldown]（默认 30 分钟）内的重复触发不写；
/// - **无显著变化不写**：RSS 未比上次记录高出 10%、imageCache 未高出 20%
///   时，即使冷却已过也跳过（同样的数字写第二遍没有信息量）。
///
/// ## 为什么不在桌面端自动清缓存
///
/// 原理上可以「RSS 超线就 `imageCache.clear()` + `clearLiveImages()`」，
/// 但那会让**正在看的图**闪一下重解码，且桌面端没有 OS 低内存信号可作依据
/// （移动端有 [installMemoryPressureHandler]）。在拿到真实机器的
/// `peak=`/分解数据之前，这条策略是在拿可见的界面抖动赌一个未知的收益。
/// 故本期只**观测**：先把数据收回来，再决定要不要自动释放。
class MemoryWatchdog {
  MemoryWatchdog({
    this.interval = const Duration(minutes: 5),
    this.cooldown = const Duration(minutes: 30),
    this.rssGrowthWarnBytes = 256 * 1024 * 1024,
    this.imageCacheWarnBytes = 24 * 1024 * 1024,
    int Function()? readRss,
    int Function()? readPeakRss,
    int Function()? readImageCacheBytes,
  }) : _readRss = readRss ?? _processRss,
       _readPeakRss = readPeakRss ?? _processPeakRss,
       _readImageCacheBytes = readImageCacheBytes ?? _imageCacheBytes;

  /// 检查间隔。
  final Duration interval;

  /// 两次日志之间的最小间隔（见文件头「必须去抖」）。
  final Duration cooldown;

  /// RSS 相对首个读数的增量告警线。
  final int rssGrowthWarnBytes;

  /// imageCache 告警线。
  final int imageCacheWarnBytes;

  final int Function() _readRss;
  final int Function() _readPeakRss;
  final int Function() _readImageCacheBytes;

  int? _baselineRss;
  int? _lastLoggedRss;
  int? _lastLoggedCache;
  DateTime? _lastLoggedAt;

  /// 最近一次记录的分解（测试断言用；null = 还没记过）。
  @visibleForTesting
  List<MemoryLedgerEntry>? lastLoggedGauges;

  /// 执行一次检查。返回是否**写了**一条日志（测试据此断言去抖）。
  ///
  /// [at] 只供测试固定时刻。
  bool tick({DateTime? at}) {
    final now = at ?? DateTime.now();

    final int rss;
    final int peak;
    final int cache;
    try {
      rss = _readRss();
      peak = _readPeakRss();
      cache = _readImageCacheBytes();
    } on Object catch (e) {
      // 读数在个别嵌入形态下不可用。观测失败不该影响任何业务路径，但也不能
      // 完全静默——留一条 debug（默认被 minLevel 过滤，不冲环形缓冲）。
      SpbLog.debug('内存高水位检查读数失败', {'error': '$e'});
      return false;
    }

    final baseline = _baselineRss ??= rss;
    final growth = rss - baseline;
    final gauges = MemoryLedger.snapshot();
    final overWarn = gauges.where((g) => g.overWarn).toList(growable: false);

    final triggered =
        cache >= imageCacheWarnBytes ||
        growth >= rssGrowthWarnBytes ||
        overWarn.isNotEmpty;
    if (!triggered) return false;

    final lastAt = _lastLoggedAt;
    if (lastAt != null && now.difference(lastAt) < cooldown) return false;

    // 无显著变化不写：同样的数字写第二遍没有信息量，只会挤掉环形缓冲。
    final lastRss = _lastLoggedRss;
    if (lastRss != null && rss * 10 < lastRss * 11) {
      final lastCache = _lastLoggedCache ?? 0;
      if (cache * 10 < lastCache * 12) return false;
    }

    _lastLoggedAt = now;
    _lastLoggedRss = rss;
    _lastLoggedCache = cache;
    lastLoggedGauges = gauges;

    SpbLog.warn('内存高水位', {
      'rss_mb': _mb(rss),
      'peak_mb': _mb(peak),
      'since_start_mb': _mb(growth),
      'image_cache_mb': _mb(cache),
      // 分解只放**有实际占用**的项（0 项的条目没有诊断价值），
      // 越线项单独标注 `!`，避免读者逐项比阈值。
      'breakdown': gauges
          .where((g) => g.count > 0 || g.bytes > 0)
          .map((g) {
            final token = g.warnToken;
            return g.overWarn ? '!$token' : token;
          })
          .join(' | '),
    });
    return true;
  }
}

int _processRss() => ProcessInfo.currentRss;

int _processPeakRss() => ProcessInfo.maxRss;

int _imageCacheBytes() => imageCache.currentSizeBytes;

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

MemoryWatchdog? _installed;

/// 已安装的高水位看门狗（测试用）。
MemoryWatchdog? get installedMemoryWatchdog => _installed;

Timer? _installedTimer;

/// 安装内存高水位日志（幂等：重复调用返回同一个实例）。
///
/// 与 [installMemoryProbe] 同一取向：默认开、无编译期开关——它每 [interval]
/// 读几个整数，且只在越线时写日志，成本可忽略；换来的却是「用户没导出报告
/// 时也能留下高水位证据」。
MemoryWatchdog installMemoryWatchdog({MemoryWatchdog? watchdog}) {
  final existing = _installed;
  if (existing != null) return existing;

  final created = watchdog ?? MemoryWatchdog();
  _installed = created;
  // 首个 tick 只建立基线（不写日志）：此时 growth 恒为 0，写出来是噪音。
  created.tick();
  _installedTimer = Timer.periodic(created.interval, (_) => created.tick());
  return created;
}

/// 卸载看门狗（仅测试用；生产是进程级定时器，退出即结束）。
@visibleForTesting
void uninstallMemoryWatchdog() {
  _installedTimer?.cancel();
  _installedTimer = null;
  _installed = null;
}
