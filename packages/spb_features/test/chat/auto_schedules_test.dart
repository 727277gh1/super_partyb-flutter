import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';

/// [AutoSchedulesUseCase] 的契约测试（issue #13）。
///
/// ## 这个测试防的是什么
///
/// 1. **不传 `agent_id`**：服务端 handler 忽略 `:group_id`，只按
///    `c.Query("agent_id")` 查。不传就是 `WHERE agent_id = ''` → **恒空**，
///    看起来像「没有排程」。
/// 2. **不本地按 group 过滤**：会得到「该 agent 的全部排程」，把同 agent 下
///    别的对话的续跑显示成当前对话的，用户会停掉不属于本对话的排程。
/// 3. **停用后不回读列表**：面板停在旧的「待触发」，用户以为没生效而反复点。
/// 4. **路径前缀写错**：列出是 `/api/chat/…/auto-schedules`（复数、带 `/api`），
///    停用是 `/chat/…/auto-schedule/stop`（单数、无 `/api`）——写错即 404。
///
/// ## 为什么不用 `testWidgets`
///
/// widget 测试跑在 fake async 里，真实 Dio 的 I/O 永远不会 resolve，测试会
/// 挂住。本文件全部用普通 `test()`，让真实 Dio + mock 适配器正常工作。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late AutoSchedulesUseCase useCase;

  /// 捕获全部请求的 method + path + query。
  late List<({String method, String path, Map<String, dynamic>? query})> calls;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    useCase = AutoSchedulesUseCase(ChatApi(dio));
    calls = [];
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add((
            method: options.method,
            path: options.path,
            query: options.queryParameters.isEmpty
                ? null
                : Map<String, dynamic>.from(options.queryParameters),
          ));
          handler.next(options);
        },
      ),
    );
  });

  Map<String, dynamic> groupJson({String? agentId = 'agt_1'}) => {
    'id': 'grp_1',
    'user_id': 'usr_1',
    'title': '某个对话',
    'status': 'active',
    if (agentId != null)
      'active_session': {'agent_id': agentId, 'session_id': 'sess_1'},
    'created_at': '2026-10-04T08:00:00Z',
    'updated_at': '2026-10-04T08:30:00Z',
  };

  Map<String, dynamic> scheduleJson({
    String id = 'sch_1',
    String groupId = 'grp_1',
    bool enabled = true,
  }) => {
    'id': id,
    'agentId': 'agt_1',
    'sessionId': 'sess_1',
    'agentType': 'pigo',
    'triggerReason': 'goal_gate',
    'triggerStatus': const {'String': 'pending', 'Valid': true},
    'message': '继续推进目标',
    'policyJson': '{"meta":{"group_id":"$groupId"}}',
    'dedupeKey': 'goal_gate:$groupId:t_1',
    'enabled': enabled,
    'runCount': 0,
    'maxRuns': 5,
    'nextRunAt': const {'Time': '2026-10-04T09:00:00Z', 'Valid': true},
    'lastRunAt': const {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    'lastErrorJson': null,
    'createdAt': '2026-10-04T08:00:00Z',
    'updatedAt': '2026-10-04T08:30:00Z',
  };

  void mockGroupGet([Map<String, dynamic>? json]) {
    adapter.onGet(
      '/chat/groups/grp_1',
      (server) => server.reply(200, json ?? groupJson()),
    );
  }

  group('load：取 agentId 并本地按 group 过滤', () {
    test('先 GET group 拿 agentId，再带 agent_id 列出', () async {
      mockGroupGet();
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {
          'items': [scheduleJson()],
        }),
        queryParameters: {'agent_id': 'agt_1', 'limit': 50},
      );

      final items = await useCase.load('grp_1');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'GET /chat/groups/grp_1',
        'GET /api/chat/groups/grp_1/auto-schedules',
      ]);
      expect(
        calls.last.query!['agent_id'],
        'agt_1',
        reason: '不传 agent_id 则服务端 WHERE agent_id = "" → 恒空',
      );
      expect(items, hasLength(1));
    });

    test('⚠️ 同 agent 下别的 group 的排程被本地过滤掉', () async {
      mockGroupGet();
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {
          'items': [
            scheduleJson(id: 'sch_mine', groupId: 'grp_1'),
            scheduleJson(id: 'sch_other', groupId: 'grp_2'),
          ],
        }),
        queryParameters: {'agent_id': 'agt_1', 'limit': 50},
      );

      final items = await useCase.load('grp_1');

      expect(items.map((s) => s.id), [
        'sch_mine',
      ], reason: 'handler 忽略 :group_id，同 agent 跨 group 的行会串进来');
    });

    test('⚠️ 取不到 groupId 的行被排除（停用谓词碰不到它）', () async {
      mockGroupGet();
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {
          'items': [
            scheduleJson(id: 'sch_mine', groupId: 'grp_1'),
            {...scheduleJson(id: 'sch_nogroup'), 'policyJson': 'not json'},
          ],
        }),
        queryParameters: {'agent_id': 'agt_1', 'limit': 50},
      );

      final items = await useCase.load('grp_1');

      expect(
        items.map((s) => s.id),
        ['sch_mine'],
        reason:
            '停用端点的 SQL 按 meta.group_id 过滤，碰不到它；'
            '放行会让按钮永远可点',
      );
    });

    test('activeSession 缺失时不带 agent_id（服务端会返空，但不崩）', () async {
      mockGroupGet(groupJson(agentId: null));
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 50},
      );

      final items = await useCase.load('grp_1');

      expect(items, isEmpty);
      expect(calls.last.query!.containsKey('agent_id'), isFalse);
    });
  });

  group('stopAll：写 + 回读列表', () {
    test('POST 停用 → GET group → GET 列表（顺序与路径都对）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) =>
            server.reply(200, {'group_id': 'grp_1', 'disabled_count': 2}),
      );
      mockGroupGet();
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {
          'items': [scheduleJson(enabled: false)],
        }),
        queryParameters: {'agent_id': 'agt_1', 'limit': 50},
      );

      final result = await useCase.stopAll('grp_1');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'POST /chat/groups/grp_1/auto-schedule/stop',
        'GET /chat/groups/grp_1',
        'GET /api/chat/groups/grp_1/auto-schedules',
      ]);
      expect(result.disabledCount, 2);
      expect(
        result.items.single.enabled,
        isFalse,
        reason: '回读到的权威状态必须是 enabled:false（不是旧的 pending）',
      );
    });

    test('停用端点路径不带 /api 前缀（写错即 404）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) => server.reply(200, {'disabled_count': 0}),
      );
      mockGroupGet();
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'agent_id': 'agt_1', 'limit': 50},
      );

      await useCase.stopAll('grp_1');

      expect(calls.first.path, '/chat/groups/grp_1/auto-schedule/stop');
    });
  });

  group('错误翻译', () {
    test('401 → 「登录已过期」', () async {
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(401, {'error': 'unauthorized'}),
      );

      await expectLater(
        useCase.load('grp_1'),
        throwsA(
          isA<AutoSchedulesFailure>().having(
            (e) => e.message,
            'message',
            '登录已过期，请重新登录',
          ),
        ),
      );
    });

    test('500 → 「服务端暂时不可用」', () async {
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        useCase.load('grp_1'),
        throwsA(
          isA<AutoSchedulesFailure>().having(
            (e) => e.message,
            'message',
            '服务端暂时不可用，请稍后重试',
          ),
        ),
      );
    });

    test('404 → 「这个对话已不存在」', () async {
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(404, {'error': 'not found'}),
      );

      await expectLater(
        useCase.load('grp_1'),
        throwsA(isA<AutoSchedulesFailure>()),
      );
    });

    test('失败时保留原始 cause（供日志/诊断，不展示）', () async {
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      try {
        await useCase.load('grp_1');
        fail('应该抛出 AutoSchedulesFailure');
      } on AutoSchedulesFailure catch (e) {
        expect(e.cause, isA<SpbError>());
      }
    });

    test('停用失败也抛 AutoSchedulesFailure（不是裸 SpbError）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        useCase.stopAll('grp_1'),
        throwsA(isA<AutoSchedulesFailure>()),
      );
    });

    test('回读失败也算整体失败（不静默返回旧列表）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) => server.reply(200, {'disabled_count': 1}),
      );
      // 回读列表失败。
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        useCase.stopAll('grp_1'),
        throwsA(isA<AutoSchedulesFailure>()),
      );
    });
  });
}
