import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';

/// 设置页测试。
///
/// ## 这个测试防的是什么
///
/// 设置页的失败模式大多**静默**，而且代价高：
/// - **改动即时落盘** → 用户改到一半退出，留下混合配置（新目录 + 旧范围）；
/// - **选目录就落盘** → 用户想换个目录，旧目录的同步状态已被清掉（不可逆）；
/// - **「全部」与「勾选若干」同时生效** → 用户以为只同步 2 个对话，实际全同步；
/// - **移动端展示托盘/快捷键开关** → 点了没反应，用户以为功能坏了；
/// - **清理不确认就删** → 不可逆的数据损失。
///
/// 故这里逐条断言：表单草稿语义、保存整份提交、范围互斥、能力项按平台显隐、
/// 清理的「预览 → 确认」两段式。
/// 两个符合 `isGroupId` 形状（32 位小写十六进制）的目录名。
///
/// 写成字面量而非 `'a' * 32`：后者不是编译期常量，不能用在 `const` 构造里。
const _gidA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _gidB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  /// 把设置页放进最小可用的 MaterialApp。
  Future<void> pumpSettings(
    WidgetTester tester, {
    SyncSettings initial = const SyncSettings(),
    List<ChatGroup> groups = const [],
    List<LocalGroupStats> localGroups = const [],
    DesktopCapabilities? capabilities,
    Future<void> Function(SyncSettings)? onSave,
    Future<PruneOutcome> Function(PrunePlan)? onPrune,
    Future<String?> Function()? pickDirectory,
    Future<SyncSettings> Function()? loadSettings,
    Future<void> Function()? onSignOut,
    Future<bool> Function()? loadLaunchAtStartup,
    Future<void> Function(bool)? setLaunchAtStartup,
  }) async {
    // ## 为什么要把测试窗口调高
    //
    // 设置页是一个 ListView，而 ListView **惰性构建**：屏幕外的条目在 widget
    // 树里根本不存在，`find.byKey` 自然找不到，`tap()` 也会因为坐标在窗口外
    // 而报 "would not hit test"。
    //
    // 默认测试窗口是 800×600，而设置页有 5 个分节（目录/范围/过滤/本地数据/
    // 桌面集成），必然超出一屏。用足够高的窗口让全部条目一次性构建，
    // 测试才是在验证页面逻辑而不是在验证滚动。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          loadSettings: loadSettings ?? () async => initial,
          saveSettings: onSave ?? (_) async {},
          loadGroups: () async => groups,
          scanGroups: () async => localGroups,
          executePrune:
              onPrune ??
              (_) async => const PruneOutcome(deleted: 0, failed: {}),
          pickDirectory: pickDirectory ?? () async => null,
          capabilities: capabilities ?? const NoopDesktopCapabilities(),
          onSignOut: onSignOut,
          loadLaunchAtStartup: loadLaunchAtStartup,
          setLaunchAtStartup: setLaunchAtStartup,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 构造一个对话。**不要**命名为 `group`——那会遮蔽 test 框架的 `group()`。
  ChatGroup chatGroup(String id, String title, {bool archived = false}) =>
      ChatGroup(
        id: id,
        userId: 'u1',
        title: title,
        status: archived ? 'archived' : 'active',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );

  group('设置页：表单草稿语义（改动不即时落盘）', () {
    testWidgets('未改动时隐藏「保存」按钮', (tester) async {
      await pumpSettings(tester);
      expect(
        find.byKey(const ValueKey('settings-save')),
        findsNothing,
        reason: '无改动时不该出现保存按钮（避免用户以为必须点一下）',
      );
    });

    testWidgets('切换媒体开关后出现保存按钮，但未保存前不落盘', (tester) async {
      var saves = 0;
      await pumpSettings(tester, onSave: (_) async => saves++);

      await tester.tap(find.byKey(const ValueKey('settings-include-media')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-save')),
        findsOneWidget,
        reason: '有未保存改动时应出现保存入口',
      );
      expect(saves, 0, reason: '未点保存不得落盘');
    });

    testWidgets('点保存把整份设置一次性提交', (tester) async {
      SyncSettings? saved;
      await pumpSettings(tester, onSave: (s) async => saved = s);

      await tester.tap(find.byKey(const ValueKey('settings-include-media')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.filter.includeMedia, isTrue, reason: '保存的应是用户刚改的值');
      expect(
        find.byKey(const ValueKey('settings-saved')),
        findsOneWidget,
        reason: '保存成功应有明确反馈',
      );
    });

    testWidgets('选目录只回填草稿：不落盘、不改已保存状态', (tester) async {
      // 回归防线：若选目录就落盘，用户「想换一个目录」时旧目录的同步状态
      // 已被清掉——那是不可逆的（增量游标已丢，下次要全量重拉）。
      var saves = 0;
      await pumpSettings(
        tester,
        pickDirectory: () async => '/home/u/new-root',
        onSave: (_) async => saves++,
      );

      await tester.tap(find.byKey(const ValueKey('settings-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.text('/home/u/new-root'), findsOneWidget);
      expect(saves, 0, reason: '选目录不得落盘，保存才落盘');
    });

    testWidgets('取消选目录不改变现有目录', (tester) async {
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/keep-me'),
        pickDirectory: () async => null, // 用户取消
      );

      await tester.tap(find.byKey(const ValueKey('settings-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.text('/home/u/keep-me'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-save')),
        findsNothing,
        reason: '取消不构成改动',
      );
    });
  });

  group('设置页：同步范围', () {
    testWidgets('默认「全部对话」开启，不展示勾选列表', (tester) async {
      await pumpSettings(tester, groups: [chatGroup('g1', '对话一')]);

      final sw = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings-scope-all')),
      );
      expect(sw.value, isTrue, reason: '默认全部：设置页没有 group 上下文');
      expect(
        find.byKey(const ValueKey('settings-group-g1')),
        findsNothing,
        reason: '「全部」模式下勾选列表无意义，不该展示',
      );
    });

    testWidgets('关掉「全部」后展示可勾选的对话并保存选中项', (tester) async {
      SyncSettings? saved;
      await pumpSettings(
        tester,
        groups: [chatGroup('g1', '对话一'), chatGroup('g2', '对话二')],
        onSave: (s) async => saved = s,
      );

      await tester.tap(find.byKey(const ValueKey('settings-scope-all')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-group-g1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-group-g2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved!.scope.allGroups, isFalse);
      expect(saved!.scope.groupIds, ['g2']);
    });

    testWidgets('重新打开「全部」时保留已勾选项（用户可来回切换）', (tester) async {
      SyncSettings? saved;
      await pumpSettings(
        tester,
        groups: [chatGroup('g1', '对话一')],
        onSave: (s) async => saved = s,
      );

      await tester.tap(find.byKey(const ValueKey('settings-scope-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-group-g1')));
      await tester.pumpAndSettle();
      // 再打开「全部」：勾选项应保留（否则用户来回切一次就丢了勾选）。
      await tester.tap(find.byKey(const ValueKey('settings-scope-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved!.scope.allGroups, isTrue);
      expect(saved!.scope.groupIds, ['g1']);
    });

    testWidgets('已归档对话也可勾选并标注状态', (tester) async {
      await pumpSettings(
        tester,
        initial: const SyncSettings(
          scope: SyncScopeConfig(allGroups: false, groupIds: ['g1']),
        ),
        groups: [chatGroup('g1', '旧对话', archived: true)],
      );

      expect(find.text('已归档'), findsOneWidget);
    });
  });

  group('设置页：过滤与拉取范围', () {
    testWidgets('媒体开关默认关闭（生产媒体占体积绝大多数）', (tester) async {
      await pumpSettings(tester);

      final sw = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings-include-media')),
      );
      expect(sw.value, isFalse);
    });

    testWidgets('单文件上限以 MB 展示，保存时换算成字节', (tester) async {
      SyncSettings? saved;
      await pumpSettings(
        tester,
        initial: const SyncSettings(
          filter: SyncFilterConfig(maxFileSize: 5 * 1024 * 1024),
        ),
        onSave: (s) async => saved = s,
      );

      expect(find.widgetWithText(TextField, '5'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('settings-max-file-size')),
        '20',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(
        saved!.filter.maxFileSize,
        20 * 1024 * 1024,
        reason: 'UI 输入是 MB，落盘必须是字节',
      );
    });

    testWidgets('单文件上限为 0 表示不限（不换算成 0 字节的限制）', (tester) async {
      SyncSettings? saved;
      await pumpSettings(
        tester,
        initial: const SyncSettings(
          filter: SyncFilterConfig(maxFileSize: 10 * 1024 * 1024),
        ),
        onSave: (s) async => saved = s,
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-max-file-size')),
        '0',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved!.filter.maxFileSize, 0);
    });

    testWidgets('清空上限输入框不会把上限改成 0（保留最后一次有效输入）', (tester) async {
      // 用户在输入过程中会先清空再打新数字。若「空」被当成 0，会静默把
      // 上限变成「不限」，一次误触就能拉下几百 MB 的媒体。
      SyncSettings? saved;
      await pumpSettings(
        tester,
        initial: const SyncSettings(
          filter: SyncFilterConfig(maxFileSize: 10 * 1024 * 1024),
        ),
        onSave: (s) async => saved = s,
      );

      await tester.enterText(
        find.byKey(const ValueKey('settings-max-file-size')),
        '20',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-max-file-size')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(
        saved!.filter.maxFileSize,
        20 * 1024 * 1024,
        reason: '清空是输入中间态，不该被当成「不限（0）」',
      );
    });

    testWidgets('拉取范围默认「不限」，可切到近 7 天并保存', (tester) async {
      SyncSettings? saved;
      await pumpSettings(tester, onSave: (s) async => saved = s);

      expect(find.text('不限'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-since-days')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('近 7 天').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved!.sinceDays, 7);
    });

    testWidgets('拉取范围选回「不限」时清空 sinceDays（而非保留旧值）', (tester) async {
      // copyWith 的经典陷阱：传 null 会被「?? 保留旧值」吃掉，导致用户选
      // 「不限」后实际仍是近 7 天。
      SyncSettings? saved;
      await pumpSettings(
        tester,
        initial: const SyncSettings(sinceDays: 7),
        onSave: (s) async => saved = s,
      );

      await tester.tap(find.byKey(const ValueKey('settings-since-days')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不限').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(saved!.sinceDays, isNull);
    });
  });

  group('设置页：桌面能力项按平台显隐', () {
    testWidgets('移动端（isSupported=false）不展示桌面集成项', (tester) async {
      await pumpSettings(tester, capabilities: const NoopDesktopCapabilities());

      expect(
        find.byKey(const ValueKey('settings-capabilities')),
        findsNothing,
        reason: '移动端展示托盘/快捷键开关，点了没反应，比不展示更糟',
      );
    });

    testWidgets('桌面端展示桌面集成项，快捷键文案取自 HotkeyBinding', (tester) async {
      await pumpSettings(tester, capabilities: _FakeDesktopCapabilities());

      expect(
        find.byKey(const ValueKey('settings-capabilities')),
        findsOneWidget,
      );
      expect(
        find.text(HotkeyBinding.quickCapture.label),
        findsOneWidget,
        reason: '快捷键文案应取绑定对象的 label，避免把 Alt+Space 硬编码在页面里',
      );
    });
  });

  group('设置页：本地统计与清理', () {
    testWidgets('展示本地统计（目录数/文件数/体积）', (tester) async {
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/out'),
        localGroups: const [
          LocalGroupStats(
            groupId: _gidA,
            fileCount: 3,
            totalBytes: 1024,
            newestMtime: 1000,
          ),
          LocalGroupStats(
            groupId: _gidB,
            fileCount: 2,
            totalBytes: 2048,
            newestMtime: 1000,
          ),
        ],
      );

      expect(find.text('2 个对话目录'), findsOneWidget);
      expect(find.text('5 个文件'), findsOneWidget);
      expect(find.text('3.0 KB'), findsOneWidget);
    });

    testWidgets('未选目录时清理按钮禁用', (tester) async {
      await pumpSettings(tester);

      final btn = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('settings-prune')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('清理是两段式：先选策略，再确认（含数量与体积）', (tester) async {
      var executed = 0;
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/out'),
        localGroups: [
          LocalGroupStats(
            groupId: _gidA,
            fileCount: 3,
            totalBytes: 5 * 1024 * 1024,
            // 很旧的 mtime：超过 30 天
            newestMtime: nowUnix() - 60 * 86400,
          ),
        ],
        onPrune: (_) async {
          executed++;
          return const PruneOutcome(deleted: 1, failed: {});
        },
      );

      await tester.tap(find.byKey(const ValueKey('settings-prune')));
      await tester.pumpAndSettle();

      // 第一段：策略选择
      expect(find.text('清理本地文件'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('settings-prune-next')));
      await tester.pumpAndSettle();

      // 第二段：确认（必须展示将删什么）
      expect(
        find.byKey(const ValueKey('settings-prune-confirm')),
        findsOneWidget,
      );
      expect(find.textContaining('将删除 1 个对话目录'), findsOneWidget);
      // 体积要断言在**确认框内**：统计卡片上也有同一个数字，用全局查找会
      // 误命中它，从而掩盖「确认框没展示体积」这个真实缺陷。
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('5.0 MB'),
        ),
        findsOneWidget,
      );
      expect(executed, 0, reason: '确认前不得执行删除');

      await tester.tap(find.byKey(const ValueKey('settings-prune-confirm')));
      await tester.pumpAndSettle();

      expect(executed, 1);
    });

    testWidgets('在确认框取消则不执行删除', (tester) async {
      var executed = 0;
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/out'),
        localGroups: [
          LocalGroupStats(
            groupId: _gidA,
            fileCount: 1,
            totalBytes: 10,
            newestMtime: nowUnix() - 60 * 86400,
          ),
        ],
        onPrune: (_) async {
          executed++;
          return const PruneOutcome(deleted: 1, failed: {});
        },
      );

      await tester.tap(find.byKey(const ValueKey('settings-prune')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prune-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(executed, 0, reason: '取消是不可逆删除的最后一道防线');
    });

    testWidgets('没有符合条件的目录时给出提示，不进入确认流程', (tester) async {
      var executed = 0;
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/out'),
        // 刚同步过：不满足「超过 30 天」
        localGroups: [
          LocalGroupStats(
            groupId: 'a' * 32,
            fileCount: 1,
            totalBytes: 10,
            newestMtime: nowUnix(),
          ),
        ],
        onPrune: (_) async {
          executed++;
          return const PruneOutcome(deleted: 0, failed: {});
        },
      );

      await tester.tap(find.byKey(const ValueKey('settings-prune')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prune-next')));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有符合条件'), findsOneWidget);
      expect(executed, 0);
    });

    testWidgets('清理失败时展示失败原因而非静默成功', (tester) async {
      await pumpSettings(
        tester,
        initial: const SyncSettings(localRoot: '/home/u/out'),
        localGroups: [
          LocalGroupStats(
            groupId: 'a' * 32,
            fileCount: 1,
            totalBytes: 10,
            newestMtime: nowUnix() - 60 * 86400,
          ),
        ],
        onPrune: (_) async =>
            const PruneOutcome(deleted: 0, failed: {_gidA: '权限不足'}),
      );

      await tester.tap(find.byKey(const ValueKey('settings-prune')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prune-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-prune-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('权限不足'), findsOneWidget);
    });
  });

  group('设置页：错误处理', () {
    testWidgets('读取设置失败时展示错误与重试', (tester) async {
      await pumpSettings(
        tester,
        loadSettings: () async => throw const StorageError('库损坏'),
      );

      expect(find.textContaining('读取设置失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('保存失败时展示原因并保留未保存改动', (tester) async {
      await pumpSettings(
        tester,
        onSave: (_) async => throw const StorageError('磁盘已满'),
      );

      await tester.tap(find.byKey(const ValueKey('settings-include-media')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('磁盘已满'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-save')),
        findsOneWidget,
        reason: '保存失败后改动应仍视为未保存，用户可重试',
      );
    });

    testWidgets('对话列表读取失败时可重试，且不阻塞其余设置', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            loadSettings: () async => const SyncSettings(
              scope: SyncScopeConfig(allGroups: false, groupIds: ['g1']),
            ),
            saveSettings: (_) async {},
            loadGroups: () async => throw const NetworkError('网络不可用'),
            scanGroups: () async => const [],
            executePrune: (_) async =>
                const PruneOutcome(deleted: 0, failed: {}),
            pickDirectory: () async => null,
            capabilities: const NoopDesktopCapabilities(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('读取对话列表失败'), findsOneWidget);
      // 其余设置仍可操作（媒体开关仍在）。
      expect(
        find.byKey(const ValueKey('settings-include-media')),
        findsOneWidget,
      );
    });
  });

  group('设置页：退出登录', () {
    testWidgets('未注入 onSignOut 时不展示入口（无认证的用法）', (tester) async {
      await pumpSettings(tester);
      expect(find.byKey(const ValueKey('settings-sign-out')), findsNothing);
    });

    testWidgets('点击需二次确认：取消则不清会话', (tester) async {
      var calls = 0;
      await pumpSettings(tester, onSignOut: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
      await tester.pumpAndSettle();

      // 确认框出现，但还没调用。
      expect(
        find.byKey(const ValueKey('settings-sign-out-confirm')),
        findsOneWidget,
      );
      expect(calls, 0, reason: '打开确认框本身不得清会话');

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '取消后绝不能清会话（登出代价是重走 OIDC 登录）');
      expect(
        find.byKey(const ValueKey('settings-sign-out-confirm')),
        findsNothing,
      );
    });

    testWidgets('确认后调用注入的 onSignOut 恰好一次', (tester) async {
      var calls = 0;
      await pumpSettings(tester, onSignOut: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-sign-out-confirm')));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('登出失败时展示原因，且入口重新可点（可重试）', (tester) async {
      var calls = 0;
      await pumpSettings(
        tester,
        onSignOut: () async {
          calls++;
          throw StateError('网络断了');
        },
      );

      await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-sign-out-confirm')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.textContaining('退出登录失败'), findsOneWidget);

      // 失败后必须能再试：否则用户被卡在「登不出去」的状态里。
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('settings-sign-out')),
      );
      expect(tile.enabled, isTrue);
      expect(tile.onTap, isNotNull);
    });

    testWidgets('提交中禁用入口（防重复登出）', (tester) async {
      // 用 Completer 把回调挂起，模拟「请求在途」。
      final gate = Completer<void>();
      await pumpSettings(tester, onSignOut: () => gate.future);

      await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-sign-out-confirm')));
      await tester.pump();

      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('settings-sign-out')),
      );
      expect(tile.enabled, isFalse, reason: '在途期间不得再点（避免重复清会话）');
      expect(tile.onTap, isNull);

      gate.complete();
      await tester.pumpAndSettle();

      // 成功之后**仍然**禁用：调用方会导航走本页（登出后回登录页），
      // 若在这里复位，用户会在跳转前的那一帧看到按钮又变回可点，
      // 点下去就是第二次登出。
      final after = tester.widget<ListTile>(
        find.byKey(const ValueKey('settings-sign-out')),
      );
      expect(after.enabled, isFalse, reason: '登出成功后不得复位为可点');
      expect(after.onTap, isNull);
    });
  });
}

/// 桌面能力桩（`isSupported == true` 以触发桌面专属区块）。
class _FakeDesktopCapabilities implements DesktopCapabilities {
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
  Future<bool> isLaunchAtStartupEnabled() async => false;

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}

  @override
  Future<void> setTrayTooltip(String tooltip) async {}

  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  @override
  Future<void> dispose() async {}
}
