import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

/// 造一帧 timings：build 与 raster 时长都被 counter 消费（均值 + 最差值）。
///
/// `buildFinish − buildStart` 就是 build 耗时；`rasterFinish − rasterStart`
/// 是光栅耗时（`FrameTiming` 的两个 Duration 字段由这两个时刻相减得到）。
FrameTiming _timing({required int rasterUs, int buildUs = 0}) {
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: buildUs,
    rasterStart: buildUs,
    rasterFinish: buildUs + rasterUs,
    rasterFinishWallTime: buildUs + rasterUs,
  );
}

void main() {
  // `installFrameActivityCounter` 要读 `SchedulerBinding.instance`。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FrameActivityCounter', () {
    test('take 取走并清零，窗口起点重置', () {
      var t = DateTime(2026, 11, 7, 23, 12, 0);
      final counter = FrameActivityCounter(now: () => t);

      counter.noteFrame();
      counter.noteFrame();
      counter.noteTimings([_timing(rasterUs: 4000), _timing(rasterUs: 6000)]);
      t = t.add(const Duration(seconds: 30));

      final a = counter.take();
      expect(a.frames, 2);
      expect(a.window, const Duration(seconds: 30));
      expect(a.fps, closeTo(2 / 30, 1e-9));
      // 平均光栅 = (4000 + 6000) / 2。
      expect(a.avgRasterUs, 5000);
      expect(a.toReportFragment(), 'fps=0.1 max_build=0.0ms raster=5.0ms');

      // 第二个窗口从零开始；本窗口无 timings → raster 缺席而不是 0ms。
      counter.noteFrame();
      t = t.add(const Duration(seconds: 60));
      final b = counter.take();
      expect(b.frames, 1);
      expect(b.window, const Duration(seconds: 60));
      expect(b.avgRasterUs, isNull);
      expect(b.toReportFragment(), 'fps=0.0');
    });

    test('从未 noteFrame 就 take：窗口为 0，fps 不除零', () {
      final counter = FrameActivityCounter(now: () => DateTime(2026));
      final a = counter.take();
      expect(a.frames, 0);
      expect(a.window, Duration.zero);
      expect(a.fps, 0.0);
    });

    test('fps 保留一位小数：3576 帧 / 60s = 59.6', () {
      var t = DateTime(2026);
      final counter = FrameActivityCounter(now: () => t);
      for (var i = 0; i < 3576; i++) {
        counter.noteFrame();
      }
      t = t.add(const Duration(minutes: 1));
      expect(counter.take().fps.toStringAsFixed(1), '59.6');
    });

    test('最差 build/raster 取窗口内最大值，且报告片段带上它（issue #99 缺口 3）', () {
      var t = DateTime(2026, 11, 9, 14, 12, 0);
      final counter = FrameActivityCounter(now: () => t);
      counter.noteFrame();
      counter.noteTimings([
        _timing(buildUs: 4000, rasterUs: 2000),
        // 一帧卡了半秒：均值仍好看，但这一段是「单次卡顿」的证据。
        _timing(buildUs: 312000, rasterUs: 9000),
        _timing(buildUs: 8000, rasterUs: 3000),
      ]);
      t = t.add(const Duration(minutes: 1));

      final a = counter.take();
      expect(a.worstBuildUs, 312000);
      expect(a.worstRasterUs, 9000);
      expect(a.toReportFragment(), contains('max_build=312.0ms'));
      expect(a.avgRasterUs, (2000 + 9000 + 3000) ~/ 3, reason: '均值口径不变');
    });

    test('没有 timings 时最差值缺席（不是 0ms），取走后窗口重置', () {
      final counter = FrameActivityCounter(now: () => DateTime(2026));
      counter.noteFrame();
      final a = counter.take();
      expect(a.worstBuildUs, isNull);
      expect(a.worstRasterUs, isNull);
      expect(a.toReportFragment(), 'fps=0.0');

      counter.noteTimings([_timing(buildUs: 10000, rasterUs: 5000)]);
      expect(counter.take().worstBuildUs, 10000);
      // 上一窗口的最差值不能漏到下一窗口。
      expect(counter.take().worstBuildUs, isNull);
    });

    test('多帧 timings 累加后取均值', () {
      final counter = FrameActivityCounter(now: () => DateTime(2026));
      counter.noteTimings([
        _timing(rasterUs: 1000),
        _timing(rasterUs: 2000),
        _timing(rasterUs: 3000),
      ]);
      expect(counter.take().avgRasterUs, 2000);
    });
  });

  group('installFrameActivityCounter', () {
    setUp(uninstallFrameActivityCounter);
    tearDown(uninstallFrameActivityCounter);

    test('幂等：重复安装返回同一实例', () {
      final first = installFrameActivityCounter();
      expect(identical(installFrameActivityCounter(), first), isTrue);
    });

    test('卸载后复位（测试用）', () {
      installFrameActivityCounter();
      expect(installedFrameActivityCounter, isNotNull);
      uninstallFrameActivityCounter();
      expect(installedFrameActivityCounter, isNull);
    });

    test('post-frame 回调真的在计帧', () {
      final counter = installFrameActivityCounter();
      // 一帧都不画时计数不动：帧数来自回调，不是「最近一次采样」的副产物。
      expect(counter.take().frames, 0);

      SchedulerBinding.instance.scheduleFrame();
      // 让被调度的帧真的执行（测试绑定下 scheduleFrame 需要 pump）。
      SchedulerBinding.instance.handleBeginFrame(Duration.zero);
      SchedulerBinding.instance.handleDrawFrame();
      expect(counter.take().frames, greaterThan(0));
    });
  });
}
