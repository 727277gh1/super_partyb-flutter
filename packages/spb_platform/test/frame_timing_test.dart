import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 构造一个指定各阶段耗时的 [FrameTiming]。
///
/// `FrameTiming` 的构造器只收原始时间戳（微秒），各阶段的时长是**派生**的：
///
/// ```
/// buildDuration = buildFinish  - buildStart
/// rasterDuration= rasterFinish - rasterStart
/// vsyncOverhead = buildStart   - vsyncStart      ← 「等 vsync / 调度」的空档
/// totalSpan     = rasterFinish - vsyncStart
/// ```
///
/// 故要让「total 超阈值而 build/raster 都不超」，只能靠 [vsyncGapUs]
/// （那正是 totalSpan 存在的原因：它把 vsync 调度开销也算进来）。
FrameTiming frameWith({
  required int buildUs,
  required int rasterUs,
  int vsyncGapUs = 0,
}) {
  final buildStart = vsyncGapUs;
  final buildFinish = buildStart + buildUs;
  final rasterStart = buildFinish;
  final rasterFinish = rasterStart + rasterUs;
  return FrameTiming(
    vsyncStart: 0,
    buildStart: buildStart,
    buildFinish: buildFinish,
    rasterStart: rasterStart,
    rasterFinish: rasterFinish,
    rasterFinishWallTime: rasterFinish,
  );
}

const _limit = Duration(milliseconds: 16);

