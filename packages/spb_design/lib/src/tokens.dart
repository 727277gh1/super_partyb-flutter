import 'package:flutter/widgets.dart';

/// 间距令牌（8pt 栅格）。
///
/// WHY 用 4 的倍数：与 Material 3 对齐，且能整除常见屏幕宽度，
/// 避免布局出现 0.5px 累积误差。
class SpbSpacing {
  const SpbSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// 对话气泡内边距。
  static const EdgeInsets bubblePadding = EdgeInsets.symmetric(
    horizontal: md,
    vertical: sm,
  );

  /// 页面内容边距。
  static const EdgeInsets pagePadding = EdgeInsets.all(lg);

  /// 卡片内边距。
  static const EdgeInsets cardPadding = EdgeInsets.all(md);
}

/// 圆角令牌。
class SpbRadius {
  const SpbRadius._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;

  static const BorderRadius cardAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius bubbleAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius inputAll = BorderRadius.all(Radius.circular(sm));
}

/// 动画时长令牌。
///
/// 桌面端动画应比移动端**更快**：鼠标操作无「手指抬起」延迟，
/// 沿用移动端时长会显得拖沓。
class SpbDuration {
  const SpbDuration._();

  static const Duration instant = Duration(milliseconds: 80);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);

  /// 「已复制」反馈的保持时长。
  ///
  /// 与上面几个**不是同类**：它们描述动画时长，本项描述「状态显示多久」。
  /// 放这里而非写在使用处，是因为它是一条**跨端一致**的交互约定——两端若各写
  /// 一个数，同一次操作在两端的反馈节奏就会不同。
  static const Duration copyFeedback = Duration(seconds: 2);
}

/// 断点（响应式布局）。
///
/// 桌面端窗口可自由缩放，必须支持三档：
/// 窄（单栏）/ 中（列表 + 内容）/ 宽（列表 + 内容 + 详情）。
class SpbBreakpoints {
  const SpbBreakpoints._();

  static const double compact = 720;
  static const double medium = 1000;
  static const double expanded = 1400;

  static bool isCompact(double width) => width < compact;
  static bool isMedium(double width) => width >= compact && width < expanded;
  static bool isExpanded(double width) => width >= expanded;
}
