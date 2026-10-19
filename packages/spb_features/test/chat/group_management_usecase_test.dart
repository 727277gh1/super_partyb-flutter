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

  group('GroupAction 是穷举的 sealed 家族', () {
    test('每个动作都能被 switch 覆盖（编译期保证，此处运行时确认类型）', () {
      const actions = <GroupAction>[
        RenameGroup('x'),
        ArchiveGroup(),
        UnarchiveGroup(),
        DeleteGroup(),
      ];
      // 穷举 switch：新增动作时这里会编译失败。
      for (final a in actions) {
        final label = switch (a) {
          RenameGroup() => 'rename',
          ArchiveGroup() => 'archive',
          UnarchiveGroup() => 'unarchive',
          DeleteGroup() => 'delete',
        };
        expect(label, isNotEmpty);
      }
    });
  });
}
