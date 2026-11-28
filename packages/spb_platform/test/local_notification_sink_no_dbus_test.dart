/// 通知**不可用**时的降级契约（issue #90 / AGENTS.md §4 的「静默降级」）。
///
/// ## 为什么单独一个文件，而不是并进 Linux 那条真链路测试
///
/// 那个文件需要**会话总线**（`dbus-run-session`），本文件相反：它断言
/// 「插件根本不可用」（等价于无 D-Bus 会话 / 平台不支持）时上层看到的是
/// **false + 一条可读结论**，而不是异常或一个骗人的 true。
///
/// 具体做法是**不注册**平台实现：`flutter test` 默认就不跑插件注册器，
/// 于是 `FlutterLocalNotificationsPlatform.instance` 保持未初始化 →
/// 插件调用失败 → 走 `LocalNotificationSink` 的降级分支。这正是线上
/// 「无 D-Bus 的 headless 环境」与「插件没注册」的共同形态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

void main() {
  test('插件不可用：initialize 返回 false，不抛异常', () async {
    final sink = LocalNotificationSink();
    expect(await sink.initialize(), isFalse);
    expect(await sink.requestPermission(), isFalse);
  });

  test('插件不可用：show / cancel 静默降级（不抛）', () async {
    final sink = LocalNotificationSink();
    await sink.show(const LocalNotification(id: 'x', title: '标题', body: '正文'));
    await sink.cancel('x');
  });

  test('插件不可用：自检给出 notInitialized，而不是含糊的失败', () async {
    final sink = LocalNotificationSink();
    final report = await sink.selfTest(
      clickWait: const Duration(milliseconds: 100),
    );

    expect(report.outcome, NotificationSelfTestOutcome.notInitialized);
    expect(report.passed, isFalse);
    expect(report.shown, isFalse);
    // 结论要能直接念给用户/贴进 issue，不能是空串或英文异常栈。
    expect(report.verdict, contains('初始化失败'));
    expect(report.logLine, contains('outcome=notInitialized'));
  });
}
