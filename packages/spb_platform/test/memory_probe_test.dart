import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 进程内存采样（docs/memory-audit.md §四「观测手段」）。
///
/// ## 这个测试防的是什么
///
/// 本模块存在的唯一理由是「把真实机器上的内存数据带回报障流程」，而它的
/// 失败模式全都是**静默**的：
///
/// - **采样无界** → 桌面端常驻进程跑一天就是几万条，成为新的泄漏（与本轮
///   修复的 G1/G2/G3 同一个病）；
/// - **峰值只取「自己采到的最大」** → 漏掉两次采样之间的瞬时峰值，而那恰恰
///   是 G6/G7 那类「一次操作占多少」的判据（故必须并入 `ProcessInfo.maxRss`
///   这个 OS 高水位）；
/// - **读数失败时抛异常** → 内存诊断把一个本来正常的启动/导出流程打断；
/// - **报告里写空小节** → 读者以为采样挂了，而不是「还没来得及采」。
///
/// 故这里对容量、间隔闸门、峰值语义、失败降级与报告行格式逐条断言。
void main() {
  setUp(
    () => SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug),
  );
  tearDown(() {
    uninstallMemoryProbe();
    SpbLog.clearRecentLogs();
  });

  /// 构造一个读数可控的采样器。
  ///
  /// [rss] 是一个可变的当前值：用例可以在两次 `sample` 之间改它。
  ({MemoryProbe probe, void Function(int) setRss, void Function(int) setPeak})
  probeWith({
    int capacity = 12,
    Duration minInterval = Duration.zero,
    int initialRss = 100 * 1024 * 1024,
    int initialPeak = 120 * 1024 * 1024,
    int cacheBytes = 4 * 1024 * 1024,
    int cacheEntries = 2,
    int live = 1,
    FrameActivity Function()? activity,
  }) {
    var rss = initialRss;
    var peak = initialPeak;
    final probe = MemoryProbe(
      capacity: capacity,
      minInterval: minInterval,
      readRss: () => rss,
      readPeakRss: () => peak,
      readImageCacheBytes: () => cacheBytes,
      readImageCacheEntries: () => cacheEntries,
      readLiveImages: () => live,
      takeFrameActivity: activity,
    );
    return (probe: probe, setRss: (v) => rss = v, setPeak: (v) => peak = v);
  }

  group('容量与淘汰', () {
    test('采样数受 capacity 硬上限约束，超出淘汰最旧', () {
      final p = probeWith(capacity: 3);
      for (var i = 0; i < 5; i++) {
        p.setRss((100 + i) * 1024 * 1024);
        p.probe.sample(force: true);
      }

      expect(p.probe.samples.length, 3, reason: '常驻进程无界采样就是一条随运行时长线性增长的泄漏');
      // 剩下的是最后三次（102/103/104MB），最旧的两条被淘汰。
      expect(p.probe.samples.map((s) => s.rssBytes).toList(), [
        (102 * 1024 * 1024),
        (103 * 1024 * 1024),
        (104 * 1024 * 1024),
      ]);
      expect(p.probe.latest?.rssBytes, 104 * 1024 * 1024);
    });

    test('samples 返回不可变副本（调用方改不动内部状态）', () {
      final p = probeWith();
      p.probe.sample(force: true);
      expect(() => p.probe.samples.clear(), throwsUnsupportedError);
    });
  });

  group('间隔闸门', () {
    test('minInterval 内的重复采样被跳过（返回 null 且不入缓冲）', () {
      final p = probeWith(minInterval: const Duration(seconds: 30));
      final first = p.probe.sample(at: DateTime(2026, 11, 5, 12, 0, 0));
      expect(first, isNotNull);

      final skipped = p.probe.sample(at: DateTime(2026, 11, 5, 12, 0, 10));
      expect(skipped, isNull, reason: '突发的一串调用会把 12 个槽位在毫秒内填满');
      expect(p.probe.samples.length, 1);
    });

    test('force 绕过间隔闸门（导出报告那一刻要最新值）', () {
      final p = probeWith(minInterval: const Duration(seconds: 30));
      p.probe.sample(at: DateTime(2026, 11, 5, 12, 0, 0));
      final forced = p.probe.sample(
        force: true,
        at: DateTime(2026, 11, 5, 12, 0, 10),
      );

      expect(forced, isNotNull);
      expect(p.probe.samples.length, 2);
    });

    test('间隔够了自然采样（不需要 force）', () {
      final p = probeWith(minInterval: const Duration(seconds: 30));
      p.probe.sample(at: DateTime(2026, 11, 5, 12, 0, 0));
      expect(p.probe.sample(at: DateTime(2026, 11, 5, 12, 0, 31)), isNotNull);
    });
  });

  group('峰值语义', () {
    test('并入 OS 高水位：两次采样之间的瞬时峰值不会被漏掉', () {
      // 采样到的 rss 一直是 100MB，但 OS 记录的高水位是 500MB
      // （采样间隔内涨到过 500MB 又回落——正是 G6/G7 那类峰值）。
      final p = probeWith(initialRss: 100 * 1024 * 1024);
      p.setPeak(500 * 1024 * 1024);

      final sample = p.probe.sample(force: true);

      expect(sample?.peakRssBytes, 500 * 1024 * 1024);
      expect(p.probe.peakRssBytes, 500 * 1024 * 1024);
      expect(sample?.rssBytes, 100 * 1024 * 1024, reason: '当前值仍是当前值');
    });

    test('峰值只增不减（后一次读数更低时保留历史峰值）', () {
      final p = probeWith(initialRss: 300 * 1024 * 1024, initialPeak: 0);
      p.probe.sample(force: true);
      expect(p.probe.peakRssBytes, 300 * 1024 * 1024);

      p.setRss(50 * 1024 * 1024);
      final later = p.probe.sample(force: true);
      expect(later?.peakRssBytes, 300 * 1024 * 1024);
    });
  });

  group('峰值时刻（issue #99 缺口 1）', () {
    test('峰值变大时记录该次采样的时刻，报告行带 @hh:mm:ss', () {
      final p = probeWith(initialPeak: 100 * 1024 * 1024);
      p.setPeak(541 * 1024 * 1024);
      final at = DateTime(2026, 11, 9, 14, 12, 35);

      final sample = p.probe.sample(force: true, at: at);
      expect(sample?.peakAt, at);
      expect(p.probe.peakObservedAt, at);
      expect(sample?.toReportLine(), contains('peak=541.0MB@14:12:35'));
    });

    test('峰值不变时保持原时刻（不重复打 @，也不被后续采样覆盖）', () {
      final p = probeWith(initialPeak: 100 * 1024 * 1024);
      p.setPeak(541 * 1024 * 1024);
      final first = DateTime(2026, 11, 9, 14, 12, 35);
      p.probe.sample(force: true, at: first);

      final second = p.probe.sample(
        force: true,
        at: DateTime(2026, 11, 9, 14, 13, 35),
      );
      expect(second?.peakAt, isNull, reason: '峰值没变，这一行不带 @');
      expect(p.probe.peakObservedAt, first, reason: '首次观察时刻不被覆盖');
      expect(second?.toReportLine(), isNot(contains('@')));
    });

    test('峰值观察时刻滚出窗口后仍能给出（reportLines 补一行）', () {
      final p = probeWith(capacity: 2, initialPeak: 100 * 1024 * 1024);
      p.setPeak(541 * 1024 * 1024);
      p.probe.sample(force: true, at: DateTime(2026, 11, 9, 14, 12, 35));
      for (var i = 0; i < 3; i++) {
        p.probe.sample(force: true, at: DateTime(2026, 11, 9, 14, 20 + i, 0));
      }

      final lines = p.probe.reportLines();
      expect(
        lines.any((l) => l.contains('峰值 541.0MB 首次观察于 14:12:35')),
        isTrue,
        reason: '窗口里已没有带 @ 的行，必须单独补一行，否则峰值时刻又读不出',
      );
    });
  });

  group('账本快照（issue #99 缺口 2）', () {
    MemoryProbe ledgerProbe({List<MemoryLedgerEntry> Function()? readLedger}) =>
        MemoryProbe(
          readRss: () => 100 * 1024 * 1024,
          readPeakRss: () => 100 * 1024 * 1024,
          readImageCacheBytes: () => 0,
          readImageCacheEntries: () => 0,
          readLiveImages: () => 0,
          readLedger: readLedger,
        );

    test('账本非空时快照随采样留存，lastLedgerSnapshot 给出最近一份', () {
      const entry = MemoryLedgerEntry(
        name: 'conversation.timeline',
        label: '对话页时间线',
        count: 19,
        bytes: 3 * 1024,
      );
      final probe = ledgerProbe(readLedger: () => const [entry]);
      final at = DateTime(2026, 11, 9, 14, 19, 6);
      probe.sample(force: true, at: at);

      final snap = probe.lastLedgerSnapshot;
      expect(snap?.at, at);
      expect(snap?.entries.single.name, 'conversation.timeline');
    });

    test('账本为空时不记快照（null = 那一刻没有持有方登记）', () {
      final probe = ledgerProbe(readLedger: () => const []);
      probe.sample(force: true);
      expect(probe.lastLedgerSnapshot, isNull);
      expect(probe.samples.single.ledger, isNull);
    });

    test('读数抛异常时降级为 null，不打断采样', () {
      final probe = ledgerProbe(readLedger: () => throw StateError('boom'));
      final sample = probe.sample(force: true);
      expect(sample, isNotNull, reason: '账本是诊断，不是采样失败的理由');
      expect(sample?.ledger, isNull);
      expect(probe.lastLedgerSnapshot, isNull);
    });

    test('页面卸载后（账本转空）最近一份非空快照仍在窗口里可取', () {
      var current = const [
        MemoryLedgerEntry(
          name: 'conversation.timeline',
          label: '对话页时间线',
          count: 19,
          bytes: 3 * 1024,
        ),
      ];
      final probe = ledgerProbe(readLedger: () => current);
      probe.sample(force: true, at: DateTime(2026, 11, 9, 14, 19, 6));

      current = const [];
      probe.sample(force: true, at: DateTime(2026, 11, 9, 14, 26, 40));

      expect(probe.samples.last.ledger, isNull, reason: '卸载后当次采样确实没有登记项');
      expect(probe.lastLedgerSnapshot?.at, DateTime(2026, 11, 9, 14, 19, 6));
    });
  });

  group('读数失败降级', () {
    test('读数抛异常时返回 null、不入缓冲、不抛给调用方', () {
      final probe = MemoryProbe(
        readRss: () => throw UnsupportedError('no rss'),
        readPeakRss: () => 0,
        readImageCacheBytes: () => 0,
        readImageCacheEntries: () => 0,
        readLiveImages: () => 0,
      );

      expect(probe.sample(force: true), isNull);
      expect(probe.samples, isEmpty);
      expect(probe.reportLines(), isEmpty);
    });
  });

  group('报告行', () {
    test('格式：时分秒 + MB（一位小数）+ 张数 + live', () {
      final p = probeWith(
        initialRss: 182 * 1024 * 1024 + 400 * 1024,
        initialPeak: 240 * 1024 * 1024,
        cacheBytes: 12 * 1024 * 1024,
        cacheEntries: 4,
        live: 1,
      );
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 14, 3, 11));

      expect(p.probe.reportLines(), [
        // 首条采样把峰值从 0 推到 240MB，故它带 `@`（峰值首次观察时刻）。
        '14:03:11 rss=182.4MB peak=240.0MB@14:03:11 '
            'imageCache=12.0MB(4 张) live=1',
      ]);
    });

    test('还没采过时是空列表（报告据此整节省略）', () {
      final p = probeWith();
      expect(p.probe.reportLines(), isEmpty);
    });
  });

  group('启动基线', () {
    test('基线在窗口内时不重复输出（它就是第一行）', () {
      final p = probeWith(capacity: 3);
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 23, 13, 19));
      p.setRss(120 * 1024 * 1024);
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 23, 14, 19));

      final lines = p.probe.reportLines();
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('23:13:19 rss='));
      expect(
        lines.where((l) => l.contains('启动基线')),
        isEmpty,
        reason: '基线还在窗口里时，它就是第一行',
      );
    });

    test('基线被环形缓冲滚掉后，报告里补一行并标注（否则读不出「从多少涨上来」）', () {
      final p = probeWith(capacity: 2);
      // 真实报障的形状：启动 66.9MB，20 分钟后窗口里只剩 253MB 那几条。
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 23, 13, 19));
      for (var i = 0; i < 4; i++) {
        p.setRss(250 * 1024 * 1024);
        p.probe.sample(
          force: true,
          at: DateTime(2026, 11, 5, 23, 33, 19 + i * 60),
        );
      }

      final lines = p.probe.reportLines();
      // 1 条基线 + 1 条「峰值首次观察」（那次采样已被滚出窗口）+ 2 条采样。
      expect(lines, hasLength(4), reason: '基线 + 峰值时刻补行 + 2 条窗口内采样');
      expect(lines.first, startsWith('23:13:19 rss='));
      expect(lines.first, contains('启动基线'));
      expect(
        lines[1],
        contains('峰值 250.0MB 首次观察于'),
        reason: '滚出窗口的那次采样才是峰值首次被观察到的一刻',
      );
      expect(p.probe.baseline?.rssBytes, 100 * 1024 * 1024);
      expect(p.probe.samples.first.rssBytes, 250 * 1024 * 1024);
    });

    test('基线只记首条（后续采样不覆盖它）', () {
      final p = probeWith();
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 10, 0, 0));
      p.setRss(500 * 1024 * 1024);
      p.probe.sample(force: true, at: DateTime(2026, 11, 5, 10, 1, 0));

      expect(p.probe.baseline?.at, DateTime(2026, 11, 5, 10, 0, 0));
      expect(p.probe.baseline?.rssBytes, 100 * 1024 * 1024);
    });
  });

  group('安装 / 卸载', () {
    test('安装后立即采一条基线（启动时的参照点）', () {
      final p = probeWith();
      final installed = installMemoryProbe(
        probe: p.probe,
        interval: const Duration(hours: 1),
      );

      expect(identical(installed, p.probe), isTrue);
      expect(installedMemoryProbe, same(p.probe));
      expect(p.probe.samples.length, 1);
    });

    test('重复安装返回同一个实例（不重复起定时器）', () {
      final p = probeWith();
      final first = installMemoryProbe(
        probe: p.probe,
        interval: const Duration(hours: 1),
      );
      final second = installMemoryProbe(
        probe: probeWith().probe,
        interval: const Duration(hours: 1),
      );

      expect(identical(first, second), isTrue);
      expect(identical(installedMemoryProbe, p.probe), isTrue);
    });

    test('定时器按间隔采样（只进环形缓冲，不写日志）', () async {
      final p = probeWith();
      installMemoryProbe(
        probe: p.probe,
        interval: const Duration(milliseconds: 10),
      );
      final logCountAfterInstall = SpbLog.recentLogs.length;

      await Future<void>.delayed(const Duration(milliseconds: 55));
      uninstallMemoryProbe();

      expect(
        p.probe.samples.length,
        greaterThan(1),
        reason: '基线 1 条 + 定时器至少再采 1 条',
      );
      expect(
        SpbLog.recentLogs.length,
        logCountAfterInstall,
        reason: '每分钟一条日志会在 8 小时内冲干净 500 条环形缓冲',
      );
    });

    test('卸载后不再采样', () async {
      final p = probeWith();
      installMemoryProbe(
        probe: p.probe,
        interval: const Duration(milliseconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      uninstallMemoryProbe();
      final frozen = p.probe.samples.length;

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(p.probe.samples.length, frozen);
      expect(installedMemoryProbe, isNull);
    });
  });

  group('渲染帧活动（CPU 维度）', () {
    test('接线后采样行尾部带 fps 与 raster', () {
      final p = probeWith(
        activity: () => const FrameActivity(
          frames: 3576,
          window: Duration(minutes: 1),
          avgRasterUs: 7300,
        ),
      );
      final s = p.probe.sample(force: true)!;
      final line = s.toReportLine();
      expect(line, contains('fps=59.6'));
      expect(line, contains('raster=7.3ms'));
    });

    test('窗口为 0（首条采样）时不写 fps，避免误读成「没画帧」', () {
      final p = probeWith(
        activity: () => const FrameActivity(frames: 0, window: Duration.zero),
      );
      expect(
        p.probe.sample(force: true)!.toReportLine(),
        isNot(contains('fps=')),
      );
    });

    test('未接线（旧构造方式）时报告行保持原样', () {
      final p = probeWith();
      final line = p.probe.sample(force: true)!.toReportLine();
      expect(line, contains('rss='));
      expect(line, isNot(contains('fps=')));
    });

    test('引擎没回传 timings 时只写 fps，不写 raster=0ms', () {
      final p = probeWith(
        activity: () =>
            const FrameActivity(frames: 60, window: Duration(seconds: 60)),
      );
      final line = p.probe.sample(force: true)!.toReportLine();
      expect(line, contains('fps=1.0'));
      expect(line, isNot(contains('raster=')));
    });
  });
}
