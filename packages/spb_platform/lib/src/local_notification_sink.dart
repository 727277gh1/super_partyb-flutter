/// `flutter_local_notifications` 支撑的 [NotificationSink] 实现。
///
/// ## 为什么在本包（而不是 apps）
///
/// 契约与判定在 `spb_domain`（纯 Dart，可无平台通道单测）；**实现**需要插件，
/// 而插件是平台能力——放 `spb_platform` 让两端 apps 各写一份「初始化时机 +
/// 导航接线」即可，不必重复实现「插件调用 → 契约」的翻译。
///
/// ## 平台差异
///
/// | 平台 | 底层 | 系统依赖 |
/// |---|---|---|
/// | Android | 原生 `NotificationManager` | 无（需 `POST_NOTIFICATIONS` 运行时权限，API 33+） |
/// | iOS | `UNUserNotificationCenter` | 无 |
/// | Linux | `flutter_local_notifications_linux`（**纯 Dart**，走 D-Bus/XDG portal） | **无**（不依赖 libnotify 的 C 库，见下） |
/// | Windows/macOS | 各自实现 | 无 |
///
/// ## Linux 为什么没有新增系统依赖（与 issue #21 正文的预判不同）
///
/// issue 正文预判「Linux 走 libnotify，需加系统依赖，是主要成本」。核实后**不成立**：
/// `flutter_local_notifications_linux` 的 `pubspec.yaml` 只声明
/// `dartPluginClass: LinuxFlutterLocalNotificationsPlugin`，**没有 `pluginClass`、
/// 没有 `linux/` CMake 目录**——它是纯 Dart 实现，通过 `dbus` 包直接调
/// `org.freedesktop.Notifications`（或 XDG portal）。故 `bundle_linux_deps.sh`
/// 无需新增任何 `.so`。
///
/// 代价是**运行时**需要 D-Bus 会话总线（桌面环境都有；无头环境没有，此时
/// [requestPermission] 返回 false，判定层静默跳过，不会崩）。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:spb_domain/spb_domain.dart';

/// 基于 `flutter_local_notifications` 的通知发送实现。
///
/// ## 初始化是**显式**的（不是构造时自动做）
///
/// `initialize` 需要在合适的时机调用（Android 需要先有 Activity、iOS 需要
/// 在 `runApp` 之后设置 delegate）。构造时自动初始化会让「谁负责调用」
/// 变得模糊，且测试里无法构造一个「未初始化的实例」。
class LocalNotificationSink implements NotificationSink {
  LocalNotificationSink({
    FlutterLocalNotificationsPlugin? plugin,
    this.androidChannelId = 'spb_confirmations',
    this.androidChannelName = '待确认事项',
    this.androidChannelDescription = '有新的确认卡需要你处理',
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final String androidChannelId;
  final String androidChannelName;
  final String androidChannelDescription;

  /// 是否已 [initialize]。未初始化时 [show] 静默跳过（记日志）。
  bool _initialized = false;

  /// 已确认的权限结果（避免重复调用插件）。
  bool? _permissionGranted;

  void Function(String? payload)? _onSelect;

  @override
  set onSelect(void Function(String? payload)? callback) =>
      _onSelect = callback;

  /// 初始化插件并接线点击回调。
  ///
  /// 返回是否初始化成功（失败时后续调用静默降级）。
  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // 权限申请交给 requestPermission 显式做（见其文档），
            // 否则首次 initialize 就会弹框——那不是我们能解释文案的时机。
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: '打开'),
        ),
        onDidReceiveNotificationResponse: (response) {
          _onSelect?.call(response.payload);
        },
      );
      _initialized = ok ?? false;
      if (!_initialized) {
        debugPrint('[notifications] 插件初始化返回 false，通知将静默降级');
      }
      return _initialized;
    } catch (e) {
      // 无平台通道（flutter test）或无 D-Bus 会话：静默降级。
      // 不抛异常——上层不该为「这个环境没有通知」写 try/catch。
      debugPrint('[notifications] 插件初始化失败，通知将静默降级：$e');
      _initialized = false;
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    final cached = _permissionGranted;
    if (cached != null) return cached;

    if (!await initialize()) {
      _permissionGranted = false;
      return false;
    }

    try {
      // 平台分派。iOS/macOS 走 Darwin 的显式请求；Android 13+ 走运行时权限；
      // Linux/Windows 无权限概念（直接 true）。
      final granted = await _requestPlatformPermission();
      _permissionGranted = granted;
      return granted;
    } catch (e) {
      debugPrint('[notifications] 权限请求失败，按「未授予」处理：$e');
      _permissionGranted = false;
      return false;
    }
  }

  Future<bool> _requestPlatformPermission() async {
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // API < 33 时该方法返回 true（无运行时权限）。
      return await android?.requestNotificationsPermission() ?? false;
    }
    if (Platform.isIOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    if (Platform.isMacOS) {
      final macos = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      return await macos?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    // Linux / Windows：无权限概念。
    return true;
  }

  @override
  Future<void> show(LocalNotification notification) async {
    if (!await initialize()) return;
    try {
      await _plugin.show(
        // ## id 为什么取 hashCode 而不是自增序号
        //
        // 平台侧相同 id 的通知会**覆盖**前一条。确认卡 id 是字符串，而插件要
        // int；用 `hashCode` 让「同一张卡」映射到同一个 int（重复发即覆盖，
        // 不会堆叠）。自增序号会让每次重复发都堆一条新的。
        //
        // hashCode 碰撞（不同卡映射到同一 int）的后果只是「后一条覆盖前一条」，
        // 而调用方（`ConfirmationNotifier`）已按字符串 id 判重，实际不会发两条
        // 不同的卡到同一个 int——除非两张卡真的碰撞，概率极低且后果轻微。
        id: notification.id.hashCode,
        title: notification.title,
        body: notification.body,
        notificationDetails: _details(),
        payload: notification.payload,
      );
    } catch (e) {
      // 发送失败（无 D-Bus、被系统拒绝）不该影响业务逻辑。
      debugPrint('[notifications] 发送失败（已忽略）：$e');
    }
  }

  NotificationDetails _details() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        // channel id 必须与下面的 channelName 在**首次创建**时一致，
        // 之后改名字不会更新已存在的 channel（Android 的限制）。
        'spb_confirmations',
        '待确认事项',
        channelDescription: '有新的确认卡需要你处理',
        importance: Importance.high,
        priority: Priority.high,
        // 确认卡需要用户行动，用默认提示音即可（不自定义，避免打包音频资源）。
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
      linux: LinuxNotificationDetails(
        // 确认卡是「需要处理」而不是「提示」，用 normal 而非 low。
        urgency: LinuxNotificationUrgency.normal,
      ),
    );
  }
}
