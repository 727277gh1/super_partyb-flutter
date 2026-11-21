import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 内存高水位日志（`MemoryWatchdog`）的触发与去抖语义。
///
/// ## 这个测试防的是什么
///
/// 看门狗写的是 `warn`，直进 500 条诊断环形缓冲。写错的方向都很安静：
///
/// - 阈值判定错 → 永远不报警，或每 5 分钟报一条把环形缓冲冲干净
///   （后者正是 `MemoryProbe` 刻意不写日志的原因，见其文件头）；
/// - 分解行漏项 → 报告里看不出「谁占的」，观测等于白做；
/// - 读数抛错没兜住 → 定时器把异常抛进 Zone，可能被全局错误兜底记成崩溃。
void main() {
  const mb = 1024 * 1024;

  setUp(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
    SpbLog.clearRecentLogs();
    MemoryLedger.reset();
  });

  tearDown(() {
    MemoryLedger.reset();
    SpbLog.clearRecentLogs();
    uninstallMemoryWatchdog();
  });

  List<LogRecord> highWaterLogs() =>
      SpbLog.recentLogs.where((r) => r.message == '内存高水位').toList();

  test('低于三条线时什么都不写（含首个 tick 只建立基线）', () {
    final watchdog = MemoryWatchdog(
      readRss: () => 100 * mb,
      readPeakRss: () => 100 * mb,
      readImageCacheBytes: () => 1 * mb,
    );

    expect(watchdog.tick(at: DateTime(2026)), isFalse);
    expect(watchdog.tick(at: DateTime(2026, 1, 1, 0, 5)), isFalse);
    expect(highWaterLogs(), isEmpty);
  });

  test('imageCache 越过告警线 → 写一条含分解的日志', () {
    MemoryLedger.register(
      name: 'conversation.timeline',
      label: '对话页时间线',
      read: () => const MemoryGauge(count: 1200, bytes: 3 * 1024 * 1024),
    );
    final watchdog = MemoryWatchdog(
      readRss: () => 200 * mb,
      readPeakRss: () => 240 * mb,
      readImageCacheBytes: () => 25 * mb,
    );

    final at = DateTime(2026, 3, 1, 12);
    expect(watchdog.tick(at: at), isTrue);

    final record = highWaterLogs().single;
    expect(record.level, LogLevel.warn);
    expect(record.fields['image_cache_mb'], '25.0');
    expect(record.fields['rss_mb'], '200.0');
    expect(record.fields['peak_mb'], '240.0');
    expect(
      record.fields['breakdown'],
      contains('对话页时间线=1200/3.0MB'),
      reason: '只剩曲线没有分解，等于「涨到多少」回答了、「花在谁身上」没回答',
    );
  });

  test('RSS 相对首个读数的增量超过线才报（RSS 不回落，故不看绝对值）', () {
    var rss = 300 * mb;
    final watchdog = MemoryWatchdog(
      readRss: () => rss,
      readPeakRss: () => rss,
      readImageCacheBytes: () => 0,
    );

    expect(watchdog.tick(at: DateTime(2026)), isFalse, reason: '首 tick 只建基线');
    rss += 100 * mb;
    expect(
      watchdog.tick(at: DateTime(2026, 1, 1, 0, 5)),
      isFalse,
      reason: '增量 100MB 未越线',
    );
    rss += 200 * mb;
    expect(watchdog.tick(at: DateTime(2026, 1, 1, 0, 10)), isTrue);
    expect(highWaterLogs().single.fields['since_start_mb'], '300.0');
  });

  test('账本条目越线也能触发，并给越线项加 `!` 标记', () {
    MemoryLedger.register(
      name: 'conversation.thumbnails',
      label: '对话页缩略图',
      read: () => const MemoryGauge(count: 600, bytes: 10 * 1024 * 1024),
      warnCount: 512,
    );
    final watchdog = MemoryWatchdog(
      readRss: () => 100 * mb,
      readPeakRss: () => 100 * mb,
      readImageCacheBytes: () => 1 * mb,
    );

    expect(watchdog.tick(at: DateTime(2026)), isTrue);
    final breakdown = highWaterLogs().single.fields['breakdown'] as String;
    expect(breakdown, startsWith('!'));
    expect(breakdown, contains('对话页缩略图=600/10.0MB'));
    expect(watchdog.lastLoggedGauges?.single.name, 'conversation.thumbnails');
  });

  test('冷却期内不重复写；冷却后无显著增长也不写', () {
    var rss = 100 * mb;
    var cache = 30 * mb;
    final watchdog = MemoryWatchdog(
      readRss: () => rss,
      readPeakRss: () => rss,
      readImageCacheBytes: () => cache,
    );

    final t0 = DateTime(2026, 5, 1, 9);
    expect(watchdog.tick(at: t0), isTrue, reason: 'imageCache 已超线');

    expect(
      watchdog.tick(at: t0.add(const Duration(minutes: 10))),
      isFalse,
      reason: '冷却期（30 分钟）内不写',
    );

    // 冷却已过，但数字没变：写第二遍没有信息量，只会挤掉环形缓冲。
    expect(
      watchdog.tick(at: t0.add(const Duration(minutes: 40))),
      isFalse,
      reason: '无显著变化不写',
    );

    // 冷却已过 + 显著增长：才写第二条。
    rss *= 2;
    cache = 31 * mb;
    expect(watchdog.tick(at: t0.add(const Duration(minutes: 80))), isTrue);
    expect(highWaterLogs().length, 2);
  });

  test('读数抛错：不抛给调用方，只留 debug 痕迹', () {
    final watchdog = MemoryWatchdog(
      readRss: () => throw StateError('no rss'),
      readPeakRss: () => 0,
      readImageCacheBytes: () => 0,
    );

    expect(watchdog.tick(at: DateTime(2026)), isFalse);
    expect(highWaterLogs(), isEmpty);
    expect(SpbLog.recentLogs.any((r) => r.message == '内存高水位检查读数失败'), isTrue);
  });

  test('installMemoryWatchdog 幂等，uninstall 后复位', () {
    MemoryWatchdog quiet() => MemoryWatchdog(
      readRss: () => 100 * mb,
      readPeakRss: () => 100 * mb,
      readImageCacheBytes: () => 0,
    );

    final first = installMemoryWatchdog(watchdog: quiet());
    final second = installMemoryWatchdog(watchdog: quiet());
    expect(identical(first, second), isTrue, reason: '重复安装必须返回同一实例');
    expect(installedMemoryWatchdog, same(first));

    uninstallMemoryWatchdog();
    expect(installedMemoryWatchdog, isNull);
  });
}
