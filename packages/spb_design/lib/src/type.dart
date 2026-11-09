import 'package:flutter/material.dart';

import 'fonts.dart';

/// 语义化文字令牌（字号层次）。
///
/// ## 为什么需要它
///
/// Material 3 的 `labelSmall` 是 **11px**，且其 `letterSpacing: 0.5` 是为
/// 拉丁字母小标签设计的。列表页的时间/状态/来源几乎全用了 `labelSmall`，
/// 侧边栏角标甚至硬编码 `fontSize: 10`——中文字形笔画密度高，小字号下的
/// 可读性衰减比拉丁字母快得多，这是「列表文字偏小」的根因（详见
/// `docs/design-decisions/ui.md` §6.76 / §6.78）。
///
/// 本类把「某类 UI 文字该多大」收敛为**一处**定义：页面按语义取用，
/// 不再各自挑 TextTheme 槽位（挑槽位的人未必记得每个槽位的实际字号）。
///
/// | 语义 | 令牌 | 实际样式 |
/// |---|---|---|
/// | 列表/面板里的次要信息行（时间/状态/来源/数量/错误说明） | [listMeta] | `bodySmall`（12 / w400） |
/// | 徽标 / 状态 chip / 导航 tab 标签 | [badge] | `labelMedium`（12 / w500） |
/// | 角标（Badge）里的数字 | [badgeCount] | `labelSmall` 归零 letterSpacing + 抬到 12（w500） |
/// | 等宽文字（登录码 / 工具入参 / 文件内容） | [mono] | `listMeta` 或指定 base + `monospace` + CJK 回退 |
/// | 正文（对话气泡、卡片说明） | [body] | `bodyMedium`（14 / w400） |
/// | 块标题（卡片 / 面板区块标题） | [cardTitle] | `titleMedium`（16 / w500） |
///
/// 下界由 `packages/spb_design/test/tokens_test.dart` 钉住：**所有**令牌
/// 不小于 12（角标数字也不例外，§6.81），且令牌之间的**相对顺序**也被钉住
/// （元数据 < 正文 < 块标题）。
///
/// ## 四条用字规则（`tools/check_type_tokens.sh` 查前两条）
///
/// 1. **不要在页面里写死字号**：`copyWith(fontSize: …)` / `TextStyle(fontSize: 数字)`
///    一律禁止（绘制场景见 [metaSize]）。想把字改小，先改这里的令牌并跑测试。
/// 2. **`labelSmall` 不是「小一号的正文」**：11px 只允许出现在**纯装饰**或
///    **受 golden 锁定的位置**，且必须在该行（或前两行）写
///    `// 字号守卫豁免：<理由>`——守卫脚本据此放行。
/// 3. **小字号不再叠加透明度**：字号已经在下界时，颜色直接用
///    `onSurfaceVariant` / `onSecondaryContainer` 原色，**不要**再
///    `.withValues(alpha: 0.7)`。小字号 + 低对比度是乘法叠加，不是加法
///    （§6.78 修过 6 处：`队列：总计 N，你的 M`、`最近：xxx`、`N 段` 等
///    都因此变得几乎读不清）。
/// 4. **层次靠字重，不靠再缩小**：已经 12px 的标签要更显眼，加 `w600` 或换主色，
///    而不是回到 11px。
class SpbType {
  const SpbType._();

  /// 列表/面板里的次要信息行：相对时间、状态词、来源、所属群名、数量、错误说明。
  ///
  /// 取 `bodySmall`（12px / w400）：它是「需要**读懂**的正文级小字」，
  /// 不是装饰。颜色（如 `onSurfaceVariant`）由调用处 `copyWith` 补充。
  ///
  /// 聊天内面板（`turn_detail_panel` / `conversation_page` 状态条等）与
  /// 列表页**同一语义**，也用本令牌（§6.78）。
  static TextStyle? listMeta(TextTheme textTheme) => textTheme.bodySmall;

  /// 小号强调文字：状态 chip、徽标文字、导航 tab 标签这类
  /// 「面积小但要一眼识别」的标签。
  ///
  /// 取 `labelMedium`（12px / w500）：与 [listMeta] 同字号但加粗，
  /// 与列表元数据拉开层次靠字重而不是靠缩小字号。
  static TextStyle? badge(TextTheme textTheme) => textTheme.labelMedium;

  /// 角标（`Badge` / 计数胶囊）里的数字。
  ///
  /// `labelSmall` 本身是 11px（Flutter 自家 `Badge` 的默认），它的
  /// `letterSpacing: 0.5` 对数字只有害处（视觉更散），归零。
  ///
  /// 字号**抬到 12**（§6.81）：11 曾是全仓唯一低于可读下界的字号，而它恰好
  /// 用在「最需要被看见」的未读数上。抬到 12 后与 [badge] 同字号，靠 w500
  /// 与主色区分（`Badge` 的背景本来就是强调色）。
  ///
  /// ⚠️ **不要**用硬编码 `fontSize: 10`：那是全应用最小的字，
  /// 却放在最需要被看见的未读数上。
  static TextStyle? badgeCount(TextTheme textTheme) =>
      textTheme.labelSmall?.copyWith(letterSpacing: 0, fontSize: metaSize);

  /// 正文：对话气泡、卡片里的说明段落。
  ///
  /// 取 `bodyMedium`（14px / w400）。与 [listMeta]（12）拉开一档，
  /// 比 [cardTitle]（16）低一档。
  static TextStyle? body(TextTheme textTheme) => textTheme.bodyMedium;

  /// 块标题：卡片标题、面板区块标题（`spec_ui_card` 的 card、文件预览卡等）。
  ///
  /// 取 `titleMedium`（16px / w500）。注意**列表行标题**是另一档
  /// （`titleSmall` 14，由 `SpbTheme` 的 `listTileTheme.titleTextStyle` 钉在
  /// 桌面端）——「块标题 16 > 行标题 14 > 正文 14 > 元数据 12」是本仓库的
  /// 层次约定，`tokens_test.dart` 钉住顺序。
  static TextStyle? cardTitle(TextTheme textTheme) => textTheme.titleMedium;

  /// 等宽文字：登录码、工具入参/结果预览、文件内容预览。
  ///
  /// ## 为什么把「等宽」做成令牌，而不是各处 `fontFamily: 'monospace'`
  ///
  /// 等宽字体**四个平台都不含 CJK**（Windows 是 Consolas，Linux 是
  /// DejaVu Sans Mono）。只写 `fontFamily` 时，工具入参里的中文只能靠引擎
  /// 隐式回退——字形不可控（见 [SpbFonts] 类文档）。所以这里把**两件事**
  /// 绑在一起：`monospace` + `SpbFonts.monoFallback`。
  ///
  /// 各调用点原先各写一遍，其中「登录码」那一处就漏了 fallback（码是字母
  /// 数字，暂时没暴露，但下一个人复制这段样式给中文用就会中招）。
  ///
  /// [base] 不给时取 [listMeta]（12px，正文级小字）；工具卡标题这类要更大时
  /// 传 `textTheme.labelLarge`。
  static TextStyle? mono(TextTheme textTheme, {TextStyle? base}) =>
      (base ?? listMeta(textTheme))?.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: SpbFonts.monoFallback,
      );

  /// 元数字号（pt），**仅供绘制场景**取用：`CustomPainter` 里的 `TextPainter`
  /// 拿不到 `TextTheme`（它只要 `TextStyle`）。
  ///
  /// 与 [listMeta] 是同一个字号的两种形态，二者相等由
  /// `tokens_test.dart` 钉住——改这里必须同时改那边。
  static const double metaSize = 12.0;
}
