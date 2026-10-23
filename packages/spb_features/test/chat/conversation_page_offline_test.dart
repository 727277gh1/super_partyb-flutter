import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 离线缓存与离线队列（issue #29 切片 B / #30）
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

  group('离线时间线提示条（issue #29 切片 B）', () {
    /// 造一条可缓存的历史事件。
    ChatEvent cachedEvent(String text, {int globalSeq = 1}) => ChatEvent(
      eventId: 'evt_$globalSeq',
      userId: 'usr_1',
      groupId: 'grp_1',
      turnId: 'turn_$globalSeq',
      eventType: EventTypes.userMessage,
      seq: 1,
      globalSeq: globalSeq,
      source: 'user',
      createdAt: DateTime.utc(2024, 3, 5),
      payload: {'input': text},
    );

    testWidgets('回填失败但有缓存 → 渲染历史 + 显示离线提示条（不显示空态）', (tester) async {
      // 反向验证：去掉对话页的 `_OfflineTimelineNotice` 渲染 → 本用例失败。
      final cache = FakeTimelineCache([
        cachedEvent('缓存里的第一条'),
        cachedEvent('缓存里的第二条', globalSeq: 2),
      ]);
      controller = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      // 不挂 timeline mock → 回填失败。
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 300,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 300,
        }),
      );

      await startController(tester);
      await tester.pumpAndSettle();
      await pumpPage(tester);

      // 历史被渲染（不是空态）。
      expect(find.text('缓存里的第一条'), findsOneWidget);
      expect(find.text('缓存里的第二条'), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);

      // 离线提示条存在。
      expect(
        find.byKey(const ValueKey('conversation-offline-timeline')),
        findsOneWidget,
      );
      expect(find.textContaining('离线数据'), findsOneWidget);
    });

    testWidgets('回填失败且无缓存 → 空态，**不显示**离线提示条', (tester) async {
      // 反向验证：把「有无缓存」判据去掉（一律显示提示条）→ 本用例失败。
      //
      // 无缓存时是「确实没有内容」，不是「离线数据」——显示离线提示会让用户
      // 以为「本来有内容但看不到」。
      controller = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: FakeTimelineCache(),
      );
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 300,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 300,
        }),
      );

      await startController(tester);
      await tester.pumpAndSettle();
      await pumpPage(tester);

      expect(find.byType(EmptyState), findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-offline-timeline')),
        findsNothing,
      );
    });

    testWidgets('网络成功时**不显示**离线提示条', (tester) async {
      final cache = FakeTimelineCache([cachedEvent('缓存内容')]);
      controller = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      mockTimeline();
      await startController(tester);
      await tester.pumpAndSettle();
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('conversation-offline-timeline')),
        findsNothing,
      );
    });

    testWidgets('页面在回落**之后**挂载也能看到提示条（初值取快照）', (tester) async {
      // 反向验证：把 `_timelineFromCache` 初值改成写死的 false → 本用例失败。
      //
      // 真实路径：用户从列表页点进对话 → `switchGroup` 先跑（回落完成）→
      // 对话页才挂载。只看流会错过那一次推送。
      final cache = FakeTimelineCache([cachedEvent('缓存内容')]);
      controller = ChatStreamController(
        sse: sse,
        api: api,
        userId: 'usr_1',
        timelineCache: cache,
      );
      adapter.onGet(
        '/api/chat/turn-runtime',
        (server) => server.reply(200, {
          'request_timeout_seconds': 300,
          'inactivity_timeout_seconds': 0,
          'client_turn_timeout_seconds': 300,
        }),
      );
      // 控制器先跑（此时对话页尚未挂载）。
      await startController(tester);
      await tester.pumpAndSettle();
      expect(controller.timelineFromCacheSnapshot, isTrue, reason: '前提：已回落');

      // 现在才挂载页面。
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('conversation-offline-timeline')),
        findsOneWidget,
        reason: '挂载时必须从快照取初值，否则提示条永不出现',
      );
    });
  });

  group('离线队列待发送条（issue #30）', () {
    OutboxEntry entry({
      String id = 'req-1',
      String input = '断网时写的一句',
      int attempts = 1,
      String? lastError = '断网',
      int maxAttempts = 10,
      String? groupId = 'grp_1',
    }) => OutboxEntry(
      id: id,
      userId: 'usr_1',
      input: input,
      groupId: groupId,
      createdAt: DateTime.utc(2026),
      attempts: attempts,
      nextAttemptAt: DateTime.utc(2026),
      lastError: lastError,
      maxAttempts: maxAttempts,
    );

    testWidgets('未注入 outboxEntries 时不渲染（未接线时页面仍是纯只读时间线）', (tester) async {
      await pumpPage(tester);

      expect(find.byKey(const ValueKey('outbox-bar')), findsNothing);
    });

    testWidgets('空队列不占空间（首帧撑出空白再收起会造成布局跳动）', (tester) async {
      await pumpPage(tester, wireOutbox: true, outbox: const []);

      expect(find.byKey(const ValueKey('outbox-bar')), findsNothing);
    });

    testWidgets('有条目时展示输入文本 + 标题计数', (tester) async {
      await pumpPage(tester, wireOutbox: true, outbox: [entry()]);

      expect(find.byKey(const ValueKey('outbox-bar')), findsOneWidget);
      expect(find.text('待发送（1） · 联网后自动发送'), findsOneWidget);
      expect(find.text('断网时写的一句'), findsOneWidget);
    });

    testWidgets('流推送后更新（队列是活的，不是首帧快照）', (tester) async {
      final stream = StreamController<List<OutboxEntry>>.broadcast();
      addTearDown(stream.close);
      await pumpPage(tester, wireOutbox: true, outboxStream: stream.stream);

      expect(find.byKey(const ValueKey('outbox-bar')), findsNothing);

      stream.add([entry()]);
      await tester.pump();
      await tester.pump();

      expect(find.text('断网时写的一句'), findsOneWidget);
    });

    testWidgets('重试用尽的条目 → 换警示色 + 「需手动重试」+ 展示失败原因', (tester) async {
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry(attempts: 10, lastError: '连接超时')],
      );

      // 文案不编造：只有真有 failed 才说「需手动重试」。
      expect(find.text('待发送（1） · 1 条需手动重试'), findsOneWidget);
      // 失败原因直接展示：用户要知道是「网络」还是「请求本身有问题」。
      expect(find.text('连接超时'), findsOneWidget);
    });

    testWidgets('非失败条目给「取消」，失败条目给「重试」（窄条只放一个主操作）', (tester) async {
      // ⚠️ 必须先给回调再挂载：按钮只在回调非 null 时渲染（面板在回调为
      // null 时不渲染对应操作项）。
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry()],
        onCancelOutbox: (_) async => true,
        onRetryOutbox: (_) async => true,
      );
      expect(find.byKey(const ValueKey('outbox-cancel-req-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('outbox-retry-req-1')), findsNothing);

      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry(attempts: 10, lastError: '超时')],
        onCancelOutbox: (_) async => true,
        onRetryOutbox: (_) async => true,
      );
      expect(find.byKey(const ValueKey('outbox-retry-req-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('outbox-cancel-req-1')), findsNothing);
    });

    testWidgets('点取消 → 回调收到 id', (tester) async {
      String? cancelled;
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry()],
        onCancelOutbox: (id) async {
          cancelled = id;
          return true;
        },
      );

      await tester.tap(find.byKey(const ValueKey('outbox-cancel-req-1')));
      await tester.pump();

      expect(cancelled, 'req-1');
    });

    testWidgets('点重试 → 回调收到 id', (tester) async {
      String? retried;
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry(attempts: 10, lastError: '超时')],
        onRetryOutbox: (id) async {
          retried = id;
          return true;
        },
      );

      await tester.tap(find.byKey(const ValueKey('outbox-retry-req-1')));
      await tester.pump();

      expect(retried, 'req-1');
    });

    testWidgets('点丢弃 → 回调收到 id', (tester) async {
      String? removed;
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [entry()],
        onRemoveOutbox: (id) async => removed = id,
      );

      await tester.tap(find.byKey(const ValueKey('outbox-remove-req-1')));
      await tester.pump();

      expect(removed, 'req-1');
    });

    testWidgets('超过 3 条时只渲染前 3 条 + 「还有 N 条…」（窄条不能撑爆输入区）', (tester) async {
      await pumpPage(
        tester,
        wireOutbox: true,
        outbox: [for (var i = 0; i < 5; i++) entry(id: 'r$i', input: '第 $i 条')],
      );

      expect(find.text('第 0 条'), findsOneWidget);
      expect(find.text('第 2 条'), findsOneWidget);
      expect(find.text('第 3 条'), findsNothing);
      expect(find.text('还有 2 条…'), findsOneWidget);
      expect(find.text('待发送（5） · 联网后自动发送'), findsOneWidget);
    });

    testWidgets('发送遇 MessageQueuedError → 提示「已加入待发送」而非「发送失败」', (tester) async {
      // ## 为什么这条必须有
      //
      // 两者都继承 SpbError，但用户的正确反应完全相反：前者要「等着，别重打」
      // （重打会发两条），后者要「改一下再试」。若页面把它们都当失败提示，
      // 用户会以为消息丢了、然后重打一遍。
      await pumpPage(
        tester,
        onSend: (_) async => throw const MessageQueuedError('断网'),
      );

      await tester.enterText(find.byType(TextField), '断网时写的');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('已加入待发送'), findsOneWidget);
      expect(find.textContaining('发送失败'), findsNothing);
    });

    testWidgets('发送遇普通错误 → 仍提示「发送失败」', (tester) async {
      await pumpPage(
        tester,
        onSend: (_) async => throw const HttpError(400, '输入不合法'),
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await tester.pumpAndSettle();

      expect(find.textContaining('发送失败'), findsOneWidget);
    });
  });
}
