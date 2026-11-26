import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 「动态」入口在移动端的接线（B）。
///
/// ## 这个文件防的是什么
///
/// 「动态」面板本身有组件级用例（`packages/spb_features/test/chat/
/// group_activity_panel_test.dart`），它自己传参、自己造数据——**接不接线它
/// 不管**。而移动端这里最容易漏的恰恰是接线（AGENTS.md §6.16 / §6.33 的同一
/// 教训：移动端宽屏搜索入口就是这么静默丢掉的）：
///
/// - 入口只在宽屏摆图标 → 窄屏彻底不可达（必须同时进溢出菜单）；
/// - 弹层用 `controller.gateDecisions` → 移动端不订阅该流，会渲染一个**永远
///   空**的 gate 区块（「没有决策」与「不看这个」视觉上无法区分）；
/// - 弹层是一次性快照 → 打开后页面继续收到 SSE 事件，面板却冻住（这正是
///   `_activityTick` 存在的原因，也是它最容易被「优化掉」的地方）。
void main() {
  /// 进入对话页所需的最小 mock（时间线 + 待处理栏）。
  ///
  /// `/api/auth/me` 与 `/chat/groups` 由 `pumpApp` 默认注册，无需重复。
  void mockChat(DioAdapter adapter, {String groupId = 'grp_act'}) {
    adapter.onGet(
      '/chat/groups/$groupId',
      (server) => server.reply(200, {
        'id': groupId,
        'user_id': 'usr_TEST',
        'title': '动态测试',
      }),
    );
    adapter.onGet(
      '/chat/groups/$groupId/timeline',
      (server) => server.reply(200, {
        'items': <Map<String, dynamic>>[],
        'next_before_global_seq': '',
      }),
      queryParameters: {'limit': 200},
    );
    adapter.onGet(
      '/users/usr_TEST/chat/messages/pending',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'group_id': groupId, 'limit': 20},
    );
  }

  testWidgets('宽屏（≥720dp）「动态」是 AppBar 独立图标，点开渲染面板', (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: mockChat,
    );
    // 先起 app 再用 `router.go` 进对话（与 `router_notify_test.dart` 的
    // `pumpInChat` 同一约定）：直接以 `initialLocation: SpbRoutes.chat(...)`
    // 启动时，页面在 `restore()` 落定前就构建，随后的路由重解析会让**注入的
    // SSE 帧再也到不了页面**（实测：push 后时间线不更新，而 `router.go` 的
    // 同样 push 立刻生效）。
    h.router.go(SpbRoutes.chat('grp_act'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final icon = find.byKey(const ValueKey('open-group-activity'));
    expect(icon, findsOneWidget, reason: '宽屏有余量，低频入口直接摆图标（与既有入口一致）');
    expect(
      tester.takeException(),
      isNull,
      reason: '新增一个 48dp 图标后 AppBar 仍不得溢出（issue #31 的反向守卫）',
    );

    await tester.tap(icon);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('activity-panel')),
      findsOneWidget,
      reason: '入口必须真的打开面板，而不是只关掉什么',
    );
    expect(
      find.byKey(const ValueKey('activity-status')),
      findsOneWidget,
      reason: '面板顶部必须有「这一刻在干什么」的状态行',
    );
  });

  testWidgets('窄屏（<720dp）「动态」收进溢出菜单，点开渲染同一面板', (tester) async {
    tester.view.physicalSize = const Size(360, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: mockChat,
    );
    // 先起 app 再用 `router.go` 进对话（与 `router_notify_test.dart` 的
    // `pumpInChat` 同一约定）：直接以 `initialLocation: SpbRoutes.chat(...)`
    // 启动时，页面在 `restore()` 落定前就构建，随后的路由重解析会让**注入的
    // SSE 帧再也到不了页面**（实测：push 后时间线不更新，而 `router.go` 的
    // 同样 push 立刻生效）。
    h.router.go(SpbRoutes.chat('grp_act'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byKey(const ValueKey('open-group-activity')),
      findsNothing,
      reason: '窄屏没有余量摆这个图标（会与常驻项抢宽度）',
    );

    await tester.tap(find.byKey(const ValueKey('conversation-overflow-menu')));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('menu-group-activity'));
    expect(item, findsOneWidget, reason: '藏掉入口等于「本端没这个功能」——只能多一步，不能消失');

    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('activity-panel')), findsOneWidget);
  });

  testWidgets('弹层不渲染 gate 决策区块（移动端不订阅 decisions）', (tester) async {
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: mockChat,
    );
    // 先起 app 再用 `router.go` 进对话（与 `router_notify_test.dart` 的
    // `pumpInChat` 同一约定）：直接以 `initialLocation: SpbRoutes.chat(...)`
    // 启动时，页面在 `restore()` 落定前就构建，随后的路由重解析会让**注入的
    // SSE 帧再也到不了页面**（实测：push 后时间线不更新，而 `router.go` 的
    // 同样 push 立刻生效）。
    h.router.go(SpbRoutes.chat('grp_act'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byKey(const ValueKey('open-group-activity')));
    await tester.pumpAndSettle();

    // `decisions: null` 的语义是「本端不展示这一块」，而不是「没有决策」。
    expect(find.byKey(const ValueKey('gate-list')), findsNothing);
    expect(
      find.byKey(const ValueKey('gate-empty')),
      findsNothing,
      reason: '渲染一个恒为空的「没有 gate 决策」区块是在说一件没发生的事',
    );
    // 工具调用区块仍在（它不依赖 gate 订阅）。
    expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
  });

  /// ## 反向验证的实测结论（别据此以为「摘掉哪条 bump 都能被发现」）
  ///
  /// 控制器每次 `_emit` 都会**重新推送** items / activities / executionStatus
  /// 三条流（见 `chat_stream_controller.dart` 的 `_emit`），所以页面这四个
  /// 回调里有三条会同时触发。实测：
  ///
  /// - 只摘掉 `_onItemsChanged` 的 bump → 用例**仍绿**；
  /// - 只摘掉 `_onActivitiesChanged` 的 bump → 仍绿；
  /// - 把四条 bump **全部**摘掉 → 用例红（面板停在 `toolcalls-empty`）。
  ///
  /// 故本用例守的是「弹层不会冻住」这个机制，而不是某一条具体的 bump。
  /// 想守到具体某一条，得先用只产生 items、不重新推送 activities 的路径驱动，
  /// 而那在真实控制器里不存在——所以不要写那种断言。
  testWidgets('弹层打开后仍随 SSE 事件更新（_activityTick 哨兵）', (tester) async {
    final sse = FakeSseClient();
    final h = await pumpApp(tester, sseClient: sse, beforePump: mockChat);
    // 先起 app 再用 `router.go` 进对话（与 `router_notify_test.dart` 的
    // `pumpInChat` 同一约定）：直接以 `initialLocation: SpbRoutes.chat(...)`
    // 启动时，页面在 `restore()` 落定前就构建，随后的路由重解析会让**注入的
    // SSE 帧再也到不了页面**（实测：push 后时间线不更新，而 `router.go` 的
    // 同样 push 立刻生效）。
    h.router.go(SpbRoutes.chat('grp_act'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byKey(const ValueKey('open-group-activity')));
    await tester.pumpAndSettle();

    // 打开时一个工具都还没有。
    expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);

    sse.push('tool_call', {
      'eventId': 'e_tc1',
      'eventType': 'tool_call',
      'userId': 'usr_TEST',
      'groupId': 'grp_act',
      'turnId': 'turn_1',
      'seq': 3,
      'globalSeq': 3,
      'payload': {'tool_call_id': 'c1', 'name': 'grep'},
      'createdAt': '2026-01-01T00:00:00Z',
    });
    // 收尾 `done`：`tool_call` 会让 turn 进入进行中，控制器据此武装看门狗
    // 计时器；不收尾会留下 pending timer（同 `router_notify_test.dart` 里
    // 推 message 后必须补 done 的说明）。工具项本身仍留在时间线里。
    sse.push('done', {
      'eventId': 'e_done',
      'eventType': 'done',
      'userId': 'usr_TEST',
      'groupId': 'grp_act',
      'turnId': 'turn_1',
      'seq': 4,
      'globalSeq': 4,
      'payload': <String, dynamic>{},
      'createdAt': '2026-01-01T00:00:01Z',
    });
    // 弹层是**独立 route**：页面的 `setState` 不会让它重建，靠 `_activityTick`
    // 转一次（见 router 里 `_bumpActivitySheet` 的文档）。
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 限定在面板内找：时间线上也有一张同名的工具卡（折叠前），全局
    // `find.text('grep')` 会命中两处，断言就成了「有地方显示了」。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('activity-panel')),
        matching: find.text('grep'),
      ),
      findsOneWidget,
      reason: '弹层若停止刷新，用户会以为「它已经不动了」——这是最坏的误判',
    );
    expect(find.byKey(const ValueKey('toolcalls-empty')), findsNothing);
  });
}
