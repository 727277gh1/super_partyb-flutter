import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_platform/spb_platform.dart';

/// 移动端没有桌面能力，恒为空实现。
///
/// 保留同名 Provider 使 `spb_features` 里的页面代码无需区分平台——
/// 页面统一读 `desktopCapabilitiesProvider`，由 [isSupported] 决定
/// 是否展示「托盘 / 全局快捷键」等设置项。
final desktopCapabilitiesProvider = Provider<DesktopCapabilities>((ref) {
  return const NoopDesktopCapabilities();
});
