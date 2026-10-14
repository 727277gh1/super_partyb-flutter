import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 设置页 / 通知订阅 / 主题 / 同步页 / 离线队列 / 习惯 / 退出登录
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/mobile_harness.dart`。
void main() {
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
    expect(
      find.byKey(const ValueKey('settings-export-diagnostics')),
      findsNothing,
      reason:
          '移动端不接导出诊断日志（file_selector 的 getSaveLocation '
          '在 Android/iOS 上未实现），未注入即隐藏，'
          '而非展示一个点了必失败的按钮（AGENTS.md §6.10 同一取舍）',
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
  group('离线写队列装配（issue #30）', () {
    testWidgets('outboxQueueProvider 用注入的 AppDatabase（同一内存库）', (tester) async {
      // 与桌面端同一条断言（`apps/spb_desktop/test/widget_test.dart` 同组）。
      // 两端各有一份装配，各测一份——否则「一端接错 db」在另一端测试里看不见。
      final harness = await pumpApp(tester);
      final queue = harness.container.read(outboxQueueProvider);
      expect(queue, isNotNull);

      await tester.runAsync(() async {
        await DriftOutboxStore(harness.container.read(appDatabaseProvider))
            .upsert(
              OutboxEntry(
                id: 'req-装配-移动',
                userId: 'usr_1',
                input: '装配层验证',
                createdAt: DateTime.utc(2026),
                nextAttemptAt: DateTime.utc(2026),
              ),
            );
        await queue.load('usr_1');
      });
      expect(queue.snapshot.map((e) => e.input), ['装配层验证']);

      await queue.dispose();
    });

    test('outboxQueueProvider **不**是 autoDispose（重试计时器要活过对话页）', () {
      // 语义与桌面端同（见那边同组用例的详细说明）：队列持有重试计时器，
      // 而对话页是 autoDispose——队列若随页面释放，用户「断网发一条 →
      // 退出对话 → 网络恢复」后消息永远不会被重试。
      //
      // 移动端尤其致命：用户切走 App 是常态（不是例外）。
      expect(
        outboxQueueProvider.isAutoDispose,
        isFalse,
        reason: '改成 Provider.autoDispose 会让重试计时器随页面一起消失',
      );
    });
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

    final store = InMemoryTokenStore(freshTokens());
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

    final store = InMemoryTokenStore(freshTokens());
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
}
