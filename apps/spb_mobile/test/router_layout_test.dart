import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

void main() {
  for (final (size, scale) in [
    (const Size(320, 812), 1.0),
    (const Size(375, 812), 1.0),
    (const Size(390, 844), 1.0),
    (const Size(375, 812), 2.0),
    (const Size(812, 375), 2.0),
  ]) {
    testWidgets('聊天标题与常用入口可用：$size，字号 $scale', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.binding.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );
      final sse = _LayoutSseClient();
      final h = await pumpApp(
        tester,
        sseClient: sse,
        loadAgents: () async => const [
          Agent(id: 'agent_a', name: '专业营销策划助手'),
          Agent(id: 'agent_b', name: '写作助手'),
        ],
        beforePump: (adapter) {
          adapter.onGet(
            '/chat/groups/grp_layout',
            (server) => server.reply(200, {
              'id': 'grp_layout',
              'user_id': 'usr_TEST',
              'title': '季度复盘',
              'active_session': {'agent_id': 'agent_a'},
            }),
          );
          adapter.onGet(
            '/chat/groups/grp_layout/timeline',
            (server) => server.reply(200, {
              'items': <Map<String, dynamic>>[],
              'next_before_global_seq': '',
            }),
            queryParameters: {'limit': 200},
          );
          adapter.onGet(
            '/users/usr_TEST/chat/messages/pending',
            (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
            queryParameters: {'group_id': 'grp_layout', 'limit': 20},
          );
        },
      );
      await tester.pumpAndSettle();
      h.router.go(SpbRoutes.chat('grp_layout'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(sse.connectedPaths, isNotEmpty);
      expect(tester.getSize(find.text('季度复盘')).width, greaterThan(0));
      expect(find.text('专业营销策划助手'), findsOneWidget);
      for (final key in ['open-group-deliverables', 'open-group-todos']) {
        expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);

      var requests = 0;
      h.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            handler.next(options);
          },
        ),
      );
      await tester.tap(find.byKey(const ValueKey('agent-switcher-label')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('agent-option-agent_b')),
      );
      await tester.tap(find.byKey(const ValueKey('agent-option-agent_b')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('agent-switcher-label')))
            .data,
        '写作助手',
      );
      expect(requests, 0, reason: '选择 Agent 只更新本地状态');

      sse.fail();
      await tester.pump();
      await tester.pumpAndSettle();
      final reconnect = find.byKey(
        const ValueKey('conversation-connection-indicator'),
      );
      expect(tester.getSize(reconnect).shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(reconnect);
      await tester.pump();
      expect(sse.resumeCount, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置分支保留草稿，系统返回确认后才交回宿主', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var exits = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpApp(tester, initialLocation: SpbRoutes.settingsSyncTab);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-include-media'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('有未保存的修改'), findsOneWidget);
    expect(exits, 0);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-discard-leave')));
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });
}

// 当前值与状态流保持一致，重建时 initialData 不能错误地回到「已连接」。
class _LayoutSseClient extends FakeSseClient {
  SseState _state = SseState.connected;

  @override
  SseState get state => _state;

  void fail() {
    _state = SseState.failed;
    statesController.add(_state);
  }
}
