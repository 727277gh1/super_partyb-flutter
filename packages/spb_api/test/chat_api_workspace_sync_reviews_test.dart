import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_api_harness.dart';

/// `ChatApi` 的 **groupsync 待确认同步项**契约测试。
///
/// ## 这个测试防的是什么
///
/// 这条链路有三处「静默」的失败模式（都不报错、不抛异常，只是数据不对）：
///
/// 1. **路径多一级 `/api`**：reviews 挂在 `r.Group("/chat")`（`router.go:173` →
///    `chat_ext.go:103`），不是 `/api/chat/*`。拼错只 404，而 mock 适配器按
///    注册路径匹配，写错的断言照样「通过」——故这里真起一次 server 验证路径。
/// 2. **`enabled: false` 被当成「没有待确认项」**：worker 未启用时端点恒 200
///    + 空 items。把它当空列表，用户就永远看不到「文件被挂起」这件事。
/// 3. **`revision` 丢失**：resolve 缺 revision 服务端回 400；而客户端若把
///    409（快照已变）当成网络错误重试，会永远失败。
void main() {
  setUpHarness();

  Map<String, dynamic> reviewShape({
    String id = 'dir:grp_1:reports',
    String path = 'reports',
    bool directory = true,
    String reason = 'too_many_files',
    int fileCount = 620,
    int totalBytes = 12 * 1048576,
    List<String> samples = const ['a.md', 'b.md'],
    String revision = 'rev1',
  }) => {
    'id': id,
    'path': path,
    'directory': directory,
    'reason': reason,
    'file_count': fileCount,
    'total_bytes': totalBytes,
    'samples': samples,
    'revision': revision,
  };

  group('listWorkspaceSyncReviews', () {
    test('解析 enabled + items，并填上 groupId', () async {
      adapter.onGet(
        '/chat/groups/grp_1/workspace-sync/reviews',
        (server) => server.reply(200, {
          'enabled': true,
          'items': [reviewShape()],
        }),
      );

      final page = await api.listWorkspaceSyncReviews('grp_1');

      expect(page.enabled, isTrue);
      expect(page.items, hasLength(1));
      final rev = page.items.single;
      // 服务端响应里没有 group_id，聚合/resolve 都靠客户端填的这一份。
      expect(rev.groupId, 'grp_1');
      expect(rev.path, 'reports');
      expect(rev.directory, isTrue);
      expect(rev.reason, WorkspaceSyncReviewReason.tooManyFiles);
      expect(rev.fileCount, 620);
      expect(rev.totalBytes, 12 * 1048576);
      expect(rev.samples, ['a.md', 'b.md']);
      expect(rev.revision, 'rev1');
    });

    test('enabled=false 必须如实回传（不是「空列表」）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/workspace-sync/reviews',
        (server) => server.reply(200, {'enabled': false, 'items': <Object>[]}),
      );

      final page = await api.listWorkspaceSyncReviews('grp_1');

      expect(page.enabled, isFalse);
      expect(page.items, isEmpty);
    });

    test('未知 reason 不丢弃该项（退化为 unknown）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/workspace-sync/reviews',
        (server) => server.reply(200, {
          'enabled': true,
          'items': [reviewShape(reason: 'future_reason_from_server')],
        }),
      );

      final page = await api.listWorkspaceSyncReviews('grp_1');

      expect(page.items.single.reason, WorkspaceSyncReviewReason.unknown);
    });

    test('响应形状漂移（缺 items）时抛 ParseError 而不是静默空列表', () async {
      adapter.onGet(
        '/chat/groups/grp_1/workspace-sync/reviews',
        (server) => server.reply(200, <Object>[]),
      );

      expect(
        api.listWorkspaceSyncReviews('grp_1'),
        throwsA(isA<ParseError>()),
        reason: '返回数组而不是 {enabled, items} 属于契约漂移',
      );
    });
  });

  group('resolveWorkspaceSyncReview', () {
    test('提交 id + revision + action', () async {
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/reviews/resolve',
        data: {'id': 'dir:grp_1:reports', 'revision': 'rev1', 'action': 'sync'},
        (server) => server.reply(200, {'status': 'accepted'}),
      );

      await api.resolveWorkspaceSyncReview(
        groupId: 'grp_1',
        reviewId: 'dir:grp_1:reports',
        revision: 'rev1',
        action: WorkspaceSyncReviewAction.sync,
      );
    });

    test('409 映射成 isConflict（调用方据此刷新列表，而不是重试）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/reviews/resolve',
        data: {
          'id': 'dir:grp_1:reports',
          'revision': 'stale',
          'action': 'ignore',
        },
        (server) => server.reply(409, {'error': '待处理文件已变化，请刷新后重试'}),
      );

      await expectLater(
        api.resolveWorkspaceSyncReview(
          groupId: 'grp_1',
          reviewId: 'dir:grp_1:reports',
          revision: 'stale',
          action: WorkspaceSyncReviewAction.ignore,
        ),
        throwsA(
          isA<HttpError>().having((e) => e.isConflict, 'isConflict', isTrue),
        ),
      );
    });

    test('503（worker 未启用）不是可重试的网络错误，原样抛 HttpError', () async {
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/reviews/resolve',
        data: {'id': 'file:grp_1:a.pdf', 'revision': 'rev1', 'action': 'sync'},
        (server) => server.reply(503, {'error': '文件同步未启用'}),
      );

      await expectLater(
        api.resolveWorkspaceSyncReview(
          groupId: 'grp_1',
          reviewId: 'file:grp_1:a.pdf',
          revision: 'rev1',
          action: WorkspaceSyncReviewAction.sync,
        ),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });
  });

  /// 真实路径验证：mock 适配器只按注册路径匹配，拼错的路径**照样通过**。
  group('真实请求路径', () {
    late HttpServer server;
    late ChatApi realApi;
    late List<({String method, String path})> received;

    setUp(() async {
      received = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      realApi = ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
      server.listen((req) async {
        received.add((method: req.method, path: req.uri.path));
        // 必须先读完请求体，否则客户端会看到连接被重置。
        await req.drain<void>();
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"enabled":true,"items":[],"status":"accepted"}');
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('reviews 与 resolve 都在 /chat 前缀下（不是 /api/chat）', () async {
      await realApi.listWorkspaceSyncReviews('grp_1');
      await realApi.resolveWorkspaceSyncReview(
        groupId: 'grp_1',
        reviewId: 'r1',
        revision: 'rev1',
        action: WorkspaceSyncReviewAction.sync,
      );

      expect(received, [
        (method: 'GET', path: '/chat/groups/grp_1/workspace-sync/reviews'),
        (
          method: 'POST',
          path: '/chat/groups/grp_1/workspace-sync/reviews/resolve',
        ),
      ]);
    });
  });
}
