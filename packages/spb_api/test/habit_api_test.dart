import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `HabitApi` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 1. **路径**：习惯端点分散在 `/api/habits*`、`/api/chat/habit-suggestions*`、
///    `/api/chat/habit-insights/*` 三处（`ext_routes.go` / `habits_full.go` /
///    `misc_extra.go` / `habit_insights.go`）。`/me/habits` **只有** create 与
///    trigger 两个别名——误把它当完整前缀会 404。
/// 2. **4xx 不抛 DioException**：`createDio` 的 `validateStatus` 放行 <500，
///    故 `pauseHabit`（`Future<void>`）若不做状态码检查，「409 状态不符」会被
///    当成成功——UI 显示已暂停而服务端从未改状态。
/// 3. **请求体形状**：`trigger_config` 必须是对象（服务端校验 `必须是 JSON 对象`）；
///    `snooze_until` 必须是 UTC RFC3339 串（服务端解析失败会**静默**回退冷却时长）。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late HabitApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = HabitApi(dio);
  });

  group('路径与前缀', () {
    test('listHabits 打 /api/habits（不是 /me/habits）', () async {
      adapter.onGet(
        '/api/habits',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 50, 'offset': 0},
      );

      expect(await api.listHabits(), isEmpty);
    });

    test(
      'runs 打 /api/habits/runs（在 /:pattern_id 之前，不能被当成 pattern id）',
      () async {
        adapter.onGet(
          '/api/habits/runs',
          (server) => server.reply(200, {'items': <dynamic>[]}),
          queryParameters: {'limit': 50},
        );

        expect(await api.listAllRuns(), isEmpty);
      },
    );

    test('suggestions 打 /api/chat/habit-suggestions（带 status）', () async {
      adapter.onGet(
        '/api/chat/habit-suggestions',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'status': 'pending'},
      );

      expect(await api.listSuggestions(), isEmpty);
    });

    test('dismissed 过滤器传 status=dismissed', () async {
      adapter.onGet(
        '/api/chat/habit-suggestions',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'status': 'dismissed'},
      );

      expect(
        await api.listSuggestions(filter: HabitSuggestionListFilter.dismissed),
        isEmpty,
      );
    });

    test('insights 打 /api/chat/habit-insights/summary', () async {
      adapter.onGet(
        '/api/chat/habit-insights/summary',
        (server) => server.reply(200, {
          'window': {'days': 30, 'start_at': '2026-09-04T00:00:00Z'},
          'suggestions': {'created_count': 0},
          'due_rules': {'trigger_count': 0},
          'signal_coverage': {'coverage_rate': 0.0},
        }),
        queryParameters: {'days': 30},
      );

      final s = await api.habitInsights();
      expect(s.days, 30);
    });
  });

  group('写操作的状态码必须显式检查（4xx 不抛 DioException）', () {
    test('pause 收到 409 时抛 HttpError（而不是静默成功）', () async {
      adapter.onPost(
        '/api/habits/hp-1/pause',
        (server) => server.reply(409, {'error': '仅 active 状态可暂停，当前: paused'}),
      );

      await expectLater(
        api.pauseHabit('hp-1'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.isConflict, 'isConflict', isTrue)
              .having((e) => e.message, 'message', contains('仅 active')),
        ),
      );
    });

    test('trigger 收到 409 时抛 HttpError', () async {
      adapter.onPost(
        '/api/habits/hp-1/trigger',
        (server) => server.reply(409, {'error': '仅 active 状态可触发，当前: paused'}),
      );

      await expectLater(
        api.triggerHabit('hp-1'),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'code', 409)),
      );
    });

    test('resolveSuggestion 收到 409（CAS 未命中）抛 HttpError', () async {
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(409, {'error': '建议已被处理或状态不符'}),
        data: Matchers.any,
      );

      await expectLater(
        api.resolveSuggestion('run-1', action: HabitSuggestionAction.accept),
        throwsA(isA<HttpError>().having((e) => e.statusCode, 'code', 409)),
      );
    });

    test('404 抛 HttpError 且 isNotFound', () async {
      adapter.onGet(
        '/api/habits/nope',
        (server) => server.reply(404, {'error': 'habit pattern 不存在'}),
      );

      await expectLater(
        api.getHabit('nope'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });

    test('archive 的 4xx 不会被吞（Future<void> 也要判码）', () async {
      adapter.onPost(
        '/api/habits/hp-1/archive',
        (server) => server.reply(404, {'error': 'habit pattern 不存在'}),
      );

      await expectLater(api.archiveHabit('hp-1'), throwsA(isA<HttpError>()));
    });
  });

  group('请求体形状', () {
    test('createHabit 的 trigger_config 是对象，不是 JSON 字符串', () async {
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/habits',
        (server) => server.reply(201, {
          'pattern_id': 'hp-1',
          'group_id': 'grp-1',
          'topic_id': 'topic-1',
          'next_fire_at': '2026-10-05T01:00:00Z',
        }),
        data: Matchers.any,
      );
      // DioAdapter 的 data 匹配器不能回传实参，故用拦截器抓请求体。
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      final r = await api.createHabit(
        topicKey: 'weekly-report',
        acceptanceLevel: HabitAcceptanceLevel.suggestOnly,
        triggerConfig: const HabitTriggerConfig(
          triggerType: HabitTriggerType.timeBased,
          time: HabitTimeTriggerConfig(
            times: [HabitTimeOfDay(hour: 9, minute: 30)],
            weekdays: [1],
          ),
        ),
        preferredAgentId: 'agt-1',
      );

      expect(r.patternId, 'hp-1');
      expect(r.groupId, 'grp-1');
      expect(captured!['topic_key'], 'weekly-report');
      expect(captured!['acceptance_level'], 'suggest_only');
      expect(captured!['preferred_agent_id'], 'agt-1');
      // 服务端校验 `trigger_config 必须是 JSON 对象`——传字符串会 400。
      final cfg = captured!['trigger_config'];
      expect(cfg, isA<Map<String, dynamic>>());
      expect(cfg['weekday'], [1]);
      expect(cfg['times'], [
        {'hour': 9, 'minute': 30},
      ]);
    });

    test('patchHabit 只发显式传入的字段（PATCH 语义）', () async {
      Map<String, dynamic>? captured;
      adapter.onPatch(
        '/api/habits/hp-1',
        (server) => server.reply(200, {'updated': true, 'pattern_id': 'hp-1'}),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      await api.patchHabit(
        'hp-1',
        acceptanceLevel: HabitAcceptanceLevel.autoRun,
      );

      expect(captured!.keys, ['acceptance_level']);
      expect(captured!['acceptance_level'], 'auto_run');
    });

    test('patchHabit 能改 topic_key（服务端 update 接受它）', () async {
      Map<String, dynamic>? captured;
      adapter.onPatch(
        '/api/habits/hp-1',
        (server) => server.reply(200, {'updated': true, 'pattern_id': 'hp-1'}),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      await api.patchHabit('hp-1', topicKey: 'weekly-report');

      expect(captured!.keys, ['topic_key']);
      expect(captured!['topic_key'], 'weekly-report');
    });

    test('patchHabit 的 preferredAgentId 空串原样发送（服务端当清除）', () async {
      // 服务端 `PreferredAgentID json.RawMessage` 三态：nil=未传、null=清除、
      // `"x"`=设置；随后 `toNullString(TrimSpace(v))` 把空串也归成「无效」=清除。
      // 故空串必须真的发出去（不能被 `if (x != null)` 之类的过滤吃掉）。
      Map<String, dynamic>? captured;
      adapter.onPatch(
        '/api/habits/hp-1',
        (server) => server.reply(200, {'updated': true, 'pattern_id': 'hp-1'}),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      await api.patchHabit('hp-1', preferredAgentId: '');

      expect(captured!.containsKey('preferred_agent_id'), isTrue);
      expect(captured!['preferred_agent_id'], '');
    });

    test('resolveSuggestion 的 snooze_until 是 UTC RFC3339（无毫秒）', () async {
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(200, {
          'resolved': true,
          'suggestion': {'id': 'run-1', 'user_feedback': 'snoozed'},
          'pattern_id': '',
        }),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      final r = await api.resolveSuggestion(
        'run-1',
        action: HabitSuggestionAction.snooze,
        snoozeUntil: DateTime.utc(2026, 10, 5),
      );

      expect(r.resolved, isTrue);
      expect(captured!['action'], 'snooze');
      // 服务端 domain.ParseISO 解析失败会**静默**回退冷却时长，故格式必须对。
      expect(captured!['snooze_until'], '2026-10-05T00:00:00Z');
    });

    test('accept 请求体用 accept（不是 accept_rule）', () async {
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(200, {
          'resolved': true,
          'suggestion': {'id': 'run-1', 'user_feedback': 'accepted'},
          'pattern_id': 'hp-new',
        }),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      final r = await api.resolveSuggestion(
        'run-1',
        action: HabitSuggestionAction.accept,
      );

      // 请求体是 accept；服务端写库才映射成 accepted（mapFeedbackValue）。
      expect(captured!['action'], 'accept');
      expect(captured!.containsKey('snooze_until'), isFalse);
      // 响应里的建出 pattern 用 pattern_id 键（事件 payload 里叫
      // resolved_pattern_id——两处不同名）。
      expect(r.patternId, 'hp-new');
      expect(r.suggestion!.userFeedback, HabitUserFeedback.accepted);
    });

    test('edit_and_accept 带 pattern_patch（服务端只在该 action 消费它）', () async {
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(200, {
          'resolved': true,
          'suggestion': {'id': 'run-1', 'user_feedback': 'accepted'},
          'pattern_id': 'hp-new',
        }),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      final r = await api.resolveSuggestion(
        'run-1',
        action: HabitSuggestionAction.editAndAccept,
        patternPatch: {
          'topic_key': 'weekly-report-v2',
          'trigger_config': {
            'times': [
              {'hour': 10, 'minute': 30},
            ],
            'weekday': [2, 4],
          },
        },
      );

      expect(captured!['action'], 'edit_and_accept');
      expect(captured!['pattern_patch'], isA<Map<String, dynamic>>());
      final patch = captured!['pattern_patch'] as Map<String, dynamic>;
      // 键名原样透传：服务端 applyPatternPatch 认 topic_key 与嵌套 trigger_config。
      expect(patch['topic_key'], 'weekly-report-v2');
      expect(patch['trigger_config'], {
        'times': [
          {'hour': 10, 'minute': 30},
        ],
        'weekday': [2, 4],
      });
      expect(r.resolved, isTrue);
    });

    test('edit_and_accept 的 patch 可只含一个键（增量而非整包替换）', () async {
      // 服务端 applyPatternPatch 的合并语义是「出现即覆盖、未出现即保留」，
      // 故客户端不必（也不应）回填未改的字段——回填会把用户在别处的修改覆盖。
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(200, {
          'resolved': true,
          'suggestion': {'id': 'run-1', 'user_feedback': 'accepted'},
          'pattern_id': 'hp-new',
        }),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      await api.resolveSuggestion(
        'run-1',
        action: HabitSuggestionAction.editAndAccept,
        patternPatch: {'preferred_agent_id': null},
      );

      final patch = captured!['pattern_patch'] as Map<String, dynamic>;
      // ⚠️ 显式 null 与「不传该键」不同：服务端把 null 解释为「清除指定 agent」。
      // 若把 null 过滤掉（如用 whereValueNotNull），用户就永远清不掉。
      expect(patch.containsKey('preferred_agent_id'), isTrue);
      expect(patch['preferred_agent_id'], isNull);
      expect(patch.containsKey('topic_key'), isFalse);
      expect(patch.containsKey('trigger_config'), isFalse);
    });

    test('其他 action 即使传了 patternPatch 也不下发（服务端不消费）', () async {
      // 服务端 PatternPatch 字段注释明写「仅 edit_and_accept 消费」。其余 action
      // 带上它只会让服务端白跑一次 applyPatternPatch，且可能被将来的校验逻辑
      // 当成异常输入。
      for (final action in [
        HabitSuggestionAction.accept,
        HabitSuggestionAction.dismiss,
        HabitSuggestionAction.snooze,
      ]) {
        Map<String, dynamic>? captured;
        adapter.onPost(
          '/api/chat/habit-suggestions/run-1/resolve',
          (server) => server.reply(200, {
            'resolved': true,
            'suggestion': {'id': 'run-1'},
            'pattern_id': '',
          }),
          data: Matchers.any,
        );
        final interceptor = InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        );
        dio.interceptors.add(interceptor);

        await api.resolveSuggestion(
          'run-1',
          action: action,
          patternPatch: {'topic_key': 'should-not-be-sent'},
        );

        expect(
          captured!.containsKey('pattern_patch'),
          isFalse,
          reason: '${action.wire} 不是 edit_and_accept，不应下发 pattern_patch',
        );
        dio.interceptors.remove(interceptor);
      }
    });

    test('edit_and_accept 不传 patternPatch 时不下发该键（等价于 accept）', () async {
      Map<String, dynamic>? captured;
      adapter.onPost(
        '/api/chat/habit-suggestions/run-1/resolve',
        (server) => server.reply(200, {
          'resolved': true,
          'suggestion': {'id': 'run-1', 'user_feedback': 'accepted'},
          'pattern_id': 'hp-new',
        }),
        data: Matchers.any,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options.data as Map<String, dynamic>?;
            handler.next(options);
          },
        ),
      );

      await api.resolveSuggestion(
        'run-1',
        action: HabitSuggestionAction.editAndAccept,
      );

      expect(captured!['action'], 'edit_and_accept');
      expect(captured!.containsKey('pattern_patch'), isFalse);
    });
  });

  group('响应解析', () {
    test(
      'listAllRuns 吃 habitRunsWithReply 形状（run_id / topic_key / reply_text）',
      () async {
        adapter.onGet(
          '/api/habits/runs',
          (server) => server.reply(200, {
            'items': [
              {
                'run_id': 'run-1',
                'pattern_id': 'hp-1',
                'topic_key': 'weekly-report',
                'trigger_reason': 'due_rule',
                'outcome': 'completed',
                'created_at': '2026-10-04T01:30:00Z',
                'reply_text': '已生成周报',
                'is_manual': true,
              },
            ],
          }),
          queryParameters: {'limit': 50},
        );

        final runs = await api.listAllRuns();
        expect(runs.single.id, 'run-1');
        expect(runs.single.topicKey, 'weekly-report');
        expect(runs.single.replyText, '已生成周报');
        expect(runs.single.isManual, isTrue);
      },
    );

    test('listAllRuns 把 days / trigger_reason 放进 query string', () async {
      // ⚠️ 回归锁：服务端 `allRuns` 只在 query 里读到这两个参数才过滤。
      // 漏发（或发错名）不会报错——只是「筛选没生效」，用户以为没有记录。
      adapter.onGet(
        '/api/habits/runs',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'days': 7, 'limit': 50, 'trigger_reason': 'due_rule'},
      );

      expect(
        await api.listAllRuns(days: 7, triggerReason: 'due_rule'),
        isEmpty,
      );
    });

    test('listAllRuns 的 trigger_reason 为空串时不发该参数', () async {
      // 空串 = 「不筛」。发空串服务端也会当不筛，但会多一个无意义参数
      // （且 mock 的 query 断言能揭出这类差异）。
      adapter.onGet(
        '/api/habits/runs',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 50},
      );

      expect(await api.listAllRuns(triggerReason: ''), isEmpty);
    });

    test('listAllRunsWithBudget 解析 daily_budget（今日已用/上限）', () async {
      // ⚠️ 回归锁：`unwrapItems` 只看 `items`，会把 `daily_budget` **静默
      // 丢掉**。丢掉的后果是「额度用完了但页面上看不到」，用户只能反复点
      // 「立即执行」收 409。
      adapter.onGet(
        '/api/habits/runs',
        (server) => server.reply(200, {
          'items': [
            {'run_id': 'run-1', 'trigger_reason': 'due_rule'},
          ],
          'daily_budget': {'limit': 20, 'used_today': 3},
        }),
        queryParameters: {'days': 30, 'limit': 50},
      );

      final result = await api.listAllRunsWithBudget(days: 30);
      expect(result.items.single.id, 'run-1');
      expect(result.dailyBudget, isNotNull);
      expect(result.dailyBudget!.limit, 20);
      expect(result.dailyBudget!.usedToday, 3);
      expect(result.dailyBudget!.remaining, 17);
      expect(result.dailyBudget!.exhausted, isFalse);
    });

    test('listAllRunsWithBudget 的 daily_budget 缺失时为 null', () async {
      // 旧版服务端 / 端点变更时不造一个假的 0/0（那会渲染成「0 / 0 已用尽」）。
      adapter.onGet(
        '/api/habits/runs',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 50},
      );

      final result = await api.listAllRunsWithBudget();
      expect(result.items, isEmpty);
      expect(result.dailyBudget, isNull);
    });

    test('listHabitRuns 打 /api/habits/:id/runs 且只发 limit/offset', () async {
      // ⚠️ 单规则端点**没有** days/trigger_reason（服务端 SQL `ListHabitRuns`
      // 无时间窗）。多传会被静默忽略，故这里断言只发这两个参数。
      adapter.onGet(
        '/api/habits/hp-1/runs',
        (server) => server.reply(200, {'items': <dynamic>[]}),
        queryParameters: {'limit': 20, 'offset': 40},
      );

      expect(await api.listHabitRuns('hp-1', limit: 20, offset: 40), isEmpty);
    });

    test(
      'listSuggestions 吃 habitRunToMap 形状（id / trigger_context_json）',
      () async {
        adapter.onGet(
          '/api/chat/habit-suggestions',
          (server) => server.reply(200, {
            'items': [
              {
                'id': 'run-sugg',
                'habit_pattern_id': null,
                'trigger_reason': 'candidate_detected',
                'outcome': 'suggested',
                'user_feedback': null,
                'trigger_context_json': '{"topic_key":"daily-standup"}',
              },
            ],
          }),
          queryParameters: {'status': 'pending'},
        );

        final s = (await api.listSuggestions()).single;
        expect(s.id, 'run-sugg');
        expect(s.topicKey, 'daily-standup');
        expect(s.isPending, isTrue);
      },
    );

    test(
      'listSuggestions 也吃对象形态的 trigger_context / feedback_payload',
      () async {
        // ⚠️ 回归锁：真实 `habitRunToMap` 下发的是**对象**（不是 `*_json` 字符串）。
        // 只读字符串形态会让候选卡静默变成「未命名 / 无理由」，且已处理项
        // 显示不出「习惯已生效」——不会报错，比 500 更难发现。
        adapter.onGet(
          '/api/chat/habit-suggestions',
          (server) => server.reply(200, {
            'items': [
              {
                'id': 'run-obj',
                'trigger_reason': 'candidate_detected',
                'outcome': 'suggested',
                'user_feedback': 'accepted',
                'trigger_context': {
                  'topic_key': 'weekly-report',
                  'reasons': ['每周一你都会让我写周报'],
                },
                'feedback_payload': {
                  'action': 'accept',
                  'resolved_pattern_id': 'hp-1',
                },
              },
            ],
          }),
          queryParameters: {'status': 'pending'},
        );

        final s = (await api.listSuggestions()).single;
        expect(s.topicKey, 'weekly-report');
        expect(s.reasons, ['每周一你都会让我写周报']);
        expect(s.feedbackPayload?['resolved_pattern_id'], 'hp-1');
        expect(s.hasResolvedPattern, isTrue);
      },
    );

    test('resumeHabit 返回新的 next_fire_at（sql.NullTime 形态也能解）', () async {
      adapter.onPost(
        '/api/habits/hp-1/resume',
        (server) => server.reply(200, {
          'resumed': true,
          'next_fire_at': '2026-10-06T01:00:00Z',
        }),
      );

      final next = await api.resumeHabit('hp-1');
      expect(next, isNotNull);
      expect(next!.toUtc().day, 6);
    });

    test('triggerHabit 读出 schedule_id / turn_id', () async {
      adapter.onPost(
        '/api/habits/hp-1/trigger',
        (server) => server.reply(200, {
          'triggered': true,
          'schedule_id': 'sched-1',
          'turn_id': 'sched-1',
        }),
      );

      final r = await api.triggerHabit('hp-1');
      expect(r.triggered, isTrue);
      expect(r.turnId, 'sched-1');
    });
  });
}
