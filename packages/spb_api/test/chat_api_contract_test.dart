/// 零生产调用者端点的**契约测试**（issue #49）。
///
/// ## 这个测试防的是什么
///
/// AGENTS.md §6.14 记录了一个真实缺陷：`ChatApi.createTurn` 曾把 `inputText`
/// 写成 `input`、`requestId` 写成 `request_id`，且把 `{status, groupId, turnId}`
/// 平铺响应解析成 `ChatTurn`——**字段名与形状双双不符**。它之所以长期潜伏，
/// 正是因为**该方法当时零生产调用者**：没人用 → 没人发现。
///
/// 同类的还有几个方法。本文件给它们补上「与 Go 路由表 / struct tag 逐字段对齐」
/// 的契约测试。⚠️ 这些断言**不看客户端自己的实现**，而是照抄服务端真源
/// （`super_partyb/apps/go-api` 的路由注册与 `turnToDict` / `confirmToDict`），
/// 故它们能抓住「客户端拼错路径 / 拼错字段名」这一类静默缺陷。
///
/// ## 为什么用真实 `HttpServer` 而不是 `DioAdapter`
///
/// 路径缺陷（如缺 `/api` 前缀）在 `DioAdapter` 下**测不出来**——它按注册的
/// 路由匹配，而测试注册什么就匹配什么。真实 server 的 `req.uri.path` 才能
/// 被断言「客户端到底请求了哪个路径」。这与 §6.27 的端到端测试同一取向。
library;

import 'dart:convert';
import 'dart:io';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 记录请求路径与请求体的最小真实服务器。
class Recorder {
  Recorder(this.server, this.paths, this.bodies);
  final HttpServer server;
  final List<String> paths;
  final List<Map<String, dynamic>> bodies;
  String get baseUrl => 'http://127.0.0.1:${server.port}';
  Future<void> close() => server.close(force: true);
}

/// 起一个 server，对每个请求返回 [respond] 给的 JSON。
Future<Recorder> startRecorder(
  Object Function(String path) respond, {
  int statusCode = 200,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final paths = <String>[];
  final bodies = <Map<String, dynamic>>[];
  server.listen((req) async {
    paths.add(req.uri.path);
    final raw = await utf8.decoder.bind(req).join();
    bodies.add(
      raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>,
    );
    req.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(respond(req.uri.path)));
    await req.response.close();
  });
  return Recorder(server, paths, bodies);
}

ChatApi apiFor(Recorder r) => ChatApi(createDio(baseUrl: r.baseUrl));

