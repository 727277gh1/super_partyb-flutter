import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `ChatApi.pendingMessages` 的契约测试。
///
/// ## 这个测试防的是什么
///
/// 端点名 `GET /users/:uid/chat/messages/pending` 会诱导人以为它返回 `ChatTurn`。
/// 实际返回的是 `chat_inbox_messages` 行（Go 侧 `inboxToDict`），字段名是
/// `input` 而非 `input_text`。用 `ChatTurn.fromJson` 解析**不会报错**——缺失的键
/// 走安全默认值，结果是 `inputText == ''`、`fanoutCount == 0` 的「全空对象」。
/// 这类 bug 在 UI 上表现为「恢复进行中对话时列表是空的」，极难定位。
///
/// 故这里不只断言「解析成功」，还**显式断言用 ChatTurn 解析会得到空 input**，
/// 把这个陷阱钉成可执行的回归。
void main() {
  /// `inboxToDict` 的真实输出形状（`internal/server/chat_inbox.go`）。
  Map<String, dynamic> inboxToDictShape({
    String id = 'inbox_01HZ',
    String status = 'pending',
    String? groupId = 'grp_1',
    String? turnId,
    String? processedAt,
  }) => {
    'id': id,
    'user_id': 'usr_01HZW',
    'group_id': groupId,
    'request_id': 'req_1',
    'agent_id': 'agt_1',
    'agent_type': 'pigo',
    'input': '帮我看一下这个报错',
    'status': status,
    'turn_id': turnId,
    'payload': {'source': 'bridge', 'channel': 'wechat_ilink'},
    'result': {'status': 'committed', 'strategy': 'latest'},
    'created_at': '2024-03-05T08:09:10Z',
    'updated_at': '2024-03-05T08:09:12Z',
    'processed_at': processedAt,
  };

  late Dio dio;
  late DioAdapter adapter;
  late ChatApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = ChatApi(dio);
  });

  group('pendingMessages 走 inbox 契约', () {
    test('解析出 input（不是 input_text）与 agent_type', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {
          'items': [inboxToDictShape()],
          'count': 1,
        }),
      );

      final pending = await api.pendingMessages('usr_1');

      expect(pending, hasLength(1));
      final m = pending.single;
      expect(m.input, '帮我看一下这个报错');
      expect(m.id, 'inbox_01HZ');
      expect(m.userId, 'usr_01HZW');
      expect(m.groupId, 'grp_1');
      expect(m.agentType, 'pigo');
      expect(m.status, 'pending');
      expect(m.requestId, 'req_1');
      expect(m.agentId, 'agt_1');
      expect(m.isPending, isTrue);
      expect(m.isProcessed, isFalse);
    });

    test('同一份 JSON 用 ChatTurn 解析会丢光 input —— 这就是本任务修的 bug', () {
      final json = inboxToDictShape();

      final asInbox = ChatInboxMessage.fromJson(json);
      final asTurn = ChatTurn.fromJson(json);

      expect(asInbox.input, isNotEmpty);
      // 反向对照：ChatTurn 读的是 `input_text`，而 inbox 给的是 `input`，
      // 于是静默得到空串（不抛异常）。
      expect(asTurn.inputText, isEmpty);
    });

    test('payload / result 被解析成 Map', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {
          'items': [inboxToDictShape()],
        }),
      );

      final m = (await api.pendingMessages('usr_1')).single;

      expect(m.payload?['channel'], 'wechat_ilink');
      expect(m.result?['strategy'], 'latest');
    });

    test('created_at / updated_at 被解析（非「现在」兜底）', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {
          'items': [inboxToDictShape()],
        }),
      );

      final m = (await api.pendingMessages('usr_1')).single;

      expect(m.createdAt.toUtc(), DateTime.utc(2024, 3, 5, 8, 9, 10));
      expect(m.updatedAt.toUtc(), DateTime.utc(2024, 3, 5, 8, 9, 12));
      expect(
        m.createdAt.difference(DateTime.now()).inDays.abs(),
        greaterThan(30),
      );
    });

    test('group_id / turn_id / processed_at 为空值时归一成 null', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {
          'items': [
            inboxToDictShape(groupId: null, turnId: null, processedAt: ''),
          ],
        }),
      );

      final m = (await api.pendingMessages('usr_1')).single;

      expect(m.groupId, isNull);
      expect(m.turnId, isNull);
      expect(m.processedAt, isNull);
    });

    test('空 items 返回空列表（不抛异常）', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {'items': <Object>[], 'count': 0}),
      );

      expect(await api.pendingMessages('usr_1'), isEmpty);
    });

    test('带 group_id 与 limit 时 query 正确拼接', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {'items': <Object>[]}),
        queryParameters: {'group_id': 'grp_1', 'limit': 5},
      );

      final result = await api.pendingMessages(
        'usr_1',
        groupId: 'grp_1',
        limit: 5,
      );

      expect(result, isEmpty);
      // 能走到这里说明 query 匹配成功（DioAdapter 默认 failOnMissingMock=true，
      // 未匹配会抛 AssertionError）。
    });
  });

  group('undoMessage 走 inbox 撤销契约', () {
    test('POST /users/:uid/chat/messages/:id/undo', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/inbox_01HZ/undo',
        (server) => server.reply(200, {
          'message_id': 'inbox_01HZ',
          'status': 'withdrawn',
        }),
        data: null,
      );

      await api.undoMessage('usr_1', 'inbox_01HZ');
      // 能走到这里说明路径与 mock 匹配（未匹配会抛 AssertionError）。
    });

    test('409 映射成 HttpError(isConflict)，供上层识别为「已处理」', () async {
      // ## 这个测试防的是什么
      //
      // 服务端 `WithdrawChatInboxMessage` 把 WHERE 限定在 status='pending'：
      // 影响行数为 0 且消息存在 → 409。这是**预期内的业务结果**（消息已被
      // dispatcher 合并成 turn），不是故障。上层据此提示「已处理，无法撤销」
      // 而不是「撤销失败」——后者会让用户以为它还会被执行，于是反复点。
      //
      // 若这里把 409 抛成别的类型（或吞掉），上层就只能靠魔法数字判断。
      adapter.onPost(
        '/users/usr_1/chat/messages/inbox_done/undo',
        (server) => server.reply(409, {'error': '消息当前状态为 committed，无法撤销'}),
        data: null,
      );

      await expectLater(
        () => api.undoMessage('usr_1', 'inbox_done'),
        throwsA(
          isA<HttpError>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.isConflict, 'isConflict', isTrue),
        ),
      );
    });

    test('404（消息不存在）映射成 HttpError(isNotFound)', () async {
      adapter.onPost(
        '/users/usr_1/chat/messages/nope/undo',
        (server) => server.reply(404, {'error': '消息不存在'}),
        data: null,
      );

      await expectLater(
        () => api.undoMessage('usr_1', 'nope'),
        throwsA(
          isA<HttpError>().having((e) => e.isNotFound, 'isNotFound', isTrue),
        ),
      );
    });
  });

  group('ChatInboxMessage 状态机', () {
    test('committed 带 turn_id，且不再是 pending', () {
      final m = ChatInboxMessage.fromJson(
        inboxToDictShape(
          status: 'committed',
          turnId: 'turn_9',
          processedAt: '2024-03-05T08:10:00Z',
        ),
      );

      expect(m.isCommitted, isTrue);
      expect(m.isPending, isFalse);
      expect(m.isProcessed, isTrue);
      expect(m.turnId, 'turn_9');
      expect(m.processedAt?.toUtc(), DateTime.utc(2024, 3, 5, 8, 10));
      expect(m.isWithdrawable, isFalse, reason: '已合并成 turn，不可撤回');
    });

    test('superseded 是「被后续消息合并取代」的终态', () {
      final m = ChatInboxMessage.fromJson(
        inboxToDictShape(status: 'superseded'),
      );

      expect(m.isSuperseded, isTrue);
      expect(m.isProcessed, isTrue);
    });

    test('withdrawn 是用户撤回的终态', () {
      final m = ChatInboxMessage.fromJson(
        inboxToDictShape(status: 'withdrawn'),
      );

      expect(m.isWithdrawn, isTrue);
      expect(m.isProcessed, isTrue);
    });

    test('只有 pending 可撤回（对齐服务端 WHERE status=\'pending\'）', () {
      final pending = ChatInboxMessage.fromJson(inboxToDictShape());
      expect(pending.isWithdrawable, isTrue);
    });

    test('未知 status 不抛异常（向前兼容）', () {
      final m = ChatInboxMessage.fromJson(
        inboxToDictShape(status: 'some_future_state'),
      );

      expect(m.status, 'some_future_state');
      expect(m.isPending, isFalse);
      expect(m.isProcessed, isTrue);
    });
  });

  group('ChatInboxMessage 容错', () {
    test('缺少可选字段时给安全默认值', () {
      final m = ChatInboxMessage.fromJson({'id': 'x', 'input': 'hi'});

      expect(m.id, 'x');
      expect(m.input, 'hi');
      expect(m.status, 'pending', reason: '缺省视为 pending（服务端默认值一致）');
      expect(m.userId, isEmpty);
      expect(m.agentType, isEmpty);
      expect(m.groupId, isNull);
    });

    test('payload 为非 Map 时归一成 null', () {
      final json = inboxToDictShape()..['payload'] = 'not-a-map';
      expect(ChatInboxMessage.fromJson(json).payload, isNull);
    });

    test('items 里非 Map 元素被跳过', () async {
      adapter.onGet(
        '/users/usr_1/chat/messages/pending',
        (server) => server.reply(200, {
          'items': [inboxToDictShape(), 'junk', 42],
        }),
      );

      expect(await api.pendingMessages('usr_1'), hasLength(1));
    });

    test('toString 不泄露正文（只给长度）', () {
      final m = ChatInboxMessage.fromJson(inboxToDictShape());
      final s = m.toString();

      expect(s, contains('ChatInboxMessage'));
      expect(s, isNot(contains('帮我看一下这个报错')));
    });
  });

  group('quickCapture：请求体只含 input', () {
    /// 记录实际发出的请求体，用于断言「恰好只有 input」。
    Map<String, dynamic>? capturedBody;

    setUp(() {
      capturedBody = null;
    });

    /// 挂载 quick-capture 的 mock，并捕获请求体。
    void mockQuickCapture(Map<String, dynamic> response) {
      adapter.onPost(
        '/me/quick-capture',
        (server) => server.reply(201, response),
        data: Matchers.any,
      );
    }

    test("请求体键集合恰为 {'input'}（不得出现 group_id/agent_id/user_id）", () async {
      // 用 Dio 拦截器捕获真实发出的 body：这是断言「请求体形状」的唯一可靠方式，
      // 比读源码 grep 强——它验证的是运行时行为。
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            capturedBody = options.data is Map
                ? Map<String, dynamic>.from(options.data as Map)
                : null;
            handler.next(options);
          },
        ),
      );
      mockQuickCapture({
        'turn_id': 'turn_q1',
        'group_id': 'grp_q1',
        'status': 'queued',
        'created_group': false,
      });

      await api.quickCapture(input: '帮我看看这个报错');

      expect(capturedBody, isNotNull);
      // 关键断言：键集合恰好是 {input}。
      expect(capturedBody!.keys.toSet(), {'input'});
      expect(capturedBody!['input'], '帮我看看这个报错');
      // 逐个排除越权字段（服务端刻意不接受，见 chat_quick_capture.go 安全性说明）。
      expect(capturedBody!.containsKey('group_id'), isFalse);
      expect(capturedBody!.containsKey('agent_id'), isFalse);
      expect(capturedBody!.containsKey('user_id'), isFalse);
    });

    test('queued 时解析出 groupId 且应导航', () async {
      mockQuickCapture({
        'turn_id': 'turn_q1',
        'group_id': 'grp_q1',
        'status': 'queued',
        'created_group': true,
        'matched_title': '报错排查',
        'route_source': 'fastpath',
      });

      final r = await api.quickCapture(input: '帮我看看');

      expect(r.groupId, 'grp_q1');
      expect(r.turnId, 'turn_q1');
      expect(r.status, 'queued');
      expect(r.isQueued, isTrue);
      expect(r.isFeedbackRecorded, isFalse);
      expect(r.shouldNavigate, isTrue);
      expect(r.createdGroup, isTrue);
      expect(r.matchedTitle, '报错排查');
      expect(r.routeSource, 'fastpath');
    });

    test('feedback_recorded 是终态：不导航、turnId 为空', () async {
      // 服务端此分支只回 status + group_id（HTTP 200，非 201）。
      adapter.onPost(
        '/me/quick-capture',
        (server) => server.reply(200, {
          'status': 'feedback_recorded',
          'group_id': 'grp_q1',
        }),
        data: Matchers.any,
      );

      final r = await api.quickCapture(input: '反馈#正确');

      expect(r.isFeedbackRecorded, isTrue);
      expect(r.isQueued, isFalse);
      expect(r.shouldNavigate, isFalse, reason: '终态不应导航，否则永远等不到回答');
      expect(r.turnId, isEmpty);
      expect(r.groupId, 'grp_q1');
    });

    test('未知 status 不被误当成终态（不应静默丢弃真正入队的消息）', () async {
      mockQuickCapture({
        'turn_id': 'turn_future',
        'group_id': 'grp_future',
        'status': 'some_future_state',
      });

      final r = await api.quickCapture(input: 'x');

      expect(r.isQueued, isFalse);
      expect(r.isFeedbackRecorded, isFalse);
      expect(r.shouldNavigate, isFalse, reason: '未知状态不导航，但也非终态');
      expect(r.status, 'some_future_state');
    });

    test('可选字段缺失时给安全默认值', () async {
      mockQuickCapture({'group_id': 'grp_min', 'status': 'queued'});

      final r = await api.quickCapture(input: 'x');

      expect(r.turnId, isEmpty);
      expect(r.createdGroup, isFalse);
      expect(r.matchedTitle, isNull);
      expect(r.routeSource, isNull);
    });

    test('404 时抛出 HttpError（端点不存在可被发现）', () async {
      adapter.onPost(
        '/me/quick-capture',
        (server) => server.reply(404, {'error': 'not found'}),
        data: Matchers.any,
      );

      await expectLater(
        api.quickCapture(input: 'x'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('toString 不含正文', () {
      final r = QuickCaptureResult.fromJson({
        'group_id': 'g',
        'status': 'queued',
      });
      expect(r.toString(), contains('QuickCaptureResult'));
    });
  });

  group('me()：取当前用户 id', () {
    /// `authHandlers.me` 的真实输出形状（`internal/server/dash.go`）。
    Map<String, dynamic> meShape({
      String role = 'admin',
      List<String>? roles,
    }) => {
      'id': 'usr_01HZW',
      'email': 'jim@example.com',
      'name': 'Jim',
      'role': role,
      'roles': roles ?? [role],
      'permissions': <String>[],
      'status': 'active',
    };

    test('取到 id（解决 /users/:user_id/* 无 userId 的缺口）', () async {
      adapter.onGet('/api/auth/me', (server) => server.reply(200, meShape()));

      final me = await api.me();

      expect(me.id, 'usr_01HZW');
      expect(me.hasId, isTrue);
      expect(me.email, 'jim@example.com');
      expect(me.name, 'Jim');
      expect(me.role, 'admin');
      expect(me.status, 'active');
      expect(me.isAdmin, isTrue);
    });

    test('roles 数组被解析（useIsAdmin 依赖 roles.includes(admin)）', () async {
      adapter.onGet(
        '/api/auth/me',
        (server) =>
            server.reply(200, meShape(role: 'member', roles: ['member'])),
      );

      final me = await api.me();

      expect(me.roles, ['member']);
      expect(me.isAdmin, isFalse);
    });

    test('roles 为 null 时归一成空列表（不抛异常）', () async {
      final json = meShape()..['roles'] = null;
      adapter.onGet('/api/auth/me', (server) => server.reply(200, json));

      final me = await api.me();

      expect(me.roles, isEmpty);
      expect(me.permissions, isEmpty);
    });

    test('路径前缀是 /api/auth/me（不在 /chat 或 /me 下）', () async {
      // 若路径写错，DioAdapter 默认 failOnMissingMock=true 会报 AssertionError，
      // 故这条用例本身就在验证前缀。
      adapter.onGet('/api/auth/me', (server) => server.reply(200, meShape()));

      await api.me();
    });

    test('401 时抛 AuthError（会话失效可被发现，而非 HttpError）', () async {
      // 401 归一化为 AuthError 而非 HttpError：上层据此**跳登录页**而不是
      // 重试请求。若沿用 HttpError，UI 只能靠 `statusCode == 401` 判断，
      // 容易漏掉一条分支。
      adapter.onGet(
        '/api/auth/me',
        (server) => server.reply(401, {'error': 'unauthorized'}),
      );

      await expectLater(
        api.me(),
        throwsA(
          isA<AuthError>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
        ),
      );
    });

    test('403 时抛 AuthError（已认证但无权限）', () async {
      adapter.onGet(
        '/api/auth/me',
        (server) => server.reply(403, {'error': 'forbidden'}),
      );

      await expectLater(
        api.me(),
        throwsA(
          isA<AuthError>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.isForbidden, 'isForbidden', isTrue),
        ),
      );
    });

    test('toString 只输出 id 与 roles（不泄露 email）', () {
      final me = CurrentUser.fromJson(meShape());
      final s = me.toString();

      expect(s, contains('usr_01HZW'));
      expect(s, isNot(contains('jim@example.com')));
    });
  });

  group('resolveConfirmation：路径含 group_id、请求体键是 action', () {
    Map<String, dynamic>? capturedBody;

    setUp(() {
      capturedBody = null;
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            capturedBody = options.data is Map
                ? Map<String, dynamic>.from(options.data as Map)
                : null;
            handler.next(options);
          },
        ),
      );
    });

    test('请求体键是 action（不是 decision，否则服务端静默丢弃用户选择）', () async {
      // 服务端 misc.go:resolve 绑定的是 `{Action, Comment}`。用 `decision` 会被
      // JSON 绑定忽略且**不报错**（action 取默认值 "resolved"），
      // 因为 resolved_action 无下游消费者，这个错误完全无声。
      adapter.onPost(
        '/api/chat/groups/grp_1/confirmations/cf_1/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation('grp_1', 'cf_1', action: 'approve');

      expect(capturedBody, isNotNull);
      expect(capturedBody!['action'], 'approve');
      expect(capturedBody!.containsKey('decision'), isFalse);
    });

    test('路径是 /api/chat/groups/:gid/confirmations/:id/resolve（issue #1）', () async {
      // 真实路由表（在 super_partyb/apps/go-api 内枚举 r.Routes()）：
      //   ROUTE GET    /chat/confirmations
      //   ROUTE GET    /api/chat/groups/:group_id/confirmations
      //   ROUTE POST   /api/chat/groups/:group_id/confirmations/:confirmation_id/resolve
      // 即「/chat/confirmations 下只有 GET 列表」，三个写端点全在 /api 下带 group_id。
      // 挂载点：ext_routes.go:39 的 registerConfirmRoutes(
      //   api.Group("/chat/groups/:group_id/confirmations"), db)，
      // 而 api 是 router.go 里 `apiv1 := r.Group("/api")`。
      //
      // 用完整 URL 断言而非只靠 DioAdapter：DioAdapter 默认
      // failOnMissingMock=true，路径写错本用例会直接失败。
      final requested = <String>[];
      dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested.add(options.uri.toString());
            handler.next(options);
          },
        ),
      );

      adapter.onPost(
        '/api/chat/groups/grp_2/confirmations/cf_2/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation(
        'grp_2',
        'cf_2',
        action: 'reject',
        comment: '不合适',
      );

      expect(
        requested.single,
        'https://api.test/pba/api/chat/groups/grp_2/confirmations/cf_2/resolve',
      );
      expect(capturedBody!['action'], 'reject');
      expect(capturedBody!['comment'], '不合适');
    });

    test('comment 为 null 时不发送该键', () async {
      adapter.onPost(
        '/api/chat/groups/grp_1/confirmations/cf_3/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation('grp_1', 'cf_3', action: 'continue');

      expect(capturedBody!.containsKey('comment'), isFalse);
    });
  });
  group('search 走 turn 摘要契约（不是 ChatEvent）', () {
    /// `search` 的真实输出形状（`internal/server/chat_stream.go` 的 `search`）。
    ///
    /// ## 这个测试防的是什么
    ///
    /// 端点名 `GET /users/:uid/chat/search` 挂在 `/chat/*` 下、又由
    /// `chat_stream.go` 实现，极易被当成「事件流的一部分」。但服务端返回的是
    /// **turn 摘要**——`{turn_id, group_id, group_title, input_text, created_at,
    /// agent_id}`，**没有** `event_id` / `event_type`。
    ///
    /// 而 `ChatEvent.fromJson` 对缺失的必需字段做显式校验并抛 `FormatException`
    /// （见 `chat_event.dart` 的 `_str2` + 显式 throw）。故一旦误用 ChatEvent，
    /// **每一次搜索都会失败**，且错误信息只提「缺少 eventId/eventType」，
    /// 不会指出是端点契约搞错了。
    ///
    /// 故这里不只断言「解析成功」，还**显式断言 ChatEvent.fromJson 会抛**，
    /// 把这个陷阱钉成可执行的回归。
    Map<String, dynamic> searchHitShape({
      String turnId = 'turn_01HZ',
      String groupId = 'grp_1',
      String groupTitle = '报错排查',
      String inputText = '帮我看一下这个报错',
      String createdAt = '2024-03-05T08:09:10Z',
      Object? agentId = 'agt_1',
    }) => {
      'turn_id': turnId,
      'group_id': groupId,
      'group_title': groupTitle,
      'input_text': inputText,
      'created_at': createdAt,
      'agent_id': agentId,
    };

    test('用真实形状解析不抛异常且字段正确', () async {
      adapter.onGet(
        '/users/usr_1/chat/search',
        (server) => server.reply(200, {
          'items': [searchHitShape()],
          'count': 1,
        }),
        queryParameters: {'q': '报错'},
      );

      final hits = await api.search('usr_1', query: '报错');

      expect(hits, hasLength(1));
      final hit = hits.single;
      expect(hit.turnId, 'turn_01HZ');
      expect(hit.groupId, 'grp_1');
      expect(hit.groupTitle, '报错排查');
      expect(hit.inputText, '帮我看一下这个报错');
      expect(hit.createdAt?.toUtc().hour, 8);
      expect(hit.agentId, 'agt_1');
    });

    test('该形状喂给 ChatEvent.fromJson 会抛 FormatException（钉住契约差异）', () {
      expect(
        () => ChatEvent.fromJson(searchHitShape()),
        throwsA(isA<FormatException>()),
        reason: '搜索返回 turn 摘要而非事件；误用 ChatEvent 会让每次搜索都失败',
      );
    });

    test('group_title 缺失（归档 group 取不到标题）→ 空串且兜底展示', () async {
      // 服务端用 ListChatGroupsByUser(status: "active") 建标题表，
      // 归档或超出 500 条的 group 取不到标题，map 查不到 → 写入 Go 零值 ""。
      adapter.onGet(
        '/users/usr_1/chat/search',
        (server) => server.reply(200, {
          'items': [searchHitShape(groupTitle: '')],
        }),
        queryParameters: {'q': 'x'},
      );

      final hit = (await api.search('usr_1', query: 'x')).single;

      expect(hit.groupTitle, '');
      expect(hit.displayTitle, '（未命名对话）');
    });

    test('agent_id 为 null（turn 无 targets）不抛异常', () async {
      adapter.onGet(
        '/users/usr_1/chat/search',
        (server) => server.reply(200, {
          'items': [searchHitShape(agentId: null)],
        }),
        queryParameters: {'q': 'x'},
      );

      final hit = (await api.search('usr_1', query: 'x')).single;

      expect(hit.agentId, isNull);
    });

    test('空结果返回空列表（服务端 q 为空时也走这条）', () async {
      adapter.onGet(
        '/users/usr_1/chat/search',
        (server) =>
            server.reply(200, {'items': <Map<String, dynamic>>[], 'count': 0}),
        queryParameters: {'q': 'nohit'},
      );

      expect(await api.search('usr_1', query: 'nohit'), isEmpty);
    });

    test('limit 透传（服务端默认 20 / 上限 50）', () async {
      adapter.onGet(
        '/users/usr_1/chat/search',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'q': 'x', 'limit': 5},
      );

      // 不传 limit 时该键不应出现（否则与上面的 mock 不匹配而报错）。
      await api.search('usr_1', query: 'x', limit: 5);
    });
  });

  // =========================================================================
  group('searchMyTurns（GET /me/turns/search）', () {
    /// `turnToListItem` 的真实输出形状（`internal/server/user_turns.go:291`）。
    ///
    /// ## 这个测试防的是什么
    ///
    /// `/me/turns/search` 与 `/users/:uid/chat/search` 名字极像，但响应形状
    /// **不同**：前者是 `turnToListItem`（`input_preview` / `derived_source`），
    /// 后者是 `ChatSearchHit` 的形状（`input_text` / `agent_id`）。
    ///
    /// 用 `ChatSearchHit.fromJson` 解析前者**不报错**——`input_text` 缺失
    /// 退化成空串，`displayTitle` 退化成「（未命名对话）」。列表里全是空行，
    /// 而不会有一句错误提示。故这里显式钉住两种形状的差异。
    Map<String, dynamic> turnListItemShape({
      String turnId = 'turn_01HZ',
      String groupId = 'grp_1',
      Object? groupTitle = '报错排查',
      String inputPreview = '帮我看一下这个报错',
      String status = 'completed',
      String derivedSource = 'chat',
      String source = 'desktop',
      String createdAt = '2024-03-05T08:09:10Z',
      Object? startedAt,
      Object? endedAt,
      bool hasError = false,
      int messageCount = 2,
    }) => {
      'turn_id': turnId,
      'group_id': groupId,
      'group_title': groupTitle,
      'input_preview': inputPreview,
      'status': status,
      'derived_source': derivedSource,
      'source': source,
      'created_at': createdAt,
      'started_at': startedAt,
      'ended_at': endedAt,
      'has_error': hasError,
      'message_count': messageCount,
    };

    test('路径是 /me/turns/search，query 带 q 与 limit', () async {
      adapter.onGet(
        '/me/turns/search',
        (server) => server.reply(200, {
          'items': [turnListItemShape()],
        }),
        queryParameters: {'q': '报错', 'limit': 20},
      );

      final items = await api.searchMyTurns(query: '报错');

      expect(items, hasLength(1));
      final t = items.single;
      expect(t.turnId, 'turn_01HZ');
      expect(t.groupId, 'grp_1');
      expect(t.groupTitle, '报错排查');
      expect(t.inputPreview, '帮我看一下这个报错');
      expect(t.status, 'completed');
      expect(t.source, TurnSource.chat);
      expect(t.createdAt.toUtc().hour, 8);
    });

    test('limit 显式透传（服务端默认 20 / 上限 50）', () async {
      adapter.onGet(
        '/me/turns/search',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'q': 'x', 'limit': 5},
      );

      expect(await api.searchMyTurns(query: 'x', limit: 5), isEmpty);
    });

    test('q 为空时**不发请求**，直接返回空列表', () async {
      // 不注册任何 mock：一旦真的发出请求，DioAdapter 会因找不到匹配路由而抛错。
      // 这正是本用例想证明的——服务端对空 q 返回 400，客户端必须拦在本地。
      expect(await api.searchMyTurns(query: ''), isEmpty);
    });

    test('q 只有空白时也不发请求（服务端先 TrimSpace 再判空）', () async {
      expect(await api.searchMyTurns(query: '   '), isEmpty);
    });

    test('q 两端空白被 trim 后才发（服务端也 trim，避免空往返）', () async {
      adapter.onGet(
        '/me/turns/search',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        // 若发的是未 trim 的 ' 报错 '，下面的 mock 不匹配 → 抛错。
        queryParameters: {'q': '报错', 'limit': 20},
      );

      await api.searchMyTurns(query: ' 报错 ');
    });

    test('group_title 为 null（归档 group）不抛异常', () async {
      adapter.onGet(
        '/me/turns/search',
        (server) => server.reply(200, {
          'items': [turnListItemShape(groupTitle: null)],
        }),
        queryParameters: {'q': 'x', 'limit': 20},
      );

      final t = (await api.searchMyTurns(query: 'x')).single;

      expect(t.groupTitle, isNull);
    });

    test('用 ChatSearchHit 解析同一份 JSON 会丢光 inputPreview（钉住契约差异）', () {
      // 两个端点名字像、实现文件不同、形状不同。误用不会报错，只会得到空列表行。
      final json = turnListItemShape();

      final asSummary = ChatTurnSummary.fromJson(json);
      final asHit = ChatSearchHit.fromJson(json);

      expect(asSummary.inputPreview, '帮我看一下这个报错');
      expect(
        asHit.inputText,
        isEmpty,
        reason: 'ChatSearchHit 读 input_text，而本端点发的是 input_preview',
      );
      expect(asHit.turnId, 'turn_01HZ', reason: 'turn_id 两者同名，故错误更隐蔽');
    });

    test('空结果返回空列表', () async {
      adapter.onGet(
        '/me/turns/search',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'q': 'nohit', 'limit': 20},
      );

      expect(await api.searchMyTurns(query: 'nohit'), isEmpty);
    });
  });

  // =========================================================================
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

  // =========================================================================
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

  // =========================================================================
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

  // =========================================================================
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

  // =========================================================================
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

  // ==================== #13 自动续跑排程 ====================

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
