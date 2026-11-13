import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

/// 横杠的静止尺寸（激活 / 非激活）。
const double kTurnRailTickWidthIdle = 8;
const double kTurnRailTickWidthActive = 13;

/// 指针在刻度条上时非激活横杠长到的宽度。
///
/// 这是「刻度条是活的」的唯一静态证据：鼠标靠近时整列**填满**一点，
/// 离开时收回。它同时解决了「16px 的细线看不出可点」的问题——不靠 tooltip、
/// 不靠说明文字。
const double kTurnRailTickWidthHover = 11;

/// 面板**入场**的时长。
///
/// ## 参数出处（不是拍脑袋定的）
///
/// | 依据 | 值 |
/// |---|---|
/// | Material 3 duration token `md.sys.motion.duration.short3` | 150ms（「小而实用的过渡」） |
/// | Atlassian Design / motion | 下拉/浮层入场 150ms |
/// | Carmen Ansio 动效令牌量表 | `--duration-fast` 150ms = hover / click / **tooltip** |
///
/// 150ms 正好是 M3 `short3`，也等于本项目 `SpbDuration.fast`（Flutter SDK 里就是
/// `Durations.short3`）。面板每次划过右侧都会出现（高频），M3 与 Atlassian 都明确
/// 「一天触发几十次的动效压在 150ms 以内」。
///
/// 附带的好处是**帧数少**：远程桌面的软件光栅下（§6.74 / issue #110）每帧都要
/// 整窗 present，150ms ≈ 9 帧；300ms 就要 18 帧。
const Duration kTurnRailMotion = SpbDuration.fast;

/// 面板**收起**的时长。
///
/// ## 为什么是入场的 53%
///
/// Material 3：「退出过渡应比进入更快」，且退出用 `accelerate`（加速离开），进入用
/// `decelerate`（减速停稳）。常见做法是把退出压到入场的 **50~60%** ——
/// `SpbDuration.instant`（80ms）÷ 150ms = 53%，落在区间正中；换成 M3 的
/// `short2`(100ms) 是 67%，会显得「关得比开得还慢」。
///
/// 这也解释了两个时长为什么共用 `SpbDuration` 的两档而不是各写一个魔数。
const Duration kTurnRailFadeOut = SpbDuration.instant;

/// 横杠伸缩（悬停变宽 / 当前轮换格）的时长。
///
/// ## 为什么比面板更快（80ms）
///
/// 它是**悬停态反馈**，不是「元素进入屏幕」：Atlassian 的规范把 hover / press 归为
/// 50–150ms 的「interactions」，示例里列表行 hover 是 50ms；M3 的对应档位是
/// `short1`(50) / `short2`(100)。横杠变宽只有 3px 的位移量，若与面板同为 150ms，
/// 会读成「两件事在同时慢慢做」；80ms 让它先到位，面板随后浮出，因果顺序更清楚。
const Duration kTurnRailTickMotion = SpbDuration.instant;