void main() {
  group('契约：listTurns（GET /chat/groups/:group_id/turns）', () {
    // 真源：`chat.go:39` 的 `rg.GET("/groups/:group_id/turns", h.listTurns)`，
    // 挂在 `chatRG := r.Group("/chat")`（`router.go:116`）下。
    // 响应：`turnToDict`（`chat.go:717`）——**snake_case**，包在 `{items: [...]}`。
    Map<String, dynamic> turnDict({
      String id = 'turn_1',
      String? requestId,
      String? channel,
    }) => {
      'id': id,
      'group_id': 'grp_1',
      'user_id': 'usr_1',
      'request_id': requestId,
      'input_text': '帮我看一下',
      'status': 'completed',
      'fanout_count': 1,
      'completed_count': 1,
      'error_count': 0,
      'metadata': <String, dynamic>{},
      'channel': channel,
      'created_at': '2024-03-05T08:09:10Z',
      'started_at': null,
      'ended_at': null,
    };

    test('路径是 /chat/groups/:id/turns，且带 limit/offset', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [turnDict()],
        },
      );
      addTearDown(rec.close);

      await apiFor(rec).listTurns('grp_1', limit: 20, offset: 5);

      expect(rec.paths, ['/chat/groups/grp_1/turns']);
    });

    test('解析 turnToDict 的 snake_case 字段（不是 camelCase）', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [
            turnDict(id: 'turn_7', requestId: 'req_7', channel: 'desktop'),
          ],
        },
      );
      addTearDown(rec.close);

      final turns = await apiFor(rec).listTurns('grp_1');

      expect(turns, hasLength(1));
      final t = turns.single;
      expect(t.id, 'turn_7');
      expect(t.groupId, 'grp_1', reason: 'Go 发 group_id，不是 groupId');
      expect(t.userId, 'usr_1', reason: 'Go 发 user_id');
      expect(t.inputText, '帮我看一下', reason: 'Go 发 input_text');
      expect(t.requestId, 'req_7', reason: 'Go 发 request_id');
      expect(t.channel, 'desktop');
      expect(t.status, 'completed');
      // ⚠️ `ChatTurn.fromJson` 把 `created_at` 做了 `.toLocal()`（与
      // spb_models 其余模型一致），故断言用 UTC 等值而非字符串。
      expect(t.createdAt.toUtc(), DateTime.utc(2024, 3, 5, 8, 9, 10));
    });

    test('空列表（items: []）不抛异常', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);

      expect(await apiFor(rec).listTurns('grp_1'), isEmpty);
    });

    test('非 2xx → HttpError（{error: ...} 裸 JSON）', () async {
      final rec = await startRecorder(
        (_) => {'error': 'group not found'},
        statusCode: 404,
      );
      addTearDown(rec.close);

      await expectLater(
        apiFor(rec).listTurns('nope'),
        throwsA(isA<HttpError>()),
      );
    });
  });

  group('契约：listConfirmations（GET /chat/confirmations，跨 group）', () {
    // 真源：`router.go:138` 的 `confirmRG := chatRG.Group("/confirmations")`
    // + `global_confirmations.go:21` 的 `rg.GET("", h.list)`。
    // 注意是 **`/chat/confirmations`**（无 `/api`）——与下面 group 版不同。
    test('路径是 /chat/confirmations（无 /api 前缀），带 status/limit', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);

      await apiFor(rec).listConfirmations(status: 'pending', limit: 30);

      expect(rec.paths, ['/chat/confirmations']);
    });

    test('解析 {items: [...]} 且返回裸 map（字段由调用方解释）', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [
            {'id': 'cf_1', 'status': 'pending', 'group_id': 'grp_1'},
          ],
        },
      );
      addTearDown(rec.close);

      final raw = await apiFor(rec).listConfirmations();

      expect(raw, hasLength(1));
      expect(raw.single['id'], 'cf_1');
    });

    test('listConfirmationsTyped 走 ChatConfirmation.fromJson', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [
            {
              'id': 'cf_1',
              'group_id': 'grp_1',
              'user_id': 'usr_1',
              'status': 'pending',
              'created_at': '2024-03-05T08:09:10Z',
            },
          ],
        },
      );
      addTearDown(rec.close);

      final typed = await apiFor(rec).listConfirmationsTyped();

      expect(typed.single.id, 'cf_1');
      expect(typed.single.status, 'pending');
    });
  });

  group('契约：groupConfirmations（按 group 过滤的确认卡）', () {
    // ⚠️ **这是 issue #49 查出的真实缺陷**：客户端曾拼
    // `/chat/groups/:id/confirmations`（缺 `/api`），而服务端注册的是
    // `/api/chat/groups/:group_id/confirmations`
    // （`ext_routes.go:40`，挂在 `apiv1 := r.Group("/api")` 下，`router.go:168`）。
    // 故原路径必然 404。
    test('路径必须带 /api 前缀（否则服务端 404）', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);

      await apiFor(rec).groupConfirmations('grp_1');

      expect(
        rec.paths,
        ['/api/chat/groups/grp_1/confirmations'],
        reason:
            '缺 /api 时服务端路由表里没有这个路径——'
            'DioAdapter 按注册路由匹配，测不出这类缺陷',
      );
    });

    test('解析 {items: [...]}', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [
            {'id': 'cf_9', 'status': 'pending'},
          ],
        },
      );
      addTearDown(rec.close);

      final raw = await apiFor(rec).groupConfirmations('grp_1');

      expect(raw.single['id'], 'cf_9');
    });

    test('与 resolveConfirmation 同一路径族（都带 /api）', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);
      final api = apiFor(rec);

      await api.groupConfirmations('grp_1');
      await api.resolveConfirmation('grp_1', 'cf_1', action: 'approve');

      expect(rec.paths, [
        '/api/chat/groups/grp_1/confirmations',
        '/api/chat/groups/grp_1/confirmations/cf_1/resolve',
      ]);
    });
  });

  group('契约：createTurn 的补强断言（issue #49）', () {
    // §6.14 已有 3 条（inputText / requestId / 响应形状）。这里补两条
    // 「反向可验证」的：
    //   - 服务端 InputText 是 `binding:"required"`，缺了会 400；
    //   - 响应 201（不是 200），且 status 固定 queued。
    test('服务端 400 时抛 HttpError（inputText 缺失即此路）', () async {
      final rec = await startRecorder(
        (_) => {'error': 'Key: InputText Error: required'},
        statusCode: 400,
      );
      addTearDown(rec.close);

      await expectLater(
        apiFor(rec).createTurn('grp_1', input: ''),
        throwsA(isA<HttpError>()),
      );
    });

    test('响应缺 turnId 时安全降级（不抛，值为空串）', () async {
      final rec = await startRecorder((_) => {'status': 'queued'});
      addTearDown(rec.close);

      final r = await apiFor(rec).createTurn('grp_1', input: 'x');

      expect(r.turnId, '');
      expect(r.status, 'queued');
    });
  });

  group('契约：group CRUD（GET/POST/PATCH/DELETE /chat/groups...）', () {
    // 真源：`chat.go:28-34` 的 7 条 group 路由，挂在 `r.Group("/chat")` 下。
    // 响应：`groupToDict`（`chat.go:638`）——**snake_case**。
    Map<String, dynamic> groupDict({
      String id = 'grp_1',
      String status = 'active',
      String? goal,
    }) => {
      'id': id,
      'user_id': 'usr_1',
      'title': '每周报告',
      'status': status,
      'goal': goal,
      'metadata': <String, dynamic>{'color': 'blue'},
      'created_at': '2024-03-05T08:09:10Z',
      'updated_at': '2024-03-05T09:00:00Z',
    };

    test('listGroups 路径 + status/limit/offset 查询参数', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [groupDict()],
        },
      );
      addTearDown(rec.close);

      final groups = await apiFor(rec)
          .listGroups(status: 'active', limit: 10, offset: 20);

      expect(rec.paths, ['/chat/groups']);
      expect(groups.single.id, 'grp_1');
      expect(groups.single.title, '每周报告');
      expect(groups.single.status, 'active');
      expect(groups.single.metadata!['color'], 'blue');
    });

    test('getGroup 路径 + 解析 groupToDict', () async {
      final rec = await startRecorder((_) => groupDict(goal: '写完'));
      addTearDown(rec.close);

      final g = await apiFor(rec).getGroup('grp_1');

      expect(rec.paths, ['/chat/groups/grp_1']);
      expect(g.goal, '写完', reason: 'Go 发 goal（可为 null）');
      expect(g.userId, 'usr_1');
    });

    test('createGroup 路径 + body 键（title / agent_id / metadata）', () async {
      final rec = await startRecorder((_) => groupDict());
      addTearDown(rec.close);

      await apiFor(rec)
          .createGroup(title: '新对话', agentId: 'agt_1', metadata: {'k': 'v'});

      expect(rec.paths, ['/chat/groups']);
      expect(rec.bodies.single['title'], '新对话');
      expect(rec.bodies.single['agent_id'], 'agt_1');
      expect(rec.bodies.single['metadata'], {'k': 'v'});
    });

    test('createGroup 不带可选参数时不出 agent_id / metadata 键', () async {
      final rec = await startRecorder((_) => groupDict());
      addTearDown(rec.close);

      await apiFor(rec).createGroup(title: 'x');

      expect(rec.bodies.single.containsKey('agent_id'), isFalse);
      expect(rec.bodies.single.containsKey('metadata'), isFalse);
    });

    test('patchGroup 只发显式传入的字段（PATCH 语义）', () async {
      final rec = await startRecorder((_) => groupDict());
      addTearDown(rec.close);

      await apiFor(rec).patchGroup('grp_1', title: '改名了');

      expect(rec.paths, ['/chat/groups/grp_1']);
      expect(
        rec.bodies.single,
        {'title': '改名了'},
        reason:
            '未传的 status/goal/metadata 不得出现——'
            '服务端用指针字段三态区分「未提交」与「清空」，'
            '多发键会把它们强制覆盖',
      );
    });

    test('patchGroup 传空串 = 清空（必须真的发出该键）', () async {
      final rec = await startRecorder((_) => groupDict());
      addTearDown(rec.close);

      await apiFor(rec).patchGroup('grp_1', goal: '');

      expect(rec.bodies.single.containsKey('goal'), isTrue);
      expect(rec.bodies.single['goal'], '');
    });

    test('deleteGroup / archiveGroup / unarchiveGroup 路径', () async {
      final rec = await startRecorder((_) => groupDict());
      addTearDown(rec.close);
      final api = apiFor(rec);

      await api.deleteGroup('grp_1');
      await api.archiveGroup('grp_1');
      await api.unarchiveGroup('grp_1');

      expect(rec.paths, [
        '/chat/groups/grp_1',
        '/chat/groups/grp_1/archive',
        '/chat/groups/grp_1/unarchive',
      ]);
    });

    test('listGroups 空列表不抛异常', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);

      expect(await apiFor(rec).listGroups(), isEmpty);
    });
  });

  group('契约：groupTimeline（GET /chat/groups/:id/timeline）', () {
    // 真源：`chat.go:383` 的 `groupTimeline`。
    // 响应：`{items, next_cursor, next_before_global_seq, next_before_time,
    //        next_before_seq}`（`chat.go:464`）。
    // 事件字典：`eventToDict`（`chat.go:767`）——**snake_case**。
    Map<String, dynamic> eventDict({
      String eventId = 'ev_1',
      String eventType = 'message',
      int globalSeq = 7,
      bool transient = false,
    }) => {
      'event_id': eventId,
      'turn_id': 'turn_1',
      'group_id': 'grp_1',
      'user_id': 'usr_1',
      'agent_id': 'agt_1',
      'session_id': null,
      'event_type': eventType,
      'seq': 3,
      'global_seq': globalSeq,
      'source': 'agent',
      'payload': {'text': '你好'},
      'transient': transient,
      'created_at': '2024-03-05T08:09:10Z',
    };

    test('路径 + limit 查询参数；无 beforeGlobalSeq 时不发该键', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [eventDict()],
          'next_cursor': 'ev_1',
          'next_before_global_seq': '7',
        },
      );
      addTearDown(rec.close);

      final page = await apiFor(rec).groupTimeline('grp_1', limit: 100);

      expect(rec.paths, ['/chat/groups/grp_1/timeline']);
      expect(page.items.single.eventType, 'message');
    });

    test('解析 eventToDict 的 snake_case 字段', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [eventDict(eventId: 'ev_9', globalSeq: 42)],
        },
      );
      addTearDown(rec.close);

      final page = await apiFor(rec).groupTimeline('grp_1');
      final ev = page.items.single;

      expect(ev.eventId, 'ev_9');
      expect(ev.turnId, 'turn_1', reason: 'Go 发 turn_id');
      expect(ev.groupId, 'grp_1');
      expect(ev.globalSeq, 42, reason: 'Go 发 global_seq（排序/分页真源）');
      expect(ev.seq, 3, reason: 'seq 是 turn 内序号，不能当分页游标');
      expect(ev.eventType, 'message');
    });

    test('游标优先取 next_before_global_seq（不是 next_cursor）', () async {
      final rec = await startRecorder(
        (_) => {
          'items': [eventDict()],
          // 两个都给，且值不同——客户端必须选 global_seq 那个。
          'next_cursor': 'ev_1',
          'next_before_global_seq': '99',
        },
      );
      addTearDown(rec.close);

      final page = await apiFor(rec).groupTimeline('grp_1');

      expect(
        page.nextCursor,
        '99',
        reason:
            'next_cursor 是 event id（降级路径）；'
            'next_before_global_seq 才是正确的分页游标',
      );
      expect(page.hasMore, isTrue);
    });

    test('空页（items: []）→ 无游标、hasMore 为 false', () async {
      final rec = await startRecorder((_) => {'items': <dynamic>[]});
      addTearDown(rec.close);

      final page = await apiFor(rec).groupTimeline('grp_1');

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('非 2xx → HttpError', () async {
      final rec = await startRecorder(
        (_) => {'error': 'group not found'},
        statusCode: 404,
      );
      addTearDown(rec.close);

      await expectLater(
        apiFor(rec).groupTimeline('nope'),
        throwsA(isA<HttpError>()),
      );
    });
  });

  group('契约：单 turn（GET /chat/turns/:id、cancel）', () {
    test('getTurn 路径 + 解析 turnToDict', () async {
      final rec = await startRecorder(
        (_) => {
          'id': 'turn_5',
          'group_id': 'grp_1',
          'user_id': 'usr_1',
          'input_text': '继续',
          'status': 'running',
          'fanout_count': 1,
          'completed_count': 0,
          'error_count': 0,
          'created_at': '2024-03-05T08:09:10Z',
        },
      );
      addTearDown(rec.close);

      final t = await apiFor(rec).getTurn('turn_5');

      expect(rec.paths, ['/chat/turns/turn_5']);
      expect(t.id, 'turn_5');
      expect(t.inputText, '继续');
      expect(t.status, 'running');
    });

    test('cancelTurn 是 POST /chat/turns/:id/cancel（不是 DELETE）', () async {
      final rec = await startRecorder((_) => <String, dynamic>{});
      addTearDown(rec.close);

      await apiFor(rec).cancelTurn('turn_5');

      expect(rec.paths, ['/chat/turns/turn_5/cancel']);
    });
  });

  group('契约：sendMessage（POST /users/:user_id/chat/messages）', () {
    // 真源：`chat_stream.go:149` 的 `sendMessage`。
    // 响应：**平铺**的 `{turn_id, group_id, status, deduped, ...}`
    // （`chat_stream.go:215`），**不是** `{turn: {...}}`。
    test(
      '路径 + body 键（input / group_id / agent_id / routing / request_id）',
      () async {
        final rec = await startRecorder(
          (_) => {
            'turn_id': 'turn_9',
            'group_id': 'grp_9',
            'status': 'queued',
            'deduped': false,
          },
        );
        addTearDown(rec.close);

        final r = await apiFor(rec).sendMessage(
          'usr_1',
          input: '你好',
          groupId: 'grp_1',
          agentId: 'agt_1',
          requestId: 'req_1',
        );

        expect(rec.paths, ['/users/usr_1/chat/messages']);
        final b = rec.bodies.single;
        expect(b['input'], '你好');
        expect(b['group_id'], 'grp_1');
        expect(b['agent_id'], 'agt_1');
        expect(b['request_id'], 'req_1', reason: 'Go 发 request_id（snake）');
        expect(b['routing'], {'mode': 'auto'});
        expect(r.turnId, 'turn_9');
        expect(r.groupId, 'grp_9', reason: '归属可能被服务端改判，必须用响应里的');
        expect(r.status, 'queued');
      },
    );

    test('无归属入口：省略 groupId 时不出该键（服务端跑分类链）', () async {
      final rec = await startRecorder(
        (_) => {
          'turn_id': 'turn_9',
          'group_id': 'grp_decided',
          'status': 'queued',
        },
      );
      addTearDown(rec.close);

      final r = await apiFor(rec).sendMessage('usr_1', input: '记一笔');

      expect(
        rec.bodies.single.containsKey('group_id'),
        isFalse,
        reason: '带上「上次落点」会绕过服务端分类链（AGENTS.md §5.5）',
      );
      expect(r.groupId, 'grp_decided');
    });

    test('归属反馈回执（feedback_recorded）→ turnId 为空但 groupId 有值', () async {
      final rec = await startRecorder(
        (_) => {
          'turn_id': '',
          'group_id': 'grp_1',
          'status': 'feedback_recorded',
          'feedback_recorded': true,
        },
      );
      addTearDown(rec.close);

      final r = await apiFor(rec).sendMessage('usr_1', input: '不对，应该是另一个对话');

      expect(r.turnId, '');
      expect(r.groupId, 'grp_1');
      expect(r.status, 'feedback_recorded');
    });

    test('deduped 命中已有 turn（幂等去重）', () async {
      final rec = await startRecorder(
        (_) => {
          'turn_id': 'turn_9',
          'group_id': 'grp_1',
          'status': 'queued',
          'deduped': true,
        },
      );
      addTearDown(rec.close);

      final r = await apiFor(rec)
          .sendMessage('usr_1', input: 'x', requestId: 'r');

      expect(r.deduped, isTrue);
    });
  });
}
