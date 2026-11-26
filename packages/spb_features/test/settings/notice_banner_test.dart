import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

class _Store implements ConfirmationReceiptStore {
  Map<String, ConfirmationReceipt> rows = {};
  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<Map<String, ConfirmationReceipt>> loadReceipts() async => rows;
  @override
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> receipts) async {
    rows = receipts;
  }
}

/// `NoticeBanner` 的关闭按钮（#129）。
///
/// ## 这条防的是什么
///
/// 全仓 67 个 `IconButton` 里只有这一个没有可读名称——图标按钮没有可读
/// 文本，读屏会把 `Icons.close` 念成「按钮」。这类缺口**任何测试都不会红**：
/// 图标照常渲染、点击照常生效，只有用读屏的人点不明白。
///
/// ## 为什么名称走 `Icon.semanticLabel` 而不是 `IconButton.tooltip`
///
/// 本组件挂在 `MaterialApp.builder` 上，位于 **Navigator 之上**（两端
/// `app.dart` 都这么接），那个位置**没有 `Overlay`**，而 `Tooltip` 会断言
/// `debugCheckHasOverlay` 直接抛异常。曾经用 tooltip 实现过，`apps/spb_desktop`
/// 的 `router_workbench_test.dart` 当场红——本文件却因为它把 banner 放进了
/// `MaterialApp(home:)`（自带 Overlay）而保持绿。下面第二条用例专门守这个
/// 位置差异，别再把它挪回 `home:` 里。
void main() {
  testWidgets('关闭按钮有可读名称，点击后通知消失', (tester) async {
    // 读屏名称要读**语义树**：不开语义，`find.bySemanticsLabel` 恒为空。
    final semantics = tester.ensureSemantics();

    final dio = Dio();
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/me/notices',
      (server) => server.reply(200, {
        'notices': [
          {
            'id': 'n1',
            'kind': 'sandbox_suppressed',
            'severity': 'warning',
            'title': '执行被沙箱拦下',
            'body': '本轮命令被策略拒绝',
            'created_at': '2026-11-20T10:00:00Z',
          },
        ],
        'unread': 1,
      }),
      queryParameters: {'limit': 200},
    );
    final center = NoticeCenter(
      api: NoticesApi(dio),
      inbox: ConfirmationNotificationInbox(
        store: _Store(),
        show: (_) async => true,
        cancel: (_) async {},
        canNotify: () async => true,
      ),
      sessionVersion: () async => 1,
      isFocused: () => true,
    );
    addTearDown(center.dispose);
    addTearDown(dio.close);

    // ⚠️ 先挂载再刷新：`NoticeCenter.changes` 是 broadcast 流，
    // 刷新若发生在订阅之前，这次通知就丢了（横幅永远不出现）。
    await tester.pumpWidget(
      MaterialApp(
        home: NoticeBanner(
          center: center,
          focused: true,
          onOpen: (_) {},
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.runAsync(center.refresh);
    await tester.pump();
    await tester.pump();

    expect(find.text('执行被沙箱拦下'), findsOneWidget);

    final close = find.byIcon(Icons.close);
    expect(close, findsOneWidget);

    // 读**语义树**而不是 widget 字段：这是读屏真正拿到的内容。
    // 名称来自 `Icon.semanticLabel`，会并进按钮节点（`label` 或 `tooltip`）。
    final node = tester.getSemantics(close);
    expect(
      node.label.contains('关闭通知') || node.tooltip == '关闭通知',
      isTrue,
      reason:
          '语义节点必须有可读名称（label=${node.label} / '
          'tooltip=${node.tooltip}），否则读屏只念「按钮」',
    );

    await tester.tap(close);
    await tester.pumpAndSettle();

    expect(find.text('执行被沙箱拦下'), findsNothing);

    // 必须在用例结束前释放：SemanticsHandle 泄漏会在 `_endOfTestVerifications`
    // 里报「A SemanticsHandle was active at the end of the test」。
    semantics.dispose();
  });

  testWidgets('挂在 Navigator 之上（无 Overlay 祖先）也能渲染（#129 回归）', (tester) async {
    // 与两端 `app.dart` 的真实位置一致：`MaterialApp.builder` 包的是
    // Navigator 本身，所以 banner **不在**任何 `Overlay` 之下。
    //
    // 用 `IconButton.tooltip` 时这里会抛
    // `No Overlay widget found / RawTooltip widgets require an Overlay widget
    // ancestor`——而放进 `MaterialApp(home:)` 的用例完全看不到这个问题。
    final dio = Dio();
    final adapter = DioAdapter(dio: dio);
    adapter.onGet(
      '/me/notices',
      (server) => server.reply(200, {
        'notices': [
          {
            'id': 'n1',
            'kind': 'sandbox_suppressed',
            'severity': 'warning',
            'title': '执行被沙箱拦下',
            'body': '本轮命令被策略拒绝',
            'created_at': '2026-11-20T10:00:00Z',
          },
        ],
        'unread': 1,
      }),
      queryParameters: {'limit': 200},
    );
    final center = NoticeCenter(
      api: NoticesApi(dio),
      inbox: ConfirmationNotificationInbox(
        store: _Store(),
        show: (_) async => true,
        cancel: (_) async {},
        canNotify: () async => true,
      ),
      sessionVersion: () async => 1,
      isFocused: () => true,
    );
    addTearDown(center.dispose);
    addTearDown(dio.close);

    // 最小可用树：有 `MediaQuery`（`SafeArea` 需要）、有 `Material`（`Card`
    // / `ListTile` 需要）、有 `Directionality`——但**刻意没有** Overlay。
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Material(
            child: NoticeBanner(
              center: center,
              focused: true,
              onOpen: (_) {},
              child: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(center.refresh);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '在 Navigator 之上渲染不能崩');
    expect(find.text('执行被沙箱拦下'), findsOneWidget);
  });
}
