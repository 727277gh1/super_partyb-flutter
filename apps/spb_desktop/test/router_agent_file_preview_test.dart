import 'dart:io';
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_data/spb_data.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 桌面端：文件预览页的返回语义在**真实路由表**上的回归。
///
/// 组件级用例（`packages/spb_features/test/chat/agent_file_preview_test.dart`）
/// 用的是裸 `MaterialApp`，宿主与预览页同一个 navigator，覆盖不到「装配层把
/// 预览压在 root Navigator、对话在 pageBuilder 生成的 page 上」这件事。移动端
/// 那份同名用例见 `apps/spb_mobile/test/router_agent_file_preview_test.dart`
/// （那边还多一层 `StatefulShellRoute` 分支栈，是「退到列表」的原始现场）。
void main() {
  const groupId = 'grp_prev';

  Future<TestHarness> pumpInChat(
    WidgetTester tester, {
    DownloadedFileStore? downloadedFileStore,
    FakeUfsApi? ufsApi,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final sse = FakeSseClient();
    final h = await pumpApp(
      tester,
      sseClient: sse,
      downloadedFileStore: downloadedFileStore,
      ufsApi: ufsApi,
      beforePump: (DioAdapter adapter) {
        adapter.onGet(
          '/chat/groups/$groupId',
          (server) => server.reply(200, {
            'id': groupId,
            'user_id': 'usr_TEST',
            'title': '预览回归',
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
        adapter.onGet(
          '/api/files/file_prev/download',
          (server) => server.reply(
            200,
            'hello',
            headers: {
              'content-type': ['text/plain'],
            },
          ),
        );
      },
    );

    h.router.go(SpbRoutes.chat(groupId));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    sse.push('agent.file.created', {
      'eventId': 'ev_file',
      'eventType': 'agent.file.created',
      'groupId': groupId,
      'turnId': 'turn_prev',
      'userId': 'usr_TEST',
      'seq': 1,
      'globalSeq': 1,
      'createdAt': '2026-01-01T00:00:00Z',
      'payload': {
        'relative_path': 'out/note.txt',
        'mime_type': 'text/plain',
        'size_bytes': 18,
        'ufs_file_id': 'file_prev',
      },
    });
    sse.push('done', {
      'eventId': 'ev_done',
      'eventType': 'done',
      'groupId': groupId,
      'turnId': 'turn_prev',
      'userId': 'usr_TEST',
      'seq': 2,
      'globalSeq': 2,
      'createdAt': '2026-01-01T00:00:01Z',
      'payload': <String, dynamic>{},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return h;
  }

  testWidgets('对话流下载进入交付面板，两个入口预览都优先读本地', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('spb_preview_download_'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
    final store = (await tester.runAsync(
      () async => DownloadedFileStore(() async => root),
    ))!;
    final ufs = FakeUfsApi()..bytes = utf8.encode('downloaded content');
    await pumpInChat(tester, downloadedFileStore: store, ufsApi: ufs);

    final card = tester.widget<AgentFileCard>(find.byType(AgentFileCard));
    await tester.runAsync(() => card.onDownload!(card.file));
    await tester.pumpAndSettle();
    expect(ufs.downloadCalls, ['file_prev']);
    final chat = tester.widget<ConversationPage>(find.byType(ConversationPage));
    final content = await tester.runAsync(
      () => chat.onPreviewAgentFile!.loadBytes!(card.file),
    );
    expect(utf8.decode(content!), 'downloaded content');
    expect(ufs.downloadCalls, ['file_prev']);

    // 远端清单为空，面板仍能从已落盘记录补齐文件。
    await tester.tap(find.byKey(const ValueKey('toggle-deliverables')));
    await tester.pump();
    final panel = tester.widget<GroupDeliverablesPanel>(
      find.byType(GroupDeliverablesPanel),
    );
    // 真实文件 IO 在 runAsync 中推进，provider 通知仍由测试帧消费。
    final artifact = find.byKey(
      const ValueKey('deliverable-preview-out/note.txt'),
    );
    for (
      var attempt = 0;
      attempt < 20 && artifact.evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(ufs.entries, isEmpty);
    expect(
      find.byKey(const ValueKey('deliverable-preview-out/note.txt')),
      findsOneWidget,
    );
    final panelContent = await tester.runAsync(
      () => panel.onPreview!.loadBytes!(card.file),
    );
    expect(utf8.decode(panelContent!), 'downloaded content');
    expect(ufs.downloadCalls, ['file_prev']);
  });

  Future<void> openPreview(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('agent-file-preview'));
    expect(button, findsOneWidget, reason: '文件卡必须渲染预览入口');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('agent-file-preview-page')),
      findsOneWidget,
    );
  }

  void expectStillInChat(TestHarness h) {
    expect(
      find.byKey(const ValueKey('agent-file-preview-page')),
      findsNothing,
      reason: '预览页必须关掉',
    );
    expect(
      find.byType(ConversationPage),
      findsOneWidget,
      reason: '对话页必须还在（退回列表就是本次回归）',
    );
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  }

  testWidgets('AppBar 返回箭头只关预览；再按一次才退到列表', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    await tester.tap(find.byKey(const ValueKey('agent-file-preview-back')));
    await tester.pumpAndSettle();
    expectStillInChat(h);

    // 守卫的 canPop 必须回到 true：否则「对话页再也退不出去」。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byType(ConversationPage),
      findsNothing,
      reason: '预览关掉后，返回应恢复「退对话」的原语义',
    );
    expect(h.router.state.uri.path, SpbRoutes.home);
  });

  testWidgets('系统返回键只关预览，对话仍在', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectStillInChat(h);
  });

  testWidgets('右上角关闭也只关预览', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    await tester.tap(find.byKey(const ValueKey('agent-file-preview-close')));
    await tester.pumpAndSettle();
    expectStillInChat(h);
  });
}
