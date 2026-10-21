import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'fonts.dart';
import 'tokens.dart';

/// 应用主题。
///
/// ## 与 webapp 的关系
///
/// 当前是**独立的 Material 3 主题**，不试图复刻 webapp 的 Tailwind 样式。
/// 理由：Flutter 是自绘引擎，逐像素复刻 Web 的 CSS 值收益低（渲染管线不同），
/// 且会绑死后续调整空间。视觉一致性靠**设计令牌**（间距/圆角/动效时长）
/// 而非精确色值对齐。
///
/// 若将来要求严格一致，应从 webapp 的 Tailwind 配置生成令牌文件，
/// 而不是手工抄色值——手工抄必然漂移。
///
/// ## 字体：显式指定 CJK 字体（不依赖引擎隐式回退）
///
/// 见 [SpbFonts] 的文档——这是 2026-10 修的一个**真实字形缺陷**。
class SpbTheme {
  const SpbTheme._();

  /// 品牌主色（取自 webapp 的 accent）。
  static const Color _seed = Color(0xFF5B6ABF);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  /// 按平台构建主题（测试用；生产走 [light] / [dark]，平台取
  /// `defaultTargetPlatform`）。
  @visibleForTesting
  static ThemeData lightFor(TargetPlatform platform) =>
      _build(Brightness.light, platform: platform);

  @visibleForTesting
  static ThemeData darkFor(TargetPlatform platform) =>
      _build(Brightness.dark, platform: platform);

  static ThemeData _build(Brightness brightness, {TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );

    // 显式指定 CJK 字体，**不要**依赖引擎在 `Segoe UI` 缺字后的隐式回退。
    //
    // WHY 必须显式：`ThemeData(fontFamily: null)` 时 Flutter 按平台选
    // `Typography.material2021` 里写死的字体名——Windows 是 `Segoe UI`，
    // 纯拉丁字体。中文只能靠引擎的 last-resort 回退，那个字体**不可控也不可测**
    // （取决于目标机器装了什么），字形可能来自日文/繁体字体，甚至出现
    // 「门」被画成「框 + 正中一根竖」这类畸形字形。
    final fontFamily = SpbFonts.sansFor(target);
    final fallback = SpbFonts.sansFallbackFor(target);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fallback,
      // 桌面端：控件密度略高，一屏能放更多内容。
      visualDensity: VisualDensity.compact,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: SpbRadius.cardAll),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        border: OutlineInputBorder(borderRadius: SpbRadius.inputAll),
        contentPadding: EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
      ),
      listTileTheme: const ListTileThemeData(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: SpbSpacing.md),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }
}
