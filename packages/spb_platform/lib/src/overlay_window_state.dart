/// 悬浮输入窗的窗口属性改写与**回滚**顺序。
///
/// ## 为什么这段逻辑单独成文件（而不是留在 `apps/spb_desktop/bootstrap.dart`）
///
/// 「进入悬浮窗」是**多步窗口改写**（先隐藏 → 放宽最小尺寸 → 改尺寸 → 置顶 →
/// 隐藏任务栏 → 定位；显示另由 `revealOverlayMode` 在悬浮页布局完成后执行）。
/// 任一步失败时，若只清掉快照而不回滚，窗口会留在**半改造**状态：720×360、
/// 置顶、且**不在任务栏**——用户看到「一个卡住的小窗、然后应用像是退出了」，
/// 而进程其实还活着。
///
/// 而 `PlatformDesktopCapabilities` 需要 `window_manager` 才能构造，**测试里
/// 造不出来**（AGENTS.md §6.41 / §6.45 的同一取向）。故顺序判据（「逆序、跳过
/// 不可回滚项」）放在本包做纯逻辑，`bootstrap.dart` 只负责把每个枚举值翻译成
/// 一次 `windowManager` 调用。
library;

/// 悬浮输入窗的窗口高度**下限**：一行输入 + 状态/按钮行
/// （与 `WindowSpec.quickCapture.height` 一致）。
///
/// 内容比它还矮时不再继续缩：更矮会让标题栏占掉可观比例，窗口看起来像被
/// 压扁的对话框。
const double kOverlayMinWindowHeight = 132;

/// 悬浮输入窗的窗口高度**上限**：内容超过它就滚动，而不是让窗口继续长高。
///
/// 480 ≈ 一屏内能舒服看完的最大高度（多附件 chip 换行 + 四行输入 + 提示行）。
/// 不设上限的话，拖入十几个附件会把悬浮窗拉长到盖住半个屏幕——那是把
/// 「一小片空白」换成了「一大块遮挡」。
const double kOverlayMaxWindowHeight = 480;

/// 把「内容自然高度」换算成**窗口高度**，并夹到 [min]/[max]。
///
/// ## 为什么需要这一步，而不是直接把内容高度当窗口高度
///
/// 内容高度是 Flutter **视图**（client area）里的逻辑像素；而
/// `window_manager.setSize` 在两个平台上语义不同：Linux 走 `gtk_window_resize`
/// （client area），Windows 走 `SetWindowPos`（含标题栏与边框的**外框**）。
/// 两者的差值由调用方实测后加进 [contentHeight]（见 `bootstrap.dart` 的
/// `_windowChromeHeight`）——本函数只做「向上取整 + 夹取」这类纯逻辑，
/// 因而可以无头单测。
///
/// 向上取整而不是四舍五入：宁可多 0.4px，也不要因为取整把底部按钮裁掉。
double fitOverlayWindowHeight(
  double contentHeight, {
  double min = kOverlayMinWindowHeight,
  double max = kOverlayMaxWindowHeight,
}) {
  // NaN 无法夹取（比较全为 false，clamp 会把它原样吐出来，窗口高度就成了
  // NaN）。按「最小值」处理：下一帧内容尺寸变化会自我纠正。
  if (contentHeight.isNaN) return min;
  return contentHeight.ceilToDouble().clamp(min, max);
}

/// 进入悬浮模式时按顺序改写的窗口属性。
enum OverlayWindowAttribute {
  /// 最小尺寸（主窗口 860×600 → 1×1，否则 `setSize` 被钳住）。
  minimumSize,

  /// 窗口尺寸。
  size,

  /// 是否可调整大小。
  resizable,

  /// 是否置顶。
  alwaysOnTop,

  /// 是否从任务栏隐藏。
  skipTaskbar,

  /// 位置。
  position,

  /// 可见性：进入时**隐藏**（改尺寸/位置的过程中不让用户看见中间态）。
  ///
  /// 显示是单独一步（`revealOverlayMode`，在悬浮页完成首次布局之后），
  /// 因为它不可回滚：没有「之前是否可见」以外的旧值要写回，而回滚路径
  /// 最后总会无条件 `show()` 一次（否则用户找不回应用）。
  ///
  /// 故 [overlayRollbackOrder] 会把它剔除。
  visibility,
}

/// 失败回滚时的步骤顺序：**逆序**、去重、剔除 [OverlayWindowAttribute.visibility]。
///
/// ## 为什么必须逆序
///
/// 正向是「先放宽 min，再改 size」。反过来先改 size 再恢复 min 会被仍为
/// 1×1 的 min 兜住吗——不会，但**顺序反了更容易踩**「改回大尺寸后立刻被
/// 旧的置顶/任务栏属性掩盖」这类问题。逆序是「撤销一个事务」的默认语义，
/// 也保证「最后改的东西最先回退」。
///
/// ## 为什么剔除 visibility
///
/// 它不可回滚（见该枚举值），而 callers 会无条件在最后调一次 `show()`。
/// 这里剔除是为了让「回滚计划」只包含**真正需要还原旧值**的步骤——否则
/// 调用方得在 switch 里写一个空分支，而空分支最容易被后来者填成错误动作。
List<OverlayWindowAttribute> overlayRollbackOrder(
  List<OverlayWindowAttribute> applied,
) {
  final seen = <OverlayWindowAttribute>{};
  final plan = <OverlayWindowAttribute>[];
  for (final attribute in applied.reversed) {
    if (attribute == OverlayWindowAttribute.visibility) continue;
    if (!seen.add(attribute)) continue;
    plan.add(attribute);
  }
  return plan;
}
