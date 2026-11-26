import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_mobile/app.dart';
import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 对话列表 / 悬浮窗 / 新建对话 / 交付物 / 待办 / 待确认角标（router 装配）
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/mobile_harness.dart`。
void main() {
  testWidgets('列表按快照展示，状态事件不更新，手动刷新和重新进入时取新数据', (tester) async {
    final sse = FakeSseClient();
    var confirmationRequests = 0;
    var groupRequests = 0;
    var pending = 1;
    Map<String, dynamic> snapshot = {
      'goal': {
        'id': 'goal1',
        'goal_text': '完成发布',
        'current_task_id': 'TASK-001',
      },
      'tasks': [
        {'task_id': 'TASK-001', 'title': '检查签名', 'status': 'pending'},
      ],
      'progress': {'total': 2, 'completed': 0},
    };
    final h = await pumpApp(
      tester,
      sseClient: sse,
      mockGroups: false,
      mockPendingConfirmations: false,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/groups',
          (server) => server.replyCallback(200, (_) {
            groupRequests++;
            return {
              'items': [
                {
                  'id': 'g1',
                  'title': '发布版本',
                  'status': 'active',
                  'current_goal': snapshot,
                },
                {'id': 'g2', 'title': '其他对话', 'status': 'active'},
              ],
            };
          }),
          queryParameters: {'limit': 30, 'offset': 0},
        );
        adapter.onGet(
          '/chat/confirmations',
          (server) => server.replyCallback(200, (_) {
            confirmationRequests++;
            return {
              'items': [
                for (var i = 0; i < pending; i++)
                  {'id': 'c$i', 'group_id': 'g1', 'status': 'pending'},
                {'id': 'other', 'group_id': 'not_loaded', 'status': 'pending'},
              ],
            };
          }),
          queryParameters: {'status': 'pending', 'limit': 50},
        );
      },
    );
    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }

    await settle();
    expect(find.text('待你确认 · 1 项'), findsOneWidget);
    expect(find.text('0/2 步 · 检查签名'), findsOneWidget);
    expect(confirmationRequests, 1);
    expect(groupRequests, 1);
    snapshot = {
      'goal': {
        'id': 'goal1',
        'goal_text': '完成发布',
        'current_task_id': 'TASK-002',
      },
      'tasks': [
        {'task_id': 'TASK-002', 'title': '构建安装包', 'status': 'blocked'},
      ],
      'progress': {'total': 2, 'completed': 1, 'blocked': 1},
    };
    pending = 0;
    sse.push('goal_updated', {
      'eventId': 'goal_evt',
      'eventType': 'goal_updated',
      'userId': 'usr_TEST',
      'groupId': 'g1',
      'turnId': '',
      'createdAt': '2026-11-10T00:00:00Z',
      'payload': {'op': 'task_status', ...snapshot},
    });
    for (final type in [
      'confirmation_required',
      'confirmation_resolved',
      'confirmation_expired',
    ]) {
      sse.push(type, {
        'eventId': 'evt_$type',
        'eventType': type,
        'userId': 'usr_TEST',
        'groupId': 'g1',
        'turnId': 'turn1',
        'createdAt': '2026-11-10T00:00:00Z',
        'payload': {'confirmation_id': 'c0'},
      });
    }
    await settle();
    expect(confirmationRequests, 1, reason: '停留列表时，确认事件不能触发额外查询');
    expect(groupRequests, 1);
    expect(find.text('待你确认 · 1 项'), findsOneWidget);
    expect(find.text('0/2 步 · 检查签名'), findsOneWidget);
    expect(find.textContaining('任务阻塞'), findsNothing);
    // 两端的下拉刷新与桌面刷新按钮共用该入口。
    unawaited(
      tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh(),
    );
    await settle();
    expect(confirmationRequests, 2);
    expect(groupRequests, 2);
    expect(find.textContaining('待你确认'), findsNothing);
    expect(find.text('1/2 步 · 构建安装包'), findsOneWidget);
    expect(find.text('1 项任务阻塞 · 构建安装包'), findsOneWidget);
    // 无确认事件也要在返回列表时重新读取；不能依赖上次事件将缓存标脏。
    h.router.go(SpbRoutes.search);
    await settle();
    pending = 2;
    h.router.go(SpbRoutes.conversations);
    await settle();
    expect(confirmationRequests, 3);
    expect(groupRequests, 3);
    expect(find.text('待你确认 · 2 项'), findsOneWidget);
    // push/pop 也必须识别顶部路由，不能只读底层列表的 URI。
    final pushed = h.router.push<void>(SpbRoutes.search);
    await settle();
    pending = 1;
    h.router.pop();
    await pushed;
    await settle();
    expect(confirmationRequests, 4);
    expect(groupRequests, 4);
    expect(find.text('待你确认 · 1 项'), findsOneWidget);
    // 移动端设置是另一个保留状态的 tab，返回时同样更新。
    h.router.go(SpbRoutes.settings);
    await settle();
    pending = 2;
    h.router.go(SpbRoutes.conversations);
    await settle();
    expect(confirmationRequests, 5);
    expect(groupRequests, 5);
    expect(find.text('待你确认 · 2 项'), findsOneWidget);
    // 新凭证代际仍需隔离旧确认计数。
    pending = 0;
    h.container.read(sessionRevisionProvider.notifier).advance();
    await settle();
    expect(confirmationRequests, 6);
    expect(find.textContaining('待你确认'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('首页渲染对话列表（无底部标签栏）', (tester) async {
    final dio = createDio(baseUrl: 'https://api.test/pba');
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {
        'items': [
          {
            'id': 'g1',
            'user_id': 'usr_1',
            'title': '移动端测试对话',
            'status': 'active',
            'created_at': '2024-03-05T08:00:00Z',
            'updated_at': '2024-03-05T08:09:10Z',
          },
        ],
      }),
      queryParameters: {'limit': 30, 'offset': 0},
    );
    // 对话列表页的待确认角标 provider 首帧即拉取。
    adapter.onGet(
      '/chat/confirmations',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'status': 'pending', 'limit': 50},
    );
    // 对话列表页要解析 userId 才能建 SSE（groupUpdatesProvider 的 family 键），
    // 故必须 mock `/me`——否则请求悬空，留下未结算的 Timer。
    adapter.onGet(
      '/api/auth/me',
      (server) => server.reply(200, {
        'id': 'usr_1',
        'email': 'a@b.c',
        'name': 'Test',
        'role': 'member',
        'roles': ['member'],
        'permissions': <String>[],
        'status': 'active',
      }),
    );

    final router = GoRouter(
      routes: buildMobileRoutes(),
      redirect: buildAuthRedirect(),
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        desktopCapabilitiesProvider.overrideWithValue(
          const NoopDesktopCapabilities(),
        ),
        dioProvider.overrideWithValue(dio),
        // 注入已登录凭证，否则守卫会把列表重定向到 /login。
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore(freshTokens())),
        signInActionProvider.overrideWithValue(() async => null),
        // 对话列表页会订阅 groupUpdatesProvider 并建立共享 SSE 连接。
        // 真实 SseClient 走流式响应，DioAdapter 不模拟，会留下重连 Timer
        // （→「A Timer is still pending」），故注入假实现。
        sseClientProvider.overrideWithValue(FakeSseClient()),
        // 列表卡片的 agent 名称来自 `/api/agents` 映射（`agentNamesProvider`）。
        // 真实实现会打未注册的 `/api/agents` → dio 起重试 Timer（同上方 SSE 的
        // 「A Timer is still pending」根因），故注入空列表。
        loadAgentsProvider.overrideWithValue(() async => const <Agent>[]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: SpbMobileApp(router: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('移动端测试对话'), findsOneWidget);
    // 没有底部标签栏：首页只有列表 + AppBar，设置等低频入口在 `≡` 菜单里。
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('对话'), findsWidgets);
    // 新建对话的入口是 FAB（＋）：上一版是闪电（快速输入），现已让位。
    expect(
      find.byKey(const ValueKey('group-list-create-fab')),
      findsOneWidget,
      reason: '移动端最高频的动作应在拇指可达处',
    );
  });

  testWidgets('对话列表 ≡ 菜单进入 /overlay（无归属入口在移动端可达）', (tester) async {
    // ## 本用例防的是什么
    //
    // `/overlay` 路由、页面、provider 接线、甚至自己的用例此前**全都在**，
    // 但没有任何导航调用点：桌面端靠 Alt+Space 与托盘，而移动端既无快捷键
    // 也无托盘，于是这个功能在手机上完全不可达。光测「路由能渲染」抓不到
    // 这类缺口（那种用例直接 `router.go(...)`，绕过了入口），故本用例从
    // **首页的入口**出发。
    //
    // ## 为什么没有 `/quick-capture` 的对应用例
    //
    // 那条路由已删：它无任何导航调用点（≡ 菜单与桌面端的 Alt+Space / 托盘
    // 都指向 `/overlay`），且走的是无附件的同步端点——纯文本场景两者等价，
    // 保留功能更弱的那个反而误导用户。那个 quick-capture 路径常量也不存在
    // 了——重加一条死路由会先在编译期报 `undefined_getter`。
    //
    // ## 为什么这里要窄屏窗口
    //
    // `≡` 菜单只在窄屏（<720dp）渲染；默认测试窗口 800dp 走宽屏分支，
    // 快速输入是常驻图标（`group-list-quick-capture`）。本用例验的是手机的
    // 真实路径，故显式设成 375×812。
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final h = await pumpApp(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('group-list-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('menu-group-list-quick-capture')),
    );
    await tester.pumpAndSettle();

    // 到的是**带附件**那条链路（enqueue），不是无附件的 /quick-capture。
    expect(h.router.state.uri.path, SpbRoutes.overlay);
    expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('overlay-attach')), findsOneWidget);
    // 手机上没有 Enter/Shift+Enter/Esc 这些键：状态行不该出现桌面键盘说明
    // （用户会去找一个不存在的 Esc 键）。桌面端接线传 `showKeyboardHints: true`。
    expect(find.textContaining('Shift+Enter'), findsNothing);
  });

  testWidgets('对话列表新建入口：POST /chat/groups 后进入新对话', (tester) async {
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: (adapter) {
        // `data` 精确匹配请求体：同时验证「标题确实发出去了」——
        // 只断言导航会漏掉「回调拿了标题却没用」的缺陷。
        adapter.onPost(
          '/chat/groups',
          (server) => server.reply(201, {
            'id': 'g_new',
            'user_id': 'usr_REAL',
            'title': '新对话',
            'status': 'active',
            'created_at': '2024-03-05T08:00:00Z',
            'updated_at': '2024-03-05T08:09:10Z',
          }),
          data: {'title': '新对话'},
        );
        // 跳转目标对话页会发这些请求（与 StatefulShellRoute 用例同）。
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/g_new/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'g_new', 'limit': 20},
        );
      },
    );

    expect(
      find.byKey(const ValueKey('group-list-create-fab')),
      findsOneWidget,
      reason: '移动端同样需要开新对话的入口（FAB 的 ＋）',
    );

    // 新建不再需要输入标题：点一下就用默认占位标题建（见 GroupListPage 的
    // `defaultGroupTitle`）。
    await tester.tap(find.byKey(const ValueKey('group-list-create-fab')));
    await tester.pumpAndSettle();

    // 不能 pumpAndSettle：对话页的加载态是无限动画。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(
      h.router.state.matchedLocation,
      SpbRoutes.chat('g_new'),
      reason: '建完对话应当直接进入它，而不是留在列表页',
    );
  });

  testWidgets('对话页选 Agent：本地生效不发请求；「同 Agent 开新会话」才调 /sessions/switch', (
    tester,
  ) async {
    // ## 本用例验证什么（与桌面端同一取向，对齐 webapp 的 `setAgentForGroup`）
    //
    // 1. 移动端没有侧边栏，agent 选择是 AppBar 上的独立入口（与「对话设置」
    //    图标按钮并列）——router **真的注入了**列表与两个回调；
    // 2. 点选 agent 是**纯本地**动作：不产生任何 HTTP 请求；
    // 3. AppBar 标签跟着本地选择变；
    // 4. 「同 Agent 开新会话」是唯一立即调端点的入口，`agentId` 以
    //    **camelCase** 进 body，且用本地选中的 agent。
    final hit = <({String path, Object? body})>[];
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      loadAgents: () async => const [
        Agent(id: 'agent_a', name: '写作助手'),
        Agent(id: 'agent_b', name: '代码助手'),
      ],
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_m',
          (server) => server.reply(200, {
            'id': 'grp_m',
            'user_id': 'usr_REAL',
            'title': '测试对话',
            'active_session': {
              'agent_id': 'agent_a',
              'session_id': 'up_1',
              'role': 'owner',
            },
          }),
        );
        // 第二个对话（grp_n）：只为验证"切走再切回"不丢本地选择。
        adapter.onGet(
          '/chat/groups/grp_n',
          (server) => server.reply(200, {
            'id': 'grp_n',
            'user_id': 'usr_REAL',
            'title': '另一个对话',
            'active_session': {
              'agent_id': 'agent_a',
              'session_id': 'up_2',
              'role': 'owner',
            },
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_n/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_n', 'limit': 20},
        );
        adapter.onGet(
          '/chat/groups/grp_m/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_m', 'limit': 20},
        );
        adapter.onPost(
          '/chat/groups/grp_m/sessions/switch',
          (server) => server.replyCallback(200, (options) {
            hit.add((path: options.path, body: options.data));
            return {
              'group_id': 'grp_m',
              'new_agent_id': 'agent_b',
              'session_id': null,
              'status': 'active',
              'force_new_session': false,
              'switched': true,
            };
          }),
          data: Matchers.any,
        );
      },
    );

    h.router.go(SpbRoutes.chat('grp_m'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('agent-switcher')),
      findsOneWidget,
      reason: 'router 必须注入 loadAgents，否则入口会因空列表而隐藏',
    );
    // 回归防线：「对话设置」入口仍在（两个图标按钮共存，不是替换）。
    expect(find.byKey(const ValueKey('open-group-settings')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('agent-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-option-agent_b')));
    await tester.pumpAndSettle();

    expect(hit, isEmpty, reason: '选 agent 必须是纯本地动作（对齐 webapp）：不应发出任何请求');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('agent-switcher-label')))
          .data,
      '代码助手',
      reason: 'AppBar 标签必须跟着本地选择变（_effectiveAgentId 优先本地值）',
    );

    // 「清空上下文」：输入栏的独立按钮（2026-11 从 agent 菜单里搬出来，
    // 与 webapp 同位置）——先弹确认。
    await tester.tap(find.byKey(const ValueKey('composer-new-session')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('new-session-confirm')), findsOneWidget);

    // 必须包在 `runAsync` 里：回调内部会 await dio 请求，dio 的 mock 响应
    // 靠真实事件循环完成（FakeAsync 时区里 await 会死锁）。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('new-session-confirm-ok')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(hit, hasLength(1), reason: '确认后必须真的发出一次切换请求');
    expect(hit.single.path, '/chat/groups/grp_m/sessions/switch');
    final body = hit.single.body! as Map<String, dynamic>;
    expect(
      body['agentId'],
      'agent_b',
      reason:
          '⚠️ 键名必须是 camelCase 的 agentId——写成 agent_id 会 400「agentId 不能为空」；'
          '且必须用**本地选中的** agent（否则开新会话会把绑定改回旧 agent）',
    );
    expect(body.containsKey('agent_id'), isFalse);
    expect(body['force_new_session'], isTrue);

    // 「自动路由」：把本地选择清回 null。它必须**盖过** group 已有的绑定
    // （`active_session.agent_id`），否则标签写着旧 agent 而下一条消息却按
    // auto 发出去——界面在撒谎。
    await tester.tap(find.byKey(const ValueKey('agent-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('agent-option-auto')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('agent-switcher-label')))
          .data,
      '自动路由',
      reason: '显式自动路由优先于服务端绑定（AgentChoiceAuto 短路 _effectiveAgentId）',
    );

    // 切到另一个对话再切回来：选择存在应用级 store 里（键是 groupId），不得
    // 回落到服务端绑定 agent_a（旧实现把选择放页面 State，`didUpdateWidget`
    // 一换对话就清 → 回来显示"写作助手"，且下一条消息按 manual + agent_a 发出）。
    h.router.go(SpbRoutes.chat('grp_n'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    h.router.go(SpbRoutes.chat('grp_m'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('agent-switcher-label')))
          .data,
      '自动路由',
      reason: '重进对话后「自动」必须还在（选择与应用级 store 对齐 webapp 的 agentByGroup）',
    );
  });

  testWidgets('对话页交付物入口：AppBar 按钮打开弹层并按 path_prefix 拉本对话清单', (tester) async {
    // ## 本用例验证什么
    //
    // 移动端没有侧边栏，「按对话浏览交付物」是 AppBar 上的独立入口。
    // `GroupDeliverablesPanel` 自身行为由 spb_features 的测试覆盖，但那个
    // 测试用**手工构造的取数闭包**，发现不了「router 忘了注入」——而那正是
    // 本仓库最常见的失败模式（功能实现了但没人调用）。
    //
    // 这里还额外锁住两件事：
    // 1. 取数必须带本 group 的 `path_prefix`（写成全局拉取会让手机上白耗流量）；
    // 2. **不注入** `onOpen`/`onReveal`：移动端 `openFile`/`revealPath` 恒为
    //    false，接了会让用户点「打开」得到「无法打开文件」。面板在回调为
    //    null 时不渲染该菜单项，故断「菜单里没有「打开」」。
    final ufs = FakeUfsApi()
      ..entries = [
        ufsFile('grp_m', 'reports/a.md'),
        ufsFile('grp_m', 'notes/b.txt'),
      ];
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      ufsApi: ufs,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_m',
          (server) => server.reply(200, {
            'id': 'grp_m',
            'user_id': 'usr_REAL',
            'title': '测试对话',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_m/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_m', 'limit': 20},
        );
      },
    );

    h.router.go(SpbRoutes.chat('grp_m'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('open-group-deliverables')),
      findsOneWidget,
      reason: 'router 必须注入交付物入口，否则手机上无法按对话看产出',
    );

    await tester.tap(find.byKey(const ValueKey('open-group-deliverables')));
    await tester.pumpAndSettle();

    // 取数必须限定在本 group 的 workspace 子树。
    expect(ufs.listCalls, isNotEmpty, reason: '打开弹层必须真的取数');
    expect(
      ufs.listCalls,
      everyElement('/workspace/groups/grp_m'),
      reason: 'path_prefix 必须带 groupId，否则会把整个 workspace 拉下来',
    );

    // 清单内容渲染（含子目录文件名）。
    expect(find.text('a.md'), findsWidgets);
    expect(find.text('b.txt'), findsWidgets);

    // 下载入口在（移动端唯一可用的文件动作）。
    expect(
      find.byKey(const ValueKey('agent-file-download')),
      findsNothing,
      reason: '那是时间线内联卡的 key，侧边栏面板用行尾菜单',
    );
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsOneWidget);
    expect(
      find.text('打开'),
      findsNothing,
      reason: '移动端 openFile 恒为 false，不得提供「打开」入口',
    );
    expect(find.text('定位'), findsNothing, reason: '移动端 revealPath 恒为 false');
  });

  testWidgets('对话页待办入口：聚合未解决确认卡并提交动作词（非状态词）', (tester) async {
    // ## 本用例验证什么
    //
    // 移动端没有侧边栏，「现在有什么在等我」靠 AppBar 的待办入口。
    // `GroupTodosPanel` 自身行为由 spb_features 覆盖，但那个测试用**手工
    // 构造的 turns**，发现不了「router 忘了把归约结果接上」——而那正是本仓库
    // 最常见的失败模式。
    //
    // 这里还锁住两条极易错的契约：
    // 1. `confirmationId` 必须取自 payload 的 `confirmation_id`，**不是**
    //    `eventId`（两者由服务端独立生成；用 eventId 去 resolve 会 404，
    //    且**无任何报错**）；
    // 2. body 里的 `action` 必须是**动作词**（`approve`/`reject`），写成
    //    `resolved` 这类状态词会被服务端拒绝。
    final hit = <({String path, Object? body})>[];
    final sse = FakeSseClient();
    final h = await pumpApp(
      tester,
      sseClient: sse,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t',
          (server) => server.reply(200, {
            'id': 'grp_t',
            'user_id': 'usr_REAL',
            'title': '待办测试',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_t', 'limit': 20},
        );
        adapter.onPost(
          '/api/chat/groups/grp_t/confirmations/conf_row_1/resolve',
          (server) => server.replyCallback(200, (options) {
            hit.add((path: options.path, body: options.data));
            return {'ok': true};
          }),
          data: Matchers.any,
        );
      },
    );

    h.router.go(SpbRoutes.chat('grp_t'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    // 推一帧 confirmation_required。
    //
    // ⚠️ payload 的 `confirmation_id` 与帧的 `eventId` **刻意不同**：实现若
    // 误用 eventId 当卡行 id，下面的 POST 路径断言会失败（真实环境则是静默
    // 404）。`eventId` 为 `evt_1`，卡行 id 为 `conf_row_1`。
    sse.push('confirmation_required', {
      'eventId': 'evt_1',
      'eventType': 'confirmation_required',
      'groupId': 'grp_t',
      'turnId': 'turn_1',
      'userId': 'usr_REAL',
      'seq': 1,
      'createdAt': '2026-01-01T00:00:00Z',
      // ⚠️ `text` 必须放在 **payload 里**：归约器读的是 `ev.text`，而它取的是
      // payload 的字段（不是帧顶层）。真实服务端 `BuildConfirmationRequiredPayload`
      // 只给 confirmation_id 与 recommendation，故线上问题文案常是兜底的
      // 「需要确认」——这里给一个独特字符串，用来证明面板渲染的确实是本帧。
      'payload': {
        'confirmation_id': 'conf_row_1',
        'text': '要删除这三个文件吗？',
        // 选项文案用「继续/取消」：`_optionToAction` 正是把它们映射成
        // approve/reject。用「批准/拒绝」会走 `_ => option` 直通分支，
        // 就测不到这层映射了。
        'options': ['继续', '取消'],
      },
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('open-group-todos')),
      findsOneWidget,
      reason: 'router 必须注入待办入口，否则手机上无法跨轮次看到待确认',
    );

    await tester.tap(find.byKey(const ValueKey('open-group-todos')));
    await tester.pumpAndSettle();

    // 问题文案出现在聚合面板里（说明归约结果真的接上了）。
    expect(find.text('要删除这三个文件吗？'), findsWidgets, reason: '待办面板必须渲染归约出的确认卡问题');

    // 点「继续」→ 断言打到正确端点且 action 是动作词。
    //
    // ⚠️ 必须**限定在弹层那张卡内**：同一张确认卡在时间线里也有一份内联渲染，
    // 而弹层是模态的（barrier 盖住时间线）。直接 `find.byKey(...).first` 会命中
    // 时间线里那份，点击落到 barrier 上——请求不会发出，用例会以一个与实现
    // 无关的理由失败。
    final optFinder = find.descendant(
      of: find.byKey(const ValueKey('todo-conf-conf_row_1')),
      matching: find.byKey(const ValueKey('confirmation-option-继续')),
    );
    // ⚠️ `tap` 本身必须在 `runAsync` 内（同本文件「切 agent」用例）：dio 的
    // mock 响应靠**真实**事件循环完成。在 FakeAsync 时区里点击，请求会发出
    // 但响应永不结算——表现为「断言 hit 为空」而看不出原因。
    await tester.runAsync(() async {
      await tester.tap(optFinder);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(hit, hasLength(1), reason: '必须真的发出一次 resolve 请求');
    expect(
      hit.single.path,
      '/api/chat/groups/grp_t/confirmations/conf_row_1/resolve',
      reason: 'confirmation_id 必须取自 payload，不能用 eventId（evt_1）',
    );
    final body = hit.single.body! as Map<String, dynamic>;
    expect(
      body['action'],
      'approve',
      reason: '⚠️ action 必须是动作词；写成 resolved 这类状态词会被服务端拒绝',
    );
    expect(body['action'], isNot('resolved'));

    // ## 弹层必须跟着状态变（本次修的缺陷）
    //
    // 待办弹层是 `showModalBottomSheet`（**独立 route**），它的 builder 闭包只在
    // 打开时跑一次、捕获那一刻的 `_items`。修复前：卡被解决后页面 `setState` 只
    // 重建页面，弹层纹丝不动——卡还在、按钮还能点，而服务端已经拒了第二次请求。
    expect(
      find.byKey(const ValueKey('todo-conf-conf_row_1')),
      findsOneWidget,
      reason: '前置：弹层里确实渲染了这张卡',
    );
    sse.push('confirmation_resolved', {
      'eventId': 'evt_2',
      'eventType': 'confirmation_resolved',
      'groupId': 'grp_t',
      'turnId': 'turn_1',
      'userId': 'usr_REAL',
      'seq': 2,
      'createdAt': '2026-01-01T00:00:01Z',
      'payload': <String, dynamic>{},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('todo-conf-conf_row_1')),
      findsNothing,
      reason: '卡已解决：打开着的待办弹层必须立刻不再列它（修复前停在旧快照上）',
    );
  });

  testWidgets('待办弹层：groupsync 开启但本对话无挂起文件时仍显示空态占位', (tester) async {
    // ## 本用例防的是什么
    //
    // `WorkspaceSyncTodoSection` 在「无待确认项」时自己渲染 `SizedBox.shrink()`，
    // 而 `GroupTodosPanel` 只看「注入了没有」来决定要不要渲染「没有待处理的确认」
    // 占位。装配层若无条件注入，groupsync 正常开启而本对话没有挂起文件时（最
    // 常见状态），弹层会整块空白——手机用户会以为入口坏了。
    //
    // 桌面端同一路径由 `group_sync_wiring_test.dart` 钉住，两端各测一次是因为
    // 装配代码是两份（§6.17）。
    final sse = FakeSseClient();
    final h = await pumpApp(
      tester,
      sseClient: sse,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t',
          (server) => server.reply(200, {
            'id': 'grp_t',
            'user_id': 'usr_REAL',
            'title': '待办测试',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_t', 'limit': 20},
        );
        // worker 在跑（enabled: true），但没有任何挂起文件。
        adapter.onGet(
          '/chat/groups/grp_t/workspace-sync/reviews',
          (server) => server.reply(200, {
            'enabled': true,
            'items': <Map<String, dynamic>>[],
          }),
        );
      },
    );

    h.router.go(SpbRoutes.chat('grp_t'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-group-todos')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('todos-empty')),
      findsOneWidget,
      reason: '没有确认卡也没有挂起文件时必须给空态提示，而不是空白弹层',
    );
    expect(find.byKey(const ValueKey('sync-todo-section')), findsNothing);
  });

  testWidgets('待办弹层开着时收到 todo.changed → 弹层立刻出现新的工作区待处理项', (tester) async {
    // ## 本用例防的是什么
    //
    // 待确认同步项由 provider 驱动（15 秒轮询 + `todo.changed`），**不经过**
    // 时间线事件。而待办弹层是独立 route：页面 `setState` 到不了它，只能靠
    // `_todosTick` 哨兵重建。此前哨兵只在时间线事件里转，于是「弹层开着时又挂起
    // 一个文件」要等用户手动关掉重开才看得到（桌面端没这问题——侧边栏在页面树里）。
    final sse = FakeSseClient();
    // 真源只有 GET：事件只是失效通知，列表内容以这一份桩为准。
    var items = <Map<String, dynamic>>[];
    final h = await pumpApp(
      tester,
      sseClient: sse,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t',
          (server) => server.reply(200, {
            'id': 'grp_t',
            'user_id': 'usr_REAL',
            'title': '待办测试',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_t/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_t', 'limit': 20},
        );
        adapter.onGet(
          '/chat/groups/grp_t/workspace-sync/reviews',
          (server) => server.replyCallback(
            200,
            (_) => {'enabled': true, 'items': items},
          ),
        );
      },
    );

    h.router.go(SpbRoutes.chat('grp_t'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-group-todos')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sync-todo-section')),
      findsNothing,
      reason: '前置：此刻还没有挂起文件',
    );

    // 服务端新挂起一个目录，并发一条失效通知（事件只带 group_id + op）。
    items = [
      {
        'id': 'dir:grp_t:reports',
        'path': 'reports',
        'directory': true,
        'reason': 'too_many_files',
        'file_count': 620,
        'total_bytes': 12 * 1048576,
        'samples': <String>['a.md'],
        'revision': 'rev1',
      },
    ];
    sse.push('todo.changed', {
      'eventId': 'evt_todo_1',
      'eventType': 'todo.changed',
      'transient': true,
      'userId': 'usr_REAL',
      'seq': 3,
      'createdAt': '2026-01-01T00:00:02Z',
      'payload': {'group_id': 'grp_t', 'op': 'created'},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('sync-todo-section')),
      findsOneWidget,
      reason: '弹层开着时收到失效通知就必须重拉并刷新（重建前靠哨兵转一次）',
    );
    expect(find.text('reports'), findsOneWidget);

    // `3+1` 是非加法：手机上只能长按看解释，故 tooltip 必须是解释文案而不是
    // 干巴巴的「待办」。
    final todoButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('open-group-todos')),
    );
    expect(
      todoButton.tooltip,
      contains('1 项工作区待处理'),
      reason: '有徽标时 tooltip 要讲清「这 1 项不阻塞对话」，否则 3+1 是谜语',
    );
  });

  testWidgets('对话内处理确认后返回列表重新读取角标', (tester) async {
    // 只有列表需要这份计数；对话内处理确认不发列表查询，返回时加载新快照。
    var confirmationRequests = 0;
    final sse = FakeSseClient();
    // 从首页（对话列表 tab）起步再导航进对话页：角标 provider 的读取点是
    // `_ConversationsTab`。
    //
    // ⚠️ 导航进 chat 后该 tab **会卸载**——`StatefulShellRoute.indexedStack`
    // 保活的是**分支**，而分支内部的 Navigator 仍然换页。故与桌面端同型：
    // invalidate 把 provider 标脏，重算推迟到用户回到列表页时。
    final h = await pumpApp(
      tester,
      sseClient: sse,
      mockPendingConfirmations: false,
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_c',
          (server) => server.reply(200, {
            'id': 'grp_c',
            'user_id': 'usr_REAL',
            'title': '角标测试',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_c/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_c', 'limit': 20},
        );
        // 计数版：覆盖 pumpApp 注册的默认 mock（后者覆盖前者）。
        adapter.onGet(
          '/chat/confirmations',
          (server) => server.replyCallback(200, (_) {
            confirmationRequests++;
            return {'items': <Map<String, dynamic>>[]};
          }),
          queryParameters: {'status': 'pending', 'limit': 50},
        );
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(confirmationRequests, 1, reason: '首页挂载时角标 provider 已拉过一次');

    h.router.go(SpbRoutes.chat('grp_c'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(
      confirmationRequests,
      1,
      reason: '进入对话页本身不该再拉一次（首次同步建基线时故意不 invalidate）',
    );

    sse.push('confirmation_required', {
      'eventId': 'evt_c1',
      'eventType': 'confirmation_required',
      'groupId': 'grp_c',
      'turnId': 'turn_c1',
      'userId': 'usr_REAL',
      'seq': 1,
      'createdAt': '2026-01-01T00:00:00Z',
      'payload': {
        'confirmation_id': 'conf_row_c1',
        'options': ['继续', '取消'],
      },
    });

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    // 对话页里没有角标的读取点，重算推迟到回到列表页（见上方注释）。
    expect(confirmationRequests, 1, reason: '对话页里没有角标的读取点，重算推迟到回到列表页时');

    // 回到对话列表 tab：角标被重新读取，provider 因已标脏而重拉。
    h.router.go(SpbRoutes.conversations);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(minutes: 6));
    await tester.pump(const Duration(seconds: 2));

    expect(
      confirmationRequests,
      2,
      reason:
          '确认卡事件到达后，回到列表页必须看到**已更新**的角标（即重拉了一次）。'
          '此前 invalidate 的是 count provider：它重建后读到的仍是被缓存的'
          'pendingConfirmationsProvider，于是这里仍是 1 —— 这条断言正是那个'
          '缺陷的回归防线',
    );
  });

  testWidgets('push 进设置再返回：回到来源页（对话栈不被重建）', (tester) async {
    // 扁平化之后没有分支栈，等价语义由 `push` 提供：设置压在当前页之上，
    // 返回即回到**进入设置的那一页**（这里是某个对话），而不是列表。
    //
    // 必须注入假 SseClient：进入对话页会建 SSE 长连接，真实现会按指数退避
    // 安排重连定时器，测试结束时留下 pending Timer 直接报错。
    //
    // 同时必须 mock `/api/auth/me` 与 timeline：对话页要先解析出真实 userId
    // 才构造控制器（issue #2 的修复使「userId 未就绪」不再降级为空串，而是
    // 停留在加载态），mock 必须在首帧前注册，故用 beforePump。
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: (adapter) {
        adapter.onGet(
          '/api/auth/me',
          (server) => server.reply(200, {
            'id': 'usr_REAL',
            'email': 'a@b.c',
            'name': 'Test',
            'role': 'member',
            'roles': ['member'],
            'permissions': <String>[],
            'status': 'active',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_x',
          (server) => server.reply(200, {
            'id': 'grp_x',
            'user_id': 'usr_REAL',
            'title': '分支恢复用对话',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_x/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_x', 'limit': 20},
        );
      },
    );

    // 进入「对话」分支下的子路由。
    h.router.go(SpbRoutes.chat('grp_x'));
    await tester.pumpAndSettle();

    // 对话页 AppBar 显示的是**对话名**，不是固定的「对话」——否则与列表页
    // 同名，用户看不出自己是否真的进了某个对话（见 `_appBarTitle`）。
    expect(find.text('分支恢复用对话'), findsOneWidget);

    // `push` 进设置（与列表页 `onOpenSettings` 的接线一致）。
    // 不 `await`：它的 Future 在设置页 pop 时才完成，await 会挂住用例。
    unawaited(h.router.push(SpbRoutes.settings));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
    expect(find.text('分支恢复用对话'), findsNothing, reason: '设置是整屏页，遮住下层');

    // 返回：应回到那个对话（ConversationPage），而非列表。
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(h.router.state.matchedLocation, SpbRoutes.chat('grp_x'));
    expect(find.text('还没有对话，输入消息开始吧'), findsOneWidget);
  });

  /// 窄屏的设置入口在 `≡` 菜单（不是底部标签栏，也不是常驻图标）。
  ///
  /// ## 本用例防的是什么
  ///
  /// 去掉底部标签栏之后，设置的唯一入口就是列表 AppBar 的分档入口：
  /// 窄屏进菜单（`menu-group-list-settings`）、宽屏常驻
  /// （`group-list-settings`）。两件事一起钉住——入口可达 + 窄屏不挤占图标位
  /// （§6.88.3 实测 320dp 时标题宽度已经是 0）。
  testWidgets('窄屏设置入口在 ≡ 菜单（AppBar 常驻位留给对话相关动作）', (tester) async {
    // 设置页是长 ListView，窗口要够高才能命中底部区块。
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final h = await pumpApp(tester);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('group-list-settings')),
      findsNothing,
      reason: '窄屏 AppBar 只留新建/待确认/搜索，设置收进 ≡ 菜单',
    );

    await tester.tap(find.byKey(const ValueKey('group-list-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-group-list-settings')));
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.settings);
    expect(find.byKey(const ValueKey('settings-tabs')), findsOneWidget);
  });
}
