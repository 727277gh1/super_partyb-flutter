import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x 的**相对亮度对比度**计算（issue #127）。
///
/// ## 为什么用计算式而不是 golden
///
/// 「12px 小字压在 secondaryContainer 上读不清」是**颜色属性**，不是像素形态：
/// golden 会把换行、字形、抗锯齿一起锁进来，改字体就全红，而真正要拦的那件事
/// （对比度从 7.2 掉到 3.5）在 golden 里没有任何信号。计算式则直接给出
/// 「4.45:1 < 4.5」这种可判定的结论。
///
/// ## 半透明文字必须先与背景合成
///
/// `onSecondaryContainer.withValues(alpha: 0.8)` 的**名义**颜色与背景比是
/// 7.20:1（完全合格），实际渲染出来是 4.45:1（不合格）。所以这里先把前景
/// 按 alpha 合成到背景上再算——这正是 §6.78 规则 3 的量化依据。
double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

/// 相对亮度（WCAG：`0.2126R + 0.7152G + 0.0722B`，sRGB 线性化后）。
double relativeLuminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// 把半透明前景合成到不透明背景上（alpha 混合）。
Color composite(Color fg, Color bg) {
  final a = fg.a;
  if (a >= 1.0) return fg;
  return Color.from(
    alpha: 1,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}

/// 前景与背景的对比度（1.0–21.0）。前景半透明时先合成。
double contrastRatio(Color fg, Color bg) {
  final f = relativeLuminance(composite(fg, bg));
  final b = relativeLuminance(bg);
  final hi = math.max(f, b), lo = math.min(f, b);
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA 对**普通文字**（< 18pt 常规 / < 14pt 粗体）的下界。
///
/// 本仓最小的文字令牌是 12px，全部落在「普通文字」档，所以断言一律用这个值。
const double wcagAAForNormalText = 4.5;

/// 取某个控件**实际**被绘制的背景色：最近的 `Material` 祖先的 `color`。
///
/// 不能直接拿 `scheme.surface` 当背景：卡片底是 `secondaryContainer`、
/// `errorContainer` 等，写死会让断言测的是「我以为的配色」而不是屏幕上的配色。
Color paintedBackground(WidgetTester tester, Finder finder) {
  final materials = find.ancestor(of: finder, matching: find.byType(Material));
  expect(materials, findsWidgets, reason: '文字必须在某个 Material 表面上渲染');
  // `.last` = 最深的祖先 = 真正垫在文字下面的那一层。
  final material = tester.widget<Material>(materials.last);
  final color = material.color;
  expect(color, isNotNull, reason: 'Material 未指定 color 时背景由主题决定，断言无从计算');
  return color!;
}

/// 断言一个小字 `Text` 的**实际**颜色在其真实背景上达到 [min]。
///
/// 与角色表（`a11y_text_contrast_test.dart`）的分工：角色表证明「令牌组合
/// 安全」，本函数证明「这个使用点确实用了安全的令牌」。把组件改回
/// `outline` 或叠上 `alpha: 0.7`，角色表仍全绿，而这里必须变红（#127）。
void expectTextReadable(
  WidgetTester tester,
  Finder finder, {
  double min = wcagAAForNormalText,
}) {
  final text = tester.widget<Text>(finder);
  final style = text.style;
  expect(style, isNotNull, reason: '$finder 未显式给样式，无法核对颜色');
  final color = style!.color;
  expect(color, isNotNull, reason: '样式里没有颜色：断言无从计算对比度');
  final bg = paintedBackground(tester, finder);
  final ratio = contrastRatio(color!, bg);
  expect(
    ratio,
    greaterThanOrEqualTo(min),
    reason:
        '${_describeColor(color)} 压在 ${_describeColor(bg)} 上只有 '
        '${ratio.toStringAsFixed(2)}:1，低于 AA 下界 $min',
  );
}

String _describeColor(Color c) {
  if (c.a < 1.0) {
    return '半透明色 ${_hex(c)}（alpha ${c.a.toStringAsFixed(2)}）';
  }
  return _hex(c);
}

String _hex(Color c) =>
    '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}';
