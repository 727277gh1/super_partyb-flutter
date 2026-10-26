import 'package:flutter/foundation.dart';

/// 字体族选择（按平台显式指定 CJK 字体）。
///
/// ## 为什么必须显式指定，而不是「用系统默认」
///
/// Flutter **没有**「用系统默认字体」这回事。`ThemeData(fontFamily: null)` 时，
/// 它按平台从 `Typography.material2021` 里取一个**写死了字体名的** TextTheme
/// （`packages/flutter/lib/src/material/typography.dart`）：
///
/// | 平台 | TextTheme | 写死的 fontFamily | 带 fallback 列表？ |
/// |---|---|---|---|
/// | android / fuchsia | `blackMountainView` | `Roboto` | ❌ |
/// | **windows** | **`blackRedmond`** | **`Segoe UI`** | ❌ |
/// | macOS | `blackRedwoodCity` | `.SF NS …` | ❌ |
/// | iOS | `blackCupertino` | `CupertinoSystem…` | ❌ |
/// | linux | `blackHelsinki` | `Roboto` | ✅ 6 个 |
///
/// 除 Linux 外，这些都是**纯拉丁字体**——中文字形只能靠引擎的 last-resort
/// 回退，而那个回退**不可控也不可测**。
///
/// ## Windows 上回退到哪里：`Segoe UI` 的 FontLink 链
///
/// Windows 的字体替换（font linking）配置在注册表
/// `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink`。
/// `Segoe UI` 的链**日文排在简体中文前面**：
///
/// ```
/// MEIRYO.TTC,Meiryo UI      ← 日文，排在前面
/// MSGOTHIC.TTC,MS UI Gothic ← 日文
/// MSJH.TTC,Microsoft JhengHei UI  ← 繁体
/// MSYH.TTC,Microsoft YaHei UI     ← 简体（被前三个抢走）
/// ```
///
/// 于是简体中文字形优先由**日文字体**提供。这在多数汉字上只差笔画细节，
/// 但「门」在日文里写作「門」的简化形——**框内是一根居中的竖**，而简体中文
/// 标准字形是「框 + 左上的点」。这就是 2026-10 用户报障的「一个框上边一个
/// 短竖」的真实来源（像素测量确认上笔中心精确在 50%）。
///
/// 同类现象在其它软件里反复出现（Notepad++ #17476「门字识别为内」、
/// Excel/Office 的 Arial 中文回退、Ubuntu fontconfig 的日文优先）。
/// 根因都是同一件事：**基字体不含 CJK → 回退链先命中日文字体**。
///
/// 故本类的修法不是「找个能显示中文的字体」，而是**明确指定简体中文字体**，
/// 让回退链根本不需要被走到。
///
/// ## 为什么只有 Windows 配了 fallback 链
///
/// 主字体名在目标平台上**不一定存在**（`Microsoft YaHei UI` 只在 Win8+ 有，
/// Win7 上是 `Microsoft YaHei`），故 Windows 之后跟一串「同类但更可能存在的」。
///
/// ⚠️ **`'sans-serif'` 不是救命稻草**：Flutter 的 `fontFamilyFallback` 只认
/// **具体字体名**，通用族名（CSS 的 `sans-serif` / `serif` / `monospace`）
/// 在 Flutter 里**不被解析**。它留在链尾是无害的习惯写法，但真正兜底的是
/// 引擎的「所有 fallback 耗尽后用平台默认字体」这条规则
/// （见 `TextStyle.fontFamilyFallback` 的官方文档）。
///
/// 其余平台**有意留 `null`**：它们的系统级 CJK 回退本来就正确（CoreText /
/// fontconfig / Android 按 locale 选 Noto CJK），显式列出会盖掉那个 locale
/// 匹配——日语用户会被强制套上简体字形。
///
/// ⚠️ 2026-10 实测（**别重蹈**）：曾给全部平台都配 fallback 链，`spb_features`
/// 的 4 张 golden 基线全红。原因不是渲染退化，而是 `flutter test`
/// （`defaultTargetPlatform == android`）**没有 CJK 字体**：中文原本落到
/// Roboto 缺字时的**细线空心 tofu**，加链后变成链耗尽落到 Ahem 的**粗实心
/// 方块**——两份都是 tofu，只是画法不同。非 Windows 配 fallback 是
/// **零收益且制造基线噪音**。
///
/// 也因此，**不要**指望在 `flutter test` 里验证 CJK 字体接线是否生效：
/// 测试环境根本没有 CJK 字体，字形永远是 tofu。能验证的只有「主题里带了正确
/// 的字体名」这类结构性断言（见 `test/fonts_test.dart`），真实字形必须靠
/// 目标平台手测。
class SpbFonts {
  const SpbFonts._();

