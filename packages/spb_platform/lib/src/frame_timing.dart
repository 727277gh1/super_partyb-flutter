/// 帧耗时观测：把超阈值的帧汇总进 [SpbLog]（供「导出诊断日志」取用）。
///
/// ## 它解决什么问题
///
/// 「界面卡」是本项目最常见的用户报障，但客户端此前**没有任何帧耗时信号**
/// ——用户只能说「很卡」，诊断报告里也只有普通日志。而本机（以及 CI）无
/// `DISPLAY`、无真机（AGENTS.md §9），开发者也无法自己看帧率。
///
/// 这个模块提供一个**可选**的观测通道：开启后按批次汇总
/// [FrameTiming.buildDuration] / [FrameTiming.rasterDuration] /
/// [FrameTiming.totalSpan]，超阈值的帧计数非零时用 `warn` 落一条日志，
/// 于是用户导出的报告里就有了「哪一类帧慢、慢多少」。
///
/// ## 为什么默认**关闭**（编译期开关）
///
/// [SchedulerBinding.addTimingsCallback] 会让引擎**每帧**回传耗时数据，并在
/// 本进程内累积一个 `List<FrameTiming>`。这本身不是免费操作，而它换来的信息
/// 只在排障时需要。故与 [SpbEnv.verboseLogging] 同一取向：编译期开关
/// （`--dart-define=SPB_FRAME_TIMING=true`），默认关闭，关闭时**不注册回调**。
///
/// ## 为什么是「按批次汇总」而不是「每帧一条日志」
///
/// 60fps 下每帧一条 = 每秒 60 条日志，会把 [SpbLog] 的 500 条环形缓冲
/// （`recentLogCapacity`）在 8 秒内冲干净——而诊断报告要的恰恰是**出事前后**
/// 的上下文。故累积到 [FrameTimingReporter.batchSize] 帧或
/// [FrameTimingReporter.flushInterval] 后**一次性**落一条，且
/// `slowCount == 0` 时用 `info`（一屏「一切正常」不该看起来像告警）。
///
/// ## 为什么汇总逻辑是纯函数
///
/// [summarizeTimings] 不读 [SpbLog]、不碰任何全局状态，故可在无引擎环境逐条
/// 断言（本包与 `spb_core` 的既有取向：正确性核心必须能无头单测）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:spb_core/spb_core.dart';

/// 一帧的耗时摘要（纯数据，无 Flutter 之外的依赖）。
///
/// 单位统一为微秒（与 [FrameTiming] 的原始数据一致），展示时由调用方换算。
@immutable
class FrameTimingSummary {
  const FrameTimingSummary({
    required this.count,
    required this.slowCount,
    required this.maxBuildUs,
    required this.maxRasterUs,
    required this.maxTotalSpanUs,
    required this.avgBuildUs,
    required this.avgRasterUs,
  });

  /// 本批次统计了多少帧。
  final int count;

  /// 其中有多少帧被判为「慢帧」（判据见 [summarizeTimings]）。
  final int slowCount;

  final int maxBuildUs;
  final int maxRasterUs;
  final int maxTotalSpanUs;
  final int avgBuildUs;
  final int avgRasterUs;

  /// 空批次（`count == 0`）。
  static const FrameTimingSummary empty = FrameTimingSummary(
    count: 0,
    slowCount: 0,
    maxBuildUs: 0,
    maxRasterUs: 0,
    maxTotalSpanUs: 0,
    avgBuildUs: 0,
    avgRasterUs: 0,
  );

  bool get isEmpty => count == 0;

  /// 落日志用的字段（键名沿用 `spb_core` 的 slog 约定：小写下划线）。
  Map<String, Object?> toLogFields() => {
    'frames': count,
    'slow_frames': slowCount,
    'max_build_ms': _ms(maxBuildUs),
    'max_raster_ms': _ms(maxRasterUs),
    'max_total_ms': _ms(maxTotalSpanUs),
    'avg_build_ms': _ms(avgBuildUs),
    'avg_raster_ms': _ms(avgRasterUs),
  };

  /// 微秒 → 毫秒（保留一位小数）。日志里带原始微秒会难以阅读。
  static double _ms(int us) => (us / 100).round() / 10;

