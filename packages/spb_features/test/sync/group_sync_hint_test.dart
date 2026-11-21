import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';

/// 「本对话有交付物未同步」提示条。
///
/// ## 为什么这些断言值得写
///
/// 提示条是「判定命中」之后**唯一的用户可见后果**。它若渲染不出来、或文案
/// 说了不存在的事实（例如没统计却报「0 个」），用户会得出错误结论——而
/// 这条路径在真实环境里只在「恰好有未同步文件」时才走到，很难手测。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  group('提示条：文案', () {
    testWidgets('有计数时说具体数量', (tester) async {
      await _pump(tester, const GroupSyncHint(pendingCount: 12));
      expect(find.text('本对话有 12 个交付物未同步到本地'), findsOneWidget);
    });

    testWidgets('计数为 0（未统计）时不说「0 个」', (tester) async {
      // ## 为什么不写「0 个」
      //
      // 0 在这里表示「数量未知」（统计被跳过 / 判定只拉了 1 条），不是
      // 「一个都没有」。写成 0 是把「不知道」说成一个具体数字——与 §5.4
      // 「没有终态事件就不写已中断」同一取向。
      await _pump(tester, const GroupSyncHint(pendingCount: 0));
      expect(find.text('本对话有交付物未同步到本地'), findsOneWidget);
      expect(find.textContaining('0 个'), findsNothing);
    });

    testWidgets('达到计数上限时说「500+」而不是精确值', (tester) async {
      // 计数有上限（`GroupSyncCheckResult.countCap`），报精确的 500 会让
      // 用户以为正好 500 个。
      await _pump(tester, const GroupSyncHint(pendingCount: 500));
      expect(find.text('本对话有 500+ 个交付物未同步到本地'), findsOneWidget);
    });
  });

  group('提示条：入口显隐', () {
    testWidgets('未注入 onSync 时不渲染「立即同步」', (tester) async {
      // 不展示点了没反应的入口（AGENTS.md 既有原则）。
      await _pump(tester, const GroupSyncHint(pendingCount: 3));
      expect(find.byKey(const ValueKey('group-sync-hint-sync')), findsNothing);
    });

    testWidgets('未注入 onDismiss 时不渲染关闭按钮', (tester) async {
      await _pump(tester, const GroupSyncHint(pendingCount: 3));
      expect(
        find.byKey(const ValueKey('group-sync-hint-dismiss')),
        findsNothing,
      );
    });

    testWidgets('两个都注入时都可点', (tester) async {
      var synced = 0;
      var dismissed = 0;
      await _pump(
        tester,
        GroupSyncHint(
          pendingCount: 3,
          onSync: () => synced++,
          onDismiss: () => dismissed++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('group-sync-hint-sync')));
      await tester.tap(find.byKey(const ValueKey('group-sync-hint-dismiss')));
      expect(synced, 1);
      expect(dismissed, 1);
    });
  });

  group('提示条：同步中', () {
    testWidgets('syncing 时按钮变转圈且禁用（防重复点击）', (tester) async {
      var synced = 0;
      await _pump(
        tester,
        GroupSyncHint(pendingCount: 3, syncing: true, onSync: () => synced++),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('立即同步'), findsNothing);

      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('group-sync-hint-sync')),
      );
      expect(button.onPressed, isNull, reason: '在途时必须禁用');

      // 即便点击也不该触发（onPressed 为 null）。
      await tester.tap(
        find.byKey(const ValueKey('group-sync-hint-sync')),
        warnIfMissed: false,
      );
      expect(synced, 0);
    });

    testWidgets('syncing 时关闭按钮也禁用', (tester) async {
      // ## 为什么关闭也要禁
      //
      // 同步已在跑，此时关掉提示条会让用户以为「取消了」，而实际下载仍在
      // 继续——那是一个更糟的错觉。
      var dismissed = 0;
      await _pump(
        tester,
        GroupSyncHint(
          pendingCount: 3,
          syncing: true,
          onSync: () {},
          onDismiss: () => dismissed++,
        ),
      );
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('group-sync-hint-dismiss')),
      );
      expect(button.onPressed, isNull);
    });
  });
}
