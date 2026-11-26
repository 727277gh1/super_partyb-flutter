import 'package:flutter/widgets.dart';

import 'package:spb_design/spb_design.dart';

/// 整页状态面（空态 / 错误态）的布局骨架：**居中 + 可滚动**。
///
/// ## 为什么不能直接 `Center > Padding > Column`
///
/// 那正是 #126 之前的形态：`Column` 高度超过可视区就垂直溢出（RenderFlex
/// 黄黑斜纹），且**任何现有测试都不会红**。触发条件不需要极端场景：
/// §6.80 明确不 clamp 系统字号，320dp 窄屏 + 2 倍字号下，一百来字的
/// `SpbError.message` 就能溢出近 200dp。
///
/// ## 为什么要分「有界 / 无界」两种高度
///
/// | 宿主约束 | 正确行为 | 无条件 `minHeight: constraints.maxHeight` 会怎样 |
/// |---|---|---|
/// | 有界（`Scaffold.body`、`Expanded`） | 短内容垂直居中，长内容完整滚动 | 正确 |
/// | 无界（`ListView` 的 child） | 按内容自然高度布局，滚动交给外层 | `maxHeight == infinity` → `minHeight: infinity` → 布局异常 |
///
/// 无界的情形是真实存在的：`GroupListPage` 把空态放在带
/// `AlwaysScrollableScrollPhysics` 的 `ListView` 里，好让空列表也能下拉刷新。
/// 所以这里**不能**无条件读 `constraints.maxHeight`。
///
/// ## 为什么不只是「套一个 `SingleChildScrollView`」
///
/// 只套滚动容器会让短内容贴顶，失去「整页状态面居中」的观感（golden 锁的
/// 就是这个居中）。做法是滚动容器内再给一个 `minHeight = 可用高度` 的
/// `ConstrainedBox`，内容短时由 `Center` 居中、内容长时由滚动容器接管。
///
/// ## 文案不截断
///
/// 不加 `maxLines` / `ellipsis`：错误说明是**需要读懂的正文级文字**，滚一下
/// 就能读完，比截断更符合这里的目的。
class StatusSurface extends StatelessWidget {
  const StatusSurface({super.key, required this.child});

  /// 状态面的内容（通常是 `Column(mainAxisSize: min)`）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padded = Padding(padding: SpbSpacing.pagePadding, child: child);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) {
          // 外层已有滚动容器：只按内容排，别塞进无限 minHeight。
          return padded;
        }
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: padded),
          ),
        );
      },
    );
  }
}
