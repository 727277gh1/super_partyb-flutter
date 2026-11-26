import 'package:flutter/material.dart';

import 'tokens.dart';

/// 动效策略：把「系统要求减少动效」这条偏好落成**可用的 API**（issue #132）。
///
/// ## 为什么需要一个工具，而不是各处直接读 `MediaQuery`
///
/// `MediaQuery.disableAnimationsOf(context)` 本身不难读，但**每条调用点都要
/// 自己选对处置方式**，而这正是最容易做错的地方：
///
/// | 场景 | 正确处置 | 做错会怎样 |
/// |---|---|---|
/// | `Scrollable.ensureVisible` | `duration: Duration.zero` | 传零时长是合法的，无需分支 |
/// | `ScrollController.animateTo` | 改 `jumpTo` | **`animateTo` 不接受零时长**（断言失败），"把时长归零" 直接崩 |
/// | `AnimatedRotation` / `AnimatedSize` | `duration: Duration.zero` | 动画仍在跑，前庭敏感用户照样不适 |
/// | spinner（`CircularProgressIndicator`） | 换成静态图标 | 时长归零 ≠ 停止无限旋转 |
/// | 「已复制」反馈保持 2 秒、网络超时、防抖 | **不动** | 它们不是动效时长，归零会让功能坏掉 |
///
/// 本类只覆盖前三行。状态保持时长（[SpbDuration.copyFeedback]）、超时与防抖
/// 刻意**不**在这里，避免下一个人顺手把它们也一起归零。
///
/// ## 为什么 `scrollTo` 要单独给一个方法
///
/// 追底是最容易踩坑的一处：`animateTo` 的 `duration` 是必填且**必须 > 0**，
/// 所以「减少动效时把时长设成 0」不是可选方案。这里把「该跳还是该动画」
/// 收成一个调用，调用点不必记得这条区别。
class SpbMotion {
  const SpbMotion._();

  /// 系统是否要求减少动效（`MediaQueryData.disableAnimations`）。
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// 过渡时长：减少动效时归零，否则用传入的令牌（默认 [SpbDuration.normal]）。
  ///
  /// 用于 `AnimatedRotation` / `AnimatedSize` / `Scrollable.ensureVisible`
  /// 这类**接受零时长**的 API。
  static Duration duration(
    BuildContext context, [
    Duration base = SpbDuration.normal,
  ]) => reduceMotion(context) ? Duration.zero : base;

  /// 把 [controller] 滚到 [offset]：减少动效时 `jumpTo`（瞬时到达），
  /// 否则沿用令牌时长做动画。
  ///
  /// ⚠️ **不要**改成 `animateTo(..., duration: Duration.zero)`：那会断言失败。
  ///
  /// 返回的 Future 在两种分支下语义一致（滚动完成/已定位），调用方无需分支。
  static Future<void> scrollTo(
    BuildContext context,
    ScrollController controller,
    double offset, {
    Duration duration = SpbDuration.fast,
    Curve curve = Curves.easeOut,
  }) {
    if (!controller.hasClients) return Future<void>.value();
    if (reduceMotion(context)) {
      controller.jumpTo(offset);
      return Future<void>.value();
    }
    return controller.animateTo(offset, duration: duration, curve: curve);
  }
}
