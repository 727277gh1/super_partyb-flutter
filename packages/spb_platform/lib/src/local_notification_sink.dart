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

import 'dart:async' show Completer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:spb_core/spb_core.dart';
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
    this.androidSmallIcon = 'ic_notification',
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final String androidChannelId;
  final String androidChannelName;
  final String androidChannelDescription;

  /// Android 状态栏小图标（`res/drawable-*/ic_notification.png`）。
  ///
  /// ## 为什么不能沿用 `initialize` 的 `@mipmap/ic_launcher`
  ///
  /// 那是**启动器图标**：彩色、满幅。API 21 起状态栏图标必须是单色剪影，
  /// 系统把彩色图当 alpha 蒙版用 → 蓝底图标糊成一块实心白/灰。故单独提供
  /// 一张纯白剪影（生成脚本 `tools/gen_brand_assets.py` 的 `notification_icon`），
  /// 并在这里显式指定；不指定时插件会回落到 `defaultIcon`（即 `@mipmap/...`）。
  final String androidSmallIcon;

  /// 是否已 [initialize]。未初始化时 [show] 静默跳过（记日志）。
  bool _initialized = false;

  /// 已确认的权限结果（避免重复调用插件）。
  bool? _permissionGranted;

  void Function(String? payload)? _onSelect;

  /// 自检的点击捕获点（issue #90）。
  ///
  /// ## 为什么与 [_onSelect] 分开而不是临时接管它
  ///
  /// [_onSelect] 是**业务导航**的接线（`ConfirmationNotifier.attach` 设的）。
  /// 自检若把它临时替换掉，用户恰好在自检期间点了一张**真实确认卡**的通知，
  /// 那次点击就丢了（页面不跳，用户以为确认卡坏了）。故自检只旁路监听，
  /// 原回调照常执行。
  void Function(String? payload)? _selfTestClick;

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
          _selfTestClick?.call(response.payload);
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
    await _showInternal(notification);
  }

  /// [show] 的可判定版本：返回是否真的发出去（供自检区分「没弹」与「没点」）。
  Future<bool> _showInternal(LocalNotification notification) async {
    if (!await initialize()) return false;
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
      return true;
    } catch (e) {
      // 发送失败（无 D-Bus、被系统拒绝）不该影响业务逻辑。
      debugPrint('[notifications] 发送失败（已忽略）：$e');
      return false;
    }
  }

  /// 通知自检（issue #90）：走完整四步并给出可读结论。
  ///
  /// ## 它解决的问题
  ///
  /// 「通知到底能不能用」在无真机/无桌面的环境里**永远无法证明**（§8/§9）：
  /// 单测只能证明「装配对了」（注入的桩被调用），证明不了「toast 真的弹、
  /// 点了真的回到对话」。故把四步（初始化 / 权限 / 发送 / 点击）串成一条
  /// 可主动触发的自检，结果既给用户看，也进诊断报告。
  ///
  /// ## 为什么等待点击而不是立即返回
  ///
  /// 点击回调是异步且**可能永远不来**（权限被拒 / 用户没点 / 回调没接线）。
  /// 立即返回只能证明「发出去了」，而那正是 issue #90 里最容易误导人的
  /// 一半。故这里等 [clickWait]：拿到 payload = 全链路通；超时 = 前两/三步
  /// 可能没问题但最后一步没验证到（报告里 [NotificationSelfTestReport.shown]
  /// 仍是 true，用户据此判断「是没弹还是点不动」）。
  ///
  /// 等待期间 [_selfTestClick] 旁路捕获，**不接管**业务导航回调。
  Future<NotificationSelfTestReport> selfTest({
    String payload = kNotificationSelfTestPayload,
    Duration clickWait = const Duration(seconds: 30),
    String title = '通知自检',
    String body = '点我：验证点击能回到应用',
  }) async {
    final initialized = await initialize();
    if (!initialized) {
      return NotificationSelfTestReport(
        payload: payload,
        initialized: false,
        permissionGranted: false,
        shown: false,
      );
    }

    final granted = await requestPermission();
    if (!granted) {
      return NotificationSelfTestReport(
        payload: payload,
        initialized: true,
        permissionGranted: false,
        shown: false,
      );
    }

    final clicked = Completer<String?>();
    _selfTestClick = (p) {
      if (!clicked.isCompleted) clicked.complete(p);
    };

    final shown = await _showInternal(
      LocalNotification(
        // 固定 id：反复自检只覆盖同一条，不在通知中心堆出一串「通知自检」。
        id: 'spb-notification-self-test',
        title: title,
        body: body,
        payload: payload,
      ),
    );

    if (!shown) {
      _selfTestClick = null;
      return NotificationSelfTestReport(
        payload: payload,
        initialized: true,
        permissionGranted: true,
        shown: false,
      );
    }

    final clickedPayload = await clicked.future.timeout(
      clickWait,
      onTimeout: () => null,
    );
    _selfTestClick = null;

    final report = NotificationSelfTestReport(
      payload: payload,
      initialized: true,
      permissionGranted: true,
      shown: true,
      clickedPayload: clickedPayload,
      clickWait: clickWait,
    );
    // 写进环形缓冲：用户导出诊断报告时自带这一行，不必靠回忆。
    SpbLog.info('通知自检完成', {'result': report.logLine});
    return report;
  }

  /// 平台通知参数。
  ///
  /// 对测试可见：这几项是**只有真机/系统侧才看得出问题**的配置（渠道重要性
  /// 决定是否横幅、小图标决定状态栏显示成什么样），所以把「取参数」这一步
  /// 放进测试，至少能挡住「有人删了某一行」这类回归。
  @visibleForTesting
  NotificationDetails get debugNotificationDetails => _details();

  NotificationDetails _details() {
    // ## 这里读字段而不是写字面量
    //
    // 三个 `androidChannel*` 字段一直是构造参数，但曾经在这里被写成字面量
    // ——于是「定制渠道名」这个能力静默失效（传了也不生效）。字段化之后，
    // 测试能断言「传进去的就是发出去的」。
    //
    // 注意 Android 的限制：channel id 与名字只在**首次创建**时生效，之后
    // 改设置不会更新已存在的 channel（要改重要性只能换 id 或卸载重装）。
    return NotificationDetails(
      android: AndroidNotificationDetails(
        androidChannelId,
        androidChannelName,
        channelDescription: androidChannelDescription,
        icon: androidSmallIcon,
        importance: Importance.high,
        priority: Priority.high,
        // 确认卡需要用户行动，用默认提示音即可（不自定义，避免打包音频资源）。
        playSound: true,
      ),
      iOS: const DarwinNotificationDetails(),
      macOS: const DarwinNotificationDetails(),
      linux: const LinuxNotificationDetails(
        // 确认卡是「需要处理」而不是「提示」，用 normal 而非 low。
        urgency: LinuxNotificationUrgency.normal,
      ),
    );
  }

  @override
  Future<void> cancel(String id) async {
    if (!await initialize()) return;
    try {
      // 与 show 同一映射（id.hashCode），否则平台侧找不到对应通知。
      //
      // ⚠️ String.hashCode 不保证跨进程稳定（Dart 文档明确说明）：撤销只在
      // 同进程内有效——确认卡解决的时刻与发通知的时刻在同一会话。若将来要
      // 「冷启动清理上次残留」，必须换稳定哈希并落盘映射，见 issue #87。
      await _plugin.cancel(id: id.hashCode);
    } catch (e) {
      // 撤销失败的最坏后果只是通知多留一会儿，不影响业务。
      debugPrint('[notifications] 撤销通知失败（已忽略）：$e');
    }
  }

  /// 冷启动的启动详情（issue #86）。
  ///
  /// App 被系统杀掉后点通知，payload 随 launch details 到达——它不会走
  /// [onSelect]（那只覆盖进程存活时的点击）。调用方在路由建好后读一次：
  /// 非空则导航到 payload（一次），与热路径的 onSelect 互斥（本方法返回后
  /// 应把详情消费掉，避免同一次点击导航两次）。
  ///
  /// 未初始化 / 插件抛异常时返回 null（调用方退化为「打开主窗口」）。
  Future<NotificationAppLaunchDetails?> launchDetails() async {
    if (!await initialize()) return null;
    try {
      return await _plugin.getNotificationAppLaunchDetails();
    } catch (e) {
      debugPrint('[notifications] 读取启动详情失败（按无点击处理）：$e');
      return null;
    }
  }
}
