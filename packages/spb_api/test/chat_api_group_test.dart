import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

import 'support/chat_api_harness.dart';

/// ChatApi 的群级配置契约测试（上传 / routing / 群开关 / goal / flush / habit）
///
/// ⚠️ 本文件由 `chat_api_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/chat_api_harness.dart`。
void main() {
  setUpHarness();

  group('uploadWorkspaceFile（交付物回传）', () {
    /// ufsUpload 的真实响应形状（`workspace_sync.go` 尾部 + `fileEntryToMap`）。
    Map<String, dynamic> ufsUploadShape({
      String relativePath = 'reports/x.md',
      int size = 12,
    }) => {
      'group_id': 'grp_1',
      'relative_path': relativePath,
      'file': {
        'id': 'ufs_file_1',
        'name': 'x.md',
        'path': 'workspace/groups/grp_1/$relativePath',
        'size': size,
        'mime_type': 'text/markdown; charset=utf-8',
        'is_directory': false,
        'updated_at': '2026-09-30T00:00:00Z',
        // 注意：故意不放 etag —— fileEntryToMap 不回 etag，这是契约。
      },
      'absolute_path': '/opt/<app>/workspace/groups/grp_1/$relativePath',
      'size_bytes': size,
      'sync_status': 'local_synced',
      'needs_local_sync': false,
    };

    test('bytes 上传：URL/method/表单字段正确，响应字段解析', () async {
      // FormDataMatcher 比较字段名/文件名/长度，不比内容 —— 兼 relative_path
      // 字段在 fields 里，所以能断言到它；这正挡住了「忘传 relative_path」
      // 这种 bug（服务端会回退用文件名，文件落到错误位置）。
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/ufs-upload',
        (server) => server.reply(200, ufsUploadShape()),
        data: Matchers.formData(
          FormData.fromMap({
            'file': MultipartFile.fromBytes(
              [1, 2, 3],
              filename: 'x.md',
              contentType: DioMediaType.parse('text/markdown'),
            ),
            'relative_path': 'reports/x.md',
          }),
        ),
      );

      final result = await api.uploadWorkspaceFile(
        groupId: 'grp_1',
        relativePath: 'reports/x.md',
        bytes: [1, 2, 3],
        filename: 'x.md',
        contentType: 'text/markdown',
      );

      expect(result.groupId, 'grp_1');
      expect(result.relativePath, 'reports/x.md');
      expect(result.fileId, 'ufs_file_1');
      expect(result.fileName, 'x.md');
      expect(result.fileSize, 12);
      expect(result.sizeBytes, 12);
      expect(result.syncStatus, 'local_synced');
      expect(result.isLocalSynced, isTrue);
      expect(result.absolutePath, isNotNull);
      // 响应里没有 etag（fileEntryToMap 不回），模型也刻意不提供该字段：
      // 调用方无法据此 markSynced（写个空 etag 会让下轮预检永远判冲突）。
      expect(result.raw.containsKey('etag'), isFalse);
    });

    test('path 上传：从磁盘流式读取（大文件不进内存第二份）', () async {
      final tmp = await Directory.systemTemp.createTemp('spb-upload-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/x.md')..writeAsBytesSync([9, 9, 9]);

      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/ufs-upload',
        (server) => server.reply(200, ufsUploadShape()),
        data: Matchers.formData(
          FormData.fromMap({
            'file': await MultipartFile.fromFile(
              file.path,
              filename: 'x.md',
              contentType: DioMediaType.parse('text/markdown'),
            ),
            'relative_path': 'reports/x.md',
          }),
        ),
      );

      final result = await api.uploadWorkspaceFile(
        groupId: 'grp_1',
        relativePath: 'reports/x.md',
        path: file.path,
        filename: 'x.md',
        contentType: 'text/markdown',
      );
      expect(result.isLocalSynced, isTrue);
    });

    test('bytes 与 path 都不给 / 都给 → ArgumentError（严格二选一）', () async {
      // 「都给」也拒绝：两条路一个流式读盘、一个把字节读进内存，静默选一个
      // 会让调用方以为自己得到的是另一种语义（大文件场景下差别很大）。
      await expectLater(
        () => api.uploadWorkspaceFile(
          groupId: 'grp_1',
          relativePath: 'a.md',
          filename: 'a.md',
        ),
        throwsArgumentError,
      );
      await expectLater(
        () => api.uploadWorkspaceFile(
          groupId: 'grp_1',
          relativePath: 'a.md',
          bytes: [1],
          path: '/tmp/nope.md',
          filename: 'a.md',
        ),
        throwsArgumentError,
      );
    });

    test('413（超服务端上限）映射成 HttpError，错误体摘要在 body 里', () async {
      // 回传编排靠 statusCode == 413 识别「改走 quick-capture 兑底」。
      // validateStatus 放行 4xx，这里若不判状态码，错误体会被当成成功响应
      // 解析成空对象，413 兑底分支永远不触发。
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/ufs-upload',
        (server) => server.reply(413, {'error': '文件超过 workspace 同步大小上限'}),
        data: Matchers.isA<FormData>(),
      );

      await expectLater(
        () => api.uploadWorkspaceFile(
          groupId: 'grp_1',
          relativePath: 'big.bin',
          bytes: List.filled(2 * 1024 * 1024, 0),
          filename: 'big.bin',
        ),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 413)
              .having((e) => e.body, 'body 摘要', contains('文件超过')),
        ),
      );
    });

    test('400（路径黑名单）与 404（/chat 前缀漏写即 404）各映射成 HttpError', () async {
      adapter.onPost(
        '/chat/groups/grp_1/workspace-sync/ufs-upload',
        (server) => server.reply(400, {'error': 'workspace 路径已在系统黑名单中'}),
        data: Matchers.isA<FormData>(),
      );
      await expectLater(
        () => api.uploadWorkspaceFile(
          groupId: 'grp_1',
          relativePath: '_attachments/x.md',
          bytes: [1],
          filename: 'x.md',
        ),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.body, 'body', contains('黑名单')),
        ),
      );

      adapter.onPost(
        '/chat/groups/grp_2/workspace-sync/ufs-upload',
        (server) => server.reply(404, {'error': '404 page not found'}),
        data: Matchers.isA<FormData>(),
      );
      await expectLater(
        () => api.uploadWorkspaceFile(
          groupId: 'grp_2',
          relativePath: 'a.md',
          bytes: [1],
          filename: 'a.md',
        ),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });
  group('routingPreview：只预览 agent（响应里没有 group_id）', () {
    /// `chat_stream.go` 的 `routingPreview` 真实输出形状。
    ///
    /// 关键点：**没有 group_id 字段**。级联已下线，故 route_source 恒为
    /// fallback、votes 恒为空、focus_topic 恒为 null。
    Map<String, dynamic> previewShape() => {
      'resolved_agent_id': 'agt_1',
      'route_source': 'fallback',
      'focus_topic': null,
      'votes': <dynamic>[],
      'candidates': [
        {
          'agent_id': 'agt_1',
          'name': '通用助手',
          'description': '默认',
          'group_name': '默认',
        },
        {
          'agent_id': 'agt_2',
          'name': '写手',
          'description': null,
          'group_name': null,
        },
      ],
      'trace': {'route': 'fallback', 'reason': 'default_agent_resolution'},
    };

    test('请求体只含 input（不传 group_id 时）', () async {
      adapter.onPost(
        '/users/usr_1/chat/routing-preview',
        (server) => server.reply(200, previewShape()),
        data: {'input': '测试'},
      );

      await api.routingPreview('usr_1', input: '测试');
    });

    test('解析出 agent / route_source / 候选 / trace', () async {
      adapter.onPost(
        '/users/usr_1/chat/routing-preview',
        (server) => server.reply(200, previewShape()),
        data: {'input': '测试'},
      );

      final p = RoutingPreview.fromJson(
        await api.routingPreview('usr_1', input: '测试'),
      );

      expect(p.resolvedAgentId, 'agt_1');
      expect(p.routeSource, 'fallback');
      expect(p.isFallback, isTrue);
      expect(p.candidates, hasLength(2));
      expect(p.candidates.first.name, '通用助手');
      // 服务端 nullStr → null，不是空串。
      expect(p.candidates[1].description, isNull);
      expect(p.candidates[1].groupName, isNull);
      expect(p.focusTopic, isNull);
      expect(p.trace['route'], 'fallback');
      // 候选里能找到 resolved 的名字。
      expect(p.resolvedAgentName, '通用助手');
    });

    test('响应里确实没有 group_id（UI 不得声称能预览归属）', () async {
      adapter.onPost(
        '/users/usr_1/chat/routing-preview',
        (server) => server.reply(200, previewShape()),
        data: {'input': '测试'},
      );

      final raw = await api.routingPreview('usr_1', input: '测试');
      expect(raw.containsKey('group_id'), isFalse);
      expect(raw['route_source'], 'fallback');
    });

    test('候选里找不到 id 时 resolvedAgentName 返回 null（不编造名字）', () {
      final p = RoutingPreview.fromJson({
        'resolved_agent_id': 'agt_missing',
        'route_source': 'fallback',
        'candidates': [
          {'agent_id': 'agt_1', 'name': '通用助手'},
        ],
      });
      expect(p.resolvedAgentName, isNull);
    });

    test('缺字段时容错（不抛，退回空值）', () {
      final p = RoutingPreview.fromJson(const {});
      expect(p.resolvedAgentId, '');
      expect(p.routeSource, isNull);
      expect(p.candidates, isEmpty);
      expect(p.isFallback, isFalse);
    });
  });
  group('群级开关：PUT 专用端点 + 只发显式传入的键', () {
    /// 捕获每次请求的 method / path / body。
    ///
    /// ## 这个测试防的是什么
    ///
    /// 三个开关在服务端注册的是 **PUT** 专用端点（`chat_ext.go:83-89`），走 CAS
    /// 读-改-写。若改用 `PATCH /chat/groups/:id` 的 metadata 通道，那是**整包
    /// 替换**语义——只提交 `{goal_gate}` 会连带清掉 `metadata.tts`（webapp 历史
    /// bug）。故这里显式断言 method 为 PUT，而不只是「路径对上了」。
    ///
    /// 第二个陷阱是**多发键**：`goal-gate` 端点里 `enabled` 与 `max_auto_turns`
    /// 语义不同（只传 max_auto_turns 时不得动 enabled，否则会触发「开启需有
    /// 目标」预检而 400）。DioAdapter 的 `data:` 匹配只能表达「相等/任意」，
    /// 表达不了「键必须缺席」，故用拦截器把 body 原样记下来断言。
    late List<({String method, String path, Map<String, dynamic>? body})> calls;

    setUp(() {
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

    test(
      'setGroupGoalGate：PUT /chat/groups/:gid/goal-gate，body 只有 enabled',
      () async {
        adapter.onPut(
          '/chat/groups/grp_1/goal-gate',
          (server) => server.reply(200, {'enabled': true}),
          data: Matchers.any,
        );

        await api.setGroupGoalGate('grp_1', enabled: true);

        expect(calls, hasLength(1));
        expect(calls.single.method, 'PUT');
        expect(calls.single.path, '/chat/groups/grp_1/goal-gate');
        expect(calls.single.body, {'enabled': true});
      },
    );

    test('setGroupGoalGate 只传 maxAutoTurns 时 body 不得出现 enabled', () async {
      // 服务端：body.Enabled == nil → toggleEnabled=false → 不跑「开启需有目标」
      // 预检。若客户端把 enabled 一并带上（哪怕值是原值），语义就变了。
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(200, {'enabled': true}),
        data: Matchers.any,
      );

      await api.setGroupGoalGate('grp_1', maxAutoTurns: 50);

      expect(calls.single.body, {'max_auto_turns': 50});
      expect(calls.single.body!.containsKey('enabled'), isFalse);
    });

    test('setGroupGoalGate 两者都传时都发出去', () async {
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(200, {'enabled': true}),
        data: Matchers.any,
      );

      await api.setGroupGoalGate('grp_1', enabled: false, maxAutoTurns: 1);

      expect(calls.single.body, {'enabled': false, 'max_auto_turns': 1});
    });

    test('setGroupGoalGate 开启但无目标 → 400 goal_required 抛 HttpError', () async {
      // ## 这是预期内的业务结果，不是故障
      //
      // 服务端 `chat_ext.go:198-201`：enable 时 `goalGateEffectiveGoal` 为空则
      // 400 `{error: "goal_required"}`。上层据此提示「请先设置目标」，而不是
      // 「保存失败」。若 `_put` 忘了走 `_unwrap`，这个 400 会被当成成功静默吞掉。
      adapter.onPut(
        '/chat/groups/grp_1/goal-gate',
        (server) => server.reply(400, {
          'error': 'goal_required',
          'message': '开启「自动实现目标」前请先设置目标',
        }),
        data: Matchers.any,
      );

      await expectLater(
        () => api.setGroupGoalGate('grp_1', enabled: true),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.body, 'body', contains('goal_required')),
        ),
      );
    });

    test(
      'setGroupFollowUpSuggest：PUT .../follow-up-suggest，body {enabled}',
      () async {
        adapter.onPut(
          '/chat/groups/grp_1/follow-up-suggest',
          (server) => server.reply(200, {'enabled': false}),
          data: Matchers.any,
        );

        await api.setGroupFollowUpSuggest('grp_1', false);

        expect(calls.single.method, 'PUT');
        expect(calls.single.path, '/chat/groups/grp_1/follow-up-suggest');
        expect(calls.single.body, {'enabled': false});
      },
    );

    test('setGroupTts：只传子开关时 body 不得出现 enabled', () async {
      // 服务端：`enabled == nil` 时不动总开关。若客户端默认补个 enabled:true，
      // 「只改思考播报」会意外把语音回复整个打开。
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(200, {
          'tts': {'enabled': true},
        }),
        data: Matchers.any,
      );

      await api.setGroupTts('grp_1', narrateThinking: true);

      expect(calls.single.method, 'PUT');
      expect(calls.single.path, '/chat/groups/grp_1/tts');
      expect(calls.single.body, {'narrate_thinking': true});
    });

    test('setGroupTts：全量字段映射到 snake_case', () async {
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(200, {'tts': <String, dynamic>{}}),
        data: Matchers.any,
      );

      await api.setGroupTts(
        'grp_1',
        enabled: true,
        narrateThinking: true,
        narrationMode: 'summary',
        fileSummary: false,
      );

      expect(calls.single.body, {
        'enabled': true,
        'narrate_thinking': true,
        'narration_mode': 'summary',
        'file_summary': false,
      });
    });

    test('setGroupTts 空参数调用仍发空 body（服务端会 400，由上层拦住）', () async {
      // 服务端要求四个键至少一个（`chat_ext.go:368-371`），否则 400。本方法不
      // 替调用方做这个校验（避免两处判断漂移），但必须保证不会悄悄补出某个键。
      adapter.onPut(
        '/chat/groups/grp_1/tts',
        (server) => server.reply(400, {'error': 'enabled required'}),
        data: Matchers.any,
      );

      await expectLater(
        () => api.setGroupTts('grp_1'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
      expect(calls.single.body, isEmpty);
    });
  });
  group('setGroupGoal：走结构化 goal 表（迁移 0022）', () {
    late List<({String method, String path, Map<String, dynamic>? body})> calls;

    setUp(() {
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

    /// `GET .../goals/current` 的响应形状（`goal_api.go:438-442`）。
    Map<String, dynamic> currentGoalShape({
      String id = 'goal_1',
      String goalText = '把同步做稳',
    }) => {
      'goal': {
        'id': id,
        'group_id': 'grp_1',
        'goal_text': goalText,
        'status': 'active',
        'tasks_source': 'manual',
        'created_at': '2024-03-05T08:09:10Z',
        'updated_at': '2024-03-05T08:09:10Z',
      },
      'tasks': <dynamic>[],
      'progress': null,
    };

    test(
      '无 current goal 时新建：GET current → POST goals（tasks_source=manual）',
      () async {
        adapter.onGet(
          '/chat/groups/grp_1/goals/current',
          (server) => server.reply(200, {
            'goal': null,
            'tasks': <dynamic>[],
            'progress': null,
          }),
        );
        adapter.onPost(
          '/chat/groups/grp_1/goals',
          (server) => server.reply(201, {
            'goal': {'id': 'goal_new'},
          }),
          data: Matchers.any,
        );

        await api.setGroupGoal('grp_1', '新目标');

        expect(calls.map((c) => '${c.method} ${c.path}'), [
          'GET /chat/groups/grp_1/goals/current',
          'POST /chat/groups/grp_1/goals',
        ]);
        expect(calls[1].body, {'goal_text': '新目标', 'tasks_source': 'manual'});
      },
    );

    test('文本与当前 goal 相同 → 不发写请求（否则双击保存留下一串同内容版本）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/goals/current',
        (server) => server.reply(200, currentGoalShape(goalText: '把同步做稳')),
      );

      await api.setGroupGoal('grp_1', '  把同步做稳  ');

      // 只发了一次 GET，没有 POST/PATCH。trim 后再比，避免「尾空格」被当成改目标。
      expect(calls, hasLength(1));
      expect(calls.single.method, 'GET');
    });

    test('清空目标 → PATCH /chat/goals/:id 置 archived（不建新行）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/goals/current',
        (server) => server.reply(200, currentGoalShape(id: 'goal_old')),
      );
      adapter.onPatch(
        '/chat/goals/goal_old',
        (server) => server.reply(200, {
          'goal': {'id': 'goal_old', 'status': 'archived'},
        }),
        data: Matchers.any,
      );

      await api.setGroupGoal('grp_1', '   ');

      expect(calls.map((c) => '${c.method} ${c.path}'), [
        'GET /chat/groups/grp_1/goals/current',
        'PATCH /chat/goals/goal_old',
      ]);
      expect(calls[1].body, {'status': 'archived'});
    });

    test('无 current goal 且文本为空 → 什么都不写（不留下空目标）', () async {
      adapter.onGet(
        '/chat/groups/grp_1/goals/current',
        (server) => server.reply(200, {
          'goal': null,
          'tasks': <dynamic>[],
          'progress': null,
        }),
      );

      await api.setGroupGoal('grp_1', '');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'GET');
    });

    test('走结构化表而不是 PUT /chat/groups/:gid/goal 旧列', () async {
      // 迁移 0022 后 `chat_groups.goal` 不再被写入（goal 变更 = 新建 chat_goals 行）。
      // 旧端点仅作存量兼容。若这里退化成旧端点，goal 变更就不会同步到任务/进度。
      adapter.onGet(
        '/chat/groups/grp_1/goals/current',
        (server) => server.reply(200, {
          'goal': null,
          'tasks': <dynamic>[],
          'progress': null,
        }),
      );
      adapter.onPost(
        '/chat/groups/grp_1/goals',
        (server) => server.reply(201, {
          'goal': {'id': 'goal_new'},
        }),
        data: Matchers.any,
      );

      await api.setGroupGoal('grp_1', '新目标');

      final paths = calls.map((c) => c.path).toList();
      expect(paths, isNot(contains('/chat/groups/grp_1/goal')));
      expect(paths, contains('/chat/groups/grp_1/goals'));
    });

    test('404（group 不存在）抛 HttpError', () async {
      adapter.onGet(
        '/chat/groups/nope/goals/current',
        (server) => server.reply(404, {'error': 'group not found'}),
      );

      await expectLater(
        () => api.setGroupGoal('nope', 'x'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });
  group('flushMessages：HTTP 200 不等于提交成功', () {
    test('成功分支解析出 turn_id / 策略 / 消费的消息', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/flush',
        (server) => server.reply(200, {
          'turn_id': 'turn_1',
          'consumed_message_ids': ['m1'],
          'flush_strategy': 'latest_only',
        }),
        data: {'group_id': 'grp_1'},
      );

      final r = await api.flushMessages('usr_1', groupId: 'grp_1');

      expect(r.turnId, 'turn_1');
      expect(r.flushStrategy, 'latest_only');
      expect(r.consumedMessageIds, ['m1']);
      expect(r.committed, isTrue);
      expect(r.needsConfirmation, isFalse);
    });

    test('多条 pending → HTTP 200 + confirmation_required（**未提交**）', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/flush',
        (server) => server.reply(200, {
          'status': 'confirmation_required',
          'reason': 'multiple_pending_messages',
          'message_ids': ['m1', 'm2'],
          'options': ['latest_only', 'merge_all', 'new_group'],
          'preview': {'latest_input': '第二句', 'merged_input': '第一句\n第二句'},
        }),
        data: {'group_id': 'grp_1'},
      );

      final r = await api.flushMessages('usr_1', groupId: 'grp_1');

      // 这正是「返回 void」会丢失的那个状态：HTTP 200，但什么都没提交。
      expect(r.needsConfirmation, isTrue);
      expect(r.committed, isFalse);
      expect(r.reason, 'multiple_pending_messages');
      expect(r.options, ['latest_only', 'merge_all', 'new_group']);
      expect(r.preview['latest_input'], '第二句');
      // 待确认分支没有 turn_id。
      expect(r.turnId, isNull);
    });

    test('flushMessagesDetailed 可传 message_ids 与 conflict_strategy', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/flush',
        (server) => server.reply(200, {
          'turn_id': 'turn_2',
          'consumed_message_ids': ['m1', 'm2'],
          'flush_strategy': 'merge_all',
        }),
        data: {
          'message_ids': ['m1', 'm2'],
          'conflict_strategy': 'merge_all',
        },
      );

      final r = await api.flushMessagesDetailed(
        'usr_1',
        messageIds: ['m1', 'm2'],
        conflictStrategy: 'merge_all',
      );

      expect(r.committed, isTrue);
      expect(r.flushStrategy, 'merge_all');
      expect(r.consumedMessageIds, ['m1', 'm2']);
    });

    test('400（没有可处理的 pending）抛 HttpError', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/flush',
        (server) => server.reply(400, {'error': '没有可处理的 pending 消息'}),
        data: {'group_id': 'grp_1'},
      );

      await expectLater(
        () => api.flushMessages('usr_1', groupId: 'grp_1'),
        throwsA(isA<HttpError>()),
      );
    });
  });

  /// `setGroupHabitSuggest` 的**真实路径与 body**（走本地 HTTP server）。
  ///
  /// ## 为什么不用 `DioAdapter` 而真起一个 server
  ///
  /// 本端点与 `/chat/groups/:id/habit-suggestions`（**复数、且是建议列表**）
  /// 只差一个 `s`，而后者确实存在（`misc_extra.go` 的
  /// `GET /api/chat/habit-suggestions`）。路径拼错**不会报错**：服务端会
  /// 404 或命中另一个端点，客户端只看到一句「请求失败」。
  ///
  /// mock 适配器按注册的路径匹配，写错路径的测试也能「通过」——因为断言的是
  /// 同一个错值。真起 server 才能确认：请求真的到了 `/chat/groups/:id/habit-suggest`。
  group('setGroupHabitSuggest 真实请求', () {
    late HttpServer server;
    late ChatApi realApi;
    late List<String> receivedPaths;
    late List<String> receivedMethods;
    late List<String> receivedBodies;

    setUp(() async {
      receivedPaths = [];
      receivedMethods = [];
      receivedBodies = [];
      // 端口 0 = 由内核分配空闲端口（避免 CI 上的固定端口冲突）。
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      realApi = ChatApi(createDio(baseUrl: 'http://127.0.0.1:${server.port}'));
      server.listen((req) async {
        receivedPaths.add(req.uri.path);
        receivedMethods.add(req.method);
        receivedBodies.add(await utf8.decodeStream(req));
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"enabled":true}');
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('PUT /chat/groups/:id/habit-suggest，body {"enabled":true}', () async {
      await realApi.setGroupHabitSuggest('grp_1', true);

      expect(receivedMethods, ['PUT']);
      expect(receivedPaths, ['/chat/groups/grp_1/habit-suggest']);
      expect(jsonDecode(receivedBodies.single), {'enabled': true});
    });

    test('enabled=false 原样下发（服务端据此删键）', () async {
      await realApi.setGroupHabitSuggest('grp_1', false);

      expect(jsonDecode(receivedBodies.single), {'enabled': false});
    });

    test('路径不含 habit-suggestions（与建议列表端点区分）', () async {
      await realApi.setGroupHabitSuggest('grp_1', true);

      // 防的是「顺手写成复数」：那个端点存在但语义完全不同（读建议列表）。
      expect(receivedPaths.single, isNot(contains('habit-suggestions')));
    });
  });
}
