import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// golden 测试的宿主：固定主题 + 固定尺寸 + 固定方向。
///
/// ## 为什么要「固定」三件事
///
/// golden 是**逐像素**比较。任何一项不确定，基线就会随机失败：
///
/// | 项 | 不固定时的后果 |
/// |---|---|
/// | 主题 | 依赖 `MaterialApp` 默认主题 → Flutter 升级改默认色即全红 |
/// | 尺寸 | 默认 800×600 → 布局随可用宽度变化（换行点、`Wrap` 行数都变） |
/// | 方向 | 依赖环境 `Directionality` → 在测试里通常有，但显式给出更稳 |
///
/// 主题固定用 [SpbTheme.light]（而非 `ThemeData()`）：本仓库的组件都依赖
/// 设计令牌（`SpbSpacing` / `SpbRadius`），用默认主题测不出令牌被改坏。
///
/// ## 为什么尺寸默认取「够小但能放下组件」
///
/// 基线图越小，diff 时人眼越容易发现变化。默认 400×200 是「大多数单组件
/// 用例刚好放下」的值；需要更大时显式传 `size`。
///
/// ## 为什么外面包 `RepaintBoundary`
///
/// `matchesGoldenFile` 的 finder 必须指向**有自己 layer 的** `RenderObject`，
/// 否则会报「could not find a render object with a layer」。`MaterialApp` 的
/// 根已经有 layer，但组件本身通常没有——包一层最保险。
Widget goldenHost(
  Widget child, {
  Size size = const Size(400, 200),
  ThemeData? theme,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme ?? SpbTheme.light(),
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Material(child: Center(child: child)),
          ),
        ),
      ),
    ),
  );
}

/// 深色主题的宿主（用于验证令牌在两种亮度下都正确）。
Widget goldenHostDark(Widget child, {Size size = const Size(400, 200)}) =>
    goldenHost(child, size: size, theme: SpbTheme.dark());
