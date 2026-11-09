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
    //
    // ⚠️ 取的是**校正过 CJK 度量**的副本，不是 `Typography.material2021(...)`
    // 的原始几何——见 [_cjkTypography]。校正必须发生在这条 localize 链的源头上，
    // 否则 `Theme.of` 合并回来的还是拉丁参数。
    //
    // ⚠️ `platform` 用 `defaultTargetPlatform` 而不是本方法注入的 [target]：
    // `Typography` 除了几何还携带**平台字体回退链**（Linux 是
    // `blackHelsinki` 的 Ubuntu/Adwaita/Cantarell…）。测试环境
    // `defaultTargetPlatform == android`，若按 [target] 取 linux 的
    // `blackHelsinki`，golden 会在本机渲染出与 CI 不同的字形
    // （`fonts_test.dart` 有一条专门钉住这件事）。生产端两者相同。
    final typography = _cjkTypography(
      Typography.material2021(
        platform: defaultTargetPlatform,
        colorScheme: scheme,
      ),
      // 正文差一档（§6.82）：移动端触屏阅读距离更近、手指遮挡更多，正文比
      // 桌面大一号（14 → 15）。**只动正文**，不动元数据（12 是下界）与
      // 块标题（16）——层次顺序由 `tokens_test.dart` 钉住。
      mobile: !desktop,
    );
    final m3Geometry = typography.englishLike;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      typography: typography,
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

  /// CJK 度量校正：把 M3 的**拉丁文**字距/行高换成中文可读的那一套（§6.79）。
  ///
  /// ## 为什么改 `Typography`，而不是 `ThemeData.textTheme`
  ///
  /// 两处都能生效：`ThemeData.localize` 做的是
  /// `localTextGeometry.merge(baseTheme.textTheme)`，而 `TextStyle.merge`
  /// 的语义是「argument 的非空字段优先」——写进 `textTheme` 的几何会覆盖
  /// 合并回来的原始几何。但 `typography` 才是几何的**唯一真源**：
  ///
  /// - 它有三套（`englishLike` / `dense` / `tall`，由 locale 的
  ///   `scriptCategory` 选择），写 `textTheme` 只影响被 merge 的那一套，
  ///   中文 locale 走 `dense` 时校正就失效了；
  /// - 本类的 `listTileTheme.titleTextStyle` 也直接读 `typography.englishLike`
  ///   （见 `_build`），两处各写一遍必然漂移。
  ///
  /// 故校正在 `Typography` 层做一次，`Theme.of` 合并出来的一定是同一套值。
  ///
  /// ## 改了什么（两条，都只针对中文正文/标签/小标题）
  ///
  /// | 属性 | M3（拉丁） | 本类 | 为什么 |
  /// |---|---|---|---|
  /// | `letterSpacing` | 0.1–0.5（为拉丁小标签设计的 tracking） | **0** | 中文全角字形不需要补字距；12px 下 0.4 已是 3% 的额外字距，密排正文显得「松」 |
  /// | `height` | 1.33 / 1.43 / 1.50 | **≥1.5** | 中文笔画密度高、无 ascender/descender 的节奏，12px 给 16px 行高偏挤 |
  ///
  /// 只动 `body*` / `label*` / `title*`：
  ///
  /// - **`labelSmall` 一字不改**：它是 Flutter 组件（`Badge` 等）的内部槽位，
  ///   改它会外溢到没审计过的组件（§6.76 的结论）。11px 的角标数字仍由
  ///   `SpbType.badgeCount` 在实例上归零字距。
  /// - **`headline*` / `display*` / `titleLarge` 不动**：它们是短的单行标题
  ///   （空态标题、登录短码），行高对可读性没有影响，动它只会扩大 golden 面。
  ///
  /// `dense` / `tall` 三套几何一起校正：`scriptCategory` 由 locale 决定，
  /// 中文 locale 落 `dense`，不跟着改会在真机上失效。
  ///
  /// ## 移动端正文再升一档（§6.82）
  ///
  /// 触屏阅读距离更近、手指遮挡更多，且移动端列表标题本来就是 M3 默认的
  /// 16（§6.77 的取向）。仅把 `bodyMedium`（正文）从 14 抬到 **15**：
  /// 仍低于 16 的块标题/列表标题，令牌层次（12 < 15 < 16）不被打破。
  static Typography _cjkTypography(Typography base, {required bool mobile}) =>
      base.copyWith(
        englishLike: _cjkTextTheme(base.englishLike, mobile: mobile),
        dense: _cjkTextTheme(base.dense, mobile: mobile),
        tall: _cjkTextTheme(base.tall, mobile: mobile),
      );

  /// 对一套几何主题逐槽位校正；语义见 [_cjkTypography] 的表。
  static TextTheme _cjkTextTheme(TextTheme g, {required bool mobile}) =>
      g.copyWith(
        bodyLarge: _cjkStyle(g.bodyLarge),
        bodyMedium: _cjkStyle(g.bodyMedium, mobile: mobile),
        bodySmall: _cjkStyle(g.bodySmall),
        labelLarge: _cjkStyle(g.labelLarge),
        labelMedium: _cjkStyle(g.labelMedium),
        titleSmall: _cjkStyle(g.titleSmall),
        titleMedium: _cjkStyle(g.titleMedium),
      );

  /// 单条样式的校正：字距归零 + 行高抬到 1.5（已 ≥1.5 的槽位保持原值）。
  ///
  /// [mobile] 为真时正文再升一档（§6.82）。**只有 `bodyMedium` 传 true**——
  /// 见 [_cjkTypography] 的说明。
  static TextStyle? _cjkStyle(TextStyle? style, {bool mobile = false}) {
    if (style == null) return null;
    final current = style.height ?? 1.0;
    final size = style.fontSize;
    return style.copyWith(
      letterSpacing: 0,
      height: current < _cjkMinHeight ? _cjkMinHeight : current,
      fontSize: mobile && size != null ? size + _mobileBodyBump : null,
    );
  }

  /// 中文正文的最小行高（§6.79）。改它要先看 `tokens_test.dart` 的行高断言。
  static const double _cjkMinHeight = 1.5;

  /// 移动端正文比桌面端大多少（§6.82）。改它要先看 `tokens_test.dart` 的
  /// 「移动端正文 15 / 桌面端 14」与令牌层次断言。
  static const double _mobileBodyBump = 1.0;
}