void main() {
  // `installFrameTimingReporter` 要读 `SchedulerBinding.instance`（注册引擎的
  // 帧回调），故必须先初始化绑定。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('summarizeTimings', () {
    test('空列表返回空摘要（不崩、不除零）', () {
      final s = summarizeTimings([], slowFrameThreshold: _limit);

      expect(s.isEmpty, isTrue);
      expect(s.count, 0);
      expect(s.slowCount, 0);
      // 平均值走 `~/ count`，count 为 0 时必须提前返回，否则是除零。
      expect(s.avgBuildUs, 0);
      expect(s.avgRasterUs, 0);
    });

    test('恰好等于阈值的帧**不**算慢帧', () {
      // 判据是 `>` 而非 `>=`：正好用完预算仍是达标帧。
      final s = summarizeTimings([
        frameWith(buildUs: 16000, rasterUs: 0),
      ], slowFrameThreshold: _limit);

      expect(s.count, 1);
      expect(s.slowCount, 0, reason: '等于预算不该判成慢帧');
      expect(s.maxBuildUs, 16000);
    });

    test('超过阈值的帧计入 slowCount（build 单独超也算）', () {
      final s = summarizeTimings([
        frameWith(buildUs: 16001, rasterUs: 0),
      ], slowFrameThreshold: _limit);

      expect(s.slowCount, 1);
    });

    test('raster 单独超阈值也算慢帧（不能只看 build）', () {
      // 这一条钉住「三者取并集」的判据：Dart 侧很快、GPU 侧拖到 40ms 时，
      // 若只看 buildDuration 就会漏掉一个用户真能感知的卡顿。
      final s = summarizeTimings([
        frameWith(buildUs: 1000, rasterUs: 40000),
      ], slowFrameThreshold: _limit);

      expect(s.slowCount, 1);
      expect(s.maxRasterUs, 40000);
      expect(s.maxBuildUs, 1000);
    });

    test('totalSpan 单独超阈值也算慢帧', () {
      // build 与 raster 都在预算内，但 vsync 空档让端到端超了。
      final s = summarizeTimings([
        frameWith(buildUs: 1000, rasterUs: 1000, vsyncGapUs: 48000),
      ], slowFrameThreshold: _limit);

      expect(s.maxBuildUs, 1000);
      expect(s.maxRasterUs, 1000);
      expect(s.maxTotalSpanUs, 50000);
      expect(s.slowCount, 1);
    });

    test('max 取各帧最大值，avg 取算术平均', () {
      final s = summarizeTimings([
        frameWith(buildUs: 1000, rasterUs: 2000),
        frameWith(buildUs: 9000, rasterUs: 1000),
        frameWith(buildUs: 5000, rasterUs: 7000),
      ], slowFrameThreshold: const Duration(milliseconds: 100));

      expect(s.count, 3);
      expect(s.maxBuildUs, 9000);
      expect(s.maxRasterUs, 7000);
      expect(s.avgBuildUs, (1000 + 9000 + 5000) ~/ 3);
      expect(s.avgRasterUs, (2000 + 1000 + 7000) ~/ 3);
      // 阈值放到 100ms，三帧都不算慢。
      expect(s.slowCount, 0);
    });

    test('单帧输入：count=1，avg 等于该帧', () {
      final s = summarizeTimings([
        frameWith(buildUs: 3000, rasterUs: 4000),
      ], slowFrameThreshold: const Duration(milliseconds: 100));

      expect(s.count, 1);
      expect(s.avgBuildUs, 3000);
      expect(s.avgRasterUs, 4000);
    });

    test('混合批次：只有超阈值的那些计入 slowCount', () {
      final s = summarizeTimings([
        frameWith(buildUs: 5000, rasterUs: 5000),
        frameWith(buildUs: 20000, rasterUs: 5000),
        frameWith(buildUs: 5000, rasterUs: 5000),
        frameWith(buildUs: 5000, rasterUs: 25000),
      ], slowFrameThreshold: _limit);

      expect(s.count, 4);
      expect(s.slowCount, 2);
    });

    test('toLogFields 把微秒换算成毫秒（保留一位小数）', () {
      // 阈值放到 100ms：本用例只验证换算，不该被 slowCount 干扰
      // （build 12345 + raster 6789 的 totalSpan 会超过上面的 16ms）。
      final s = summarizeTimings([
        frameWith(buildUs: 12345, rasterUs: 6789),
      ], slowFrameThreshold: const Duration(milliseconds: 100));

      final fields = s.toLogFields();
      expect(fields['frames'], 1);
      expect(fields['slow_frames'], 0);
      expect(fields['max_build_ms'], 12.3);
      expect(fields['max_raster_ms'], 6.8);
      // 键名沿用 spb_core 的 slog 约定（小写下划线），便于与服务端日志串联。
      expect(fields.keys, contains('max_total_ms'));
    });
  });

  group('FrameTimingReporter', () {
    /// 把 SpbLog 换成捕获 sink，返回捕获列表；tearDown 自动还原。
    List<LogRecord> captureLogs() {
      final records = <LogRecord>[];
      final old = SpbLog.configure(
        sink: _CaptureSink(records),
        minLevel: LogLevel.debug,
      );
      addTearDown(() {
        SpbLog.configure(sink: old);
        SpbLog.clearRecentLogs();
      });
      return records;
    }

    test('累积满 batchSize 帧后落一条日志并清空', () {
      captureLogs();
      final reporter = FrameTimingReporter(
        batchSize: 3,
        flushInterval: const Duration(hours: 1), // 不让计时器抢先触发
        captureSummaries: true,
      );
      addTearDown(reporter.dispose);

      reporter.addTimings([frameWith(buildUs: 1000, rasterUs: 1000)]);
      expect(reporter.pendingCount, 1);
      expect(reporter.reported, isEmpty, reason: '未满批次不该上报');

      reporter.addTimings([
        frameWith(buildUs: 1000, rasterUs: 1000),
        frameWith(buildUs: 1000, rasterUs: 1000),
      ]);

      expect(reporter.reported, hasLength(1));
      expect(reporter.reported.single.count, 3);
      expect(reporter.pendingCount, 0, reason: '上报后必须清空，否则下批会重复统计');
    });

    test('慢帧批次用 warn 级，全绿批次用 info 级', () {
      final records = captureLogs();

      final slow = FrameTimingReporter(batchSize: 1);
      addTearDown(slow.dispose);
      slow.addTimings([frameWith(buildUs: 50000, rasterUs: 1000)]);

      final fast = FrameTimingReporter(batchSize: 1);
      addTearDown(fast.dispose);
      fast.addTimings([frameWith(buildUs: 1000, rasterUs: 1000)]);

      expect(
        records.where((r) => r.level == LogLevel.warn).map((r) => r.message),
        contains('检测到慢帧'),
      );
      expect(
        records.where((r) => r.level == LogLevel.info).map((r) => r.message),
        contains('帧耗时正常'),
      );
    });

    test('空批次 flush 不落日志', () {
      final records = captureLogs();
      final reporter = FrameTimingReporter(
        batchSize: 120,
        captureSummaries: true,
      );
      addTearDown(reporter.dispose);

      reporter.flush();

      expect(records, isEmpty);
      expect(reporter.reported, isEmpty);
    });

    test('空 timings 输入被忽略（不改 pending）', () {
      captureLogs();
      final reporter = FrameTimingReporter(batchSize: 2);
      addTearDown(reporter.dispose);

      reporter.addTimings(const []);

      expect(reporter.pendingCount, 0);
    });

    test('install 幂等：重复安装返回同一个上报器（不重复统计）', () {
      captureLogs();
      final first = installFrameTimingReporter();
      addTearDown(uninstallFrameTimingReporter);

      final second = installFrameTimingReporter();

      expect(identical(first, second), isTrue, reason: '重复注册会让同一帧被统计两次');
    });
  });
}

/// 记录日志的 sink（测试用）。
class _CaptureSink implements LogSink {
  _CaptureSink(this.records);

  final List<LogRecord> records;

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    records.add(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        fields: fields,
      ),
    );
  }
}
