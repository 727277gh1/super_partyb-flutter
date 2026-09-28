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

    test('401 时抛 AuthError（会话失效可被发现）', () async {
      adapter.onGet(
        '/api/auth/me',
        (server) => server.reply(401, {'error': 'unauthorized'}),
      );

      await expectLater(
        api.me(),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 401),
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

  group('resolveConfirmation：路径无 group_id、请求体键是 action', () {
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
        '/chat/confirmations/cf_1/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation('cf_1', action: 'approve');

      expect(capturedBody, isNotNull);
      expect(capturedBody!['action'], 'approve');
      expect(capturedBody!.containsKey('decision'), isFalse);
    });

    test('路径是 /chat/confirmations/:id/resolve（不带 group_id）', () async {
      // 带 group_id 的那个端点（/chat/groups/:gid/confirmations/:id/resolve）
      // 是列表 + 动作语义，不是「解决某张卡」。DioAdapter 默认
      // failOnMissingMock=true，故路径写错本用例会直接失败。
      adapter.onPost(
        '/chat/confirmations/cf_2/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation('cf_2', action: 'reject', comment: '不合适');

      expect(capturedBody!['action'], 'reject');
      expect(capturedBody!['comment'], '不合适');
    });

    test('comment 为 null 时不发送该键', () async {
      adapter.onPost(
        '/chat/confirmations/cf_3/resolve',
        (server) => server.reply(200, {'resolved': true}),
        data: Matchers.any,
      );

      await api.resolveConfirmation('cf_3', action: 'continue');

      expect(capturedBody!.containsKey('comment'), isFalse);
    });
  });
}
