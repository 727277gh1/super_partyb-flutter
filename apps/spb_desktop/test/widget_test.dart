import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:path/path.dart' as p;

import 'package:drift/native.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/app.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/router.dart';

/// 测试环境句柄：把 pumpApp 内部创建的 dio / adapter / router 暴露给用例。
///
/// ## 为什么必须由 pumpApp 创建 adapter 并返回
///
/// 初版让用例自己 `DioAdapter(dio: ...)` 再传进 pumpApp，结果 mock 全部不命中
/// ——`DioAdapter` 是绑定到**某个具体 dio 实例**的，而 pumpApp 内部另建了一个
/// dio 并 override 给了 `dioProvider`。两个 adapter 各挂各的 dio，
/// 用例注册的 mock 永远不会被使用（表现为请求真实发出、测试超时 10 分钟）。
/// 故 adapter 必须在 pumpApp 内部创建并交回用例。
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

/// 假的 [SseClient]：记录收到的 path，不连网、不重试。
///
/// ## 为什么必须注入它
///
/// 进入 `/chat/:groupId` 会挂载 `ConversationPage`，其控制器调
/// `SseClient.connect` 发真实长连接请求。测试环境下这必然失败，而真实现会
/// **按指数退避安排重连定时器**，测试结束时留下 pending Timer，flutter_test
/// 直接报「A Timer is still pending even after the widget tree was disposed」。
///
/// 用真 SseClient + mock adapter 解决不了：SSE 走 `ResponseType.stream`，
/// `DioAdapter` 不模拟流式响应，仍会落到失败/重试路径。
class _FakeSseClient extends SseClient {
  _FakeSseClient()
    : super(dio: Dio(), baseUrl: 'https://fake.invalid', maxRetries: 0);

  final framesController = StreamController<SseFrame>.broadcast();
  final statesController = StreamController<SseState>.broadcast();

  /// `connect` 收到的全部 path（按调用顺序）。
  ///
  /// 这是 issue #2 的观测点：修复前这里是 `/users//chat/stream`（空 userId），
  /// 修复后必须是 `/users/<真实 id>/chat/stream`。
  final connectedPaths = <String>[];

  @override
  Stream<SseFrame> get frames => framesController.stream;

  @override
  Stream<SseState> get states => statesController.stream;

  @override
  SseState get state => SseState.connected;

  @override
  Future<void> connect({required String path}) async {
    connectedPaths.add(path);
    _hasPath = true;
  }

  /// `resume` 被调用的次数。
  int resumeCount = 0;

  /// 是否已经 `connect` 过（同真实 `SseClient._path != null`）。
  bool _hasPath = false;

  /// 复刻真实 `resume()` 的 `if (_path == null) return;` 早退。
  ///
  /// 本用例**不**依赖它来抓「family 键写错」（那件事靠共享 SseClient 兜住了，
  /// 见用例注释）；但 fake 仍应与真实实现同构——否则将来 `resume` 增加前置条件
  /// 时，测试会给出与生产不符的结论。
  @override
  Future<void> resume() async {
    if (!_hasPath) return;
    resumeCount++;
  }

  @override
  void recordEventId(String eventId) {}

  /// 推一帧（camelCase，同 `chatbus.Event` 的 SSE 形态）。
  ///
  /// 手写极简 JSON 编码而不是 import `dart:convert`：本文件已 import `dart:io`
  /// （它的 `jsonEncode` 不在此），而 payload 只含字符串/数字/列表，无需完整
  /// 实现。（移动端同名 fake 有同一处 helper。）
  void push(String event, Map<String, dynamic> data) {
    framesController.add(SseFrame(event: event, data: _encode(data), id: null));
  }

  static String _encode(Map<String, dynamic> m) =>
      '{${m.entries.map((e) => '"${e.key}":${_jsonValue(e.value)}').join(',')}}';

  static String _jsonValue(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) {
      final escaped = v
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n');
      return '"$escaped"';
    }
    if (v is List) return '[${v.map(_jsonValue).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${_jsonValue(e.value)}').join(',')}}';
    }
    return '"$v"';
  }

  @override
  Future<void> dispose() async {
    await framesController.close();
    await statesController.close();
  }
}