  /// 无衬线主字体名（`ThemeData.fontFamily`）。`null` 表示交给平台默认。
  ///
  /// ⚠️ **只有 Windows 返回非 null**。这不是偷懒，是实测后的取舍：
  ///
  /// | 平台 | 系统级 CJK 回退 | 需要显式指定？ |
  /// |---|---|---|
  /// | android / fuchsia | 有（系统按 locale 选 Noto CJK） | ❌ |
  /// | macOS / iOS | 有（PingFang 覆盖简繁日） | ❌ |
  /// | linux | 有（fontconfig，`blackHelsinki` 另带 6 个 fallback） | ❌ |
  /// | **windows** | **无**（`Segoe UI` 是纯拉丁，`blackRedmond` 零 fallback） | ✅ |
  ///
  /// 其余平台显式指定反而**有害**：会覆盖系统按用户语言（zh-CN / zh-TW / ja）
  /// 做的字体匹配——一个日语用户会被强制套上简体字形的 `PingFang SC`。
  ///
  /// ⚠️ **不要**改回全 `null`：那会让 Windows 回到 `Segoe UI` + 零 fallback 的
  /// 不可控状态（见类文档）。
  static String? sansFor(TargetPlatform platform) => switch (platform) {
    TargetPlatform.windows => 'Microsoft YaHei UI',
    TargetPlatform.macOS ||
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.fuchsia ||
    TargetPlatform.linux => null,
  };

  /// 无衬线 fallback 链（`ThemeData.fontFamilyFallback`）。
  ///
  /// ⚠️ **只有 Windows 返回非 null**，理由同 [sansFor]——其余平台的系统级回退
  /// 已经正确，显式列出反而会盖掉 fontconfig / CoreText 的 locale 匹配。
  ///
  /// ⚠️ 2026-10 实测（**别重蹈**）：曾给全部平台都配了 fallback 链，结果
  /// `spb_features` 的 4 张 golden 基线全红。原因不是渲染退化，而是
  /// `flutter test` 环境（`defaultTargetPlatform == android`）**没有 CJK 字体**：
  /// 中文原本落到 Roboto 缺字时的**细线空心 tofu**，加了 fallback 链后变成
  /// 链耗尽落到 Ahem 的**粗实心方块**——两份都是 tofu，只是画法不同。
  /// 即：非 Windows 平台配 fallback 是**零收益且制造基线噪音**。
  static List<String>? sansFallbackFor(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.windows => const [
          'Microsoft YaHei', // Win7 及部分 Server 版没有 UI 变体
          'Segoe UI', // 拉丁兜底（与 Flutter 默认一致）
          // ⚠️ Flutter **不解析**通用族名，这一项实际不生效；
          // 真正的兜底是「fallback 耗尽 → 用平台默认字体」。保留只为可读性。
          'sans-serif',
        ],
        TargetPlatform.macOS ||
        TargetPlatform.iOS ||
        TargetPlatform.android ||
        TargetPlatform.fuchsia ||
        TargetPlatform.linux => null,
      };

  static const List<String> monoFallback = [
    'Menlo', // macOS
    'Consolas', // Windows
    'DejaVu Sans Mono', // Linux
    'Courier New',
    // 以下是 CJK 兜底：等宽字体几乎都不含中文，必须显式接上。
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'WenQuanYi Micro Hei',
    'monospace',
  ];
}
