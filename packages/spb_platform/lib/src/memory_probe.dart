/// 进程内存采样：把 RSS / 峰值 / imageCache 占用带进「导出诊断日志」
/// （docs/memory-audit.md §四「观测手段」）。
///
/// ## 它解决什么
///
/// `docs/memory-audit.md` 的全部内存结论都停在**结构事实**层面（「这个容器
/// 无界」），因为开发机无 `DISPLAY`、无真机（AGENTS.md §9），拿不到绝对
/// RSS 曲线——那一项一直挂在 既有问题。而内存问题的最终判据只能来自
/// **真实用户的机器**：哪台机器、跑了多久、涨到多少。
///
/// 本模块把这条通道补上，且不依赖 DevTools：
///
/// - [ProcessInfo.currentRss] —— 当前 RSS（`dart:io`，release 包里也可用，
///   不需要 VM service；Windows 由运行时经 `GetProcessMemoryInfo` 取得）；
/// - [ProcessInfo.maxRss] —— **进程启动以来的 RSS 高水位**。这一项尤其关键：
///   它不需要我们持续采样就能拿到「峰值」（G6/G7 那类瞬时峰值的判据），
///   也不会因为「GC 不缩堆 + ANGLE 保留」而低估（见下）；
/// - 全局 `imageCache` 的字节数 / 张数 / live 张数——解码位图是本客户端
///   最大的可再生态（`kImageCacheMaxBytes` = 32MB 上限）。
///
/// ## 为什么 RSS 会「涨上去不回落」，这不是泄漏
///
/// 两条外部事实（本仓库改不到，只作为读曲线时的判据）：
///
/// 1. Dart GC 的取舍是「堆看起来大小合适就不回收」，即便里面有大量可回收
///    垃圾；真正缩堆靠 `dart_notify_low_memory`，而它只在 **OS 发低内存警告**
///    时被 Flutter 调用——桌面端根本没有这条信号（见 [installMemoryPressureHandler]）；
/// 2. Windows 上 Skia/ANGLE 会为性能保留 GPU 侧数据，独显比核显稳定在更低
///    水位（flutter/flutter#179834 的结论）。
///
/// 故读 [MemorySample] 时看**峰值与斜率**，不要看「是否回落到基线」。
///
/// ## 为什么按分钟采样、且不写日志
///
/// 采样本身极便宜（6 个整数 + 一次 `imageCache` 取值），但**不能每条都写
/// [SpbLog]**：诊断报告只带最近 500 条日志，一条/分钟就是 8 小时冲干净
/// 环形缓冲——那正是「出事前后的上下文」被挤掉的经典原因（与
/// `FrameTimingReporter` 的批次汇总同一教训）。故采样只进本模块的有界环形
/// 缓冲，**仅在导出诊断报告时**作为独立小节呈现。
///
/// ## 为什么放 `spb_platform`
///
/// 它同时依赖 `dart:io`（RSS）与 `package:flutter/painting.dart`
/// （`imageCache`），纯 Dart 包放不了（AGENTS.md §4 分层）；
/// 与 [configureImageCache] / [installMemoryPressureHandler] 同一职责族
/// （平台侧观测与装配）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show imageCache;
import 'package:spb_core/spb_core.dart';

/// 一次内存采样的快照（纯数据，可在无引擎环境构造）。
@immutable
class MemorySample {
  const MemorySample({
    required this.at,
    required this.rssBytes,
    required this.peakRssBytes,
    required this.imageCacheBytes,
    required this.imageCacheEntries,
    required this.liveImages,
  });

  /// 采样时刻（报告里显示到秒）。
  final DateTime at;

  /// 采样瞬间的常驻集大小。
  final int rssBytes;

  /// 进程启动以来的 RSS 高水位（OS 计数，见 [ProcessInfo.maxRss]）。
  final int peakRssBytes;

  /// 全局 `imageCache` 当前占用的解码位图字节数。
  final int imageCacheBytes;

  /// 全局 `imageCache` 当前缓存的图片张数。
  final int imageCacheEntries;

