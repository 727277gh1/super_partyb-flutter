import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `MemoryApi` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 1. **路径**：`/api/memories`（不是 `/open/memories`，那是 API Key 面）。
/// 2. **4xx 不抛 `DioException`**：`createDio` 的 `validateStatus` 放行 4xx，
///    故 `archiveMemory`（`Future<void>`）若不显式查状态码，「归档别人的记忆
///    得到的 404」会被当成功——UI 从列表移走条目，服务端从未归档。
/// 3. **过滤参数只在非 unknown 时发送**：把 `unknown`（wire 为空串）发上去
///    会被服务端当成过滤条件 `status=''`，结果静默返回空列表。
/// 4. **PATCH 是增量语义**：空补丁是调用方的编程错误（多一次无意义往返）。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late MemoryApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = MemoryApi(dio);
  });

  Map<String, dynamic> row({
    String id = 'mem_1',
    String status = 'active',
    String category = 'preference',
  }) => {
    'id': id,
    'userId': 'usr_1',
    'category': category,
    'topicKey': 'reply-language',
    'topicId': 'topic_1',
    'content': '偏好中文回复',
    'contentJson': {'String': '{}', 'Valid': true},
    'sourceGroupId': {'String': 'grp_1', 'Valid': true},
    'sourceTurnId': {'String': 'turn_1', 'Valid': true},
    'confidence': 0.8,
    'learnedFromTurns': 2,
    'status': status,
    'lastReinforcedAt': {'Time': '2026-11-20T10:00:00Z', 'Valid': true},
    'createdAt': '2026-11-01T08:00:00Z',
    'updatedAt': '2026-11-20T10:00:00Z',
  };

  group('listMemories', () {
    test('打 /api/memories，带 limit/offset 且不发送 unknown 过滤值', () async {
      adapter.onGet(
        '/api/memories',
        (server) => server.reply(200, {
          'items': [row()],
        }),
        queryParameters: {'limit': 200, 'offset': 0},
      );

      final items = await api.listMemories();
      expect(items, hasLength(1));
      expect(items.single.content, '偏好中文回复');
      expect(items.single.sourceGroupId, 'grp_1');
    });

    test('status / category 过滤按 wire 值发送', () async {
      adapter.onGet(
        '/api/memories',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {
          'status': 'archived',
          'category': 'fact',
          'limit': 200,
          'offset': 0,
        },
      );

      final items = await api.listMemories(
        status: UserMemoryStatus.archived,
        category: UserMemoryCategory.fact,
      );
      expect(items, isEmpty);
    });

    test('unknown 枚举不发送（否则服务端按空串过滤 → 恒返空）', () async {
      adapter.onGet(
        '/api/memories',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 200, 'offset': 0},
      );

      await api.listMemories(
        status: UserMemoryStatus.unknown,
        category: UserMemoryCategory.unknown,
      );
    });

    test('分页参数按调用方传入（页大小 + 下一页 offset）', () async {
      adapter.onGet(
        '/api/memories',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 100, 'offset': 100},
      );

      await api.listMemories(limit: 100, offset: 100);
    });

    test('{items: [...]} 外壳被拆开，直接返回数组的响也同样兼容', () async {
      adapter.onGet(
        '/api/memories',
        (server) => server.reply(200, [row(id: 'mem_2')]),
        queryParameters: {'limit': 200, 'offset': 0},
      );

      final items = await api.listMemories();
      expect(items.single.id, 'mem_2');
    });
  });

  group('updateMemory', () {
    test('PATCH /api/memories/:id，只发传入的字段，返回权威对象', () async {
      adapter.onPatch(
        '/api/memories/mem_1',
        (server) => server.reply(200, row(status: 'archived')),
        data: {'status': 'archived'},
      );

      final updated = await api.updateMemory(
        'mem_1',
        status: UserMemoryStatus.archived,
      );
      expect(updated.status, UserMemoryStatus.archived);
      expect(updated.content, '偏好中文回复');
    });

    test('内容 + 分类 + 状态一起改', () async {
      adapter.onPatch(
        '/api/memories/mem_1',
        (server) => server.reply(200, row(category: 'fact')),
        data: {'content': '住在杭州', 'category': 'fact', 'status': 'active'},
      );

      final updated = await api.updateMemory(
        'mem_1',
        content: '住在杭州',
        category: UserMemoryCategory.fact,
        status: UserMemoryStatus.active,
      );
      expect(updated.category, UserMemoryCategory.fact);
    });

    test('空补丁直接拒绝（不到服务端）', () async {
      expect(() => api.updateMemory('mem_1'), throwsA(isA<ArgumentError>()));
    });

    test('404 抛 HttpError 而不是静默返回', () async {
      adapter.onPatch(
        '/api/memories/mem_missing',
        (server) => server.reply(404, {'error': '记忆不存在'}),
        data: {'content': 'x'},
      );

      await expectLater(
        api.updateMemory('mem_missing', content: 'x'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', '记忆不存在'),
        ),
      );
    });
  });

  group('archiveMemory', () {
    test('DELETE /api/memories/:id（软删 = 归档）', () async {
      adapter.onDelete(
        '/api/memories/mem_1',
        (server) => server.reply(200, {'id': 'mem_1', 'status': 'archived'}),
      );

      await api.archiveMemory('mem_1');
    });

    test('非本人 / 不存在 → 404 必须抛错（不能当成已归档）', () async {
      adapter.onDelete(
        '/api/memories/mem_other',
        (server) => server.reply(404, {'error': '记忆不存在'}),
      );

      await expectLater(
        api.archiveMemory('mem_other'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });
  });
}
