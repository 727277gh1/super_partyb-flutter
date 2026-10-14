/// 移动端 widget 测试 的共享夹具（issue #48 从 `widget_test.dart` 抽出）。
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
class FakeSseClient extends SseClient {
  FakeSseClient()
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

  /// 推一帧（camelCase，同 `chatbus.Event` 的 SSE 形态）。
  ///
  /// ## 为什么手写 JSON 而不 import `dart:convert`
  ///
  /// `SseFrame.data` 是 JSON 字符串，本文件已 import `dart:io`（它的
  /// `jsonEncode` 不在此）——手写一个极简编码即可，payload 只有字符串/数字/
  /// 列表，无需完整实现。
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

  /// 是否注册默认的 `/chat/confirmations` mock。
  ///
  /// 需要**计数**该端点请求次数的用例（角标自动刷新）传 false 并自己在
  /// `beforePump` 里注册计数版——否则默认 mock 会覆盖它（见该处注释）。
  bool mockPendingConfirmations = true,

  /// UFS API（交付物弹层用）。默认不 override：弹层默认不打开，用不到的用例
  /// 不应被它拖慢（同桌面端同名参数的理由）。
  UfsApi? ufsApi,

  /// 本地通知发送桩（issue #21）。默认 [NoopNotificationSink]。
  ///
  /// 真实实现是 `LocalNotificationSink`，走平台通道——`flutter test` 里没有
  /// 通道（内部已捕获并降级，但那样观测不到「发了什么」）。
  NotificationSink? notificationSink,

  /// 应用初始是否在前台（issue #21）。默认 true（启动时不打扰）。
  ///
  /// 传 false 模拟「应用切到后台」——通知只在该状态下发。
  bool appForeground = true,
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
      if (notificationSink != null)
        notificationSinkProvider.overrideWithValue(notificationSink),
      // 初始前后台状态。`_SpbMobileAppState` 通过 `AppLifecycleState` 推送
      // 变化，而 flutter test 不会派发生命周期事件，故这个初始值就是全程的值。
      windowFocusedProvider.overrideWith(
        () => FixedWindowFocused(appForeground),
      ),
      // 默认注入「已登录」的内存存储：否则 restore() 会读真实的
      // SecureTokenStore（走平台通道，测试环境必然抛 MissingPluginException），
      // 得到「未登录」后被守卫重定向到 /login——那么所有期望「列表渲染」
      // 的用例都会失败，而失败原因与被测行为无关。
      tokenStoreProvider.overrideWithValue(
        tokenStore ?? InMemoryTokenStore(freshTokens()),
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
      sseClientProvider.overrideWithValue(sseClient ?? FakeSseClient()),
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
      if (ufsApi != null) ufsApiProvider.overrideWithValue(ufsApi),
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
StoredTokens freshTokens() => StoredTokens(
  accessToken: 'at_test',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
);

/// `flutter_secure_storage` 的内存假后端（无平台通道环境下替换真实现）。
class FakeSecureStoragePlatform extends FlutterSecureStoragePlatform
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

/// `UfsApi` 的内存桩：记录 `listFiles` 调用并返回可配条目。
///
/// 用子类重写而不是 mock 框架（与桌面端同名桩同取向）：`UfsApi` 的方法都是
/// 虚方法，重写 `listFiles`/`download` 即可，无需引入 mockito 依赖。
class FakeUfsApi extends UfsApi {
  FakeUfsApi() : super(Dio());

  List<UfsFileEntry> entries = const [];

  /// `listFiles` 收到的 `pathPrefix`（按调用顺序）。
  final listCalls = <String?>[];

  /// `download` 收到的 file id（按调用顺序）。
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

/// 固定值的前后台状态（测试用：不随生命周期事件变化）。
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
