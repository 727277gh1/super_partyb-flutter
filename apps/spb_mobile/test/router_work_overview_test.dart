import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

void main() {
  testWidgets('概览在窄屏大字号和横屏保留首要入口', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpApp(tester, initialLocation: SpbRoutes.workOverview);
    await tester.pumpAndSettle();

    void expectPrimaryEntries() {
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('对话').hitTestable(), findsOneWidget);
      for (final label in ['快速对话', '待确认', '当前工作', '交付物']) {
        expect(find.text(label).hitTestable(), findsWidgets);
      }
    }

    expectPrimaryEntries();
    tester.view.physicalSize = const Size(700, 360);
    await tester.pumpAndSettle();
    expectPrimaryEntries();
  });

  testWidgets('从工作概览进入确认、异常任务和交付物预览', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 820);
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
      ..entries = [ufsFile(groupId, 'reports/check.txt', id: 'file_overview')]
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

    await tester.tap(find.text('查看全部待处理'));
    await tester.pumpAndSettle();
    expect(find.text('待你处理'), findsOneWidget);
    expect(find.text('失败与阻塞'), findsOneWidget);
    expect(find.textContaining('检查签名'), findsOneWidget);
    await tester.tap(find.text('是否继续发布？'));
    await tester.pumpAndSettle();
    expect(find.text('确认详情'), findsOneWidget);
    expect(find.text('是否继续发布？'), findsOneWidget);
    expect(find.text('查看所属轮次'), findsOneWidget);
    expect(confirmationRequests, 1, reason: '首页和收件箱共用已完成的查询');
    await tester.tap(
      find.byKey(const ValueKey('pending-confirmation-approve')),
    );
    await tester.pumpAndSettle();
    expect(resolved, isTrue);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.text('暂无待确认事项'), findsOneWidget);
    expect(find.text('待你处理'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('工作概览'), findsOneWidget);

    final work = find.widgetWithText(ListTile, '发布版本').first;
    await tester.ensureVisible(work);
    await tester.tap(work);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '本工作待确认'));
    await tester.pumpAndSettle();
    expect(h.router.state.uri.queryParameters['group'], groupId);
    h.router.pop();
    await tester.pumpAndSettle();
    h.router.pop();
    await tester.pumpAndSettle();

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
    expect(find.text('查看对话'), findsOneWidget);
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
    expect(find.text('工作区文件 · 本地副本未核实'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(find.text('签名检查结果'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('check.txt'), findsOneWidget);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(WorkOverviewPage), findsOneWidget);
    expect(groupRequests, 1, reason: '返回后保留已加载工作列表');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    h.router.go(SpbRoutes.conversations);
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
  });
}
