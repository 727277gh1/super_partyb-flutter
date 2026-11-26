import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 同步在途字节计数与账本登记（`sync_memory.dart`）。
///
/// ## 这个测试防的是什么
///
/// 这条读数存在的理由是「2026-11 真机报障的高水位日志 `breakdown=` 是空的」。
/// 它的失败模式同样是静默的：
///
/// - **只 hold 不 release**（异常路径漏掉 `finally`）→ 读数一路虚高，下次报障
///   的分解行误导人，比没有读数更糟；
/// - **release 多于 hold** → 负数会让读者以为账本坏了；
/// - **登记项没进账本** → 日志里还是空的（功能等于没做）。
void main() {
  setUp(() {
    SpbLog.configure(sink: const NullLogSink(), minLevel: LogLevel.debug);
    SyncInFlightBytes.reset();
    MemoryLedger.reset();
  });
  tearDown(() {
    SyncInFlightBytes.reset();
    MemoryLedger.reset();
  });

  group('计数', () {
    test('hold 累加字节与文件数，release 减回去', () {
      SyncInFlightBytes.hold(10);
      SyncInFlightBytes.hold(5);
      expect(SyncInFlightBytes.bytes, 15);
      expect(SyncInFlightBytes.files, 2);

      SyncInFlightBytes.release(10);
      expect(SyncInFlightBytes.bytes, 5);
      expect(SyncInFlightBytes.files, 1);

      SyncInFlightBytes.release(5);
      expect(SyncInFlightBytes.bytes, 0);
      expect(SyncInFlightBytes.files, 0);
    });

    test('release 多于 hold 时归零（不报负数）', () {
      SyncInFlightBytes.hold(10);
      SyncInFlightBytes.release(100);
      expect(SyncInFlightBytes.bytes, 0);
      expect(SyncInFlightBytes.files, 0);
    });

    test('0 / 负数字节不计数（0 字节文件不占内存）', () {
      SyncInFlightBytes.hold(0);
      SyncInFlightBytes.hold(-5);
      expect(SyncInFlightBytes.bytes, 0);
      expect(SyncInFlightBytes.files, 0);
    });
  });

  group('账本登记', () {
    test('登记后读数出现在账本快照里（高水位日志的 breakdown 靠它）', () {
      final token = registerSyncInFlightGauge();
      SyncInFlightBytes.hold(3 * 1024 * 1024);

      final entry = MemoryLedger.snapshot().firstWhere(
        (e) => e.name == syncInFlightGaugeName,
      );
      expect(entry.bytes, 3 * 1024 * 1024);
      expect(entry.count, 1);
      expect(entry.reportLine, contains('同步在途字节'));

      MemoryLedger.unregister(token);
      expect(
        MemoryLedger.snapshot().where((e) => e.name == syncInFlightGaugeName),
        isEmpty,
      );
    });

    test('越过高水位线时被标记（默认 128MB）', () {
      registerSyncInFlightGauge();
      SyncInFlightBytes.hold(200 * 1024 * 1024);

      final over = MemoryLedger.overWarnEntries();
      expect(over.map((e) => e.name), contains(syncInFlightGaugeName));
    });

    test('在途清零后不越线', () {
      registerSyncInFlightGauge();
      SyncInFlightBytes.hold(200 * 1024 * 1024);
      SyncInFlightBytes.release(200 * 1024 * 1024);

      expect(
        MemoryLedger.overWarnEntries().where(
          (e) => e.name == syncInFlightGaugeName,
        ),
        isEmpty,
      );
    });
  });
}
