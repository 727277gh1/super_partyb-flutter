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
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
        ],
      ),
    );
  }
}
