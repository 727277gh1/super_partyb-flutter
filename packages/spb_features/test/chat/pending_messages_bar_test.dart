import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 待处理消息栏的**撤销**语义测试。
///
/// ## 这个测试防的是什么
///
/// 撤销操作打的是 `POST /users/:uid/chat/messages/:message_id/undo`，而服务端
/// 的 `WithdrawChatInboxMessage` 把 WHERE 限定在 `status = 'pending'`：
///
/// ```sql
/// UPDATE chat_inbox_messages SET status='withdrawn', ...
///  WHERE id=? AND user_id=? AND status='pending';
/// ```
///
/// 影响行数为 0 时服务端返回 **409**（消息已被 dispatcher 合并成 turn，或已被
/// 取代/撤回）或 **404**（消息不存在）。这是**预期内的业务结果**，不是故障：
/// 用户想让这条消息别被执行，而它要么已经被处理、要么根本不存在。
///
/// 若把 409 当成普通错误弹「撤销失败」，用户会以为它还会被执行——于是反复点，
/// 反复失败。故必须：提示「已处理，无法撤销」+ 从列表移除。
void main() {
  Map<String, dynamic> inboxJson({
    required String id,
    String input = '帮我看一下这个报错',
    String status = 'pending',
    String? groupId = 'grp_1',
    String agentType = 'pigo',
    String? processedAt,
    String? turnId,
  }) => {
    'id': id,
    'user_id': 'usr_1',
    'group_id': groupId,
    'request_id': 'req_1',
    'agent_id': 'agt_1',
    'agent_type': agentType,
    'input': input,
    'status': status,
    'turn_id': turnId,
    'payload': null,
    'result': null,
    'created_at': '2024-03-05T08:09:10Z',
    'updated_at': '2024-03-05T08:09:12Z',
    'processed_at': processedAt,
  };

  /// ## 为什么默认带一个**不同的** turn_id
  ///
  /// 撤销必须用 `ChatInboxMessage.id`（`chat_inbox_messages.id`），**不是**
  /// `turn_id`——撤销操作的是「还没被 dispatcher 合并成 turn 的那条收件箱记录」。
  /// 若 fixture 的 turn_id 为 null，「误传 turn id」的实现会因为 `?? id` 兜底
  /// 而侥幸通过测试（实测：反向验证确实没被抓住）。
  /// 故这里显式给一个与 id 不同的 turn_id，让误传立刻失败。
  ChatInboxMessage msg(String id, {String input = '某条消息'}) =>
      ChatInboxMessage.fromJson(
        inboxJson(id: id, input: input, turnId: 'turn_of_$id'),
      );

  late List<String> undoIds;
  late LoadPendingMessages load;
  late UndoPendingMessage undo;

  void useStubs({
    List<ChatInboxMessage> Function()? messages,
    Future<void> Function(String id)? undoImpl,
  }) {
    undoIds = [];
    load = () async => messages?.call() ?? const [];
    undo = (id) async {
      undoIds.add(id);
      await undoImpl?.call(id);
    };
  }

  Future<void> pumpBar(
    WidgetTester tester, {
    String reloadKey = 'grp_1',
    FlushPending? flush,
    FlushWithStrategy? flushWithStrategy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PendingMessagesBar(
                load: load,
                undo: undo,
                flush: flush,
                flushWithStrategy: flushWithStrategy,
                reloadKey: reloadKey,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// 推进若干帧（**不能用 `pumpAndSettle`**）。
  ///
  /// ## 为什么本文件不能 pumpAndSettle
  ///
  /// 「立即发送」在途时按钮换成 `CircularProgressIndicator`，而它是**无限
  /// 动画**；流程中还要 `await showDialog(...)` 等用户决策，期间该动画一直在
  /// 跑。`pumpAndSettle` 会一直等到「没有待处理帧」，于是直接超时。
  ///
  /// 用固定时长推进既确定又能覆盖对话框的入场动画（`SpbDuration.normal` 为
  /// 220ms，这里给足 400ms）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 服务端在「多条 pending 且未指定策略」时的响应形态。
  ///
  /// 见 `apps/go-api/internal/server/chat_inbox.go` 的 `flush`：HTTP **200** +
  /// `status=confirmation_required`，且**什么都没提交**。`new_group` 仅在最新
  /// 一条已归属 group 时才出现。
  FlushResult needsConfirmation({
    List<String> options = const ['latest_only', 'merge_all', 'new_group'],
  }) => FlushResult.fromJson({
    'status': 'confirmation_required',
    'reason': 'multiple_pending_messages',
    'options': options,
    'preview': {'latest_input': '第二条', 'merged_input': '第一条\n第二条'},
  });

  FlushResult committed({String strategy = 'merge_all'}) =>
      FlushResult.fromJson({
        'turn_id': 'turn_1',
        'flush_strategy': strategy,
        'consumed_message_ids': ['inbox_1', 'inbox_2'],
      });

  group('待处理消息：撤销', () {
    testWidgets('展示待处理消息正文与 agent_type', (tester) async {
      useStubs(messages: () => [msg('inbox_1', input: '帮我看一下这个报错')]);
      await pumpBar(tester);

      expect(find.text('帮我看一下这个报错'), findsOneWidget);
      expect(find.text('pigo'), findsOneWidget);
      expect(find.text('待处理消息（1）'), findsOneWidget);
    });

    testWidgets('无待处理消息时不占空间（空列表是常态）', (tester) async {
      useStubs(messages: () => const []);
      await pumpBar(tester);

      expect(find.byKey(const ValueKey('pending-messages-bar')), findsNothing);
    });

    testWidgets('点撤销用 ChatInboxMessage.id（不是 turn id）', (tester) async {
      useStubs(messages: () => [msg('inbox_42')]);
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_42')));
      await tester.pump();
      await tester.pump();

      expect(undoIds, ['inbox_42'], reason: '撤销操作的是收件箱记录 id；turn 一旦生成就无法撤销');
    });

    testWidgets('撤销成功后该条从列表移除', (tester) async {
      useStubs(
        messages: () => [
          msg('inbox_1', input: '第一条'),
          msg('inbox_2', input: '第二条'),
        ],
      );
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();
      await tester.pump();

      expect(find.text('第一条'), findsNothing);
      expect(find.text('第二条'), findsOneWidget, reason: '只移除被撤销的那条');
      expect(find.text('待处理消息（1）'), findsOneWidget);
    });

    testWidgets('409（已处理）→ 提示「已处理，无法撤销」且不抛异常、移除该条', (tester) async {
      // 服务端：影响行数 0 且消息存在 → 409「消息当前状态为 committed，无法撤销」。
      useStubs(
        messages: () => [msg('inbox_1')],
        undoImpl: (_) async => throw const HttpError(409, 'HTTP 409'),
      );
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '409 是业务结果，不该崩');
      expect(find.text('已处理，无法撤销'), findsOneWidget);
      expect(
        find.text('第一条'),
        findsNothing,
        reason: '它确实不再是 pending 了；留着只会让用户再点一次、再失败一次',
      );
      expect(find.text('待处理消息（1）'), findsNothing);
    });

    testWidgets('404（消息不存在）→ 提示「消息已不存在」并移除该条', (tester) async {
      useStubs(
        messages: () => [msg('inbox_1')],
        undoImpl: (_) async => throw const HttpError(404, 'HTTP 404'),
      );
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('消息已不存在'), findsOneWidget);
      expect(find.text('待处理消息（1）'), findsNothing);
    });

    testWidgets('500 → 提示撤销失败但**保留**条目（操作可能未生效）', (tester) async {
      useStubs(
        messages: () => [msg('inbox_1', input: '第一条')],
        undoImpl: (_) async => throw const HttpError(500, 'HTTP 500'),
      );
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('撤销失败'), findsOneWidget);
      expect(
        find.text('第一条'),
        findsOneWidget,
        reason: '5xx 意味着操作可能没生效，移除条目会让用户以为撤销成功了',
      );
    });

    testWidgets('网络错误 → 提示撤销失败并保留条目（重试可能成功）', (tester) async {
      useStubs(
        messages: () => [msg('inbox_1', input: '第一条')],
        undoImpl: (_) async => throw const NetworkError('连接超时'),
      );
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();
      await tester.pump();

      expect(find.text('撤销失败：连接超时'), findsOneWidget);
      expect(find.text('第一条'), findsOneWidget);
    });

    testWidgets('撤销中不重复提交（按钮换成进度圈）', (tester) async {
      // 挂起撤销，观察按钮状态。
      final gate = Completer<void>();
      useStubs(messages: () => [msg('inbox_1')]);
      undo = (id) async {
        undoIds.add(id);
        await gate.future;
      };
      await pumpBar(tester);

      await tester.tap(find.byKey(const ValueKey('pending-undo-inbox_1')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('pending-undo-inbox_1')),
        findsNothing,
        reason: '进行中应换成进度圈，避免重复点击发第二次请求',
      );
      expect(undoIds, hasLength(1));

      gate.complete();
      await tester.pump();
      await tester.pump();
    });
  });

  /// 「立即发送」的冲突策略选择。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 服务端在「有多条 pending 且未指定策略」时返回 **HTTP 200** 加
  /// `confirmation_required`——**什么都没提交**。修复前两个 app 的
  /// `flushMessagesProvider` 把这个状态抛成 `ValidationError`，而注入点签名是
  /// `Future<void>`，**没有任何入口能选策略**：用户每次点「立即发送」都失败，
  /// 永远走不到提交成功那条路（功能性死锁）。
  ///
  /// 故本组用例必须证明：待确认**不是终点**，而是「弹选项 → 选中 → 真的提交」。
  group('待处理消息：立即发送的冲突策略', () {
    testWidgets('多条 pending 时出现发送入口，单条也能发', (tester) async {
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(tester, flush: () async => committed());

      expect(
        find.byKey(const ValueKey('pending-flush')),
        findsOneWidget,
        reason: '本栏展示的正是「将要被提交的那几条」，发送入口应在这里',
      );
    });

    testWidgets('未接线时不显示发送入口（不误导用户点空按钮）', (tester) async {
      useStubs(messages: () => [msg('inbox_1')]);
      await pumpBar(tester);

      expect(find.byKey(const ValueKey('pending-flush')), findsNothing);
    });

    testWidgets('提交成功（无待确认）直接完成，不弹策略窗', (tester) async {
      var flushes = 0;
      useStubs(messages: () => [msg('inbox_1')]);
      await pumpBar(
        tester,
        flush: () async {
          flushes++;
          return committed(strategy: 'latest_only');
        },
        flushWithStrategy: (_) async => committed(),
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      expect(flushes, 1);
      expect(find.text('有多条待处理消息'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('待确认时弹策略选择，选中后用该策略重新提交', (tester) async {
      final strategies = <String>[];
      var flushes = 0;
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(
        tester,
        flush: () async {
          flushes++;
          return needsConfirmation();
        },
        flushWithStrategy: (strategy) async {
          strategies.add(strategy);
          return committed(strategy: strategy);
        },
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      // 第一步：默认策略被拒，弹窗出现（三个选项都在）。
      expect(flushes, 1, reason: '默认策略只提交一次，不能循环重试');
      expect(find.text('有多条待处理消息'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('flush-strategy-merge_all')),
        findsOneWidget,
      );

      // 第二步：选中「合并全部为一条」→ 用该策略重试。
      await tester.tap(find.byKey(const ValueKey('flush-strategy-merge_all')));
      await settle(tester);

      expect(strategies, ['merge_all'], reason: '必须把用户选的策略传给服务端；不传就是修复前的死锁');
      expect(tester.takeException(), isNull);
    });

    testWidgets('选项按服务端 options 动态渲染（不硬编码三项）', (tester) async {
      // 服务端仅在「最新一条已归属 group」时才追加 new_group。
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(
        tester,
        flush: () async =>
            needsConfirmation(options: ['latest_only', 'merge_all']),
        flushWithStrategy: (_) async => committed(),
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      expect(
        find.byKey(const ValueKey('flush-strategy-merge_all')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('flush-strategy-new_group')),
        findsNothing,
        reason: '硬编码三项会让用户选到一个必然 400 的选项',
      );
    });

    testWidgets('选项文案与 webapp 一致（三端同一句话）', (tester) async {
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(
        tester,
        flush: () async => needsConfirmation(),
        flushWithStrategy: (_) async => committed(),
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      // 逐条对齐 apps/webapp/messages/zh.json 的 outboxStrategy*。
      expect(find.text('合并全部为一条'), findsOneWidget);
      expect(find.text('在新会话中发送'), findsOneWidget);
      expect(find.text('只发最新一条'), findsOneWidget);
    });

    testWidgets('取消策略选择不提交、不报错（用户主动放弃不是失败）', (tester) async {
      var retried = 0;
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(
        tester,
        flush: () async => needsConfirmation(),
        flushWithStrategy: (_) async {
          retried++;
          return committed();
        },
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);
      // 点遮罩关闭对话框。
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);

      expect(retried, 0);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('立即发送失败'), findsNothing);
    });

    testWidgets('无选策略回调时把待确认上报为错误（不能假装成功）', (tester) async {
      useStubs(messages: () => [msg('inbox_1'), msg('inbox_2')]);
      await pumpBar(tester, flush: () async => needsConfirmation());

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      // 服务端一条都没提交，必须让用户知道；静默会让用户以为发好了。
      expect(find.textContaining('立即发送失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('提交成功后重新加载（已提交的不能再挂在待处理里）', (tester) async {
      var calls = 0;
      var items = [msg('inbox_1'), msg('inbox_2')];
      load = () async {
        calls++;
        return items;
      };
      undo = (_) async {};
      await pumpBar(tester, flush: () async => committed());
      expect(calls, 1);

      // 模拟服务端把这两条标为 committed。
      items = [];
      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await tester.pump();
      await tester.pump();

      expect(calls, 2, reason: '不刷新会让已提交的消息继续显示为待处理');
      expect(find.byKey(const ValueKey('pending-messages-bar')), findsNothing);
    });

    testWidgets('在途时禁用发送入口（防重复提交）', (tester) async {
      final gate = Completer<FlushResult>();
      var flushes = 0;
      useStubs(messages: () => [msg('inbox_1')]);
      await pumpBar(
        tester,
        flush: () {
          flushes++;
          return gate.future;
        },
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await tester.pump();

      expect(flushes, 1);
      expect(
        find.byKey(const ValueKey('pending-flush')),
        findsNothing,
        reason: '在途应换成进度圈，避免连点发多次请求',
      );

      gate.complete(committed());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('提交失败时提示且复位（不永久禁用）', (tester) async {
      useStubs(messages: () => [msg('inbox_1')]);
      await pumpBar(
        tester,
        flush: () async => throw const NetworkError('连接超时'),
      );

      await tester.tap(find.byKey(const ValueKey('pending-flush')));
      await settle(tester);

      expect(find.text('立即发送失败：连接超时'), findsOneWidget);
      expect(find.byKey(const ValueKey('pending-flush')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('待处理消息：加载与刷新', () {
    testWidgets('加载失败展示错误与重试（不能静默成「没有待处理消息」）', (tester) async {
      var calls = 0;
      load = () async {
        calls++;
        throw const NetworkError('连接超时');
      };
      undo = (_) async {};
      await pumpBar(tester);

      expect(find.textContaining('待处理消息加载失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('pending-retry')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pending-retry')));
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
    });

    testWidgets('点刷新重新加载（dispatcher 消费后本栏不会自动感知）', (tester) async {
      var calls = 0;
      var items = [msg('inbox_1')];
      load = () async {
        calls++;
        return items;
      };
      undo = (_) async {};
      await pumpBar(tester);
      expect(calls, 1);

      // 模拟 dispatcher 消费掉了它。
      items = [];
      await tester.tap(find.byKey(const ValueKey('pending-refresh')));
      await tester.pump();
      await tester.pump();

      expect(calls, 2);
      expect(find.byKey(const ValueKey('pending-messages-bar')), findsNothing);
    });

    testWidgets('切换 group（reloadKey 变化）重新加载并先清空旧 group 的消息', (tester) async {
      // ## 这个用例防的是什么
      //
      // 从 /chat/g1 切到 /chat/g2 时 Flutter 会**复用**本组件的 State（widget
      // 类型与位置都没变），initState 不会重跑。若不处理，列表会一直显示 g1 的
      // 消息——而那些 id 在 g2 里不存在，点撤销会得到 404。
      var group = 'grp_1';
      load = () async => group == 'grp_1'
          ? [msg('inbox_g1', input: 'g1 的消息')]
          : [msg('inbox_g2', input: 'g2 的消息')];
      undo = (_) async {};

      await pumpBar(tester, reloadKey: 'grp_1');
      expect(find.text('g1 的消息'), findsOneWidget);

      group = 'grp_2';
      await pumpBar(tester, reloadKey: 'grp_2');

      expect(find.text('g2 的消息'), findsOneWidget);
      expect(find.text('g1 的消息'), findsNothing);
    });
  });
}
