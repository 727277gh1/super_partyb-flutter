/// 本地通知的**契约**（数据形态 + 发送能力），不含任何平台插件依赖。
///
/// ## 为什么契约与实现分开
///
/// `flutter_local_notifications` 是平台插件：`flutter test` 里没有平台通道，
/// 直接调它会抛 `MissingPluginException`。把契约放本包（纯 Flutter 依赖，
/// 无插件）后：
///
/// - `spb_domain` 可以在纯 `dart test` 里验证「该不该发」（那是**产品规则**，
///   见 `spb_domain/src/confirmation_notifier.dart`）；
/// - 平台实现（`flutter_local_notifications`）留在 apps 层，测试注入记录桩。
///
/// ## 为什么契约在 `spb_domain` 而实现不在
///
/// 依赖方向是 `spb_platform → spb_domain`（platform 的 `LocalFileSink` 实现
/// domain 的 `FileSink`），反向 import 会形成循环并被 `check_layering.sh` 拦。
/// 故契约（本文件）与判定逻辑（`confirmation_notifier.dart`）都放 domain，
/// 平台实现（`flutter_local_notifications`）放 apps。
///
/// 本文件只依赖 `spb_core`，不引入任何 Flutter 依赖——domain 的纯 Dart
/// 约束（AGENTS.md §4）不受影响。
library;

import 'package:spb_core/spb_core.dart';

/// 一条待发出的本地通知。
class LocalNotification {
  const LocalNotification({
    required this.id,
    required this.title,
    required this.body,
    this.payload,
  });

  /// 通知 id。
  ///
  /// ## 两个用途
  ///
  /// 1. **调用方的判重键**（同一张确认卡只发一次）；
  /// 2. **平台侧的覆盖语义**：Android/iOS 上相同 id 的通知会**覆盖**前一条
  ///    （而不是堆叠）。这正是我们要的——同一张卡重复发不该堆出两条。
  final String id;

  final String title;
  final String body;

  /// 点击通知时带回来的负载（路由路径）。
  final String? payload;

  @override
  String toString() => 'LocalNotification($id, $title)';
}

/// 发送本地通知的能力。
///
/// 实现方在平台不支持时应**静默降级**（记日志、不抛异常）——对齐
/// `DesktopCapabilities` 的哲学：上层不应为「这个平台没有通知」写 try/catch。
abstract interface class NotificationSink {
  /// 请求通知权限，返回是否已获得。
  ///
  /// ## 为什么要显式请求而不是「发的时候自然弹权限框」
  ///
  /// Android 13+ 的通知权限是**运行时**权限，首次 `show` 时系统弹框。若不在
  /// 合适的时机（应用启动后、用户能看到解释文案时）主动请求，用户会在一条
  /// 通知被静默吞掉的瞬间看到权限框——那是最难解释的时机。
  ///
  /// 返回 false 表示被拒（含平台不支持），调用方据此不再调用 [show]
  /// （避免每次都走一遍无效的插件调用）。
  Future<bool> requestPermission();

  /// 发出通知。**不抛异常**。
  Future<void> show(LocalNotification notification);

  /// 点击通知的回调接线点。
  ///
  /// 与 `WindowDisplayTarget` 同一理由：这是「接线」不是「能力」，
  /// 只有真正能接收事件的实现才需要。
  set onSelect(void Function(String? payload)? callback);
}

/// 什么都不做的实现（测试 / 不支持通知的平台）。
class NoopNotificationSink implements NotificationSink {
  const NoopNotificationSink();

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<void> show(LocalNotification notification) async {
    SpbLog.debug('通知在当前平台不可用', {'id': notification.id});
  }

  @override
  set onSelect(void Function(String? payload)? callback) {}
}
