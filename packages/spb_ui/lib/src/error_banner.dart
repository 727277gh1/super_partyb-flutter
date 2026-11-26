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
///
/// ## [category] / [detail] 与正文的分工（super_partyb#182 / #115）
///
/// 正文（[message]）永远是服务端下发的**一句话人话**（`error` payload 的
/// `message`）；Banner 不拿 `code` 自己造句，否则三端文案必然漂移。
///
/// - [category] 是**分类徽标**（如「内存不足」），只回答「哪一类失败」，让用户
///   一屏扫出差异；null 时不渲染（历史事件没有 `code`）；
/// - [detail] 是**原始诊断串**（`transport: upstream 429` / `responses invoke: …`），
///   含英文诊断、路径与命令，故默认折叠、只在「技术详情」里可展开看；
///   null 时整块不渲染。
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
    this.icon = Icons.error_outline,
    this.category,
    this.detail,
  });

  final String message;

  /// 重试动作。null 时不渲染按钮。
  final VoidCallback? onRetry;

  /// 按钮文案。默认「重试」。
  final String retryLabel;

  /// 前导图标（按错误码分类，默认 info 类错误图标）。
  final IconData icon;

  /// 分类徽标（如「内存不足」）。null 时不渲染。
  final String? category;

  /// 原始诊断串（默认折叠）。null 时不渲染。
  final String? detail;

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
          Icon(icon, color: scheme.onErrorContainer),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            // 单列 Column（而不是直接放 Text）：三个子项都可能缺席，缺席时
            // 渲染结果与「只有一个 Text」完全一致（golden 基线因此不动）。
            child: Column(
              // min 而不是默认的 max：默认会把 Column 撑满可用高度，
              // 三个可选子项都缺席时也会把提示条拉高（golden 基线因此会变）。
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (category != null) ...[
                  Text(
                    category!,
                    style: SpbType.badge(Theme.of(context).textTheme)
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: SpbSpacing.xxs),
                ],
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
                if (detail != null && detail!.trim().isNotEmpty)
                  _ErrorDetailText(detail: detail!),
              ],
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
                minimumSize: Size(
                  48,
                  SpbTheme.isDesktopPlatform(context) ? 32 : 48,
                ),
                tapTargetSize: SpbTheme.isDesktopPlatform(context)
                    ? MaterialTapTargetSize.shrinkWrap
                    : MaterialTapTargetSize.padded,
              ),
              child: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「技术详情」折叠块：默认收起，展开后显示原始诊断串（可选中复制）。
///
/// ## 为什么要折叠而不是直接显示
///
/// `detail` 是执行器原样给出的诊断（`transport: upstream 429` / 含工作区路径的
/// 命令串）。它对人排障有用、对普通用户只是噪音；而一旦默认展示，用户就会把
/// 它当成「界面上要读的正文」，也是我们此前在其它面板反复踩过的错位。
///
/// 用可选中文本而不是普通 `Text`：这一段的存在意义就是被复制去搜/贴给管理员。
class _ErrorDetailText extends StatefulWidget {
  const _ErrorDetailText({required this.detail});

  final String detail;

  @override
  State<_ErrorDetailText> createState() => _ErrorDetailTextState();
}

class _ErrorDetailTextState extends State<_ErrorDetailText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final desktop = SpbTheme.isDesktopTheme(theme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          style: TextButton.styleFrom(
            foregroundColor: scheme.onErrorContainer,
            // 命中区按端分档（与右侧「重试」按钮同一判据，#129）：移动端触控
            // 目标至少 48dp，桌面端保持紧凑。修复前这里是
            // `minimumSize: Size(0, 16)` + `padding: zero` + `shrinkWrap`，
            // 实测命中区只有 56×21dp——比一枚指尖接触面积还小。
            //
            // 约束必须在**按钮自身**：外包一层大盒子不参与 hit testing，
            // 看着变大、实际点不到。
            padding: desktop
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
            minimumSize: Size(
              desktop ? 0 : SpbSpacing.xxxl,
              desktop ? SpbSpacing.xxl : SpbSpacing.xxxl,
            ),
            tapTargetSize: desktop
                ? MaterialTapTargetSize.shrinkWrap
                : MaterialTapTargetSize.padded,
          ),
          child: Text(_expanded ? '收起技术详情' : '技术详情'),
        ),
        if (_expanded)
          SelectableText(
            widget.detail,
            style: SpbType.mono(
              theme.textTheme,
              base: theme.textTheme.bodySmall,
            )?.copyWith(color: scheme.onErrorContainer),
          ),
      ],
    );
  }
}
