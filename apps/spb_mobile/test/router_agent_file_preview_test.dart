import 'dart:io';
import 'dart:convert' show utf8;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';

import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 文件预览页的**返回语义**在真实路由表上的回归（§6.110 / issue 见 chat.md）。
///
/// ## 这个文件防的是什么
///
/// `packages/spb_features/test/chat/agent_file_preview_test.dart` 的「返回语义」
/// 组用的是**裸 `MaterialApp`**：宿主和预览页在同一个 navigator 里，`pop` 一次
/// 必然只弹预览。真实 app 不是这样——预览压在 **root Navigator**，对话在
/// **分支 Navigator**（`StatefulShellRoute.indexedStack`），系统返回在 go_router
/// 里先试分支栈顶，只靠「shell 之上压了 pageless route 就 break」这条实现细节
/// 兜住。真机反馈的「预览完按返回，退回了对话列表」正是这条判据失效的样子。
///
/// 故这里用**真实 router + 真实对话页 + 真实文件卡**钉住四件事：
/// 1. AppBar 返回箭头只关预览；
/// 2. 系统返回只关预览；
/// 3. 返回请求被派到**宿主**（分支栈顶）时，由宿主守卫转给预览（本轮修复的核心）；
/// 4. 守卫不会把返回永久吃掉：预览关掉后返回仍能正常退到列表。
void main() {
  const groupId = 'grp_prev';

  /// 进入对话页并推一张文件卡（预览入口靠它出现）。
  Future<TestHarness> pumpInChat(
    WidgetTester tester, {
    DownloadedFileStore? downloadedFileStore,
    FakeUfsApi? ufsApi,
  }) async {
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
        // 预览取数（UFS 原始字节）。
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

    // 先起 app 再用 `router.go` 进对话（与 router_activity_test 同一约定：
    // 直接以 `initialLocation` 启动时注入的 SSE 帧到不了页面）。
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
    // 收尾取消本轮看门狗，避免测试结束留下运行中计时器。
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

  /// 点文件卡的预览按钮并等页面就位。
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
    await tester.tap(find.byKey(const ValueKey('open-group-deliverables')));
    await tester.pump();
    final panel = tester.widget<GroupDeliverablesPanel>(
      find.byType(GroupDeliverablesPanel),
    );
    final files = (await tester.runAsync(panel.loadFiles))!;
    await tester.pumpAndSettle();
    expect(files.map((file) => file.id), ['file_prev']);
    expect(
      find.byKey(const ValueKey('deliverable-preview-out/note.txt')),
      findsOneWidget,
    );
    final panelContent = await tester.runAsync(
      () => panel.onPreview!.loadBytes!(card.file),
    );
    expect(utf8.decode(panelContent!), 'downloaded content');
    expect(ufs.downloadCalls, ['file_prev']);

    // 删除本地副本后预览自动回退远端，不能被过期路径卡住。
    final entry = agentFileDownloadEntry(card.file, groupId);
    await tester.runAsync(() async {
      final path = await store.localPath(groupId, entry);
      await File(path!).delete();
    });
    ufs.bytes = utf8.encode('remote fallback');
    final fallback = await tester.runAsync(
      () => panel.onPreview!.loadBytes!(card.file),
    );
    expect(utf8.decode(fallback!), 'remote fallback');
    expect(ufs.downloadCalls, ['file_prev', 'file_prev']);
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
      reason: '对话页必须还在——退回列表就是这次修复要挡的回归',
    );
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  }

  testWidgets('AppBar 返回箭头只关预览；再按一次才退到列表（守卫不吃返回）', (tester) async {
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
    expect(h.router.state.uri.path, SpbRoutes.conversations);
  });

  testWidgets('系统返回键只关预览，对话仍在', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    // 与 Android/iOS 硬件返回同一条链路（不是点按钮）。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectStillInChat(h);
  });

  testWidgets('返回请求落到宿主栈顶时，宿主守卫把它转给预览（只关预览）', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    // 直接对**分支 navigator**（对话页所在的栈）发一次 pop：这正是 go_router
    // 在「shell 之上压了 pageless route」判据失效时的行为——被问到的是对话页
    // 而不是预览页。守卫必须让这次返回只关预览。
    //
    // `skipOffstage: false`：对话页被预览页盖着，默认 finder 不命中它。
    final chatContext = tester.element(
      find.byType(ConversationPage, skipOffstage: false),
    );
    unawaited(Navigator.of(chatContext).maybePop());
    await tester.pumpAndSettle();

    expectStillInChat(h);
  });

  testWidgets('连点两次返回只退一层', (tester) async {
    final h = await pumpInChat(tester);
    await openPreview(tester);

    await tester.tap(find.byKey(const ValueKey('agent-file-preview-back')));
    await tester.pump(const Duration(milliseconds: 50));
    // 第二次落在退场动画期间：`isCurrent` 为假 → 什么都不做。
    await tester.tap(
      find.byKey(const ValueKey('agent-file-preview-back')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expectStillInChat(h);
  });

  testWidgets('上一条用例留下未关的预览，不影响下一条的返回语义', (tester) async {
    // 回归防线：登记表靠 `dispose` 注销。若注销漏了，层数回不到 0，后续宿主的
    // 返回会被永久吃掉（表现为「返回没反应」）——这里用「用例结束时预览还开着」
    // 的场景验证拆卸路径。
    await pumpInChat(tester);
    await openPreview(tester);
    // 不关闭，直接结束本条用例。
  });

  testWidgets('上一用例遗留的预览层已被清理：返回照常退对话', (tester) async {
    final h = await pumpInChat(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      find.byType(ConversationPage),
      findsNothing,
      reason: '残留的预览层数会让这里什么都不发生（返回被守卫吃掉）',
    );
    expect(h.router.state.uri.path, SpbRoutes.conversations);
  });
}