/// 时间线右侧的轮次导航刻度条（竖置「齿轮」）。
///
/// ## 交互（三条，都来自同一个心智模型：目录）
///
/// | 操作 | 结果 |
/// |---|---|
/// | 常驻 | 每轮一根横杠；当前轮那根**更长、更亮**（primary） |
/// | 鼠标悬停 | 横杠微微一长（「这列是活的」），左侧浮出面板显示「序号 + 该轮问题摘要」 |
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
/// 全局」，故激活格会自动滚进视野（[_TurnRailState._reveal]）。
///
/// ## 为什么面板浮在正文上，而不是把时间线挤窄
///
/// hover 触发一次布局变化（正文宽度改变 → 整份 Markdown 重排）在远程桌面的
/// 软件光栅下就是一次整窗重绘（§6.74 与 issue #110 是同一类）。
/// 面板用 `Stack` 叠在消息流上方，时间线布局在 hover 前后**逐像素不变**。
///
/// ## 动效：只有三处，都是「状态变了才有」，且全部可关
///
/// 初版是零动画（理由是软件光栅下 alpha 混合太贵）。这个结论现在收窄为：
/// **连续/整窗**的动效仍然不做（页面过渡、`allowSnapshotting`、常驻发光），
/// 但**事件驱动、≤150ms、局部脏矩形**的微过渡代价可以忽略——它们每帧只重绘
/// 264×300 的面板或 16×7 的格子，而不是整窗 Markdown。故：
///
/// | 动效 | 触发 | 手段 | 时长 | 曲线 |
/// |---|---|---|---|---|
/// | 面板淡入 + 从右滑出 12px | 指针进入刻度列 | `FadeTransition` + `SlideTransition`（纯合成） | [kTurnRailMotion]（150ms = M3 `short3`） | `Easing.standardDecelerate` |
/// | 面板淡出（反向收回） | 指针离开 | 同一 controller 反向 | [kTurnRailFadeOut]（80ms = 入场的 53%） | `Easing.standardAccelerate` |
/// | 横杠伸缩 / 当前轮换格 | 悬停、激活轮变化 | `AnimatedContainer`（只重排 16×7 的格子） | [kTurnRailTickMotion]（80ms，hover 态要比入场更快） | `Easing.standardDecelerate` |
///
/// 三条约束：
///
/// 1. **不引入 `AnimatedSize` / 尺寸过渡**：面板宽度恒定 264（浮层不挤正文），
///    高度直接撑满可用高度；尺寸动画才是会带动时间线重排的那一类；
/// 2. **不做循环动画**（呼吸、脉冲）：它会让远程桌面**持续**整窗 present，
///    正是 issue #110 的成因；
/// 3. `MediaQuery.disableAnimations`（系统「减少动效」）时全部时长为 0，
///    此时面板收起后**立即**从树上移除（不等 `onEnd`）。
///
/// ## 触屏端（平板 / 折叠屏展开 / 横屏手机，宽度 ≥ 720）
///
/// 没有 hover 就没有面板，而**点横杠仍然可用**（跳转不依赖面板）。但「只能盲点」
/// 不是合格的导航：用户看不到各轮摘要，也数不出共有几轮。故调用方可以传
/// [onOpenList]：**触摸**点刻度 → 打开整屏列表（`showTurnListSheet`，48dp 行高），
/// 鼠标点刻度 → 维持直跳。判据用 `TapDownDetails.kind`（输入设备自带），不做
/// 平台嗅探——同一台设备接上鼠标时行为会自动切回桌面语义。
///
/// 窄屏（< 720）由调用方决定不显示（见 `ConversationPage`）：390dp 的手机上这条
/// 16px 的列会挤压正文，且与系统边缘返回手势抢；那里的入口是「更多」菜单里的
/// 轮次列表。
class TurnRail extends StatefulWidget {
  const TurnRail({
    super.key,
    required this.entries,
    required this.activeTurnId,
    required this.onJump,
    this.onOpenList,
  });

  /// 轮次列表（**旧 → 新**，见 [buildTurnRailEntries]）。
  final List<TurnRailEntry> entries;

  /// 当前激活轮（归一化后的 turn id）；null = 还没有结论（首帧未布局）。
  final String? activeTurnId;

  /// 点了某一格（传归一化后的 turn id）。
  final void Function(String turnId) onJump;

  /// 触屏点刻度时改为打开列表（见类文档「触屏端」）。null = 触摸也直跳。
  final VoidCallback? onOpenList;

  @override
  State<TurnRail> createState() => _TurnRailState();
}

