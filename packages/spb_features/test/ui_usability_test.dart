import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

void main() {
  SettingsPage settings({Future<void> Function(SyncSettings)? save}) =>
      SettingsPage(
        loadSettings: () async => const SyncSettings(localRoot: '/tmp/files'),
        saveSettings: save ?? (_) async {},
        loadGroups: () async => [],
        scanGroups: () async => [],
        executePrune: (_) async => const PruneOutcome(deleted: 0, failed: {}),
        pickDirectory: () async => null,
        initialTab: SettingsTab.sync,
        runSync: () async => SyncReport(),
      );

  Future<void> pumpSettings(
    WidgetTester tester, {
    Future<void> Function(SyncSettings)? save,
  }) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: SpbTheme.light(),
        initialRoute: '/settings',
        routes: {
          '/': (_) => const Scaffold(body: Text('首页')),
          '/settings': (_) => settings(save: save),
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-include-media')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-unsaved-notice')),
      findsOneWidget,
    );
  }

  testWidgets('取消离开保留草稿，放弃后才返回且不保存', (tester) async {
    var saves = 0;
    await pumpSettings(tester, save: (_) async => saves++);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('settings-include-media')),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-discard-leave')));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
    expect(saves, 0);
  });

  testWidgets('保存失败保留页面与草稿，再试成功才离开', (tester) async {
    var fail = true;
    SyncSettings? saved;
    await pumpSettings(
      tester,
      save: (value) async {
        if (fail) throw StateError('磁盘已满');
        saved = value;
      },
    );
    for (final attempt in [0, 1]) {
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-save-leave')));
      await tester.pumpAndSettle();
      if (attempt == 0) {
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(find.text('保存失败，修改已保留，请重试'), findsOneWidget);
        expect(saved, isNull);
        fail = false;
      }
    }
    expect(saved!.filter.includeMedia, isTrue);
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('保存期间再次返回不能丢弃在途修改', (tester) async {
    final pending = Completer<void>();
    await pumpSettings(tester, save: (_) => pending.future);
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('首页'), findsOneWidget);
  });

  testWidgets('同步操作在手机首屏可见，桌面表单宽度有限', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final size in [const Size(375, 812), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(theme: SpbTheme.light(), home: settings()),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('sync-start-button'));
      expect(tester.getRect(button).bottom, lessThan(size.height));
      expect(button.hitTestable(), findsOneWidget);
      expect(
        tester.getSize(find.byType(ListView)).width,
        lessThanOrEqualTo(880),
      );
      expect(find.text('同步有四条下行通道'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('侧栏所有入口在 320dp 与 2 倍字号下可点且报告选中态', (tester) async {
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    final semantics = tester.ensureSemantics();
    const labels = ['交付物', '待办', '设置', '目标', '任务', '续跑', '动态'];
    await tester.pumpWidget(
      MaterialApp(
        theme: SpbTheme.lightFor(TargetPlatform.linux),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ChatSidebar(
              tabs: [
                for (final label in labels)
                  ChatSidebarTab(
                    label: label,
                    icon: Icons.folder_outlined,
                    content: Text('$label内容'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in labels) {
      final tab = find.byKey(ValueKey('sidebar-tab-$label'));
      expect(tab.hitTestable(), findsOneWidget);
      await tester.tap(tab);
      await tester.pump();
      expect(
        tester.getSemantics(tab).getSemanticsData().flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(find.text('$label内容'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('深色同步页在横竖屏、两倍字号和减少动画下仍可编辑', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    for (final size in [const Size(375, 812), const Size(812, 375)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          theme: SpbTheme.darkFor(TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: settings(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('同步方式说明'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.text('同步方式说明').hitTestable(), findsOneWidget);
      await tester.tap(find.text('同步方式说明'));
      await tester.pumpAndSettle();
      final media = find.byKey(const ValueKey('settings-include-media'));
      await tester.scrollUntilVisible(
        media,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(media.hitTestable(), findsOneWidget);
      await tester.tap(media);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-save')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
