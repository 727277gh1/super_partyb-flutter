import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

/// 造一帧 timings：只有 raster 时长被本模块消费（见 counter 的 noteTimings）。
FrameTiming _timing({required int rasterUs}) {
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: 0,
    rasterStart: 0,
    rasterFinish: rasterUs,
    rasterFinishWallTime: rasterUs,
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
      expect(a.toReportFragment(), 'fps=0.1 raster=5.0ms');

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