class _TurnRailState extends State<TurnRail>
    with SingleTickerProviderStateMixin {
  final _tickController = ScrollController();
  final _panelController = ScrollController();

  /// 面板的出现/消失（0 = 完全收起，1 = 完全展开）。
  ///
  /// ## 为什么用显式 controller 而不是 `AnimatedOpacity`
  ///
  /// `ImplicitlyAnimatedWidget` 在**首次挂载**时直接取目标值，不播动画。而面板
  /// 是「指针进来才挂上」的（收起时不在树上，否则它会（虽然不可见）占着那 264px
  /// 的命中区），于是 `AnimatedOpacity` 的入场永远是闪现——看着像没做动效。
  /// 显式 controller 从 0 开始 `forward()`，入场就真的有中间帧。
  late final AnimationController _panelAnim;
  late final Animation<double> _panelOpacity;
  late final Animation<Offset> _panelSlide;

  /// 指针是否在刻度列 / 面板上（两者共同决定面板是否展开）。
  ///
  /// ## 为什么要两个独立的标志而不是「一个 hovered」
  ///
  /// 指针从刻度列移进面板时必须**不经过**「两个都不在」的中间态，否则面板会在
  /// 鼠标穿越那 0 像素的缝隙时闪一下（真实发生：面板贴着刻度列左缘，移入瞬间
  /// 触发 `onExit` → `setState` → 面板移除 → 指针落在正文上 → 再也回不来）。
  bool _overTicks = false;
  bool _overPanel = false;

  /// 面板是否还挂在树上。
  ///
  /// 与 [_expanded] 分离是为了让**淡出**有机会播完：指针离开时立刻开始反向
  /// 动画，但要留到 `dismissed` 状态再移除，否则永远看不到出场动画（等于没有
  /// 动效，只是延迟出现）。
  bool _panelMounted = false;

  /// 最近一次按下的设备类型（见 [TurnRail.onOpenList]）。
  ///
  /// 只用于**这一次**点按的语义判定，不缓存成「本机是触屏」之类的长期结论：
  /// 判定依据应当是当前这次输入，而不是设备能力（后者没有可靠的跨平台 API）。
  PointerDeviceKind? _lastTapKind;

  bool get _expanded => _overTicks || _overPanel;

  @override
  void initState() {
    super.initState();
    _panelAnim = AnimationController(
      vsync: this,
      duration: kTurnRailMotion,
      reverseDuration: kTurnRailFadeOut,
    )..addStatusListener(_handlePanelStatus);
    // 进入用 `decelerate`（减速停稳），退出用 `accelerate`（加速离开）——这是
    // M3 的 easing 令牌 `Easing.standardDecelerate` / `Easing.standardAccelerate`
    // （Flutter SDK 里就在 `Easing` 类里，值即 specs 的 Cubic(0,0,0,1) /
    // Cubic(0.3,0,1,1)）。不用 `Curves.easeOutCubic` 是因为它不是 M3 令牌，
    // 停在 0.355 而非 1.0，尾段会留一点「没走完」的迟疑感。
    final curved = CurvedAnimation(
      parent: _panelAnim,
      curve: Easing.standardDecelerate,
      reverseCurve: Easing.standardAccelerate,
    );
    _panelOpacity = curved;
    _panelSlide = Tween<Offset>(
      // 从刻度列那一侧滑出 `SpbSpacing.sm`（12px）：位移比缩放更像浮层，且不改变
      // 命中区域大小（缩放会）。12px 也够小——M3 说「在屏幕内出现的容器」用
      // 淡入 + 从 95% 轻微放大，我们把「轻微」折算成 ≈ 一个间距令牌的位移。
      begin: const Offset(SpbSpacing.sm / kTurnRailPanelWidth, 0),
      end: Offset.zero,
    ).animate(curved);
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
    _panelAnim.dispose();
    _tickController.dispose();
    _panelController.dispose();
    super.dispose();
  }

  /// 动效时长（系统开了「减少动效」时为 0）。
  Duration _motion(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

  /// 面板淡出播完 → 真正从树上移除。
  ///
  /// 重入期间（用户又回来了）状态不是 `dismissed`，这里什么都不做。
  void _handlePanelStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    if (!mounted || _expanded || !_panelMounted) return;
    setState(() => _panelMounted = false);
  }

  /// 让 controller 追上「当前要不要展开」。
  void _syncPanelAnimation() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _panelAnim.duration = reduceMotion ? Duration.zero : kTurnRailMotion;
    _panelAnim.reverseDuration = reduceMotion
        ? Duration.zero
        : kTurnRailFadeOut;
    if (_expanded) {
      _panelAnim.forward();
    } else {
      _panelAnim.reverse();
    }
  }

  void _setOver({bool? ticks, bool? panel}) {
    final nextTicks = ticks ?? _overTicks;
    final nextPanel = panel ?? _overPanel;
    if (nextTicks == _overTicks && nextPanel == _overPanel) return;
    final wasExpanded = _expanded;
    setState(() {
      _overTicks = nextTicks;
      _overPanel = nextPanel;
      // 展开时先把面板挂上（controller 还是 0），让淡入有起点。
      if (_expanded && !wasExpanded) _panelMounted = true;
    });
    if (_expanded != wasExpanded) _syncPanelAnimation();
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
  ///
  /// ## 为什么是 `jumpTo` 而不是动画滚动
  ///
  /// 面板是「随着指针出现」的，里面的列表跟着动画滚会与淡入叠成两段运动，
  /// 读起来像页面在晃；而且滚动动画是连续帧，恰恰是远程桌面最贵的一类。
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

  /// 刻度被点：触摸改为打开列表，鼠标直跳（见 [TurnRail.onOpenList]）。
  void _handleTickTap(TurnRailEntry entry) {
    final onOpenList = widget.onOpenList;
    // null（还没点过任何一格）按非触摸处理：鼠标用户点第一下就该直跳。
    final isTouch = switch (_lastTapKind) {
      PointerDeviceKind.touch ||
      PointerDeviceKind.stylus ||
      PointerDeviceKind.invertedStylus => true,
      _ => false,
    };
    if (isTouch && onOpenList != null) {
      onOpenList();
      return;
    }
    widget.onJump(entry.turnId);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 减少动效时不等淡出回调：收起就立刻摘掉（那 80ms 的不可见命中区没有意义）。
    final showPanel = _panelMounted && (_expanded || !reduceMotion);
    return SizedBox(
      // 面板 + 刻度列的总宽：这个盒子整体叠在时间线之上（见类文档），
      // 未展开时除刻度列外**不接收指针**（`SizedBox` 没有可命中的子节点）。
      width: kTurnRailWidth + kTurnRailPanelWidth,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          if (showPanel)
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
    final motion = _motion(context, kTurnRailTickMotion);
    // 指针在刻度条上（刻度列或面板）时整列「填满」一点：不说话的「可点」提示。
    final boost = _expanded;
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
            // `onTapDown` 自带输入设备类型：这是判「该直跳还是该开列表」的
            // 唯一可靠依据（见 [_handleTickTap]）。
            onTapDown: (details) => _lastTapKind = details.kind,
            onTap: () => _handleTickTap(entry),
            child: Align(
              alignment: Alignment.centerRight,
              // 横杠：激活的那根更长更亮。长度差而非只换颜色，是因为色差在
              // 高对比主题 / 色弱用户那里可能不可辨，而长度差永远可辨。
              //
              // 尺寸变化只波及这个 16×7 的格子（`itemExtent` 固定，列表不重排）。
              child: AnimatedContainer(
                duration: motion,
                curve: Easing.standardDecelerate,
                margin: const EdgeInsets.only(right: SpbSpacing.xxs),
                width: isActive
                    ? kTurnRailTickWidthActive
                    : (boost
                          ? kTurnRailTickWidthHover
                          : kTurnRailTickWidthIdle),
                height: isActive ? 4 : (boost ? 2.5 : 2),
                decoration: BoxDecoration(
                  color: isActive
                      ? scheme.primary
                      : (boost
                            ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
                            : scheme.outlineVariant),
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 面板标题：告诉用户「这是第几轮 / 共几轮」。
  ///
  /// 面板只有 264px，标题挤占的是一行的空间，但它换掉了另一种更贵的做法：
  /// 用户点开列表后仍要靠数行数来定位自己（刻度条上又没有数字）。
  String get _panelTitle {
    final total = widget.entries.length;
    final index = _activeIndex;
    return index < 0 ? '共 $total 轮' : '第 ${index + 1} / $total 轮';
  }

  Widget _buildPanel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeIndex = _activeIndex;
    final fadeIn = _motion(context, kTurnRailMotion);
    return MouseRegion(
      onEnter: (_) => _setOver(panel: true),
      onExit: (_) => _setOver(panel: false),
      child: FadeTransition(
        opacity: _panelOpacity,
        child: SlideTransition(
          position: _panelSlide,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              SpbSpacing.sm,
              kTurnRailListPadding,
              SpbSpacing.sm,
              kTurnRailListPadding,
            ),
            // 收起过程中不要拦住点击：此时面板已经不可见，但还在树上 80ms。
            child: IgnorePointer(
              ignoring: !_expanded,
              child: Material(
                key: const ValueKey('turn-rail-panel'),
                elevation: 6,
                color: scheme.surfaceContainerHigh,
                borderRadius: SpbRadius.cardAll,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        SpbSpacing.sm + 3,
                        SpbSpacing.xs,
                        SpbSpacing.sm,
                        SpbSpacing.xxs,
                      ),
                      child: Text(
                        _panelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SpbType.listMeta(theme.textTheme)
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Divider(height: 1, color: scheme.outlineVariant),
                    Expanded(
                      child: ListView.builder(
                        controller: _panelController,
                        primary: false,
                        padding: const EdgeInsets.symmetric(
                          vertical: SpbSpacing.xxs,
                        ),
                        itemExtent: kTurnRailPanelRowHeight,
                        itemCount: widget.entries.length,
                        itemBuilder: (context, i) => _buildRow(
                          context,
                          theme,
                          scheme,
                          widget.entries[i],
                          isActive: i == activeIndex,
                          duration: fadeIn,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    TurnRailEntry entry, {
    required bool isActive,
    required Duration duration,
  }) {
    return InkWell(
      key: ValueKey('turn-rail-row-${entry.turnId}'),
      onTap: () => widget.onJump(entry.turnId),
      hoverColor: scheme.primary.withValues(alpha: 0.07),
      child: AnimatedContainer(
        duration: duration,
        curve: Easing.standardDecelerate,
        // 当前轮：底色 + 左侧 3px 主色标记。两层都要，因为底色在浅色主题里
        // 与 hover 色接近，而竖标记是「我在这一行」的确定性信号。
        color: isActive ? scheme.primaryContainer : null,
        child: Row(
          children: [
            AnimatedContainer(
              duration: duration,
              curve: Easing.standardDecelerate,
              width: 3,
              height: kTurnRailPanelRowHeight,
              color: isActive
                  ? scheme.primary
                  : scheme.primary.withValues(alpha: 0),
            ),
            const SizedBox(width: SpbSpacing.sm),
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
            const SizedBox(width: SpbSpacing.xs),
          ],
        ),
      ),
    );
  }
}
