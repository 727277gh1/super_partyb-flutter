import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

/// 后台通知的两个平台契约（§6.110）。
///
/// ## 这个测试防的是什么
///
/// `WorkManager` 的后台任务跑在**另一个 Flutter engine**（同进程、不同
/// isolate）里。它要知道「用户此刻是不是正在用 App」——判定错了的两种后果
/// 都是用户可见的：
///
/// - 误判「不在前台」→ 用户正盯着对话页，通知栏又弹一条同样的确认卡；
/// - 误判「在前台」→ 用户锁屏等着确认，什么都不弹（比不弹更糟：静默失败）。
///
/// 而这条判定靠 `IsolateNameServer` 的进程内端口映射，**没有类型系统兜底**：
/// 端口名写错、忘了 `dispose`、超时不回退，全都只是「永远返回 false」。
void main() {
  group('NotificationForegroundBridge', () {
    test('没有界面 engine 注册时当作不在前台（进程被系统杀掉后重建）', () async {
      // 不 attach 任何端口：后台 engine 是唯一活着的 engine。
      expect(await NotificationForegroundBridge.isForeground(), isFalse);
    });

    test('注册后把界面 engine 的答案原样回传，dispose 后回到「不在前台」', () async {
      var focused = false;
      final bridge = NotificationForegroundBridge()..attach(() => focused);
      addTearDown(bridge.dispose);

      expect(await NotificationForegroundBridge.isForeground(), isFalse);
      focused = true;
      expect(await NotificationForegroundBridge.isForeground(), isTrue);
      // 每次询问都现取，不缓存：用户随时可能切走。
      focused = false;
      expect(await NotificationForegroundBridge.isForeground(), isFalse);

      bridge.dispose();
      expect(await NotificationForegroundBridge.isForeground(), isFalse);
    });

    test('重复 attach 覆盖旧映射，不会留下两个监听者', () async {
      final bridge = NotificationForegroundBridge()
        ..attach(() => false)
        ..attach(() => true);
      addTearDown(bridge.dispose);

      expect(await NotificationForegroundBridge.isForeground(), isTrue);
    });

    test('界面 engine 不回应时按「在前台」处理（宁可少弹，不可误弹）', () async {
      // 一个只收不回的端口：模拟界面 engine 卡在长任务里。
      final silent = ReceivePort();
      IsolateNameServer.registerPortWithName(
        silent.sendPort,
        NotificationForegroundBridge.portName,
      );
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(
          NotificationForegroundBridge.portName,
        );
        silent.close();
      });

      expect(await NotificationForegroundBridge.isForeground(), isTrue);
    });
  });

  group('NoopNotificationPollingScheduler', () {
    test('报告不支持，且 reconcile 是空操作（桌面端 / iOS 装配用）', () async {
      const scheduler = NoopNotificationPollingScheduler();
      expect(scheduler.supported, isFalse);
      await scheduler.reconcile(enabled: true);
      await scheduler.reconcile(enabled: false);
    });
  });
}