  @override
  String toString() =>
      'FrameTimingSummary(count: $count, slow: $slowCount, '
      'maxBuild: ${_ms(maxBuildUs)}ms, maxRaster: ${_ms(maxRasterUs)}ms)';
}

/// 汇总一批 [FrameTiming]。
///
/// ## 慢帧判据
///
/// 一帧被判为慢，当且仅当**任一**阶段超过 [slowFrameThreshold]：
///
/// | 阶段 | 超阈值意味着 |
/// |---|---|
/// | [FrameTiming.buildDuration] | Dart 侧（build/layout/paint）来不及——正是本仓库能优化的部分 |
/// | [FrameTiming.rasterDuration] | GPU 侧光栅化来不及（大量阴影/裁剪/图片缩放） |
/// | [FrameTiming.totalSpan] | 端到端超过一帧预算（含 vsync 调度开销） |
///
/// 三者取**并集**而非只看 build：只看 build 会漏掉「Dart 侧很快、但光栅化
/// 拖到 50ms」这类卡顿（大量 `Image` 或模糊效果时常见）。
///
/// ## 为什么判据是 `>` 而不是 `>=`
///
/// 阈值语义是「超过预算才算慢」。恰好等于阈值意味着**正好**用完预算，
/// 仍是达标帧。这条有专门用例钉住，避免把「60fps 的 16.7ms 边界」判成慢。
FrameTimingSummary summarizeTimings(
  List<FrameTiming> timings, {
  required Duration slowFrameThreshold,
}) {
  if (timings.isEmpty) return FrameTimingSummary.empty;

  var slowCount = 0;
  var maxBuild = 0;
  var maxRaster = 0;
  var maxTotal = 0;
  var sumBuild = 0;
  var sumRaster = 0;

  for (final t in timings) {
    final build = t.buildDuration.inMicroseconds;
    final raster = t.rasterDuration.inMicroseconds;
    final total = t.totalSpan.inMicroseconds;

    if (build > maxBuild) maxBuild = build;
    if (raster > maxRaster) maxRaster = raster;
    if (total > maxTotal) maxTotal = total;
    sumBuild += build;
    sumRaster += raster;

    final limit = slowFrameThreshold.inMicroseconds;
    if (build > limit || raster > limit || total > limit) slowCount++;
  }

  final count = timings.length;
  return FrameTimingSummary(
    count: count,
    slowCount: slowCount,
    maxBuildUs: maxBuild,
    maxRasterUs: maxRaster,
    maxTotalSpanUs: maxTotal,
    avgBuildUs: sumBuild ~/ count,
    avgRasterUs: sumRaster ~/ count,
  );
}

/// 帧耗时上报器（累积 + 按批次落日志）。
///
/// ## 为什么要有独立的类（而不是一个 `install` 函数）
///
/// 批次状态（累积的帧、挂起的计时器）必须有归属，否则：
/// - 无法在测试里断言「120 帧后落了 1 条日志」而不等待真实 5 秒；
/// - 无法在重复调用 `install` 时清理上一份状态。
///
/// 故 [installFrameTimingReporter] 只是「建一个、装到绑定上、记住它」的薄封装。
class FrameTimingReporter {
  FrameTimingReporter({
    this.slowFrameThreshold = const Duration(milliseconds: 32),
    this.batchSize = 120,
    this.flushInterval = const Duration(seconds: 5),
    this.captureSummaries = false,
  });

  /// 慢帧阈值。默认 **32ms** ≈ 30fps 的一帧预算。
  ///
  /// 不用 16.7ms（60fps 预算）：那会把「偶尔掉一帧」也算进来，日志里
  /// `slow_frames` 长期非零，用户与开发者都会开始忽略它。32ms 意味着
  /// 「明显掉到 30fps 以下」——那种卡顿是用户真能感知的。
  final Duration slowFrameThreshold;

  /// 累积到多少帧就落一条日志。
  final int batchSize;

  /// 或累积到多久就落一条（即使帧数不足 [batchSize]）。
  ///
  /// 两者取先到者：只有 [batchSize] 时，一次 10 秒的滚动卡顿若只有 30 帧
  /// （真卡的时候帧数本来就少）就永远凑不满，日志永远不落——而它恰恰是
  /// 最该被记录的场景。
  final Duration flushInterval;

