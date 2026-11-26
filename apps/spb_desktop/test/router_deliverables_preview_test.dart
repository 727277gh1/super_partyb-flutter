import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_features/spb_features.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 桌面端交付物侧栏里的**预览**（2026-11 接入）。
///
/// 侧栏是 `Offstage` 常驻的 tab（收起不卸载，见 §6.46），故用例要点开
/// `toggle-deliverables` 才能看到它。与移动端那份同名用例的分工：
/// 移动端守「底部弹层当宿主时返回只关预览」，这里守「侧栏 / 对话页这一层
/// 不会因为关预览而退掉」——两端宿主类型不同，回归点也不同。
void main() {
  const groupId = 'grp_deliv';
  const fileId = 'file_deliv';
  const relPath = 'out/note.txt';

  Future<TestHarness> pumpInChatWithDeliverable(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // UFS 用内存桩：清单与预览取字节都不发真 HTTP。
    final ufs = FakeUfsApi()
      ..entries = [ufsFile(groupId, relPath, id: fileId)]
      ..bytes = utf8.encode('hello deliverable');

    final h = await pumpApp(
      tester,
      ufsApi: ufs,
      beforePump: (DioAdapter adapter) {
        adapter.onGet(
          '/chat/groups/$groupId',
          (server) => server.reply(200, {
            'id': groupId,
            'user_id': 'usr_TEST',
            'title': '交付物预览',
          }),
        );
        adapter.onGet(
          '/chat/groups/$groupId/timeline',
          (server) => server.reply(200, {
            'items': <Map<String, dynamic>>[],
            'next_before_global_seq': '',
          }),
          queryParameters: {'limit': 200},
        );
        adapter.onGet(
          '/users/usr_TEST/chat/messages/pending',
          (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
          queryParameters: {'group_id': groupId, 'limit': 20},
        );
      },
    );

    h.router.go(SpbRoutes.chat(groupId));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    return h;
  }

  /// 展开侧栏并等交付物清单加载完。
  Future<void> openSidebar(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
    await tester.pumpAndSettle();
    expect(find.text('note.txt'), findsOneWidget, reason: '交付物清单必须渲染');
  }

  testWidgets('交付物侧栏里能打开预览（入口 + 取数都接通）', (tester) async {
    await pumpInChatWithDeliverable(tester);
    await openSidebar(tester);

    final previewButton = find.byIcon(Icons.visibility_outlined);
    expect(
      previewButton,
      findsOneWidget,
      reason: '未传 onPreview 时这里找不到图标——那就是「功能等于没做」',
    );
    await tester.tap(previewButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-file-preview-page')),
      findsOneWidget,
    );
    expect(
      find.text('hello deliverable'),
      findsOneWidget,
      reason: '取数没接上时预览页只会显示加载失败',
    );
  });

  testWidgets('系统返回只关预览，侧栏与对话都还在', (tester) async {
    final h = await pumpInChatWithDeliverable(tester);
    await openSidebar(tester);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-file-preview-page')),
      findsNothing,
      reason: '预览页必须关掉',
    );
    expect(
      find.text('note.txt'),
      findsOneWidget,
      reason: '侧栏内容被一起退掉就是这次接入要挡的回归',
    );
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  });

  testWidgets('预览关掉后返回恢复原语义：退回列表', (tester) async {
    final h = await pumpInChatWithDeliverable(tester);
    await openSidebar(tester);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 守卫的 canPop 必须回到 true，否则对话页再也退不出去。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.byType(ConversationPage),
      findsNothing,
      reason: '预览关掉后，返回应恢复「退对话」的原语义',
    );
    expect(h.router.state.uri.path, SpbRoutes.home);
  });
}
