import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
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
  TestHarness({required this.dio, required this.adapter, required this.router});

  final Dio dio;
  final DioAdapter adapter;
  final GoRouter router;
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
Future<TestHarness> pumpApp(
  WidgetTester tester, {
  String initialLocation = SpbRoutes.home,
  bool mockGroups = true,
}) async {
  final dio = createDio(baseUrl: 'https://api.test/pba');
  final adapter = DioAdapter(dio: dio);

  if (mockGroups) {
    adapter.onGet(
      '/chat/groups',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
      queryParameters: {'limit': 30, 'offset': 0},
    );
  }

  // 路由必须在 pumpWidget 前建好，测试才能主动导航。
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: buildDesktopRoutes(),
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        desktopCapabilitiesProvider.overrideWithValue(
          const NoopDesktopCapabilities(),
        ),
        dioProvider.overrideWithValue(dio),
      ],
      child: SpbDesktopApp(router: router),
    ),
  );
  // 推进假时钟：让 dio mock 的 Timer 触发（不能用 runAsync，见
  // packages/spb_features/test/chat/group_list_page_test.dart 的说明）。
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));

  return TestHarness(dio: dio, adapter: adapter, router: router);
}

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

    final router = GoRouter(routes: buildDesktopRoutes());
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopCapabilitiesProvider.overrideWithValue(
            const NoopDesktopCapabilities(),
          ),
          dioProvider.overrideWithValue(dio),
        ],
        child: SpbDesktopApp(router: router),
      ),
    );
    // 推进假时钟让 dio mock 的 Timer 触发。
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('测试对话'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
  });

  testWidgets('/quick-capture 可导航且渲染悬浮输入窗', (tester) async {
    // 该页面不请求任何数据（提交才发请求），故无需 mock 任何端点——
    // 这本身也验证了「打开悬浮窗不产生网络请求」。
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.quickCapture);
    await tester.pumpAndSettle();

    expect(find.text('Enter 提交 · Esc 取消'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-capture-submit')), findsOneWidget);
  });

  testWidgets('/settings 可导航（占位页）', (tester) async {
    final h = await pumpApp(tester);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.textContaining('设置项待接入'), findsOneWidget);
  });

  testWidgets('注入的 desktopCapabilitiesProvider 生效（空实现）', (tester) async {
    await pumpApp(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpbDesktopApp)),
    );
    expect(
      container.read(desktopCapabilitiesProvider),
      isA<NoopDesktopCapabilities>(),
    );
  });

  testWidgets('devUserHeaderOverride 默认 null（未传 SPB_DEV_USER_ID）', (
    tester,
  ) async {
    // 这条断言防的是「默认值不小心写成非 null」——那等于允许客户端自选身份
    // （任何拿到打包产物的人都能把 X-User-ID 改成别人的 id）。
    await pumpApp(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpbDesktopApp)),
    );
    expect(container.read(devUserHeaderOverrideProvider), isNull);
  });

  testWidgets('currentUserProvider 走 mock 的 /api/auth/me', (tester) async {
    final h = await pumpApp(tester, mockGroups: false);
    h.adapter.onGet(
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

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SpbDesktopApp)),
    );
    // 触发请求并推进假时钟。
    final future = container.read(currentUserProvider.future);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final user = await future;
    expect(user.id, 'usr_1');
    expect(user.isAdmin, isFalse);
  });
}
