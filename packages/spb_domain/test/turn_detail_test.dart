import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// `LoadTurnDetailUseCase` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 上游 `GET /chat/turns/:id` **不返回 events**（`super_partyb#56`），故详情要
/// 自己凑：`getTurn` 拿 meta + `groupTimeline` 按 turnId 过滤拿事件。这里有三个
/// 不会报错的坑：
///
/// 1. **过滤丢 turnId**：`groupTimeline` 是群级端点，返回**全群**事件。不过滤
///    就会把别的轮次的事件也渲染进这一轮的详情页。
/// 2. **不翻页**：目标 turn 的事件可能已被挤出首页窗口——单页过滤得到空列表，
///    表现为「详情页什么都没有」而真相是「没翻到」。
/// 3. **不排序**：timeline 给的是 `global_seq` 倒序，而详情页要 per-turn `seq`
///    升序；不排会让用户看到「回复在思考之前」。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });

  Map<String, dynamic> turnShape({
    String id = 'turn_1',
    String groupId = 'grp_1',
    String inputText = '帮我看一下这个报错',
    String status = 'completed',
  }) => {
    'id': id,
    'group_id': groupId,
    'user_id': 'usr_1',
    'input_text': inputText,
    'status': status,
    'fanout_count': 1,
    'completed_count': 2,
    'error_count': 0,
    'created_at': '2024-03-05T12:00:00Z',
  };

  Map<String, dynamic> eventShape({
    required String eventId,
    required String turnId,
    String eventType = 'message',
    int seq = 1,
    int globalSeq = 1,
    String? text,
  }) => {
    'eventId': eventId,
    'userId': 'usr_1',
    'groupId': 'grp_1',
    'turnId': turnId,
    'eventType': eventType,
    'seq': seq,
    'globalSeq': globalSeq,
    'source': 'agent',
    'createdAt': '2024-03-05T12:00:0${seq % 10}Z',
    if (text != null) 'payload': {'text': text},
  };

  void mockGetTurn({String turnId = 'turn_1', Map<String, dynamic>? body}) {
    adapter.onGet(
      '/chat/turns/$turnId',
      (server) => server.reply(200, body ?? turnShape(id: turnId)),
    );
  }

  void mockTimeline({
    required List<Map<String, dynamic>> items,
    String? cursor,
    String? beforeGlobalSeq,
    int limit = 200,
  }) {
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': items,
        'next_before_global_seq': cursor ?? '',
      }),
      queryParameters: {
        'limit': limit,
        if (beforeGlobalSeq != null) 'before_global_seq': beforeGlobalSeq,
      },
    );
  }

  test('返回 meta + 该 turn 的事件', () async {
    mockGetTurn(body: turnShape(inputText: '把 CI 修绿'));
    mockTimeline(
      items: [eventShape(eventId: 'ev_1', turnId: 'turn_1', text: '回复')],
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.turn.id, 'turn_1');
    expect(detail.turn.inputText, '把 CI 修绿');
    expect(detail.events, hasLength(1));
    expect(detail.events.single.text, '回复');
    expect(detail.hasNoEvents, isFalse);
  });

  test('按 turnId 过滤掉别的轮次的事件（timeline 是群级）', () async {
    mockGetTurn();
    mockTimeline(
      items: [
        eventShape(eventId: 'ev_mine', turnId: 'turn_1', text: '我的'),
        eventShape(eventId: 'ev_other', turnId: 'turn_2', text: '别人的'),
        eventShape(eventId: 'ev_mine2', turnId: 'turn_1', text: '我的2'),
      ],
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.events.map((e) => e.text), ['我的', '我的2']);
  });

  test('按 seq 升序排序（timeline 给的是 globalSeq 倒序）', () async {
    mockGetTurn();
    mockTimeline(
      items: [
        // 服务端 DESC：globalSeq 大的在前。
        eventShape(
          eventId: 'ev_3',
          turnId: 'turn_1',
          seq: 3,
          globalSeq: 30,
          text: '第三',
        ),
        eventShape(
          eventId: 'ev_1',
          turnId: 'turn_1',
          seq: 1,
          globalSeq: 10,
          text: '第一',
        ),
        eventShape(
          eventId: 'ev_2',
          turnId: 'turn_1',
          seq: 2,
          globalSeq: 20,
          text: '第二',
        ),
      ],
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.events.map((e) => e.text), ['第一', '第二', '第三']);
  });

  test('首页没有该 turn 的事件时向后翻页（否则详情页空着而真相是没翻到）', () async {
    mockGetTurn();
    // 首页：全是别人的事件，且**取满**（说明可能还有更早的）。
    mockTimeline(
      items: [
        for (var i = 0; i < 200; i++)
          eventShape(
            eventId: 'ev_other_$i',
            turnId: 'turn_2',
            globalSeq: 1000 + i,
          ),
      ],
      cursor: '999',
    );
    // 第二页：目标 turn 的事件在这里。
    mockTimeline(
      items: [
        eventShape(
          eventId: 'ev_mine',
          turnId: 'turn_1',
          globalSeq: 500,
          text: '翻到了',
        ),
      ],
      beforeGlobalSeq: '999',
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.events.map((e) => e.text), ['翻到了']);
  });

  test('命中后不再继续翻页（更早的页不会有该 turn 的事件）', () async {
    mockGetTurn();
    // 只挂第一页的 mock：若用例继续翻第二页，会因找不到路由而失败。
    mockTimeline(
      items: [eventShape(eventId: 'ev_mine', turnId: 'turn_1', text: '命中')],
      cursor: '99',
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.events, hasLength(1));
  });

  test('翻满 maxPages 就停（老 turn 不该把用户拖进几十次请求）', () async {
    mockGetTurn();
    // 两页都取满且不含目标 turn。只挂两页的 mock：用例若翻第三页会因找不到
    // 路由而失败，故「只请求了两页」是被真正验证的（不只是看计数器）。
    mockTimeline(
      items: [
        for (var i = 0; i < 200; i++)
          eventShape(
            eventId: 'ev_p1_$i',
            turnId: 'turn_2',
            globalSeq: 5000 + i,
          ),
      ],
      cursor: '5000',
    );
    mockTimeline(
      items: [
        for (var i = 0; i < 200; i++)
          eventShape(
            eventId: 'ev_p2_$i',
            turnId: 'turn_2',
            globalSeq: 3000 + i,
          ),
      ],
      cursor: '3000',
      beforeGlobalSeq: '5000',
    );

    final detail = await LoadTurnDetailUseCase(api, maxPages: 2)(
      'grp_1',
      'turn_1',
    );

    expect(detail.events, isEmpty);
    expect(detail.hasNoEvents, isTrue);
  });

  test('首页不足一页时不再翻（已到最早）', () async {
    mockGetTurn();
    // 只挂首页的 mock：若用例继续翻页会因找不到路由而失败。
    mockTimeline(
      items: [eventShape(eventId: 'ev_1', turnId: 'turn_2')],
      cursor: '1',
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.hasNoEvents, isTrue);
  });

  test('timeline 完全为空 → 空事件（不是错误）', () async {
    mockGetTurn();
    mockTimeline(items: const []);

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.hasNoEvents, isTrue);
    // meta 仍在（空事件不影响 turn 的加载）。
    expect(detail.turn.id, 'turn_1');
  });

  test('服务端没给游标时不再翻（不能拿 null 去请求「最新一页」）', () async {
    mockGetTurn();
    // 取满一页但**没有游标**：若用例硬翻，会拿 null 再请求一次「最新一页」
    // ——同一页无限循环。只挂首页 mock，故「只请求了一次」被真正验证。
    mockTimeline(
      items: [
        for (var i = 0; i < 200; i++)
          eventShape(eventId: 'ev_$i', turnId: 'turn_2'),
      ],
      cursor: '',
    );

    final detail = await LoadTurnDetailUseCase(api)('grp_1', 'turn_1');

    expect(detail.hasNoEvents, isTrue);
  });

  test('turn 不存在（404）时抛 SpbError（不静默返回空详情）', () async {
    adapter.onGet(
      '/chat/turns/turn_missing',
      (server) => server.reply(404, {'error': 'turn not found'}),
    );

    expect(
      () => LoadTurnDetailUseCase(api)('grp_1', 'turn_missing'),
      throwsA(isA<SpbError>()),
      reason: '静默返回空详情会让用户看到「这一轮没有事件」而真相是轮次不存在',
    );
  });
}
