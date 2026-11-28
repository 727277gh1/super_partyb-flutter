import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `WorkspaceSyncReview` / `WorkspaceSyncReviewsPage` 契约测试。
///
/// ## 这个测试防的是什么
///
/// 这三处读错都会让「被挂起的文件」重新变成静默缺失（用户看不到任何解释）：
///
/// | 读错 | 后果 |
/// |---|---|
/// | `enabled: false` 当成空列表 | 服务端没跑 groupsync 时页面装作「一切正常」 |
/// | 未知 `reason` 被丢弃 | 服务端新增原因后该项消失，文件静默卡住 |
/// | 丢掉 `revision` | resolve 必然被 409/400 拒绝，用户点按钮永远失败 |
void main() {
  Map<String, dynamic> reviewJson({
    Object? id = 'file:grp_1:a.pdf',
    Object? path = 'a.pdf',
    Object? directory = false,
    Object? reason = 'file_too_large',
    Object? fileCount = 1,
    Object? totalBytes = 20 * 1048576,
    Object? samples = const <String>[],
    Object? revision = 'rev1',
    Object? turnId,
    Object? attributionSource,
  }) => {
    'id': id,
    'path': path,
    'directory': directory,
    'reason': reason,
    'file_count': fileCount,
    'total_bytes': totalBytes,
    'samples': samples,
    'revision': revision,
    if (turnId != null) 'turn_id': turnId,
    if (attributionSource != null) 'attribution_source': attributionSource,
  };

  group('WorkspaceSyncReview', () {
    test('解析扫描时归因（turn_id / attribution_source，可选）', () {
      final withAttr = WorkspaceSyncReview.fromJson(
        reviewJson(turnId: 'turn_abc', attributionSource: 'scan_running_turn'),
      );
      expect(withAttr.turnId, 'turn_abc');
      expect(withAttr.attributionSource, 'scan_running_turn');

      // 缺省是常态（并发多轮 / 后台对账 / 用户手动上传时服务端一律留空）。
      final without = WorkspaceSyncReview.fromJson(reviewJson());
      expect(without.turnId, isEmpty);
      expect(without.attributionSource, isEmpty);
    });

    test('解析全部字段（服务端 SyncReview 的 json tag）', () {
      final review = WorkspaceSyncReview.fromJson(
        reviewJson(
          id: 'dir:grp_1:reports',
          path: 'reports',
          directory: true,
          reason: 'too_many_files',
          fileCount: 620,
          totalBytes: 12 * 1048576,
          samples: ['a.md', 'b.md'],
        ),
        groupId: 'grp_1',
      );

      expect(review.id, 'dir:grp_1:reports');
      expect(review.groupId, 'grp_1');
      expect(review.path, 'reports');
      expect(review.directory, isTrue);
      expect(review.reason, WorkspaceSyncReviewReason.tooManyFiles);
      expect(review.fileCount, 620);
      expect(review.samples, ['a.md', 'b.md']);
      expect(review.revision, 'rev1');
    });

    test('四个已知 reason 各自映射到对应枚举', () {
      const cases = {
        'file_too_large': WorkspaceSyncReviewReason.fileTooLarge,
        'too_many_files': WorkspaceSyncReviewReason.tooManyFiles,
        'file_burst': WorkspaceSyncReviewReason.fileBurst,
        'batch_too_large': WorkspaceSyncReviewReason.batchTooLarge,
      };
      for (final entry in cases.entries) {
        expect(
          WorkspaceSyncReviewReason.fromWire(entry.key),
          entry.value,
          reason: '${entry.key} 必须映射到 ${entry.value.name}',
        );
      }
    });

    test('未知 / 缺失 reason 退化为 unknown（不丢弃该项）', () {
      expect(
        WorkspaceSyncReviewReason.fromWire('future_reason'),
        WorkspaceSyncReviewReason.unknown,
      );
      expect(
        WorkspaceSyncReviewReason.fromWire(null),
        WorkspaceSyncReviewReason.unknown,
      );
    });

    test('数值字段允许字符串与数字（服务端换编码不该丢数据）', () {
      final review = WorkspaceSyncReview.fromJson(
        reviewJson(fileCount: '620', totalBytes: 12582912),
      );
      expect(review.fileCount, 620);
      expect(review.totalBytes, 12582912);
    });

    test('体积文案与 webapp 同口径（MB 一位小数）', () {
      final review = WorkspaceSyncReview.fromJson(
        reviewJson(totalBytes: 12 * 1048576),
      );
      expect(review.totalMegabytes, '12.0');
    });

    test('samples 里的空值被过滤（目录级挂起时列表不带空行）', () {
      final review = WorkspaceSyncReview.fromJson(
        reviewJson(samples: ['a.md', '', null]),
      );
      expect(review.samples, ['a.md']);
    });
  });

  group('WorkspaceSyncReviewsPage', () {
    test('enabled=false 与「已启用但为空」是两种状态', () {
      final disabled = WorkspaceSyncReviewsPage.fromJson({
        'enabled': false,
        'items': <Object>[],
      });
      final empty = WorkspaceSyncReviewsPage.fromJson({
        'enabled': true,
        'items': <Object>[],
      });

      expect(disabled.enabled, isFalse);
      expect(empty.enabled, isTrue);
      expect(disabled.items, isEmpty);
      expect(empty.items, isEmpty);
    });

    test('逐项填上 groupId（响应里没有 group_id）', () {
      final page = WorkspaceSyncReviewsPage.fromJson({
        'enabled': true,
        'items': [reviewJson(id: 'r1'), reviewJson(id: 'r2')],
      }, groupId: 'grp_1');

      expect(page.items.map((r) => r.groupId), ['grp_1', 'grp_1']);
    });

    test('items 不是数组时退化为空列表（不抛异常）', () {
      final page = WorkspaceSyncReviewsPage.fromJson({
        'enabled': true,
        'items': 'oops',
      });
      expect(page.items, isEmpty);
    });
  });
}
