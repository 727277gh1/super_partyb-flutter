import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_design/spb_design.dart';

/// 「复制到剪贴板」图标按钮：点一下复制 [text]，短暂显示勾选作为反馈。
///
/// ## 与代码块自带的复制按钮的关系
///
/// `gpt_markdown` 的代码围栏**已自带**复制按钮（`CodeField._copyButton`，
/// 当 `style.showCopyButton ?? true` 时渲染）。本组件补的是另一件事：
/// **整条消息正文**的复制。两者不重叠——代码块按钮只复制那一段代码，
/// 且只存在于代码围栏上；用户想复制一条纯文本回复时没有任何入口。
///
/// ## 为什么做成本仓库自己的组件而不是复用库的实现
///
/// `CodeField` 是 `gpt_markdown` 的**私有**实现（`lib/custom_widgets/` 下，
/// 不在公开 API 里），无法从外部引用。故按同样的交互语义重写一份。
///
/// ## 交互语义（与库实现对齐）
///
/// - 复制成功 → 图标切成勾选，保持 [SpbDuration.copyFeedback] 后复位；
/// - **复制中 / 已复制时忽略重复点击**：连点两次会把剪贴板内容覆盖成同一个值
///   （无害），但反馈会不断重置，用户以为没生效；
/// - 失败（平台通道不可用）只复位，不弹错误——剪贴板失败通常无补救动作，
///   弹窗打断阅读的代价大于收益；
/// - `mounted` 守卫：复制是异步的，用户可能在延迟期间离开页面。
///
/// ## 为什么不给「已复制」加动画
///
/// 库实现用 `AnimatedSwitcher` + `ScaleTransition`。本组件从简（直接换图标）：
/// 它出现在每一条消息下方，一屏可能有十几份，逐帧动画的收益不抵开销。
/// 反馈靠**图标形状变化**（复制 → 勾选）传达，已经足够明确。
class CopyIconButton extends StatefulWidget {
  const CopyIconButton({super.key, required this.text, this.tooltip = '复制'});

  /// 要写入剪贴板的完整文本。
  ///
  /// 传入的是**原始正文**（组件入参），不是渲染后的富文本——从 `RichText`
  /// 反推会带上 Markdown 渲染产生的换行与省略。
  final String text;

  /// 悬停/长按提示文案。null 时不显示提示。
  final String? tooltip;

  @override
  State<CopyIconButton> createState() => _CopyIconButtonState();
}

class _CopyIconButtonState extends State<CopyIconButton> {
  /// 是否已复制（驱动图标切换）。
  bool _copied = false;

  /// 是否有一次复制正在进行。与 [_copied] 分开：复制是异步的，两者之间存在
  /// 一个「已点击但结果未知」的窗口。
  bool _copying = false;

  Future<void> _copy() async {
    if (_copying || _copied) return;
    setState(() => _copying = true);

    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
    } catch (_) {
      // 平台通道不可用（如无剪贴板的后端）。静默复位：没有可执行的补救动作，
      // 弹错误只会打断阅读。
      if (mounted) setState(() => _copying = false);
      return;
    }

    if (!mounted) return;
    setState(() {
      _copying = false;
      _copied = true;
    });
    await Future<void>.delayed(SpbDuration.copyFeedback);
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = _copied ? '已复制' : (widget.tooltip ?? '复制');

    // 用 [IconButton] 而不是自绘圆形按钮：它自带最小触控目标（≥48dp）与
    // 悬停/按下反馈，且 `tooltip` 同时充当无障碍名称（图标按钮没有可读文本）。
    // 库实现自绘是因为它要精确控制 32×32 的紧凑尺寸；本组件出现在气泡下方，
    // 有足够空间，不必为此牺牲触控目标。
    return IconButton(
      // 视觉尺寸收敛到与正文同档，但**不改**触控目标（见上）。
      iconSize: SpbSpacing.lg,
      icon: Icon(
        _copied ? Icons.check_rounded : Icons.content_copy_outlined,
        // 颜色随状态变化：未复制用弱化的 onSurfaceVariant（不与正文抢注意力），
        // 已复制用 primary（明确「这次生效了」）。
        color: _copied ? scheme.primary : scheme.onSurfaceVariant,
      ),
      // 已复制时禁用，防重复点击（见类文档）。
      onPressed: _copied ? null : _copy,
      tooltip: label,
    );
  }
}