  /// 仍有 listener 的图片张数（`clear()` 清不掉的那部分）。
  final int liveImages;

  /// 报告里的一行。
  ///
  /// 形如 `14:03:11 rss=182.4MB peak=240.9MB imageCache=12.1MB(4 张) live=1`。
  /// 只写时刻（不写日期）：同一份报告里的采样都在同一次运行内，日期是噪音。
  String toReportLine() {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ss = at.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss rss=${_mb(rssBytes)}MB peak=${_mb(peakRssBytes)}MB '
        'imageCache=${_mb(imageCacheBytes)}MB($imageCacheEntries 张) '
        'live=$liveImages';
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}

/// 有界的内存采样器。
///
/// ## 有界性（docs/memory-audit.md 的 A 类判据）
///
/// [capacity] 条采样为硬上限（默认 12 条 ≈ 12 分钟窗口），超出淘汰最旧——
/// 桌面端是常驻进程，无界采样就是一条随运行时长线性增长的泄漏。
///
/// ## 为什么可注入读数函数
///
/// 测试要断言「容量淘汰 / 峰值取最大 / 报告行格式」，而 `ProcessInfo` 与
/// 全局 `imageCache` 在纯 `dart test` 里拿不到（后者需要 `PaintingBinding`）。
/// 注入后这些语义可在无引擎环境逐条断言（与 `summarizeTimings` 同一取向）。
class MemoryProbe {
  MemoryProbe({
    this.capacity = 12,
    this.minInterval = const Duration(seconds: 30),
    int Function()? readRss,
    int Function()? readPeakRss,
    int Function()? readImageCacheBytes,
    int Function()? readImageCacheEntries,
    int Function()? readLiveImages,
  }) : _readRss = readRss ?? _processRss,
       _readPeakRss = readPeakRss ?? _processPeakRss,
       _readImageCacheBytes = readImageCacheBytes ?? _imageCacheBytes,
       _readImageCacheEntries = readImageCacheEntries ?? _imageCacheEntries,
       _readLiveImages = readLiveImages ?? _imageCacheLiveImages;

  /// 环形缓冲容量（硬上限）。
  final int capacity;

  /// 两次采样之间的最小间隔（[sample] 非强制调用时生效）。
  ///
  /// 存在的意义：`sample()` 会被「启动 / 内存压力 / 定时器」等多个点调用，
  /// 没有这个闸门时突发的一串调用会把 12 个槽位在毫秒内填满，曲线就退化成
  /// 一个时刻的 12 个重复值。导出报告时用 `force: true` 绕过它。
  final Duration minInterval;

  final int Function() _readRss;
  final int Function() _readPeakRss;
  final int Function() _readImageCacheBytes;
  final int Function() _readImageCacheEntries;
  final int Function() _readLiveImages;

  final Queue<MemorySample> _samples = Queue<MemorySample>();
  int _peakRssBytes = 0;
  DateTime? _lastSampleAt;

  /// 已采集的采样（最旧在前）。返回不可变副本，调用方无法改动内部状态。
  List<MemorySample> get samples => List<MemorySample>.unmodifiable(_samples);

  /// 观测到的 RSS 峰值（取「OS 高水位」与「已采样最大值」的较大者）。
  int get peakRssBytes => _peakRssBytes;

  /// 最近一次采样；null = 还没采过。
  MemorySample? get latest => _samples.isEmpty ? null : _samples.last;

