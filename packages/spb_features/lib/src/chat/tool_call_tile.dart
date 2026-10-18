import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 工具调用（已与结果配对）。
///
/// ## 折叠 + 状态图标
///
/// 工具调用是「过程信息」：用户在等待时想看它，结果出来后就不关心了。
/// 故默认折叠，用图标表达状态（进行中 / 完成 / 失败），标题显示工具名。
///
/// ## 参数与结果用等宽字体
///
/// 两者都是机器格式（JSON / 命令输出），等宽字体能让缩进与对齐可读。
/// 不用 `SelectableText` 的富文本高亮——工具输出可能极大，做 JSON 高亮
/// 需要先完整解析，收益低且会在大输出上卡顿。
class ToolCallTile extends StatelessWidget {
  const ToolCallTile({
    super.key,
    required this.name,
    this.args,
    this.output,
    this.isComplete = false,
  });

  final String name;
  final Map<String, dynamic>? args;

  /// null 表示结果尚未返回。
  final String? output;

  final bool isComplete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 结果尚未返回 → 进行中。
    final isRunning = output == null;
    final hasFailed = isComplete && _looksLikeError(output);

    final (IconData icon, Color color, String label) = switch ((
      isRunning,
      hasFailed,
    )) {
      (true, _) => (Icons.sync, scheme.primary, '执行中'),
      (false, true) => (Icons.error_outline, scheme.error, '失败'),
      (false, false) => (Icons.check_circle_outline, scheme.tertiary, '完成'),
    };

    final mono = textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurfaceVariant,
    );

    return Card(
      color: scheme.surfaceContainerLow,
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
        childrenPadding: const EdgeInsets.fromLTRB(
          SpbSpacing.lg,
          0,
          SpbSpacing.lg,
          SpbSpacing.sm,
        ),
        leading: isRunning
            ? SizedBox(
                width: SpbSpacing.lg,
                height: SpbSpacing.lg,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(icon, size: SpbSpacing.lg, color: color),
        title: Text(
          name,
          style: textTheme.labelLarge?.copyWith(fontFamily: 'monospace'),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: color),
        ),
        children: [
          if (args != null && args!.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text('参数', style: textTheme.labelSmall),
            ),
            const SizedBox(height: SpbSpacing.xs),
            Container(
              width: double.infinity,
              padding: SpbSpacing.cardPadding,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: SpbRadius.cardAll,
              ),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(args),
                style: mono,
              ),
            ),
          ],
          if (output != null) ...[
            const SizedBox(height: SpbSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('结果', style: textTheme.labelSmall),
            ),
            const SizedBox(height: SpbSpacing.xs),
            Container(
              width: double.infinity,
              // 输出可能极长（如构建日志）。限高 + 内部滚动，避免撑爆时间线
              // 导致用户要滚很久才能跳过它。
              constraints: const BoxConstraints(maxHeight: 240),
              padding: SpbSpacing.cardPadding,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: SpbRadius.cardAll,
              ),
              child: SingleChildScrollView(
                child: SelectableText(output!, style: mono),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 粗判输出是否为错误。
  ///
  /// 服务端 `tool_result` 没有独立的错误标志位（payload 里只有文本），
  /// 故只能从文本特征判断。这是**启发式**，仅用于选图标颜色，
  /// 不用于任何控制流——判错只影响一个图标，不影响功能。
  static bool _looksLikeError(String? output) {
    if (output == null || output.isEmpty) return false;
    final lower = output.toLowerCase();
    return lower.startsWith('error') ||
        lower.startsWith('exception') ||
        lower.contains('traceback') ||
        lower.contains('failed');
  }
}
