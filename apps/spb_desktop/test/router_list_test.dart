import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/app.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 对话列表 / 搜索 / 待确认角标 / 对话内搜索入口（router 装配）
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/desktop_harness.dart`。
void main() {
  testWidgets('首页渲染对话列表（用 mock 数据，无真实网络）', (tester) async {
    final dio = createDio(baseUrl: 'https://api.test/pba');
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {
        'items': [
          {
            'id': 'g1',
            'user_id': 'usr_1',
            'title': '测试对话',
            'status': 'active',
            'created_at': '2024-03-05T08:00:00Z',
            'updated_at': '2024-03-05T08:09:10Z',
          },
        ],
      }),
      queryParameters: {'limit': 30, 'offset': 0},
    );
    // 待确认角标 provider 首帧即拉取。
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
      routes: buildDesktopRoutes(),
      redirect: buildAuthRedirect(),
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        desktopCapabilitiesProvider.overrideWithValue(
          const NoopDesktopCapabilities(),
        ),
        dioProvider.overrideWithValue(dio),
        // 注入已登录凭证，否则守卫会把首页重定向到 /login。
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
        child: SpbDesktopApp(router: router),
      ),
    );
    // 推进假时钟让 dio mock 的 Timer 触发。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('测试对话'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
  });

  testWidgets('对话列表有搜索入口，点击进入 /search', (tester) async {
    final h = await pumpApp(tester);

    expect(
      find.byKey(const ValueKey('group-list-search')),
      findsOneWidget,
      reason: '搜索是对话列表的常规能力，没有入口等于没实现',
    );

    await tester.tap(find.byKey(const ValueKey('group-list-search')));
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.search);
    expect(find.byKey(const ValueKey('search-field')), findsOneWidget);
  });

  testWidgets('搜索页点击命中项跳到该消息所属对话', (tester) async {
    final h = await pumpApp(
      tester,
      mockGroups: false,
      // 跳转目标对话页会建 SSE。不注入假实现的话，真实 SseClient 在 mock
      // 地址上连不上会**排一个重连 Timer**，测试结束时留下未结算的 Timer 报
      // 「A Timer is still pending even after the widget tree was disposed」
      // （见本文件里 issue #2 用例的同一处说明）。
      sseClient: FakeSseClient(),
      beforePump: (adapter) {
        // 跳转目标对话页会发 /api/auth/me 与 timeline（与 issue #2 用例同）。
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
          '/chat/groups/grp_42/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_42', 'limit': 20},
        );
      },
      searchChat: (query, {int? limit}) async => [
        ChatSearchHit.fromJson({
          'turn_id': 't1',
          'group_id': 'grp_42',
          'group_title': '报错排查',
          'input_text': '帮我看一下这个报错',
          'created_at': '2024-03-05T08:09:10Z',
          'agent_id': 'agt_1',
        }),
      ],
    );

    h.router.go(SpbRoutes.search);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('search-field')), '报错');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('报错排查'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-hit-t1')));

    // ⚠️ 不能 pumpAndSettle：跳转目标是对话页，它挂载后进入加载态，而
    // CircularProgressIndicator 是**无限动画**——pumpAndSettle 会一直等到超时
    // （见本文件里 issue #2 用例的同一处说明）。用显式 pump 推进假时钟。
    //
    // 多 pump 几轮：对话页挂载后由 postFrameCallback 依次发出
    // `/api/auth/me`、timeline、`messages/pending`，每个请求的 mock 响应都在
    // 一个 Timer 里 resolve。只 pump 一轮会让后发出的请求留下未结算的 Timer
    // （报「A Timer is still pending even after the widget tree was disposed」）。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(
      h.router.state.matchedLocation,
      SpbRoutes.chat('grp_42'),
      reason: '搜索的用途是「找到那句话然后回到它的上下文」',
    );
  });

  testWidgets('收到确认卡事件后待确认角标自动重拉（不是等用户打开待确认页）', (tester) async {
    // ## 这个用例防的是什么
    //
    // 对话列表页的角标读 `pendingConfirmationCountProvider`，它派生自
    // `pendingConfirmationsProvider`。此前对话页在 items 变化时调的是
    // `ref.invalidate(pendingConfirmationCountProvider)`——**失效的**：count
    // 重建后读到的仍是被缓存的被依赖者，角标纹丝不动。
    //
    // 故本用例的观测点是**网络请求次数**：SSE 推来一帧确认卡后，
    // `/chat/confirmations` 必须被**重新请求**一次。只断言「角标数字变了」
    // 抓不到这个缺陷——数字可能因为其它 provider 重算而恰好正确。
    var confirmationRequests = 0;
    final sse = FakeSseClient();
    // ⚠️ 必须**从首页起步**再导航进对话页，不能直接深链到 /chat/grp_c。
    //
    // 角标 provider 的**唯一读取点**是首页（`_HomePage` 里的 `ref.watch`）。
    // 直接深链时首页从不挂载 → 无人读它 → 它从未初始化 → 首次请求根本不发
    // 生，「推一帧后重新请求」也就无从观测。这也正是本缺陷在生产里的暴露
    // 条件：用户**先进列表页看到角标**，再点进某个对话，此时收到确认卡事件
    // 角标才该变。
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

    // 进对话页（provider 是常驻的，不会被 dispose）。
    h.router.go(SpbRoutes.chat('grp_c'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));

    expect(
      confirmationRequests,
      1,
      reason: '进入对话页本身不该再拉一次（首次同步建基线时故意不 invalidate）',
    );

    // 推一帧 confirmation_required。
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

    // 归约 → items 流 → invalidate。每步都要一轮 pump 让微任务与 mock 响应的
    // Timer 结算。
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    // ## 为什么此时请求数仍是 1（而不是 2）
    //
    // 角标 provider 的唯一读取点是**首页**，而用户此刻在对话页——首页已卸载，
    // 无人监听。invalidate 把 provider 标脏，但重算要等到有人再读它。
    // 这不是缺陷，是 Riverpod 的正常语义；下面的「回到首页」才是观测点。
    expect(confirmationRequests, 1, reason: '对话页里没有角标的读取点，重算推迟到回到列表页时');

    // 回到列表页：角标被重新读取，provider 因已标脏而重拉。
    h.router.go(SpbRoutes.home);
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

    // 收尾：避免 SSE 相关的 pending timer。
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('对话列表新建入口：POST /chat/groups 后进入新对话', (tester) async {
    final h = await pumpApp(
      tester,
      sseClient: FakeSseClient(),
      beforePump: (adapter) {
        // 用 `data` 精确匹配请求体：这样能同时验证「标题确实发出去了」
        // ——只断言导航会漏掉「回调拿了标题却没用」的缺陷。
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
        // 跳转目标对话页会发这些请求（与「搜索跳转」用例同）。
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

    // 新建不再需要输入标题：点一下就用默认占位标题建（见 GroupListPage 的
    // `defaultGroupTitle`）。
    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();

    // 不能 pumpAndSettle：对话页的加载态是无限动画（同搜索跳转用例）。
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

  /// 对话页 AppBar 必须提供「在本对话中搜索」入口（对话内搜索 / issue #31）。
  ///
  /// ## 这个用例防的是什么
  ///
  /// `ConversationPage.enableSearch` 默认为 `false`（移动端 AppBar 无余量，
  /// 见 issue #31）。若某一端的 router 忘了显式打开，**页面测试不会失败**
  /// （它们自己传参），而用户界面上那个入口会静默消失——「功能实现了但没接线」
  /// 是这类开关型参数最容易出的错。
  ///
  /// 故这里从 **router** 层断言：真实装配出来的对话页上有那个图标。
  testWidgets('对话页 AppBar 提供对话内搜索入口（router 显式打开 enableSearch）', (tester) async {
    final h = await pumpApp(tester);
    h.router.go(SpbRoutes.chat('grp_search_wire'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byKey(const ValueKey('conversation-search-open')),
      findsOneWidget,
      reason:
          '桌面端 AppBar 有宽屏余量，必须直接摆出搜索图标'
          '（移动端才收进溢出菜单）',
    );

    // 点开确认它真的打开面板（而不是只渲染了一个图标）。
    await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conversation-search-field')),
      findsOneWidget,
    );
  });

  /// 桌面端 `/settings` 此前**没有任何 UI 入口**——
  /// 托盘只有「同步设置…」（直达 `/settings/sync`），列表 AppBar 没有设置
  /// 图标，而 `WindowRole.settings → /settings` 的映射在生产代码里无调用方。
  /// 于是同步目录 / 范围 / 过滤 / 外观 / 个人偏好 / 导出诊断日志全不可达。
  ///
  /// ## 为什么从 router 层断言
  ///
  /// 与上一用例同型：`GroupListPage` 的页面测试自己传 `onOpenSettings`，
  /// 接不接线它不管。只有真实装配出的列表页上那个图标才能钉住接线。
  testWidgets('对话列表 AppBar 提供全局设置入口，点击进入 /settings', (tester) async {
    final h = await pumpApp(tester);

    expect(
      find.byKey(const ValueKey('group-list-settings')),
      findsOneWidget,
      reason: '没有这个入口，设置页在界面上就是不可达的',
    );

    await tester.tap(find.byKey(const ValueKey('group-list-settings')));
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.settings);
    // 真进了设置页（而不是只改了路径）。
    expect(find.byKey(const ValueKey('settings-scope-all')), findsOneWidget);
  });
}
