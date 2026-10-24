import 'package:flutter/material.dart';

import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

import 'perf_probe.dart';

/// Agent 回复气泡（左对齐），用 [GptMarkdown] 渲染 Markdown。
///
/// ## 流式
///
/// [isStreaming] 为 true 时启用逐字 reveal 动画（`fade`），由 `gpt_markdown`
/// 内部驱动：settled 前缀缓存、只重建变化中的尾部，故长回复的单帧成本不随
/// 回复增长。`isStreaming` 置 false 时残余文本 fast-forward 收尾。
///
/// reveal 动画本身就是「仍在生成」的视觉信号，取代了旧版手工拼接的闪烁光标
/// （`SelectableText` 无法在文本流中间内联 widget，`GptMarkdown` 同理；与其
/// 把光标单独摆一行，不如交给库内置的 reveal）。
///
/// ## 选择
///
/// 完成后（`isStreaming == false`）用 [SelectionArea] 包裹以支持选择；流式中
/// 尾部每帧重建、选择锚点不稳，故**不**包 [SelectionArea]。这与旧版「流式
/// 不可选、完成后可选」的取舍一致。
///
/// ## 数学 / 链接
///
/// 默认 `$...$` **不**当 LaTeX（`useDollarSignsForLatex` 留 false）——agent
/// 回复里 `$HOME` 这类 shell 变量远比公式常见，误判代价更高。`\(...\)` /
/// `\[...\]` 仍按数学渲染（解析失败自动回退为原文本）。
///
/// 链接默认**不**打开：打开 URL 属平台 IO，应由 app 层注入 [onLinkTap]
/// （与 [onDownloadAgentFile] 同一原则：页面只收集意图）。为 null 时链接
/// 照常渲染样式，但不响应点击。
///
/// ## 常驻（keep-alive）——为什么是**有界**的
///
/// [GptMarkdown] 的解析是**最贵的一步**：实测（本机 2026-10，debug）4 段
/// 580 字符的冷重建 **68.0 ms**、20 段 2940 字符 **202.5 ms**、60 段 8900 字符
/// **441.6 ms**；而 Element 复用（暖重建）同内容只需 **16.9 / 30.3 ms**。
/// 冷/暖差 **4–15×**。
///
/// 而 `ListView.builder` 的子项一旦滚出 `cacheExtent` 就被 **dispose**——
/// 缓存（`gpt_markdown` 的 `_settled` 前缀）也跟着没了。长对话上下滚动时，
/// 每次滚回顶部都要把可见的几条长回复重新解析一遍，那就是「滚动不顺」的
/// 主要来源。
///
/// ## ⚠️ 为什么不能无界常驻
///
/// `AutomaticKeepAliveClientMixin` 让子项**留在树上**，而
/// `RenderSliverMultiBoxAdaptor` 每帧仍要**布局**它们（keep-alive 的语义是
/// 「不回收」，不是「不布局」）。2000 条历史全常驻会把每帧布局成本变成
/// O(历史长度)，比它要解决的「重解析」还贵。
///
/// 故常驻是**页面决定的有界策略**（见 `ConversationPage` 的
/// `_keepAliveMinChars` / `_keepAliveWindow`）：只给「够长、值得缓存」且
/// 「最近的若干个」气泡开。本组件只提供一个开关，不做任何策略判断。
class AssistantMessageBubble extends StatefulWidget {
  const AssistantMessageBubble({
    super.key,
    required this.text,
    this.isStreaming = false,
    this.onLinkTap,
    this.keepAlive = false,
  });

  final String text;

  /// 该段是否仍在接收增量。true 时启用 reveal 动画。
  final bool isStreaming;

  /// 链接点击回调。null 时链接不响应点击（仅样式）。
  ///
  /// 签名与 `GptMarkdown.onLinkTap` 一致：`(url, title)`。
  final void Function(String url, String title)? onLinkTap;

  /// 是否滚出视口后仍保留 Element（从而保留 Markdown 解析缓存）。
  ///
  /// 默认 **false**：大多数气泡不值得常驻（短回复解析很快，且常驻要付
  /// 每帧布局成本）。由调用方按「长度阈值 + 最近窗口」决定，见类文档。
  final bool keepAlive;

  @override
  State<AssistantMessageBubble> createState() => _AssistantMessageBubbleState();
}

