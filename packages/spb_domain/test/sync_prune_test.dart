import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 本地目录清理计划（`buildPrunePlan`）测试。
///
/// ## 这个测试防的是什么
///
/// 这是**删除**逻辑。`isGroupId` 是唯一的准入门槛，放宽一点就会把用户自己
/// 名为 `a1b2` 的目录纳入候选——不可逆的数据损失。故：
/// - 形状校验必须严格（大小写、长度、字符集）；
/// - 策略边界（`days = 0` 的「全部可删」语义、空目录、恰好等于 cutoff）；
/// - 计划必须**可预览**（数量、体积、原因）——用户看不到数字的删除是不可接受的。
void main() {
  const gidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const gidC = '0123456789abcdef0123456789abcdef';

  LocalGroupStats stats(
    String id, {
    int fileCount = 1,
    int totalBytes = 100,
    int? newestMtime,
  }) => LocalGroupStats(
    groupId: id,
    fileCount: fileCount,
    totalBytes: totalBytes,
    newestMtime: newestMtime,
  );

  group('isGroupId：唯一准入门槛', () {
    test('接受 32 位小写十六进制', () {
      expect(isGroupId(gidA), isTrue);
      expect(isGroupId(gidC), isTrue);
      expect(isGroupId('0' * 32), isTrue);
      expect(isGroupId('f' * 32), isTrue);
    });

    test('拒绝长度不符', () {
      expect(isGroupId(''), isFalse);
      expect(isGroupId('a' * 31), isFalse);
      expect(isGroupId('a' * 33), isFalse);
      expect(isGroupId('a1b2'), isFalse);
    });

    test('拒绝大写十六进制', () {
      // 刻意严格：Go 侧 NewID 产出的是小写，大写不可能是真实 group_id，
      // 那更可能是用户自己的目录。
      expect(isGroupId('A' * 32), isFalse);
      expect(isGroupId('aB' * 16), isFalse);
    });

    test('拒绝非十六进制字符（用户自己的文件/目录）', () {
      expect(isGroupId('z' * 32), isFalse);
      expect(isGroupId('g${'a' * 31}'), isFalse);
      expect(isGroupId('-${'a' * 31}'), isFalse);
      expect(isGroupId('_${'a' * 31}'), isFalse);
      expect(isGroupId('${'a' * 31} '), isFalse);
      expect(isGroupId('${'a' * 31}.'), isFalse);
    });

    test('排除常见开发目录名', () {
      for (final name in [
        '.git',
        'node_modules',
        'README.md',
        'src',
        'build',
      ]) {
        expect(isGroupId(name), isFalse, reason: '$name 不该进入删除候选');
      }
    });
  });

  group('PruneOlderThanDays：按时间清理', () {
    const now = 1781771217;

    test('超过 N 天的进入候选，未超过的保留', () {
      final plan = buildPrunePlan(
        groups: [
          stats(gidA, newestMtime: now - 40 * 86400), // 40 天前
          stats(gidB, newestMtime: now - 5 * 86400), // 5 天前
        ],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );

      expect(plan.candidates.length, 1);
      expect(plan.candidates.first.groupId, gidA);
      expect(plan.kept, 1);
      expect(plan.candidates.first.reason, '超过 30 天未更新');
    });

    test('恰好等于 cutoff 的**保留**（边界：用 < 而非 <=）', () {
      // 恰好 N 天前的文件不算「超过 N 天」。
      final plan = buildPrunePlan(
        groups: [stats(gidA, newestMtime: now - 30 * 86400)],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );
      expect(plan.candidates, isEmpty);
      expect(plan.kept, 1);
    });

    test('days=0 是显式「全部可删」（不靠 mtime 推导）', () {
      // 若靠 `mtime < now` 推导，刚写入的文件会因 mtime == now 而幸存，
      // 使「清空」看着像没清干净。
      final plan = buildPrunePlan(
        groups: [
          stats(gidA, newestMtime: now), // 就是此刻写入的
          stats(gidB, newestMtime: now - 1),
        ],
        policy: const PruneOlderThanDays(days: 0, nowUnix: now),
      );
      expect(plan.candidates.length, 2);
      expect(plan.kept, 0);
    });

    test('空目录（newestMtime 为 null）视为可清理', () {
      // 同步没产出内容，留着也没用。
      final plan = buildPrunePlan(
        groups: [stats(gidA, fileCount: 0, totalBytes: 0, newestMtime: null)],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );
      expect(plan.candidates.length, 1);
      expect(plan.candidates.first.reason, '空目录');
    });

    test('空目录即使 days=0 也正常（不因 null 崩）', () {
      final plan = buildPrunePlan(
        groups: [stats(gidA, newestMtime: null)],
        policy: const PruneOlderThanDays(days: 0, nowUnix: now),
      );
      expect(plan.candidates.length, 1);
    });

    test('空输入 → 空计划', () {
      final plan = buildPrunePlan(
        groups: const [],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.kept, 0);
      expect(plan.totalBytes, 0);
    });
  });

  group('PruneNotInKeepList：孤儿清理', () {
    test('不在保留集合里的进入候选', () {
      final plan = buildPrunePlan(
        groups: [stats(gidA), stats(gidB), stats(gidC)],
        policy: const PruneNotInKeepList({gidA, gidC}),
      );
      expect(plan.candidates.length, 1);
      expect(plan.candidates.first.groupId, gidB);
      expect(plan.candidates.first.reason, '不在保留列表中');
      expect(plan.kept, 2);
    });

    test('保留集合为空 → 全部候选（用户已无任何 group）', () {
      final plan = buildPrunePlan(
        groups: [stats(gidA), stats(gidB)],
        policy: const PruneNotInKeepList({}),
      );
      expect(plan.candidates.length, 2);
      expect(plan.kept, 0);
    });
  });

  group('PrunePlan：可预览性', () {
    test('汇总数量与体积（用户看不到数字的删除不可接受）', () {
      const now = 1781771217;
      final plan = buildPrunePlan(
        groups: [
          stats(
            gidA,
            fileCount: 3,
            totalBytes: 5 * 1024 * 1024,
            newestMtime: now - 40 * 86400,
          ),
          stats(
            gidB,
            fileCount: 2,
            totalBytes: 1024,
            newestMtime: now - 50 * 86400,
          ),
        ],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );

      expect(plan.totalFiles, 5);
      expect(plan.totalBytes, 5 * 1024 * 1024 + 1024);
      expect(plan.summarize(), contains('将删除 2 个对话目录'));
      expect(plan.summarize(), contains('5 个文件'));
      expect(plan.summarize(), contains('保留 0 个'));
    });

    test('无候选时的摘要说明保留了多少', () {
      final plan = buildPrunePlan(
        groups: [stats(gidA, newestMtime: 1781771217)],
        policy: const PruneOlderThanDays(days: 30, nowUnix: 1781771217),
      );
      expect(plan.summarize(), contains('无需清理'));
      expect(plan.summarize(), contains('保留 1 个'));
    });

    test('候选按体积降序（用户更关心省空间），同体积按 id 保证可复现', () {
      const now = 1781771217;
      final plan = buildPrunePlan(
        groups: [
          stats(gidB, totalBytes: 100, newestMtime: now - 40 * 86400),
          stats(gidA, totalBytes: 100, newestMtime: now - 40 * 86400),
          stats(gidC, totalBytes: 999, newestMtime: now - 40 * 86400),
        ],
        policy: const PruneOlderThanDays(days: 30, nowUnix: now),
      );

      expect(plan.candidates.map((c) => c.groupId).toList(), [
        gidC,
        gidA,
        gidB,
      ]);
    });
  });

  group('humanBytes', () {
    test('各量级', () {
      expect(humanBytes(0), '0 B');
      expect(humanBytes(512), '512 B');
      expect(humanBytes(1024), '1.0 KB');
      expect(humanBytes(1536), '1.5 KB');
      expect(humanBytes(1024 * 1024), '1.0 MB');
      expect(humanBytes(5 * 1024 * 1024), '5.0 MB');
      expect(humanBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('用二进制单位（与文件管理器一致，避免两个数字让用户困惑）', () {
      // 1000 字节 < 1024 → 显示为 B，而不是 "1.0 KB"。
      expect(humanBytes(1000), '1000 B');
    });
  });
}
