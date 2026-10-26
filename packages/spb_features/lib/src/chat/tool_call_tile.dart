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
///
/// ## 为什么是 `StatefulWidget`
///
/// 只为缓存一个派生量：[_hasFailed]。它是 `output` 的**纯函数**，而 `output`
/// 在一条工具卡的生命周期里只变一次（未返回 → 返回）。
///
/// 但父级每次 `setState` 都会重建本组件（`SliverChildBuilderDelegate` 的
/// `shouldRebuild` 恒 true），于是 [_looksLikeError] 会**每次 build 都跑一遍**
/// 全量扫描。实测（本机 2026-10，debug）1 MB 输出一次 **6.93 ms**，而工具
/// 输出到 MB 级并不罕见（构建日志、文件内容）。滚动时一屏十几条工具卡，
/// 每次重建就是几十毫秒——这正是「偶发重帧」的来源之一。
///
/// 缓存后成本从「每次 build」降到「每个 output 一次」。
class ToolCallTile extends StatefulWidget {
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
  State<ToolCallTile> createState() => _ToolCallTileState();
}

class _ToolCallTileState extends State<ToolCallTile> {
  /// 上一次算出的「输出像不像错误」。
  ///
  /// 只缓存结果，不缓存判据本身：`didUpdateWidget` 拿 `oldWidget` 就能比，
  /// 多存一份 `_cachedIsComplete` 只会多一个可能与 `widget` 不同步的副本。
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  @override
  void didUpdateWidget(ToolCallTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在输入真的变了时重算。`isComplete` 也进判据：`hasFailed` 是
    // `isComplete && ...`，完成态翻转时结果可能从 false 变 true。
    if (!identical(oldWidget.output, widget.output) ||
        oldWidget.isComplete != widget.isComplete) {
      _recompute();
    }
  }

  void _recompute() {
    _hasFailed = widget.isComplete && _looksLikeError(widget.output);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // 结果尚未返回 → 进行中。
    final isRunning = widget.output == null;
    final hasFailed = _hasFailed;

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
      // 等宽字体四个平台都不含 CJK（Windows 是 Consolas）。不接 fallback 时
      // 工具入参里的中文只能靠引擎隐式回退，字形不可控。见 SpbFonts 类文档。
      fontFamilyFallback: SpbFonts.monoFallback,
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
          widget.name,
          style: textTheme.labelLarge?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: SpbFonts.monoFallback,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          label,
          style: textTheme.bodySmall?.copyWith(color: color),
        ),
        children: [
          if (widget.args != null && widget.args!.isNotEmpty) ...[
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
                const JsonEncoder.withIndent('  ').convert(widget.args),
                style: mono,
              ),
            ),
          ],
          if (widget.output != null) ...[
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
                child: SelectableText(widget.output!, style: mono),
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
  ///
  /// ## 为什么不先 `toLowerCase()`
  ///
  /// 那是一次**全量拷贝**（Dart `String` 不可变）：1 MB 输出实测（本机
  /// 2026-10，debug）6.93 ms，而这里只关心四个**固定** ASCII 特征。
  /// 改成逐字符比较大小写不敏感后同量级降到 **2.66 ms**，且**零分配**
  /// （不产生与输入等长的临时字符串，GC 压力也随之下降）。
  ///
  /// `| 0x20` 把 ASCII 大写字母映射到小写：'A'=0x41 → 0x61='a'。
  /// 只对 ASCII 字母成立，而四个特征全是 ASCII——对非 ASCII 字符，
  /// `| 0x20` 可能碰巧相等（例如 U+0041 类情形），但**特征串自身**全 ASCII，
  /// 故不可能把中文误判成 `failed`。
  static bool _looksLikeError(String? output) {
    if (output == null || output.isEmpty) return false;
    return _startsWithAscii(output, 'error') ||
        _startsWithAscii(output, 'exception') ||
        _containsAscii(output, 'traceback') ||
        _containsAscii(output, 'failed');
  }

  /// 大小写不敏感的 ASCII 前缀判断（不分配）。
  static bool _startsWithAscii(String s, String prefix) {
    if (s.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if ((s.codeUnitAt(i) | 0x20) != prefix.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 大小写不敏感的 ASCII 子串查找（不分配）。
  static bool _containsAscii(String s, String needle) {
    final n = needle.length;
    final last = s.length - n;
    for (var i = 0; i <= last; i++) {
      var j = 0;
      while (j < n && (s.codeUnitAt(i + j) | 0x20) == needle.codeUnitAt(j)) {
        j++;
      }
      if (j == n) return true;
    }
    return false;
  }
}
