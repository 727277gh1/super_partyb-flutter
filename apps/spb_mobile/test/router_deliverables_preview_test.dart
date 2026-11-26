import 'dart:async' show unawaited;
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_features/spb_features.dart';

import 'package:spb_mobile/router.dart';

import 'support/mobile_harness.dart';

/// 交付物弹层里的**预览**（2026-11 接入）在真实路由表上的回归。
///
/// ## 这个文件防的是什么
///
/// 交付物弹层以前只有「下载」：想看一眼产出得先落盘、再去系统文件管理器里
/// 找。接上预览后有三个容易坏又不容易发现的点：
///
/// 1. **入口没接**（`onPreview` 漏传）→ 弹层里压根没有预览图标，功能等于没做；
/// 2. **取数没接**（`AgentFilePreviewCallbacks` 少一个能力）→ 图标在、点了空白；
/// 3. **返回语义**：弹层是 `showModalBottomSheet`（分支 navigator 上的
///    `PopupRoute`），预览在 root Navigator。系统返回可能先落到**弹层**，
///    于是「关预览」的一次返回把弹层一起退掉——正是 §6.110 记的那个真机回归
///    换了个宿主重演。故面板自带 [AgentFilePreviewHostGuard]。
///
/// 断言顺序即用户路径：进对话 → 开交付物 → 点预览 → 返回只关预览 → 再返回
/// 才关弹层（守卫不吃返回）。
void main() {
  const groupId = 'grp_deliv';
  const fileId = 'file_deliv';
  const relPath = 'out/note.txt';

  Future<TestHarness> pumpInChatWithDeliverable(WidgetTester tester) async {
    // UFS 用内存桩（`FakeUfsApi`）：交付物清单与预览取字节都不发真 HTTP。
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

    // 先起 app 再 `router.go`（直接以 initialLocation 进对话时 SSE 帧到不了页面，
    // 与 router_activity_test 同一约定）。
    h.router.go(SpbRoutes.chat(groupId));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    return h;
  }

  /// 打开交付物弹层并等清单加载完。
  Future<void> openDeliverables(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('open-group-deliverables')));
    await tester.pumpAndSettle();
    expect(find.text('note.txt'), findsOneWidget, reason: '交付物清单必须渲染');
  }

  testWidgets('交付物弹层里能打开预览（入口 + 取数都接通）', (tester) async {
    await pumpInChatWithDeliverable(tester);
    await openDeliverables(tester);

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

  testWidgets('系统返回只关预览，交付物弹层与对话都还在', (tester) async {
    final h = await pumpInChatWithDeliverable(tester);
    await openDeliverables(tester);

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
      reason: '弹层被一起退掉就是这次接入要挡的回归（与 §6.110 同型）',
    );
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  });

  testWidgets('返回请求落到弹层栈顶时，面板守卫把它转给预览（只关预览）', (tester) async {
    final h = await pumpInChatWithDeliverable(tester);
    await openDeliverables(tester);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();

    // 直接对**弹层所在的 navigator** 发一次 pop：这正是 go_router 在「shell
    // 之上压了 pageless route」判据失效时的行为——被问到的是弹层而不是预览。
    // 没有面板守卫时，这一次返回会把弹层弹掉、预览仍留在 root 栈顶。
    //
    // `skipOffstage: false`：弹层被预览页盖着，默认 finder 不命中。
    final sheetContext = tester.element(
      find.byType(GroupDeliverablesPanel, skipOffstage: false),
    );
    unawaited(Navigator.of(sheetContext).maybePop());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent-file-preview-page')),
      findsNothing,
      reason: '预览页必须关掉',
    );
    expect(find.text('note.txt'), findsOneWidget, reason: '弹层必须还在');
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  });

  testWidgets('预览关掉后返回恢复原语义：关弹层而不是退对话', (tester) async {
    final h = await pumpInChatWithDeliverable(tester);
    await openDeliverables(tester);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // 守卫的 canPop 必须回到 true，否则弹层再也关不掉。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('note.txt'), findsNothing, reason: '第二次返回应关弹层');
    expect(
      find.byType(ConversationPage),
      findsOneWidget,
      reason: '关弹层不该连带退掉对话',
    );
    expect(h.router.state.uri.path, SpbRoutes.chat(groupId));
  });
}
