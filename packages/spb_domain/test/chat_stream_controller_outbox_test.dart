import 'dart:async';

import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 离线写队列接线（issue #30）
///
/// ⚠️ 本文件由 `chat_stream_controller_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
void main() {
  setUpHarness();

  group('离线写队列接线（issue #30）', () {
    /// 内存版 OutboxStore（与 `outbox_test.dart` 的同构；本文件只关心
    /// 控制器与队列的接线，队列自身行为由那份测试覆盖）。
    final store = FakeOutboxStore();

    setUp(store.rows.clear);

    test('可重试错误（断网）→ 入队，send 抛 MessageQueuedError', () async {
      // 断网：mock 一个连不上的地址（http_mock_adapter 无匹配路由 → 抛错）。
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queueFor(store, fail: const NetworkError('断网')),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      await expectLater(
        c.send(input: '断网时写的一句'),
        throwsA(isA<MessageQueuedError>()),
      );

      // 消息**没有丢**：进了队列（而不是只在 UI 上弹个「发送失败」）。
      expect(store.rows, hasLength(1));
      expect(store.rows.values.single.input, '断网时写的一句');

      await c.dispose();
    });

    test('入队后**不**注入乐观回显（避免服务端 user_message 到达后两个气泡）', () async {
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queueFor(store, fail: const NetworkError('断网')),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      try {
        await c.send(input: '断网时写的一句');
      } on MessageQueuedError {
        // 预期。
      }

      // ## 为什么这里必须是空的
      //
      // 入队的条目还没有 turnId，而归约器**按 turnId 去重**。若在此注入
      // 一个无 turnId 的本地项，服务端随后的 `user_message` 会被当成新消息
      // → 用户看到**两个气泡**。
      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('终态错误（400）→ 不入队，照旧上抛（重试无用）', () async {
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queueFor(store),
      );
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(400, {'error': '输入不合法'}),
        data: Matchers.any,
      );

      await expectLater(c.send(input: 'x'), throwsA(isA<HttpError>()));
      expect(store.rows, isEmpty, reason: '400 重试一万次还是 400');

      await c.dispose();
    });

    test('未注入队列时行为不变：可重试错误照旧上抛', () async {
      // 这是**向后兼容**的保证：页面单测与「未接线的宿主」不该因为本特性
      // 而看到新的异常类型。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      adapter.onPost(
        '/users/usr_1/chat/messages',
        (server) => server.reply(503, {'error': 'unavailable'}),
        data: Matchers.any,
      );

      await expectLater(c.send(input: 'x'), throwsA(isA<HttpError>()));

      await c.dispose();
    });

    test('队列投递成功 → 用服务端 turnId 注入回显（进时间线）', () async {
      final queue = queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      // 先把控制器挂到 grp_1 上（delivered 只在同 group 时注入）。
      mockTimeline();
      // ⚠️ 必须 await：`_bindOutbox` 在 `start` 的 `_backfill` 之后才执行，
      // 不等它跑完，队列投递的事件会被订阅前的窗口吞掉。
      await c.start(groupId: 'grp_1');

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: '离线时写的',
          groupId: 'grp_1',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      final item = c.snapshot.whereType<UserMessageItem>().single;
      expect(item.text, '离线时写的');
      // turnId 来自服务端响应 —— 只有这样随后的 user_message 才会原位合并。
      expect(item.turnId, 'turn-out');

      await c.dispose();
    });

    test('投递成功但属于**别的**对话 → 不注入（用户已切走）', () async {
      // 投递本身**成功**（队列正常），但归属的是另一个 group。
      final queue = queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      // ⚠️ `start(groupId:)` 才是「聚焦到某个对话」——`switchGroup` 不会建立
      // SSE 连接（它假定连接已由 `start` 建好），故这里用 start。
      mockTimeline();
      await c.start(groupId: 'grp_1');

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: '别的对话的消息',
          groupId: 'grp_other',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      // 队列是全局的：在 A 对话入队、投递成功时用户可能已切到 B。
      expect(c.snapshot.whereType<UserMessageItem>(), isEmpty);
      // 条目已出队（投递**确实**成功了）——证明「没注入」不是因为投递没发生。
      expect(queue.snapshot, isEmpty);

      await c.dispose();
    });

    test('SSE 变为 connected → 触发队列重试（onConnectivityRestored）', () async {
      final queue = queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      unawaited(c.start());

      // 先塞一条在退避窗口里的条目（否则 onConnectivityRestored 无事可做）。
      final future = DateTime.now().add(const Duration(hours: 1));
      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          attempts: 1,
          nextAttemptAt: future,
          lastError: '断网',
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      expect(
        queue.snapshot.single.nextAttemptAt.isAfter(DateTime.now()),
        isTrue,
      );

      sse.emitState(SseState.connected);
      await Future<void>.delayed(Duration.zero);

      // 恢复网络后不该干等退避计时器。
      expect(queue.snapshot, isEmpty, reason: '应被立刻重投并成功');

      await c.dispose();
    });

    test('队列终态失败 → 推 MessageDeliveryFailedError 到 errors 流', () async {
      // 400：终态错误（不是重试用尽），条目会被移除并上报。
      final queue = queueFor(store, fail: const HttpError(400, '输入不合法'));
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      unawaited(c.start());

      final errors = <SpbError>[];
      c.errors.listen(errors.add);

      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);

      expect(errors.whereType<MessageDeliveryFailedError>(), hasLength(1));

      await c.dispose();
    });

    test('dispose 会退订队列流（不再向已释放的控制器推事件）', () async {
      final queue = queueFor(store);
      final c = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        outbox: queue,
      );
      unawaited(c.start());
      await c.dispose();

      // 释放后再投递：控制器不该崩（订阅已取消）。
      await store.upsert(
        OutboxEntry(
          id: 'req-1',
          userId: 'usr_1',
          input: 'x',
          createdAt: DateTime.utc(2026),
          nextAttemptAt: DateTime.utc(2026),
        ),
      );
      await queue.load('usr_1');
      await Future<void>.delayed(Duration.zero);
    });
  });
}
