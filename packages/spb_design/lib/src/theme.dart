import 'package:flutter/material.dart';

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
class SpbTheme {
  const SpbTheme._();

  /// 品牌主色（取自 webapp 的 accent）。
  static const Color _seed = Color(0xFF5B6ABF);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
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
