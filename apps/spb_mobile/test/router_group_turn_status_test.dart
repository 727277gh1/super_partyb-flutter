import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

void main() {
  testWidgets('概览批量加载轮次，实时显示失败并定位到对应轮次', (tester) async {
    final sse = FakeSseClient();
    var batches = 0;
    var detailQueries = 0;
    final h = await pumpApp(
      tester,
      initialLocation: SpbRoutes.workOverview,
      sseClient: sse,
      mockGroups: false,
      beforePump: (adapter) {
        adapter.onGet(
          '/chat/groups',
          (server) => server.reply(200, {
            'items': [
              {'id': 'grp_1', 'status': 'active', 'title': '无目标对话'},
              {'id': 'grp_2', 'status': 'active', 'title': '未覆盖对话'},
            ],
          }),
          queryParameters: {'limit': 30, 'offset': 0},
        );
        adapter.onGet(
          '/me/turns',
          (server) => server.replyCallback(200, (_) {
            batches++;
            return {
              'items': [
                {
                  'turn_id': 'turn_current',
                  'group_id': 'grp_1',
                  'status': 'running',
                  'created_at': '2026-11-27T00:00:00Z',
                },
              ],
            };
          }),
          queryParameters: {'limit': 200, 'days': 30},
        );
        adapter.onGet(
          '/chat/groups/grp_1',
          (server) => server.reply(200, {
            'id': 'grp_1',
            'status': 'active',
            'title': '无目标对话',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_2',
          (server) => server.reply(200, {
            'id': 'grp_2',
            'status': 'active',
            'title': '未覆盖对话',
          }),
        );
        adapter.onGet(
          '/chat/groups/grp_2/turns',
          (server) => server.replyCallback(200, (_) {
            detailQueries++;
            return {
              'items': [
                {
                  'id': 'turn_other',
                  'group_id': 'grp_2',
                  'status': 'completed',
                },
              ],
            };
          }),
          queryParameters: {'limit': 1, 'offset': 0},
        );
      },
    );
    await tester.pumpAndSettle();
    expect(batches, 1);
    expect(find.text('执行中'), findsOneWidget);
    expect(find.text('状态未核实'), findsOneWidget);
    expect(detailQueries, 0);
    await tester.tap(find.widgetWithText(ListTile, '状态未核实'));
    await tester.pumpAndSettle();
    expect(find.text('最近一轮 · 已完成'), findsOneWidget);
    expect(detailQueries, 1);
    h.router.pop();
    await tester.pumpAndSettle();
    expect(batches, 1);

    sse.push('done', {
      'eventId': 'evt_done',
      'userId': 'usr_TEST',
      'groupId': 'grp_1',
      'turnId': 'turn_current',
      'eventType': 'done',
      'createdAt': '2026-11-27T00:01:00Z',
      'payload': {'status': 'failed'},
    });
    await tester.pumpAndSettle();
    expect(find.text('无目标对话 · 最近一轮失败'), findsOneWidget);
    expect(batches, 1);

    sse.statesController.add(SseState.reconnecting);
    await tester.pumpAndSettle();
    expect(find.text('无目标对话 · 最近一轮失败'), findsNothing);
    sse.statesController.add(SseState.connected);
    await tester.pumpAndSettle();
    expect(batches, 2);
    expect(find.text('无目标对话 · 最近一轮失败'), findsOneWidget);

    await tester.tap(find.text('失败与阻塞'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '最近一轮失败 · 查看对话'));
    await tester.pumpAndSettle();
    expect(h.router.state.uri.path, SpbRoutes.chat('grp_1'));
    expect(h.router.state.uri.queryParameters['turn'], 'turn_current');
  });
}
