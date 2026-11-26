/// Linux 通知链路的**真实现**测试：真插件 → 真 D-Bus → 假 notification daemon。
///
/// ## 为什么这比「注入一个记录桩」强
///
/// issue #90 的困境是「`flutter test` 只能证明装配对了，证明不了 toast 真的
/// 弹、点了真的回到应用」。但 Linux 这条路有一个别处没有的性质：
/// `flutter_local_notifications_linux` 是**纯 Dart**（走 D-Bus，不依赖
/// libnotify 的 C 库），因此**不需要 GUI、不需要真机**就能跑真实现。
///
/// 于是本文件把 daemon 端也自己实现（进程内的 `org.freedesktop.Notifications`），
/// 断言的就是线上真正发生的事：
///
/// 1. `Notify` 收到的 summary / body / actions 就是确认卡该有的；
/// 2. daemon 回 `ActionInvoked` 后，`LocalNotificationSink.selfTest` 拿回
///    **期望的 payload**（= 点击→导航链路的最后一米）；
/// 3. `cancel` 真的发出 `CloseNotification`（#87 的撤销）。
///
/// ## 运行方式（必须有会话总线）
///
/// ```bash
/// dbus-run-session -- bash -c 'cd packages/spb_platform && flutter test test/local_notification_sink_linux_test.dart'
/// ```
///
/// 直接 `flutter test`（无 `DBUS_SESSION_BUS_ADDRESS`）时本文件**整组跳过**，
/// 不让「环境没有会话总线」变成红灯——那条降级路径由
/// `local_notification_sink_no_dbus_test.dart` 单独守。
///
/// ## 三个踩过的坑（改动本文件前先看）
///
/// | 坑 | 现象 | 解法 |
/// |---|---|---|
/// | `flutter test` 不跑插件注册器 | `LateInitializationError: Field '_instance' has not been initialized` | 手动 `LinuxFlutterLocalNotificationsPlugin.registerWith()` |
/// | `flutter test` 的 `defaultTargetPlatform` 默认是 **android** | 插件按 android 分派 → `initialize()` 返回 false、静默降级 | `debugDefaultTargetPlatformOverride = TargetPlatform.linux` |
/// | 机器上真装了 `xfce4-notifyd` 时 D-Bus 会按需激活它 | 名字被它抢走；它无 `DISPLAY` 起不来 → `Spawn.ChildExited` | 假 daemon 用 `doNotQueue` 先占名字，占不到就**跳过**而不是失败 |
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show
        FlutterLocalNotificationsPlatform,
        LinuxFlutterLocalNotificationsPlugin;
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

const String _kBusName = 'org.freedesktop.Notifications';
const String _kPath = '/org/freedesktop/Notifications';

/// 一次 `Notify` 调用被捕获到的内容。
class CapturedNotify {
  CapturedNotify({
    required this.id,
    required this.summary,
    required this.body,
    required this.actions,
    required this.replacesId,
  });

  final int id;
  final String summary;
  final String body;
  final List<String> actions;
  final int replacesId;

  @override
  String toString() =>
      'CapturedNotify(id=$id, summary=$summary, actions=$actions)';
}

/// 进程内的假 notification daemon。
class FakeNotificationDaemon extends DBusObject {
  FakeNotificationDaemon(this._client) : super(DBusObjectPath(_kPath));

  final DBusClient _client;

  final List<CapturedNotify> notifies = <CapturedNotify>[];
  final List<int> closed = <int>[];

  /// 收到 `Notify` 后自动回一次 `ActionInvoked`（模拟用户点通知）。
  bool autoClick = true;

