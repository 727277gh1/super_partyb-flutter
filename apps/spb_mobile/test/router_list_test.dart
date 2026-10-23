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
  testWidgets('首页渲染对话列表 + 底部标签栏', (tester) async {
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
    // 底部标签栏的两个标签。
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('对话'), findsWidgets);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('对话列表的 FAB 进入 /overlay（无归属入口在移动端可达）', (tester) async {
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
    // 那条路由已删：它无任何导航调用点（本 FAB 与桌面端的 Alt+Space / 托盘
    // 都指向 `/overlay`），且走的是无附件的同步端点——纯文本场景两者等价，
    // 保留功能更弱的那个反而误导用户。那个 quick-capture 路径常量也不存在
    // 了——重加一条死路由会先在编译期报 `undefined_getter`。
    final h = await pumpApp(tester);
    await tester.pumpAndSettle();

    final fab = find.byKey(const ValueKey('group-list-quick-capture'));
    expect(fab, findsOneWidget, reason: '移动端必须有进入无归属入口的入口');

    await tester.tap(fab);
    await tester.pumpAndSettle();

    // 到的是**带附件**那条链路（enqueue），不是无附件的 /quick-capture。
    expect(h.router.state.uri.path, SpbRoutes.overlay);
    expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('overlay-attach')), findsOneWidget);
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
      find.byKey(const ValueKey('group-list-create')),
      findsOneWidget,
      reason: '移动端同样需要开新对话的入口',
    );

    // 新建不再需要输入标题：点一下就用默认占位标题建（见 GroupListPage 的
    // `defaultGroupTitle`）。
    await tester.tap(find.byKey(const ValueKey('group-list-create')));
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

  testWidgets(
    '对话页 Agent 切换：AppBar 入口接到 POST /chat/groups/:id/sessions/switch',
    (tester) async {
      // ## 本用例验证什么
      //
      // 移动端没有侧边栏，agent 切换是 AppBar 上的独立入口（与「对话设置」
      // 图标按钮并列）。这里验证 router **真的注入了**列表与回调，且回调打到
      // 正确端点、`agentId` 以 **camelCase** 进 body。
      //
      // `AgentSwitcher` 自身行为由 `spb_features` 的测试覆盖；但那个测试用
      // 手工构造的回调，发现不了「router 忘了注入」——而那正是本仓库最常见的
      // 失败模式（功能实现了但没人调用）。
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

      // 必须包在 `runAsync` 里：回调内部会 await dio 请求，dio 的 mock 响应
      // 靠真实事件循环完成（FakeAsync 时区里 await 会死锁）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('agent-switch-confirm-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(hit, hasLength(1), reason: '必须真的发出一次切换请求');
      expect(hit.single.path, '/chat/groups/grp_m/sessions/switch');
      final body = hit.single.body! as Map<String, dynamic>;
      expect(
        body['agentId'],
        'agent_b',
        reason: '⚠️ 键名必须是 camelCase 的 agentId——写成 agent_id 会 400「agentId 不能为空」',
      );
      expect(body.containsKey('agent_id'), isFalse);
    },
  );

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
  });

  testWidgets('收到确认卡事件后待确认角标自动重拉（不是等用户打开待确认页）', (tester) async {
    // ## 这个用例防的是什么
    //
    // 对话列表页的角标读 `pendingConfirmationCountProvider`，它派生自
    // `pendingConfirmationsProvider`。此前对话页在 items 变化时调的是
    // `ref.invalidate(pendingConfirmationCountProvider)`——**失效的**：count
    // 重建后读到的仍是被缓存的被依赖者，角标纹丝不动。
    //
    // 故观测点是**网络请求次数**：SSE 推来一帧确认卡后，
    // `/chat/confirmations` 必须被重新请求一次。只断言「角标数字变了」抓不到
    // 这个缺陷——数字可能因为其它 provider 重算而恰好正确。
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

  testWidgets('StatefulShellRoute：切标签后返回，保留分支导航栈', (tester) async {
    // 这是用 shell route 的理由：在「对话」分支里进入某对话后切到「设置」，
    // 再切回「对话」应回到那个对话而非列表。
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

    // 切到「设置」。
    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sync-entry')), findsOneWidget);

    // 用 goBranch 切回「对话」分支（模拟点底部标签）。
    final shell = tester.widget<NavigationBar>(find.byType(NavigationBar));
    shell.onDestinationSelected?.call(0);
    await tester.pumpAndSettle();

    // 分支恢复：应回到 chat 路由（ConversationPage），而非列表。
    // 故用「时间线的空提示」区分二者。
    expect(find.text('还没有对话，输入消息开始吧'), findsOneWidget);
  });

  /// 移动端的全局设置入口是**底部标签栏**，不是列表 AppBar 图标。
  ///
  /// ## 本用例防的是什么
  ///
  /// `GroupListPage.onOpenSettings` 只在桌面端接线（移动端设置已是一级目的地，
  /// 见 `check_wiring_parity.sh` 的 exempt）。若将来有人「为了对称」把它也
  /// 接到移动端，窄屏 AppBar 会多一个图标——而那里已经有 5 个常驻项
  /// （§6.16 的溢出教训）。故这里同时钉住两件事：标签可达 + AppBar 无重复图标。
  testWidgets('全局设置入口在底部标签栏（AppBar 不重复放图标）', (tester) async {
    final h = await pumpApp(tester);

    final shell = tester.widget<NavigationBar>(find.byType(NavigationBar));
    shell.onDestinationSelected?.call(1);
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.settings);
    expect(find.byKey(const ValueKey('settings-sync-entry')), findsOneWidget);

    // 回到对话标签，确认列表 AppBar 没有第二个设置入口。
    shell.onDestinationSelected?.call(0);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('group-list-settings')),
      findsNothing,
      reason: '移动端设置是一级 tab，AppBar 再放一个就是同一目标的第二个入口',
    );
  });
}