class _AssistantMessageBubbleState extends State<AssistantMessageBubble>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(AssistantMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ## 为什么必须显式调 `updateKeepAlive()`
    //
    // `AutomaticKeepAliveClientMixin` 的 `build` **只会申请、永不释放**：
    //
    // ```dart
    // if (wantKeepAlive && _keepAliveHandle == null) _ensureKeepAlive();
    // ```
    //
    // 而唯一会释放的是 `updateKeepAlive()`（wantKeepAlive 转 false 时）与
    // `deactivate()`。后者的前提是「被移出树」——可一旦 keep-alive 生效，它就
    // 永远不会被移出树。
    //
    // 于是窗口往前滑（新消息到来使尾部窗口移动）后，曾经进过窗口的气泡会
    // **永久常驻**，常驻数量随对话长度无界增长——正是「有界」要防的那件事。
    // 实测（2026-10，本机）：20 条长回复滚到顶部时 20 个全部留在树上（应为
    // 12 + 视口内）。
    //
    // ⚠️ 只比 `keepAlive`：其余字段变化不影响 keep-alive 状态。
    if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 要求：必须在 build 里调用 super，
    // 否则 keep-alive 不生效（不会报错，只是默默失效）。
    super.build(context);
    PerfProbe.assistantBubbleBuilds++;

    final text = widget.text;
    final isStreaming = widget.isStreaming;
    final onLinkTap = widget.onLinkTap;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final dir = Directionality.of(context);

    // 空文本 + 流式中：显示「正在生成」占位，避免出现一个 0 高度气泡
    // （用户会以为卡住）。
    if (text.isEmpty && isStreaming) {
      return Padding(
        padding: SpbSpacing.bubblePadding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: SpbSpacing.md,
              height: SpbSpacing.md,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Text('正在生成…', style: textTheme.bodySmall),
          ],
        ),
      );
    }

    final md = GptMarkdown(
      text,
      // 流式逐字淡入；非流式时 reveal 引擎直接 snap 到末尾，无动画、无 ticker。
      animation: GptMarkdownAnimation.fade,
      // 块级元素（表格 / 代码围栏 / 公式）淡入。**不用** growIn——它会改变
      // 布局高度，与 `conversation_page` 的「跟随底部」逻辑打架（见其
      // `_followBottom` 注释：流式期间 maxScrollExtent 惰性估算，块高度
      // 抖动会让跟随断续）。
      blockAnimation: GptMarkdownBlockAnimation.fadeIn,
      isStreaming: isStreaming,
      // 桌面端更快收尾：reveal 不应明显落后于 token 流。引擎在落后超过
      // ~0.4s 时会自动提速追赶，这里只是抬高基线。
      charactersPerSecond: 600,
      textDirection: dir,
      style: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      styleSheet: _styleSheet(scheme),
      onLinkTap: onLinkTap == null
          ? null
          : (url, title) => onLinkTap(url, title),
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: SpbSpacing.bubblePadding,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: SpbRadius.bubbleAll,
            ),
            child: isStreaming ? md : SelectionArea(child: md),
          ),
          // 整条正文的复制入口。
          //
          // ## 为什么**仅**非流式显示
          //
          // 流式中 [text] 每帧都在变，此时复制拿到的是半截内容：用户以为复制了
          // 完整回复，粘出来却是残句。宁可此时没有入口——`SelectionArea` 在流式中
          // 也刻意不包（同一取舍，见类文档）。
          //
          // ## 为什么在气泡**下方**而不是内部
          //
          // 助手气泡占满宽度且内含 Markdown（可能有表格/代码块），把按钮放进
          // 气泡内会与内容挤在一起，也会被 `SelectionArea` 圈进去（选中文本时
          // 连按钮一起选）。放外侧下方，左对齐，视觉上仍归属于这条消息。
          if (!isStreaming) CopyIconButton(text: text),
        ],
      ),
    );
  }

  /// 用本仓库设计令牌微调 Markdown 各元素的呈现。
  ///
  /// 只覆盖**外观**（圆角 / 间距 / 颜色取自 ColorScheme），结构交给库默认。
  /// 字段留空即回退到库默认值，故追加样式不会改动未提及的元素。
  static GptMarkdownStyleSheet _styleSheet(ColorScheme scheme) =>
      GptMarkdownStyleSheet(
        // 代码块：比气泡底色再沉一档，并收敛圆角到设计令牌。
        codeBlock: CodeBlockStyle(
          backgroundColor: scheme.surfaceContainerHigh,
          borderColor: scheme.outlineVariant,
          borderRadius: const Radius.circular(SpbRadius.sm),
        ),
        // 行内 `code`：与代码块同色系，保持视觉一致。
        inlineCode: InlineCodeStyle(
          backgroundColor: scheme.surfaceContainerHigh,
          borderColor: scheme.outlineVariant,
          borderRadius: const Radius.circular(SpbRadius.xs),
        ),
        // 引用条：用 outline 而非默认的 onSurfaceVariant，与卡片边框同语义。
        blockQuote: BlockQuoteStyle(
          barColor: scheme.outline,
          backgroundColor: scheme.surfaceContainerHigh,
        ),
        // 表格：单元格内边距与卡片对齐。
        table: TableStyle(
          borderColor: scheme.outlineVariant,
          cellPadding: const EdgeInsets.symmetric(
            horizontal: SpbSpacing.sm,
            vertical: SpbSpacing.xs,
          ),
          headerBackground: scheme.surfaceContainerHigh,
        ),
        // 链接：用 primary 色显式标出（默认取 theme.linkColor，桌面端未配置）。
        link: LinkStyle(color: scheme.primary),
      );
}
