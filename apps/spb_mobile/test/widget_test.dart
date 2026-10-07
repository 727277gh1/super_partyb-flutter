import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:drift/native.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

  /// `connect` 收到的全部 path（按调用顺序）。
  final connectedPaths = <String>[];

  @override
  Future<void> connect({required String path}) async {
    connectedPaths.add(path);
    _hasPath = true;
  }

  /// `resume` 被调用的次数（仅在已 `connect` 过之后才计数）。
  int resumeCount = 0;

  /// 是否已经 `connect` 过（同真实 `SseClient._path != null`）。
  bool _hasPath = false;

  /// 复刻真实 `resume()` 的 `if (_path == null) return;` 早退——
  /// 否则「router 用错 family 键拿到未启动的控制器」这个 bug 观测不到。
  @override
  Future<void> resume() async {
    if (!_hasPath) return;
    resumeCount++;
  }

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

  /// 可选 agent 列表（对话页 AppBar 的 agent 切换入口用）。
  ///
  /// ## 为什么必须默认 override
  ///
  /// 真实实现走 dio → DioAdapter 未注册 `/api/agents` → 失败后 dio 会起
  /// 超时 Timer，flutter_test 报「A Timer is still pending even after the
  /// widget tree was disposed」（与 `sseClient` 同一问题）。
  ///
  /// 默认空列表会让切换入口**隐藏**，既有用例的 AppBar 宽度不变。
  LoadAgents? loadAgents,
}) async {
  final dio = createDio(baseUrl: 'https://api.test/pba');
  final adapter = DioAdapter(dio: dio);

  // 默认的 `/api/auth/me`。
  //
  // ## 为什么现在必须无条件 mock（此前只有部分用例自己注册）
  //
  // 对话列表页现在会订阅 `groupUpdatesProvider`，而该 provider 要先解析出
  // userId 才能拿到控制器（`family` 的键是 userId，见 providers.dart 的
  // issue #2 说明）。于是**任何挂在首页的用例**都会触发 `/api/auth/me`。
  // 不 mock 就会留下一个未结算的请求（→「A Timer is still pending」）。
  //
  // 注册在 `beforePump` **之前**：mock 匹配是「后者覆盖前者」，这样需要
  // 指定 userId 的用例仍可在 `beforePump` 里注册自己的 `/me` 覆盖本默认值。
  adapter.onGet(
    '/api/auth/me',
    (server) => server.reply(200, {
      'id': 'usr_TEST',
      'email': 'test@example.com',
      'name': 'Test',
      'role': 'member',
      'roles': ['member'],
      'permissions': <String>[],
      'status': 'active',
    }),
  );

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
  // 待确认角标 provider 在首页首帧即拉取，与 mockGroups 无关。
  adapter.onGet(
    '/chat/confirmations',
    (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
    queryParameters: {'status': 'pending', 'limit': 50},
  );

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
      // 默认注入假 SSE 客户端。
      //
      // ## 为什么不能再用真实的 SseClient
      //
      // 对话列表页现在会调 `ensureConnected()` 建立共享连接。真实 `SseClient`
      // 走 `ResponseType.stream`，`DioAdapter` 不模拟流式响应，于是连接失败后
      // 进入重连退避——留下未结算的 Timer，flutter_test 直接报
      // 「A Timer is still pending even after the widget tree was disposed」。
      //
      // 需要观察连接行为的用例显式传自己的 fake（见 `connectedPaths`）。
      sseClientProvider.overrideWithValue(sseClient ?? _FakeSseClient()),
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
      runSyncActionProvider.overrideWithValue(
        runSync ?? () async => SyncReport(),
      ),
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
        executePrune ?? (_) async => const PruneOutcome(deleted: 0, failed: {}),
      ),
      // 见 `loadAgents` 参数的说明：不 override 会留下未结算的 Timer。
      loadAgentsProvider.overrideWithValue(
        loadAgents ?? () async => const <Agent>[],
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

/// `flutter_secure_storage` 的内存假后端（无平台通道环境下替换真实现）。
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform
    with MockPlatformInterfaceMixin {
  final Map<String, String> data = {};

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => data[key] = value;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => data[key];

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => data.containsKey(key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => data.remove(key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(data);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      data.clear();
}

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
        tokenStoreProvider.overrideWithValue(
          InMemoryTokenStore(_freshTokens()),
        ),
        signInActionProvider.overrideWithValue(() async => null),
        // 对话列表页会订阅 groupUpdatesProvider 并建立共享 SSE 连接。
        // 真实 SseClient 走流式响应，DioAdapter 不模拟，会留下重连 Timer
        // （→「A Timer is still pending」），故注入假实现。
        sseClientProvider.overrideWithValue(_FakeSseClient()),
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

  group('带附件的悬浮输入窗（/overlay）', () {
    /// 造一个真实存在的临时文件并 mock 系统文件选择器返回它。
    ///
    /// ## 为什么要用**真实文件**而不是 `DroppedFile.fromBytes`
    ///
    /// 本组要验证的是「文件选择器 → 附件列表 → 提交带 file_id」这条**移动端
    /// 特有**的链路（手机没有拖拽）。文件选择器只能返回磁盘路径，而
    /// `_addFiles` 会读 `length()`——文件不存在会被标记 size=-1 并禁用提交。
    /// 用字节来源就绕过了「路径从哪来」这个正是被测的环节。
    ({Directory dir, File file}) makeTempFile(String name) {
      final dir = Directory.systemTemp.createTempSync('mobile-overlay');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(List.filled(32, 7));
      return (dir: dir, file: file);
    }

    /// mock `file_selector` 的通道，让它返回 [paths]。
    ///
    /// 通道名与 method 取自 `file_selector_platform_interface` 的
    /// `MethodChannelFileSelector`（`plugins.flutter.io/file_selector` +
    /// `openFile`）。移动端无原生侧，不 mock 的话会抛
    /// MissingPluginException 并被 `pickFilesForOverlay` 静默吞成空列表——
    /// 用例会以「没添加任何附件」的形式失败，而看不出根因。
    void mockFileSelector(WidgetTester tester, List<String> paths) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' ? paths : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });
    }

    testWidgets('/overlay 渲染带附件的输入窗（附件入口可用，不带标签栏）', (tester) async {
      final h = await pumpApp(tester);

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('overlay-input')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overlay-attach')),
        findsOneWidget,
        reason: '移动端无拖拽，但有系统文件选择器——这个入口必须存在',
      );
      // 移动端注入 NoopDragDropCapability（不伪造拖拽），故不展示拖拽区。
      // 但附件功能不受影响：按钮走 pickFilesForOverlay。
      expect(find.textContaining('拖入'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing, reason: '整屏临时页不应占据标签分支');
    });

    testWidgets('点「添加文件」→ 选中的文件进入待发列表', (tester) async {
      final tmp = makeTempFile('报告.pdf');
      mockFileSelector(tester, [tmp.file.path]);
      final h = await pumpApp(tester);

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('overlay-attach')));
      // ⚠️ 必须 runAsync：`_addFiles` 里的 `f.length()` 是真实文件 I/O，
      // 而 testWidgets 跑在 fake async 里，真实 I/O 的 Future 不会被推进。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('报告.pdf'),
        findsOneWidget,
        reason: '选中的文件必须出现在附件列表（说明文件选择器接线生效）',
      );
    });

    testWidgets('带附件提交 → 上传得 file_id 后入队（wire 契约 file_id 必填）', (tester) async {
      final tmp = makeTempFile('截图.png');
      mockFileSelector(tester, [tmp.file.path]);

      // 捕获入队请求体：断言带的是 **file_id**（服务端生成的句柄），
      // 而不是展示用的文件名——后者是历史上出过的错（见 use case 类文档）。
      Map<String, dynamic>? enqueueBody;

      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onPost(
            '/me/quick-capture/attachments',
            (server) => server.reply(201, {
              'file_id': 'ufs_file_abc',
              'file_name': '截图.png',
              'size': 32,
              'mime_type': 'image/png',
            }),
            data: Matchers.any,
          );
          adapter.onPost(
            '/me/quick-capture/enqueue',
            (server) => server.reply(202, {'accepted': true}),
            data: Matchers.any,
          );
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/me/quick-capture/enqueue')) {
              enqueueBody = options.data is Map
                  ? Map<String, dynamic>.from(options.data as Map)
                  : null;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.overlay);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('overlay-attach')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      // 只有附件、无文本，也应可提交。
      await tester.tap(find.byKey(const ValueKey('overlay-submit')));
      // ⚠️ 必须 runAsync：提交走 `MultipartFile.fromFile`，从磁盘**真实读**
      // 文件；fake async 不会推进这类 I/O，pumpAndSettle 会一直等到超时。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(enqueueBody, isNotNull, reason: '提交必须真的发出入队请求（否则附件上传了却没投递）');
      expect(enqueueBody!['attachments'], [
        'ufs_file_abc',
      ], reason: '附件必须用服务端返回的 file_id 作句柄，而不是文件名或路径');
    });
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

    testWidgets('工作台新建：POST /chat/miniapp/works 后进入新工作详情', (tester) async {
      // 端到端验证 router 把「点新建」接到了真实端点，且拿到返回的 workId 导航。
      Map<String, dynamic>? createBody;
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          adapter.onPost(
            '/chat/miniapp/works',
            (server) => server.reply(201, {
              'work': {
                'id': 'grp_new',
                'title': '新会话',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
                'steps': <Map<String, dynamic>>[],
                'pending_confirmations': <Map<String, dynamic>>[],
                'artifacts': <Map<String, dynamic>>[],
                'recent_events': <Map<String, dynamic>>[],
                'can_send_message': true,
                'can_stop': true,
                'can_complete': true,
              },
              'dispatch': null,
            }),
            data: Matchers.any,
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_new',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_new',
                'title': '新会话',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
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
            '/chat/miniapp/works/grp_new/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_new/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.endsWith('/chat/miniapp/works') &&
                options.method == 'POST') {
              createBody = options.data is Map
                  ? Map<String, dynamic>.from(options.data as Map)
                  : null;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byKey(const ValueKey('miniapp-works-create')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(createBody, isNotNull, reason: '必须真的发出新建请求');
      expect(
        createBody!.containsKey('template_id'),
        isFalse,
        reason: '服务端 template_id 可选；传空会让 metadata 里多一个无意义的空值',
      );
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_new'),
        reason: '新建后应进入新工作详情（新工作标题是占位符，列表里分不出来）',
      );
    });

    testWidgets('工作详情上传：multipart 打到 /works/:id/files，字段名为 file', (
      tester,
    ) async {
      // 断言真实请求形状：服务端 `c.FormFile("file")`，字段名不对会 400
      // 「缺少 file」。这是「上传按钮存在」之外的实质验证。
      final tmp = Directory.systemTemp.createTempSync('mobile-work-upload');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/报告.pdf')
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/file_selector'),
        (call) async => call.method == 'openFile' ? [file.path] : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/file_selector'),
          null,
        );
      });

      String? uploadPath;
      Object? uploadBody;
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          // ⚠️ 三个 GET 必须也 mock：详情页并发拉 detail/events/artifacts，
          // 任一失败就进错误分支（那棵树里**没有**上传按钮），
          // 于是 `tap` 找不到目标、上传链路根本不会触发。
          adapter.onGet(
            '/chat/miniapp/works/grp_up',
            (server) => server.reply(200, {
              'work': {
                'id': 'grp_up',
                'title': '上传用工作',
                'status': 'running',
                'status_label': '运行中',
                'progress': {'total': 0, 'completed': 0, 'percent': 0},
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
            '/chat/miniapp/works/grp_up/events',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 100},
          );
          adapter.onGet(
            '/chat/miniapp/works/grp_up/artifacts',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          );
          adapter.onPost(
            '/chat/miniapp/works/grp_up/files',
            (server) => server.reply(201, {
              'work_id': 'grp_up',
              'artifact': {
                'id': 'a1',
                'work_id': 'grp_up',
                'name': '报告.pdf',
                'type': 'document',
                'mime_type': 'application/pdf',
                'size_bytes': 4,
                'preview_mode': '',
              },
              'upload': {'relative_path': '报告.pdf'},
            }),
            data: Matchers.any,
          );
        },
      );
      h.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('/files')) {
              uploadPath = options.path;
              uploadBody = options.data;
            }
            handler.next(options);
          },
        ),
      );

      h.router.go(SpbRoutes.work('grp_up'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      // ⚠️ 整条链路必须在**一个** runAsync 里：平台通道与文件 I/O 只在真实
      // 时区完成；把 tap 留在 FakeAsync 时区会让 await 永远不推进
      // （实测 uploadPath 恒为 null，且页面不报错）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('miniapp-work-upload')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(
        uploadPath,
        contains('/chat/miniapp/works/grp_up/files'),
        reason: 'workId 必须来自路由参数（family 键写错会打到别的 work）',
      );
      expect(
        uploadBody,
        isA<FormData>(),
        reason: '必须是 multipart（服务端 c.FormFile 读 multipart 表单）',
      );
      final form = uploadBody! as FormData;
      expect(
        form.files.map((e) => e.key),
        contains('file'),
        reason: '字段名必须叫 file，否则服务端 400「缺少 file」',
      );
    });

    testWidgets('/miniapp/works 与 /miniapp/works/:workId 不互相抢匹配', (
      tester,
    ) async {
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

  testWidgets('对话列表新建入口：POST /chat/groups 后进入新对话', (tester) async {
    final h = await pumpApp(
      tester,
      sseClient: _FakeSseClient(),
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

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '新对话',
    );
    // 必须 pump 一帧让确认按钮解除禁用（见 GroupListPage 测试里的说明）。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-create-confirm')));

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
        sseClient: _FakeSseClient(),
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

  testWidgets('设置页「默认 Agent」下拉拿到真实 agent 列表（调用点传参）', (tester) async {
    // ## 这个用例防的是什么
    //
    // 与桌面端同名用例同一取向：`preferenceAgentOptions` 默认 `const []`，
    // 此前两端调用点都没传（全仓 grep 零命中），用户在下拉里永远只能选到
    // 「自动」。面板测试用手工 options，抓不到「router 忘了传」。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(
      tester,
      loadAgents: () async => const [
        Agent(id: 'agent_a', name: '写作助手'),
        Agent(id: 'agent_b', name: '代码助手'),
      ],
      beforePump: (adapter) {
        adapter.onGet(
          '/me/preferences',
          (server) => server.reply(200, {
            'reply_language': 'auto',
            'available_languages': ['auto', 'zh-CN'],
            'language_labels': {'auto': '跟随输入', 'zh-CN': '简体中文'},
            'default_agent_id': '',
            'display_name': '',
            'avatar_url': '',
          }),
        );
      },
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings-prefs-default-agent')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('写作助手'),
      findsWidgets,
      reason: '调用点必须传 preferenceAgentOptions，否则下拉里永远只有「自动」',
    );
    expect(find.text('代码助手'), findsWidgets);
  });

  testWidgets('移动端设置页展示固定沙箱目录（用户需知道文件落在哪）', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('/app/deliverables'), findsOneWidget);
  });

  testWidgets('设置页通知订阅：读真实端点并按服务端返回回显', (tester) async {
    // 端到端验证 router 把 provider 接到了真实端点（只断言页面渲染会漏掉
    // 「provider 绑错方法」这类缺陷）。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(
      tester,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/miniapp/notifications/subscriptions',
          (server) => server.reply(200, {
            'items': [
              {'template_key': 'notify', 'remaining_quota': 4, 'enabled': true},
            ],
          }),
        );
      },
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-notification-notify')),
      findsOneWidget,
    );
    expect(find.text('剩余 4 条'), findsOneWidget, reason: '必须回显服务端额度，而不是本地猜一个');
  });

  testWidgets('设置页通知订阅：切换开关打到 POST 且 body 只含白名单 key', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Map<String, dynamic>? savedBody;
    final h = await pumpApp(
      tester,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/miniapp/notifications/subscriptions',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        );
        adapter.onPost(
          '/chat/miniapp/notifications/subscriptions',
          (server) => server.reply(200, {
            'items': [
              {'template_key': 'notify', 'remaining_quota': 1, 'enabled': true},
            ],
          }),
          data: Matchers.any,
        );
      },
    );
    h.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/notifications/subscriptions') &&
              options.method == 'POST') {
            savedBody = options.data is Map
                ? Map<String, dynamic>.from(options.data as Map)
                : null;
          }
          handler.next(options);
        },
      ),
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings-notification-notify')),
    );
    await tester.pumpAndSettle();

    expect(savedBody, isNotNull, reason: '必须真的发出保存请求');
    expect(savedBody!['accepted'], {'notify': 1});
    expect(
      MiniappNotificationTemplates.isKnown(
        (savedBody!['accepted'] as Map).keys.first as String,
      ),
      isTrue,
      reason: '未知 key 服务端整体 400，客户端不得自造',
    );
  });

  testWidgets('移动端设置页保存走注入的 saveSyncSettings', (tester) async {
    // 设置页是 ListView，**惰性构建**：屏幕外的条目在树里根本不存在。
    // 新增「外观」区块后页面变高，默认 800×600 下媒体开关已落到屏幕外
    // → find 不到（与同文件其它设置页用例同一处理）。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SyncSettings? saved;
    final h = await pumpApp(tester, saveSyncSettings: (s) async => saved = s);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-include-media')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect(saved!.filter.includeMedia, isTrue);
  });

  testWidgets('主题模式：默认跟随系统，切换后即时生效并落盘', (tester) async {
    // 端到端验证三件事：① 默认 themeMode 是 system（改动前行为）；② 在设置页
    // 选「深色」后 MaterialApp 立刻变；③ 值真的写进了偏好库（不是只改内存）。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(tester, mockGroups: false);

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
      reason: '未设置过时必须跟随系统',
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-theme-dark')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
      reason: '选中即生效——主题是即时反馈项，不该等「保存」按钮',
    );
    expect(h.container.read(themeModeProvider), ThemeMode.dark);

    // 落盘：直接读偏好库，证明不是只改了内存。
    final stored = await h.container
        .read(preferencesStoreProvider)
        .getString(SpbThemeMode.prefKey);
    expect(
      stored,
      SpbThemeMode.encode(ThemeMode.dark),
      reason: '必须持久化，否则重启后设置丢失',
    );
  });

  testWidgets('主题模式：启动时从偏好库恢复（重启后不丢）', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(tester, mockGroups: false);

    // 模拟「上次设过深色」：直接写偏好，再让 notifier 重读。
    await h.container
        .read(preferencesStoreProvider)
        .setString(SpbThemeMode.prefKey, SpbThemeMode.encode(ThemeMode.light));
    await h.container.read(themeModeProvider.notifier).restore();
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
      reason: '恢复的是偏好里的值，而不是恒为 system',
    );
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

  group('习惯（移动端接线）', () {
    /// `/api/habits` 列表项（sqlc camelCase 形态）。
    Map<String, dynamic> habitJson({
      String id = 'hp_1',
      String topicKey = 'weekly-report',
    }) => {
      'id': id,
      'userId': 'usr_1',
      'originGroupId': 'grp_1',
      'topicKey': topicKey,
      'triggerType': 'time_based',
      'triggerConfigJson': '{"weekday":[1],"times":[{"hour":9,"minute":0}]}',
      'acceptanceLevel': 'suggest_only',
      'sourceType': 'manual',
      'status': 'active',
      'triggerCount': 2,
      'confidence': 0.5,
      'nextFireAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    };

    testWidgets('对话列表点「习惯」进入习惯页（挂在对话标签的栈下）', (tester) async {
      // 端到端验证 router 把 onOpenHabits 接到真实路由与两个端点。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/api/habits',
            (server) => server.reply(200, {
              'items': [habitJson()],
            }),
            queryParameters: {'limit': 50, 'offset': 0},
          );
          adapter.onGet(
            '/api/habits/runs',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'limit': 50},
          );
        },
      );

      await tester.tap(find.byKey(const ValueKey('group-list-habits')));
      await tester.pumpAndSettle();

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.habits,
        reason: '点习惯入口必须真的导航到习惯页，否则入口是摆设',
      );
      expect(find.text('weekly report'), findsOneWidget);
      // 挂在 shell 内（对话标签的栈），故底部标签栏仍在。
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('任务编辑接线（updateTask 走真实 router 装配）', () {
    /// 断言移动端的底部弹层真的把 `onUpdateTask` 接上了。
    ///
    /// 与桌面端同名用例同一取向：面板自身测试用手工回调，无法发现「router
    /// 忘了注入」——而那正是本仓库最常见的失败模式（`updateTask` 此前全仓
    /// 零引用）。故这里打 HTTP 断言请求真的发出去了。
    testWidgets('任务清单弹层里点编辑改标题保存 → PATCH 带新标题', (tester) async {
      final patch = <({String path, Object? body})>[];
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
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
              'current_goal': {
                'goal': {
                  'id': 'goal_1',
                  'group_id': 'grp_x',
                  'goal_text': '把 CI 修绿',
                  'status': 'active',
                  'tasks_source': 'manual',
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
                'tasks': [
                  {
                    'id': 'row_1',
                    'goal_id': 'goal_1',
                    'task_id': 'TASK-001',
                    'order_index': 0,
                    'title': '旧标题',
                    'description': '',
                    'status': 'pending',
                    'origin': 'llm',
                    'edited_by_user': false,
                    'created_at': '2024-03-05T08:00:00Z',
                    'updated_at': '2024-03-05T08:00:00Z',
                  },
                ],
                'progress': {
                  'total': 1,
                  'completed': 0,
                  'in_progress': 0,
                  'blocked': 0,
                  'error_stopped': 0,
                  'pending': 1,
                  'percent': 0,
                },
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
          adapter.onPatch(
            '/chat/goals/goal_1/tasks/TASK-001',
            (server) => server.replyCallback(200, (options) {
              patch.add((path: options.path, body: options.data));
              return {
                'task': {
                  'id': 'row_1',
                  'goal_id': 'goal_1',
                  'task_id': 'TASK-001',
                  'order_index': 0,
                  'title': '新标题',
                  'description': '',
                  'status': 'pending',
                  'origin': 'llm',
                  'edited_by_user': true,
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
              };
            }),
            data: Matchers.any,
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // 打开任务清单底部弹层。
      await tester.tap(find.byKey(const ValueKey('open-goal-tasks')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('goal-task-edit-TASK-001')),
        findsOneWidget,
        reason: '未注入 onUpdateTask 时该按钮整个不渲染',
      );

      await tester.tap(find.byKey(const ValueKey('goal-task-edit-TASK-001')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('goal-task-edit-title')),
        '新标题',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('goal-task-edit-save')));
      await tester.pumpAndSettle();

      expect(patch, hasLength(1), reason: 'updateTask 必须真的发出请求');
      expect(patch.single.path, '/chat/goals/goal_1/tasks/TASK-001');
      final body = patch.single.body as Map<String, dynamic>;
      expect(body['title'], '新标题');
      expect(body['description'], '');
      expect(tester.takeException(), isNull);
    });
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
        signInAction: () async =>
            'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
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

  testWidgets('对话页停止生成：router 把 turnId 接到 POST /chat/turns/:id/cancel', (
    tester,
  ) async {
    // 只验证 **router 的接线**：直接取树上 `ConversationPage` 的回调调一下，
    // 不依赖 SSE 事件（原因见桌面端同一用例的说明：`_focus` 用 `ref.read`、
    // `build` 用 `ref.watch`，对 autoDispose.family 而言不是同一实例，是既有 bug）。
    // 「何时可点、传哪个 turnId」由 spb_features 的测试覆盖。
    final hitPaths = <String>[];
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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
        // `replyCallback` 只在**请求真的到达**时被调用，因此记录的路径就是
        // 实际发出的请求（`adapter.history` 存的是**已注册的 mock**）。
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

    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onCancelTurn,
      isNotNull,
      reason: 'router 必须注入 onCancelTurn，否则页面上不会出现停止按钮',
    );

    // 必须包在 `runAsync` 里：回调内部 await 一个 dio 请求，在 FakeAsync 时区
    // 直接 await 会死锁（dio 的 mock 响应靠真实事件循环完成）。
    await tester.runAsync(() => page.onCancelTurn!('turn_9'));
    await tester.pump();

    expect(hitPaths, [
      '/chat/turns/turn_9/cancel',
    ], reason: 'turnId 必须原样透传到路径，且只发一次请求');
  });

  testWidgets('对话页归属反馈：router 把 token 接到 POST /chat/feedback/:token/resolve', (
    tester,
  ) async {
    // 只验证 **router 的接线**（理由同上一条「停止生成」用例）。
    // 移动端与桌面端共用同一条回执语义：可视化渠道直接解决，不经消息通道。
    final hit = <(String, Object?)>[];
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.chat('grp_x'),
      mockGroups: false,
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
      page.onResolveFeedback!('tok_fb1', false);
      // onResolveFeedback 返回 void（页面内 fire-and-forget），真实 dio 往返
      // 需要真实事件循环跑完——短 delay 会拿不到请求。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(hit, hasLength(1), reason: '必须真的发出一次回执请求');
    expect(hit.single.$1, '/chat/feedback/tok_fb1/resolve');
    expect(hit.single.$2, containsPair('correct', false));
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

  testWidgets('对话页重连：router 注入 onReconnect 且打到同一条 SSE 连接', (tester) async {
    // 只验证 **router 的接线**：注入的 onReconnect 必须调用**已连接的那个**
    // 控制器的 reconnect()。
    //
    // ## 这条用例抓不住什么（已实测，勿误信）
    //
    // 它**抓不住**「family 键写错成 groupId」：`sseClientProvider` 是跨对话共享
    // 的单例，`reconnect()` 最终就是 `_sse.resume()`，而共享 client 上确实有
    // `_path`——换哪个 family 条目都能连通。故这里不宣称覆盖该场景；键的正确性
    // 靠「注入点与 `ref.watch` 在同一 build 里取自同一变量」来保证（见 router 注释）。
    final sse = _FakeSseClient();
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
    ], reason: '前置条件：必须先真的连上，否则 resume 会早退');

    final page = tester.widget<ConversationPage>(find.byType(ConversationPage));
    expect(
      page.onReconnect,
      isNotNull,
      reason: 'router 必须注入 onReconnect，否则指示器永远不可点',
    );

    page.onReconnect!();
    await tester.pump();

    expect(
      sse.resumeCount,
      1,
      reason: '必须打到已连接的那个控制器（family 键应为 userId，不是 groupId）',
    );
  });

  testWidgets('设置页退出登录：确认后清凭证并回登录页', (tester) async {
    // 端到端验证「点退出 → 清凭证 → 状态变未登录 → 回到登录页」。
    //
    // 用 `InMemoryTokenStore.clearCount` 作观测点：它证明**凭证真的被清了**，
    // 而不只是路由跳走了（后者可能是别的原因导致的重定向）。
    // 设置页是 ListView，**惰性构建**：屏幕外的条目在树里根本不存在，
    // 而「退出登录」在最底部。默认 800×600 下必然在屏幕外 → find 不到。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = InMemoryTokenStore(_freshTokens());
    final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    // 前置条件：确实处于已登录态。少了这一句，整条用例可能**空洞通过**
    // ——若从未登录过，登出照样清凭证、照样回登录页，断言全中但没有意义。
    expect(
      h.container.read(authStateProvider).isAuthenticated,
      isTrue,
      reason: '前置条件：必须先处于已登录态，否则本用例空洞通过',
    );

    await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-sign-out-confirm')));
    await tester.pumpAndSettle();

    expect(store.clearCount, 1, reason: '必须真的清掉本地凭证');
    expect(
      h.container.read(authStateProvider).isAuthenticated,
      isFalse,
      reason: '状态必须变为未登录',
    );
    expect(
      h.router.state.matchedLocation,
      SpbRoutes.login,
      reason: '登出后必须回到登录页',
    );
  });

  testWidgets('设置页退出登录：取消则保留凭证且留在设置页', (tester) async {
    // 同上：底部条目需要更高的测试窗口才会被构建。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final store = InMemoryTokenStore(_freshTokens());
    final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(store.clearCount, 0, reason: '取消绝不能清凭证');
    expect(h.container.read(authStateProvider).isAuthenticated, isTrue);
    expect(h.router.state.matchedLocation, SpbRoutes.settings);
  });

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
      final fakePlatform = _FakeSecureStoragePlatform();
      FlutterSecureStoragePlatform.instance = fakePlatform;
      addTearDown(() {
        FlutterSecureStoragePlatform.instance = _FakeSecureStoragePlatform();
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
}
