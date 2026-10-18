import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_api_harness.dart';

/// ChatApi 的消息与确认契约测试（quickCapture / me / resolveConfirmation / search）
///
/// ⚠️ 本文件由 `chat_api_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/chat_api_harness.dart`。
void main() {
  setUpHarness();

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
}
