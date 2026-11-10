import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// `GroupManagementUseCase` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 三个写端点的**响应形状不一致**（这是既有事实，不是笔误）：
///
/// | 端点 | 响应 |
/// |---|---|
/// | `PATCH /chat/groups/:id` | `{"updated": true}` ← **没有** group |
/// | `POST …/archive` / `…/unarchive` | `{"group": {...}, "status": "..."}` |
/// | `DELETE /chat/groups/:id` | `{"deleted": true}` |
///
/// 若照 `ChatGroup.fromJson({"updated": true})` 解析，会得到一个**字段全空的
/// ChatGroup**（`id: ''`、`title: ''`），把它写回列表会让该条目变成空白行。
/// 而 `ChatGroup.fromJson` 的每个字段都有 `?? ''` 兜底，**不会抛异常**——
/// 这类 bug 在 UI 上表现为「改完名之后那一行空白了」，极难定位。
///
/// 故这里显式断言「PATCH 之后拿到的是重新 GET 的权威对象」，把这个陷阱钉成
/// 可执行的回归。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late GroupManagementUseCase useCase;

  /// `groupToDict` 的真实输出形状（`internal/server/chat.go`）。
  Map<String, dynamic> groupJson({
    String id = 'grp_1',
    String title = '原对话',
    String status = 'active',
    String updatedAt = '2024-03-05T08:09:10Z',
  }) => {
    'id': id,
    'user_id': 'usr_1',
    'title': title,
    'status': status,
    'goal': null,
    'metadata': null,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': updatedAt,
  };

  /// ## 为什么叫 chatGroup 而不是 group
  ///
  /// `chatGroup()` 是 test 框架的顶层函数（定义测试分组）。在文件里再定义一个同名
  /// 局部函数会**遮蔽**它，于是所有 `group('...', () {})` 调用都会报
  /// 「Too many positional arguments: 0 allowed」——错误信息指向分组调用处，
  /// 与被改的这行毫无关系，极难定位。
  ChatGroup chatGroup({String id = 'grp_1', String title = '原对话'}) =>
      ChatGroup.fromJson(groupJson(id: id, title: title));

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    useCase = GroupManagementUseCase(api);
  });

  group('重命名', () {
    test('PATCH 只回 {updated:true} 时，补一次 GET 拿权威对象（不是空 group）', () async {
      // PATCH 的真实响应：没有 group 字段。
      adapter.onPatch(
        '/chat/groups/grp_1',
        (server) => server.reply(200, {'updated': true}),
        data: {'title': '新标题'},
      );
      // 权威对象由 GET 提供（含服务端刚更新的 updated_at）。
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(
          200,
          groupJson(title: '新标题', updatedAt: '2024-03-05T09:00:00Z'),
        ),
      );

      final result = await useCase.execute(
        chatGroup(),
        const RenameGroup('新标题'),
      );

      expect(result, isA<GroupActionApplied>());
      final applied = result as GroupActionApplied;
      expect(
        applied.group?.title,
        '新标题',
        reason: '必须来自 GET；若直接用 PATCH 响应会得到 title == "" 的空对象',
      );
      expect(applied.group?.id, 'grp_1');
      // 服务端在 PATCH 时也更新了 updated_at，本地拼对象会漏掉它。
      expect(applied.group?.updatedAt.toUtc().hour, 9);
    });

    test('目标已不存在（404）→ 视为已完成且不带 group（本地应移除该条目）', () async {
      adapter.onPatch(
        '/chat/groups/grp_1',
        (server) => server.reply(404, {'error': 'group not found'}),
        data: {'title': '新标题'},
      );

      final result = await useCase.execute(
        chatGroup(),
        const RenameGroup('新标题'),
      );

      expect(result, isA<GroupActionApplied>());
      expect(
        (result as GroupActionApplied).group,
        isNull,
        reason: '资源已不存在，页面应移除条目而不是显示一条改名失败的记录',
      );
    });
  });

  group('归档 / 取消归档', () {
    test('归档后返回的权威对象 status 为 archived', () async {
      adapter.onPost(
        '/chat/groups/grp_1/archive',
        (server) => server.reply(200, {
          'group': groupJson(status: 'archived'),
          'status': 'archived',
        }),
        data: null,
      );
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(200, groupJson(status: 'archived')),
      );

      final result = await useCase.execute(chatGroup(), const ArchiveGroup());

      expect((result as GroupActionApplied).group?.isArchived, isTrue);
    });

    test('取消归档后 status 回到 active', () async {
      adapter.onPost(
        '/chat/groups/grp_1/unarchive',
        (server) =>
            server.reply(200, {'group': groupJson(), 'status': 'active'}),
        data: null,
      );
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(200, groupJson()),
      );

      final result = await useCase.execute(
        ChatGroup.fromJson(groupJson(status: 'archived')),
        const UnarchiveGroup(),
      );

      expect((result as GroupActionApplied).group?.isArchived, isFalse);
    });
  });

  group('删除', () {
    test('成功后 group 为 null（页面据此移除条目）', () async {
      adapter.onDelete(
        '/chat/groups/grp_1',
        (server) => server.reply(200, {'deleted': true}),
      );

      final result = await useCase.execute(chatGroup(), const DeleteGroup());

      expect(result, isA<GroupActionApplied>());
      expect(
        (result as GroupActionApplied).group,
        isNull,
        reason: '删除成功没有「新状态」可言，null 是「移除本地条目」的信号',
      );
    });

    test('目标已不存在（404）→ 视为已完成（用户想删的东西确实没了）', () async {
      adapter.onDelete(
        '/chat/groups/grp_1',
        (server) => server.reply(404, {'error': 'group not found'}),
      );

      final result = await useCase.execute(chatGroup(), const DeleteGroup());

      expect(
        result,
        isA<GroupActionApplied>(),
        reason: '提示「删除失败」会让用户以为还留着，实际已经没了',
      );
    });
  });

  group('错误分类', () {
    test('403 仍抛异常（操作可能未生效，不能假装成功）', () async {
      adapter.onDelete(
        '/chat/groups/grp_1',
        (server) => server.reply(403, {'error': 'forbidden'}),
      );

      expect(
        () => useCase.execute(chatGroup(), const DeleteGroup()),
        throwsA(isA<AuthError>()),
      );
    });

    test('500 仍抛异常（服务端故障，不是业务拒绝）', () async {
      adapter.onDelete(
        '/chat/groups/grp_1',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      expect(
        () => useCase.execute(chatGroup(), const DeleteGroup()),
        throwsA(isA<HttpError>()),
      );
    });

    test('网络错误抛 NetworkError', () async {
      adapter.onDelete(
        '/chat/groups/grp_1',
        (server) => server.throws(
          0,
          DioException(
            requestOptions: RequestOptions(path: '/chat/groups/grp_1'),
            type: DioExceptionType.connectionError,
          ),
        ),
      );

      expect(
        () => useCase.execute(chatGroup(), const DeleteGroup()),
        throwsA(isA<NetworkError>()),
      );
    });
  });

  group('归档结项快照', () {
    /// 带快照的 group JSON（Go `groupRowToDict` + `archive_snapshot`）。
    Map<String, dynamic> archivedGroupJson({
      String snapshotStatus = 'ready',
      bool downloadAvailable = true,
    }) => {
      ...groupJson(status: 'archived'),
      'archive_snapshot': {
        'id': 'snap_1',
        'version': 2,
        'status': snapshotStatus,
        'archive_reason': 'explicit',
        'summary': '做完了',
        'created_at': '2024-03-05T08:09:00Z',
        'download_available': downloadAvailable,
        'site': {
          'status': 'ready',
          'slug': 'g-grp_1',
          'access_url': '/ufs_sites/g-grp_1/',
        },
        'links': {
          'markdown': '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
          'html': '/chat/groups/grp_1/archive-snapshots/snap_1/html',
        },
      },
    };

    ChatGroup archivedGroup() => ChatGroup.fromJson(archivedGroupJson());

    test('下载 markdown：走 bytes 端点，文件名用标题+版本而不是短 id', () async {
      // ⚠️ 这个测试**不能**断言字节的精确内容。
      //
      // `http_mock_adapter` 会把响应体统一按 JSON 编码：给 `List<int>` 得到
      // `[35,32,...]` 这段文本的字节（首字节 91 = '['），给 `String` 得到带
      // 引号的 `"# title"`。两种都不是服务端 `c.Data(200, ..., []byte)` 的
      // 真实行为。故这里只断言「拿到了非空字节 + 走对了端点 + 文件名正确」，
      // 字节保真度由 `ResponseType.bytes` 这个选项本身保证（见
      // `ChatApi._downloadSnapshot` 的注释与 `downloadArtifact` 的同类实现）。
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
        (server) => server.reply(200, '# title'),
      );

      final result = await useCase.execute(
        archivedGroup(),
        const DownloadSnapshot('snap_1', 'markdown'),
      );

      expect(result, isA<SnapshotDownloaded>());
      final d = result as SnapshotDownloaded;
      expect(d.bytes, isNotEmpty);
      expect(d.format, 'markdown');
      // 文件名含标题与版本，不含 group id 前 8 位那种对用户无意义的短 id。
      expect(d.suggestedFileName, 'archive-原对话-v2.md');
    });

    test('下载 html：扩展名是 html，走 html 端点', () async {
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/html',
        (server) => server.reply(200, '<html>'),
      );

      final result = await useCase.execute(
        archivedGroup(),
        const DownloadSnapshot('snap_1', 'html'),
      );

      expect(result, isA<SnapshotDownloaded>());
      expect(
        (result as SnapshotDownloaded).suggestedFileName,
        endsWith('.html'),
      );
      expect((result).bytes, isNotEmpty);
    });

    test('下载不 reload 列表：成功结果不是 GroupActionApplied', () async {
      // 这条守着「下载顺手刷新列表」的误实现——那会多一次 GET，
      // 且让调用方以为服务端状态变了。
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
        (server) => server.reply(200, 'A'),
      );
      final result = await useCase.execute(
        archivedGroup(),
        const DownloadSnapshot('snap_1', 'markdown'),
      );
      expect(result, isNot(isA<GroupActionApplied>()));
    });

    test('快照未 ready 时下载 → 409 转成 HttpError（不是业务拒绝）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
        (server) => server.reply(409, {'error': 'snapshot not ready'}),
      );

      expect(
        () => useCase.execute(
          archivedGroup(),
          const DownloadSnapshot('snap_1', 'markdown'),
        ),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 409),
        ),
      );
    });

    test('UFS 侧文件已删 → 410 也是 HttpError', () async {
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/html',
        (server) => server.reply(410, {'error': 'gone'}),
      );
      expect(
        () => useCase.execute(
          archivedGroup(),
          const DownloadSnapshot('snap_1', 'html'),
        ),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 410),
        ),
      );
    });

    test('重部署返回 pending → 是成功结果且标记为 pending（不是失败）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/archive-snapshots/snap_1/site/redeploy',
        (server) =>
            server.reply(200, {'site_id': 'site_1', 'site_status': 'pending'}),
        data: null,
      );

      final result = await useCase.execute(
        archivedGroup(),
        const RedeploySnapshotSite('snap_1'),
      );

      expect(result, isA<SnapshotSiteActionApplied>());
      final r = (result as SnapshotSiteActionApplied).result;
      expect(r.isPending, isTrue);
      expect(r.isReady, isFalse);
    });

    test('重部署把站点打回 none（UFS 侧丢了）→ 同样是成功结果', () async {
      adapter.onPost(
        '/chat/groups/grp_1/archive-snapshots/snap_1/site/redeploy',
        (server) => server.reply(200, {'site_status': 'none'}),
        data: null,
      );
      final result = await useCase.execute(
        archivedGroup(),
        const RedeploySnapshotSite('snap_1'),
      );
      expect((result as SnapshotSiteActionApplied).result.isReset, isTrue);
    });

    test('发布返回 ready + production', () async {
      adapter.onPost(
        '/chat/groups/grp_1/archive-snapshots/snap_1/site/publish',
        (server) => server.reply(200, {
          'site_id': 'site_1',
          'site_status': 'ready',
          'environment': 'production',
          'access_url': 'https://app.example.com/ufs_sites/g-grp_1/',
        }),
        data: null,
      );

      final result = await useCase.execute(
        archivedGroup(),
        const PublishSnapshotSite('snap_1'),
      );

      final r = (result as SnapshotSiteActionApplied).result;
      expect(r.isReady, isTrue);
      expect(r.environment, 'production');
      expect(r.accessUrl, contains('ufs_sites'));
    });

    test('站点动作 409（快照未 ready）→ HttpError，不当成功', () async {
      adapter.onPost(
        '/chat/groups/grp_1/archive-snapshots/snap_1/site/publish',
        (server) => server.reply(409, {'error': 'snapshot not ready'}),
        data: null,
      );
      expect(
        () => useCase.execute(
          archivedGroup(),
          const PublishSnapshotSite('snap_1'),
        ),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 409),
        ),
      );
    });

    test('标题含路径分隔符时文件名被清洗', () async {
      adapter.onGet(
        '/chat/groups/grp_1/archive-snapshots/snap_1/markdown',
        (server) => server.reply(200, 'A'),
      );
      final group = ChatGroup.fromJson({
        ...archivedGroupJson(),
        'title': 'a/b:c*d',
      });
      final result = await useCase.execute(
        group,
        const DownloadSnapshot('snap_1', 'markdown'),
      );
      final name = (result as SnapshotDownloaded).suggestedFileName;
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
      expect(name, endsWith('.md'));
    });
  });

  group('GroupAction 是穷举的 sealed 家族', () {
    test('每个动作都能被 switch 覆盖（编译期保证，此处运行时确认类型）', () {
      const actions = <GroupAction>[
        RenameGroup('x'),
        ArchiveGroup(),
        UnarchiveGroup(),
        DeleteGroup(),
        DownloadSnapshot('snap_1', 'markdown'),
        RedeploySnapshotSite('snap_1'),
        PublishSnapshotSite('snap_1'),
      ];
      // 穷举 switch：新增动作时这里会编译失败。
      for (final a in actions) {
        final label = switch (a) {
          RenameGroup() => 'rename',
          ArchiveGroup() => 'archive',
          UnarchiveGroup() => 'unarchive',
          DeleteGroup() => 'delete',
          DownloadSnapshot() => 'download',
          RedeploySnapshotSite() => 'redeploy',
          PublishSnapshotSite() => 'publish',
        };
        expect(label, isNotEmpty);
      }
    });
  });
}
