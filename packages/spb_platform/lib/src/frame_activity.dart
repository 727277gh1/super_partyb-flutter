/// 渲染帧计数：把「引擎是不是一直在出帧」变成诊断报告里的一行读数。
///
/// ## 它解决什么
///
/// 2026-11 真机报障的第二份报告里，RSS 470MB 平台期 + `peak 897MB` 与
/// **同步、图片、登录页全部无关**（在途字节 0、`imageCache` 0 张、无 401），
/// 而用户同时报「CPU 也一直很高」。这两条线索指向同一件事，但报告里**没有
/// 任何渲染维度的读数**：
///
/// - CPU 高 + 内存高，可能是**引擎每帧都在跑完整管线**（常驻的
///   indeterminate 进度动画、每帧重建的子树）；
/// - 也可能是**光栅化退回了软件实现**（`Microsoft Basic Render Driver`，
///   无独显 / 远程桌面 / 驱动被禁）——那样 Skia surface 在系统内存里，
///   光栅化全落 CPU，正好同时解释内存与 CPU。
///
/// 这两条要靠两个数字分开：**每秒帧数**（是否在画）与**平均光栅耗时**
/// （画得贵不贵）。本模块只负责采集，落进 [MemoryProbe] 的采样行里。
///
/// ## 为什么不用 `FrameTiming` 数帧
///
/// [FrameTiming] 只在引擎回传 timings 时才有（部分平台/构建不提供），若用它
/// 计数，「没有 timings」会被误读成「没有出帧」——把两个完全不同的结论混成
/// 一个。故帧数用 `addPostFrameCallback` 自续排计数（**必定**每帧触发），
/// 光栅耗时才用 timings，且拿不到时报告里就不写这一项（缺席 ≠ 0ms）。
///
/// ## 为什么成本可忽略
///
/// 每帧一次 `int++`（连日志都不写，只在导出报告时被读走）；timings 回调
/// 累加两个整数。对比 [installFrameTimingReporter]（默认关闭、会累积
/// `List<FrameTiming>`），本模块常开无压力。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:spb_core/spb_core.dart';

/// 一个统计窗口内的渲染活动（纯数据，可在无引擎环境构造）。
@immutable
class FrameActivity {
  const FrameActivity({
    required this.frames,
    required this.window,
    this.avgRasterUs,
  });

  /// 窗口内引擎实际出的帧数（`addPostFrameCallback` 计数）。
  final int frames;

  /// 窗口时长（两次采样之间的真实间隔）。
  final Duration window;

  /// 窗口内平均光栅耗时；null = 引擎没回传 timings（**不是 0ms**）。
  final int? avgRasterUs;

  /// 每秒帧数（窗口时长未知时按 0 处理，避免出现 (int)/0）。
  double get fps {
    final us = window.inMicroseconds;
    if (us <= 0) return 0;
    return frames * 1000000 / us;
  }

  /// 报告里的片段：`fps=59.6 raster=7.3ms`。
  ///
  /// 帧数保留一位小数：1 分钟窗口里 3576 帧 = 59.6fps，四舍五入成整数会把
  /// 「60 帧满速」与「50 帧掉帧」显示成同一个值。
  String toReportFragment() {
    final raster = avgRasterUs;
    final base = 'fps=${fps.toStringAsFixed(1)}';
    if (raster == null) return base;
    return '$base raster=${(raster / 1000).toStringAsFixed(1)}ms';
  }

  @override
  String toString() =>
      'FrameActivity(frames: $frames, window: ${window.inMilliseconds}ms, '
      'avgRaster: ${avgRasterUs == null ? 'n/a' : '${avgRasterUs! ~/ 1000}ms'})';
}

/// 帧活动计数器（累积 + 取窗口快照）。
///
/// ## 为什么不是纯静态
///
/// 窗口状态（上次取数时刻、累积值）必须有归属：静态计数器在测试之间会串味，
/// 也无法断言「取走一次后清零」。
class FrameActivityCounter {
  FrameActivityCounter({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  int _frames = 0;
  int _rasterSumUs = 0;
  int _rasterFrames = 0;
  DateTime? _windowStart;

  /// 引擎出了一帧（`addPostFrameCallback` 回调里调）。
  void noteFrame() {
    _frames++;
    _windowStart ??= _now();
  }

  /// 引擎回传一批帧耗时（`addTimingsCallback` 回调里调）。
  ///
  /// 只累加光栅耗时：build 耗时已在 `FrameTimingReporter` 那条通道上，
  /// 这里要回答的是「光栅是否在 CPU 上」。
  void noteTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _rasterSumUs += t.rasterDuration.inMicroseconds;
    }
    _rasterFrames += timings.length;
  }

  /// 取走本窗口的活动并清零（下一次调用重新计窗口）。
  FrameActivity take() {
    final now = _now();
    final start = _windowStart ?? now;
    final activity = FrameActivity(
      frames: _frames,
      window: now.difference(start),
      // 一帧 timings 都没收到 → 这一项不可用，而不是「0ms」。
      avgRasterUs: _rasterFrames == 0 ? null : _rasterSumUs ~/ _rasterFrames,
    );
    _windowStart = now;
    _frames = 0;
    _rasterSumUs = 0;
    _rasterFrames = 0;
    return activity;
  }
}

FrameActivityCounter? _installed;

/// 已安装的计数器（测试用）。
FrameActivityCounter? get installedFrameActivityCounter => _installed;

/// 把计数器接到引擎上（幂等：重复调用只接一次）。
///
/// ## 两条回调各自的作用
///
/// - `addPostFrameCallback`：数帧。自续排（回调里再注册自己）是标准的「观察
///   每一帧」写法，**不会**因此多画一帧——它不请求帧，只等下一帧。
/// - `addTimingsCallback`：拿光栅耗时。拿不到时 [FrameActivity.avgRasterUs]
///   为 null，报告里就不写 `raster=`。
///
/// ## 绑定未初始化时
///
/// `SchedulerBinding.instance` 在未 `ensureInitialized` 的进程里会断言失败。
/// 生产上两端 `main()` 都在绑定之后调用本函数；测试里可能没有绑定，故这里
/// **降级为「不接线」并留一条 debug 痕迹**，而不是让诊断功能把启动打断。
FrameActivityCounter installFrameActivityCounter({
  FrameActivityCounter? counter,
}) {
  final existing = _installed;
  if (existing != null) return existing;

  final created = counter ?? FrameActivityCounter();
  _installed = created;

  final SchedulerBinding binding;
  try {
    binding = SchedulerBinding.instance;
  } on Object catch (e) {
    // 没有绑定 = 没有帧可言（纯 Dart 单测、无引擎嵌入）。采样行里就不会有
    // `fps=`，读者据此知道「这一维没有采集」，而不是「一帧都没画」。
    SpbLog.debug('帧活动计数未接线（绑定未初始化）', {'error': '$e'});
    return created;
  }

  void onFrame(Duration _) {
    created.noteFrame();
    binding.addPostFrameCallback(onFrame);
  }

  binding.addPostFrameCallback(onFrame);
  binding.addTimingsCallback(created.noteTimings);
  return created;
}

/// 卸载（仅测试用；生产是进程级监听，退出即结束）。
@visibleForTesting
void uninstallFrameActivityCounter() {
  _installed = null;
}
