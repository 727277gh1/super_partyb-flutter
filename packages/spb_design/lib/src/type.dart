import 'package:flutter/material.dart';

/// 语义化文字令牌（字号层次）。
///
/// ## 为什么需要它
///
/// Material 3 的 `labelSmall` 是 **11px**，且其 `letterSpacing: 0.5` 是为
/// 拉丁字母小标签设计的。列表页的时间/状态/来源几乎全用了 `labelSmall`，
/// 侧边栏角标甚至硬编码 `fontSize: 10`——中文字形笔画密度高，小字号下的
/// 可读性衰减比拉丁字母快得多，这是「列表文字偏小」的根因（详见
/// `docs/design-decisions/ui.md` 的对应小节）。
///
/// 本类把「某类 UI 文字该多大」收敛为**一处**定义：页面按语义取用，
/// 不再各自挑 TextTheme 槽位（挑槽位的人未必记得每个槽位的实际字号）。
///
/// | 语义 | 令牌 | 实际样式 |
/// |---|---|---|
/// | 列表条目的元数据行（时间/状态/来源） | [listMeta] | `bodySmall`（12 / w400） |
/// | 徽标 / 状态 chip / 导航 tab 标签 | [badge] | `labelMedium`（12 / w500） |
/// | 角标（Badge）里的数字 | [badgeCount] | `labelSmall` 归零 letterSpacing（11 / w500） |
///
/// 下界由 `packages/spb_design/test/tokens_test.dart` 钉住：元数据与徽标
/// **不小于 12**、角标数字**不小于 11**。想把字改小，先改这里并跑测试，
/// 不要在页面里 `copyWith(fontSize: …)` 或写死 `TextStyle(fontSize: …)`。
class SpbType {
  const SpbType._();

  /// 列表条目里的次要信息行：相对时间、状态词、来源、所属群名等。
  ///
  /// 取 `bodySmall`（12px / w400）：它是「需要**读懂**的正文级小字」，
  /// 不是装饰。颜色（如 `onSurfaceVariant`）由调用处 `copyWith` 补充。
  static TextStyle? listMeta(TextTheme textTheme) => textTheme.bodySmall;

  /// 小号强调文字：状态 chip、徽标文字、导航 tab 标签这类
  /// 「面积小但要一眼识别」的标签。
  ///
  /// 取 `labelMedium`（12px / w500）：与 [listMeta] 同字号但加粗，
  /// 与列表元数据拉开层次靠字重而不是靠缩小字号。
  static TextStyle? badge(TextTheme textTheme) => textTheme.labelMedium;

  /// 角标（`Badge`）里的数字。
  ///
  /// `labelSmall` 本身是 11px（Flutter 自家 `Badge` 的默认），但它的
  /// `letterSpacing: 0.5` 对数字只有害处（视觉更散），归零。
  ///
  /// ⚠️ **不要**用硬编码 `fontSize: 10`：那是全应用最小的字，
  /// 却放在最需要被看见的未读数上。
  static TextStyle? badgeCount(TextTheme textTheme) =>
      textTheme.labelSmall?.copyWith(letterSpacing: 0);
}
