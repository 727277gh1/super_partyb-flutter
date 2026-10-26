import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 设置页 / 同步页 / 主题 / 托盘 / 开机自启（router 装配）
///
/// ⚠️ 本文件由 `widget_test.dart` 按顶层用例边界拆出（issue #48）——
/// 纯移动，未改动任何断言。共享夹具见 `support/desktop_harness.dart`。
void main() {
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
    final h = await pumpApp(tester, capabilities: FakeDesktopCapabilities());

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-capabilities')), findsOneWidget);
    // 移动端不展示这一段（见 spb_features 的设置页用例）。
    expect(find.text('系统托盘'), findsOneWidget);
  });

  testWidgets('桌面端设置页有「导出诊断日志」入口，点击交给能力实现（issue #40）', (tester) async {
    // ## 这个用例防的是什么
    //
    // `SettingsPage.onExportDiagnostics` 默认是 null（未注入即隐藏）。页面自身
    // 的测试自己传参，**抓不到「router 忘了传」**——而本仓库最常见的失败模式
    // 就是「功能齐全但无人调用」（见 AGENTS.md §6.17）。故从 router 层断言。
    //
    // 同时验证**真的走到了能力层**：导出文本与文件名经
    // `exportDiagnosticsReport` → `capabilities.saveDiagnostics`，而不是在
    // 页面里拼一份不经脱敏的字符串。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final caps = FakeDesktopCapabilities();
    final h = await pumpApp(tester, capabilities: caps);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('settings-export-diagnostics'));
    expect(entry, findsOneWidget, reason: '桌面端必须有入口');

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(caps.exportedDiagnostics, hasLength(1));
    final report = caps.exportedDiagnostics.single;
    expect(report, contains('Super PartyB 诊断报告'));
    expect(report, contains('## 运行环境'));
    expect(report, contains('## 最近日志'));
  });

  testWidgets('导出诊断日志：失败时给用户反馈（不静默）', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final caps = FakeDesktopCapabilities()
      ..diagnosticsOutcome = DiagnosticsExportOutcome.failed;
    final h = await pumpApp(tester, capabilities: caps);

    h.router.go(SpbRoutes.settings);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-export-diagnostics')));
    await tester.pumpAndSettle();

    expect(find.text('导出诊断报告失败，请重试'), findsOneWidget);
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

  testWidgets('注入的 desktopCapabilitiesProvider 生效（空实现）', (tester) async {
    final h = await pumpApp(tester);

    expect(
      h.container.read(desktopCapabilitiesProvider),
      isA<NoopDesktopCapabilities>(),
    );
  });

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
  group('托盘提示接线', () {
    testWidgets('启动时推送一次托盘提示（否则永远是托盘库的默认值）', (tester) async {
      final caps = FakeDesktopCapabilities();
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
      final caps = FakeDesktopCapabilities();
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
      final caps = FakeDesktopCapabilities();
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
      final caps = FakeDesktopCapabilities();
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
      final caps = FakeDesktopCapabilities()..launchAtStartupEnabled = true;
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
      final caps = FakeDesktopCapabilities();
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

  group('自动同步（桌面端）', () {
    /// 设置页是惰性 `ListView`，「自动同步」区块在「过滤与范围」之后，
    /// 默认 800×600 下落在屏幕外。
    void useTallWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('桌面端渲染自动同步区块（启动同步 + 周期档位）', (tester) async {
      useTallWindow(tester);
      final h = await pumpApp(tester, syncLocalRoot: '/home/u/out');

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-auto-sync-on-launch')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-auto-sync-interval')),
        findsOneWidget,
      );
    });

    testWidgets('自动同步初值来自注入的设置', (tester) async {
      useTallWindow(tester);
      final h = await pumpApp(
        tester,
        syncLocalRoot: '/home/u/out',
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/home/u/out',
          auto: AutoSyncConfig(onLaunch: true, intervalMinutes: 30),
        ),
      );

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      final tile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings-auto-sync-on-launch')),
      );
      expect(tile.value, isTrue);
      expect(find.text('每 30 分钟'), findsOneWidget);
    });

    testWidgets('改动自动同步会随整份提交一起落盘', (tester) async {
      useTallWindow(tester);
      SyncSettings? saved;
      final h = await pumpApp(
        tester,
        syncLocalRoot: '/home/u/out',
        saveSyncSettings: (s) async => saved = s,
      );

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('settings-auto-sync-on-launch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.auto.onLaunch, isTrue);
      expect(saved!.auto.intervalMinutes, 0);
    });

    testWidgets('保存设置后把新配置喂给调度器', (tester) async {
      // ## 这条守的是「配置改了但排程没跟着变」
      //
      // 只断言 `saveSyncSettings` 收到新值是不够的——那只证明落盘了，
      // 不证明**当前会话**的排程器看到了它（用户会以为要重启才生效）。
      useTallWindow(tester);
      final scheduler = NoopAutoSyncScheduler();
      // 可变的「已落盘设置」：保存后 `reconcile` 会**再读一次**，故必须
      // 让它读到新值，否则断言只证明「喂了旧值」。
      var stored = const SyncSettings(localRoot: '/home/u/out');
      final h = await pumpApp(
        tester,
        syncLocalRoot: '/home/u/out',
        autoSyncScheduler: scheduler,
        saveSyncSettings: (s) async => stored = s,
        loadSyncSettings: () async => stored,
      );

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      // 打开周期同步（默认「关闭」），再保存。
      await tester.tap(
        find.byKey(const ValueKey('settings-auto-sync-interval')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('每 15 分钟').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(
        scheduler.applied,
        contains(const AutoSyncConfig(intervalMinutes: 15)),
        reason: '保存后必须 reconcile，否则新配置要等重启才生效',
      );
    });
  });

  group('会话失效 → 回登录页（AuthInterceptor.onSessionExpired 接线）', () {
    /// 把测试窗口调高（设置页是惰性 ListView，目标条目可能在屏幕外）。
    void useTallWindow(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    // ## 这个 group 防的是什么
    //
    // 修复前，401 只被归一化成 `AuthError` 抛给调用方，而各页面拿到它只翻成
    // 一句 SnackBar 文案（「登录已过期，请重新登录」）——**没有任何一处**把
    // 认证状态推进到未登录。于是会话真的过期后，用户卡在当前页面，只能手动
    // 进设置页点「退出登录」。
    //
    // 这两条从**装配层**断言整条链路：401 → `onSessionExpired` →
    // `markUnauthenticated` → `AuthRefreshNotifier` → 路由守卫重定向。
    // 只测拦截器回调不够——回调接错了地方（如忘了 `dioProvider` 那一行）
    // 时拦截器单测仍绿，而用户仍然卡住。

    testWidgets('已登录时收到 401 → 回到登录页（且不清凭证）', (tester) async {
      useTallWindow(tester);
      final store = InMemoryTokenStore(freshTokens());
      final h = await pumpApp(tester, tokenStore: store, mockGroups: false);

      // 前置条件：确实处于已登录态（否则本用例空洞通过）。
      expect(
        h.container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '前置条件：必须先处于已登录态',
      );

      h.router.go(SpbRoutes.settings);
      await tester.pumpAndSettle();

      // 模拟一次「刷新也救不回来」的 401。真实触发点是 `dioProvider` 里的
      // `AuthInterceptor.onSessionExpired`，它调的就是这个 notifier 方法。
      h.container
          .read(authStateProvider.notifier)
          .markUnauthenticated('会话已失效，请重新登录');
      await tester.pumpAndSettle();

      expect(
        h.router.state.matchedLocation,
        SpbRoutes.login,
        reason: '会话失效必须回到登录页（修复前这里仍停在 /settings）',
      );
      expect(
        h.router.state.uri.queryParameters['from'],
        SpbRoutes.settings,
        reason: '登录成功后可回跳原页面',
      );
      expect(
        find.text('会话已失效，请重新登录'),
        findsOneWidget,
        reason: '登录页要如实说明为什么被踢回来',
      );
      expect(
        store.clearCount,
        0,
        reason: '会话失效不清凭证：401 可能是网关侧临时问题，清掉会丢 refresh_token',
      );
    });

    test('dioProvider 的拦截器真的接了 onSessionExpired（接线断言）', () async {
      // 上一条直接调 notifier，本用例验证**装配**：`dioProvider` 构造的
      // `AuthInterceptor` 必须把 `onSessionExpired` 接到同一个 notifier。
      //
      // ## 为什么不能走 harness 的 dio
      //
      // `pumpApp` 把 `dioProvider` **整体覆盖**成“挂了 DioAdapter 的 dio”，
      // 那个 dio 没有 AuthInterceptor——在那里发 401 只能得到裸 DioException，
      // 无法验证接线（实测：断言路由仍停在 /settings）。
      //
      // 故这里另建一个只覆盖 `tokenStoreProvider` 的容器，让 `dioProvider`
      // 走**真实实现**，再把它的适配器换成“一律 401”。
      final store = InMemoryTokenStore(freshTokens());
      final container = ProviderContainer(
        overrides: [tokenStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      final dio = container.read(dioProvider);
      dio.httpClientAdapter = _UnauthorizedAdapter();

      // 先等启动恢复完成，确认起点是“已登录”（否则本用例空洞通过）。
      await container.read(authStateProvider.notifier).restore();
      expect(
        container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '前置条件：必须先处于已登录态',
      );

      await expectLater(
        dio.get<dynamic>('/api/auth/me'),
        throwsA(isA<DioException>()),
      );

      expect(
        container.read(authStateProvider).isUnauthenticated,
        isTrue,
        reason: '拦截器的 401 必须推进认证状态（漏接 onSessionExpired 时会停在已登录）',
      );
      expect(store.clearCount, 0, reason: '会话失效不清凭证');
    });
  });
}

/// 一律 401 的适配器（用于验证拦截器的会话失效路径）。
class _UnauthorizedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    '{"error":"unauthorized"}',
    401,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
