import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';

/// 品牌标志（成蹊 / Super PartyB）。
///
/// ## 为什么是位图资源而不是 `IconData`
///
/// 品牌标志是**图形**而非字形：它有双色渐变、圆角气泡与镂空对勾，用
/// `IconData` 表达不了。故与托盘图标同一取向（见 `apps/spb_desktop/pubspec.yaml`
/// 的注释）：随包分发一张 PNG，由 Flutter 缩放。
///
/// 资源随**本包**分发（`packages/spb_ui/assets/brand/logo.png`），故任何依赖
/// `spb_ui` 的端都能直接用它——两端各存一份会漂移（同 §6.13 的
/// `golden_fonts.dart` 教训）。
///
/// ## 为什么自带降级渲染
///
/// 单元测试宿主、以及将来某个未打包资源的端，`Image.asset` 会异步失败并抛
/// `FlutterError`——在登录页上表现为**一片红色错误块**，而那正是「用户进不来」
/// 的首屏。降级成一个同色系占位（圆角方块 + 对勾图标）比崩掉好：
/// 品牌是装饰，登录能力才是功能。
///
/// ## 无障碍
///
/// 标志是**装饰性**的：它旁边永远有 `登录 Super PartyB` 这样的标题文本。
/// 屏幕阅读器再念一遍「logo」只是噪音，故 `excludeFromSemantics: true`。
/// 这与 `docs/m0-manual-verification.md` §2.7「纯装饰图标不加语义标签」一致。
class SpbLogo extends StatelessWidget {
  const SpbLogo({super.key, this.size = 64, this.borderRadius});

  /// 边长（正方形）。默认 64：登录页首屏的标志位。
  final double size;

  /// 圆角。为 null 时按 `size` 取 `SpbRadius.md`（大图）或 `SpbRadius.sm`（小图）。
  final BorderRadius? borderRadius;

  /// 资源路径（**必须带包前缀**，见 Flutter 的 package asset 约定）。
  static const String assetPath = 'packages/spb_ui/assets/brand/logo.png';

  /// 标志的主色（与源 SVG 的 `rect fill` 一致：#1a5cd7）。
  ///
  /// 写死而非取主题色：品牌标志的颜色**不该随主题变**——深色主题下把底色
  /// 换成灰黑，对勾（靠底色镂空）就会失去对比。降级占位也用它，保证「资源
  /// 加载失败」时视觉上仍是同一个标志。
  static const Color brandBlue = Color(0xFF1A5CD7);

  @override
  Widget build(BuildContext context) {
    final radius =
        borderRadius ??
        BorderRadius.all(
          Radius.circular(size >= 48 ? SpbRadius.md : SpbRadius.sm),
        );

    return ClipRRect(
      borderRadius: radius,
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 装饰性：语义由旁边的标题承担。
        excludeFromSemantics: true,
        errorBuilder: (context, error, stackTrace) =>
            _Fallback(size: size, borderRadius: radius),
      ),
    );
  }
}

/// 资源不可用时的占位（同色系圆角方块 + 对勾）。
class _Fallback extends StatelessWidget {
  const _Fallback({required this.size, required this.borderRadius});

  final double size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: SpbLogo.brandBlue,
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: Icon(Icons.check_rounded, size: size * 0.5, color: Colors.white),
    );
  }
}
