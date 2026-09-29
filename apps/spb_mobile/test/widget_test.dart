import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:drift/native.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_mobile/app.dart';
import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

/// 假的 [SseClient]：不连网、不重试。
///
/// ## 为什么必须注入它
///
/// 进入 `/chat/:groupId` 会挂载 `ConversationPage`，其控制器调
/// `SseClient.connect` 发真实长连接请求。测试环境下这必然失败，而
/// `SseClient` 会**按指数退避安排重连定时器**（1s / 2s / ...），于是测试结束时
/// 仍有 pending Timer，flutter_test 直接报
/// 「A Timer is still pending even after the widget tree was disposed」。
///
/// 用真 SseClient + mock adapter 解决不了：SSE 走 `ResponseType.stream`，
/// `DioAdapter` 不模拟流式响应，仍会落到失败/重试路径。故直接替换为假实现。
class _FakeSseClient extends SseClient {
  _FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();
  bool disposed = false;

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {}

  @override
  Future<void> resume() async {}

  @override
  void recordEventId(String eventId) {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await framesController.close();
    await statesController.close();
  }
}

/// 测试环境句柄。
///
/// ## 为什么由 pumpApp 创建 adapter 并返回
///
/// `DioAdapter` 绑定到**某个具体 dio 实例**。若用例自己建 adapter、而 pumpApp
/// 内部另建 dio override 给 `dioProvider`，用例注册的 mock 永远不会被命中
/// （表现为请求真实发出、测试挂到超时）。故 adapter 必须在 pumpApp 内创建并交回。
class TestHarness {
  TestHarness({
    required this.dio,
    required this.adapter,
    required this.router,
    required this.container,
  });

  final Dio dio;
  final DioAdapter adapter;
  final GoRouter router;

  /// Riverpod 容器（显式创建，见 [pumpApp] 的说明）。
  final ProviderContainer container;
}

