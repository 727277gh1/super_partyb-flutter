import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

/// 本轮只交付 Android WorkManager；其他平台不注册不可靠的定时任务。
bool get supportsBackgroundNotifications => Platform.isAndroid;

abstract interface class NotificationPollingScheduler {
  bool get supported;
  Future<void> reconcile({required bool enabled});
}

class NoopNotificationPollingScheduler implements NotificationPollingScheduler {
  const NoopNotificationPollingScheduler();
  @override
  bool get supported => false;
  @override
  Future<void> reconcile({required bool enabled}) async {}
}

/// WorkManager 的独立 Flutter engine 与界面 engine 共用进程内端口映射。
/// 不把「前台」永久写盘，避免进程被杀后一直误认为窗口还可见。
class NotificationForegroundBridge {
  /// 端口名是**跨 engine 的协议常量**（后台 isolate 用同一个名字找前台）。
  static const portName = 'spb.notifications.foreground.v1';
  ReceivePort? _port;

  void attach(bool Function() focused) {
    dispose();
    final port = _port = ReceivePort();
    IsolateNameServer.removePortNameMapping(portName);
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((message) {
      if (message is SendPort) message.send(focused());
    });
  }

  static Future<bool> isForeground() async {
    final port = IsolateNameServer.lookupPortByName(portName);
    if (port == null) return false;
    final reply = ReceivePort();
    try {
      port.send(reply.sendPort);
      // 界面 engine 无响应时宁可跳过本轮，避免用户正操作时误弹通知。
      return await reply.first.timeout(
            const Duration(seconds: 1),
            onTimeout: () => true,
          ) ==
          true;
    } finally {
      reply.close();
    }
  }

  void dispose() {
    if (_port == null) return;
    IsolateNameServer.removePortNameMapping(portName);
    _port!.close();
    _port = null;
  }
}
