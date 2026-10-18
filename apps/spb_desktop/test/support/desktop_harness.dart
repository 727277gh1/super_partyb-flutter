/// 桌面端 widget 测试 的共享夹具（issue #48 从 `widget_test.dart` 抽出）。
///
/// ⚠️ 文件私有的 `_Xxx` 移到共享库后必须去掉下划线（跨库不可见），
/// 故拆分时引用它们的调用点同步改名（纯重命名，无行为变化）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:drift/native.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
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
class FakeSseClient extends SseClient {
  FakeSseClient()
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
    framesController.add(SseFrame(event: event, data: encode(data), id: null));
  }

  static String encode(Map<String, dynamic> m) =>
      '{${m.entries.map((e) => '"${e.key}":${jsonValue(e.value)}').join(',')}}';

  static String jsonValue(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return v.toString();
    if (v is String) {
      final escaped = v
          .replaceAll(r'\', r'\\')
          .replaceAll('"', r'\"')
          .replaceAll('\n', r'\n');
      return '"$escaped"';
    }
    if (v is List) return '[${v.map(jsonValue).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '"${e.key}":${jsonValue(e.value)}').join(',')}}';
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
/// `SpbEndpoints.current.apiBaseUrl`（默认 `127.0.0.1:8000`）发真实请求——测试环境里
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

  /// 本地通知发送桩（issue #21）。默认 [NoopNotificationSink]。
  ///
  /// ## 为什么必须可注入
  ///
  /// 真实实现是 `LocalNotificationSink`，它调 `flutter_local_notifications`
  /// 的平台通道——`flutter test` 里没有通道，`initialize()` 会抛
  /// `MissingPluginException`（内部已捕获并降级，但那样就观测不到「发了什么」）。
  /// 注入记录桩后可以断言通知的**内容与次数**。
  NotificationSink? notificationSink,

  /// 窗口初始聚焦状态（issue #21）。默认 true（启动时不打扰）。
  ///
  /// 传 false 模拟「应用在后台」——通知只在该状态下发。
  bool windowFocused = true,

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
        tokenStore ?? InMemoryTokenStore(freshTokens()),
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
      sseClientProvider.overrideWithValue(sseClient ?? FakeSseClient()),
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
      if (notificationSink != null)
        notificationSinkProvider.overrideWithValue(notificationSink),
      // 初始聚焦状态。`_SpbDesktopAppState` 只在能力实现 WindowFocusTarget
      // 时才推送变化；测试默认的空实现不推，故这个初始值就是全程的值。
      windowFocusedProvider.overrideWith(
        () => FixedWindowFocused(windowFocused),
      ),
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
StoredTokens freshTokens() => StoredTokens(
  accessToken: 'at_test',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
);

/// `UfsApi` 的内存桩：记录 `listFiles` 调用并返回可配条目。
///
/// 用子类重写而不是 mock 框架：`UfsApi` 的方法都是虚方法，重写 `listFiles`
/// 即可，无需引入 mockito 依赖，也不依赖 dio。
class FakeUfsApi extends UfsApi {
  FakeUfsApi() : super(Dio());

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
    return const UfsDownload(
      notModified: false,
      bytes: [1, 2, 3],
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
UfsFileEntry ufsFile(String gid, String rel, {String? id}) =>
    UfsFileEntry.fromJson({
      'id': id ?? 'uf-$rel',
      'path': '/workspace/groups/$gid/$rel/',
      'size': 1024,
      'name': rel.split('/').last,
      'mime_type': 'text/markdown',
      'is_directory': false,
      'updated_at': '2026-01-01T00:00:00Z',
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
    ...workJson(id: id, title: title, status: status, statusLabel: statusLabel),
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

// =========================================================================

// =========================================================================

/// 桌面能力桩（`isSupported == true`，用于验证桌面专属设置项会展示）。
class FakeDesktopCapabilities implements DesktopCapabilities {
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

  /// 收到的诊断报告导出请求（按顺序）。
  final exportedDiagnostics = <String>[];

  /// `saveDiagnostics` 的返回值（用例可改以验证失败提示）。
  DiagnosticsExportOutcome diagnosticsOutcome = DiagnosticsExportOutcome.saved;

  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async {
    exportedDiagnostics.add(text);
    return diagnosticsOutcome;
  }

  @override
  Future<void> dispose() async {}
}

/// 固定值的焦点状态（测试用：不随平台事件变化）。
class FixedWindowFocused extends WindowFocusedNotifier {
  FixedWindowFocused(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

/// 记录发出的通知（并模拟权限结果）。见 `notificationSink` 参数说明。
class RecordingNotificationSink implements NotificationSink {
  RecordingNotificationSink({this.granted = true});

  final bool granted;
  int permissionCalls = 0;
  final sent = <LocalNotification>[];
  void Function(String? payload)? onSelect;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return granted;
  }

  @override
  Future<void> show(LocalNotification notification) async {
    sent.add(notification);
  }
}
