import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import 'package:spb_desktop/auth_loopback.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 对话页 / 登录重定向 / SSE 建连 / 停止生成 / 反馈 / Agent 切换
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/desktop_harness.dart`。
void main() {
  testWidgets('/overlay 可导航且渲染带附件的悬浮输入窗', (tester) async {
    // 该页面提交才发请求，打开时不产生网络流量（无需 mock 任何端点）。
    //
    // ## 为什么没有 `/quick-capture` 的对应用例
    //
    // 那条路由已删：它无任何导航调用点（`Alt+Space` 与托盘都指向本路由），
    // 且走的是无附件的同步端点。那个 quick-capture 路径常量也不存在了
    // ——重加一条死路由会先在编译期报 `undefined_getter`。
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.overlay);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('overlay-attach')), findsOneWidget);
    expect(find.text('Enter 提交 · Shift+Enter 换行 · Esc 清空'), findsOneWidget);
  });
  group('未认证重定向（登录页 + /login 路由）', () {
    testWidgets('未认证访问 / 被重定向到 /login', (tester) async {
      // 回归防线：路由守卫必须真的生效。若守卫没接上，未登录用户会看到
      // 首页，然后在里面报一堆 401——比直接给登录页差得多。
      final h = await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
      expect(find.text('使用 SSO 登录'), findsOneWidget);
    });

    testWidgets('未认证深链 /chat/grp_1 也被重定向到 /login', (tester) async {
      // 深链是容易被漏掉的入口：用户从通知/书签直接进来，若守卫只拦首页，
      // 这条路径就会绕过认证。
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_1'),
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
    });

    testWidgets('重定向时带上原目标路径（from 参数，登录后可回跳）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(
        h.router.state.uri.queryParameters['from'],
        SpbRoutes.settings,
        reason: '登录后应能回到用户原本想去的页面',
      );
    });

    testWidgets('已认证时访问 /login 被送回首页', (tester) async {
      // 否则已登录用户点开一个旧的登录链接会停在登录页，看起来像「被登出了」。
      final h = await pumpApp(tester, initialLocation: SpbRoutes.login);

      expect(h.router.state.matchedLocation, SpbRoutes.home);
      expect(find.byKey(const ValueKey('login-sso-button')), findsNothing);
    });

    testWidgets('登录页点击 SSO 按钮调用注入的 signInAction', (tester) async {
      var calls = 0;
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
        signInAction: () async {
          calls++;
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('signInAction 返回错误时登录页显示该错误', (tester) async {
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
        signInAction: () async => 'OIDC client_id 未配置',
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.text('OIDC client_id 未配置'), findsOneWidget);
    });

    testWidgets('点 SSO 完成登录后离开登录页（signIn 不得把已登录状态盖回 unknown）', (tester) async {
      // 回归防线（真实缺陷：登录成功却仍停在登录页）。
      //
      // ## 缺陷成因
      //
      // 桌面端 `signInAction` 是**同步等到 token** 的（loopback 流程）：它在
      // 内部落盘凭证并调 `signedIn()`，此时状态已是 `authenticated`。而
      // `AuthStateNotifier.signIn` 收尾时**无条件**写
      // `state = AuthState(status: unknown)`——那是给「只发起、等回调」的
      // 旧实现（`openGatewaySignIn`）留的分支。于是刚拿到的 authenticated 被
      // 盖回 unknown，守卫在 unknown 时放行、不重定向，用户**永远停在
      // /login**（界面还显示「已发起，等待浏览器回调」）。
      //
      // 既有用例抓不到它：`登录页点击 SSO 按钮调用注入的 signInAction` 只断言
      // 动作被调用一次；`登录成功后守卫放行首页` 绕过了 `signIn()` 直接调
      // `signedIn()`。故两条都绿而缺陷在。
      final store = InMemoryTokenStore();
      late TestHarness h;
      h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.login,
        tokenStore: store,
        mockGroups: false,
        signInAction: () async {
          // 与真实 `loopbackSignIn` 收尾完全一致：先落盘，再推进状态。
          await store.write(freshTokens());
          h.container.read(authStateProvider.notifier).signedIn();
          return null;
        },
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: 'signIn 收尾不得把已登录状态盖回 unknown',
      );
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.home,
        reason: '登录完成后守卫应把用户送离 /login',
      );
      expect(find.byKey(const ValueKey('login-sso-button')), findsNothing);
    });

    testWidgets('loopback 登录落盘的 Bearer 是 id_token 而不是 ory_at_ 不透明串', (
      tester,
    ) async {
      // 回归防线（真实缺陷：Windows 客户端登录成功后立刻提示「会话已失效」）。
      //
      // ## 缺陷成因
      //
      // `signInActionProvider` 曾写成 `accessToken: tokens.accessToken`，于是
      // 把 IdP（fosite）签发的**不透明** access_token（`ory_at_…`，无点号）
      // 当 Bearer 发给 api-gateway。网关的两个认证器都要求 compact JWS：
      //   - `pkg/auth/jwt_authenticate.go`（JWKS + RS256）
      //   - `pkg/auth/oidc_auth.go`（go-oidc `verifier.Verify`）
      // 分别报「token contains an invalid number of segments」与
      // 「compact JWS format must have three parts」，于是登录刚完成就 401
      // → 客户端判定会话失效 → 把用户踢回登录页。
      //
      // ## 为什么用注入的 loopback 实现而不是替换 `signInAction`
      //
      // 要测的是**真实 `signInActionProvider` 的落盘代码**。替换掉它就等于
      // 把被测的那一行删了——这正是既有用例（`登录页点击 SSO 按钮调用注入的
      // signInAction` 只断言调用次数）抓不到本缺陷的原因。
      final store = InMemoryTokenStore();
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.login,
        tokenStore: store,
        mockGroups: false,
        loopbackSignIn: ({required OidcConfig config}) async =>
            LoopbackSignInResult.success(
              OidcTokens.fromJson({
                'access_token': 'ory_at_2Xk9opaque',
                'token_type': 'Bearer',
                'expires_in': 3600,
                'id_token': 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c3JfMSJ9.sig',
                'refresh_token': 'ory_rt_1',
                'scope': 'openid profile email',
              }),
            ),
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      final stored = await store.read();
      expect(stored, isNotNull);
      expect(
        stored!.accessToken,
        startsWith('eyJ'),
        reason: '落盘的必须是 id_token（RS256 JWT），网关只认这个',
      );
      expect(
        stored.accessToken,
        isNot(startsWith('ory_at_')),
        reason: 'ory_at_… 是 fosite 不透明串，网关验不了 → 登录后立刻 401',
      );
      expect(stored.refreshToken, 'ory_rt_1', reason: '刷新链路要用它续期');
      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '凭证落盘后应推进到已登录',
      );
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.home,
        reason: '登录完成后守卫应把用户送离 /login',
      );
    });

    testWidgets('登录成功后守卫放行首页（状态从 unknown 推进到 authenticated）', (tester) async {
      // 端到端验证「凭证落盘 → 守卫放行」这条链路，而不只是「路由表里有 /login」。
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);

      // 模拟外部回调把 token 落盘（真实场景由浏览器回调后的处理流程完成）。
      await store.write(freshTokens());
      h.container.read(authStateProvider.notifier).signedIn();
      await tester.pumpAndSettle();

      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '状态应变为已登录',
      );
    });
  });

  testWidgets('devUserHeaderOverride 默认 null（未传 SPB_DEV_USER_ID）', (
    tester,
  ) async {
    // 这条断言防的是「默认值不小心写成非 null」——那等于允许客户端自选身份
    // （任何拿到打包产物的人都能把 X-User-ID 改成别人的 id）。
    final h = await pumpApp(tester);

    expect(h.container.read(devUserHeaderOverrideProvider), isNull);
  });

  testWidgets('进入对话页用真实 userId 建 SSE（issue #2：不得是 /users//chat/stream）', (
    tester,
  ) async {
    // 回归防线：修复前 `_focus()` 在 `/api/auth/me` 返回前就读
    // `currentUserIdProvider.value`（必然 null）→ 拼出 `/users//chat/stream`，
    // 且 provider 重建出的新实例永远不被 start。
    //
    // mock 必须在 pumpWidget 前注册：`/api/auth/me` 是首帧 postFrameCallback
    // 就发出的请求（见 beforePump 的说明）。
    final sse = FakeSseClient();
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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

    // 不用 pumpAndSettle：加载态里的 CircularProgressIndicator 是无限动画，
    // pumpAndSettle 会一直等到超时。用显式 pump 推进假时钟即可。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(sse.connectedPaths, isNotEmpty, reason: '必须建立 SSE 连接');
    expect(
      sse.connectedPaths.single,
      '/users/usr_REAL/chat/stream',
      reason: 'userId 必须来自 /api/auth/me，而不是空串',
    );
  });

  testWidgets('进入对话后 AppBar 标题是 group.title（不是固定的「对话」）', (tester) async {
    // ## 本用例防的是什么
    //
    // 修复前两端都传 `title: '对话'`（硬编码），而**列表页**的 AppBar 也叫
    // 「对话」——用户点进去后看不出自己是否真的进了某个对话、进的是哪一个。
    // 两端 router 都改用 `_appBarTitle`（取自 `_group.title`）。
    //
    // ## 为什么必须在 router 层断言
    //
    // `ConversationPage` 自己的测试**自己传 title**——它不关心 router 传什么，
    // 所以「router 又写回硬编码」这种漏接在那里永远发现不了（与 §6.17 接线
    // 守卫同一个失败模式）。
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_title'),
      mockGroups: false,
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
          '/chat/groups/grp_title',
          (server) => server.reply(200, {
            'id': 'grp_title',
            'user_id': 'usr_REAL',
            'title': '季度复盘',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_title/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_REAL/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': 'grp_title', 'limit': 20},
        );
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(
      find.widgetWithText(AppBar, '季度复盘'),
      findsOneWidget,
      reason: '进入对话后 AppBar 必须显示对话名',
    );
    expect(
      find.widgetWithText(AppBar, '对话'),
      findsNothing,
      reason: '硬编码的「对话」与列表页同名，用户看不出自己进了哪个对话',
    );
  });

  testWidgets('同一 userId 下跨两个 group 只建一次 SSE（切 group 走 switchGroup）', (
    tester,
  ) async {
    // 回归防线：若切对话仍走 `start()`，`SseClient.connect()` 会把续接游标
    // 置 null（丢 cursor 回放能力），且每次切对话都多一次建连往返。
    final sse = FakeSseClient();
    final h = await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_1'),
      mockGroups: false,
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
        for (final gid in ['grp_1', 'grp_2']) {
          adapter.onGet(
            '/chat/groups/$gid/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': gid, 'limit': 20},
          );
        }
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(sse.connectedPaths, hasLength(1), reason: '首次进入建立连接');

    // 切到另一个 group（同一路由模式，不同 path 参数）。
    h.router.go(SpbRoutes.chat('grp_2'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      sse.connectedPaths,
      hasLength(1),
      reason: 'SSE 是 user 级订阅，切 group 不得重连',
    );
  });

  testWidgets('currentUserProvider 走 mock 的 /api/auth/me', (tester) async {
    // `/me` 必须在 `beforePump` 里注册：`pumpApp` 自带一个默认 `/me`（首页
    // 现在会解析 userId 以建 SSE），而 mock 是「后者覆盖前者」——若在
    // `pumpApp` 返回后才注册，首帧那次请求早已用默认值发出去了。
    final h = await pumpApp(
      tester,
      mockGroups: false,
      beforePump: (adapter) {
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
      },
    );

    // 触发请求并推进假时钟。
    final future = h.container.read(currentUserProvider.future);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final user = await future;
    expect(user.id, 'usr_1');
    expect(user.isAdmin, isFalse);
  });

  testWidgets('对话页重连：router 注入 onReconnect 且把重连送到 SseClient', (tester) async {
    // 只验证 **router 的接线**：注入的 onReconnect 必须真的把重连请求送到
    // SseClient（`resumeCount` 从 0 变 1）。
    //
    // ## 这条用例抓不住什么（已实测，勿误信）
    //
    // 它**抓不住**「family 键写错成 groupId」：`sseClientProvider` 是跨对话共享
    // 的单例，`reconnect()` 最终就是 `_sse.resume()`，而共享 client 上确实有
    // `_path`——换哪个 family 条目都能连通。故这里不宣称覆盖该场景；键的正确性
    // 靠「注入点与 `ref.watch` 在同一 build 里取自同一变量」来保证（见 router 注释）。
    final sse = FakeSseClient();
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(sse.connectedPaths, [
      '/users/usr_REAL/chat/stream',
    ], reason: '前置条件：必须先真的连上');

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onReconnect,
      isNotNull,
      reason: 'router 必须注入 onReconnect，否则指示器永远不可点',
    );

    page.onReconnect!();
    await tester.pump();

    expect(sse.resumeCount, 1, reason: '重连请求必须真的到达 SseClient');
  });

  testWidgets('对话页停止生成：router 把 turnId 接到 POST /chat/turns/:id/cancel', (
    tester,
  ) async {
    // ## 本用例验证什么
    //
    // 只验证 **router 的接线**：「注入的 onCancelTurn 会打到哪个端点、turnId 是否
    // 原样透传」。直接取树上 `ConversationPage` 的回调调一下，不依赖任何 SSE 事件。
    //
    // ## 为什么不走「推流式帧 → 点按钮」的完整链路
    //
    // 那样写会卡在一个**既有的 bug** 上（与本任务无关，已实测）：
    // `_ChatPage._focus()` 用 `ref.read(chatStreamControllerProvider(...))`，
    // 而 `build()` 用 `ref.watch(...)`——对 `autoDispose.family` 而言这两次拿到
    // 的**不是同一个实例**。于是 `start()` 跑在实例 A 上，页面拿的是未被启动的
    // 实例 B，B 的 `items` 永远收不到事件（实测：回填的 timeline 也渲染不出来，
    // 用 pristine 代码同样复现）。
    //
    // 「什么时候按钮可点、传哪个 turnId」由 spb_features 的
    // `conversation_page_test.dart` 完整覆盖（那里直接构造控制器，没有这个问题）。
    final hitPaths = <String>[];
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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
        // 用 `replyCallback` 而非 `reply`：它只在**请求真的到达**时被调用，
        // 因此记录的路径就是实际发出的请求（`adapter.history` 里存的是
        // **已注册的 mock**，不能用来断言「请求发生过」）。
        adapter.onPost(
          '/chat/turns/turn_9/cancel',
          (server) => server.replyCallback(200, (options) {
            hitPaths.add(options.path);
            return {'status': 'cancelled'};
          }),
          data: Matchers.any,
        );
      },
    );

    // 推进假时钟：解析 userId → 回填 timeline（不需要 pumpAndSettle：
    // 对话页的加载态是无限动画，会等到超时）。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onCancelTurn,
      isNotNull,
      reason: 'router 必须注入 onCancelTurn，否则页面上不会出现停止按钮',
    );

    // 必须包在 `runAsync` 里：回调内部会 await 一个 dio 请求，而 dio 的 mock
    // 响应靠真实事件循环完成——在 FakeAsync 时区里直接 `await` 会死锁
    // （实测：卡满 10 分钟超时）。`runAsync` 让这段跑在真实时区。
    await tester.runAsync(() => page.onCancelTurn!('turn_9'));
    await tester.pump();

    expect(hitPaths, [
      '/chat/turns/turn_9/cancel',
    ], reason: 'turnId 必须原样透传到路径，且只发一次请求');
  });

  testWidgets('对话页归属反馈：router 把 token 接到 POST /chat/feedback/:token/resolve', (
    tester,
  ) async {
    // 只验证 **router 的接线**：注入的 onResolveFeedback 打到哪个端点、
    // correct 是否进请求体。直接取树上 ConversationPage 的回调调一下，
    // 不依赖 SSE 事件（理由见上面的「停止生成」用例：完整链路会撞上
    // _focus()/build() 拿到不同控制器实例的既有问题）。
    final hit = <(String, Object?)>[];
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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
        adapter.onPost(
          '/chat/feedback/tok_fb1/resolve',
          (server) => server.replyCallback(200, (options) {
            hit.add((options.path, options.data));
            return <String, dynamic>{};
          }),
          data: Matchers.any,
        );
      },
    );

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onResolveFeedback,
      isNotNull,
      reason: 'router 必须注入 onResolveFeedback，否则反馈卡按钮会被禁用',
    );

    await tester.runAsync(() async {
      await page.onResolveFeedback!('tok_fb1', true);
      // onResolveFeedback 返回 Future，但真实 dio 往返需要真实事件循环跑完。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(hit, hasLength(1), reason: '必须真的发出一次回执请求');
    expect(hit.single.$1, '/chat/feedback/tok_fb1/resolve');
    expect(
      hit.single.$2,
      containsPair('reply', '准确'),
      reason:
          '服务端入参只有 reply/index/group_id（feedback_resolve.go）；'
          '发 correct 会被 ShouldBindJSON 忽略 → Reply 空 → 400 reply is required',
    );
    expect(
      (hit.single.$2! as Map).containsKey('correct'),
      isFalse,
      reason: 'correct 是错误键名，发出去只会让服务端静默忽略',
    );
  });

  testWidgets(
    '对话页 Agent 切换：router 把 agentId 接到 POST /chat/groups/:id/sessions/switch',
    (tester) async {
      // ## 本用例验证什么
      //
      // 只验证 **router 的接线**：AppBar 上的 `AgentSwitcher` 确实被注入了
      // 「可用的 agent 列表」与「切换回调」，且回调打到正确端点、`agentId` 以
      // **camelCase** 进 body。
      //
      // ## 为什么要单独测「接线」
      //
      // `AgentSwitcher` 自己的行为（确认框、降级、菜单内容）由
      // `spb_features/test/chat/agent_switcher_test.dart` 覆盖。但那个测试
      // 用的是**手工构造的**回调——它无法发现「router 忘了注入」这种错误，
      // 而那正是本仓库最常见的失败模式（功能实现了但没人调用）。
      final hit = <({String path, Object? body})>[];
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
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
            '/chat/groups/grp_x',
            (server) => server.reply(200, {
              'id': 'grp_x',
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
          adapter.onPost(
            '/chat/groups/grp_x/sessions/switch',
            (server) => server.replyCallback(200, (options) {
              hit.add((path: options.path, body: options.data));
              return {
                'group_id': 'grp_x',
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

      // 推进假时钟：解析 userId + 拉 group（设置 tab 与 agent 标签都依赖它）。
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // 前置条件：入口真的出现在 AppBar 上（注入生效）。
      expect(
        find.byKey(const ValueKey('agent-switcher')),
        findsOneWidget,
        reason: 'router 必须注入 loadAgents，否则入口会因空列表而隐藏',
      );

      // 走真实交互路径：开菜单 → 选项 → 确认。
      await tester.tap(find.byKey(const ValueKey('agent-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-option-agent_b')));
      await tester.pumpAndSettle();

      // 必须包在 `runAsync` 里：回调内部会 await dio 请求，而 dio 的 mock
      // 响应靠真实事件循环完成——在 FakeAsync 时区里直接 await 会死锁
      // （见同文件 onCancelTurn 用例的说明）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('agent-switch-confirm-ok')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(hit, hasLength(1), reason: '必须真的发出一次切换请求');
      expect(hit.single.path, '/chat/groups/grp_x/sessions/switch');
      final body = hit.single.body! as Map<String, dynamic>;
      expect(
        body['agentId'],
        'agent_b',
        reason: '⚠️ 键名必须是 camelCase 的 agentId——写成 agent_id 会 400「agentId 不能为空」',
      );
      expect(body.containsKey('agent_id'), isFalse);
    },
  );
  group('登录后回跳（消费 from 参数）', () {
    testWidgets('未认证访问 /settings → 落在 /login?from=%2Fsettings', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(
        h.router.state.uri.queryParameters['from'],
        SpbRoutes.settings,
        reason: '守卫必须把原目标写进 from，否则登录后无从回跳',
      );
    });

    testWidgets('登录完成后回跳到 from 指向的页面（而非首页）', (tester) async {
      // 端到端验证「写入的 from 真的被消费」。修复前该参数被写入却无人读取，
      // 用户从 /settings 被踢到登录页，登录完只落到首页。
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
      );
      expect(h.router.state.matchedLocation, SpbRoutes.login);

      // 模拟认证完成（真实场景由 OIDC 回调流程完成）。
      h.container.read(authStateProvider.notifier).signedIn();

      // ## 为什么这里要多推一次 2 秒
      //
      // 回跳会挂载首页（`/settings` 是 `/` 的子路由），它的 `initState` 立刻
      // 发 `/chat/groups`。`DioAdapter` 用**零延时 Timer** 投递响应，而
      // `pumpAndSettle` 只推进微任务与动画，不会让零延时 Timer 到期——
      // 于是用例结束时框架以 `!timersPending` 断言失败。报错栈完全指向网络层，
      // 与「回跳」毫无关系，极易误导。
      //
      // `pumpApp` 内部对首帧做了同样的事（`pump(2s)`）；这里因为导航发生在
      // 用例中途，必须再推一次。
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.settings,
        reason: '登录成功必须回到用户原本想去的页面',
      );
    });

    testWidgets('已认证用户带 from=/settings 打开 /login 也回跳（刷新/书签路径）', (tester) async {
      // 「已认证 + 停在 /login」不只发生在「刚登录成功」那一瞬：刷新页面、
      // 点开旧书签同样如此。回跳逻辑放在守卫里才能覆盖这些路径。
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=%2Fsettings',
      );

      expect(h.router.state.matchedLocation, SpbRoutes.settings);
    });

    testWidgets('from=https://evil.com 被拒绝，落回首页（防开放重定向）', (tester) async {
      // 开放重定向：诱导用户点一个看起来是本站的链接，登录完成后落到外站，
      // 而用户刚在真正的本站输入过凭证——这正是钓鱼需要的信任转移。
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=https%3A%2F%2Fevil.com',
      );

      expect(h.router.state.matchedLocation, SpbRoutes.home);
    });

    testWidgets('from=//evil.com 被拒绝，落回首页（协议相对 URL）', (tester) async {
      // `//evil.com` 是协议相对 URL（RFC 3986 §4.2），解析结果同样是
      // `https://evil.com`。只判「以 / 开头」会把它放过去，必须单独挡。
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=%2F%2Fevil.com',
      );

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.home,
        reason: '协议相对 URL 必须被拒绝（只判前导 / 会漏掉它）',
      );
    });

    testWidgets('from=/login 被拒绝，落回首页（否则构成重定向环）', (tester) async {
      final h = await pumpApp(tester, initialLocation: '/login?from=%2Flogin');

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.home,
        reason: '回跳到登录页自身会让 go_router 检测到重定向环并抛异常',
      );
    });
  });
}
