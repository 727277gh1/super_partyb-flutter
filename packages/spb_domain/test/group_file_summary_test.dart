/// 「本地已同步交付物按 group 统计」聚合（[groupFileSummaryOf]）测试。
///
/// ## 命题
///
/// 聚合是纯函数，输入是两个状态键的 [SyncState]（workspace / 单 group 布局），
/// 输出是一个 group 的 `GroupFileSummary`（文件数 / 字节 / 最近同步时间）。
/// 逐条覆盖：两种布局、前缀边界、机器产物过滤、去重、空态与异常时间。
library;

import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

void main() {
  /// 造一条已同步记录。
  SyncedFile file({String? etag, int size = 100, String? updatedAt}) =>
      SyncedFile(etag: etag, size: size, updatedAt: updatedAt);

  group('groupFileSummaryOf', () {
    test('workspace 布局：按 `{groupId}/` 前缀聚合', () {
      final state = SyncState(
        cursor: '2024-01-01T00:00:00Z',
        files: {
          'g1/reports/a.md': file(size: 100, updatedAt: '2024-03-01T08:00:00Z'),
          'g1/reports/b.md': file(size: 200, updatedAt: '2024-03-02T08:00:00Z'),
          // 别的 group 的文件：不算进 g1。
          'g2/README.md': file(size: 5000),
        },
      );

      final s = groupFileSummaryOf(groupId: 'g1', workspaceState: state);
      expect(s, isNotNull);
      expect(s!.fileCount, 2);
      expect(s.totalBytes, 300);
      // 最近同步时间取最大值。
      expect(s.lastSyncedAt, DateTime.parse('2024-03-02T08:00:00Z').toLocal());
    });

    test('前缀必须按段匹配：`g10/` 不算进 `g1`', () {
      // `startsWith('g1/')` 天然拒绝 `g10/...`（`g10` 不以 `g1/` 开头），
      // 但反向要小心：这是防回归哨兵——若实现改成 `startsWith('g1')`
      // （漏斜杠），g10 的文件会被错误计入 g1。
      final state = SyncState(files: {'g10/reports/x.md': file(size: 999)});
      final s = groupFileSummaryOf(groupId: 'g1', workspaceState: state);
      expect(s, isNull, reason: 'g10 的文件不属于 g1');
    });

    test('单 group 布局：记录本身就是 group 内路径', () {
      final state = SyncState(
        files: {'reports/a.md': file(size: 100), 'README.md': file(size: 50)},
      );
      final s = groupFileSummaryOf(
        groupId: 'g1',
        workspaceState: SyncState.empty,
        singleGroupState: state,
      );
      expect(s, isNotNull);
      expect(s!.fileCount, 2);
      expect(s.totalBytes, 150);
    });

    test('同一 group 在两个键下都有记录：合并去重', () {
      // 「先定向同步（单 group 键）、后全量同步（workspace 键）」会留下两份
      // 记录，指向同一份内容。按 group 内路径去重后不该双倍计数。
      final s = groupFileSummaryOf(
        groupId: 'g1',
        workspaceState: SyncState(files: {'g1/reports/a.md': file(size: 100)}),
        singleGroupState: SyncState(files: {'reports/a.md': file(size: 100)}),
      );
      expect(s, isNotNull);
      expect(s!.fileCount, 1, reason: '同一文件在两个键里各留一条，去重后是一份');
      expect(s.totalBytes, 100);
    });

    test('机器产物不计入（TTS / .archive / _attachments）', () {
      final state = SyncState(
        files: {
          // TTS：锚定开头的判据（group 内路径 `reports/tts/...`）。
          'g1/reports/tts/seg1.mp3': file(size: 40000),
          // 机器产物目录段出现在任意层级。
          'g1/.archive/v1/snapshot.md': file(size: 300),
          'g1/_attachments/tmp.bin': file(size: 700),
          // 真交付物。
          'g1/reports/report.md': file(size: 100),
          // 不误伤：`x/.archivey/b.md` 不是按段相等。
          'g1/x/.archivey/b.md': file(size: 10),
        },
      );
      final s = groupFileSummaryOf(groupId: 'g1', workspaceState: state);
      expect(s, isNotNull);
      expect(s!.fileCount, 2, reason: '只有 report.md 与 .archivey/b.md 算');
      expect(s.totalBytes, 110);
    });

    test('全部是机器产物时返回 null（不显示 0 文件条）', () {
      final state = SyncState(
        files: {'g1/reports/tts/seg1.mp3': file(size: 40000)},
      );
      expect(groupFileSummaryOf(groupId: 'g1', workspaceState: state), isNull);
    });

    test('从未同步（两个键都空）返回 null', () {
      expect(
        groupFileSummaryOf(
          groupId: 'g1',
          workspaceState: SyncState.empty,
          singleGroupState: SyncState.empty,
        ),
        isNull,
      );
    });

    test('未传单 group 状态时只看 workspace 键', () {
      final s = groupFileSummaryOf(
        groupId: 'g1',
        workspaceState: SyncState(files: {'g1/a.md': file(size: 1)}),
      );
      expect(s, isNotNull);
      expect(s!.fileCount, 1);
    });

    test('groupId 为空返回 null（防御）', () {
      expect(
        groupFileSummaryOf(
          groupId: '',
          workspaceState: SyncState(files: {'a.md': file()}),
        ),
        isNull,
      );
    });

    test('updated_at 缺失或不可解析：lastSyncedAt 用其它文件的最大值', () {
      final state = SyncState(
        files: {
          'g1/a.md': file(size: 1, updatedAt: null),
          'g1/b.md': file(size: 2, updatedAt: '不是时间'),
          'g1/c.md': file(size: 3, updatedAt: '2024-03-03T08:00:00Z'),
        },
      );
      final s = groupFileSummaryOf(groupId: 'g1', workspaceState: state);
      expect(s, isNotNull);
      expect(
        s!.lastSyncedAt,
        DateTime.parse('2024-03-03T08:00:00Z').toLocal(),
        reason: '缺时间的记录不参与，但不能让整体变 null',
      );
    });

    test('group 根目录行（空 inner）跳过', () {
      // workspace 布局下 group 根目录自身不会成为文件记录（同步器只写文件），
      // 但防御性跳过空路径——它来自 `g1/` 恰好剥完前缀的情形。
      final state = SyncState(files: {'g1/': file(size: 0)});
      expect(groupFileSummaryOf(groupId: 'g1', workspaceState: state), isNull);
    });
  });

  group('formatByteSize', () {
    test('分级', () {
      expect(formatByteSize(512), '512 B');
      expect(formatByteSize(1024), '1.0 KB');
      expect(formatByteSize(1536), '1.5 KB');
      expect(formatByteSize(3 * 1024 * 1024), '3.0 MB');
      expect(formatByteSize(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });
}
