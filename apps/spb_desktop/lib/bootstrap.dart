import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 桌面端启动引导：初始化窗口、托盘、全局快捷键。
///
/// ## 为什么独立成文件
///
/// `main.dart` 只负责编排顺序，具体初始化逻辑（尤其涉及平台分支的部分）
/// 放在这里，便于测试时替换，也避免 `main.dart` 膨胀。
Future<DesktopCapabilities> bootstrapDesktop(
  WidgetsFlutterBinding binding,
) async {
  if (!SpbEnv.isDesktop) {
    return const NoopDesktopCapabilities();
  }

  try {
    // TODO(M0): 接入真实实现（window_manager / tray_manager / hotkey_manager）。
    // 当前返回 Noop 以便先跑通编译与依赖解析；M0 验证目标是确认这三个插件
    // 在 Flutter 3.47.5 下可用，以及多窗口是否依赖未稳定的 enable-windowing 特性。
    //
    // 验证清单（见仓库 AGENTS.md「M0 验证项」）：
    //   [ ] 三个窗口能否同时存在（主窗 + 设置窗 + 悬浮窗）
    //   [ ] 悬浮窗 Alt+Space 全局唤起（含失焦自动隐藏）
    //   [ ] 托盘菜单点击回调
    //   [ ] Linux 下需要 libsecret / appindicator 运行时依赖
    final caps = _PlatformDesktopCapabilities();
    await caps.initialize();
    return caps;
  } catch (e, st) {
    // 桌面能力初始化失败不应阻止应用启动——降级为无托盘/无快捷键，
    // 用户仍可通过主窗口正常使用。
    SpbLog.error('桌面能力初始化失败，降级运行', error: e, stackTrace: st);
    return const NoopDesktopCapabilities();
  }
}

/// 桌面端实现骨架。
///
/// 方法体待 M0 阶段用真实插件填充；当前所有方法静默成功，
/// 保证应用能启动、UI 能渲染。
class _PlatformDesktopCapabilities implements DesktopCapabilities {
  bool _initialized = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    SpbLog.info('桌面能力已初始化', {'platform': Platform.operatingSystem});
    // TODO(M0): windowManager.ensureInitialized(); 创建托盘; 注册 Alt+Space。
  }

  @override
  Future<void> showWindow(WindowRole role) async {
    SpbLog.debug('showWindow', {'role': role.name});
    // TODO(M0): 按 role 查找/创建窗口并 focus。
  }

  @override
  Future<void> hideWindow(WindowRole role) async {
    SpbLog.debug('hideWindow', {'role': role.name});
  }

  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async {
    SpbLog.debug('registerHotkey', {'id': id, 'binding': binding.label});
    // TODO(M0): hotKeyManager.register(...)。注意 Alt+Space 可能被系统占用，
    // 注册失败需返回 false 由设置页提示用户改绑。
    return true;
  }

  @override
  Future<void> unregisterHotkey(String id) async {}

  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}

  @override
  Future<void> setTrayTooltip(String tooltip) async {}

  @override
  Future<void> dispose() async {}
}
