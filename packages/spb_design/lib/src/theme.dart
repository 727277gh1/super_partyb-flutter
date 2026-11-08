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

    // 密度按平台分支（§6.77）：桌面端鼠标操作无「手指拍击」误差，控件密度
    // 高（一屏更多内容）；移动端触控需要 ≥48dp 的目标，standard 才能达标。
    // 测试环境（defaultTargetPlatform == android）自动落移动端分支。
    final desktop = switch (target) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
    final density = desktop ? VisualDensity.compact : VisualDensity.standard;
    // M3 字号几何（titleSmall = 14/w500）。ThemeData 的 textTheme 在构造后
    // fontSize 为 null（几何由 Theme.of 经 localize 合并），拿不到现成样式，
    // 故直接从 typography 取几何主题（与 localize 用的同源）。
    final m3Geometry = Typography.material2021(
      platform: target,
      colorScheme: scheme,
    ).englishLike;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fallback,
      // 桌面端：控件密度略高，一屏能放更多内容（移动端 standard，见上）。
      visualDensity: density,
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
      // ⚠️ 不设 `dense: true`（§6.77）：M3 下它把标题硬压到 13px 且发生在
      // 显式 style **之后**的 copyWith（list_tile.dart:925）——连页面显式
      // 指定 bodyMedium(14) 都会被覆盖，官方也明确不建议（list_tile.dart:501）。
      // 桌面端的紧凑诉求改由 ListTile 级 visualDensity + 显式标题样式承担。
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
        // 只对 ListTile 补密度（行高 -8px），不碰字号——标题字号由下面
        // titleTextStyle 显式钉在 titleSmall(14)：裸 M3 默认是 bodyLarge(16)，
        // 对中文列表行偏大；显式声明后不再有「以为 14 实际 13」的落差。
        visualDensity: desktop ? VisualDensity.compact : null,
        titleTextStyle: desktop
            ? m3Geometry.titleSmall?.copyWith(color: scheme.onSurface)
            : null,
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }
}
