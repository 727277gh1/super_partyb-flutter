import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `UfsFileEntry` / `UfsFilePage` 契约测试。
///
/// ## 这个测试防的是什么
///
/// 交付物同步（`docs/deliverable-upload-and-conflict.md`）的正确性建立在这几个
/// 字段的**精确语义**上，而它们全都很容易读错：
///
/// | 字段 | 读错的后果 |
/// |---|---|
/// | `updatedAtRaw` | 用解析后的 `DateTime` 反格式化当游标 → 丢掉纳秒后三位 → 文件每轮重复拉（严格比较时**永久漏掉**） |
/// | `etag` | 空串不归一成 null → `is_unchanged` 的「任一侧缺 etag」分支走不到 |
/// | `deletedAt` | 靠「清单里缺席」推断删除 → 把所有未变化的文件都删掉 |
/// | `isDirectory` | 不过滤 → 把目录当文件下载 |
///
/// `_date` 也**刻意不回退 `now()`**（与 `ChatSearchHit` 同取向）：回退会让
/// 「没有 updated_at」的条目看起来像刚刚更新过，破坏增量语义。
void main() {
  Map<String, dynamic> fileJson({
    Object? id = 'f1',
    Object? path = 'grp_1/reports/a.md',
    Object? size = 100,
    Object? name = 'a.md',
    Object? parentId,
    Object? mimeType = 'text/markdown',
    Object? isDirectory = false,
    Object? etag = 'W/"1"',
    Object? updatedAt = '2026-03-01T00:00:00.123456789Z',
    Object? deletedAt,
    Object? ownerType = 'group',
    Object? ownerId = 'grp_1',
    Object? metadata,
  }) => {
    'id': id,
    'path': path,
    'size': size,
    'name': name,
    'parent_id': parentId,
    'mime_type': mimeType,
    'is_directory': isDirectory,
    'etag': etag,
    'updated_at': updatedAt,
    'created_at': '2026-02-01T00:00:00Z',
    'deleted_at': deletedAt,
    'owner_type': ownerType,
    'owner_id': ownerId,
    'metadata_json': metadata,
  };

  group('UfsFileEntry 基本解析（snake_case）', () {
    test('字段名照抄 UFS（mime_type / is_directory / updated_at）', () {
      final f = UfsFileEntry.fromJson(fileJson());
      expect(f.id, 'f1');
      expect(f.path, 'grp_1/reports/a.md');
      expect(f.size, 100);
      expect(f.name, 'a.md');
      expect(f.mimeType, 'text/markdown');
      expect(f.isDirectory, isFalse);
      expect(f.etag, 'W/"1"');
      expect(f.ownerType, 'group');
      expect(f.ownerId, 'grp_1');
    });

    test('isFile：目录为 false，删除的条目仍算 file', () {
      // 删除的条目也要进同步计划（用于删本地副本），故只排除目录。
      expect(UfsFileEntry.fromJson(fileJson()).isFile, isTrue);
      expect(
        UfsFileEntry.fromJson(fileJson(isDirectory: true)).isFile,
        isFalse,
      );
      expect(
        UfsFileEntry.fromJson(fileJson(deletedAt: '2026-03-02T00:00:00Z'))
            .isFile,
        isTrue,
      );
    });

    test('isDirectory 只认严格 true（字符串不算）', () {
      expect(
        UfsFileEntry.fromJson(fileJson(isDirectory: 'true')).isDirectory,
        isFalse,
      );
      expect(
        UfsFileEntry.fromJson(fileJson(isDirectory: 1)).isDirectory,
        isFalse,
      );
    });

    test('size 是字符串也归一成 int', () {
      expect(UfsFileEntry.fromJson(fileJson(size: '250')).size, 250);
      expect(UfsFileEntry.fromJson(fileJson(size: 250.0)).size, 250);
    });
  });

  group('updatedAtRaw：游标必须用原始字符串', () {
    test('原始串保留纳秒精度（不与解析后的 DateTime 等价）', () {
      // 服务端 Go time.Time 序列化为 RFC3339 纳秒精度；Dart DateTime 只到微秒。
      // 解析再格式化会丢后三位 → 游标比服务端原值小 → 重复拉（或严格比较时漏掉）。
      const raw = '2026-03-01T00:00:00.123456789Z';
      final f = UfsFileEntry.fromJson(fileJson(updatedAt: raw));

      expect(f.updatedAtRaw, raw, reason: '游标必须保留服务端原值');
      // 解析后的 DateTime 精度更低——证明两者不可互推。
      expect(
        f.updatedAt!.toUtc().toIso8601String(),
        isNot(contains('123456789')),
        reason: 'DateTime 只到微秒，故不能反格式化当游标',
      );
    });

    test('updatedAtRaw 空串 → null（omitempty 归一）', () {
      final f = UfsFileEntry.fromJson(fileJson(updatedAt: ''));
      expect(f.updatedAtRaw, isNull);
      expect(f.updatedAt, isNull);
    });
  });

  group('etag / deletedAt：同步语义的关键', () {
    test('etag 空串归一成 null（不是「存在但为空」）', () {
      // 不归一会出现「etag 存在但是空」这种需要特判的中间状态。
      expect(UfsFileEntry.fromJson(fileJson(etag: '')).etag, isNull);
      expect(UfsFileEntry.fromJson(fileJson(etag: null)).etag, isNull);
      expect(UfsFileEntry.fromJson(fileJson(etag: 'abc')).etag, 'abc');
    });

    test('deletedAt 非 null 即判 isDeleted（远端软删除）', () {
      expect(UfsFileEntry.fromJson(fileJson()).isDeleted, isFalse);
      final d = UfsFileEntry.fromJson(
        fileJson(deletedAt: '2026-03-02T10:00:00Z'),
      );
      expect(d.isDeleted, isTrue);
      expect(d.deletedAt, DateTime.parse('2026-03-02T10:00:00Z').toLocal());
    });

    test('deleted_at 空串（服务端 iso 对零值产空串）→ 不判删除', () {
      final f = UfsFileEntry.fromJson(fileJson(deletedAt: ''));
      expect(f.deletedAt, isNull);
      expect(f.isDeleted, isFalse);
    });
  });

  group('缺字段 / 类型漂移：不抛，回安全默认值', () {
    test('全空对象', () {
      final f = UfsFileEntry.fromJson(const {});
      expect(f.id, '');
      expect(f.path, '');
      expect(f.size, 0);
      expect(f.isDirectory, isFalse);
      expect(f.etag, isNull);
      expect(f.updatedAt, isNull);
      expect(f.deletedAt, isNull);
      expect(f.isDeleted, isFalse);
    });

    test('updated_at 非法时不回退 now()（否则破坏增量语义）', () {
      final f = UfsFileEntry.fromJson(fileJson(updatedAt: 'not-a-date'));
      expect(f.updatedAt, isNull);
    });

    test('metadata_json 对象保留；非对象归一成 null', () {
      expect(
        UfsFileEntry.fromJson(fileJson(metadata: {'sync': true}))
            .metadata?['sync'],
        isTrue,
      );
      expect(UfsFileEntry.fromJson(fileJson(metadata: 'x')).metadata, isNull);
    });

    test('raw 保留原始响应', () {
      final f = UfsFileEntry.fromJson(fileJson()..['future'] = 1);
      expect(f.raw['future'], 1);
    });
  });

  group('UfsFilePage（{items,total}，不是 next_cursor）', () {
    test('解析 items 与 total（total 不能丢）', () {
      final p = UfsFilePage.fromJson({
        'items': [fileJson(id: 'f1'), fileJson(id: 'f2')],
        'total': 10,
      });
      expect(p.items.map((e) => e.id), ['f1', 'f2']);
      expect(p.total, 10);
      expect(p.isEmpty, isFalse);
    });

    test('hasMore 按 total 算（不是 items.length == pageSize 的脆弱推断）', () {
      final p = UfsFilePage.fromJson({
        'items': [fileJson()],
        'total': 10,
      });
      expect(p.hasMore(page: 1, pageSize: 5), isTrue); // 5 < 10
      expect(p.hasMore(page: 2, pageSize: 5), isFalse); // 10 < 10 = false
      expect(p.hasMore(page: 0, pageSize: 5), isTrue);
    });

    test('空 items / 非列表 → 空页（不抛）', () {
      expect(UfsFilePage.fromJson(const {'total': 0}).items, isEmpty);
      expect(UfsFilePage.fromJson(const {'items': 'x'}).items, isEmpty);
      expect(UfsFilePage.fromJson(const {'items': 'x'}).total, 0);
    });

    test('items 里非 Map 的元素被跳过（坏行不拖垮整页）', () {
      final p = UfsFilePage.fromJson({
        'items': [fileJson(id: 'ok'), 'garbage', 42, null],
        'total': 4,
      });
      expect(p.items.map((e) => e.id), ['ok']);
    });

    test('total 是字符串也归一', () {
      expect(UfsFilePage.fromJson(const {'total': '7'}).total, 7);
    });
  });
}
