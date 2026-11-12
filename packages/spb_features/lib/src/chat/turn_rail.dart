import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 刻度列的常驻宽度。
///
/// ## 为什么是 16 而不是 24（与时间线右侧内边距对齐）
///
/// 时间线的行左边距/右边距都是 `SpbSpacing.pagePadding`（16）。刻度列**叠在
/// 消息流右侧**（不参与时间线的布局，见 [TurnRail] 的说明），宽度取 16 就正好
/// 落在内边距里：既不压正文，也不用为它缩窄整份时间线。再宽就会盖住文字的
/// 最后一个字——那是「加了个导航条，正文被裁了」的观感。
const double kTurnRailWidth = 16;

/// hover 面板的宽度。
///
/// 它与 [kTurnRailLabelMaxChars] 是一对：12px 字号下 24 个汉字 ≈ 288px，扣掉
/// 序号列与内边距后取 264，恰好容纳「截断后的整句 + 一点余量」。改窄了就要
/// 同步调小字符数，否则面板里全部变成 ellipsis，「保留前 N 字符」就名存实亡。
const double kTurnRailPanelWidth = 264;

/// 每格刻度的占位高度（含间隔）。
///
/// 固定步距而不是「按轮次数压缩到刚好铺满」：200 轮的对话若压缩，每格只剩
/// 2px 高的细线，既看不出层次也点不中。固定 7px 时一屏约能显示 80 格，
/// 更多的靠**滚动刻度列本身**（见 [TurnRail] 的交互说明）。
const double kTurnRailTickPitch = 7;

/// 刻度列首尾的留白（让第一格/最后一格不贴边）。
const double kTurnRailListPadding = 8;

/// hover 面板每行的固定高度。
///
/// 固定高度让「打开时把当前轮滚到中间」可以**算**出偏移量（`index × 26`），
/// 不必为每一行登记 GlobalKey 再 `ensureVisible`——后者在面板刚插入的那一帧
/// 拿不到上下文，只能再排一帧，表现为「打开时先闪一下顶部」。
const double kTurnRailPanelRowHeight = 26;

/// 时间线右侧的轮次导航刻度条（竖置「齿轮」）。
///
/// ## 交互（三条，都来自同一个心智模型：目录）
///
/// | 操作 | 结果 |
/// |---|---|
/// | 常驻 | 每轮一根横杠；当前轮那根**更长、更亮**（primary） |
/// | 鼠标悬停 | 左侧浮出面板，逐行显示「序号 + 该轮问题摘要」 |
/// | 点横杠 / 点面板行 | 跳到那一轮（回调 [onJump]）；滚轮可滚刻度列本身 |
///
/// ## 为什么默认只画横杠，而不是常驻摘要列表
///
/// 摘要列表要么占掉正文宽度、要么塞满屏幕，而它 99% 的时间没人看（与 webapp
/// `ChatTurnNav` 把它做成弹出列表的理由相同）。横杠的密度优势才是导航条的价值：
/// 一屏就能看出「这个对话有多少轮、我在哪、后面还有多少」。
///
/// ## 为什么刻度列自己可滚，而不是压缩到铺满
///
/// 压缩到铺满在 200 轮时每格 < 3px：既点不中（触摸目标远小于 44dp），也表达
/// 不出「这一段很长」。固定步距 + 自身滚动保住可点性与可读性；代价是「看不到
/// 全局」，故激活格会自动滚进视野（[_revealActive]）。
///
/// ## 为什么面板浮在正文上，而不是把时间线挤窄
///
/// hover 触发一次布局变化（正文宽度改变 → 整份 Markdown 重排）在远程桌面的
/// 软件光栅下就是一次整窗重绘（§6.74 与 issue #110 是同一类）。
/// 面板用 `Stack` 叠在消息流上方，时间线布局在 hover 前后**逐像素不变**。
///
/// ## 为什么没有动画
///
/// 面板插入/移除不做淡入淡出：整窗 alpha 混合在软件光栅下是本条链路里最贵的
/// 一类操作，而这个面板出现得越「干脆」越像滚动条而非内容。附带好处是
/// `MediaQuery.disableAnimations` 无需特判。
///
/// ## 触屏端
///
/// 没有 hover 就没有面板，但**点横杠仍然可用**（跳转不依赖面板）。窄屏是否
/// 显示由调用方按宽度决定（见 `ConversationPage` 的 `SpbBreakpoints.compact`）：
/// 390dp 的手机上这条 16px 的列会挤压正文，不值得。
class TurnRail extends StatefulWidget {
  const TurnRail({
    super.key,
    required this.entries,
    required this.activeTurnId,
    required this.onJump,
  });

  /// 轮次列表（**旧 → 新**，见 [buildTurnRailEntries]）。
  final List<TurnRailEntry> entries;

  /// 当前激活轮（归一化后的 turn id）；null = 还没有结论（首帧未布局）。
  final String? activeTurnId;

  /// 点了某一格（传归一化后的 turn id）。
  final void Function(String turnId) onJump;

  @override
  State<TurnRail> createState() => _TurnRailState();
}

class _TurnRailState extends State<TurnRail> {
  final _tickController = ScrollController();
  final _panelController = ScrollController();

  /// 指针是否在刻度列 / 面板上（两者共同决定面板是否展开）。
  ///
  /// ## 为什么要两个独立的标志而不是「一个 hovered」
  ///
  /// 指针从刻度列移进面板时必须**不经过**「两个都不在」的中间态，否则面板会在
  /// 鼠标穿越那 0 像素的缝隙时闪一下（真实发生：面板贴着刻度列左缘，移入瞬间
  /// 触发 `onExit` → `setState` → 面板移除 → 指针落在正文上 → 再也回不来）。
  bool _overTicks = false;
  bool _overPanel = false;

