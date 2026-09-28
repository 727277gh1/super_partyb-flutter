import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spb_platform/spb_platform.dart';

/// 桌面能力 Provider。
///
/// 在 `main.dart` 的 `ProviderScope` 里被 override 为真实实现；
/// 默认值是空实现，使测试无需注入即可运行。
///
/// WHY 定义在独立文件：`main.dart` 会 import `app.dart`，
/// 而 `app.dart` 需要读本 Provider——放一起会形成 import 环。
final desktopCapabilitiesProvider = Provider<DesktopCapabilities>((ref) {
  return const NoopDesktopCapabilities();
});
