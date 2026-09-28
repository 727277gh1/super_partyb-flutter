import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
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
  TestHarness({required this.dio, required this.adapter, required this.router});

  final Dio dio;
  final DioAdapter adapter;
  final GoRouter router;
}

/// 启动测试用 app，注入 fake provider（**禁止真实网络**）。
Future<TestHarness> pumpApp(
  WidgetTester tester, {
  String initialLocation = SpbRoutes.conversations,
  bool mockGroups = true,
  SseClient? sseClient,
}) async {
  final dio = createDio(baseUrl: 'https://api.test/pba');
  final adapter = DioAdapter(dio: dio);

  // 首页（对话列表）挂载即请求。不 mock 会留下未结算 Timer，
  // flutter_test 报「A Timer is still pending...」。
  if (mockGroups) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
  }

  final router = GoRouter(
    initialLocation: initialLocation,
    routes: buildMobileRoutes(),
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopCapabilitiesProvider.overrideWithValue(
          const NoopDesktopCapabilities(),
        ),
        dioProvider.overrideWithValue(dio),
        if (sseClient != null) sseClientProvider.overrideWithValue(sseClient),
      ],
      child: SpbMobileApp(router: router),
    ),
  );
  // 推进假时钟让 dio mock 的 Timer 触发（runAsync 不推进假时钟）。
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));

  return TestHarness(dio: dio, adapter: adapter, router: router);
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

    final router = GoRouter(routes: buildMobileRoutes());
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopCapabilitiesProvider.overrideWithValue(
            const NoopDesktopCapabilities(),
          ),
          dioProvider.overrideWithValue(dio),
        ],
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

  testWidgets('切到设置标签渲染占位页', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.textContaining('设置项待接入'), findsOneWidget);
  });

  testWidgets('StatefulShellRoute：切标签后返回，保留分支导航栈', (tester) async {
    // 这是用 shell route 的理由：在「对话」分支里进入某对话后切到「设置」，
    // 再切回「对话」应回到那个对话而非列表。
    //
    // 必须注入假 SseClient：进入对话页会建 SSE 长连接，真实现会按指数退避
    // 安排重连定时器，测试结束时留下 pending Timer 直接报错。
    final h = await pumpApp(tester, sseClient: _FakeSseClient());

    // 进入「对话」分支下的子路由。
    h.router.go(SpbRoutes.chat('grp_x'));
    await tester.pumpAndSettle();

    // 切到「设置」。
    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();
    expect(find.textContaining('设置项待接入'), findsOneWidget);

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
    await pumpApp(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpbMobileApp)),
    );
    // 移动端没有托盘/多窗口，必须降级为空实现（页面据此隐藏相关设置项）。
    expect(container.read(desktopCapabilitiesProvider).isSupported, isFalse);
  });

  testWidgets('devUserHeaderOverride 默认 null（未传 SPB_DEV_USER_ID）', (
    tester,
  ) async {
    await pumpApp(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpbMobileApp)),
    );
    expect(container.read(devUserHeaderOverrideProvider), isNull);
  });
}
