import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 错误提示条：整块 errorContainer 底色 + 图标 + 可换行的多行文本。
///
/// ## 为什么用 [Key] 而不是内置 ValueKey
///
/// 上提前本仓库有两份私有实现（登录页 / 同步页），**唯一差别**就是写死的
/// 测试 key（`login-error` / `sync-error`）——两处共 12 个测试断言依赖它。
///
/// 把 key 作为构造参数由调用方传入，既去掉了重复，又让「哪个页面报错」这件
/// 事留在页面自己手里：组件库不该知道「登录页」这种业务概念，否则每加一个
/// 页面就要往这里塞一个字符串。
///
/// 用法：
/// ```dart
/// ErrorBanner(key: const ValueKey('login-error'), message: error)
/// ```
///
/// ## [onRetry] 为 null 时不渲染按钮
///
/// 与 [ErrorState] 同取向：有些错误重试无用（参数非法 / 权限不足），渲染一个
/// 按了也没用的按钮比不渲染更糟。当前唯一使用者是对话页的 `ErrorItem`
/// （turn 终态失败），那里传的是「用原输入重发本轮」。
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;

  /// 重试动作。null 时不渲染按钮。
  final VoidCallback? onRetry;

  /// 按钮文案。默认「重试」。
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onRetry = this.onRetry;
    return Container(
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: SpbSpacing.sm),
            // 用 TextButton 而不是 FilledButton：这是**次要**动作（用户多数
            // 时候只是看一眼错误），且要嵌在 errorContainer 底色上——
            // FilledButton 的填充色会与底色打架。
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
                padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}
