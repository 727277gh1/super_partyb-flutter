import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'tool_call_tile.dart';

/// 连续工具调用的折叠卡（时间线内嵌）。
///
/// ## 它解决什么
///
/// 一轮 agent 工作动辄调用几十次工具，而每条 `ToolCallItem` 在时间线里是一张
/// 独立的 `Card`（折叠态约 56px）。二三十张同构卡片夹在正文之间，会把对话正文
/// 完全挤出视野——用户翻不动，也读不下去。本卡把一段连续的工具调用折成**一张**
/// 摘要（「已调用 12 个工具 · 最近：bash」），点开才逐条渲染 [ToolCallTile]。
///
/// ## 折叠只发生在**展示层**
///
/// 分组来自 `spb_domain` 的 `groupToolCallsForDisplay`（输入归约结果、输出
/// 展示行，**不改归约结果**）。因此：
///
/// - **对话内搜索照旧**：搜的仍是完整 `_items`（工具名 / 参数 / 输出都在），
///   命中项的 id 通过 `locateIdsOf` 映射回这张卡并滚过去；
/// - **看门狗照旧**：`EventReducer.inFlightTurnIds` 仍能看见每条未完成工具的
///   `output == null`（§5.8 的判据依赖它）。
///
/// ## 含「执行中」成员时**默认展开**
///
/// 摘要只回答「调了几次」，不回答「现在这一步是什么」。一轮正在跑工具时把它
/// 折起来，等于把用户唯一能看见的「它在干活」的证据藏掉（那正是
/// `TurnStatusStrip` 存在的理由）。故 [ToolCallBatchRow.hasRunning]
/// 为真时默认展开。
///
/// ## 为什么不做「失败 N 条」的徽标
///
/// 「这条输出算不算失败」是 [ToolCallTile] 里的**展示层启发式**（扫输出文本找
/// `error` / `traceback` 等）。把判据复制一份到摘要里就会有两处可能不一致的
/// 判断（摘要说「0 个失败」、展开后满屏红）。宁可不显示。
///
/// ## 展开态是组件内 State，不进归约
///
/// 与 `AgentFileBatchCard` 同一取舍：展开与否纯属这一帧的视图状态。副作用是
/// 切换对话/重开页面后展开态复位。
class ToolCallBatchCard extends StatefulWidget {
  const ToolCallBatchCard({super.key, required this.batch});

  final ToolCallBatchRow batch;

  @override
  State<ToolCallBatchCard> createState() => _ToolCallBatchCardState();
}

class _ToolCallBatchCardState extends State<ToolCallBatchCard> {
  /// 展开态。null = 尚未被用户操作过 → 按 [ToolCallBatchRow.hasRunning] 决定。
  ///
  /// 用可空字段而不是在 `initState` 里初始化：`didUpdateWidget` 时批可能从
  /// 「全完成」变成「有在飞」（下一条工具调用并进来），此时若用户从没点过，
  /// 展开态应跟着走；用户点过之后则以用户的选择为准。
  bool? _expanded;

  /// 显式控制器：`ExpansionTile.initiallyExpanded` **只在 initState 生效**
  /// （SDK 的 `_ExpansionTileState.didUpdateWidget` 不同步它），故「跑完后
  /// 自动收起」必须走控制器，否则一轮结束后这张卡会永远摊开——而那正是本
  /// 组件要消除的噪声。
  final ExpansibleController _controller = ExpansibleController();

  /// 程序性切换期间置位，避免把自己触发的回调记成「用户操作过」。
  bool _syncingExpansion = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ToolCallBatchCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 用户点过 → 以用户的选择为准，不再跟随批的状态。
    if (_expanded != null) return;
    final before = oldWidget.batch.hasRunning;
    final after = widget.batch.hasRunning;
    if (before == after) return;

    // 在飞 ↔ 全完成：同步到控制器（`expand`/`collapse` 都是幂等的）。
    _syncingExpansion = true;
    if (after) {
      _controller.expand();
    } else {
      _controller.collapse();
    }
    _syncingExpansion = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final batch = widget.batch;
    final expanded = _expanded ?? batch.hasRunning;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与单条工具卡同款容器（`Card` + `dense` 的 `ExpansionTile`）：
        // 折叠卡与展开后的单卡在视觉上是同一类东西，用户不需要重新学。
        Card(
          color: scheme.surfaceContainerLow,
          child: ExpansionTile(
            dense: true,
            // 折叠卡的身份取**首条**成员的 id（与文件批量卡同理）：首条 id 在
            // 折叠期间稳定，展开/收起不会换 key（换 key 会销毁子 State，用户
            // 刚展开的内容会塌回去）。
            key: const ValueKey('tool-call-batch-tile'),
            controller: _controller,
            initiallyExpanded: expanded,
            onExpansionChanged: (v) {
              // 程序性切换不算「用户操作」：否则跑完自动收起一次就把
              // `_expanded` 定格，下一轮再也不会自动展开。
              if (_syncingExpansion) return;
              setState(() => _expanded = v);
            },
            tilePadding: const EdgeInsets.symmetric(horizontal: SpbSpacing.sm),
            childrenPadding: const EdgeInsets.fromLTRB(
              SpbSpacing.lg,
              0,
              SpbSpacing.lg,
              SpbSpacing.sm,
            ),
            leading: Icon(
              batch.hasRunning
                  ? Icons.construction_outlined
                  : Icons.build_outlined,
              size: SpbSpacing.lg,
              color: batch.hasRunning
                  ? scheme.primary
                  : scheme.onSurfaceVariant,
            ),
            title: Text(
              '已调用 ${batch.count} 个工具',
              key: const ValueKey('tool-call-batch-title'),
              style: theme.textTheme.labelLarge,
            ),
            subtitle: Text(
              _subtitle(batch),
              key: const ValueKey('tool-call-batch-subtitle'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: batch.hasRunning
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            // 展开项：逐条复用单卡。注意单卡自己的入参/结果是**二次折叠**的
            // （见 [ToolCallTile]），所以「展开这张卡」不等于「展开 20 段输出」。
            children: [
              for (final call in batch.calls)
                Padding(
                  key: ValueKey('tool-batch-member-${call.id}'),
                  padding: const EdgeInsets.only(bottom: SpbSpacing.xs),
                  child: ToolCallTile(
                    name: call.name,
                    args: call.args,
                    output: call.output,
                    isComplete: call.isComplete,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 副标题：「最近：bash」（有在飞项时追加「执行中 · 已完成 11/12」）。
  ///
  /// ## 为什么是「最近」而不是「首个」
  ///
  /// 用户关心「它现在在干什么」，而批内最后一条就是当前进度（工具调用是串行
  /// 的）。首条只在回看时有点意义，且它已经在展开的列表里。
  ///
  /// ## 「已完成 N/M」只在有在飞项时给
  ///
  /// 全部完成时 N == M，那句纯属重复标题里的计数。
  String _subtitle(ToolCallBatchRow batch) {
    final last = batch.last.name;
    if (!batch.hasRunning) return '最近：$last';
    return '执行中 · 最近：$last（已完成 ${batch.completedCount}/${batch.count}）';
  }
}
