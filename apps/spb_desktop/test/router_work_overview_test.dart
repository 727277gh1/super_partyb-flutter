import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

const _overviewPlatforms = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
});

Future<void> _pressBackShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('从工作概览进入确认、异常任务和交付物预览', (tester) async {
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    const groupId = 'grp_overview';
    const group = {
      'id': groupId,
      'title': '发布版本',
      'status': 'active',
      'current_goal': {
        'goal': {
          'id': 'goal1',
          'goal_text': '完成发布',
          'current_task_id': 'TASK-002',
        },
        'tasks': [
          {
            'goal_id': 'goal1',
            'task_id': 'TASK-001',
            'title': '整理资料',
            'status': 'completed',
          },
          {
            'goal_id': 'goal1',
            'task_id': 'TASK-002',
            'title': '检查签名',
            'status': 'error_stopped',
          },
        ],
        'progress': {'total': 2, 'completed': 1, 'error_stopped': 1},
      },
    };
    final ufs = FakeUfsApi()
      ..entries = [
        ufsFile(groupId, 'reports/check.txt', id: 'file_overview'),
        ufsFile(groupId, 'reports/notes.txt', id: 'file_notes'),
      ]
      ..bytes = utf8.encode('签名检查结果');
    var groupRequests = 0;
    var confirmationRequests = 0;
    var resolved = false;
    final h = await pumpApp(
      tester,
      initialLocation: SpbRoutes.workOverview,
      mockGroups: false,
      mockPendingConfirmations: false,
      ufsApi: ufs,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/groups',
          (server) => server.replyCallback(200, (_) {
            groupRequests++;
            return {
              'items': [group],
            };
          }),
          queryParameters: {'limit': 30, 'offset': 0},
        );
        adapter.onGet(
          '/chat/groups/$groupId',
          (server) => server.reply(200, group),
        );
        adapter.onGet(
          '/chat/confirmations',
          (server) => server.replyCallback(200, (_) {
            confirmationRequests++;
            return {
              'items': [
                if (!resolved)
                  {
                    'id': 'confirm_overview',
                    'group_id': groupId,
                    'turn_id': 'turn_overview',
                    'status': 'pending',
                    'decision': {'reason': '是否继续发布？'},
                  },
              ],
            };
          }),
          queryParameters: {'status': 'pending', 'limit': 50},
        );
        adapter.onPost(
          '/api/chat/groups/$groupId/confirmations/confirm_overview/resolve',
          (server) => server.replyCallback(200, (_) {
            resolved = true;
            return {'status': 'resolved'};
          }),
          data: {'action': 'approve'},
        );
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('工作概览'), findsOneWidget);
    expect(find.text('1 项待确认'), findsOneWidget);
    expect(groupRequests, 1);

    await tester.tap(find.text('1 项待确认'));
    await tester.pumpAndSettle();
    expect(find.text('是否继续发布？'), findsOneWidget);
    expect(confirmationRequests, 1, reason: '首页和收件箱共用已完成的查询');
    await tester.tap(
      find.byKey(const ValueKey('pending-confirmation-approve')),
    );
    await tester.pumpAndSettle();
    expect(resolved, isTrue);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.text('暂无待确认事项'), findsOneWidget);

    await tester.tap(find.text('失败与阻塞'));
    await tester.pumpAndSettle();
    expect(find.text('异常任务'), findsOneWidget);
    await tester.tap(find.text('发布版本'));
    await tester.pumpAndSettle();
    expect(find.byType(GoalTasksPanel), findsOneWidget);
    expect(
      find.byType(GoalTasksPanel).evaluate().single.widget,
      isA<GoalTasksPanel>().having(
        (panel) => panel.focusTaskId,
        '定位任务',
        'TASK-002',
      ),
    );
    expect(find.text('检查签名'), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.text('异常任务'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '交付物'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupDeliverablesPanel), findsNothing);
    await tester.tap(find.text('发布版本'));
    await tester.pumpAndSettle();
    expect(find.text('check.txt'), findsOneWidget);
    tester.view.physicalSize = const Size(900, 850);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.visibility_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('签名检查结果'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-file-switcher')), findsNothing);
    tester.view.physicalSize = const Size(1200, 850);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('preview-file-switcher')), findsOneWidget);
    if (isWindows) {
      final firstFile = find.widgetWithText(ListTile, 'reports/check.txt');
      tester.widget<ListTile>(firstFile).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<ListTile>(firstFile).selected, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    } else {
      await tester.tap(find.text('reports/notes.txt'));
    }
    await tester.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(ufs.downloadCalls, ['file_overview', 'file_notes']);
    if (isWindows) {
      await _pressBackShortcut(tester);
    } else {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.text('check.txt'), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(WorkOverviewPage), findsOneWidget);
    expect(groupRequests, 1, reason: '返回后保留已加载工作列表');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('小程序工作台'), findsOneWidget);
    expect(find.text('习惯'), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    if (isWindows) {
      await _pressBackShortcut(tester);
      await _pressBackShortcut(tester);
    } else {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(find.text('工作概览'), findsOneWidget);
    h.router.go(SpbRoutes.home);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选已加载的对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务阻塞'));
    await tester.pumpAndSettle();
    expect(find.text('已加载的对话中暂无匹配项'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选已加载的对话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('任务失败'));
    await tester.pumpAndSettle();
    expect(find.text('发布版本'), findsOneWidget);
    expect(groupRequests, 1, reason: '筛选和切换共用已加载窗口');
  }, variant: _overviewPlatforms);

  testWidgets('桌面会话侧栏复用对话列表并保持返回路径', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const groups = [
      {'id': 'g1', 'title': '发布版本', 'status': 'active'},
      {'id': 'g2', 'title': '处理反馈', 'status': 'active'},
    ];
    var requests = 0;
    final h = await pumpApp(
      tester,
      mockGroups: false,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/groups',
          (server) => server.replyCallback(200, (_) {
            requests++;
            return {'items': groups};
          }),
          queryParameters: {'limit': 30, 'offset': 0},
        );
        for (final group in groups) {
          final id = group['id'];
          adapter.onGet(
            '/chat/groups/$id',
            (server) => server.reply(200, group),
          );
          adapter.onGet(
            '/chat/groups/$id/timeline',
            (server) => server.reply(200, {'items': <Object>[]}),
            queryParameters: {'limit': 200},
          );
        }
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('发布版本'));
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.chat('g1'));

    final secondConversation = find.byKey(
      const ValueKey('switch-conversation-g2'),
    );
    expect(secondConversation, findsOneWidget);
    expect(requests, 1);
    await tester.tap(secondConversation);
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.chat('g2'));
    expect(tester.widget<ListTile>(secondConversation).selected, isTrue);
    expect(requests, 1);

    tester.view.physicalSize = const Size(900, 850);
    await tester.pumpAndSettle();
    expect(secondConversation, findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.home);
  });

  testWidgets('Windows 对话列表键盘滚动、打开、切换和返回', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 650);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final groups = [
      for (var index = 1; index <= 16; index++)
        {'id': 'g$index', 'title': '测试对话 $index', 'status': 'active'},
    ];
    final h = await pumpApp(
      tester,
      mockGroups: false,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/groups',
          (server) => server.reply(200, {'items': groups}),
          queryParameters: {'limit': 30, 'offset': 0},
        );
        for (final group in groups.skip(13)) {
          final id = group['id'];
          adapter.onGet(
            '/chat/groups/$id',
            (server) => server.reply(200, group),
          );
          adapter.onGet(
            '/chat/groups/$id/timeline',
            (server) => server.reply(200, {'items': <Object>[]}),
            queryParameters: {'limit': 200},
          );
        }
      },
    );
    await tester.pumpAndSettle();

    Finder row(int index) => find.ancestor(
      of: find.text('测试对话 $index'),
      matching: find.byType(InkWell),
    );
    FocusNode rowFocus(int index) =>
        tester.widget<InkWell>(row(index)).focusNode!;

    expect(row(15).hitTestable(), findsNothing);
    for (var tab = 0; tab < 20 && !rowFocus(1).hasPrimaryFocus; tab++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(rowFocus(1).hasPrimaryFocus, isTrue);
    for (var index = 2; index <= 16; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(rowFocus(index).hasPrimaryFocus, isTrue);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(rowFocus(15).hasPrimaryFocus, isTrue);
    expect(row(15).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.chat('g15'));

    final switcher = find.byKey(
      const ValueKey('desktop-conversation-switcher'),
    );
    final previous = find.byKey(const ValueKey('switch-conversation-g14'));
    await tester.drag(switcher, const Offset(0, -700));
    await tester.pumpAndSettle();
    tester.widget<ListTile>(previous).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.chat('g16'));

    final field = find.descendant(
      of: find.byType(MessageComposer),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, '草稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      tester.widget<EditableText>(field).controller.selection.baseOffset,
      1,
    );
    await _pressBackShortcut(tester);
    expect(
      tester.widget<EditableText>(field).controller.selection.baseOffset,
      0,
    );
    expect(h.router.state.uri.path, SpbRoutes.chat('g16'));

    unawaited(
      showDialog<void>(
        context: tester.element(field),
        builder: (_) => const AlertDialog(title: Text('测试弹窗')),
      ),
    );
    await tester.pumpAndSettle();
    await _pressBackShortcut(tester);
    expect(find.text('测试弹窗'), findsNothing);
    expect(h.router.state.uri.path, SpbRoutes.chat('g16'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _pressBackShortcut(tester);
    expect(h.router.state.uri.path, SpbRoutes.home);
    await _pressBackShortcut(tester);
    expect(h.router.state.uri.path, SpbRoutes.home);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}
