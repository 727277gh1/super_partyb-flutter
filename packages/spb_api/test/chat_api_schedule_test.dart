import 'dart:convert';
import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_api_harness.dart';

/// ChatApi 的 turn 运行时与排程契约测试（turnRuntime / auto-schedules / createTurn）
///
/// ⚠️ 本文件由 `chat_api_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/chat_api_harness.dart`。
void main() {
  setUpHarness();

  group('turnRuntime', () {
    test('GET /api/chat/turn-runtime 解析三个字段', () async {
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 600,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 600,
        }),
      );

      final rt = await api.turnRuntime();

      expect(rt.requestTimeoutSeconds, 600);
      expect(rt.inactivityTimeoutSeconds, 0);
      expect(rt.clientTurnTimeoutSeconds, 600);
      expect(rt.effectiveClientTurnTimeout, const Duration(minutes: 10));
    });

    test('client_turn_timeout_seconds=0 时退化为兜底阈值（不当成零秒超时）', () async {
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 0,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 0,
        }),
      );

      final rt = await api.turnRuntime();

      expect(rt.clientTurnTimeout, isNull);
      expect(rt.effectiveClientTurnTimeout, TurnRuntime.fallback);
    });
  });

  /// 路径真伪测试（真起 server）。
  ///
  /// ## 为什么必须真发一次
  ///
  /// Go API 有**两套**前缀且都以 `/chat` 结尾/开头：
  ///
  /// | 注册位置 | 前缀 |
  /// |---|---|
  /// | `router.go` 的 `apiv1.Group("/chat")` | `/api/chat/*` |
  /// | `router.go` 的 `r.Group("/chat")` | `/chat/*` |
  ///
  /// `turn-runtime` 挂在**前者**（`registerChatRuntimeRoutes(apiv1.Group("/chat"), ...)`）。
  /// 拼成 `/chat/turn-runtime` 不会报错——服务端只会 404，而 mock 适配器按注册
  /// 路径匹配，写错的测试照样「通过」（断言的是同一个错值）。真起 server 才能
  /// 确认请求真的到了 `/api/chat/turn-runtime`。
  group('turnRuntime 真实请求路径', () {
    late HttpServer server;
    late ChatApi realApi;
    late List<String> receivedPaths;

    setUp(() async {
      receivedPaths = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      realApi = ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
      server.listen((req) async {
        receivedPaths.add(req.uri.path);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"client_turn_timeout_seconds":300}');
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('打到 /api/chat/turn-runtime（不是 /chat/turn-runtime）', () async {
      await realApi.turnRuntime();

      expect(receivedPaths, ['/api/chat/turn-runtime']);
    });
  });

  /// `listAutoSchedules` 的契约与请求形状。
  group('listAutoSchedules', () {
    test('解析 items 为 ChatTurnSchedule（camelCase）', () async {
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {
          'items': [
            {
              'id': 'sch_1',
              'agentId': 'agt_1',
              'sessionId': 'sess_1',
              'agentType': 'pigo',
              'triggerReason': 'goal_gate',
              'triggerStatus': {'String': 'pending', 'Valid': true},
              'message': '继续',
              'policyJson': '{"meta":{"group_id":"grp_1"}}',
              'dedupeKey': 'goal_gate:grp_1:t_1',
              'enabled': true,
              'runCount': 1,
              'maxRuns': 5,
              'nextRunAt': {'Time': '2026-10-04T09:00:00Z', 'Valid': true},
              'lastRunAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
              'lastErrorJson': null,
              'createdAt': '2026-10-04T08:00:00Z',
              'updatedAt': '2026-10-04T08:30:00Z',
            },
          ],
        }),
      );

      final list = await api.listAutoSchedules('grp_1', agentId: 'agt_1');

      expect(list, hasLength(1));
      final s = list.single;
      expect(s.agentId, 'agt_1');
      expect(s.triggerReason, 'goal_gate');
      expect(s.triggerStatus, 'pending');
      expect(s.runCount, 1);
      expect(s.groupId, 'grp_1');
      expect(s.isPending, isTrue);
      expect(s.nextRunAt?.toUtc(), DateTime.utc(2026, 10, 4, 9));
      expect(s.lastRunAt, isNull);
    });

    test('空列表不报错', () async {
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {'items': <dynamic>[]}),
      );

      expect(await api.listAutoSchedules('grp_1'), isEmpty);
    });
  });

  /// `stopAutoSchedule` 的返回解析（服务端 `{group_id, disabled_count}`）。
  group('stopAutoSchedule', () {
    test('返回 disabled_count', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) =>
            server.reply(200, {'group_id': 'grp_1', 'disabled_count': 3}),
      );

      expect(await api.stopAutoSchedule('grp_1'), 3);
    });

    test('缺 disabled_count → 0（不抛异常）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) => server.reply(200, {'group_id': 'grp_1'}),
      );

      expect(await api.stopAutoSchedule('grp_1'), 0);
    });
  });

  /// 真实请求路径测试。
  ///
  /// ## 为什么必须真发一次
  ///
  /// 这两个端点的前缀**故意不一致**（不是笔误）：
  ///
  /// | 端点 | 实际路径 |
  /// |---|---|
  /// | 列出 | `/api/chat/groups/…/auto-schedules`（**复数**，带 `/api`） |
  /// | 停用 | `/chat/groups/…/auto-schedule/stop`（**单数**，无 `/api`） |
  ///
  /// 统一成同一个前缀、或把复数写成单数，都会 404。而 mock adapter 是
  /// **按我写的路径注册**的——写错了它照样通过，所以必须打真 server 验证。
  group('auto-schedules 真实请求路径', () {
    late HttpServer server;
    late ChatApi realApi;
    late List<String> received;

    setUp(() async {
      received = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      realApi = ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
      server.listen((req) async {
        received.add('${req.method} ${req.uri.path}');
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"items":[],"disabled_count":0}');
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('列出打到 /api/chat/groups/:id/auto-schedules（复数，带 /api）', () async {
      await realApi.listAutoSchedules('grp_1', agentId: 'agt_1');

      expect(received, ['GET /api/chat/groups/grp_1/auto-schedules']);
    });

    test('停用打到 /chat/groups/:id/auto-schedule/stop（单数，无 /api）', () async {
      await realApi.stopAutoSchedule('grp_1');

      expect(received, ['POST /chat/groups/grp_1/auto-schedule/stop']);
    });
  });

  /// `POST /chat/groups/:group_id/turns` 的**请求体字段名**契约。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 该端点绑定 Go 的 `CreateTurnRequest`（`internal/server/chat.go:476`），
  /// 字段是 **camelCase** 且文本键叫 `inputText`：
  ///
  /// ```go
  /// RequestID string `json:"requestId"`
  /// InputText string `json:"inputText" binding:"required"`
  /// ```
  ///
  /// 而消息流端点 `/users/:uid/chat/messages` 用的是 `input` / `request_id`。
  /// 两个端点长得像、参数名却不同，写成后者会被 `binding:"required"` 打回 400
  /// ——历史上这里正是发 `{input, request_id}` 并解析成 `ChatTurn`，**双重**不符。
  ///
  /// 故这里断言的是「打到线上的字面量」，而不是「调用没抛异常」。
  group('createTurn 请求体字段名（对齐 CreateTurnRequest）', () {
    late HttpServer server;
    late ChatApi realApi;
    late List<String> received;
    late List<Map<String, dynamic>> bodies;

    setUp(() async {
      received = [];
      bodies = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      realApi = ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
      server.listen((req) async {
        received.add('${req.method} ${req.uri.path}');
        final raw = await utf8.decoder.bind(req).join();
        bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        req.response
          ..statusCode = 201
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'queued',
              'groupId': 'grp_1',
              'turnId': 'turn_9',
            }),
          );
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('发 inputText（不是 input），并带上 source', () async {
      final result = await realApi.createTurn('grp_1', input: '再跑一遍');

      expect(received, ['POST /chat/groups/grp_1/turns']);
      expect(bodies.single['inputText'], '再跑一遍');
      expect(bodies.single.containsKey('input'), isFalse);
      expect(bodies.single['source'], 'direct');
      // 响应是 camelCase 平铺，不是 ChatTurn。
      expect(result.turnId, 'turn_9');
      expect(result.groupId, 'grp_1');
      expect(result.status, 'queued');
    });

    test('requestId 用 camelCase（不是 request_id）', () async {
      await realApi.createTurn('grp_1', input: 'x', requestId: 'req_1');

      expect(bodies.single['requestId'], 'req_1');
      expect(bodies.single.containsKey('request_id'), isFalse);
    });

    test('不带 requestId 时不出该键（服务端每次新建）', () async {
      await realApi.createTurn('grp_1', input: 'x');

      expect(bodies.single.containsKey('requestId'), isFalse);
    });

    test('CreateTurnResult 缺字段时不抛异常（安全默认值）', () {
      final r = CreateTurnResult.fromJson(const {});

      expect(r.turnId, '');
      expect(r.groupId, '');
      expect(r.status, 'queued');
    });
  });
}
