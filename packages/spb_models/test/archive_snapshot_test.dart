import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 归档结项快照模型的契约测试。
///
/// 守三条线：
/// 1. `fromJson` 对 Go DTO 的真实形状解析正确（含 `site` 始终存在）；
/// 2. `toJson` 与 `fromJson` **逐字对称**（本地缓存 round-trip 不丢字段）；
/// 3. 状态判定的边界（pending/failed 没有链接、ready 才有）。
void main() {
  /// Go `archiveSnapshotDTO` 的真实输出（字段名照抄，勿"美化"成 camelCase）。
  Map<String, dynamic> readyJson() => {
    'id': 'snap_1',
    'version': 3,
    'status': 'ready',
    'archive_reason': 'explicit',
    'summary': '前三章已完成，第四章节纲待定',
    'created_at': '2024-03-05T08:09:00Z',
    'download_available': true,
    'site': {
      'status': 'ready',
      'slug': 'g-grp_1',
      'access_url': '/_staging/ufs_sites/g-grp_1/',
    },
    'links': {
      'markdown': '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
      'html': '/chat/groups/grp_1/archive-snapshots/snap_1/html',
    },
  };

  group('ArchiveSnapshot.fromJson', () {
    test('ready 快照：所有字段正确解析', () {
      final s = ArchiveSnapshot.fromJson(readyJson());
      expect(s.id, 'snap_1');
      expect(s.version, 3);
      expect(s.status, 'ready');
      expect(s.archiveReason, 'explicit');
      expect(s.summary, '前三章已完成，第四章节纲待定');
      expect(s.createdAt, DateTime.utc(2024, 3, 5, 8, 9).toLocal());
      expect(s.downloadAvailable, isTrue);
      expect(s.site.status, 'ready');
      expect(s.site.slug, 'g-grp_1');
      expect(s.site.accessUrl, '/_staging/ufs_sites/g-grp_1/');
      expect(s.links?.markdown, contains('/markdown'));
      expect(s.links?.html, contains('/html'));
      expect(s.isReady, isTrue);
      expect(s.hasDownloadLink, isTrue);
    });

    test('pending 快照：没有 links，download_available 为 false', () {
      final s = ArchiveSnapshot.fromJson({
        'id': 'snap_2',
        'version': 1,
        'status': 'pending',
        'archive_reason': 'explicit',
        'summary': null,
        'created_at': '2024-03-05T08:00:00Z',
        'download_available': false,
        'site': {'status': 'none', 'slug': null, 'access_url': null},
      });
      expect(s.isPending, isTrue);
      expect(s.summary, isNull);
      expect(s.downloadAvailable, isFalse);
      // links 键不存在 → null（不是空对象）。
      expect(s.links, isNull);
      expect(s.hasDownloadLink, isFalse);
      expect(s.site.isNone, isTrue);
      expect(s.site.isOpenable, isFalse);
    });

    test('site 子对象缺失时降级成 status=none（不抛异常）', () {
      // 服务端保证 site 始终存在，但客户端不该因此崩在旧服务端上。
      final s = ArchiveSnapshot.fromJson({
        'id': 'snap_3',
        'version': 1,
        'status': 'failed',
        'archive_reason': 'completed',
      });
      expect(s.site.status, 'none');
      expect(s.isFailed, isTrue);
      expect(s.downloadAvailable, isFalse);
    });

    test('只有 markdown 时 links 仍非空（html 渲染失败是常见组合）', () {
      final s = ArchiveSnapshot.fromJson({
        ...readyJson(),
        'links': {'markdown': '/chat/groups/g/archive-snapshots/s/markdown'},
      });
      expect(s.links?.markdown, isNotNull);
      expect(s.links?.html, isNull);
      expect(s.hasDownloadLink, isTrue);
    });

    test('空 links 对象归一成 null（调用方只需判一次空）', () {
      final s = ArchiveSnapshot.fromJson({
        ...readyJson(),
        'links': <String, dynamic>{},
      });
      expect(s.links, isNull);
    });

    test('download_available 读后端推导值，不在客户端重新计算', () {
      // 故意造一个「矛盾」组合：status=ready 但后端说不可下载。
      // 客户端必须以服务端为准——它才是知道 file id 有没有的那一端。
      final s = ArchiveSnapshot.fromJson({
        ...readyJson(),
        'download_available': false,
      });
      expect(s.isReady, isTrue);
      expect(s.downloadAvailable, isFalse);
    });
  });

  group('ArchiveSnapshot.toJson（本地缓存 round-trip）', () {
    test('全字段 round-trip 不丢字段', () {
      final original = ArchiveSnapshot.fromJson(readyJson());
      final back = ArchiveSnapshot.fromJson(original.toJson());

      expect(back.id, original.id);
      expect(back.version, original.version);
      expect(back.status, original.status);
      expect(back.archiveReason, original.archiveReason);
      expect(back.summary, original.summary);
      expect(back.createdAt, original.createdAt);
      expect(back.downloadAvailable, original.downloadAvailable);
      expect(back.site.status, original.site.status);
      expect(back.site.slug, original.site.slug);
      expect(back.site.accessUrl, original.site.accessUrl);
      expect(back.links?.markdown, original.links?.markdown);
      expect(back.links?.html, original.links?.html);
    });

    test('toJson 的键名是 snake_case（与 Go DTO 一致）', () {
      final json = ArchiveSnapshot.fromJson(readyJson()).toJson();
      // 这条守着「有人把 toJson 写成 camelCase」：那样缓存能写进去，
      // 读回来 fromJson 找不到键 → 字段全丢，且**不报错**。
      expect(json.containsKey('archive_reason'), isTrue);
      expect(json.containsKey('archiveReason'), isFalse);
      expect(json.containsKey('download_available'), isTrue);
      expect(json.containsKey('downloadAvailable'), isFalse);
      expect(json.containsKey('created_at'), isTrue);
      expect(json.containsKey('createdAt'), isFalse);
      final site = json['site'] as Map<String, dynamic>;
      expect(site.containsKey('access_url'), isTrue);
      expect(site.containsKey('accessUrl'), isFalse);
    });

    test('null 可选字段不写键（读回仍是 null，不变空串）', () {
      final s = ArchiveSnapshot.fromJson({
        'id': 'snap_4',
        'version': 1,
        'status': 'pending',
        'archive_reason': 'explicit',
        'download_available': false,
        'site': {'status': 'none'},
      });
      final json = s.toJson();
      expect(json.containsKey('summary'), isFalse);
      expect(json.containsKey('created_at'), isFalse);
      expect(json.containsKey('links'), isFalse);
      final site = json['site']! as Map<String, dynamic>;
      expect(site.containsKey('slug'), isFalse);
      expect(site.containsKey('access_url'), isFalse);

      final back = ArchiveSnapshot.fromJson(json);
      expect(back.summary, isNull);
      expect(back.createdAt, isNull);
      expect(back.links, isNull);
      expect(back.site.slug, isNull);
      expect(back.site.accessUrl, isNull);
    });
  });

  group('ArchiveSnapshotSite 判定', () {
    test('isOpenable 要求 ready 且有非空 URL', () {
      const ready = ArchiveSnapshotSite(
        status: 'ready',
        slug: 'g-1',
        accessUrl: '/ufs_sites/g-1/',
      );
      expect(ready.isOpenable, isTrue);

      const noUrl = ArchiveSnapshotSite(status: 'ready', slug: 'g-1');
      expect(noUrl.isOpenable, isFalse);

      const emptyUrl = ArchiveSnapshotSite(status: 'ready', accessUrl: '');
      expect(emptyUrl.isOpenable, isFalse);

      const pending = ArchiveSnapshotSite(
        status: 'pending',
        accessUrl: '/ufs_sites/g-1/',
      );
      expect(pending.isOpenable, isFalse);
    });

    test('相对路径原样保留（拼 origin 是调用方的事）', () {
      final s = ArchiveSnapshotSite.fromJson({
        'status': 'ready',
        'access_url': '/_staging/ufs_sites/g-1/',
      });
      // 不在这里补域名：同一份客户端也连测试/预发环境。
      expect(s.accessUrl, '/_staging/ufs_sites/g-1/');
      expect(s.accessUrl, isNot(contains('http')));
    });
  });

  group('ArchiveSnapshotSiteAction', () {
    test('ready 响应带 access_url 与 environment', () {
      final a = ArchiveSnapshotSiteAction.fromJson({
        'site_id': 'site_1',
        'site_status': 'ready',
        'access_url': 'https://example.test/ufs_sites/g-1/',
        'environment': 'production',
      });
      expect(a.isReady, isTrue);
      expect(a.siteId, 'site_1');
      expect(a.accessUrl, contains('ufs_sites'));
      expect(a.environment, 'production');
    });

    test('pending 是 202 语义，不是错误', () {
      final a = ArchiveSnapshotSiteAction.fromJson({
        'site_id': 'site_1',
        'site_status': 'pending',
      });
      expect(a.isReady, isFalse);
      expect(a.isPending, isTrue);
      expect(a.isReset, isFalse);
    });

    test('none 表示站点已重置待重建（同样不是错误）', () {
      final a = ArchiveSnapshotSiteAction.fromJson({'site_status': 'none'});
      expect(a.isReset, isTrue);
      expect(a.isPending, isFalse);
    });
  });
}
