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

  /// 撤销一条已发出的通知（issue #87：确认卡解决后不再留在通知中心）。
  ///
  /// id 与 [show] 时传的 [LocalNotification.id] 同源（字符串）。实现方负责
  /// 映射到平台 id（与 [show] 同一映射，否则撤不掉）。**不抛异常**：平台
  /// 不支持 / id 不存在都静默——撤销失败的最坏后果只是通知多留一会儿，
  /// 不值得打断业务链路。
  Future<void> cancel(String id);

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
  Future<void> cancel(String id) async {
    // 空实现：与 show 一致的静默降级（本类就是「无通知平台」的化身）。
  }

  @override
  set onSelect(void Function(String? payload)? callback) {}
}

/// 「通知自检」的默认点击负载：设置页（自检入口就在那里）。
///
/// ## 为什么是 `/settings` 而不是某个对话
///
/// 自检必须**可重复且不依赖数据**：指向 `/chat/<gid>` 就得先有真实群 id
/// （换账号 / 空列表时会退化成不存在的路由），而用户点了通知却落到错误页
/// 会被读成「点击坏了」。指向设置页则总是有效，且用户就在那里点自检——
/// 落位后还能在同一个页面上看到自检结论。
const String kNotificationSelfTestPayload = '/settings';

/// 「通知自检」的结论（issue #90）。
///
/// ## 为什么把「四步」都记下来，而不是只给一个 bool
///
/// 通知链路的四步失败起来**症状相同、成因完全不同**（issue #90 的核心难点）：
///
/// | 步骤 | 失败时的表现 | 修法 |
/// |---|---|---|
/// | `initialize` | 插件没注册 / 平台通道缺失，之后全部静默跳过 | 装配问题 |
/// | `requestPermission` | 系统权限被拒（Android 13+ / macOS） | 用户去设置里开 |
/// | `show` | 调用抛错（无 D-Bus / 无 toast 运行时） | 环境问题 |
/// | 点击回调 | 通知弹了但点不动 / payload 没回来 | 回调接线问题 |
///
/// 只回一个 `false` 时，用户报「通知没反应」，我们无法判断该查哪一层。
/// 故这份报告是**给用户念给我们的那一行**，也是诊断报告里的证据。
class NotificationSelfTestReport {
  const NotificationSelfTestReport({
    required this.payload,
    required this.initialized,
    required this.permissionGranted,
    required this.shown,
    this.clickedPayload,
    this.clickWait = Duration.zero,
    this.error,
  });

  /// 本次自检期望的点击负载（见 [kNotificationSelfTestPayload]）。
  final String payload;

  /// 插件是否初始化成功。
  final bool initialized;

  /// 权限是否已授予（Linux/Windows 无权限概念，恒 true）。
  final bool permissionGranted;

  /// 通知是否真的发出去了（调用未抛异常）。
  final bool shown;

  /// 点击回来时的负载；null = 等待期内没收到点击。
  ///
  /// **与 [shown] 分开**：通知发出去了但用户没点（或点了但回调没接线）
  /// 是两件事，混在一起会把「回调没接上」误判成「通知没弹」。
  final String? clickedPayload;

  /// 等待点击的时长（用于判断「没收到」是不是等得太短）。
  final Duration clickWait;

  /// 失败时的异常摘要（不抛给 UI，只进日志/报告）。
  final String? error;

  /// 四步里第一个失败点。
  NotificationSelfTestOutcome get outcome {
    if (!initialized) return NotificationSelfTestOutcome.notInitialized;
    if (!permissionGranted) {
      return NotificationSelfTestOutcome.permissionDenied;
    }
    if (!shown) return NotificationSelfTestOutcome.sendFailed;
    if (clickedPayload == payload) return NotificationSelfTestOutcome.passed;
    return NotificationSelfTestOutcome.clickMissing;
  }

  /// 是否全链路通过（通知弹出 + 点击回到应用）。
  bool get passed => outcome == NotificationSelfTestOutcome.passed;

  /// 一行中文结论（展示给用户，也写进日志/诊断报告）。
  String get verdict => switch (outcome) {
    NotificationSelfTestOutcome.passed => '自检通过：通知已弹出，点击已回到应用',
    NotificationSelfTestOutcome.clickMissing =>
      '通知已发出，但 ${clickWait.inSeconds} 秒内没收到点击'
          '（没弹出？点了没反应？把这一行连同诊断报告一起提供）',
    NotificationSelfTestOutcome.notInitialized =>
      '通知插件初始化失败，通知将静默不生效（装配/平台通道问题）',
    NotificationSelfTestOutcome.permissionDenied =>
      '系统通知权限被拒：去系统设置里允许本应用发送通知后重试',
    NotificationSelfTestOutcome.sendFailed =>
      '通知发送失败${error == null ? '' : '：$error'}',
  };

  /// 结构化日志/诊断用的一行（键值对，不含正文）。
  String get logLine =>
      'notification_self_test outcome=${outcome.name} '
      'initialized=$initialized permission=$permissionGranted '
      'shown=$shown clicked=${clickedPayload != null} '
      'payload=$payload wait_ms=${clickWait.inMilliseconds}';

  @override
  String toString() => 'NotificationSelfTestReport($logLine)';
}

/// 自检的第一个失败点（顺序即链路顺序）。
enum NotificationSelfTestOutcome {
  /// 插件初始化失败。
  notInitialized,

  /// 权限被拒。
  permissionDenied,

  /// 通知发送失败。
  sendFailed,

  /// 通知发出去了，但没收到点击。
  clickMissing,

  /// 全链路通过。
  passed,
}
