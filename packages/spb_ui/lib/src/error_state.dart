import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 整页错误状态：图标 + 消息 + 「重试」按钮。
///
/// ## 为什么上提到这里（issue #22）
///
/// 上提前仓库里有 2 份**逐字段相同**的私有实现（对话列表页 `_FullPageError`、
/// 搜索页 `_ErrorState`），连「重试」按钮的样式（`FilledButton.tonal`）都一样。
/// 这是本次上提里除 [ErrorBanner] 之外第二处真正的重复代码。
///
/// ## 与 [ErrorBanner] 的分工
///
/// | 组件 | 场景 |
/// |---|---|
/// | [ErrorBanner] | **局部**错误（内联在页面某块区域，如登录表单下方） |
/// | [ErrorState] | **整页**错误（页面主体无内容可显示，只有这个错误） |
///
/// 两者的排版因此不同：Banner 是「一块底色 + 一行文本」（会嵌在别的布局里），
/// State 是「居中大图标 + 消息 + 行动按钮」（占据整页）。
///
/// ## [onRetry] 为 null 时不渲染按钮
///
/// 有些错误**不可重试**（如参数非法、权限不足）：此时渲染一个按了也没用的
/// 「重试」比不渲染更糟——用户会反复点它。由调用方决定（传 null）。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  /// 错误消息。直接展示给用户，故调用方应传**已本地化/已归一**的文案
  /// （通常是 `SpbError.message`）。
  final String message;

  /// 重试动作。null 时不渲染按钮。
  final VoidCallback? onRetry;

  /// 按钮文案。默认「重试」。
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onRetry = this.onRetry;
    return Center(
      child: Padding(
        padding: SpbSpacing.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: SpbSpacing.xxxl,
              color: scheme.error,
            ),
            const SizedBox(height: SpbSpacing.md),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: SpbSpacing.lg),
              FilledButton.tonal(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
