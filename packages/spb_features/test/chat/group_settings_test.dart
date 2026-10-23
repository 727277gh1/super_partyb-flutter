import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:flutter_test/flutter_test.dart';

/// [GroupSettingsUseCase] 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 每个设置写操作都是**两步**：先调专用 PUT 端点，再 `GET /chat/groups/:id`
/// 取权威状态。第二步不可省——服务端的写响应只有 `{updated: true}` /
/// `{enabled: ...}` / `{tts: ...}`，**没有** group。若图省事直接解析写响应，
/// 会得到 `id: ''` / `title: ''` 的空对象，界面表现为「一改设置，对话标题变空白」。
///
/// 故这里对每个动作都断言「PUT 之后确实还发了一次 GET」，而不只断言 PUT。
///
/// 第二类要防的是**错误文案**：`HttpError.message` 固定是 `"HTTP 400"`，
/// 直接显示等于没说。`400 goal_required` 是预期内的业务结果（用户少做了一步），
/// 提示必须给出下一步动作。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;
  late GroupSettingsUseCase useCase;

  /// 捕获全部请求的 method + path。
  late List<({String method, String path, Map<String, dynamic>? body})> calls;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    useCase = GroupSettingsUseCase(api);
    calls = [];
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

  /// `groupToDict` 的真实输出形状。
  Map<String, dynamic> groupJson({
    Map<String, dynamic>? metadata,
    Map<String, dynamic>? currentGoal,
  }) => {
    'id': 'grp_1',
    'user_id': 'usr_1',
    'title': '某个对话',
    'status': 'active',
    'metadata': metadata,
    'current_goal': currentGoal,
    'created_at': '2024-03-05T08:00:00Z',
    'updated_at': '2024-03-05T08:09:10Z',
  };

  void mockGroupGet([Map<String, dynamic>? json]) {
    adapter.onGet(
      '/chat/groups/grp_1',
      (server) => server.reply(200, json ?? groupJson()),
    );
  }

  group('每个写操作都是「PUT 端点 + 回读 group」两步', () {
    test('toggleGoalGate：PUT goal-gate → GET group', () async {
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(200, {'enabled': true}),
        data: Matchers.any,
      );
      mockGroupGet(
        groupJson(
          metadata: {
            'goal_gate': {'enabled': true, 'continue_until_done': true},
          },
        ),
      );

      final g = await useCase.toggleGoalGate('grp_1', true);

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'PUT /chat/groups/grp_1/goal-gate',
        'GET /chat/groups/grp_1',
      ]);
      expect(calls.first.body, {'enabled': true});
      // 返回的是**回读**的权威对象，不是 PUT 的响应。
      expect(g.goalGateEnabled, isTrue);
      expect(g.title, '某个对话');
    });

    test('saveMaxAutoTurns：只发 max_auto_turns（enabled 保持原值）', () async {
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(200, {'max_auto_turns': 50}),
        data: Matchers.any,
      );
      mockGroupGet();

      await useCase.saveMaxAutoTurns('grp_1', 50);

      expect(calls.first.body, {'max_auto_turns': 50});
      expect(calls.first.body!.containsKey('enabled'), isFalse);
      expect(calls.map((c) => c.method), ['PUT', 'GET']);
    });

    test('toggleFollowUpSuggest：PUT follow-up-suggest → GET group', () async {
      adapter.onPut(
        '/chat/groups/grp_1/follow-up-suggest',
        (server) => server.reply(200, {'enabled': false}),
        data: Matchers.any,
      );
      mockGroupGet();

      await useCase.toggleFollowUpSuggest('grp_1', false);

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'PUT /chat/groups/grp_1/follow-up-suggest',
        'GET /chat/groups/grp_1',
      ]);
      expect(calls.first.body, {'enabled': false});
    });

    test('saveTts：只发传入的键（不整包提交）', () async {
      // webapp 提交的是合并后的完整配置；本用例刻意只发意图字段——整包提交在
      // 并发场景下会把另一台设备刚改的键回滚。
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(200, {
          'tts': {'enabled': true},
        }),
        data: Matchers.any,
      );
      mockGroupGet();

      await useCase.saveTts('grp_1', narrateThinking: true);

      expect(calls.first.body, {'narrate_thinking': true});
      expect(calls.map((c) => c.method), ['PUT', 'GET']);
    });

    test('saveTts 全量字段映射到 snake_case', () async {
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(200, {'tts': <String, dynamic>{}}),
        data: Matchers.any,
      );
      mockGroupGet();

      await useCase.saveTts(
        'grp_1',
        enabled: true,
        narrateThinking: true,
        narrationMode: 'summary',
        fileSummary: false,
      );

      expect(calls.first.body, {
        'enabled': true,
        'narrate_thinking': true,
        'narration_mode': 'summary',
        'file_summary': false,
      });
    });

    test('saveGoal：清空目标走 PATCH goals/:id，然后回读 group', () async {
      adapter.onGet(
        '/chat/groups/grp_1/goals/current',
        (server) => server.reply(200, {
          'goal': {'id': 'goal_old', 'goal_text': '旧目标'},
          'tasks': <dynamic>[],
          'progress': null,
        }),
      );
      adapter.onPatch(
        '/chat/goals/goal_old',
        (server) => server.reply(200, {
          'goal': {'id': 'goal_old'},
        }),
        data: Matchers.any,
      );
      mockGroupGet();

      final g = await useCase.saveGoal('grp_1', '');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'GET /chat/groups/grp_1/goals/current',
        'PATCH /chat/goals/goal_old',
        'GET /chat/groups/grp_1',
      ]);
      expect(g.title, '某个对话');
    });
  });

  group('错误翻译', () {
    test('400 goal_required → 提示「请先设置目标」（不是「HTTP 400」）', () async {
      // 面板已本地禁用开关，但目标可能被另一台设备清空，故这条路径仍会走到。
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(400, {
          'error': 'goal_required',
          'message': '开启「自动实现目标」前请先设置目标',
        }),
        data: Matchers.any,
      );

      await expectLater(
        () => useCase.toggleGoalGate('grp_1', true),
        throwsA(
          isA<GroupSettingsFailure>()
              .having((e) => e.message, 'message', '请先设置目标，再开启自动实现目标')
              // 原始错误必须保留（供日志/诊断）。
              .having((e) => e.cause, 'cause', isA<HttpError>()),
        ),
      );
    });

    test('409 metadata_conflict → 「设置冲突，请稍后重试」', () async {
      // CAS 乐观锁在并发写时返回 409，是预期内的可重试结果。
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(409, {
          'error': 'metadata_conflict',
          'message': '设置冲突，请重试',
        }),
        data: Matchers.any,
      );

      await expectLater(
        () => useCase.saveTts('grp_1', enabled: true),
        throwsA(
          isA<GroupSettingsFailure>().having(
            (e) => e.message,
            'message',
            '设置冲突，请稍后重试',
          ),
        ),
      );
    });

    test('404（group 已删除）→ 提示返回列表刷新', () async {
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(404, {'error': 'group not found'}),
        data: Matchers.any,
      );

      await expectLater(
        () => useCase.toggleGoalGate('grp_1', true),
        throwsA(
          isA<GroupSettingsFailure>().having(
            (e) => e.message,
            'message',
            '这个对话已不存在，请返回列表刷新',
          ),
        ),
      );
    });

    test('写成功但回读失败也算失败（不返回旧值假装成功）', () async {
      // 返回旧对象会让界面显示未生效的设置，用户以为没保存而重复点。
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(200, {'enabled': true}),
        data: Matchers.any,
      );
      adapter.onGet(
        '/chat/groups/grp_1',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        () => useCase.toggleGoalGate('grp_1', true),
        throwsA(
          isA<GroupSettingsFailure>().having(
            (e) => e.message,
            'message',
            '服务端暂时不可用，请稍后重试',
          ),
        ),
      );
    });
  });

  group('describeGroupSettingsError 的兜底分支', () {
    test('无 body 的 400 → 通用文案（不暴露 "HTTP 400"）', () {
      expect(
        describeGroupSettingsError(const HttpError(400, 'HTTP 400')),
        '设置未被接受，请检查输入',
      );
    });

    test('body 里有 message 时优先展示它', () {
      expect(
        describeGroupSettingsError(
          const HttpError(
            400,
            'HTTP 400',
            body: '{"error":"x","message":"轮次上限非法"}',
          ),
        ),
        '轮次上限非法',
      );
    });

    test('body 是 Dart Map 字面量形态时也能提取（真实 HttpError.body 的形状）', () {
      // `ChatApi._bodyPreview` 用 `data.toString()`，而 Dio 已把响应体解析成 Map
      // → body 实际是 `{error: goal_required, message: ...}`，**不带引号**。
      // 只按 JSON 写正则会在真实响应上静默提取不到（单测里手写 JSON 反而能过）。
      expect(
        describeGroupSettingsError(
          const HttpError(
            400,
            'HTTP 400',
            body: '{error: goal_required, message: 开启「自动实现目标」前请先设置目标}',
          ),
        ),
        '请先设置目标，再开启自动实现目标',
      );
      expect(
        describeGroupSettingsError(
          const HttpError(
            409,
            'HTTP 409',
            body: '{error: metadata_conflict, message: 设置冲突，请重试}',
          ),
        ),
        '设置冲突，请稍后重试',
      );
    });

    test('401 → 提示重新登录', () {
      expect(
        describeGroupSettingsError(
          const AuthError('unauthorized', statusCode: 401),
        ),
        '登录已过期，请重新登录',
      );
    });

    test('网络错误 → 提示检查网络', () {
      expect(
        describeGroupSettingsError(const NetworkError('timeout')),
        '网络连接失败，请检查网络后重试',
      );
    });
  });
}