  int _nextId = 1;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _kBusName) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Notify':
        final values = call.values;
        final id = _nextId++;
        final captured = CapturedNotify(
          id: id,
          summary: (values[3] as DBusString).value,
          body: (values[4] as DBusString).value,
          actions: (values[5] as DBusArray).asStringArray().toList(),
          replacesId: (values[1] as DBusUint32).value,
        );
        notifies.add(captured);
        if (autoClick) {
          // 让 Notify 的回复先发出去，再发信号（否则插件侧还没写完 storage
          // 映射，收到 ActionInvoked 会查不到 systemId → 点击被静默丢弃）。
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 200), () async {
              await _client.emitSignal(
                path: DBusObjectPath(_kPath),
                interface: _kBusName,
                name: 'ActionInvoked',
                values: [DBusUint32(id), const DBusString('default')],
              );
            }),
          );
        }
        return DBusMethodSuccessResponse([DBusUint32(id)]);

      case 'GetCapabilities':
        return DBusMethodSuccessResponse([
          DBusArray.string(['actions', 'body', 'body-markup']),
        ]);

      case 'CloseNotification':
        closed.add((call.values[0] as DBusUint32).value);
        return DBusMethodSuccessResponse();

      case 'GetServerInformation':
        return DBusMethodSuccessResponse([
          const DBusString('fake-notifyd'),
          const DBusString('spb'),
          const DBusString('1.0'),
          const DBusString('1.2'),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  // 无会话总线 → 整组跳过（不是失败）：这条降级路径另有专门的用例。
  final hasSessionBus =
      Platform.isLinux &&
      Platform.environment['DBUS_SESSION_BUS_ADDRESS'] != null;

  group('Linux 通知链路（真插件 + 假 D-Bus daemon）', () {
    late DBusClient client;
    late FakeNotificationDaemon daemon;
    var nameOwned = false;

    setUpAll(() async {
      if (!hasSessionBus) return;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // 等价于插件注册器做的事（`flutter test` 不跑注册器）。直接写
      // `registerWith()` 也可，但那在 web 分支的 stub 上不存在，analyzer 会报
      // `undefined_method`；赋值 `instance` 是同一件事的公开 API。
      FlutterLocalNotificationsPlatform.instance =
          LinuxFlutterLocalNotificationsPlugin();

      client = DBusClient.session();
      daemon = FakeNotificationDaemon(client);
      final reply = await client.requestName(
        _kBusName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      nameOwned = reply == DBusRequestNameReply.primaryOwner;
      if (!nameOwned) {
        // 机器上有真的 daemon（如 xfce4-notifyd）占着名字：跳过而不是失败。
        // 它可能因为无 DISPLAY 根本起不来，此时「跳过」正是我们想要的信号。
        return;
      }
      await client.registerObject(daemon);
    });

    tearDownAll(() async {
      if (!hasSessionBus) return;
      if (nameOwned) {
        await client.releaseName(_kBusName);
        await client.close();
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('自检：Notify 的标题/正文/动作正确，点击回传期望 payload', () async {
      final sink = LocalNotificationSink();
      final report = await sink.selfTest(
        clickWait: const Duration(seconds: 10),
      );

      // ① 真的发到了 daemon 上（不是「桩被调用了」）。
      expect(daemon.notifies, isNotEmpty, reason: '没有捕获到 Notify 调用');
      final captured = daemon.notifies.last;
      expect(captured.summary, '通知自检');
      expect(captured.body, contains('点我'));
      // 「打开」来自 LocalNotificationSink 的 defaultActionName。
      expect(captured.actions, containsAll(<String>['default', '打开']));

      // ② 点击回来的是期望 payload（= 点击→导航链路的最后一米）。
      expect(report.initialized, isTrue);
      expect(report.permissionGranted, isTrue);
      expect(report.shown, isTrue);
      expect(report.clickedPayload, kNotificationSelfTestPayload);
      expect(report.passed, isTrue, reason: report.verdict);
      expect(report.verdict, contains('自检通过'));
    });

    test('cancel 真的发出 CloseNotification（#87 撤销）', () async {
      final sink = LocalNotificationSink();
      expect(await sink.initialize(), isTrue);
      await sink.show(
        const LocalNotification(id: 'cancel-me', title: '待撤销', body: '正文'),
      );
      final sentId = daemon.notifies.last.id;
      await sink.cancel('cancel-me');
      expect(daemon.closed, contains(sentId));
    });

    test('daemon 不回点击时报告 clickMissing 而不是 passed', () async {
      daemon.autoClick = false;
      addTearDown(() => daemon.autoClick = true);

      final sink = LocalNotificationSink();
      final report = await sink.selfTest(
        clickWait: const Duration(milliseconds: 400),
      );

      expect(report.shown, isTrue, reason: '通知本身应该发得出去');
      expect(report.clickedPayload, isNull);
      expect(report.passed, isFalse);
      expect(report.verdict, contains('没收到点击'));
    });
  }, skip: hasSessionBus ? false : '无 D-Bus 会话总线（用 dbus-run-session 跑）');
}
