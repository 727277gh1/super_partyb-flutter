import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show
        NotificationAppLaunchDetails,
        NotificationResponse,
        NotificationResponseType;
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

import 'package:spb_desktop/router.dart';

import 'support/desktop_harness.dart';

/// 点系统通知 → 落位到 `/chat/{groupId}`（本文件的唯一被测行为）。
///
/// ## 为什么必须钉住「用 revealWindow 而不是 showWindow」
///
/// 两者在能力层是**同一个窗口操作的两个语义**：
///
/// - `showWindow(main)` = 显示 + **导航到首页**（托盘图标/快捷键的语义，
///   `DesktopIntegration._navigateToRole`）；
/// - `revealWindow(main)` = 只显示，不换页面。
///
/// 通知点击的落点由 payload 决定，而 `showWindow` 的导航发生在它自己的
/// `show()/focus()` **之后**——用错时那个迟到的 `go('/')` 会把本回调刚设的
/// `/chat/{groupId}` 顶掉。症状是「点了通知，回到的是对话列表而不是那个
/// group」，而两条路径**都不报错、测试里互不干扰**（能力桩的 `showWindow`
/// 是空实现，谁都不会真的导航）。故这里只断言「调了哪个」与「落在哪」两件事。
void main() {
  testWidgets('热路径（进程存活时点击）：落到该 group，且只提到前台不改路由', (tester) async {
    final caps = FakeDesktopCapabilities();
    final sink = RecordingNotificationSink();
    final h = await pumpApp(
      tester,
      capabilities: caps,
      notificationSink: sink,
      // 从设置页出发：证明落位不是「本来就在那个对话」。
      initialLocation: SpbRoutes.settings,
    );
    await tester.pump();

    expect(sink.onSelect, isNotNull, reason: '插件初始化后必须接上点击回调');
    sink.onSelect!.call('/chat/grp_notified');
    await tester.pumpAndSettle();

    expect(
      h.router.state.matchedLocation,
      '/chat/grp_notified',
      reason: '点通知必须落在它携带的 group，而不是对话列表',
    );
    expect(caps.revealWindowCalls, [
      WindowRole.main,
    ], reason: '窗口可能被隐藏/最小化（通知只在非前台发），必须提到前台');
    expect(
      caps.showWindowCalls,
      isEmpty,
      reason: 'showWindow 会异步导航到首页，把 /chat/{groupId} 顶掉（本文件头的说明）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('冷启动（进程被系统杀掉后点击）：落到该 group', (tester) async {
    final caps = FakeDesktopCapabilities();
    final h = await pumpApp(
      tester,
      capabilities: caps,
      notificationSink: _LaunchFromNotification('/chat/grp_cold'),
    );
    await tester.pump();
    // 冷启动的导航排在首帧回调里（initState 阶段路由栈尚未就绪）。
    await tester.pump(const Duration(milliseconds: 500));

    expect(h.router.state.matchedLocation, '/chat/grp_cold');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('冷启动：没有 payload 时退化为普通启动（不导航到空路径）', (tester) async {
    final caps = FakeDesktopCapabilities();
    final h = await pumpApp(
      tester,
      capabilities: caps,
      notificationSink: _LaunchFromNotification(null),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      h.router.state.matchedLocation,
      SpbRoutes.home,
      reason: '空 payload 必须留在默认路由，不能拼出 `null`/空 location',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 真的 [LocalNotificationSink]（能进 `is LocalNotificationSink` 分支），但把
/// 平台通道里的「启动详情」换成固定值。
///
/// `flutter test` 没有插件通道，基类实现只会返回 null——那样就观测不到
/// 冷启动的落位。
class _LaunchFromNotification extends LocalNotificationSink {
  _LaunchFromNotification(this.payload);

  final String? payload;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<NotificationAppLaunchDetails?> launchDetails() async =>
      NotificationAppLaunchDetails(
        true,
        notificationResponse: NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: payload,
        ),
      );
}