/// 启动测试用 app，注入 fake provider（**禁止真实网络**）。
Future<TestHarness> pumpApp(
  WidgetTester tester, {
  String initialLocation = SpbRoutes.conversations,
  bool mockGroups = true,
  SseClient? sseClient,
  TokenStore? tokenStore,
  Future<String?> Function()? signInAction,
  void Function(DioAdapter adapter)? beforePump,
  /// 目录选择器（移动端恒为「取消」，用例可覆盖以验证注入生效）。
  PickSyncDirectory? pickDirectory,
  /// 同步动作。
  RunSyncAction? runSync,
  /// 设置页注入点：读取设置。默认「固定目录 + 全部范围」。
  LoadSyncSettings? loadSyncSettings,
  /// 设置页注入点：保存设置。
  SaveSyncSettings? saveSyncSettings,
  /// 设置页注入点：对话列表。
  LoadSyncGroups? loadSyncGroups,
  /// 设置页注入点：本地扫描。
  ScanLocalGroups? scanLocalGroups,
  /// 设置页注入点：执行清理。
  ExecutePrune? executePrune,
}) async {
  final dio = createDio(baseUrl: 'https://api.test/pba');
  final adapter = DioAdapter(dio: dio);

  // 供用例在 pumpWidget **之前**注册 mock。
  //
  // ## 为什么需要这个钩子
  //
  // 若在 `pumpApp` 返回后才注册 mock，则任何在**首帧**触发的请求
  // （如对话页 postFrameCallback 里的 `/api/auth/me`）已经以未 mock 状态发出，
  // 得到 NetworkError 后页面永远停在加载态——表现为「mock 明明注册了却不命中」。
  beforePump?.call(adapter);

  // 首页（对话列表）挂载即请求。不 mock 会留下未结算 Timer，
  // flutter_test 报「A Timer is still pending...」。
  if (mockGroups) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
  }

  // ## 为什么用 `UncontrolledProviderScope` + 显式 container
  //
  // 路由的 `refreshListenable`（认证状态变化时重跑守卫）来自 Riverpod 容器，
  // 而它必须在 `pumpWidget` **之前**就存在才能传给 `GoRouter`。若用
  // `ProviderScope`（内部自建容器），测试拿不到容器也就拿不到 listenable，
  // 于是「凭证恢复完成 → 重跑守卫」这条链路永远不会被触发——表现为
  // 「未登录用户停在列表页」。
  final container = ProviderContainer(
    overrides: [
      desktopCapabilitiesProvider.overrideWithValue(
        const NoopDesktopCapabilities(),
      ),
      dioProvider.overrideWithValue(dio),
      // 默认注入「已登录」的内存存储：否则 restore() 会读真实的
      // SecureTokenStore（走平台通道，测试环境必然抛 MissingPluginException），
      // 得到「未登录」后被守卫重定向到 /login——那么所有期望「列表渲染」
      // 的用例都会失败，而失败原因与被测行为无关。
      tokenStoreProvider.overrideWithValue(
        tokenStore ?? InMemoryTokenStore(_freshTokens()),
      ),
      // 移动端真实实现尚未接入（属下一任务），测试里注入可控假实现。
      signInActionProvider.overrideWithValue(signInAction ?? () async => null),
      if (sseClient != null) sseClientProvider.overrideWithValue(sseClient),
      // 内存库：真实实现走 path_provider 平台通道，测试环境必然抛
      // MissingPluginException（且会写开发者本机的应用数据目录）。
      appDatabaseProvider.overrideWith((ref) {
        final db = AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      // 同步目录固定（移动端无目录选择器）。
      syncLocalRootProvider.overrideWith((ref) async => '/app/deliverables'),
      pickDirectoryProvider.overrideWithValue(
        pickDirectory ?? ({String? title}) async => null,
      ),
      runSyncActionProvider.overrideWithValue(runSync ?? () async => SyncReport()),
      // 设置页的注入点（真实实现会读库/走网络/扫磁盘）。
      loadSyncSettingsProvider.overrideWithValue(
        loadSyncSettings ??
            () async => const SyncSettings(localRoot: '/app/deliverables'),
      ),
      saveSyncSettingsProvider.overrideWithValue(
        saveSyncSettings ?? (_) async {},
      ),
      loadSyncGroupsProvider.overrideWithValue(
        loadSyncGroups ?? () async => const [],
      ),
      scanLocalGroupsProvider.overrideWithValue(
        scanLocalGroups ?? () async => const [],
      ),
      executePruneProvider.overrideWithValue(
        executePrune ??
            (_) async => const PruneOutcome(deleted: 0, failed: {}),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: buildMobileRoutes(),
    redirect: buildAuthRedirect(),
    refreshListenable: container.read(authRefreshListenableProvider),
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: SpbMobileApp(router: router),
    ),
  );
  // 推进假时钟让 dio mock 的 Timer 触发（runAsync 不推进假时钟）。
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();

  return TestHarness(
    dio: dio,
    adapter: adapter,
    router: router,
    container: container,
  );
}

/// 一份「不会过期」的凭证（测试用）。
StoredTokens _freshTokens() => StoredTokens(
  accessToken: 'at_test',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
);

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
        tokenStoreProvider.overrideWithValue(
          InMemoryTokenStore(_freshTokens()),
        ),
        signInActionProvider.overrideWithValue(() async => null),
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

  testWidgets('/quick-capture 可导航且渲染悬浮输入窗（不带标签栏）', (tester) async {
    // 该页不请求数据（提交才发请求），故无需 mock 任何端点。
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.quickCapture);
    await tester.pumpAndSettle();

    expect(find.text('Enter 提交 · Esc 取消'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-capture-submit')), findsOneWidget);
    // 悬浮窗在 shell 之外：不应带底部标签栏（它是整屏临时页）。
    expect(find.byType(NavigationBar), findsNothing, reason: '悬浮输入窗不应占据标签分支');
  });

  group('小程序工作台路由（/miniapp/*，整屏页在 shell 之外）', () {
    testWidgets('/miniapp/works 渲染工作列表且不带底部标签栏', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'w1',
                  'title': '移动端工作',
                  'status': 'running',
                  'status_label': '运行中',
                  'progress': {'total': 2, 'completed': 1, 'percent': 50},
                  'pending_confirmation_count': 0,
                  'latest_summary': null,
                  'latest_artifact': null,
                  'created_at': '2024-03-05T08:09:10Z',
                  'updated_at': '2024-03-05T08:09:12Z',
                },
              ],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('移动端工作'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
      // 整屏页：不应带底部标签栏（沿用 quick-capture 的先例）。
      expect(
        find.byType(NavigationBar),
        findsNothing,
        reason: '工作台是整屏页，不应占据标签分支',
      );
    });

    testWidgets('点工作条目进入 /miniapp/works/:workId 详情', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'grp_w9',
                  'title': '报表工作',
                  'status': 'running',
                  'status_label': '运行中',
                  'progress': {'total': 1, 'completed': 0, 'percent': 0},
                  'pending_confirmation_count': 0,
                  'created_at': '2024-03-05T08:09:10Z',
                  'updated_at': '2024-03-05T08:09:12Z',
                },
              ],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_w9',
                'title': '报表工作',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 1, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
            }),
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_w9/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byKey(const ValueKey('miniapp-work-grp_w9')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_w9'),
        reason: 'work.id 就是 group id，直接用作路径参数',
      );
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsOneWidget,
      );
    });

    testWidgets('/miniapp/works 与 /miniapp/works/:workId 不互相抢匹配', (tester) async {
      // ## 这个测试防的是什么
      //
      // 两条路径段数不同（2 段 vs 3 段），故当前实现下不会歧义——**实测**
      // 即使把 `:workId` 那条写在前面，`/miniapp/works` 仍匹配到列表页。
      //
      // 这条用例是**回归护栏**：若将来有人把详情页改成 `works` 的嵌套子路由
      // （`path: ':workId'`），或把列表改成通配前缀，就会产生歧义——那时
      // 访问 `/miniapp/works` 可能被详情页抢走，workId 变空串、页面去请求
      // `/works/`，表现为「列表页一打开就是错误」。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(h.router.state.matchedLocation, SpbRoutes.works);
      expect(find.byKey(const ValueKey('miniapp-works-page')), findsOneWidget);
    });

    testWidgets('对话列表有工作台入口（点了能到 /miniapp/works）', (tester) async {
      final h = await pumpApp(tester);

      expect(find.byKey(const ValueKey('group-list-works')), findsOneWidget);

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(h.router.state.matchedLocation, SpbRoutes.works);
    });
  });

  testWidgets('切到设置标签渲染完整设置页', (tester) async {
    // ## 为什么要把测试窗口调高
    //
    // 设置页是 ListView，**惰性构建**：屏幕外的条目在 widget 树里根本不存在，
    // `find.byKey` 找不到。默认 800×600 的测试窗口下，底部的清理入口必然
    // 在屏幕外。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsWidgets);
    expect(find.byKey(const ValueKey('settings-sync-entry')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-include-media')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-prune')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-capabilities')),
      findsNothing,
      reason: '移动端不展示托盘/快捷键区块',
    );
  });

  testWidgets('移动端设置页展示固定沙箱目录（用户需知道文件落在哪）', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('/app/deliverables'), findsOneWidget);
  });

  testWidgets('移动端设置页保存走注入的 saveSyncSettings', (tester) async {
    SyncSettings? saved;
    final h = await pumpApp(
      tester,
      saveSyncSettings: (s) async => saved = s,
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-include-media')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect(saved!.filter.includeMedia, isTrue);
  });

  testWidgets('从设置进入 /settings/sync 渲染同步页', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-sync-entry')));
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.sync);
    expect(find.byKey(const ValueKey('sync-start-button')), findsOneWidget);
    // 移动端没有目录选择器，按钮点了无副作用（provider 恒返回 null）。
    expect(find.byKey(const ValueKey('sync-pick-directory')), findsOneWidget);
  });

  group('未认证重定向（登录页 + /login 路由）', () {
    testWidgets('未认证访问 / 被重定向到 /login（且不带标签栏）', (tester) async {
      // 回归防线：守卫必须真的生效。若没接上，未登录用户会看到列表页，
      // 然后在里面报一堆 401。
      final h = await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
      expect(find.text('使用 SSO 登录'), findsOneWidget);
      // 登录页在 shell 之外：整屏页面不应带底部标签栏。
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('未认证深链 /chat/grp_x 也被重定向到 /login', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
    });

    testWidgets('重定向时带上原目标路径（from 参数）', (tester) async {
      final h = await pumpApp(
        tester,
        initialLocation: SpbRoutes.settings,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
      );

      expect(h.router.state.matchedLocation, SpbRoutes.login);
      expect(h.router.state.uri.queryParameters['from'], SpbRoutes.settings);
    });

    testWidgets('已认证时访问 /login 被送回对话列表', (tester) async {
      final h = await pumpApp(tester, initialLocation: SpbRoutes.login);

      expect(h.router.state.matchedLocation, SpbRoutes.conversations);
      expect(find.byKey(const ValueKey('login-sso-button')), findsNothing);
    });

    testWidgets('登录页点击 SSO 按钮把 signInAction 的失败原因显示出来', (tester) async {
      // 验证「点按钮 → 走 signIn → 失败文案展示」这条链路完整。
      //
      // 注意：移动端真实登录会去打开系统浏览器（平台通道，单测环境不可用），
      // 故这里注入一个返回错误的假实现。真实 `mobileSignIn` 的 URL 构造、
      // state/verifier 暂存、回调解析由 `test/auth_deeplink_test.dart` 覆盖。
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        mockGroups: false,
        signInAction: () async => 'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('client_id'), findsOneWidget);
    });

    testWidgets('凭证落盘后状态推进到已登录', (tester) async {
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

      expect(h.container.read(authStateProvider).isUnauthenticated, isTrue);

      await store.write(_freshTokens());
      h.container.read(authStateProvider.notifier).signedIn();
      await tester.pumpAndSettle();

      expect(h.container.read(authStateProvider).isAuthenticated, isTrue);
    });
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
      sseClient: _FakeSseClient(),
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

    // 进入「对话」分支下的子路由。
    h.router.go(SpbRoutes.chat('grp_x'));
    await tester.pumpAndSettle();

    // 切到「设置」。
    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sync-entry')), findsOneWidget);

    // 用 goBranch 切回「对话」分支（模拟点底部标签）。
    final shell = tester.widget<NavigationBar>(find.byType(NavigationBar));
    shell.onDestinationSelected?.call(0);
    await tester.pumpAndSettle();

    // 分支恢复：应回到 chat 路由（ConversationPage），而非列表。
    // ConversationPage 有 AppBar('对话')，列表页的 AppBar 也是「对话」，
    // 故用「时间线的空提示」区分二者。
    expect(find.text('还没有对话，输入消息开始吧'), findsOneWidget);
  });

  testWidgets('移动端注入的 desktopCapabilities 是空实现', (tester) async {
    final h = await pumpApp(tester);

    // 移动端没有托盘/多窗口，必须降级为空实现（页面据此隐藏相关设置项）。
    expect(h.container.read(desktopCapabilitiesProvider).isSupported, isFalse);
  });

  testWidgets('devUserHeaderOverride 默认 null（未传 SPB_DEV_USER_ID）', (
    tester,
  ) async {
    final h = await pumpApp(tester);

    expect(h.container.read(devUserHeaderOverrideProvider), isNull);
  });
}
