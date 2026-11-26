/// 窗口管理相关的补充类型。
///
/// 核心接口（[DesktopCapabilities]）与 [WindowSpec] 定义在
/// `desktop_capabilities.dart`，本文件放窗口状态与几何信息。
library;

import 'dart:ui' show Size;

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

/// 主窗口的初始尺寸计算（按屏幕可用工作区自适应）。
///
/// ## 为什么需要它（2026-10 真实缺陷）
///
/// `WindowSpec.main` 的 1180×800 是**硬编码逻辑像素**，而逻辑像素在不同
/// DPI 缩放下的物理大小不同。1080p 的 14 寸笔记本上：
///
/// | 系统缩放 | 逻辑屏高 | 工作区高 | 800 高窗口居中后的 y |
/// |---|---|---|---|
/// | 100% | 1080 | 1040 | 120 ✅ |
/// | 125% | 864 | 824 | 12 ⚠️ 贴顶 |
/// | **150%** | **720** | **680** | **−60 ❌** |
/// | 175% | 617 | 577 | −111 ❌ |
///
/// 负的 y 意味着**标题栏（可拖拽区 + 最大化按钮）跑到屏幕外**——用户报的
/// 「无法移动、无法点全屏」正是这个。
///
/// ⚠️ **不是任务栏没考虑**：`window_manager.center()` 用的是
/// `visibleSize`（Windows 的 `rcWork` / Linux 的 `gdk_monitor_get_workarea`
/// / macOS 的 `visibleFrame`），三平台**都已排除任务栏与系统栏**。问题纯粹是
/// 「窗口比工作区还高」。
///
/// ## 取舍
///
/// 窗口占工作区的 [fillRatio]，但不超过 [maxWidth]/[maxHeight]（大屏上不必
/// 铺满，保持阅读舒适宽度），也不低于 [WindowSpec.minWidth]/[minHeight]
/// （否则小屏上会小到布局溢出——那时宁可让窗口略大于工作区，由窗口管理器
/// 自己钳制）。
class MainWindowSize {
  const MainWindowSize._();

  /// 默认占工作区的比例。
  ///
  /// 0.85 而不是 1.0：四周留一圈桌面可见，用户能一眼看出「这是个窗口」而不是
  /// 最大化态，也方便直接拖拽标题栏（贴满工作区时标题栏正好顶到屏幕上沿）。
  static const fillRatio = 0.85;

  /// 宽度上限（逻辑像素）。超过后只是变宽，可读性下降，故不跟随屏幕无限放大。
  static const maxWidth = 1180.0;

  /// 高度上限（逻辑像素）。
  static const maxHeight = 800.0;

  /// 计算主窗口初始尺寸。
  ///
  /// [workWidth] / [workHeight] 是屏幕**可用工作区**（已排除任务栏），
  /// 通常取 `Display.visibleSize`，缺失时回退 `Display.size`。
  /// [minWidth] / [minHeight] 来自 [WindowSpec]（低于它布局会溢出）。
  static (double, double) compute({
    required double workWidth,
    required double workHeight,
    double minWidth = 860,
    double minHeight = 600,
  }) {
    // 非正数说明显示器信息拿不到（无 DISPLAY / 平台未实现）。
    // 此时**退回规格里的静态值**，而不是算出一个 0×0 的窗口。
    if (workWidth <= 0 || workHeight <= 0) {
      return (maxWidth, maxHeight);
    }

    final width = _clampSize(workWidth * fillRatio, maxWidth, minWidth);
    final height = _clampSize(workHeight * fillRatio, maxHeight, minHeight);
    return (width, height);
  }

  /// 从 `screen_retriever` 的 `Display` 字段算出主窗口尺寸。
  ///
  /// ## 为什么收在本包而不是留在 `bootstrap.dart`
  ///
  /// `apps/spb_desktop/lib/bootstrap.dart` 的 `PlatformDesktopCapabilities`
  /// 需要 `window_manager` / `tray_manager` 才能构造，**测试里造不出来**，
  /// 故那里的逻辑无法在无头 CI 里验证（§6.41 的先例）。
  /// 「工作区优先、回退整屏」这条选择是**正确性核心**（回退写反会让小屏用户
  /// 拿到整屏高度、标题栏又出屏），必须可测——故把参数摊成两个可空尺寸，
  /// bootstrap 只剩一行转发。
  ///
  /// [visibleSize] 为 `Display.visibleSize`（工作区，已排除任务栏），
  /// [fullSize] 为 `Display.size`（整屏）。两者都缺失时退回规格值。
  static (double, double) fromDisplay({
    required Size? visibleSize,
    required Size? fullSize,
    double minWidth = 860,
    double minHeight = 600,
  }) {
    // 优先工作区：整屏尺寸包含任务栏与系统栏，用它算居中会把窗口推到
    // 任务栏底下（Windows 任务栏默认在底部时，窗口底部被盖住）。
    final work = visibleSize ?? fullSize;
    return compute(
      workWidth: work?.width.toDouble() ?? 0,
      workHeight: work?.height.toDouble() ?? 0,
      minWidth: minWidth,
      minHeight: minHeight,
    );
  }

  /// 先按 [cap] 封顶，再按 [floor] 兜底。
  ///
  /// 顺序不能反：小屏（工作区 600）上 `floor=600` 与 `cap=800` 同时生效时，
  /// 「先 floor 后 cap」会得到 800（又出屏），「先 cap 后 floor」得到 600
  /// （正好放下）。故先 cap。
  static double _clampSize(double raw, double cap, double floor) {
    final capped = raw > cap ? cap : raw;
    return capped < floor ? floor : capped;
  }
}