/// 启动测试用 app，注入全部 fake provider（**禁止真实网络**）。
///
/// ## 为什么必须 override 这几个 provider
///
/// `chatApiProvider` / `currentUserProvider` 若用默认实现，会向
/// `SpbEnv.apiBaseUrl`（默认 `127.0.0.1:8000`）发真实请求——测试环境里
/// 那是一次必然失败的真实网络调用，既慢又依赖环境。故：
///
/// - `dioProvider` → 换成挂了 `DioAdapter` 的 dio（响应可控）；
/// - `chatApiProvider` / `sseClientProvider` 自动随之指向 mock；
/// - `desktopCapabilitiesProvider` → 空实现（测试环境无真实窗口/托盘）。
///
/// ## 为什么要默认 mock `/chat/groups`
///
/// 首页（`GroupListPage`）挂载即发请求。若不 mock，会留下未结算的 Timer，
/// flutter_test 直接报「A Timer is still pending even after the widget tree
/// was disposed」。
///
/// ## 为什么用 `UncontrolledProviderScope` + 显式 container
///
/// 路由的 `refreshListenable`（认证状态变化时重跑守卫）来自 Riverpod 容器，
/// 而它必须在 `pumpWidget` **之前**就存在才能传给 `GoRouter`。若用
/// `ProviderScope`（内部自建容器），测试拿不到容器也就拿不到 listenable，
/// 于是「凭证恢复完成 → 重跑守卫」这条链路永远不会被触发——表现为
/// 「未登录用户停在首页」。故显式建容器再交给 `UncontrolledProviderScope`。
Future<TestHarness> pumpApp(
  WidgetTester tester, {
  String initialLocation = SpbRoutes.home,
  bool mockGroups = true,
  SseClient? sseClient,
  TokenStore? tokenStore,
  Future<String?> Function()? signInAction,
  void Function(DioAdapter adapter)? beforePump,

  /// 目录选择器（同步页用）。默认「用户取消」。
  PickSyncDirectory? pickDirectory,

  /// 同步动作（同步页用）。默认返回空报告。
  RunSyncAction? runSync,

  /// 同步目录初始值（同步页用）。默认未选。
  String? syncLocalRoot,

  /// 测试用数据库。默认在内存库上新建。
  ///
  /// 需要预置**同步状态 / 目录绑定**的用例传入自己 seed 过的实例——
  /// 见「已同步则直接打开」用例：它要在库里写入 workspace 布局的已同步记录，
  /// 才能让 `deliverableLocalIndexProvider` 真的读到东西。
  AppDatabase? database,

  /// 设置页注入点：读取设置。默认「未选目录 + 全部范围」。
  LoadSyncSettings? loadSyncSettings,

  /// 设置页注入点：保存设置。
  SaveSyncSettings? saveSyncSettings,

  /// 设置页注入点：对话列表（同步范围勾选用）。
  LoadSyncGroups? loadSyncGroups,

  /// 设置页注入点：本地扫描（清理与统计用）。
  ScanLocalGroups? scanLocalGroups,

  /// 设置页注入点：执行清理。
  ExecutePrune? executePrune,

  /// 平台能力。默认空实现（不展示桌面集成项）。
  DesktopCapabilities? capabilities,

  /// 搜索实现（搜索页用）。默认返回空结果。
  SearchChat? searchChat,

  /// 是否注册默认的 `/chat/confirmations` mock。
  ///
  /// 需要**计数**该端点请求次数的用例（角标自动刷新）传 false 并自己在
  /// `beforePump` 里注册计数版——否则默认 mock 会覆盖它（见该处注释）。
  bool mockPendingConfirmations = true,

  /// 可选 agent 列表（对话页 AppBar 的 agent 切换入口用）。
  ///
  /// ## 为什么必须默认 override，不能让它走真实实现
  ///
  /// 真实实现走 dio → DioAdapter 未注册 `/api/agents` 路由 → 连接被拒后
  /// dio 会起重试/超时 Timer，flutter_test 直接报「A Timer is still pending
  /// even after the widget tree was disposed」（与 `sseClient` 同一问题，
  /// 见上方注释）。
  ///
  /// 默认空列表会让切换入口**隐藏**（`AgentSwitcher` 对空列表即不渲染），
  /// 于是既有用例的 AppBar 宽度不变。需要断言切换入口的用例显式传自己的列表。
  LoadAgents? loadAgents,

  /// UFS API（交付物侧边栏用）。默认不 override：侧边栏默认不展开，
  /// 用不到的用例不应被它拖慢。
  UfsApi? ufsApi,

  /// 「诊断」tab 的门控开关。默认不 override（即 `!SpbEnv.isRelease`）。
  ///
  /// 测试跑在 JIT 下，`SpbEnv.isRelease` 恒为 false → 诊断 tab 默认**可见**，
  /// 与既有用例的期望一致。要验证发布包行为（tab 消失）的用例显式传 false
  /// ——这正是把门控做成 provider 而非直接判 `isRelease` 的理由。
  bool? showDebugPanel,
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

  if (mockGroups) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
  }
  // 待确认角标 provider 在首页首帧即拉取，与 mockGroups 无关（即使列表不 mock，
  // 角标 provider 仍会触发）。无条件 mock 以免留下未结算 Timer。
  //
  // 可关掉：需要**计数**该端点请求次数的用例（角标自动刷新）要在
  // `beforePump` 里注册自己的 mock，而本默认值注册在 `beforePump` **之后**
  // 会把它覆盖掉——那样计数永远是 0，用例会以与实现无关的理由失败。
  if (mockPendingConfirmations) {
    adapter.onGet(
      '/chat/confirmations',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'status': 'pending', 'limit': 50},
    );
  }

  final container = ProviderContainer(
    overrides: [
      desktopCapabilitiesProvider.overrideWithValue(
        capabilities ?? const NoopDesktopCapabilities(),
      ),
      dioProvider.overrideWithValue(dio),
      // 默认注入「已登录」的内存存储：
      //
      // 否则 `authStateProvider.restore()` 会读真实的 `SecureTokenStore`
      // （走 flutter_secure_storage 平台通道，测试环境必然抛
      // MissingPluginException），得到「未登录」后被守卫重定向到 /login
      // ——那么所有期望「首页渲染对话列表」的用例都会失败，而失败原因
      // 与被测行为无关。需要测未登录的用例显式传空存储。
      tokenStoreProvider.overrideWithValue(
        tokenStore ?? InMemoryTokenStore(_freshTokens()),
      ),
      // 真实实现要开系统浏览器，测试里换成可控的假实现。
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
      // 内存库：真实的 appDatabaseProvider 会在 ~/.local/share 下建文件，
      // 让测试污染开发者的同步状态（且用例之间互相干扰）。
      appDatabaseProvider.overrideWith((ref) {
        final db = database ?? AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      // 同步页的两个注入点：默认「取消 + 空报告」，需要断言的用例显式传。
      pickDirectoryProvider.overrideWithValue(
        pickDirectory ?? ({String? title}) async => null,
      ),
      runSyncActionProvider.overrideWithValue(
        runSync ?? () async => SyncReport(),
      ),
      // 设置页的注入点：全部换成可控假实现（真实的会读库/走网络/扫磁盘）。
      loadSyncSettingsProvider.overrideWithValue(
        loadSyncSettings ?? () async => SyncSettings(localRoot: syncLocalRoot),
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
      // 搜索页的注入点：真实实现要 /api/auth/me + 网络，测试里换成假实现。
      searchChatProvider.overrideWithValue(
        searchChat ?? (query, {int? limit}) async => const [],
      ),
      // 见 `loadAgents` 参数的说明：不 override 会留下未结算的 Timer。
      loadAgentsProvider.overrideWithValue(
        loadAgents ?? () async => const <Agent>[],
      ),
      if (ufsApi != null) ufsApiProvider.overrideWithValue(ufsApi),
      // 仅显式传值时 override：默认走 provider 自己的 `!SpbEnv.isRelease`。
      if (showDebugPanel != null)
        showDebugPanelProvider.overrideWithValue(showDebugPanel),
      // 初始目录：写进内存库的绑定表，让 syncLocalRootProvider 读得到。
      if (syncLocalRoot != null)
        syncLocalRootProvider.overrideWith((ref) async => syncLocalRoot),
    ],
  );
  addTearDown(container.dispose);

  // 路由必须在 pumpWidget 前建好，测试才能主动导航。
  //
  // 带上**与生产一致**的认证守卫与 refreshListenable：这样
  // 「未认证被重定向到 /login」与「凭证恢复后重跑守卫」在测试里真跑，
  // 而不是测一个与生产不同的路由表。
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: buildDesktopRoutes(),
    redirect: buildAuthRedirect(),
    refreshListenable: container.read(authRefreshListenableProvider),
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: SpbDesktopApp(router: router),
    ),
  );
  // 推进假时钟：让 dio mock 的 Timer 触发（不能用 runAsync，见
  // packages/spb_features/test/chat/group_list_page_test.dart 的说明）。
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

/// `UfsApi` 的内存桩：记录 `listFiles` 调用并返回可配条目。
///
/// 用子类重写而不是 mock 框架：`UfsApi` 的方法都是虚方法，重写 `listFiles`
/// 即可，无需引入 mockito 依赖，也不依赖 dio。
class _FakeUfsApi extends UfsApi {
  _FakeUfsApi() : super(Dio());

  List<UfsFileEntry> entries = const [];

  /// `listFiles` 收到的 `pathPrefix`（按调用顺序）。
  final listCalls = <String?>[];

  /// `download` 收到的 file id（按调用顺序）。
  ///
  /// 用来断言「已同步的交付物不触发下载」——只断言打开路径还不够：实现若先
  /// 下载再打开，路径可能看起来也对（取决于实现），但多了一次网络请求。
  final downloadCalls = <String>[];

  @override
  Future<UfsDownload> download(String fileId, {String? ifNoneMatch}) async {
    downloadCalls.add(fileId);
    return UfsDownload(
      notModified: false,
      bytes: const [1, 2, 3],
      etag: 'W/"test"',
    );
  }

  @override
  Future<UfsFilePage> listFiles({
    String? pathPrefix,
    String? updatedSince,
    bool includeDeleted = false,
    List<String> excludePrefix = const [],
    int page = 1,
    int pageSize = 20,
    String ownerType = 'user',
  }) async {
    listCalls.add(pathPrefix);
    return UfsFilePage(items: entries, total: entries.length);
  }
}

/// 构造一条 UFS 条目（路径按 group workspace 前缀拼）。
UfsFileEntry _ufsFile(String gid, String rel, {String? id}) =>
    UfsFileEntry.fromJson({
      'id': id ?? 'uf-$rel',
      'path': '/workspace/groups/$gid/$rel/',
      'size': 1024,
      'name': rel.split('/').last,
      'mime_type': 'text/markdown',
      'is_directory': false,
      'updated_at': '2026-01-01T00:00:00Z',
    });

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
        child: SpbDesktopApp(router: router),
      ),
    );
    // 推进假时钟让 dio mock 的 Timer 触发。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('测试对话'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
  });

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

  testWidgets('/settings 渲染完整设置页（含同步入口与各配置项）', (tester) async {
    // 设置页是 ListView，**惰性构建**：屏幕外的条目在树里根本不存在。
    // 新增「外观」区块后页面变高，默认 800×600 下底部的清理入口已落到屏幕外
    // → find 不到（与同文件其它设置页用例同一处理）。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-sync-entry')),
      findsOneWidget,
      reason: '桌面端的核心差异价值是交付物同步，必须有入口',
    );
    // 占位页时代只有「待接入」文案；现在是可操作的配置项。
    expect(
      find.byKey(const ValueKey('settings-pick-directory')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-scope-all')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-include-media')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-max-file-size')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-since-days')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-prune')), findsOneWidget);
  });

  testWidgets('设置页展示从注入读到的目录', (tester) async {
    final h = await pumpApp(tester, syncLocalRoot: '/home/u/out');

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.text('/home/u/out'), findsOneWidget);
  });

  testWidgets('设置页保存走注入的 saveSyncSettings（整份提交）', (tester) async {
    SyncSettings? saved;
    final h = await pumpApp(
      tester,
      syncLocalRoot: '/home/u/out',
      saveSyncSettings: (s) async => saved = s,
    );

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-include-media')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.filter.includeMedia, isTrue);
    expect(saved!.localRoot, '/home/u/out');
  });

  testWidgets('桌面端（真实能力）展示桌面集成项', (tester) async {
    // ## 为什么要把测试窗口调高
    //
    // 设置页是 ListView，**惰性构建**：屏幕外的条目在 widget 树里根本不存在，
    // `find.byKey` 找不到。桌面集成区块排在最后一个分节，默认 800×600 的
    // 测试窗口下必然在屏幕外。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 桌面端注入的是 isSupported=true 的能力实现，故应展示托盘/快捷键区块。
    final h = await pumpApp(tester, capabilities: _FakeDesktopCapabilities());

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-capabilities')), findsOneWidget);
    // 移动端不展示这一段（见 spb_features 的设置页用例）。
    expect(find.text('系统托盘'), findsOneWidget);
  });

  testWidgets('设置页「默认 Agent」下拉拿到真实 agent 列表（调用点传参）', (tester) async {
    // ## 这个用例防的是什么
    //
    // `SettingsPage.preferenceAgentOptions` 默认是 `const []`，此前两端调用点
    // **都没传**（全仓 grep 零命中），于是用户在下拉里永远只能选到「自动」，
    // 具体 agent 一个都看不到——功能齐全但无人调用，本仓库最常见的失败模式。
    //
    // 面板自身的测试用手工构造的 options，抓不到「router 忘了传」。故这里打
    // 真实 router + 真实 HTTP。
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
        // 偏好表单加载（`GET /me/preferences`）。
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

  testWidgets('从设置页进入 /settings/sync 并渲染同步页', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-sync-entry')));
    await tester.pumpAndSettle();

    expect(h.router.state.matchedLocation, SpbRoutes.sync);
    expect(find.text('交付物同步'), findsWidgets);
    expect(find.byKey(const ValueKey('sync-pick-directory')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-start-button')), findsOneWidget);
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
      sseClient: _FakeSseClient(),
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
    final sse = _FakeSseClient();
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

  testWidgets('同步页展示注入的初始目录（从数据库绑定读入）', (tester) async {
    final h = await pumpApp(tester, syncLocalRoot: '/home/u/deliverables');

    h.router.go(SpbRoutes.sync);
    await tester.pumpAndSettle();

    expect(find.text('/home/u/deliverables'), findsOneWidget);
  });

  testWidgets('同步页点「立即同步」调用注入的 runSync 并展示结果', (tester) async {
    var calls = 0;
    final h = await pumpApp(
      tester,
      syncLocalRoot: '/home/u/deliverables',
      runSync: () async {
        calls++;
        return SyncReport(
          downloaded: 4,
          skipped: {SyncSkipReason.mediaExcluded: 2},
          failed: const [SyncFailure('a.md', '下载失败：超时')],
        );
      },
    );

    h.router.go(SpbRoutes.sync);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-start-button')));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.byKey(const ValueKey('sync-report')), findsOneWidget);
    expect(find.text('4 个'), findsOneWidget);
    expect(find.textContaining('a.md'), findsOneWidget);
  });

  testWidgets('同步页选择目录后写入数据库绑定（换目录清状态）', (tester) async {
    // 端到端验证「目录变更 → bindLocalRoot 落库」这条链路，
    // 而不只是「页面上显示了新路径」。
    final h = await pumpApp(
      tester,
      pickDirectory: ({String? title}) async => '/home/u/new-root',
    );

    h.router.go(SpbRoutes.sync);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-pick-directory')));
    await tester.pumpAndSettle();

    final store = h.container.read(syncStateStoreProvider);
    expect(await store.boundLocalRoot(), '/home/u/new-root');
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

    testWidgets('登录成功后守卫放行首页（状态从 unknown 推进到 authenticated）', (tester) async {
      // 端到端验证「凭证落盘 → 守卫放行」这条链路，而不只是「路由表里有 /login」。
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);

      // 模拟外部回调把 token 落盘（真实场景由浏览器回调后的处理流程完成）。
      await store.write(_freshTokens());
      h.container.read(authStateProvider.notifier).signedIn();
      await tester.pumpAndSettle();

      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '状态应变为已登录',
      );
    });
  });

  testWidgets('注入的 desktopCapabilitiesProvider 生效（空实现）', (tester) async {
    final h = await pumpApp(tester);

    expect(
      h.container.read(desktopCapabilitiesProvider),
      isA<NoopDesktopCapabilities>(),
    );
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

  testWidgets('同一 userId 下跨两个 group 只建一次 SSE（切 group 走 switchGroup）', (
    tester,
  ) async {
    // 回归防线：若切对话仍走 `start()`，`SseClient.connect()` 会把续接游标
    // 置 null（丢 cursor 回放能力），且每次切对话都多一次建连往返。
    final sse = _FakeSseClient();
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

  /// 小程序工作台测试用的载荷构造（形状同 `internal/server/miniapp.go`）。
  ///
  /// 抽成函数而不是内联字面量：工作列表项与详情的字段高度重叠（`progress` /
  /// `status_label` 等），两处手写容易漂移成「测试通过但形状与真源不同」。
  Map<String, dynamic> workJson({
    required String id,
    String title = '某个工作',
    String status = 'running',
    String statusLabel = '运行中',
    int total = 2,
    int completed = 1,
  }) => {
    'id': id,
    'title': title,
    'status': status,
    'status_label': statusLabel,
    'progress': {'total': total, 'completed': completed, 'percent': 50},
    'pending_confirmation_count': 0,
    'latest_summary': null,
    'latest_artifact': null,
    'created_at': '2024-03-05T08:09:10Z',
    'updated_at': '2024-03-05T08:09:12Z',
  };

  Map<String, dynamic> workDetailJson({
    required String id,
    String title = '某个工作',
    String status = 'running',
    String statusLabel = '运行中',
  }) => {
    'work': {
      ...workJson(
        id: id,
        title: title,
        status: status,
        statusLabel: statusLabel,
      ),
      'steps': <Map<String, dynamic>>[],
      'pending_confirmations': <Map<String, dynamic>>[],
      'artifacts': <Map<String, dynamic>>[],
      'recent_events': <Map<String, dynamic>>[],
      'can_send_message': true,
      'can_stop': true,
      'can_complete': true,
    },
  };

  /// 挂上详情页需要的三个端点（详情 / 事件 / 产物）。
  void mockWorkDetail(
    DioAdapter adapter,
    String workId, {
    String title = '某个工作',
  }) {
    adapter.onGet(
      '/chat/miniapp/works/$workId',
      (server) => server.reply(200, workDetailJson(id: workId, title: title)),
    );
    adapter.onGet(
      '/chat/miniapp/works/$workId/events',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 100},
    );
    adapter.onGet(
      '/chat/miniapp/works/$workId/artifacts',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
    );
  }

  testWidgets('主题模式：默认跟随系统，切换后即时生效并落盘', (tester) async {
    // 端到端验证：默认 system；设置页选「深色」后 MaterialApp 立刻变；
    // 值真的写进了偏好库（不是只改内存）。
    final h = await pumpApp(tester, mockGroups: false);

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
      reason: '未设置过时必须跟随系统（与改动前行为一致）',
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
    final h = await pumpApp(tester, mockGroups: false);

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

  group('小程序工作台（桌面端接线）', () {
    testWidgets('对话列表点「工作台」进入工作列表', (tester) async {
      // 端到端验证 router 把首页的 onOpenWorks 接到了真实路由与端点。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [workJson(id: 'w1', title: '桌面端工作')],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
        },
      );

      // 入口只在注入了 onOpenWorks 时出现（见 GroupListPage.onOpenWorks）。
      await tester.tap(find.byKey(const ValueKey('group-list-works')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.works,
        reason: '点工作台入口必须真的导航到工作列表，否则入口是摆设',
      );
      expect(find.text('桌面端工作'), findsOneWidget);
      expect(find.text('运行中'), findsOneWidget);
    });

    testWidgets('工作列表点条目进入详情（work.id 就是 group id）', (tester) async {
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {
              'items': [workJson(id: 'grp_w9', title: '报表工作')],
            }),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          mockWorkDetail(adapter, 'grp_w9', title: '报表工作');
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

    testWidgets('新建工作：POST /chat/miniapp/works 后进入新工作详情', (tester) async {
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
              ...workDetailJson(id: 'grp_new', title: '新会话'),
              'dispatch': null,
            }),
            data: Matchers.any,
          );
          mockWorkDetail(adapter, 'grp_new', title: '新会话');
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

      expect(createBody, isNotNull, reason: '必须真的发出建工作请求');
      expect(
        h.router.state.matchedLocation,
        SpbRoutes.work('grp_new'),
        reason: '新建后直接进详情——列表里一堆同名「新会话」看不出哪个是刚建的',
      );
    });

    testWidgets('两条工作台路由不会互相抢匹配', (tester) async {
      // `/miniapp/works` 是 2 段、`/miniapp/works/:workId` 是 3 段，段数不同。
      // 这条用例守住「将来有人把它改成嵌套子路由而引入歧义」。
      final h = await pumpApp(
        tester,
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/miniapp/works',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'status': 'active', 'limit': 20},
          );
          mockWorkDetail(adapter, 'grp_x');
        },
      );

      h.router.go(SpbRoutes.works);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('miniapp-works-page')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsNothing,
      );

      h.router.go(SpbRoutes.work('grp_x'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('miniapp-work-detail-page')),
        findsOneWidget,
      );
    });
  });

  group('习惯（桌面端接线）', () {
    /// `/api/habits` 列表项（sqlc camelCase 形态）。
    Map<String, dynamic> habitJson({
      String id = 'hp_1',
      String topicKey = 'weekly-report',
      String status = 'active',
    }) => {
      'id': id,
      'userId': 'usr_1',
      'originGroupId': 'grp_1',
      'topicKey': topicKey,
      'triggerType': 'time_based',
      'triggerConfigJson': '{"weekday":[1],"times":[{"hour":9,"minute":0}]}',
      'acceptanceLevel': 'suggest_only',
      'sourceType': 'manual',
      'status': status,
      'triggerCount': 2,
      'confidence': 0.5,
      'nextFireAt': {'Time': '0001-01-01T00:00:00Z', 'Valid': false},
    };

    /// `/api/habits/runs` 列表项（snake_case + `run_id`）。
    Map<String, dynamic> runJson({
      String runId = 'run_1',
      String? turnId = 'turn_9',
    }) => {
      'run_id': runId,
      'pattern_id': 'hp_1',
      'topic_key': 'weekly-report',
      'trigger_reason': 'due_rule',
      'outcome': 'completed',
      'created_at': '2024-03-05T08:09:10Z',
      'delivery_group_id': 'grp_1',
      'delivery_group_title': null,
      'turn_id': turnId,
      'reply_text': '已生成周报草稿。',
      'is_manual': false,
    };

    testWidgets('对话列表点「习惯」进入习惯页（两个 Tab 都拉到数据）', (tester) async {
      // 端到端验证 router 把 onOpenHabits 接到真实路由与两个端点。
      //
      // 两个 Tab 都要 mock：页面首次构建时两个 FutureProvider 都会被监听到
      // （TabBarView 用 IndexedStack 语义保留两个子页），漏一个会留下未结算请求。
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
            (server) => server.reply(200, {
              'items': [runJson()],
            }),
            queryParameters: {'limit': 50},
          );
        },
      );

      // 入口只在注入了 onOpenHabits 时出现（见 GroupListPage.onOpenHabits）。
      await tester.tap(find.byKey(const ValueKey('group-list-habits')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.habits,
        reason: '点习惯入口必须真的导航到习惯页，否则入口是摆设',
      );
      expect(find.text('weekly report'), findsOneWidget);
    });

    testWidgets('未注入 habit 回调时习惯页仍可浏览（只读不炸）', (tester) async {
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

      h.router.go(SpbRoutes.habits);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('weekly report'), findsOneWidget);
    });
  });

  group('侧边栏（桌面端接线：交付物 / 待办 / 目标 / 任务 / 续跑 / 诊断）', () {
    /// 进入对话页并补齐必要的 mock（/me + timeline + pending）。返回 fake UFS API
    /// 以观察侧边栏的取数。
    Future<_FakeUfsApi> openChat(
      WidgetTester tester,
      SseClient sse, {
      String groupId = 'grp_x',
    }) async {
      final ufs = _FakeUfsApi();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat(groupId),
        mockGroups: false,
        sseClient: sse,
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
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      return ufs;
    }

    /// 把 tab 条横向滚到露出 [label] 那个 tab。
    ///
    /// ## 为什么必须滚动
    ///
    /// 侧边栏宽 320px，tab 条是**横向可滚的** `ListView.builder`。它的子项是
    /// **懒构建**的：超出 `cacheExtent`（默认 250px）的 tab 根本不在树里，
    /// `find.byKey` 会得到 0 个——那不是「tab 被删了」，而是「还没构建」。
    /// tab 数量增加到 7 个后，「诊断」正好落到可视区 + cacheExtent 之外。
    ///
    /// 故断言尾部 tab 之前必须先滚到它——`scrollUntilVisible` 会驱动
    /// `ListView` 构建出目标项。真实用户横向滚动一下也能看到，这是
    /// **测试驱动方式的问题，不是 UI 缺陷**。
    Future<void> revealTab(WidgetTester tester, String label) async {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('sidebar-tab-$label')),
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('sidebar-tabbar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('默认不展开：开关存在但侧边栏不可见，未取数', (tester) async {
      final sse = _FakeSseClient();
      final ufs = await openChat(tester, sse);

      // AppBar 里有侧边栏开关。
      final toggle = find.byKey(const ValueKey('toggle-deliverables'));
      expect(toggle, findsOneWidget);

      // 未取数：侧边栏默认折叠，autoDispose provider 不该被读。
      expect(ufs.listCalls, isEmpty);
      // 侧边栏 tab 也不在。
      expect(find.text('交付物'), findsNothing);
    });

    testWidgets('点开关展开侧边栏，按 group 前缀取数并渲染文件', (tester) async {
      final sse = _FakeSseClient();
      final ufs = await openChat(tester, sse);
      ufs.entries = [_ufsFile('grp_x', 'README.md')];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 取数时用 group workspace 前缀。
      expect(ufs.listCalls, contains('/workspace/groups/grp_x'));
      // 文件名出现在侧边栏。
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('交付物'), findsOneWidget);
    });

    testWidgets('再点开关收起侧边栏', (tester) async {
      final sse = _FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('交付物'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('交付物'), findsNothing);
    });

    testWidgets('展开后各 tab 齐全（交付物 / 待办 / 设置 / 目标 / 任务 / 续跑 / 诊断）', (
      tester,
    ) async {
      final sse = _FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      // 尾部 tab 在 320px 侧边栏里落在可视区外（tab 条横向可滚且懒构建），
      // 断言前先滚到它们。
      await revealTab(tester, '目标');
      expect(find.byKey(const ValueKey('sidebar-tab-目标')), findsOneWidget);
      await revealTab(tester, '续跑');
      expect(find.byKey(const ValueKey('sidebar-tab-续跑')), findsOneWidget);
      await revealTab(tester, '诊断');
      expect(find.byKey(const ValueKey('sidebar-tab-诊断')), findsOneWidget);
    });

    /// 把 tab 条横向滚到露出 [label] 那个 tab，然后点它。
    Future<void> tapTab(WidgetTester tester, String label) async {
      await revealTab(tester, label);
      await tester.tap(find.byKey(ValueKey('sidebar-tab-$label')));
      await tester.pumpAndSettle();
    }

    testWidgets('无待确认项时待办 tab 显示空提示，且不带徽标', (tester) async {
      final sse = _FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 无待办 → 无徽标（badge 0 不渲染）。
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('门控关闭（发布构建）时「诊断」tab 整个消失，其余 tab 仍在', (tester) async {
      // ## 这个用例防的是什么
      //
      // 诊断面板展示工具调用入参与 gate 决策明细，是内部视图，不应随发布包
      // 分发。但此前全仓没有任何 `kReleaseMode` / `isRelease` 使用——发布包里
      // 它照样在。
      //
      // ## 为什么能在这里断言
      //
      // 若门控写成 `if (!SpbEnv.isRelease)`，测试跑在 JIT 下 `isRelease` 恒为
      // false，这个行为**根本无法验证**。故门控走 provider，测试可以把它置为
      // false（等价于发布构建）。
      final sse = _FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: _FakeUfsApi(),
        showDebugPanel: false,
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

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsNothing,
        reason: '发布包不该暴露工具调用与 gate 决策诊断',
      );
      expect(
        find.byKey(const ValueKey('debug-panel')),
        findsNothing,
        reason: '面板本身也必须不在树里（不只是 tab 按钮隐藏）',
      );
      // 其余 tab 不受影响（门控只该拿掉诊断那一个）。
      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar-tab-待办')), findsOneWidget);
      await revealTab(tester, '续跑');
      expect(find.byKey(const ValueKey('sidebar-tab-续跑')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsNothing,
        reason: '滚到尾部后诊断仍不该存在',
      );
      // 默认落点仍是第一个 tab（删掉尾部 tab 不改索引语义）：
      // IndexedStack 显示的是 index 0 的「交付物」，其空态已渲染。
      final stack = tester.widget<IndexedStack>(
        find.byKey(const ValueKey('sidebar-content')),
      );
      expect(
        stack.index,
        0,
        reason: 'tabs 变短不该改变默认落点（initialIndex 语义与 tab 数量无关）',
      );
      expect(find.byKey(const ValueKey('deliverables-empty')), findsOneWidget);
    });

    testWidgets('门控打开（开发构建）时「诊断」tab 仍在', (tester) async {
      // 与上一条成对：证明「tab 消失」确实来自门控，而不是别的原因（例如
      // tab 被误删、或被挤出可视区而 find 不到——后者要靠滚动才可见，
      // 但 `findsOneWidget` 检查的是挂载，不是可见）。
      final sse = _FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: _FakeUfsApi(),
        showDebugPanel: true,
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

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 诊断在 tab 条尾部，懒构建，先滚到它。
      await revealTab(tester, '诊断');
      expect(
        find.byKey(const ValueKey('sidebar-tab-诊断')),
        findsOneWidget,
        reason: '开发构建下诊断入口必须可用',
      );
    });

    testWidgets('切到诊断 tab 显示工具调用 + gate 面板（两者空态）', (tester) async {
      final sse = _FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tapTab(tester, '诊断');

      // 诊断 tab = 工具调用 + gate 决策上下分栏（对齐 webapp 的 debug tab）。
      expect(find.byKey(const ValueKey('debug-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('toolcalls-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('gate-empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('目标历史 tab 已接线（列出历史目标）', (tester) async {
      final sse = _FakeSseClient();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat('grp_x'),
        mockGroups: false,
        sseClient: sse,
        ufsApi: _FakeUfsApi(),
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
          // 历史目标列表（`GET /chat/groups/:id/goals`）——独立于 group 快照。
          adapter.onGet(
            '/chat/groups/grp_x/goals',
            (server) => server.reply(200, {
              'items': [
                {
                  'id': 'goal_1',
                  'group_id': 'grp_x',
                  'goal_text': '把 CI 修绿',
                  'status': 'active',
                  'tasks_source': 'manual',
                  'created_at': '2024-03-05T08:00:00Z',
                  'updated_at': '2024-03-05T08:00:00Z',
                },
              ],
            }),
            queryParameters: {'limit': 50},
          );
        },
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      await tapTab(tester, '目标');

      expect(
        find.text('把 CI 修绿'),
        findsOneWidget,
        reason: 'listGoals 已接线（此前全仓零引用）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('收起按钮（侧边栏头部）也能关闭侧边栏', (tester) async {
      final sse = _FakeSseClient();
      await openChat(tester, sse);

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('sidebar-close')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar-tab-交付物')), findsNothing);
    });
  });

  // =========================================================================
  group('任务编辑接线（updateTask 走真实 router 装配）', () {
    /// 断言「router 真的把 onUpdateTask 接上了」。
    ///
    /// ## 为什么必须打真实 router
    ///
    /// 面板自身的测试（`goal_tasks_panel_test.dart`）用的是**手工构造的**
    /// 回调——它能验证面板行为，但无法发现「router 忘了注入 onUpdateTask」
    /// 这种错误，而那正是本仓库最常见的失败模式（能力实现了但没人调用：
    /// `updateTask` 此前全仓零引用）。故这里打 HTTP，断言请求真的发出去了。
    testWidgets('点编辑改标题保存 → PATCH 带新标题', (tester) async {
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
          // 带 current_goal + 一条任务的 group（任务 tab 才有内容可编辑）。
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

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();

      // 切到「任务」tab（它在 320px 侧边栏里落在可视区外，需先横滚）。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('sidebar-tab-任务')),
        80,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('sidebar-tabbar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-tab-任务')));
      await tester.pumpAndSettle();

      // 编辑入口存在（证明 router 注入了 onUpdateTask）。
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
      // '' = 清除（不是 null = 不改）。
      expect(body['description'], '');
      expect(tester.takeException(), isNull);
    });
  });

  // =========================================================================
  group('交付物「已同步则直接打开」（同步索引打通）', () {
    /// 最近一次 [seedSyncState] 建好的库（供 pumpApp 的 database 参数使用）。
    late AppDatabase seededDb;

    /// 建临时同步目录 + 落一个真实文件 + 在库里写入「已同步」记录与目录绑定。
    ///
    /// ## 为什么整段包在 `tester.runAsync` 里
    ///
    /// `testWidgets` 的测试体跑在 `FakeAsync` 区域：真实文件 IO（
    /// `createTemp` / `writeAsString`）与真实事件循环绑定，fake 时钟不会推进它，
    /// 直接 `await` 会**挂死**（实测：10 分钟超时后才报 `TimeoutException`）。
    /// `runAsync` 临时切回真实异步，专用于这类测试前置副作用。
    ///
    /// ## 为什么要落**真实文件**
    ///
    /// provider 会 `File(abs).existsSync()` 校验（索引记的是「曾经同步过」，
    /// 用户可能手动删了）。不建真文件的话菜单项恒为禁用，用例会以
    /// 「实现看起来没生效」的形式失败。
    Future<Directory> seedSyncState(
      WidgetTester tester, {
      required String gid,
      required String rel,
      bool markSynced = true,
    }) async {
      late Directory root;
      late AppDatabase db;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('spb-sync-');
        if (markSynced) {
          final file = File(p.join(root.path, gid, rel));
          await file.parent.create(recursive: true);
          await file.writeAsString('# 已同步的交付物\n');
        }
        db = AppDatabase(NativeDatabase.memory());
        final store = DriftSyncStateStore(db);
        // 先绑目录再写状态：bindLocalRoot 在目录**变化**时会清空状态，
        // 顺序反了会把刚写入的记录清掉。
        await store.bindLocalRoot(root.path);
        if (markSynced) {
          await store.save(
            workspaceStateKey,
            SyncState(
              cursor: '2026-01-01T00:00:00Z',
              files: {'$gid/$rel': const SyncedFile(size: 21)},
            ),
          );
        }
      });
      // 同步删除（不用异步版本）：tearDown 阶段可能已不在 runAsync 区域内。
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
        db.close();
      });
      // 把 db 也带出去：pumpApp 要它作为 appDatabaseProvider 的 override。
      seededDb = db;
      return root;
    }

    /// 进入某个 group 的对话页所需的 mock（含侧边栏依赖的两个端点）。
    void mockChat(DioAdapter adapter, String gid) {
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

    testWidgets('已同步的交付物不触发下载即可打开', (tester) async {
      const gid = 'grp_sync';
      const rel = 'reports/spec.md';
      final root = await seedSyncState(tester, gid: gid, rel: rel);

      final sse = _FakeSseClient();
      final caps = _FakeDesktopCapabilities();
      final ufs = _FakeUfsApi();
      await pumpApp(
        tester,
        initialLocation: SpbRoutes.chat(gid),
        mockGroups: false,
        sseClient: sse,
        ufsApi: ufs,
        capabilities: caps,
        database: seededDb,
        beforePump: (adapter) => mockChat(adapter, gid),
      );
      ufs.entries = [_ufsFile(gid, rel)];

      await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
      await tester.pumpAndSettle();
      expect(find.text('spec.md'), findsOneWidget);

      // 不点「下载」，直接打开。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isTrue, reason: '已同步的文件应可直接打开（无需下载）');

      await tester.tap(find.text('用默认程序打开'));
      await tester.pumpAndSettle();

      expect(caps.openedPaths, hasLength(1));
      expect(caps.openedPaths.single, p.join(root.path, gid, rel));
      // 关键断言：没有发生下载（UFS 下载端点一次都没被请求）。
      expect(ufs.downloadCalls, isEmpty, reason: '已同步的文件不应触发下载');
    });
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
  testWidgets('对话列表新建入口：POST /chat/groups 后进入新对话', (tester) async {
    final h = await pumpApp(
      tester,
      sseClient: _FakeSseClient(),
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

    await tester.tap(find.byKey(const ValueKey('group-list-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('group-create-field')),
      '新对话',
    );
    // 必须 pump 一帧让确认按钮解除禁用（见 GroupListPage 测试里的说明）。
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-create-confirm')));

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
      page.onResolveFeedback!('tok_fb1', true);
      // onResolveFeedback 返回 void（页面内 fire-and-forget），真实 dio 往返
      // 需要真实事件循环跑完——短 delay 会拿不到请求（实测 Duration.zero 不够）。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(hit, hasLength(1), reason: '必须真的发出一次回执请求');
    expect(hit.single.$1, '/chat/feedback/tok_fb1/resolve');
    expect(
      hit.single.$2,
      containsPair('correct', true),
      reason: 'correct 必须进请求体，否则服务端拿不到标注',
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

  group('托盘提示接线', () {
    testWidgets('启动时推送一次托盘提示（否则永远是托盘库的默认值）', (tester) async {
      final caps = _FakeDesktopCapabilities();
      await pumpApp(tester, capabilities: caps);

      expect(
        caps.trayTooltips,
        isNotEmpty,
        reason:
            '不推的话托盘一直显示托盘库默认值，而「未配置同步目录」'
            '这条信息恰恰在用户还没同步时最有用',
      );
      expect(caps.trayTooltips.first, contains('Super PartyB'));
    });

    testWidgets('未配置同步目录时提示如实说明', (tester) async {
      final caps = _FakeDesktopCapabilities();
      await pumpApp(tester, capabilities: caps);

      expect(
        caps.trayTooltips.first,
        contains('未配置同步目录'),
        reason: '用户不知道「为什么同步没动静」，提示要直接说出来',
      );
    });

    testWidgets('同步开始与结束分别推送提示（在途 → 空闲）', (tester) async {
      // 端到端验证「同步在途 → 托盘提示」这条链路：光有 TrayState 类不够，
      // 必须真的被推送到托盘。
      //
      // ## 为什么直接驱动 notifier，而不真的跑一轮同步
      //
      // 真同步要打 UFS + 写盘（那是 sync 页测试的事）。这里只验证**订阅**
      // 是否接上——驱动 `syncInFlightProvider` 等价于同步开始/结束那一刻。
      //
      // ⚠️ 不要用 Completer 之类「不结束的 Future」来卡住状态：一旦上面的
      // 断言先失败，那个 Future 永远不结算，测试框架会一直等到超时
      // （实测一次变异跑 15 分钟）。
      final caps = _FakeDesktopCapabilities();
      final h = await pumpApp(
        tester,
        capabilities: caps,
        syncLocalRoot: '/out',
      );
      final before = caps.trayTooltips.length;

      h.container.read(syncInFlightProvider.notifier).set(true);
      await tester.pump();
      expect(
        caps.trayTooltips.length,
        greaterThan(before),
        reason: '在途状态变化必须触发推送',
      );
      expect(
        caps.trayTooltips.last,
        contains('同步中'),
        reason: '提示要反映当下状态，而不是历史结果',
      );

      h.container.read(syncInFlightProvider.notifier).set(false);
      await tester.pump();
      expect(
        caps.trayTooltips.last,
        isNot(contains('同步中')),
        reason: '同步结束后必须回到空闲——永久显示「同步中…」比没提示更糟',
      );
    });

    testWidgets('同步结束后回到空闲态（订阅确实接在同步在途上）', (tester) async {
      // 去重逻辑本身由 tray_tooltip_test.dart 单测覆盖；这里只验证**接线**
      // 确实把同步在途状态连到了托盘上。
      final caps = _FakeDesktopCapabilities();
      final h = await pumpApp(
        tester,
        capabilities: caps,
        syncLocalRoot: '/out',
      );
      final before = caps.trayTooltips.length;

      h.container.read(syncInFlightProvider.notifier).set(true);
      await tester.pump();
      expect(caps.trayTooltips.length, greaterThan(before));

      h.container.read(syncInFlightProvider.notifier).set(false);
      await tester.pump();
      expect(caps.trayTooltips.last, isNot(contains('同步中')));
    });
  });

  group('开机自启设置项', () {
    /// 把测试窗口调高。
    ///
    /// 设置页是惰性 `ListView`，屏幕外的条目在树里根本不存在；开机自启位于
    /// **最底部**的桌面集成区块，默认 800×600 下必然在屏幕外。
    void useTallWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('桌面端展示开关，初值来自能力实现', (tester) async {
      useTallWindow(tester);
      final caps = _FakeDesktopCapabilities()..launchAtStartupEnabled = true;
      final h = await pumpApp(tester, capabilities: caps);

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings-launch-at-startup')),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('切换开关调用能力的 setLaunchAtStartup', (tester) async {
      useTallWindow(tester);
      final caps = _FakeDesktopCapabilities();
      final h = await pumpApp(tester, capabilities: caps);

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('settings-launch-at-startup')),
      );
      await tester.pumpAndSettle();

      expect(caps.launchAtStartupCalls, [true]);
    });

    testWidgets('移动端（Noop 能力）不展示开机自启开关', (tester) async {
      // Noop 能力的 isSupported == false → 桌面集成整段不渲染。
      final h = await pumpApp(tester);

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-launch-at-startup')),
        findsNothing,
      );
    });
  });

  group('导入会话（粘贴凭证 → 落盘 → 请求带 Bearer）', () {
    testWidgets('导入合法会话后状态变为已登录', (tester) async {
      // 端到端验证桌面端登录闭环：这是全仓库最高价值的缺口——SSO 在系统浏览器
      // 完成，Flutter 读不到浏览器 Cookie，故「粘贴导入」是唯一入口。
      final store = InMemoryTokenStore();
      final h = await pumpApp(
        tester,
        tokenStore: store,
        initialLocation: SpbRoutes.login,
      );

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

    testWidgets('导入后请求头带上 Authorization: Bearer <token>', (tester) async {
      // 这是「闭环」的最后一环：光落盘不够，请求必须真的带上凭证，
      // 否则服务端仍然 401，用户看到的还是登录页。
      //
      // ## 为什么不能用 `pumpApp` 的 harness
      //
      // `pumpApp` 把 `dioProvider` override 成裸 dio（只挂 `DioAdapter`，
      // **没有 AuthInterceptor**）——那套 dio 是为了让页面里的请求可被 mock。
      // 用它断言「带 Bearer」是**空洞**的：拦截器根本不在链上（实测
      // `Authorization` 恒为 null）。
      //
      // 故这里自建容器，**只** override 凭证存储，让 `dioProvider` 用生产实现
      // （带真实 `AuthInterceptor`）。这才能证明「凭证 → 请求头」真的通。
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
            seen['X-User-ID'] = options.headers['X-User-ID'] as String?;
            handler.next(options);
          },
        ),
      );

      // ## 必须先等启动时的 restore() 落定（这是**真实的竞态**，不是测试噪音）
      //
      // `AuthStateNotifier.build()` 会 `unawaited(restore())`。那一刻 store 还是
      // 空的，于是这次 restore 会走「清理残留凭证」分支：它 await 完
      // `currentAccessToken()` 后**再次读 store**，若此时已经不为空（比如我们
      // 刚导入完），就判定为「残留」并调 `logout()` —— **把刚写入的凭证清掉**。
      //
      // 实测：不等的话 `importSession` 返回 null（成功）但 store 立刻变空。
      // 真实使用中用户不可能在启动那一瞬完成粘贴，故影响可忽略；但测试必须
      // 建立确定的前置状态，否则断言毫无意义。
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
        reason: '凭证必须真的落盘，否则后面的请求头断言是空洞的',
      );

      adapter.onGet(
        '/chat/groups',
        (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
        queryParameters: {'limit': 50, 'offset': 0},
      );

      // 必须包在 `runAsync` 里：内部 await 一个 dio 请求，而 dio 的 mock
      // 响应依赖真实 Timer——widget test 的假时钟不会推进它（实测：不包会
      // 卡满 10 分钟超时）。仓库内既有用例已记录同一陷阱。
      await tester.runAsync(() => container.read(chatApiProvider).listGroups());

      expect(
        seen.containsKey('Authorization'),
        isTrue,
        reason: '请求必须真的发出，否则下面的断言是空洞的',
      );
      expect(
        seen['Authorization'],
        'Bearer test-id-token',
        reason: '凭证必须出现在 Authorization 头，否则服务端仍 401',
      );
      expect(seen['X-User-ID'], isNull, reason: '客户端不得自选身份（X-User-ID 由网关注入）');
    });

    testWidgets('认不出的内容报错且不落盘（不造无效凭证）', (tester) async {
      final store = InMemoryTokenStore();
      final h = await pumpApp(tester, tokenStore: store);

      // 注意：不能拿「一个随便的单词」当反例——单段且无 `=` 的输入会被当作
      // **裸 token**（那是受支持的形态）。真正的反例是「有键值对但没有可用
      // 的 token 键」。
      final err = await h.container
          .read(authControllerProvider)
          .importSession('session_id=abc; csrf=def');

      expect(err, isNotNull, reason: '必须给出可操作的错误，而不是静默失败');
      expect(
        await store.read(),
        isNull,
        reason: '认不出时绝不能落盘——那会造出一个「已登录但请求全 401」的假状态',
      );
      expect(h.container.read(authStateProvider).isAuthenticated, isFalse);
    });

    testWidgets('登录页展示导入入口与输入框', (tester) async {
      await pumpApp(
        tester,
        tokenStore: InMemoryTokenStore(),
        initialLocation: SpbRoutes.login,
      );

      expect(
        find.byKey(const ValueKey('login-import-session')),
        findsOneWidget,
        reason: '桌面端必须有这个入口，否则登录无法闭环',
      );

      // 默认收起：SSO 是主路径，导入是备选。
      expect(find.byKey(const ValueKey('login-import-field')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-import-field')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('login-import-confirm')),
        findsOneWidget,
      );
    });
  });
}

/// 桌面能力桩（`isSupported == true`，用于验证桌面专属设置项会展示）。
class _FakeDesktopCapabilities implements DesktopCapabilities {
  /// 收到的托盘提示（按推送顺序）。
  ///
  /// 用列表而非单个值：托盘提示的**推送时机与去重**本身就是被测行为
  /// （如「同步结束后必须推回空闲态」）。
  final List<String> trayTooltips = [];

  /// 收到的开机自启设置调用。
  final List<bool> launchAtStartupCalls = [];

  /// 收到的「用默认程序打开」路径（按顺序）。
  final List<String> openedPaths = [];

  /// 收到的「在文件管理器中定位」路径（按顺序）。
  final List<String> revealedPaths = [];

  /// `isLaunchAtStartupEnabled` 的返回值（用例可改以验证初值来源）。
  bool launchAtStartupEnabled = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> showWindow(WindowRole role) async {}

  @override
  Future<void> hideWindow(WindowRole role) async {}

  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async => true;

  @override
  Future<void> unregisterHotkey(String id) async {}

  @override
  Future<bool> isLaunchAtStartupEnabled() async => launchAtStartupEnabled;

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {
    launchAtStartupCalls.add(enabled);
  }

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}

  @override
  Future<void> setTrayTooltip(String tooltip) async {
    trayTooltips.add(tooltip);
  }

  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<bool> revealPath(String path) async {
    revealedPaths.add(path);
    return true;
  }

  @override
  Future<bool> openFile(String path) async {
    openedPaths.add(path);
    return true;
  }

  @override
  Future<void> dispose() async {}
}
