import 'package:flutter/material.dart';

import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

import 'markdown_image.dart';
import 'perf_probe.dart';

/// Agent 回复气泡（左对齐），用 [GptMarkdown] 渲染 Markdown。
///
/// ## 流式
///
/// [isStreaming] 为 true 时启用逐字 reveal 动画（`fade`），由 `gpt_markdown`
/// 内部驱动：settled 前缀缓存减少重复解析；已挂载长正文仍需布局，不能视为
/// 常量成本。`isStreaming` 置 false 时残余文本 fast-forward 收尾。
///
/// reveal 动画本身就是「仍在生成」的视觉信号，取代了旧版手工拼接的闪烁光标
/// （`SelectableText` 无法在文本流中间内联 widget，`GptMarkdown` 同理；与其
/// 把光标单独摆一行，不如交给库内置的 reveal）。
///
/// ## 选择
///
/// 始终保留 [SelectionArea] 与 [SelectionContainer] 的父链，只在完成后
/// 启用选择。流式中禁选以避免锚点漂移；结束时不卸载 Markdown 解析器。
///
/// ## 数学 / 链接
///
/// 默认 `$...$` **不**当 LaTeX（`useDollarSignsForLatex` 留 false）——agent
/// 回复里 `$HOME` 这类 shell 变量远比公式常见，误判代价更高。`\(...\)` /
/// `\[...\]` 仍按数学渲染（解析失败自动回退为原文本）。
///
/// ## 图片
///
/// Markdown 里的图片走 [markdownImageBuilder]（docs/memory-audit.md G10）：
/// 插件的默认实现不传 `cacheWidth`，一张 4000×3000 的截图就按原图分辨率
/// 解码 ≈ 48MB 位图进全局 imageCache，而它在气泡里最多占 1024dp 宽。
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
/// keep-alive 桶中的子项不参与每帧布局/绘制，但其 Element、RenderObject 与
/// 解析结果仍占内存。2000 条历史全常驻会保留 2000 份子树与解析缓存。
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
  /// 默认 **false**：短回复解析很快，不值得付出子树常驻内存。
  /// 由调用方按「长度阈值 + 最近窗口」决定，见类文档。
  final bool keepAlive;

  @override
  State<AssistantMessageBubble> createState() => _AssistantMessageBubbleState();
}

class _AssistantMessageBubbleState extends State<AssistantMessageBubble>
    with AutomaticKeepAliveClientMixin {
  final _selectionDelegate = StaticSelectionContainerDelegate();
  final _selectionAreaKey = GlobalKey<SelectionAreaState>();

  // Markdown 缓存的 span 不随回调 identity 失效；稳定入口须读取当前 widget，
  // 否则切换回调或从 null 启用链接后仍会执行旧闭包。
  void _onLinkTap(String url, String title) =>
      widget.onLinkTap?.call(url, title);

  @override
  void dispose() {
    _selectionDelegate.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(AssistantMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isStreaming && widget.isStreaming) {
      // 超时恢复等路径会重新进入流式。先撤掉选区/手柄，再禁用容器，
      // 否则上层仍把手柄发给已 disabled 的 SelectionContainer。
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    }
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
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final dir = Directionality.of(context);

    // 等待反馈由轮次状态栏统一承担，空正文不再生成第二个 loading 气泡。
    if (text.isEmpty && isStreaming) return const SizedBox.shrink();

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
      style: SpbType.body(textTheme)?.copyWith(color: scheme.onSurface),
      styleSheet: _styleSheet(scheme),
      // 图片解码降采样（docs/memory-audit.md G10）。不传时插件用
      // `Image(image: NetworkImage(url))`——无 ResizeImage，按原图分辨率解码。
      imageBuilder: markdownImageBuilder,
      onLinkTap: _onLinkTap,
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
            child: SelectionArea(
              key: _selectionAreaKey,
              child: Builder(
                builder: (context) => isStreaming
                    ? SelectionContainer.disabled(child: md)
                    : SelectionContainer(
                        // disabled → enabled 时必须显式传入上层 registrar；
                        // 此次是 widget 更新，未必触发 didChangeDependencies。
                        registrar: SelectionContainer.maybeOf(context),
                        delegate: _selectionDelegate,
                        child: md,
                      ),
              ),
            ),
          ),
          // 整条正文的复制入口。
          //
          // ## 为什么**仅**非流式显示
          //
          // 流式中 [text] 每帧都在变，此时复制拿到的是半截内容：用户以为复制了
          // 完整回复，粘出来却是残句。因此与流式禁选一起，仅在完成后启用。
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