  /// 采一次。
  ///
  /// [force] 为 true 时忽略 [minInterval]（导出报告那一刻要最新值）。
  /// [at] 只供测试固定时刻。
  ///
  /// 返回本次采样；被 [minInterval] 跳过或读数失败时返回 null。
  MemorySample? sample({bool force = false, DateTime? at}) {
    final now = at ?? DateTime.now();
    final last = _lastSampleAt;
    if (!force && last != null && now.difference(last) < minInterval) {
      return null;
    }

    final int rss;
    final int osPeak;
    final int cacheBytes;
    final int cacheEntries;
    final int live;
    try {
      rss = _readRss();
      osPeak = _readPeakRss();
      cacheBytes = _readImageCacheBytes();
      cacheEntries = _readImageCacheEntries();
      live = _readLiveImages();
    } on Object catch (e) {
      // 读数在个别平台/嵌入形态下不可用（如未初始化绑定、平台不实现 RSS）。
      // 采样是**诊断**，不值得为它抛异常打断启动或导出流程；留一条 debug
      // 痕迹即可（debug 默认被 minLevel 过滤，不会冲掉环形缓冲）。
      SpbLog.debug('内存采样失败', {'error': '$e'});
      return null;
    }

    final peak = rss > osPeak ? rss : osPeak;
    if (peak > _peakRssBytes) _peakRssBytes = peak;

    final sample = MemorySample(
      at: now,
      rssBytes: rss,
      peakRssBytes: _peakRssBytes,
      imageCacheBytes: cacheBytes,
      imageCacheEntries: cacheEntries,
      liveImages: live,
    );
    _samples.addLast(sample);
    _lastSampleAt = now;
    while (_samples.length > capacity) {
      _samples.removeFirst();
    }
    return sample;
  }

  /// 诊断报告的「内存采样」小节（逐行）。空表示还没采过——报告里整个小节
  /// 会被省略，而不是写一个空壳（同 `TimelineProbe` 的取向）。
  List<String> reportLines() =>
      _samples.map((s) => s.toReportLine()).toList(growable: false);
}

int _processRss() => ProcessInfo.currentRss;

int _processPeakRss() => ProcessInfo.maxRss;

int _imageCacheBytes() => imageCache.currentSizeBytes;

int _imageCacheEntries() => imageCache.currentSize;

int _imageCacheLiveImages() => imageCache.liveImageCount;

/// 当前已安装的采样器；null 表示未安装。
MemoryProbe? _installed;

/// 已安装的采样器（`exportDiagnosticsReport` 从这里取采样）。
MemoryProbe? get installedMemoryProbe => _installed;

/// 安装内存采样（幂等：重复调用返回同一个实例）。
///
/// ## 为什么默认开、且不需要编译期开关
///
/// `FrameTimingReporter` 是 `SPB_FRAME_TIMING` opt-in 的，因为它的回调**每帧**
/// 触发。本模块是每分钟一次、6 个整数、一个 12 槽环形缓冲——成本可忽略，而
/// 它换来的恰恰是「用户报障时报告里有没有内存数据」。默认关掉等于永远拿不到
/// 真实机器的曲线（既有问题 会一直挂着）。
///
/// ## 为什么在 `configureImageCache()` 之后调用
///
/// 首条采样就是**基线**（启动完成、缓存还是空的），它决定了后面读曲线时的
/// 参照点。放在缓存配置之前，基线里的 imageCache 值就没有意义。
///
/// 采样器不写 [SpbLog]（见文件头）；只有安装时落一条基线日志，因为
/// 「这次运行的起点是多少」本身就是报障要的第一条信息。
MemoryProbe installMemoryProbe({
  Duration interval = const Duration(minutes: 1),
  MemoryProbe? probe,
}) {
  final existing = _installed;
  if (existing != null) return existing;

  final created = probe ?? MemoryProbe();
  _installed = created;

  final first = created.sample(force: true);
  if (first != null) {
    SpbLog.info('内存基线', {
      'rss_mb': _mb(first.rssBytes),
      'peak_rss_mb': _mb(first.peakRssBytes),
      'image_cache_mb': _mb(first.imageCacheBytes),
    });
  }

  // 周期采样：只写环形缓冲，不落日志。进程退出即结束，故不保存 timer 的
  // 引用以外的东西；`uninstall` 只为测试复位。
  final timer = Timer.periodic(interval, (_) => created.sample());
  _installedTimer = timer;
  return created;
}

Timer? _installedTimer;

/// 卸载采样器（仅测试用；生产是进程级监听，退出即结束）。
@visibleForTesting
void uninstallMemoryProbe() {
  _installedTimer?.cancel();
  _installedTimer = null;
  _installed = null;
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
