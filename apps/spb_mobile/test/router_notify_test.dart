import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 登录回跳 / 确认通知 / 导入会话 / 窄屏 AppBar（issue #31）
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/mobile_harness.dart`。
void main() {
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

    testWidgets('登录完成后回跳到 from 指向的页面（而非对话列表）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
      );
      expect(h.router.state.matchedLocation, SpbRoutes.login);

      h.container.read(authStateProvider.notifier).signedIn();
      await tester.pumpAndSettle();

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.settings,
        reason: '登录成功必须回到用户原本想去的页面',
      );
    });

    testWidgets('已认证用户带 from=/settings 打开 /login 也回跳', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=%2Fsettings',
      );

      expect(h.router.state.matchedLocation, SpbRoutes.settings);
    });

    testWidgets('from=https://evil.com 被拒绝，落回对话列表（防开放重定向）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=https%3A%2F%2Fevil.com',
      );

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.conversations,
        reason: '绝对 URL 必须被拒绝',
      );
    });

    testWidgets('from=//evil.com 被拒绝，落回对话列表（协议相对 URL）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: '/login?from=%2F%2Fevil.com',
      );

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.conversations,
        reason: '协议相对 URL 必须被拒绝（只判前导 / 会漏掉它）',
      );
    });

    testWidgets('from=/login 被拒绝，落回对话列表（否则构成重定向环）', (tester) async {
      final h = await pumpApp(tester, initialLocation: '/login?from=%2Flogin');

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.conversations,
        reason: '回跳到登录页自身会让 go_router 检测到重定向环并抛异常',
      );
    });
  });
  group('确认卡到达时发 OS 通知（issue #21）', () {
    void pushConfirmation(
      FakeSseClient sse, {
      String eventId = 'evt_n1',
      String confirmationId = 'conf_n1',
      String groupId = 'grp_n',
      String question = '要部署到生产吗？',
    }) {
      sse.push('confirmation_required', {
        'eventId': eventId,
        'eventType': 'confirmation_required',
        'groupId': groupId,
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'payload': {
          'confirmation_id': confirmationId,
          'question': question,
          'options': ['继续', '取消'],
        },
      });
    }

    /// 起一个「已进入某对话页」的测试环境。
    Future<TestHarness> pumpInChat(
      WidgetTester tester, {
      required FakeSseClient sse,
      required NotificationSink sink,
      bool foreground = false,
      String groupId = 'grp_n',
    }) async {
      final h = await pumpApp(
        tester,
        sseClient: sse,
        notificationSink: sink,
        appForeground: foreground,
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
            '/chat/groups/$groupId',
            (server) => server.reply(200, {
              'id': groupId,
              'user_id': 'usr_REAL',
              'title': '通知测试',
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
            '/users/usr_REAL/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': groupId, 'limit': 20},
          );
        },
      );
      h.router.go(SpbRoutes.chat(groupId));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      return h;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('新的确认卡到达 → 发一条通知（应用在后台）', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, foreground: false);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, hasLength(1));
      expect(sink.sent.single.title, '需要你确认');
      expect(sink.sent.single.body, '要部署到生产吗？');
      expect(sink.sent.single.payload, '/chat/grp_n');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('应用在前台 → 不发通知', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, foreground: true);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('同 id 重复推送（SSE 重连回放）→ 只发一次', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, foreground: false);

      pushConfirmation(sse, eventId: 'evt_n1');
      await settle(tester);
      pushConfirmation(sse, eventId: 'evt_n1_replay');
      await settle(tester);

      expect(sink.sent, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('权限被拒 → 不发通知（静默降级，不崩）', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink(granted: false);
      await pumpInChat(tester, sse: sse, sink: sink, foreground: false);

      pushConfirmation(sse);
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('普通消息（非确认卡）不触发通知', (tester) async {
      final sse = FakeSseClient();
      final sink = RecordingNotificationSink();
      await pumpInChat(tester, sse: sse, sink: sink, foreground: false);

      sse.push('message', {
        'eventId': 'evt_msg',
        'eventType': 'message',
        'groupId': 'grp_n',
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 1,
        'createdAt': '2026-01-01T00:00:00Z',
        'payload': {'text': '普通回复'},
      });
      // 收尾 `done`：`message` 会让 turn 进入进行中，控制器据此武装看门狗
      // 计时器；不收尾会留下 pending timer（同桌面端用例的说明）。
      sse.push('done', {
        'eventId': 'evt_done',
        'eventType': 'done',
        'groupId': 'grp_n',
        'turnId': 'turn_n1',
        'userId': 'usr_REAL',
        'seq': 2,
        'createdAt': '2026-01-01T00:00:01Z',
        'payload': <String, dynamic>{},
      });
      await settle(tester);

      expect(sink.sent, isEmpty);
      expect(sink.permissionCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
  group('导入会话（粘贴凭证 → 落盘 → 请求带 Bearer）', () {
    testWidgets('导入合法会话后状态变为已登录', (tester) async {
      // 移动端登录闭环的唯一入口：IdP 未注册 `partyb://oidc/callback`
      // public client，深链路径当前无法换到 token（见
      // docs/mobile-oidc-deeplink.md）。故「粘贴导入」不是可选便利功能，
      // 而是移动端**现在唯一能登录的路径**。
      final store = InMemoryTokenStore();
      final h = await pumpApp(
        tester,
        tokenStore: store,
        initialLocation: SpbRoutes.login,
        mockGroups: false,
      );

      // 必须先等启动时的 restore() 落定，否则它与 importSession 竞争 store。
      //
      // 这是**真实的竞态**（非测试噪音）：`AuthStateNotifier.build()` 里
      // `unawaited(restore())` 在 store 为空时走「清理残留凭证」分支，
      // 它 await 完 currentAccessToken() 后会再读一次 store，若那时已被
      // 导入写入，就判定为残留并 logout()——把刚导入的凭证清掉。
      await tester.runAsync(() async {
        while (h.container.read(authStateProvider).status ==
            AuthStatus.unknown) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });

      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isFalse,
        reason: '前置条件：导入前必须是未登录，否则本用例空洞通过',
      );

      final err = await h.container
          .read(authControllerProvider)
          .importSession('id_token=test-id-token; refresh_token=test-refresh');

      expect(err, isNull, reason: '合法凭证不该报错');
      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '导入后必须变为已登录，否则用户仍被守卫挡在登录页',
      );

      final stored = await store.read();
      expect(stored!.accessToken, 'test-id-token');
      expect(stored.refreshToken, 'test-refresh');
    });

    testWidgets('认不出的内容报错且不落盘（不造无效凭证）', (tester) async {
      final store = InMemoryTokenStore();
      final h = await pumpApp(
        tester,
        tokenStore: store,
        initialLocation: SpbRoutes.login,
        mockGroups: false,
      );
      await tester.runAsync(() async {
        while (h.container.read(authStateProvider).status ==
            AuthStatus.unknown) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });

      final err = await h.container
          .read(authControllerProvider)
          .importSession('session_id=abc; csrf=def');

      expect(err, isNotNull, reason: '无 id_token/access_token 必须报错');
      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isFalse,
        reason: '解析失败不得置为已登录',
      );
      expect(await store.read(), isNull, reason: '不该把认不出的数据写进安全存储');
    });

    testWidgets('导入后请求头带上 Authorization: Bearer <token>', (tester) async {
      // 闭环的最后一环：光落盘不够，请求必须真的带上凭证，否则服务端仍 401。
      //
      // 为什么不能用 pumpApp 的 harness：`pumpApp` 把 dioProvider override
      // 成裸 dio（只挂 DioAdapter，没有 AuthInterceptor），用它断言「带
      // Bearer」是空洞的（实测 Authorization 恒为 null）。故自建容器，
      // 只 override 凭证存储，让 dioProvider 走生产实现。
      final store = InMemoryTokenStore();
      final container = ProviderContainer(
        overrides: [tokenStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      final dio = container.read(dioProvider);
      final adapter = DioAdapter(dio: dio);
      addTearDown(dio.close);

      final seen = <String, String?>{};
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            seen['Authorization'] = options.headers['Authorization'] as String?;
            handler.next(options);
          },
        ),
      );

      await tester.runAsync(() async {
        while (container.read(authStateProvider).status == AuthStatus.unknown) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });

      final err = await container
          .read(authControllerProvider)
          .importSession('id_token=test-id-token');
      expect(err, isNull, reason: '前置条件：导入必须成功');
      expect(
        (await store.read())?.accessToken,
        'test-id-token',
        reason: '凭证必须真的落盘，否则下面的请求头断言是空洞的',
      );

      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'limit': 50, 'offset': 0},
      );

      await tester.runAsync(() => container.read(chatApiProvider).listGroups());

      expect(
        seen.containsKey('Authorization'),
        isTrue,
        reason: '请求必须真的发出，否则下面的断言是空洞的',
      );
      expect(
        seen['Authorization'],
        'Bearer test-id-token',
        reason: '导入的凭证必须出现在 Authorization 头上，否则服务端仍 401',
      );
    });

    testWidgets('登录页展示导入入口与输入框', (tester) async {
      // 移动端此前只注入 onSignIn，LoginPage 的导入区不渲染。
      // 这条用例守住「移动端也有这条路」——它是当前唯一可登录路径。
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        initialLocation: SpbRoutes.login,
        mockGroups: false,
      );
      await tester.pumpAndSettle();

      // 导入区默认收起（它是备选路径，展开着会让登录页看起来有两条对等入口）
      // ——必须先展开才能断言输入框存在。
      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('login-import-field')),
        findsOneWidget,
        reason: '移动端必须展示粘贴导入入口（深链闭环依赖 IdP 注册）',
      );
    });

    testWidgets('待验证登录请求持久化：进程重启后仍可消费（回调能完成换 token）', (tester) async {
      // 深链登录的闭环条件：授权流程把用户带到外部浏览器，应用可能在此期间
      // 被系统回收。state/verifier 若只存内存，重启后回调会因「没有进行中的
      // 登录」被拒。这里模拟该场景：put → 丢弃整个容器（进程死亡）→ 新容器
      // 从加密存储消费。内存实现会在第二步返回 null。
      //
      // 平台存储用假后端（flutter_secure_storage 无平台通道，真调用抛
      // MissingPluginException）；持久化行为本身（TTL、round-trip）由
      // spb_data 的 secure_pending_auth_store_test.dart 覆盖，这里断言
      // 「装配点选了持久实现且整条链路真的通」。
      final fakePlatform = FakeSecureStoragePlatform();
      FlutterSecureStoragePlatform.instance = fakePlatform;
      addTearDown(() {
        FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
      });

      const request = PendingAuthRequest(
        state: 'st_restart',
        pkce: PkcePair(verifier: 'v_restart', challenge: 'ch_restart'),
      );

      // 进程 1：发起登录（写入持久存储）。
      final container1 = ProviderContainer();
      addTearDown(container1.dispose);
      await container1.read(pendingAuthStoreProvider).put(request);

      // 进程 2：系统回收后重启，新容器从加密存储恢复。
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final restored = await container2
          .read(pendingAuthStoreProvider)
          .consume();

      expect(restored, isNotNull, reason: '进程被回收后回调必须仍能完成 state 校验');
      expect(restored!.state, 'st_restart');
      expect(restored.pkce.verifier, 'v_restart');
    });
  });
  group('对话页窄屏 AppBar（issue #31）', () {
    /// ## 这个 group 防的是什么
    ///
    /// 此前对话页在常见手机宽度下**两处** RenderFlex 溢出（composer 360dp
    /// 达 64px、AppBar 达 66px），而测试没发现——因为全部 widget test 用
    /// **默认 800dp 窗口**，比真机宽。本机无 `DISPLAY`（AGENTS.md §9），
    /// 也没有真机可看。
    ///
    /// 故这里显式把窗口压到真机宽度。用例只断言「不溢出」，不锁定具体
    /// 布局——布局会随设计调整，而「任何宽度都不该出黄黑条」是不变式。
    for (final width in [320.0, 360.0, 390.0, 412.0]) {
      testWidgets('宽 $width dp 下对话页无 RenderFlex 溢出', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // 用长 agent 名（140dp 上限）：短名字会掩盖 AgentSwitcher 的宽度问题。
        await pumpApp(
          tester,
          initialLocation: SpbRoutes.chat('grp_narrow'),
          loadAgents: () async => const [
            Agent(id: 'agent_a', name: '一个名字很长的写作助手'),
          ],
        );
        await tester.pump(const Duration(seconds: 1));

        expect(
          tester.takeException(),
          isNull,
          reason: '窄屏溢出会把右侧入口裁掉/盖住，用户点不到（issue #31）',
        );
      });
    }

    testWidgets('窄屏低频入口收进溢出菜单，宽屏摆出独立图标', (tester) async {
      // 窄屏：三个低频入口在菜单里，独立图标不存在。
      tester.view.physicalSize = const Size(360, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_menu'),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('conversation-overflow-menu')),
        findsOneWidget,
        reason: '窄屏必须收起低频入口，否则 AppBar 溢出（issue #31）',
      );
      // 常驻项（带徽标，需一眼可见）仍在。
      expect(
        find.byKey(const ValueKey('open-group-deliverables')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('open-group-todos')), findsOneWidget);

      // 展开菜单：三个低频入口 + 对话内搜索。
      await tester.tap(
        find.byKey(const ValueKey('conversation-overflow-menu')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('menu-group-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-goal-tasks')), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-goal-history')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('menu-conversation-search')),
        findsOneWidget,
        reason: '窄屏不摆搜索图标（没地方），但功能不能因此消失',
      );

      // 关掉菜单，避免留下未结算的动画。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // 宽屏：独立图标回来，菜单消失。
      tester.view.physicalSize = const Size(1000, 2400);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-overflow-menu')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('open-group-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-goal-tasks')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-goal-history')), findsOneWidget);
      // 宽屏下 `_ChatPage` 的 enableSearch 为 true（搜索改由独立图标提供，
      // 见 `宽屏（≥720dp）对话内搜索入口以独立图标可达` 用例），菜单消失。
      expect(h.router.state.matchedLocation, SpbRoutes.chat('grp_menu'));
    });

    testWidgets('窄屏从溢出菜单能打开对话内搜索', (tester) async {
      tester.view.physicalSize = const Size(360, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpApp(tester, initialLocation: SpbRoutes.chat('grp_search'));
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(
        find.byKey(const ValueKey('conversation-overflow-menu')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-conversation-search')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
        reason: '菜单项必须真的打开搜索面板（而不是只关掉菜单）',
      );
    });

    /// ## 这个用例防的是什么
    ///
    /// 此前移动端在**宽屏（≥720dp）**下两个搜索入口**同时消失**
    /// （issue #33）：`enableSearch` 恒为 `false`，而 `_overflowItems()`
    /// 在非 compact 宽度返回 `null` —— 溢出菜单也不渲染。平板、折叠屏
    /// 展开态、横屏手机上「对话内搜索」彻底不可达，而既有用例只断言了
    /// `_group` 系列入口（`open-*` / `menu-*`），没碰搜索。
    ///
    /// 故这里从 **router** 层断言：宽屏下搜索图标存在且能打开面板，
    /// 同时溢出菜单**不**渲染（避免两个入口重复）。与桌面端
    /// `apps/spb_desktop/test/widget_test.dart` 的
    /// `对话页 AppBar 提供对话内搜索入口` 同型：页面测试自己传参，
    /// 「接不接线」它不管，只有 router 层能钉住。
    testWidgets('宽屏（≥720dp）对话内搜索入口以独立图标可达（issue #33）', (tester) async {
      // 取**边界值** 720dp（最紧的宽屏）而不是 1000dp：新增的 48dp 图标若
      // 会在宽屏撑破 AppBar，最可能先在这一档暴露（issue #31 的溢出是
      // 宽度敏感的）。`isCompact(720) == false`，故它属于宽屏。
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpApp(tester, initialLocation: SpbRoutes.chat('grp_search_wide'));
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('conversation-overflow-menu')),
        findsNothing,
        reason: '宽屏低频入口摆独立图标，不需要溢出菜单',
      );

      final icon = find.byKey(const ValueKey('conversation-search-open'));
      expect(
        icon,
        findsOneWidget,
        reason:
            '宽屏必须直接摆出搜索图标——此前它与溢出菜单同时消失，'
            '搜索在 ≥720dp 彻底不可达（issue #33）',
      );

      // 新增的 48dp 图标不能在宽屏把 AppBar 又撑破（issue #31 的反向守卫）。
      expect(
        tester.takeException(),
        isNull,
        reason: '宽屏加搜索图标后仍不应有 RenderFlex 溢出',
      );

      // 点开确认它真的打开面板（而不是只渲染了一个图标）。
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
      );
    });

    /// 与上一条互补：窄屏没有余量，搜索必须留在溢出菜单里。
    ///
    /// 两条分开写而不是合成一个循环：循环里 `pumpApp` 两次会让第一个 app
    /// 的 SSE 重连计时器跨轮次残留（`A Timer is still pending`）。
    testWidgets('窄屏（<720dp）对话内搜索入口收进溢出菜单（issue #31/#33）', (tester) async {
      tester.view.physicalSize = const Size(360, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_search_narrow'),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('conversation-search-open')),
        findsNothing,
        reason: '窄屏没有 48dp 余量摆图标（issue #31）',
      );
      final menu = find.byKey(const ValueKey('conversation-overflow-menu'));
      expect(menu, findsOneWidget, reason: '窄屏搜索走溢出菜单');

      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-conversation-search')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
      );
    });

    testWidgets('极窄屏（<360dp）AgentSwitcher 隐藏名字，避免溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_tiny'),
        loadAgents: () async => const [
          Agent(id: 'agent_a', name: '一个名字很长的写作助手'),
        ],
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('agent-switcher-label')),
        findsNothing,
        reason: '320dp 下名字（最多 140dp）放不下，只留图标（issue #31）',
      );
      expect(find.byKey(const ValueKey('agent-switcher')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
