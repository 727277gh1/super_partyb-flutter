/// Windows 通知**初始化设置**的回归守卫。
///
/// ## 它防的是什么（真机 2026-11 踩过）
///
/// `InitializationSettings` 只给了 android/iOS/macOS/linux，**漏了 `windows`**。
/// 插件在 Windows 上对空值是硬性要求：
///
/// ```dart
/// // flutter_local_notifications/lib/src/flutter_local_notifications_plugin.dart
/// } else if (defaultTargetPlatform == TargetPlatform.windows) {
///   if (settings.windows == null) {
///     throw ArgumentError(
///       'Windows settings must be set when targeting Windows platform.',
///     );
///   }
/// ```
///
/// 而 `LocalNotificationSink.initialize` 的 `catch` 会把任何异常吞成
/// `_initialized = false`（这是对的：无平台通道时不该崩）。于是用户看到的只有
/// 自检那一句「通知插件初始化失败，通知将静默不生效（装配/平台通道问题）」
/// ——**方向完全指错**：装配是好的、平台通道也没问题，缺的是一条设置。
///
/// ## 为什么之前全绿
///
/// `flutter test` 在 Linux 上跑，`defaultTargetPlatform` 是 `linux`，而 `linux:`
/// 一直是给着的；Windows 分支只由 GH Actions 的 tag 构建编译，没人跑过自检。
/// 故这里用 `debugDefaultTargetPlatformOverride` 把平台切到 Windows 再问一遍。
///
/// ## 能验到哪、验不到哪
///
/// 本文件证明「设置项齐全、真插件不再因此抛 ArgumentError」；**证明不了 toast
/// 真的弹**——那仍需 Windows 真机（AGENTS.md §9）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows 目标下必须带 windows 设置，且字段来自构造参数', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final sink = LocalNotificationSink();

    final windows = sink.debugInitializationSettings.windows;
    expect(
      windows,
      isNotNull,
      reason:
          '缺少 windows 设置时插件抛 ArgumentError（"Windows settings must be set '
          'when targeting Windows platform."），被 initialize 吞成 false → '
          '自检只会说「装配/平台通道问题」',
    );
    expect(windows!.appName, kWindowsAppDisplayName);
    expect(windows.appUserModelId, kWindowsAppUserModelId);
    expect(windows.guid, kWindowsNotificationActivationGuid);
  });

  test('构造参数真的生效（与 androidChannel* 同一类回归）', () {
    final sink = LocalNotificationSink(
      windowsAppName: '自定义显示名',
      windowsAppUserModelId: 'com.example.custom',
    );

    expect(sink.debugInitializationSettings.windows?.appName, '自定义显示名');
    expect(
      sink.debugInitializationSettings.windows?.appUserModelId,
      'com.example.custom',
    );
  });

  test('激活 GUID 是稳定常量（换值 = 点通知回不来）', () {
    // 钉住字面量：它是 COM 激活器的注册键，不是随机值、也不是构造参数。
    expect(
      kWindowsNotificationActivationGuid,
      'b1f0a6c4-2d3e-4f57-9a8b-6c0d7e5a1f92',
    );
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(kWindowsNotificationActivationGuid),
      isTrue,
      reason: '必须是合法 GUID 形态，否则插件注册 COM 激活器时抛错',
    );
  });

  test('AppUserModelID 与安装包标识一致（Runner.rc 的 CompanyName.ProductName）', () {
    // 不一致时 toast 归不到本应用，部分 Windows 版本静默丢弃。
    expect(kWindowsAppUserModelId, 'com.atjog.spb.spb_desktop');
  });

  test('真插件不再因缺少 windows 设置抛 ArgumentError', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final settings = LocalNotificationSink().debugInitializationSettings;

    Object? error;
    try {
      await FlutterLocalNotificationsPlugin().initialize(settings: settings);
    } catch (e) {
      error = e;
    }

    // `flutter test` 里没有插件注册器，可能抛 LateInitializationError /
    // MissingPluginException——都属「本环境没有原生实现」，与设置项无关。
    // 唯一不能出现的是那个 ArgumentError。
    expect(
      error,
      isNot(isA<ArgumentError>()),
      reason: 'Windows 分支的 "Windows settings must be set" 必须消失',
    );
  });

  test('其他平台的设置没被顺手删掉', () {
    final settings = LocalNotificationSink().debugInitializationSettings;

    expect(settings.android, isNotNull);
    expect(settings.linux, isNotNull);
    expect(settings.iOS, isNotNull);
    expect(settings.macOS, isNotNull);
    expect(settings.windows, isNotNull);
  });
}
