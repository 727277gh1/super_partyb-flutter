import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 内存账本（`MemoryLedger`）的语义测试。
///
/// ## 这个测试防的是什么
///
/// 账本是**观测**设施，写错不会让任何业务用例变红，但会让「导出诊断日志」
/// 里的分解行**静默骗人**：聚合漏项、阈值取错、注销后仍读到旧闭包、读数抛错
/// 把整份报告带崩。这些都是「看起来有数据」的错误，比没有数据更糟。
void main() {
  setUp(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
    SpbLog.clearRecentLogs();
    MemoryLedger.reset();
  });

  tearDown(() {
    MemoryLedger.reset();
    SpbLog.clearRecentLogs();
  });

  group('注册 / 注销', () {
    test('注销后快照里不再出现（防止全局 Map 钉住页面 State）', () {
      final token = MemoryLedger.register(
        name: 'conversation.thumbnails',
        label: '对话页缩略图',
        read: () => const MemoryGauge(count: 3, bytes: 300),
      );

      expect(MemoryLedger.snapshot().single.count, 3);
      MemoryLedger.unregister(token);
      expect(MemoryLedger.snapshot(), isEmpty);
      expect(MemoryLedger.registrationCount, 0);
    });

    test('重复注销幂等（不抛）', () {
      final token = MemoryLedger.register(
        name: 'x',
        label: 'X',
        read: () => MemoryGauge.zero,
      );
      MemoryLedger.unregister(token);
      expect(() => MemoryLedger.unregister(token), returnsNormally);
    });

    test('同名登记项求和，阈值取最大而不是求和', () {
      MemoryLedger.register(
        name: 'conversation.timeline',
        label: '对话页时间线',
        read: () => const MemoryGauge(count: 100, bytes: 1000),
        warnCount: 2000,
      );
      MemoryLedger.register(
        name: 'conversation.timeline',
        label: '对话页时间线',
        read: () => const MemoryGauge(count: 50, bytes: 500),
        warnCount: 1500,
      );

      final entry = MemoryLedger.snapshot().single;
      expect(entry.count, 150, reason: '两端/多页面同名项应求和');
      expect(entry.bytes, 1500);
      expect(entry.warnCount, 2000, reason: '阈值取最大：两个页面各挂一份缓存时告警线不该翻倍');
    });
  });

  group('快照', () {
    test('按字节降序，字节相同按 name 稳定排序', () {
      MemoryLedger.register(
        name: 'b',
        label: 'B',
        read: () => const MemoryGauge(count: 1, bytes: 10),
      );
      MemoryLedger.register(
        name: 'a',
        label: 'A',
        read: () => const MemoryGauge(count: 1, bytes: 10),
      );
      MemoryLedger.register(
        name: 'c',
        label: 'C',
        read: () => const MemoryGauge(count: 1, bytes: 99),
      );

      expect(MemoryLedger.snapshot().map((e) => e.name).toList(), [
        'c',
        'a',
        'b',
      ], reason: '大头在前；同字节按 name 保证报告可 diff');
    });

    test('读数抛错：跳过该项并留一条 warn，其余项照常', () {
      MemoryLedger.register(
        name: 'broken',
        label: '坏读数',
        read: () => throw StateError('boom'),
      );
      MemoryLedger.register(
        name: 'ok',
        label: '正常',
        read: () => const MemoryGauge(count: 2, bytes: 20),
      );

      final snapshot = MemoryLedger.snapshot();
      expect(snapshot.map((e) => e.name), ['ok']);
      expect(
        SpbLog.recentLogs.any((r) => r.message == '内存账本读数失败'),
        isTrue,
        reason: '读数挂了本身就是要查的事，不能完全静默',
      );
    });
  });

  group('高水位判定与报告格式', () {
    test('overWarn：条目数或字节数任一越线即为真', () {
      const byCount = MemoryLedgerEntry(
        name: 'x',
        label: 'X',
        count: 11,
        bytes: 0,
        warnCount: 10,
      );
      const byBytes = MemoryLedgerEntry(
        name: 'x',
        label: 'X',
        count: 1,
        bytes: 11,
        warnBytes: 10,
      );
      const below = MemoryLedgerEntry(
        name: 'x',
        label: 'X',
        count: 10,
        bytes: 10,
        warnCount: 10,
        warnBytes: 10,
      );

      expect(byCount.overWarn, isTrue);
      expect(byBytes.overWarn, isTrue);
      expect(below.overWarn, isFalse, reason: '等于阈值不算越线');
    });

    test('reportLine / warnToken 的人类可读格式', () {
      const entry = MemoryLedgerEntry(
        name: 'conversation.thumbnails',
        label: '对话页缩略图',
        count: 214,
        bytes: 6396313,
      );
      expect(entry.reportLine, '对话页缩略图: 214 项 / 6.1MB');
      expect(entry.warnToken, '对话页缩略图=214/6.1MB');
    });

    test('formatMemoryBytes 三档单位', () {
      expect(formatMemoryBytes(512), '512B');
      expect(formatMemoryBytes(1536), '1.5KB');
      expect(formatMemoryBytes(3 * 1024 * 1024), '3.0MB');
    });

    test('reportLines 与 overWarnEntries 基于同一快照', () {
      MemoryLedger.register(
        name: 'a',
        label: 'A',
        read: () => const MemoryGauge(count: 5, bytes: 0),
        warnCount: 1,
      );
      MemoryLedger.register(
        name: 'b',
        label: 'B',
        read: () => const MemoryGauge(count: 0, bytes: 0),
      );

      expect(MemoryLedger.reportLines(), ['A: 5 项 / 0B', 'B: 0 项 / 0B']);
      expect(MemoryLedger.overWarnEntries().map((e) => e.name), ['a']);
    });
  });
}