  /// 是否记录 [reported]（测试用）。
  ///
  /// 默认 **false**：桌面端是常驻进程，每 [batchSize] 帧一条摘要，跑一天就是
  /// 几万条——而生产路径**不消费**它（信息已进 [SpbLog]）。默认开着就是一个
  /// 随运行时长线性增长的内存泄漏，且用户看不见。
  final bool captureSummaries;

  final List<FrameTiming> _pending = [];
  Timer? _flushTimer;

  /// 已上报的批次摘要（仅当 [captureSummaries] 为 true 时累积；测试用）。
  final List<FrameTimingSummary> reported = [];

  /// 累积中的帧数（测试用）。
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// 引擎每帧回调一次。
  void addTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    _pending.addAll(timings);
    if (_pending.length >= batchSize) {
      flush();
      return;
    }
    // 批次没满 → 起一个计时器兜底，避免「帧数少但一直有」时永不落日志。
    _flushTimer ??= Timer(flushInterval, flush);
  }

  /// 立即汇总并落一条日志，清空累积。
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty) return;

    final summary = summarizeTimings(
      _pending,
      slowFrameThreshold: slowFrameThreshold,
    );
    _pending.clear();
    if (captureSummaries) reported.add(summary);

    // slowCount > 0 用 warn：那是用户能感知的卡顿。全绿则用 info——否则
    // 环形缓冲里会堆满「一切正常」，反而挤掉真正的异常。
    if (summary.slowCount > 0) {
      SpbLog.warn('检测到慢帧', summary.toLogFields());
    } else {
      SpbLog.info('帧耗时正常', summary.toLogFields());
    }
  }

  /// 停止累积（不再落日志）。
  ///
  /// 生产路径不调用（进程退出即结束）；测试用它避免计时器泄漏。
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
  }
}

/// 当前已安装的上报器；null 表示未安装。
///
/// 用顶层变量而非「再装一次就再注册一个回调」：重复注册会让同一帧被统计
/// 两次（日志里 `frames` 翻倍），而调用方无法察觉。
FrameTimingReporter? _installed;

/// 安装帧耗时上报（幂等：重复调用不重复注册）。
///
/// ## 为什么要在 `SpbLog.configure` 之后调用
///
/// 上报器在帧回调里写 [SpbLog]。若在 `configure` 之前安装，首批日志会落到
/// 默认 sink（`ConsoleLogSink` + info 级）——功能上没问题，但「自定义 sink /
/// 更严格的级别」对首批日志不生效，行为不一致。两端 `main()` 都已在
/// `configure` 之后、`runApp` 之前调用。
///
/// ## 为什么返回上报器
///
/// 测试需要拿到它来断言 [FrameTimingReporter.reported] 并调 `dispose`；
/// 生产调用方忽略返回值即可。
FrameTimingReporter installFrameTimingReporter({
  Duration slowFrameThreshold = const Duration(milliseconds: 32),
}) {
  final existing = _installed;
  if (existing != null) return existing;

  final reporter = FrameTimingReporter(slowFrameThreshold: slowFrameThreshold);
  SchedulerBinding.instance.addTimingsCallback(reporter.addTimings);
  _installed = reporter;
  SpbLog.info('已启用帧耗时观测', {
    'slow_threshold_ms': slowFrameThreshold.inMilliseconds,
    'batch_size': reporter.batchSize,
  });
  return reporter;
}

/// 卸载上报器（仅测试用；生产是进程级监听，退出即结束）。
@visibleForTesting
void uninstallFrameTimingReporter() {
  final reporter = _installed;
  if (reporter == null) return;
  _installed = null;
  reporter.dispose();
  // 注意：不调 `removeTimingsCallback`。它需要与注册时**同一个**闭包引用，
  // 而 `addTimingsCallback` 收到的是 `reporter.addTimings`（tear-off 每次
  // 求值都是新实例），无法回收。故 `dispose` 只停掉累积与计时器——回调仍会
  // 被调用，但 `_pending` 已清空且不再起计时器，等价于空转。
  //
  // ⚠️ 这是有意的取舍：生产从不卸载，测试里每个用例装一次、用
  // `uninstallFrameTimingReporter` 复位即可。
}
