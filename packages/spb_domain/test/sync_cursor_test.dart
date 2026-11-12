import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 同步游标计算（`effectiveCursor`）与时间格式化测试。
///
/// ## 这个测试防的是什么
///
/// 游标算错的后果是**静默漏更新**：本地看起来同步成功，但一批文件永远不会
/// 被拉下来。两种典型错法：
/// - 取「更早」而非「更晚」的下限 → `since_days` 完全失效（用户设了 7 天，
///   实际仍拉全部历史），或反复重拉已同步区间；
/// - 时间格式化与 UFS 的 `updated_at` 形状不一致 → 字符串比较（字典序即时序）
///   失效，服务端 `updated_since` 过滤出错。
void main() {
  group('unixToRfc3339', () {
    test('格式与 UFS 的 updated_at 一致（秒级、无毫秒段、Z 结尾）', () {
      // Go time.Time 序列化秒级时刻时是 `2026-06-18T08:26:57Z`。
      // DateTime.toIso8601String() 会给 `.000` 毫秒段，那会破坏字典序比较。
      final s = unixToRfc3339(1781771217);
      expect(s, '2026-06-18T08:26:57Z');
      expect(s.contains('.'), isFalse, reason: '不得出现毫秒段');
      expect(s.length, 20);
    });

    test('epoch 与负时间戳', () {
      expect(unixToRfc3339(0), '1970-01-01T00:00:00Z');
      expect(unixToRfc3339(-1), '1969-12-31T23:59:59Z');
    });

    test('月/日/时/分/秒都补零（字典序即时序的前提）', () {
      // 缺零会让 "2026-1-2T3:0:0Z" 与 "2026-10-01..." 的字典序颠倒。
      final early = unixToRfc3339(
        DateTime.utc(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000,
      );
      expect(early, '2026-01-02T03:04:05Z');
    });

    test('字典序即时序（跨年、跨月、跨日、跨时）', () {
      final times = [
        DateTime.utc(2025, 12, 31, 23, 59, 59),
        DateTime.utc(2026, 1, 1, 0, 0, 0),
        DateTime.utc(2026, 1, 2, 0, 0, 0),
        DateTime.utc(2026, 2, 1, 0, 0, 0),
        DateTime.utc(2026, 10, 1, 0, 0, 0),
        DateTime.utc(2027, 1, 1, 0, 0, 0),
      ].map((d) => d.millisecondsSinceEpoch ~/ 1000).toList();

      for (var i = 1; i < times.length; i++) {
        final a = unixToRfc3339(times[i - 1]);
        final b = unixToRfc3339(times[i]);
        expect(a.compareTo(b) < 0, isTrue, reason: '$a 应排在 $b 之前（字典序）');
      }
    });
  });

  group('cutoffDaysAgo', () {
    test('days=0 返回 now 本身（不是 1970）', () {
      const now = 1781771217;
      expect(cutoffDaysAgo(now, 0), unixToRfc3339(now));
    });

    test('减去整天数', () {
      final now =
          DateTime.utc(2026, 6, 18, 8, 0, 0).millisecondsSinceEpoch ~/ 1000;
      expect(cutoffDaysAgo(now, 1), '2026-06-17T08:00:00Z');
      expect(cutoffDaysAgo(now, 30), '2026-05-19T08:00:00Z');
    });

    test('跨年', () {
      final jan2 = DateTime.utc(2026, 1, 2).millisecondsSinceEpoch ~/ 1000;
      expect(cutoffDaysAgo(jan2, 1), '2026-01-01T00:00:00Z');
      expect(cutoffDaysAgo(jan2, 2), '2025-12-31T00:00:00Z');
    });
  });

  group('effectiveCursor', () {
    const now = 1781771217; // 2026-06-18T08:26:57Z

    test('无游标、无 since_days → null（首次全量）', () {
      // 关键：首次若发增量请求，服务端只返回近期变化，本地漏掉全部历史
      // 交付物，而用户以为同步完成了。
      expect(
        effectiveCursor(saved: null, sinceDays: null, nowUnix: now),
        isNull,
      );
    });

    test('无游标、有 since_days → 用下限（用户明确要求跳过历史）', () {
      final c = effectiveCursor(saved: null, sinceDays: 7, nowUnix: now);
      expect(c, cutoffDaysAgo(now, 7));
    });

    test('有游标、无 since_days → 用游标（正常增量）', () {
      const saved = '2026-06-01T00:00:00Z';
      expect(
        effectiveCursor(saved: saved, sinceDays: null, nowUnix: now),
        saved,
      );
    });

    test('游标比下限更晚 → 保留游标（不因加了 since_days 而重拉）', () {
      // 游标 06-10 晚于「近 7 天」下限 06-11？不——06-10 < 06-11，故这里
      // 用 06-15 作游标（晚于下限）。
      const saved = '2026-06-15T00:00:00Z';
      expect(effectiveCursor(saved: saved, sinceDays: 7, nowUnix: now), saved);
    });

    test('下限比游标更晚 → 用下限（用户刚把 since_days 调小）', () {
      // 游标是半年前的，用户设了「近 7 天」：应从下限开始，跳过历史。
      const saved = '2026-01-01T00:00:00Z';
      expect(
        effectiveCursor(saved: saved, sinceDays: 7, nowUnix: now),
        cutoffDaysAgo(now, 7),
      );
    });

    test('since_days 为 0 表示「不限」而非「下限=此刻」', () {
      // 若把 0 解释成 cutoffDaysAgo(now, 0) == now，则 updated_since=now，
      // 什么都同步不到。UI 上「0」与「不限」是同一个选项，行为必须一致。
      const saved = '2026-01-01T00:00:00Z';
      expect(effectiveCursor(saved: saved, sinceDays: 0, nowUnix: now), saved);
      expect(
        effectiveCursor(saved: null, sinceDays: 0, nowUnix: now),
        isNull,
        reason: '无游标 + 0 → 仍是首次全量',
      );
    });

    test('游标为空白串视为无游标', () {
      expect(
        effectiveCursor(saved: '   ', sinceDays: null, nowUnix: now),
        isNull,
      );
      expect(
        effectiveCursor(saved: '', sinceDays: 7, nowUnix: now),
        cutoffDaysAgo(now, 7),
      );
    });

    test('游标两端空白被裁掉（否则服务端字符串比较会错）', () {
      expect(
        effectiveCursor(
          saved: ' 2026-06-01T00:00:00Z ',
          sinceDays: null,
          nowUnix: now,
        ),
        '2026-06-01T00:00:00Z',
      );
    });
  });
}
