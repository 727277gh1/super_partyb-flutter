import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 空状态：居中图标 + 文案。
///
/// ## 为什么上提到这里（issue #22）
///
/// 上提前仓库里有 3 份私有实现（对话页 `_EmptyHint`、对话列表页 `_EmptyState`、
/// 搜索页 `_EmptyState`），各自的图标尺寸、间距、文字颜色**互不相同**——用户
/// 在三个页面看到三种观感。本组件统一「居中 + 可选图标 + 弱化色文案」这一结构。
///
/// ## 为什么只收结构与样式，不收文案
///
/// 文案是**页面语义**（「还没有对话」vs「输入关键字搜索消息内容」vs「没有找到
/// 『X』」），属 `spb_features`。组件库不该知道这些，否则每加一个页面就要往
/// 这里塞一个字符串常量。
///
/// ## [icon] 可空
///
/// 对话页的空提示（「还没有对话，输入消息开始吧」）刻意不带图标——它出现在
/// 输入框正上方，加图标会让「引导输入」看起来像「页面出错」。故图标可选。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon});

  /// 空状态文案。
  final String message;

  /// 图标。null 时只渲染文案。
  ///
  /// 颜色固定用 [ColorScheme.outline]（弱化）——空状态不是错误，用 error 色
  /// 会让用户以为出了问题。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: SpbSpacing.xxxl, color: scheme.outline),
              const SizedBox(height: SpbSpacing.md),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
