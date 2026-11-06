import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 一次性提示的语义等级。
enum HintKind { info, warn, error }

/// 一次性提示内容。
///
/// ## 为什么是「数据 + 独立渲染组件」而不是一个 Widget
///
/// 提示文案是在**异步回调里**产生的（提交成功/失败、附件超限），而那时不该
/// 直接构造 Widget——页面只需要记下「当前该显示什么」，渲染交给 build。
/// 把文案与等级抽成一个不可变值对象，页面状态里就能只存 `Hint?`。
///
/// 上提前本仓库有两份**逐字节相同**的私有实现（悬浮输入窗 / 快速提交页），
/// 各 98 字节——这是本次上提里唯一真正的重复代码。
class Hint {
  const Hint(this.text, this.kind);

  final String text;
  final HintKind kind;
}

/// 内联提示行：图标 + 单行省略文本，颜色随 [HintKind] 变化。
class HintLine extends StatelessWidget {
  const HintLine({super.key, required this.hint});

  final Hint hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (IconData icon, Color color) = switch (hint.kind) {
      HintKind.info => (Icons.check_circle_outline, scheme.tertiary),
      HintKind.warn => (Icons.info_outline, scheme.secondary),
      HintKind.error => (Icons.error_outline, scheme.error),
    };

    return Row(
      children: [
        Icon(icon, size: SpbSpacing.lg, color: color),
        const SizedBox(width: SpbSpacing.xs),
        Expanded(
          child: Text(
            hint.text,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
