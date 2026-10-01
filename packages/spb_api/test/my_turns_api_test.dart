import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `ChatApi.listMyTurns` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// `/me/turns` 返回的是 `turnToListItem`（`user_turns.go`）的投影：
/// 键名是 `turn_id` / `input_preview` / `derived_source` / `message_count`，
/// **不是** `ChatTurn`（`turnToDict`）的 `id` / `input_text` / `completed_count`。
/// 用错模型解析不会报错——缺失的键走安全默认值，结果是「全空对象」，
/// UI 表现为列表全是空行。
void main() {
  /// `turnToListItem` 的真实输出形状（`internal/server/user_turns.go`）。
  Map<String, dynamic> turnToListItemShape({
    String turnId = 'turn_01HZ',
    String groupId = 'grp_01HZZ',
    String? groupTitle = '测试对话',
    String inputPreview = '帮我看看这个报错',
    String status = 'completed',
    String derivedSource = 'chat',
    String? source = 'direct',
    bool hasError = false,
    int messageCount = 2,
  }) => {
    'turn_id': turnId,
    'group_id': groupId,
    'group_title': groupTitle,
    'input_preview': inputPreview,
    'status': status,
    'derived_source': derivedSource,
    'source': source,
    'created_at': '2024-03-05T08:09:10Z',
    'started_at': '2024-03-05T08:09:10Z',
    'ended_at': '2024-03-05T08:09:30Z',
    'has_error': hasError,
    'message_count': messageCount,
  };

  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });

  group('我的轮次 listMyTurns', () {
    test('走 GET /me/turns 且解析投影字段（不是 ChatTurn 的键名）', () async {
      adapter.onGet(
        '/me/turns',
        (server) => server.reply(200, {
          'items': [turnToListItemShape()],
        }),
        queryParameters: {'limit': 50},
      );

      final turns = await api.listMyTurns();
      expect(turns, hasLength(1));
      final t = turns.single;
      expect(t.turnId, 'turn_01HZ');
      expect(t.groupId, 'grp_01HZZ');
      expect(t.groupTitle, '测试对话');
      expect(t.inputPreview, '帮我看看这个报错');
      expect(t.status, 'completed');
      expect(t.source, TurnSource.chat);
      expect(t.hasError, isFalse);
      expect(t.messageCount, 2);
      expect(t.createdAt, DateTime.parse('2024-03-05T08:09:10Z').toLocal());
    });

    test('过滤参数与 days 透传到 query', () async {
      adapter.onGet(
        '/me/turns',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {
          'limit': 20,
          'days': 30,
          'status': 'completed',
          'source': 'chat',
          'group_id': 'grp_x',
        },
      );

      final turns = await api.listMyTurns(
        limit: 20,
        days: 30,
        status: 'completed',
        source: 'chat',
        groupId: 'grp_x',
      );
      expect(turns, isEmpty);
    });

    test('derived_source 五类来源映射（habit 优先语义由服务端派生）', () async {
      adapter.onGet(
        '/me/turns',
        (server) => server.reply(200, {
          'items': [
            turnToListItemShape(turnId: 't1', derivedSource: 'habit'),
            turnToListItemShape(turnId: 't2', derivedSource: 'mq'),
            turnToListItemShape(turnId: 't3', derivedSource: 'schedule'),
            turnToListItemShape(turnId: 't4', derivedSource: 'tool_agent'),
            // 未知值：向前兼容，落 unknown 不抛。
            turnToListItemShape(turnId: 't5', derivedSource: 'future_kind'),
          ],
        }),
        queryParameters: {'limit': 50},
      );

      final turns = await api.listMyTurns();
      expect(turns.map((t) => t.source).toList(), [
        TurnSource.habit,
        TurnSource.mq,
        TurnSource.schedule,
        TurnSource.toolAgent,
        TurnSource.unknown,
      ]);
    });

    test('4xx 被转成 HttpError 而不是解析成空列表（validateStatus 陷阱）', () async {
      adapter.onGet(
        '/me/turns',
        (server) => server.reply(400, {'error': 'invalid days'}),
        queryParameters: {'limit': 50},
      );

      await expectLater(
        api.listMyTurns(),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });

    test('group_title 为 null（对话已删）时不抛', () async {
      adapter.onGet(
        '/me/turns',
        (server) => server.reply(200, {
          'items': [turnToListItemShape(groupTitle: null, inputPreview: '')],
        }),
        queryParameters: {'limit': 50},
      );

      final turns = await api.listMyTurns();
      expect(turns.single.groupTitle, isNull);
      expect(turns.single.inputPreview, isEmpty);
    });
  });
}