  bool get _expanded => _overTicks || _overPanel;

  @override
  void initState() {
    super.initState();
    // 首帧就把激活格滚进视野：长对话的激活轮通常是最新那几轮，不滚的话刻度列
    // 永远停在最早一段，「我在哪」要用户自己去找。
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(TurnRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeTurnId != widget.activeTurnId) _scheduleReveal();
  }

  @override
  void dispose() {
    _tickController.dispose();
    _panelController.dispose();
    super.dispose();
  }

  void _setOver({bool? ticks, bool? panel}) {
    final nextTicks = ticks ?? _overTicks;
    final nextPanel = panel ?? _overPanel;
    if (nextTicks == _overTicks && nextPanel == _overPanel) return;
    final wasExpanded = _expanded;
    setState(() {
      _overTicks = nextTicks;
      _overPanel = nextPanel;
    });
    if (_expanded && !wasExpanded) _scheduleReveal();
  }

  /// 激活格的下标（找不到时为 -1）。
  int get _activeIndex {
    final active = normalizeTurnAnchor(widget.activeTurnId);
    if (active == null) return -1;
    for (var i = 0; i < widget.entries.length; i++) {
      if (widget.entries[i].turnId == active) return i;
    }
    return -1;
  }

  /// 把激活格滚进视野（并尽量居中）。
  ///
  /// ## 为什么排到下一帧
  ///
  /// 面板刚插入的那一帧还未布局，`position.maxScrollExtent` 仍是 0；此时 `jumpTo`
  /// 会被 clamp 到 0，等于「打开就停在顶部」。
  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reveal(_tickController, kTurnRailTickPitch, kTurnRailListPadding);
      _reveal(_panelController, kTurnRailPanelRowHeight, SpbSpacing.xs);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _reveal(ScrollController controller, double rowHeight, double padding) {
    if (!controller.hasClients) return;
    final index = _activeIndex;
    if (index < 0) return;
    final position = controller.position;
    if (!position.hasContentDimensions) return;
    final viewport = position.viewportDimension;
    final target = (padding + index * rowHeight - viewport / 2 + rowHeight / 2)
        .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() < 0.5) return;
    controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      // 面板 + 刻度列的总宽：这个盒子整体叠在时间线之上（见类文档），
      // 未展开时除刻度列外**不接收指针**（`SizedBox` 没有可命中的子节点）。
      width: kTurnRailWidth + kTurnRailPanelWidth,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (_expanded)
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: kTurnRailPanelWidth,
              child: _buildPanel(context),
            ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: kTurnRailWidth,
            child: _buildTicks(context),
          ),
        ],
      ),
    );
  }

  Widget _buildTicks(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeIndex = _activeIndex;
    return MouseRegion(
      onEnter: (_) => _setOver(ticks: true),
      onExit: (_) => _setOver(ticks: false),
      child: ListView.builder(
        key: const ValueKey('turn-rail-ticks'),
        controller: _tickController,
        // 刻度列自己滚（滚轮/触控板），不把滚动链传给时间线：用户在这里滚动
        // 的意图是「翻目录」，而不是「翻正文」。
        primary: false,
        padding: const EdgeInsets.symmetric(vertical: kTurnRailListPadding),
        itemExtent: kTurnRailTickPitch,
        itemCount: widget.entries.length,
        itemBuilder: (context, i) {
          final entry = widget.entries[i];
          final isActive = i == activeIndex;
          return GestureDetector(
            key: ValueKey('turn-rail-tick-${entry.turnId}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onJump(entry.turnId),
            child: Align(
              alignment: Alignment.centerRight,
              // 横杠：激活的那根更长更亮。长度差而非只换颜色，是因为色差在
              // 高对比主题 / 色弱用户那里可能不可辨，而长度差永远可辨。
              child: Container(
                margin: const EdgeInsets.only(right: SpbSpacing.xxs),
                width: isActive ? 13 : 8,
                height: isActive ? 4 : 2,
                decoration: BoxDecoration(
                  color: isActive ? scheme.primary : scheme.outlineVariant,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeIndex = _activeIndex;
    return MouseRegion(
      onEnter: (_) => _setOver(panel: true),
      onExit: (_) => _setOver(panel: false),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SpbSpacing.sm,
          kTurnRailListPadding,
          SpbSpacing.sm,
          kTurnRailListPadding,
        ),
        child: Material(
          key: const ValueKey('turn-rail-panel'),
          elevation: 6,
          color: scheme.surfaceContainerHigh,
          borderRadius: SpbRadius.cardAll,
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(
            controller: _panelController,
            primary: false,
            padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xs),
            itemExtent: kTurnRailPanelRowHeight,
            itemCount: widget.entries.length,
            itemBuilder: (context, i) {
              final entry = widget.entries[i];
              final isActive = i == activeIndex;
              return InkWell(
                key: ValueKey('turn-rail-row-${entry.turnId}'),
                onTap: () => widget.onJump(entry.turnId),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SpbSpacing.sm,
                  ),
                  color: isActive ? scheme.primaryContainer : null,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: Text(
                          '${entry.index}',
                          textAlign: TextAlign.right,
                          style: SpbType.listMeta(theme.textTheme)?.copyWith(
                            color: isActive
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: SpbSpacing.sm),
                      Expanded(
                        child: Text(
                          entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isActive
                                ? scheme.onPrimaryContainer
                                : scheme.onSurface,
                            fontWeight: isActive ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
