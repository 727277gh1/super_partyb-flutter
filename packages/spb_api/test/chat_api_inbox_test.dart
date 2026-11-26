import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_api_harness.dart';

/// ChatApi 的 inbox 契约测试（pendingMessages / undoMessage / ChatInboxMessage）
///
/// ⚠️ 本文件由 `chat_api_test.dart` 按 group 边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/chat_api_harness.dart`。
void main() {
  setUpHarness();

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
}
