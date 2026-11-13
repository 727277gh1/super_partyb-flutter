import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 轮次列表每行的固定高度（触屏目标）。
///
/// ## 为什么是 48 而不是 26（`kTurnRailPanelRowHeight`）
///
/// 刻度条的 hover 面板是**鼠标**用的，26px 足够精确拾取；而这里每一行都要
/// **手指**点，Material 的最小可点区域是 48×48dp（`kMinInteractiveDimension`）。
/// 两者共用 26 会让移动端每一行都点不准，且点错时会跳到隔壁轮次。
const double kTurnListRowHeight = 48;

/// 弹层最大高度占屏幕的比例。
///
/// 取 0.6 而不是铺满：铺满会遮住正文，用户失去「我在哪个对话、这段是什么」的
/// 上下文；0.6 时下方仍露出对话，滑动关闭手势也更好做（`showDragHandle`）。
const double kTurnListMaxHeightFactor = 0.6;

/// 打开轮次列表弹层（触屏 / 窄屏用的「刻度条等价物」，§6.94）。
///
/// 返回被选中的 `turnId`（关闭 = null），跳转由调用方决定——弹层只管「选哪一轮」，
/// 这样它能与刻度条共用同一套锚点状态机（`_jumpToTurn`），不必各自实现一遍。
///
/// ## 为什么触屏/窄屏给的是列表，而不是把刻度条调窄
///
/// 三条硬约束（§6.94「移动端形态」）：
///
/// 1. 刻度列的步距是 7px——**手指点不中**；撑到 48dp 高，40 轮要 1920dp；
/// 2. 刻度条的价值一半在 hover 预览（悬停读摘要），触屏没有 hover；
/// 3. 手机可视宽度 360–430dp，常驻 16px 的列就等于吃掉 4% 宽度，还会与
///    Android / iOS 的左右边缘返回手势抢。
///
/// 列表用 [ListView.builder] 固定行高、保留同一个「序号 + 摘要 + 当前轮高亮」
/// 口径（数据就是刻度条那份 [TurnRailEntry]，口径不会漂）。
Future<String?> showTurnListSheet(
  BuildContext context, {
  required List<TurnRailEntry> entries,
  String? activeTurnId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _TurnListSheet(entries: entries, activeTurnId: activeTurnId),
  );
}

class _TurnListSheet extends StatefulWidget {
  const _TurnListSheet({required this.entries, required this.activeTurnId});

  final List<TurnRailEntry> entries;
  final String? activeTurnId;

  @override
  State<_TurnListSheet> createState() => _TurnListSheetState();
}

class _TurnListSheetState extends State<_TurnListSheet> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    // 打开时把当前轮滚进视野：长对话（几十轮）从顶部开始，用户还得自己滑到
    // 自己所在的位置。行高固定，故偏移量可以算出来。
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealActive());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _activeIndex {
    final active = normalizeTurnAnchor(widget.activeTurnId);
    if (active == null) return -1;
    for (var i = 0; i < widget.entries.length; i++) {
      if (widget.entries[i].turnId == active) return i;
    }
    return -1;
  }

  void _revealActive() {
    if (!mounted || !_controller.hasClients) return;
    final index = _activeIndex;
    if (index < 0) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final target =
        (index * kTurnListRowHeight -
                position.viewportDimension / 2 +
                kTurnListRowHeight / 2)
            .clamp(0.0, position.maxScrollExtent);
    if ((position.pixels - target).abs() < 0.5) return;
    _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeIndex = _activeIndex;
    final maxHeight =
        MediaQuery.sizeOf(context).height * kTurnListMaxHeightFactor;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          key: const ValueKey('turn-list-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpbSpacing.lg,
                SpbSpacing.xs,
                SpbSpacing.lg,
                SpbSpacing.sm,
              ),
              child: Text(
                '本对话共 ${widget.entries.length} 轮',
                style: SpbType.listMeta(theme.textTheme)
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            Flexible(
              child: ListView.builder(
                key: const ValueKey('turn-list-rows'),
                controller: _controller,
                primary: false,
                padding: EdgeInsets.zero,
                itemExtent: kTurnListRowHeight,
                itemCount: widget.entries.length,
                itemBuilder: (context, i) {
                  final entry = widget.entries[i];
                  final isActive = i == activeIndex;
                  return InkWell(
                    key: ValueKey('turn-list-row-${entry.turnId}'),
                    // 关闭弹层并回传选中的轮次；页面在那里接锚点状态机。
                    onTap: () => Navigator.of(context).pop(entry.turnId),
                    child: Container(
                      color: isActive ? scheme.primaryContainer : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: SpbSpacing.lg,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${entry.index}',
                              textAlign: TextAlign.right,
                              style: SpbType.listMeta(theme.textTheme)
                                  ?.copyWith(
                                    color: isActive
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                          const SizedBox(width: SpbSpacing.md),
                          Expanded(
                            child: Text(
                              entry.label,
                              // 移动端宽度更窄，留两行：24 字标签单行放不下时
                              // 折一行，比直接省略更能分辨相近的两轮。
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
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
          ],
        ),
      ),
    );
  }
}
