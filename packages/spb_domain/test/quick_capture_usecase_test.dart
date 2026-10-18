import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 假的 [SseClient]（与 chat_stream_controller_test.dart 同构，此处内联以免
/// 测试文件互相 import）。
class _FakeSseClient extends SseClient {
  _FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();
  final recordedEventIds = <String>[];
  bool disposed = false;

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {}

  @override
  Future<void> resume() async {}

  @override
  void recordEventId(String eventId) => recordedEventIds.add(eventId);

  @override
  Future<void> dispose() async {
    disposed = true;
    await framesController.close();
    await statesController.close();
  }
}

/// `QuickCaptureUseCase` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// `POST /me/quick-capture` 有**两种语义完全不同的成功响应**，而它们看起来
/// 只差一个 `status` 字符串：
///
/// | status | 服务端做了什么 | UI 该做什么 |
/// |---|---|---|
/// | `queued` | 建了 turn 入队 | 导航到 group_id 并等回答 |
/// | `feedback_recorded` | 只记标注，**不建 turn** | 不导航、不等、不回显 |
///
/// 若把 `feedback_recorded` 当 `queued`，UI 会导航到一个永远没有回答的对话
/// （用户看到空对话，以为系统卡死）；反过来则消息静默消失。
/// 两种都是「不报错但行为错」，故必须钉成回归。
///
/// 另一个重点是**客户端不得写落点**（见 use case 文档）：落点由服务端写
/// `router_preferences`，客户端只读响应 group_id。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late QuickCaptureUseCase useCase;
  late _FakeSseClient sse;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    useCase = QuickCaptureUseCase(api);
    sse = _FakeSseClient();
  });

  /// 挂载 quick-capture 的 mock。
  ///
  /// `data: Matchers.any` 必需——http_mock_adapter 默认会连请求体一起比对，
  /// 不声明等于断言「请求体为 null」，真实 POST 永远匹配不上。
  void mockQuickCapture(Map<String, dynamic> response, {int statusCode = 201}) {
    adapter.onPost(
      '/me/quick-capture',
      (server) => server.reply(statusCode, response),
      data: Matchers.any,
    );
  }

  group('queued：有 turn 可等，应导航', () {
    test('返回 QuickCaptureQueued 且携带服务端判定的 groupId 与 turnId', () async {
      mockQuickCapture({
        'turn_id': 'turn_q1',
        'group_id': 'grp_q1',
        'status': 'queued',
        'created_group': false,
        'matched_title': '报错排查',
        'route_source': 'fastpath',
      });

      final outcome = await useCase.submit(input: '帮我看看这个报错');

      expect(outcome, isA<QuickCaptureQueued>());
      final q = outcome as QuickCaptureQueued;
      // 核心断言：groupId 来自**服务端判定**（调用方没传 group_id）。
      expect(q.groupId, 'grp_q1');
      expect(q.turnId, 'turn_q1');
      expect(q.createdGroup, isFalse);
      expect(q.matchedTitle, '报错排查');
    });

    test('created_group=true 时透传（UI 可提示「已新建对话」）', () async {
      mockQuickCapture({
        'turn_id': 'turn_new',
        'group_id': 'grp_new',
        'status': 'queued',
        'created_group': true,
      });

      final outcome = await useCase.submit(input: '新话题');

      expect((outcome as QuickCaptureQueued).createdGroup, isTrue);
    });

    test('传 echoInto 时把用户消息注入控制器缓冲（即时回显）', () async {
      mockQuickCapture({
        'turn_id': 'turn_q1',
        'group_id': 'grp_1',
        'status': 'queued',
      });
      // 控制器已聚焦 grp_1（与响应 group_id 一致，符合 echoInto 的时序要求）。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );
      await c.start(groupId: 'grp_1');
      expect(c.snapshot, isEmpty);

      await useCase.submit(input: '悬浮窗输入的内容', echoInto: c);

      // 立即出现用户气泡，不等服务端 SSE 事件往返。
      final items = c.snapshot;
      expect(items, hasLength(1));
      expect(items.single, isA<UserMessageItem>());
      expect((items.single as UserMessageItem).text, '悬浮窗输入的内容');
      expect(items.single.turnId, 'turn_q1');

      // 乐观项不得推进 SSE 游标（本地合成、不落库、无有效 eventId）。
      expect(sse.recordedEventIds, isEmpty);

      await c.dispose();
    });
  });

  group('feedback_recorded：终态，不导航', () {
    test('返回 QuickCaptureFeedbackRecorded 而非 Queued', () async {
      // 服务端此分支回 HTTP 200（非 201），且不填 turn_id。
      mockQuickCapture({
        'status': 'feedback_recorded',
        'group_id': 'grp_q1',
      }, statusCode: 200);

      final outcome = await useCase.submit(input: '反馈#正确');

      expect(outcome, isA<QuickCaptureFeedbackRecorded>());
      // 关键：**不是** QuickCaptureQueued —— 否则 UI 会导航到一个永远没有回答的对话。
      expect(outcome, isNot(isA<QuickCaptureQueued>()));
      expect(outcome.groupId, 'grp_q1');
    });

    test('即使传了 echoInto 也不回显（元指令不是消息）', () async {
      mockQuickCapture({
        'status': 'feedback_recorded',
        'group_id': 'grp_1',
      }, statusCode: 200);
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );
      await c.start(groupId: 'grp_1');

      await useCase.submit(input: '反馈#正确', echoInto: c);

      // 回显会在对话里留下一个「发了但没处理」的假气泡。
      expect(c.snapshot, isEmpty);
      await c.dispose();
    });

    test('与 queued 的 groupId 来源相同但语义不同（指向被评价的归属）', () async {
      mockQuickCapture({
        'status': 'feedback_recorded',
        'group_id': 'grp_evaluated',
      }, statusCode: 200);

      final outcome = await useCase.submit(input: '反馈#错误#2');

      expect(outcome.groupId, 'grp_evaluated');
      // turnId 为空是终态的旁证（服务端不填该字段）。
      expect(outcome.result.turnId, isEmpty);
    });
  });

  group('未知 status：不猜语义', () {
    test('服务端新增状态时返回 QuickCaptureUnknown（既不终态也不入队）', () async {
      mockQuickCapture({
        'turn_id': 'turn_future',
        'group_id': 'grp_future',
        'status': 'some_future_state',
      });

      final outcome = await useCase.submit(input: 'x');

      expect(outcome, isA<QuickCaptureUnknown>());
      expect((outcome as QuickCaptureUnknown).status, 'some_future_state');
      // 不导航（避免停到错误对话），也不当终态（避免丢弃真正入队的消息）。
      expect(outcome, isNot(isA<QuickCaptureQueued>()));
      expect(outcome, isNot(isA<QuickCaptureFeedbackRecorded>()));
    });

    test('未知 status 且传了 echoInto 时也不回显（语义未知，不乱插）', () async {
      mockQuickCapture({'group_id': 'grp_1', 'status': 'mystery'});
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      adapter.onGet(
        '/chat/groups/grp_1/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );
      await c.start(groupId: 'grp_1');

      await useCase.submit(input: 'x', echoInto: c);

      expect(c.snapshot, isEmpty);
      await c.dispose();
    });
  });

  group('错误传播', () {
    test('请求失败时抛 SpbError（不吞成「已提交」）', () async {
      adapter.onPost(
        '/me/quick-capture',
        (server) => server.reply(503, {'error': 'pipeline 未装配'}),
        data: Matchers.any,
      );

      await expectLater(useCase.submit(input: 'x'), throwsA(isA<SpbError>()));
    });

    test('401 时抛 SpbError（会话失效可被发现，不静默成功）', () async {
      adapter.onPost(
        '/me/quick-capture',
        (server) => server.reply(401, {'error': 'unauthorized'}),
        data: Matchers.any,
      );

      await expectLater(useCase.submit(input: 'x'), throwsA(isA<SpbError>()));
    });
  });

  group('sealed class 穷举（编译期保证漏分支被发现）', () {
    test('switch 能覆盖全部变体', () {
      // 若将来新增 outcome 变体，此 switch 会编译失败——这正是用 sealed class
      // 的目的：把「UI 漏处理某个分支」从运行时静默错误变成编译错误。
      String describe(QuickCaptureOutcome o) => switch (o) {
        QuickCaptureQueued() => 'navigate',
        QuickCaptureFeedbackRecorded() => 'toast',
        QuickCaptureUnknown() => 'log',
      };

      const result = QuickCaptureResult(
        turnId: '',
        groupId: 'g',
        status: 'feedback_recorded',
      );
      expect(
        describe(
          const QuickCaptureFeedbackRecorded(groupId: 'g', result: result),
        ),
        'toast',
      );
    });
  });
}
