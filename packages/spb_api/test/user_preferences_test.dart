import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 用户偏好端点（`GET|PUT /me/preferences`）的契约测试。
///
/// ## 这个测试防的第一件事：路径前缀
///
/// 服务端把用户级端点挂在 `r.Group("/me")`（与 `/me/turns` 同组），**不在**
/// `apiv1 := r.Group("/api")` 下。写成 `/api/me/preferences` 会 404 —— 而 404 在
/// 前端会静默降级成「偏好区空白」，界面上不报错，极难定位。
///
/// webapp 已用回归测试钉住这一条（`apps/webapp/src/lib/api/user-preferences.test.ts`
/// 的 `expect(pathOf(fetchMock)).toBe("/me/preferences")`），本文件照抄该约束。
///
/// ⚠️ 与之对照：`/api/auth/me` **是**带 `/api` 的。两个端点前缀不同是既有事实，
/// 本文件同时钉住两者，防止有人「统一」掉。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  /// 捕获全部请求的 method + path + body（用于断言「路径正确」与「body 只含提交字段」）。
  late List<({String method, String path, Map<String, dynamic>? body})> calls;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
    calls = [];
    // ⚠️ 「键必须缺席」无法用 DioAdapter 的 `data:` 匹配器表达（它只能断言相等），
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

  /// 服务端 `userPrefResponse` 的真实形状（见 Go `user_preferences.go`）。
  Map<String, dynamic> prefsJson({
    String replyLanguage = 'en',
    bool customized = true,
    bool followUpSuggest = false,
    bool habitSuggest = false,
    bool agentRecommend = true,
    bool agentRecommendSet = false,
    bool goalJudge = false,
    // ⚠️ 服务端 GET 当前**不下发** goal_discovery 两个键（上游 issue #95），
    // 解析侧按「缺省关 / 缺省可用」兑底；服务端修复后此处应同步补键。
    bool goalDiscovery = false,
    String defaultAgentId = '',
    String displayName = '',
    String avatarUrl = '',
    String habitNotifyChannels = '',
    bool habitNotifyChannelsSet = false,
  }) => {
    'reply_language': replyLanguage,
    'available_languages': ['auto', 'zh-CN', 'en', 'ja'],
    'language_labels': {
      'auto': '跟随输入',
      'zh-CN': '简体中文',
      'en': 'English',
      'ja': '日本語',
    },
    'customized': customized,
    'follow_up_suggest': followUpSuggest,
    'follow_up_suggest_available': true,
    'habit_suggest': habitSuggest,
    'habit_suggest_available': true,
    'agent_recommend': agentRecommend,
    'agent_recommend_set': agentRecommendSet,
    'agent_recommend_available': true,
    'goal_judge': goalJudge,
    'goal_judge_available': true,
    'goal_discovery': goalDiscovery,
    'goal_discovery_available': true,
    'default_agent_id': defaultAgentId,
    'display_name': displayName,
    'avatar_url': avatarUrl,
    'habit_notify_channels': habitNotifyChannels,
    'habit_notify_channels_set': habitNotifyChannelsSet,
    'available_channels': [
      {'value': 'wechat_ilink', 'label': '微信'},
      {'value': 'dingtalk', 'label': '钉钉'},
    ],
  };

  group('路径前缀（回归锁）', () {
    test('GET 走 /me/preferences，不带 /api 前缀', () async {
      adapter.onGet(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
      );

      await api.getPreferences();

      expect(calls.single.path, '/me/preferences');
      // 显式断言不带前缀：写成 /api/me/preferences 时上面的 mock 不会命中，
      // 但 404 也可能被误当成「服务端返回空」，故这里再钉一次字面量。
      expect(calls.single.path, isNot(startsWith('/api/')));
    });

    test('PUT 走 /me/preferences，不带 /api 前缀', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(replyLanguage: 'ja')),
        data: Matchers.any,
      );

      await api.updatePreferences(replyLanguage: 'ja');

      expect(calls.single.path, '/me/preferences');
      expect(calls.single.method, 'PUT');
    });

    test('对照：/api/auth/me 仍然带 /api 前缀（不要「统一」两者）', () async {
      adapter.onGet(
        '/api/auth/me',
        (server) => server.reply(200, {
          'id': 'usr_1',
          'email': 'u1@example.com',
          'name': '张三',
          'roles': ['member'],
        }),
      );

      await api.me();

      expect(
        calls.single.path,
        '/api/auth/me',
        reason: '用户偏好与「我是谁」两个端点前缀不同是既有事实',
      );
    });
  });

  group('GET /me/preferences 解析', () {
    test('解析全部字段', () async {
      adapter.onGet(
        '/me/preferences',
        (server) => server.reply(
          200,
          prefsJson(
            replyLanguage: 'ja',
            followUpSuggest: true,
            habitSuggest: true,
            defaultAgentId: 'agent_1',
            displayName: '张三',
            avatarUrl: 'https://cdn.example.com/a.png',
            habitNotifyChannels: 'wechat_ilink,dingtalk',
            habitNotifyChannelsSet: true,
          ),
        ),
      );

      final p = await api.getPreferences();

      expect(p.replyLanguage, 'ja');
      expect(p.availableLanguages, ['auto', 'zh-CN', 'en', 'ja']);
      expect(p.customized, isTrue);
      expect(p.followUpSuggest, isTrue);
      expect(p.habitSuggest, isTrue);
      // 本 fixture 未覆盖 available 开关（恒 true）：急停语义见下方专门组。
      expect(p.followUpSuggestAvailable, isTrue);
      expect(p.agentRecommend, isTrue);
      expect(p.agentRecommendSet, isFalse);
      expect(p.goalJudge, isFalse);
      expect(p.goalDiscovery, isFalse);
      expect(p.goalDiscoveryAvailable, isTrue);
      expect(p.defaultAgentId, 'agent_1');
      expect(p.displayName, '张三');
      expect(p.avatarUrl, 'https://cdn.example.com/a.png');
      expect(p.habitNotifyChannels, 'wechat_ilink,dingtalk');
      expect(p.habitNotifyChannelsSet, isTrue);
      expect(p.availableChannels.map((c) => c.value), [
        'wechat_ilink',
        'dingtalk',
      ]);
      expect(p.availableChannels.first.label, '微信');
    });

    test('label 由服务端下发，客户端不自算中文名', () async {
      // 渠道白名单真源在 mq-server（跨仓），中文名真源在 Go outboundchannel。
      // 客户端硬编码必然漂移，且「微信」是个人微信（iLink 桥接）、
      // 「企业微信」是另一产品——叫法混淆会让用户选错渠道。
      adapter.onGet(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
      );

      final p = await api.getPreferences();

      expect(p.availableChannels.map((c) => c.label), ['微信', '钉钉']);
    });

    test('字段缺失时不抛异常，reply_language 回落 auto', () async {
      // 服务端声称 reply_language 恒有值，但客户端仍不该因字段缺失而崩。
      adapter.onGet(
        '/me/preferences',
        (server) => server.reply(200, <String, dynamic>{}),
      );

      final p = await api.getPreferences();

      expect(p.replyLanguage, kLanguageAuto);
      expect(p.isReplyLanguageAuto, isTrue);
      expect(p.availableLanguages, isEmpty);
      expect(p.availableChannels, isEmpty);
    });

    test('400 抛 HttpError（不静默返回空偏好）', () async {
      adapter.onGet(
        '/me/preferences',
        (server) => server.reply(400, {'error': 'bad request'}),
      );

      await expectLater(
        () => api.getPreferences(),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });
  });

  group('PUT /me/preferences：只提交显式传入的键', () {
    test('只传 replyLanguage → body 只有 reply_language', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(replyLanguage: 'ja')),
        data: Matchers.any,
      );

      await api.updatePreferences(replyLanguage: 'ja');

      expect(calls.single.body, {'reply_language': 'ja'});
    });

    test('只传 displayName → 不动回复语言（部分更新语义）', () async {
      // 若提交完整对象，未编辑的字段会被一并覆盖——例如只改昵称却把回复语言
      // 重置成 auto，用户会看到「改个名字语言也变了」。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(displayName: '张三')),
        data: Matchers.any,
      );

      await api.updatePreferences(displayName: '张三');

      expect(calls.single.body, {'display_name': '张三'});
      expect(calls.single.body!.containsKey('reply_language'), isFalse);
      expect(calls.single.body!.containsKey('default_agent_id'), isFalse);
    });

    test('四个字段同传时全部映射到 snake_case', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
        data: Matchers.any,
      );

      await api.updatePreferences(
        displayName: '张三',
        avatarUrl: 'https://cdn.example.com/a.png',
        replyLanguage: 'zh-CN',
        defaultAgentId: 'agent_1',
      );

      expect(calls.single.body, {
        'display_name': '张三',
        'avatar_url': 'https://cdn.example.com/a.png',
        'reply_language': 'zh-CN',
        'default_agent_id': 'agent_1',
      });
    });

    test('空串是有效入参（清除），不是「不传」', () async {
      // displayName:'' 清除自设昵称（展示侧回落 users.name）；
      // defaultAgentId:'' 恢复「跟随系统默认」（服务端删记录）。
      // 两者语义不同，但都必须**真的发出去**。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
        data: Matchers.any,
      );

      await api.updatePreferences(displayName: '', defaultAgentId: '');

      expect(calls.single.body, {'display_name': '', 'default_agent_id': ''});
      expect(calls.single.body!.containsKey('display_name'), isTrue);
    });

    test('auto 原样发给后端（由后端删记录，客户端不特殊处理）', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(replyLanguage: 'auto')),
        data: Matchers.any,
      );

      await api.updatePreferences(replyLanguage: 'auto');

      expect(calls.single.body, {'reply_language': 'auto'});
    });

    test('习惯推送渠道原样提交逗号分隔串（含 off 哨兵）', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
        data: Matchers.any,
      );

      await api.updatePreferences(habitNotifyChannels: 'wechat_ilink,feishu');

      expect(calls.single.body, {
        'habit_notify_channels': 'wechat_ilink,feishu',
      });
    });

    test('只传 followUpSuggest → body 恰好只有 follow_up_suggest 一个键', () async {
      // 验收明确要求：服务端是部分更新语义，多送一个键就会覆盖用户没改的项。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(followUpSuggest: true)),
        data: Matchers.any,
      );

      await api.updatePreferences(followUpSuggest: true);

      expect(calls.single.body, {'follow_up_suggest': true});
      expect(calls.single.body!.keys, hasLength(1));
    });

    test('只传 habitSuggest → body 恰好只有 habit_suggest 一个键', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(habitSuggest: true)),
        data: Matchers.any,
      );

      await api.updatePreferences(habitSuggest: true);

      expect(calls.single.body, {'habit_suggest': true});
      expect(calls.single.body!.keys, hasLength(1));
    });

    test('只传 agentRecommend → body 恰好只有 agent_recommend 一个键', () async {
      // agent_recommend 缺省**开**：显式关闭（false）是最常见的写路径，
      // 必须真的发出去。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(agentRecommend: false)),
        data: Matchers.any,
      );

      await api.updatePreferences(agentRecommend: false);

      expect(calls.single.body, {'agent_recommend': false});
      expect(calls.single.body!.keys, hasLength(1));
    });

    test('只传 goalJudge → body 恰好只有 goal_judge 一个键', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(goalJudge: true)),
        data: Matchers.any,
      );

      await api.updatePreferences(goalJudge: true);

      expect(calls.single.body, {'goal_judge': true});
      expect(calls.single.body!.keys, hasLength(1));
    });

    test('只传 goalDiscovery → body 恰好只有 goal_discovery 一个键', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(goalDiscovery: true)),
        data: Matchers.any,
      );

      await api.updatePreferences(goalDiscovery: true);

      expect(calls.single.body, {'goal_discovery': true});
      expect(calls.single.body!.keys, hasLength(1));
    });

    test('五个 bool 的 false 会真的发出去（不是「不传」）', () async {
      // 若写成 `if (x == true)` 就永远无法关闭这五个开关——
      // false 是**有意义的显式关闭**，与「不传」（保持原值）必须区分。
      // agent_recommend 缺省开，把它关掉正是本开关最主要的用途。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson()),
        data: Matchers.any,
      );

      await api.updatePreferences(
        followUpSuggest: false,
        habitSuggest: false,
        agentRecommend: false,
        goalJudge: false,
        goalDiscovery: false,
      );

      expect(calls.single.body, {
        'follow_up_suggest': false,
        'habit_suggest': false,
        'agent_recommend': false,
        'goal_judge': false,
        'goal_discovery': false,
      });
    });

    test('五个 bool 不传时 body 不得出现对应键', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(200, prefsJson(displayName: '张三')),
        data: Matchers.any,
      );

      await api.updatePreferences(displayName: '张三');

      expect(calls.single.body!.containsKey('follow_up_suggest'), isFalse);
      expect(calls.single.body!.containsKey('habit_suggest'), isFalse);
      expect(calls.single.body!.containsKey('agent_recommend'), isFalse);
      expect(calls.single.body!.containsKey('goal_judge'), isFalse);
      expect(calls.single.body!.containsKey('goal_discovery'), isFalse);
    });

    group('五个 reminder 开关的 available 急停下发', () {
      // 运维急停（*_DISABLED env）只影响 available，**不改写**开关本身。
      // 客户端把「未下发」当可用处理（缺省 true），避免加载中闪一次误导性的
      // 「已停用」提示。
      test('available=false 时如实解析为不可用', () async {
        adapter.onGet(
          '/me/preferences',
          (server) => server.reply(
            200,
            prefsJson()
              ..['follow_up_suggest_available'] = false
              ..['habit_suggest_available'] = false
              ..['agent_recommend_available'] = false
              ..['goal_judge_available'] = false
              ..['goal_discovery_available'] = false,
          ),
        );

        final p = await api.getPreferences();

        expect(p.followUpSuggestAvailable, isFalse);
        expect(p.habitSuggestAvailable, isFalse);
        expect(p.agentRecommendAvailable, isFalse);
        expect(p.goalJudgeAvailable, isFalse);
        expect(p.goalDiscoveryAvailable, isFalse);
        // 急停不改写开关本身：解除后用户的原设置自动恢复生效。
        expect(p.agentRecommend, isTrue);
      });

      test('available 缺失（旧响应）按可用处理', () async {
        adapter.onGet(
          '/me/preferences',
          (server) => server.reply(200, <String, dynamic>{}),
        );

        final p = await api.getPreferences();

        expect(p.followUpSuggestAvailable, isTrue);
        expect(p.habitSuggestAvailable, isTrue);
        expect(p.agentRecommendAvailable, isTrue);
        expect(p.goalJudgeAvailable, isTrue);
        expect(p.goalDiscoveryAvailable, isTrue);
      });

      test('agent_recommend 缺省开：未表态（键缺失）时解析为 true', () async {
        adapter.onGet(
          '/me/preferences',
          (server) => server.reply(200, <String, dynamic>{}),
        );

        final p = await api.getPreferences();

        expect(p.agentRecommend, isTrue);
        expect(p.agentRecommendSet, isFalse);
        // 对照：follow_up / habit / goal_judge 缺省关。
        expect(p.followUpSuggest, isFalse);
        expect(p.habitSuggest, isFalse);
        expect(p.goalJudge, isFalse);
      });

      test('agent_recommend_set=true 区分「显式开启」与「默认开」', () async {
        adapter.onGet(
          '/me/preferences',
          (server) => server.reply(200, prefsJson(agentRecommendSet: true)),
        );

        final p = await api.getPreferences();

        expect(p.agentRecommend, isTrue);
        expect(p.agentRecommendSet, isTrue);
      });
    });

    test('非法 reply_language → 400 抛 HttpError（不静默回落 auto）', () async {
      // 服务端显式校验而非静默归一化：用户传 "fr" 必须得到错误反馈，
      // 否则会误以为已生效。调用方需把该错误透出给用户。
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(400, {
          'error': 'unsupported reply_language: fr',
          'supported': ['auto', 'zh-CN', 'en', 'ja'],
        }),
        data: Matchers.any,
      );

      await expectLater(
        () => api.updatePreferences(replyLanguage: 'fr'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              // ⚠️ `message` 恒为 "HTTP 400"（_unwrap 的构造），服务端文案在
              // `body` 里——UI 要展示它必须从 body 提取，不能直接显示 message。
              .having((e) => e.message, 'message', 'HTTP 400')
              .having(
                (e) => e.body,
                'body',
                allOf(contains('unsupported reply_language'), contains('fr')),
              ),
        ),
      );
    });

    test('返回的是服务端回读的生效值（可直接替换本地状态）', () async {
      adapter.onPut(
        '/me/preferences',
        (server) => server.reply(
          200,
          // 服务端把 auto 归一化后回读：客户端应直接采用该结果。
          prefsJson(replyLanguage: 'auto', customized: false),
        ),
        data: Matchers.any,
      );

      final p = await api.updatePreferences(replyLanguage: 'auto');

      expect(p.replyLanguage, 'auto');
      expect(p.customized, isFalse);
      expect(p.isReplyLanguageAuto, isTrue);
    });
  });

  group('UserPreferences 语义 getter（空串是合法状态，不是 null）', () {
    test('default_agent_id 空串 = 「自动」', () {
      final p = UserPreferences.fromJson(prefsJson(defaultAgentId: ''));
      expect(p.defaultAgentIsAuto, isTrue);
      expect(p.defaultAgentId, '');
    });

    test('display_name / avatar_url 空串 = 未设置', () {
      final p = UserPreferences.fromJson(prefsJson());
      expect(p.hasCustomDisplayName, isFalse);
      expect(p.hasCustomAvatar, isFalse);
    });

    test('habit_notify_channels 空串 + set=false = 未设置（不是「关闭」）', () {
      // 两者语义相反：未设置应显示默认选中项，显式关闭应显示「已关闭」。
      final p = UserPreferences.fromJson(
        prefsJson(habitNotifyChannels: '', habitNotifyChannelsSet: false),
      );
      expect(p.habitNotifyDisabled, isFalse);
      expect(p.selectedHabitChannels, isEmpty);
    });

    test('habit_notify_channels = off + set=true = 显式关闭', () {
      final p = UserPreferences.fromJson(
        prefsJson(habitNotifyChannels: 'off', habitNotifyChannelsSet: true),
      );
      expect(p.habitNotifyDisabled, isTrue);
      expect(p.selectedHabitChannels, isEmpty);
    });

    test('渠道列表解析：trim + 去空 + 去重前的原样拆分', () {
      final p = UserPreferences.fromJson(
        prefsJson(
          habitNotifyChannels: ' wechat_ilink , dingtalk ,, feishu ',
          habitNotifyChannelsSet: true,
        ),
      );
      expect(p.selectedHabitChannels, ['wechat_ilink', 'dingtalk', 'feishu']);
    });

    test('languageLabel 取服务端下发的展示名', () {
      final p = UserPreferences.fromJson(prefsJson());
      expect(p.languageLabel('zh-CN'), '简体中文');
      expect(p.languageLabel('auto'), '跟随输入');
      // 缺键时回落原始标签（返回空串会让 UI 显示空白，像是选项坏了）。
      expect(p.languageLabel('fr'), 'fr');
    });

    test('reply_language 空串也算 auto（服务端把两者同构处理）', () {
      final p = UserPreferences.fromJson(prefsJson(replyLanguage: ''));
      expect(p.isReplyLanguageAuto, isTrue);
    });
  });

  group('CurrentUser 的展示回落', () {
    test('avatarUrl 从 raw 读取（空串 = 未设置）', () {
      final u = CurrentUser.fromJson({
        'id': 'usr_1',
        'email': 'u1@example.com',
        'name': '张三',
        'avatar_url': 'https://cdn.example.com/a.png',
      });
      expect(u.avatarUrl, 'https://cdn.example.com/a.png');
      expect(u.hasName, isTrue);
    });

    test('name 为空时回落到 email；avatar_url 缺失时为空串', () {
      // 服务端 `GET /api/auth/me` 已按 display_name → users.name → email
      // 解析好 name，客户端不该自己再拼一遍回退链。
      final u = CurrentUser.fromJson({
        'id': 'usr_1',
        'email': 'u1@example.com',
        'name': '',
      });
      expect(u.hasName, isFalse);
      expect(u.displayNameFallback, 'u1@example.com');
      expect(u.avatarUrl, '');
    });
  });
}
