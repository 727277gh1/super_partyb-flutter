import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// Agent 目录与会话切换端点的契约测试。
///
/// ## 这个测试防的是什么
///
/// `POST /chat/groups/:gid/sessions/switch` 的请求体是**手写的匿名结构体**
/// （`sessions.go:155`），字段名不完全一致：
///
/// ```go
/// AgentID         string `json:"agentId"`          // ← camelCase
/// Role            string `json:"role"`
/// ForceNewSession bool   `json:"force_new_session"`
/// ```
///
/// 只有 `agentId` 是 camelCase，而它恰好是最容易写成 `agent_id` 的那个
/// （全仓其余端点的 agent 字段都是 `agent_id`）。写错的失败方式很隐蔽：
/// 服务端 `AgentID` 保持空串 → 400 `agentId 不能为空`——文案不会提示
/// 「你的键名写错了」，排障者会以为 agent 真的不存在。
///
/// 故本文件对 body 键名做**字面量**断言（而不是「包含某值」）。
///
/// 第二类是**路径前缀**：`/api/agents` 带 `/api`，而
/// `/chat/groups/:gid/sessions/switch` 不带。两个请求在同一批调用里相邻，
/// 照抄其中一个去改另一个就会 404。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late AgentsApi api;

  /// 捕获全部请求的 method + path + body（用于断言键名与路径）。
  late List<({String method, String path, Map<String, dynamic>? body})> calls;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = AgentsApi(dio);
    calls = [];
    // ⚠️ 「键必须缺席」无法用 DioAdapter 的 `data:` 匹配器表达（只能断言相等），
    // 故用拦截器捕获原始 body。
    dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          calls.add((
            method: options.method,
            path: options.path,
            body: options.data is Map
                ? Map<String, dynamic>.from(options.data as Map)
                : null,
          ));
          handler.next(options);
        },
      ),
    );
  });

  /// `agents.go` 的 `agentDTO` 形状（snake_case）。
  Map<String, dynamic> agentJson({
    String id = 'agent_1',
    String name = '写作助手',
    String status = 'active',
  }) => {
    'id': id,
    'name': name,
    'group_name': '通用',
    'description': '帮你写东西',
    'content_md': '# 写作助手',
    'tags': ['写作', '润色'],
    'user_id': 'usr_1',
    'skills': ['write'],
    'status': status,
    'provider_type': 'pigo',
    'provider_config': {'base_url': 'https://llm.example.com'},
    'env': {'FOO': 'bar'},
    'default_model_id': 'gpt-4o',
    'model_tier': 'large',
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-06T09:00:00Z',
  };

  group('GET /api/agents', () {
    test('路径带 /api 前缀，响应按 {items:[...]} 解包', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {
          'items': [agentJson(), agentJson(id: 'agent_2', name: '代码助手')],
        }),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      final agents = await api.listAgents();

      expect(calls.single.path, '/api/agents');
      expect(agents, hasLength(2));
      expect(agents.first.id, 'agent_1');
      expect(agents[1].name, '代码助手');
    });

    test('解析 agentDTO 的全部字段', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {
          'items': [agentJson()],
        }),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      final a = (await api.listAgents()).single;

      expect(a.id, 'agent_1');
      expect(a.name, '写作助手');
      expect(a.groupName, '通用');
      expect(a.description, '帮你写东西');
      expect(a.contentMd, '# 写作助手');
      expect(a.tags, ['写作', '润色']);
      expect(a.userId, 'usr_1');
      expect(a.skills, ['write']);
      expect(a.status, 'active');
      expect(a.providerType, 'pigo');
      expect(a.providerConfig, {'base_url': 'https://llm.example.com'});
      expect(a.env, {'FOO': 'bar'});
      expect(a.defaultModelId, 'gpt-4o');
      expect(a.modelTier, 'large');
      expect(a.createdAt, isNotNull);
      expect(a.updatedAt, isNotNull);
    });

    test('裸数组响应也能解析（unwrapItems 的兼容路径）', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, [agentJson()]),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      expect(await api.listAgents(), hasLength(1));
    });

    test('limit / offset / status 作为 query 下发', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 20, 'offset': 40, 'status': 'archived'},
      );

      await api.listAgents(limit: 20, offset: 40, status: 'archived');

      expect(calls.single.path, '/api/agents');
    });

    test('status 为空串时不带该 query（不查空状态）', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      await api.listAgents(status: '');

      expect(calls.single.path, '/api/agents');
    });

    test('字段缺失时不抛异常（status 空 → isActive 视为可选）', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {
          'items': [
            {'id': 'a1'},
          ],
        }),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      final a = (await api.listAgents()).single;

      expect(a.id, 'a1');
      expect(a.name, '');
      expect(a.tags, isEmpty);
      expect(a.providerConfig, isNull);
      // 名称缺失时 label 回退 id（显示空白会让用户不知道是哪个 agent）。
      expect(a.label, 'a1');
      expect(a.isActive, isTrue);
    });

    test('归档 agent 的 isActive 为假', () async {
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(200, {
          'items': [agentJson(status: 'archived')],
        }),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      expect((await api.listAgents()).single.isActive, isFalse);
    });

    test('500 抛 HttpError（不静默返回空列表）', () async {
      // 静默空列表会让 UI 隐藏切换入口，用户以为「没有可用 agent」。
      adapter.onGet(
        '/api/agents',
        (server) => server.reply(500, {'error': 'boom'}),
        queryParameters: {'limit': 100, 'offset': 0},
      );

      await expectLater(
        () => api.listAgents(),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });
  });

  group('GET /api/agents/:id', () {
    test('路径带 /api 前缀', () async {
      adapter.onGet(
        '/api/agents/agent_1',
        (server) => server.reply(200, agentJson()),
      );

      final a = await api.getAgent('agent_1');

      expect(calls.single.path, '/api/agents/agent_1');
      expect(a.name, '写作助手');
    });
  });

  group('GET /chat/groups/:gid/sessions', () {
    /// `sessionRowToDict` 形状。
    Map<String, dynamic> sessionJson({
      String id = 'sess_1',
      String agentId = 'agent_1',
      String? sessionId = 'up_1',
      String status = 'active',
    }) => {
      'id': id,
      'group_id': 'grp_1',
      'agent_id': agentId,
      'session_id': sessionId,
      'agent_name': '写作助手',
      'agent_provider': 'pigo',
      'role': 'owner',
      'status': status,
      'joined_at': '2024-03-05T08:00:00Z',
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:00:00Z',
    };

    test('路径不带 /api 前缀（与 /api/agents 相反）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/sessions',
        (server) => server.reply(200, {
          'items': [sessionJson()],
        }),
        queryParameters: {'status': 'active'},
      );

      final sessions = await api.listGroupSessions('grp_1');

      expect(
        calls.single.path,
        '/chat/groups/grp_1/sessions',
        reason: '会话端点挂在 /chat 下，不带 /api',
      );
      expect(sessions.single.agentId, 'agent_1');
      expect(sessions.single.agentName, '写作助手');
      expect(sessions.single.agentProvider, 'pigo');
    });

    test('status 为空串时回落 active（不查空状态）', () async {
      // 服务端 `c.DefaultQuery("status", "active")`——显式传空串会**原样**查空
      // 状态，得到一个空列表（不是「不限」）。
      adapter.onGet(
        '/chat/groups/grp_1/sessions',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'status': 'active'},
      );

      await api.listGroupSessions('grp_1', status: '');

      expect(calls.single.path, '/chat/groups/grp_1/sessions');
    });

    test('session_id 为 null 是正常的（lazy 激活）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/sessions',
        (server) => server.reply(200, {
          'items': [sessionJson(sessionId: null)],
        }),
        queryParameters: {'status': 'active'},
      );

      final s = (await api.listGroupSessions('grp_1')).single;

      expect(s.sessionId, isNull);
      expect(s.agentId, 'agent_1', reason: '不能因为 session_id 空就当成坏数据');
    });

    test('agent_name 缺失时 label 回退 agent_id', () async {
      adapter.onGet(
        '/chat/groups/grp_1/sessions',
        (server) => server.reply(200, {
          'items': [
            {'id': 's1', 'group_id': 'grp_1', 'agent_id': 'agent_x'},
          ],
        }),
        queryParameters: {'status': 'active'},
      );

      expect((await api.listGroupSessions('grp_1')).single.label, 'agent_x');
    });

    test('404（group 不存在）抛 HttpError', () async {
      adapter.onGet(
        '/chat/groups/grp_gone/sessions',
        (server) => server.reply(404, {'error': 'group not found'}),
        queryParameters: {'status': 'active'},
      );

      await expectLater(
        () => api.listGroupSessions('grp_gone'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });

  group('POST /chat/groups/:gid/sessions/switch', () {
    Map<String, dynamic> switchJson({
      String agentId = 'agent_2',
      bool forceNewSession = false,
    }) => {
      'group_id': 'grp_1',
      'new_agent_id': agentId,
      'session_id': null, // lazy：待 turn 执行回填
      'status': 'active',
      'force_new_session': forceNewSession,
      'switched': true,
    };

    test('body 键名是 agentId（camelCase），不是 agent_id', () async {
      // ⚠️ 这是本文件最重要的一条断言。写成 agent_id 会 400
      // 「agentId 不能为空」，而错误文案不会提示键名写错了。
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      await api.switchGroupAgent('grp_1', agentId: 'agent_2');

      expect(calls.single.method, 'POST');
      expect(calls.single.path, '/chat/groups/grp_1/sessions/switch');
      expect(calls.single.body!.containsKey('agentId'), isTrue);
      expect(
        calls.single.body!.containsKey('agent_id'),
        isFalse,
        reason: '写成 agent_id 会让服务端 AgentID 保持空串 → 400',
      );
      expect(calls.single.body!['agentId'], 'agent_2');
    });

    test('路径不带 /api 前缀（与 /api/agents 相反）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      await api.switchGroupAgent('grp_1', agentId: 'agent_2');

      expect(calls.single.path, isNot(startsWith('/api/')));
    });

    test('force_new_session 恒在 body 里（默认 false）', () async {
      // 服务端是 bool 非指针，缺键与 false 等价；但显式下发让日志/抓包能看出
      // 客户端意图，也避免将来服务端改成指针时行为漂移。
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      await api.switchGroupAgent('grp_1', agentId: 'agent_2');

      expect(calls.single.body!['force_new_session'], isFalse);
    });

    test('forceNewSession=true 时下发 true（同 agent 开新会话）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson(forceNewSession: true)),
        data: Matchers.any,
      );

      final r = await api.switchGroupAgent(
        'grp_1',
        agentId: 'agent_1',
        forceNewSession: true,
      );

      expect(calls.single.body!['force_new_session'], isTrue);
      expect(r.forceNewSession, isTrue);
    });

    test('role 缺省时不发该键（服务端取 owner）', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      await api.switchGroupAgent('grp_1', agentId: 'agent_2');

      expect(calls.single.body!.containsKey('role'), isFalse);
    });

    test('role 显式传入时下发', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      await api.switchGroupAgent('grp_1', agentId: 'agent_2', role: 'reviewer');

      expect(calls.single.body!['role'], 'reviewer');
    });

    test('解析响应：switched / new_agent_id / session_id 为 null', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(200, switchJson()),
        data: Matchers.any,
      );

      final r = await api.switchGroupAgent('grp_1', agentId: 'agent_2');

      expect(r.groupId, 'grp_1');
      expect(r.newAgentId, 'agent_2');
      expect(r.switched, isTrue);
      expect(r.status, 'active');
      // session_id 为 null 是 lazy 激活的预期结果，不是失败。
      expect(r.sessionId, isNull);
    });

    test('400「agentId 不能为空」抛 HttpError（不静默当成功）', () async {
      // 服务端对这个错误返回 400，而 validateStatus 放行 4xx——不补判就会把
      // 「切换失败」渲染成「切换成功」。
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(400, {'error': 'agentId 不能为空'}),
        data: Matchers.any,
      );

      await expectLater(
        () => api.switchGroupAgent('grp_1', agentId: ''),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              // 服务端文案在 body 里（message 恒为 "HTTP 400"）。
              .having((e) => e.body, 'body', contains('agentId')),
        ),
      );
    });

    test('404（agent 不存在）抛 HttpError', () async {
      adapter.onPost(
        '/chat/groups/grp_1/sessions/switch',
        (server) => server.reply(404, {'error': 'agent 不存在: ghost'}),
        data: Matchers.any,
      );

      await expectLater(
        () => api.switchGroupAgent('grp_1', agentId: 'ghost'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });
}
