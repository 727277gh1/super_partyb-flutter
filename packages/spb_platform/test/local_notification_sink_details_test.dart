import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// 通知参数本身（渠道 / 小图标 / 优先级）的回归守卫。
///
/// ## 为什么这组用例值得存在
///
/// 「横幅弹不弹」「状态栏显示成什么」**只有真机看得出来**（§8/§9），本机与 CI
/// 都验不了。能验的只有一件事：喂给插件的那组参数对不对。而这里恰好踩过两次
/// 静默失效：
///
/// 1. `androidChannel*` 三个构造参数曾经被 `_details()` 写成字面量——传了也
///    不生效，且没有任何报错（改渠道名的人会以为改了）；
/// 2. 小图标曾经沿用 `@mipmap/ic_launcher`（彩色启动图标）——API 21 起状态栏
///    图标必须是单色剪影，彩色图会被当 alpha 蒙版糊成实心块。
///
/// 本文件把这两条钉死：字段传得进去、`icon` 指向白剪影而不是启动图标。
void main() {
  group('LocalNotificationSink 的 Android 通知参数', () {
    test('默认：渠道、单色小图标、高重要性 + 声音（横幅的前提）', () {
      final android = LocalNotificationSink().debugNotificationDetails.android!;

      expect(android.channelId, 'spb_confirmations');
      expect(android.channelName, '待确认事项');
      expect(android.channelDescription, '有新的确认卡需要你处理');

      // 小图标必须是 drawable 里的白剪影，而不是启动器图标：
      // 前者在状态栏是「气泡 + 镂空对勾」，后者是一团实心块。
      expect(android.icon, 'ic_notification');
      expect(android.icon, isNot(contains('mipmap')));

      // Importance.high 是**横幅弹出**的前提（API 26+ 由渠道决定，改不了已
      // 存在的渠道）；priority 是 API 25 及以下的老字段，两者要一致。
      expect(android.importance, Importance.high);
      expect(android.priority, Priority.high);
      expect(android.playSound, isTrue);
    });

    test('构造参数真的生效（曾经的「传了也没用」回归）', () {
      final android = LocalNotificationSink(
        androidChannelId: 'custom_channel',
        androidChannelName: '自定义渠道',
        androidChannelDescription: '自定义描述',
        androidSmallIcon: 'custom_icon',
      ).debugNotificationDetails.android!;

      expect(android.channelId, 'custom_channel');
      expect(android.channelName, '自定义渠道');
      expect(android.channelDescription, '自定义描述');
      expect(android.icon, 'custom_icon');
    });

    test('同一份参数覆盖四个平台（漏某个平台会让该端静默无通知）', () {
      final details = LocalNotificationSink().debugNotificationDetails;
      expect(details.android, isNotNull);
      expect(details.iOS, isNotNull);
      expect(details.macOS, isNotNull);
      expect(details.linux, isNotNull);
      // Linux 的紧急度是「需要处理」而非「提示」，见 `_details()` 的注释。
      expect(details.linux!.urgency, LinuxNotificationUrgency.normal);
    });
  });
}
