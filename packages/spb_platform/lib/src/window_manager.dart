/// 窗口管理相关的补充类型。
///
/// 核心接口（[DesktopCapabilities]）与 [WindowSpec] 定义在
/// `desktop_capabilities.dart`，本文件放窗口状态与几何信息。
library;

import 'desktop_capabilities.dart';

/// 窗口几何信息。
class WindowGeometry {
  const WindowGeometry({
    required this.role,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final WindowRole role;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// 悬浮输入窗的定位策略。
///
/// ## 为什么需要专门策略
///
/// 悬浮窗应出现在**鼠标所在显示器**上（多屏场景），且居中偏上，
/// 而不是固定在主窗口所在屏幕——否则多屏用户按 Alt+Space 后
/// 窗口会出现在另一块屏幕上，体验断裂。
class QuickCapturePlacement {
  const QuickCapturePlacement._();

  /// 根据目标显示器尺寸计算居中偏上的位置。
  ///
  /// [screenWidth] / [screenHeight] 为目标显示器尺寸，
  /// [windowWidth] / [windowHeight] 为窗口尺寸。
  /// 返回 `(x, y)`。
  static (double, double) compute({
    required double screenWidth,
    required double screenHeight,
    required double windowWidth,
    required double windowHeight,
  }) {
    final x = (screenWidth - windowWidth) / 2;
    // 垂直位置取屏幕高度的 28%：偏上但不过于贴顶，
    // 避免与系统顶栏/通知区域重叠。
    final y = screenHeight * 0.28;
    return (x, y);
  }
}
