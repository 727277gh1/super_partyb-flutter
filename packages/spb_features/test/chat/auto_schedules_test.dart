import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';

/// [AutoSchedulesUseCase] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 1. **本地按 group 过滤的校验仍在**：服务端（Go `b2a54b5a` 起）按路径
///    `:group_id` 过滤，但「解析不出 `policy.meta.group_id`」的行停用端点
///    碰不到——放行它们会让「停用全部」按钮看起来点了没反应。此前这层
///    过滤还兼「服务端忽略 :group_id」的 workaround；server 修复后它降级为
///    廉价校验，但**不能删**。
/// 2. **单次请求**：server 修复后不再需要先 GET group 拿 agentId——若有人
///    把两步 workaround 加回来，请求序列断言会变红（多一次无谓往返）。
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

  /// Go `scheduleToDTO`（snake_case）的形状。
  Map<String, dynamic> scheduleJson({
    String id = 'sch_1',
    String groupId = 'grp_1',
    bool enabled = true,
  }) => {
    'id': id,
    'agent_id': 'agt_1',
    'session_id': 'sess_1',
    'agent_type': 'pigo',
    'trigger_reason': 'goal_gate',
    'trigger_status': 'pending',
    'message': '继续推进目标',
    'policy': {
      'meta': {'group_id': groupId},
      'max_auto_turns': 5,
    },
    'dedupe_key': 'goal_gate:$groupId:t_1',
    'enabled': enabled,
    'run_count': 0,
    'max_runs': 5,
    'next_run_at': '2026-10-04T09:00:00Z',
    'last_run_at': null,
    'last_error': null,
    'schedule_state': 'pending',
    'created_at': '2026-10-04T08:00:00Z',
    'updated_at': '2026-10-04T08:30:00Z',
  };

  void mockList([List<Map<String, dynamic>>? items]) {
    adapter.onGet(
      '/api/chat/groups/grp_1/auto-schedules',
      (server) => server.reply(200, {
        'items': items ?? [scheduleJson()],
      }),
    );
  }

  group('load：单次请求 + group 归属校验', () {
    test('单次 GET 列出（不带 agent_id 两步 workaround）', () async {
      mockList();

      final items = await useCase.load('grp_1');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'GET /api/chat/groups/grp_1/auto-schedules',
      ], reason: '服务端已按 :group_id 过滤（b2a54b5a），先取 group 是多余的往返');
      expect(items, hasLength(1));
      expect(items.single.agentId, 'agt_1');
      expect(items.single.scheduleState, 'pending');
    });

    test('⚠️ 不属于本 group 的行被过滤（防服务端回归 / 脏数据）', () async {
      mockList([
        scheduleJson(id: 'sch_mine', groupId: 'grp_1'),
        scheduleJson(id: 'sch_other', groupId: 'grp_2'),
      ]);

      final items = await useCase.load('grp_1');

      expect(items.map((s) => s.id), ['sch_mine']);
    });

    test('⚠️ 取不到 groupId 的行被排除（停用谓词碰不到它）', () async {
      mockList([
        scheduleJson(id: 'sch_mine', groupId: 'grp_1'),
        {...scheduleJson(id: 'sch_nogroup'), 'policy': null},
      ]);

      final items = await useCase.load('grp_1');

      expect(
        items.map((s) => s.id),
        ['sch_mine'],
        reason:
            '停用端点的 SQL 按 meta.group_id 过滤，碰不到它；'
            '放行会让按钮永远可点',
      );
    });
  });

  group('stopAll：写 + 回读列表', () {
    test('POST 停用 → GET 列表（顺序与路径都对）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/auto-schedule/stop',
        data: null,
        (server) =>
            server.reply(200, {'group_id': 'grp_1', 'disabled_count': 2}),
      );
      mockList([scheduleJson(enabled: false)]);

      final result = await useCase.stopAll('grp_1');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'POST /chat/groups/grp_1/auto-schedule/stop',
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
      mockList(const []);

      await useCase.stopAll('grp_1');

      expect(calls.first.path, '/chat/groups/grp_1/auto-schedule/stop');
    });
  });

  group('错误翻译', () {
    test('401 → 「登录已过期」', () async {
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
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
        '/api/chat/groups/grp_1/auto-schedules',
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
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(404, {'error': 'not found'}),
      );

      await expectLater(
        useCase.load('grp_1'),
        throwsA(isA<AutoSchedulesFailure>()),
      );
    });

    test('失败时保留原始 cause（供日志/诊断，不展示）', () async {
      adapter.onGet(
        '/api/chat/groups/grp_1/auto-schedules',
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
        '/api/chat/groups/grp_1/auto-schedules',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        useCase.stopAll('grp_1'),
        throwsA(isA<AutoSchedulesFailure>()),
      );
    });
  });
}
