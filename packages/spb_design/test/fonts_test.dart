import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';

/// `SpbFonts` 与「主题真的接上了字体」的回归测试。
///
/// ## 这个测试防的是什么（一个真实缺陷）
///
/// 2026-10 用户报障：Windows 上「门」显示成「一个框 + 正中一根竖」。
///
/// 根因不是字符写错，而是**主题从未指定字体**：
///
/// - `ThemeData(fontFamily: null)` 时 Flutter 按平台取
///   `Typography.material2021` 里**写死字体名**的 TextTheme
///   （Windows = `blackRedmond` = `Segoe UI`）；
/// - `Segoe UI` 是纯拉丁字体，中文字形只能靠**引擎的 last-resort 回退**；
/// - 那个回退取决于目标机器装了什么字体，**不可控也不可测**。
///
/// ⚠️ **这个缺陷的全部既有测试都是绿的**：字体名是合法字符串，`dart analyze`
/// 不报；golden 用 Ahem/tofu，看不出字形；widget test 不渲染真实字体。
/// 与 AGENTS.md §6.21 / §6.26 / §6.33 同一类「绿不代表对」。
///
/// ## 能验证什么、不能验证什么
///
/// **不能**在 `flutter test` 里验证字形：测试环境（`defaultTargetPlatform`
/// == android）根本没有 CJK 字体，中文永远是 tofu——改成什么字体名都看不出来。
/// 真实字形必须靠目标平台手测。
///
/// **能**验证的是接线：`SpbTheme` 确实把正确的字体名落进了 `ThemeData`
/// （而不是只定义了 `SpbFonts` 却忘了传参）。
void main() {
  /// Windows 是本次缺陷平台，必须显式指定。
  const windowsFont = 'Microsoft YaHei UI';

  /// 其余平台的系统级 CJK 回退本来就正确，**有意**留 `null`。
  const passthroughPlatforms = [
    TargetPlatform.android,
    TargetPlatform.fuchsia,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
  ];

  group('SpbFonts 结构约束', () {
    test('Windows 显式指定微软雅黑 UI（不是 Segoe UI）', () {
      // 直接钉住「修的是什么」：改回 Segoe UI 或 null 都会让这条挂。
      expect(SpbFonts.sansFor(TargetPlatform.windows), windowsFont);
      expect(
        SpbFonts.sansFor(TargetPlatform.windows),
        isNot('Segoe UI'),
        reason: 'Segoe UI 是纯拉丁字体，中文只能靠不可控的引擎回退',
      );
    });

    test('其余平台有意返回 null（不覆盖系统 locale 匹配）', () {
      // 显式指定 `PingFang SC` 会让日语用户被强制套上简体字形——
      // 那些平台的 CoreText / fontconfig / Android 本来就会按 locale 选。
      for (final p in passthroughPlatforms) {
        expect(
          SpbFonts.sansFor(p),
          isNull,
          reason: '$p 应保持平台默认（系统级 CJK 回退已正确）',
        );
        expect(
          SpbFonts.sansFallbackFor(p),
          isNull,
          reason: '$p 不该有显式 fallback 链（见 fonts.dart 的 2026-10 实测记录）',
        );
      }
    });

    test('Windows fallback 链非空、末位是通用族名、含 Win7 变体', () {
      final fb = SpbFonts.sansFallbackFor(TargetPlatform.windows);
      expect(fb, isNotNull);
      expect(fb, isNotEmpty);
      expect(fb!.last, 'sans-serif', reason: '链尾必须留通用族名，否则主字体在新平台缺失时直接 tofu');
      expect(
        fb,
        contains('Microsoft YaHei'),
        reason: 'Win7 及部分 Server 版没有 UI 变体，必须能退化到 YaHei',
      );
    });

    test('monoFallback 含 CJK 兜底（等宽字体四平台都不含中文）', () {
      // `'monospace'` 不是真实字体名，是「问系统要等宽字体」——四个平台
      // 拿到的都是纯拉丁（Consolas / Menlo / DejaVu Sans Mono）。
      // 工具调用的入参/结果经常含中文，必须显式接上 CJK。
      const cjkMarkers = ['CJK', 'YaHei', 'PingFang', 'WenQuanYi'];
      final hasCjk = SpbFonts.monoFallback.any(
        (f) => cjkMarkers.any((m) => f.toLowerCase().contains(m.toLowerCase())),
      );
      expect(
        hasCjk,
        isTrue,
        reason: 'monoFallback 缺 CJK 兜底：${SpbFonts.monoFallback}',
      );
      expect(SpbFonts.monoFallback.last, 'monospace');
    });
  });

  group('SpbTheme 字体接线（防止「定义了却没接上」）', () {
    test('Windows 主题的 textTheme 真的带上了微软雅黑', () {
      // ⚠️ 这条是本组最重要的一条：`SpbFonts` 定义得再对，
      // `ThemeData` 里没传 `fontFamily` 就等于没修。
      final theme = SpbTheme.lightFor(TargetPlatform.windows);
      final body = theme.textTheme.bodyMedium!;
      expect(body.fontFamily, windowsFont);
      expect(body.fontFamilyFallback, contains('Microsoft YaHei'));
    });

    test('Windows 主题不与 Flutter 默认（Segoe UI）重合', () {
      // 反方向守卫：若有人把 `_build` 里的 fontFamily 传参删掉，
      // `ThemeData` 会回落到 `blackRedmond` 的 Segoe UI——这条会挂。
      final theme = SpbTheme.lightFor(TargetPlatform.windows);
      expect(theme.textTheme.bodyMedium!.fontFamily, isNot('Segoe UI'));
      expect(theme.textTheme.titleLarge!.fontFamily, isNot('Segoe UI'));
    });

    test('非 Windows 平台保持 Flutter 默认（不传 fontFamily）', () {
      // `ThemeData(fontFamily: null)` 时 textTheme 的 fontFamily 来自
      // `Typography.material2021`——android 是 Roboto，Linux 也是 Roboto。
      // 只断言「不是我们硬塞的雅黑」，避免钉死 Flutter 内部实现。
      for (final p in passthroughPlatforms) {
        final f = SpbTheme.lightFor(p).textTheme.bodyMedium?.fontFamily;
        expect(f, isNot(windowsFont), reason: '$p 不该被套上 Windows 的字体');
      }
    });

    test('dark() 与 light() 的字体一致（只改亮度不改字形）', () {
      final light = SpbTheme.lightFor(TargetPlatform.windows);
      final dark = SpbTheme.darkFor(TargetPlatform.windows);
      expect(
        light.textTheme.bodyMedium?.fontFamily,
        dark.textTheme.bodyMedium?.fontFamily,
      );
      expect(
        light.textTheme.bodyMedium?.fontFamilyFallback,
        dark.textTheme.bodyMedium?.fontFamilyFallback,
      );
    });

    test('fontFamilyFallback 落到了每个文本样式（不只 bodyMedium）', () {
      // `ThemeData` 的 `fontFamilyFallback` 是 apply 到整个 TextTheme 的。
      // 若将来有人改成只覆盖个别样式，这条会挂。
      final theme = SpbTheme.lightFor(TargetPlatform.windows);
      final t = theme.textTheme;
      final styles = <String, TextStyle?>{
        'displayLarge': t.displayLarge,
        'headlineSmall': t.headlineSmall,
        'titleMedium': t.titleMedium,
        'bodyLarge': t.bodyLarge,
        'bodySmall': t.bodySmall,
        'labelSmall': t.labelSmall,
      };
      styles.forEach((name, style) {
        expect(
          style?.fontFamilyFallback,
          contains('Microsoft YaHei'),
          reason: 'textTheme.$name 没有拿到 fontFamilyFallback',
        );
      });
    });

    test('非 Windows 平台不注入 fontFamilyFallback（golden 基线守卫）', () {
      // ⚠️ 这条是 2026-10 实测出来的：给全部平台都配 fallback 链时，
      // `spb_features` 的 4 张 golden 基线全红。
      //
      // 原因**不是**渲染退化，而是 `flutter test` 里 `defaultTargetPlatform`
      // 恒为 android 且环境**没有 CJK 字体**：
      //   - 无 fallback 链：中文落到 Roboto 缺字的细线空心 tofu（基线原样）；
      //   - 有 fallback 链：链耗尽落到 Ahem 的粗实心方块 → 基线全废。
      // 两份都是 tofu，但像素不同。
      //
      // 若有人重新给 android/linux 加 fallback，这条会先挂——比 4 张 golden
      // 报「像素不匹配」更容易定位根因。
      for (final p in passthroughPlatforms) {
        final style = SpbTheme.lightFor(p).textTheme.bodyMedium;
        expect(
          style?.fontFamilyFallback,
          isNull,
          reason: '$p 注入了 fontFamilyFallback，会让 golden 基线退化成 Ahem',
        );
      }
    });
  });
}
