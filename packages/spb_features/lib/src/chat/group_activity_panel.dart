import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'group_gate_panel.dart';
import 'group_tool_calls_panel.dart';
import 'turn_status.dart';

/// 「动态」面板：**现在这一轮在干什么** + 工具调用 + Gate 决策。
///
/// ## 它解决什么
///
/// 时间线是给「读对话」用的，但 agent 一轮工作会产生大量**过程信息**：几十次
/// 工具调用、每次的入参与输出、若干 gate 决策。把它们全部内联在时间线上会把
/// 正文挤出视野；而把它们全部藏起来，用户又会失去「它到底在做什么」的感知。
///
/// 本面板是这个矛盾的第二半：时间线保留内联工具卡（过程感 + 搜索命中），
/// 面板提供**集中视图**——最新在上、可按需展开、且顶部固定一行当前状态。
///
/// ## 与时间线的分工（不要合并）
///
/// | | 时间线 | 本面板 |
/// |---|---|---|
/// | 目的 | 读对话、看过程发生的**顺序** | 回答「刚才跑/正在跑什么」 |
/// | 顺序 | 时间正序，夹在正文之间 | 时间**倒序**，最新在上 |
/// | 工具折叠 | 连续 ≥5 条折成一张卡 | 平铺（单条各自折叠） |
///
/// ## 为什么顶部状态行是「固定一行」而不是可滚区
///
/// 它回答的是「此刻」，而下面的列表可以滚很远。若它也随列表滚走，用户滚到
/// 一半就不知道这轮是否还在跑了。故它固定在顶部，两个列表各自滚动。
///
/// ## 为什么上下分栏而不是单一滚动列表（沿用原诊断面板的取舍）
///
/// 两个子面板各自是 `ListView`（数据量可能很大，各自独立滚动更稳）。合并成
/// 一个滚动列表要把两者拆成 sliver，改动面大且会丢失各自的滚动位置。
/// 分栏比例 3:2——工具调用条目更多、更常看。
///
/// ## 为什么它是「人人可见」而不是开发构建专属
///
/// 此前这层能力叫「诊断」，只在 `!SpbEnv.isRelease` 时作为侧边栏 tab 出现，
/// 理由是「工具入参与 gate 决策是内部视图」。但那让**发布版的用户**完全无法
/// 回答「它卡在哪一步 / 为什么自己又跑了一轮」——而这正是用户报障时最常问的
/// 问题，也让「时间线太吵」只能靠折叠缓解、没有替代视图。
///
/// 现在它叫「动态」并始终可见：内容仍是只读事实（工具调用 + gate 决策），
/// 不含凭据也不含管理面操作，没有理由藏起来。逐条仍默认折叠，不喧宾夺主。
class GroupActivityPanel extends StatelessWidget {
  const GroupActivityPanel({
    super.key,
    required this.items,
    required this.activities,
    this.decisions,
    this.staleTurnIds = const {},
    this.executionStatus,
    this.toolCallsFlex = 3,
    this.decisionsFlex = 2,
  });

  /// 时间线（归约结果）。工具调用列表与「当前轮次状态」都从它派生。
  ///
  /// ## 为什么不直接传 `toolCalls` / `status`
  ///
  /// 装配层（两端 router）手里拿的就是这份 items。若由它们各自算“哪些是
  /// 工具调用”“现在是什么状态”，就会出现「页面说还在跑、面板说已结束」
  /// 这类漂移——与 §6.17 同一失败模式，只是发生在数据侧。
  final List<ConversationItem> items;

  /// `turn_activity` 快照（turnId → 快照）。
  final Map<String, TurnActivitySnapshot> activities;

  /// Gate 决策（回答「它为什么决定继续 / 停止」）。
  ///
  /// **null 表示本端不订阅它**（移动端当前不接 `controller.gateDecisions`）。
  /// 此时整块决策区**不渲染**，工具调用区占满高度——而不是显示一个「暂无
  /// gate 决策」的空态，那会被读成「这一轮确实没有决策」。
  final List<GateDecision>? decisions;

  /// 看门狗判出的 stale turn 集合（§5.8）。
  ///
  /// ⚠️ 必须传：不传则面板会在 turn 已判「无进展」时继续显示「已调 N 个
  /// 工具」，与页面上的超时提示条自相矛盾。
  final Set<String> staleTurnIds;

  /// 排队 / 重试状态；null 表示没有。
  final ExecutionStatus? executionStatus;

  /// 上下分栏的弹性比例。
  final int toolCallsFlex;
  final int decisionsFlex;

  @override
  Widget build(BuildContext context) {
    final toolCalls = items.whereType<ToolCallItem>().toList(growable: false);

    // 当前轮次：取**最后一个**带流式标记的项。只取最后一个而不是扫描全部
    // 同 §5.8 的理由——一个很久以前丢过 `done` 的 turn 会把面板永远判成
    // 运行中。
    final turnId = streamingTurnIdOf(items);
    final status = deriveTurnStatusFor(
      items: items,
      turnId: turnId,
      activities: activities,
      staleTurnIds: staleTurnIds,
      executionStatus: executionStatus,
    );

    return Column(
      key: const ValueKey('activity-panel'),
      children: [
        _StatusRow(status: status),
        const Divider(height: 1),
        Expanded(
          flex: decisions == null ? 1 : toolCallsFlex,
          child: GroupToolCallsPanel(toolCalls: toolCalls),
        ),
        if (decisions != null) ...[
          const Divider(height: 1),
          Expanded(
            flex: decisionsFlex,
            child: GroupGatePanel(decisions: decisions!),
          ),
        ],
      ],
    );
  }
}

/// 顶部状态行：一行字回答「现在在等 / 在跑 / 不动了 / 没在跑」。
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});

  /// null 表示没有进行中的轮次（显示「当前没有进行中的轮次」，而不是空白
  /// 或一条陈旧的「执行中」）。
  final TurnStatusSummary? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = status;
    // 没有进行中的轮次时用「静止」图标而不是转圈：转圈会让用户以为还在跑。
    final spinner = summary?.spinner ?? false;
    final text = summary?.text ?? '当前没有进行中的轮次';
    final detail = summary?.detail;

    return Padding(
      key: const ValueKey('activity-status'),
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.md,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: SpbSpacing.lg,
            height: SpbSpacing.lg,
            child: spinner
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  )
                : Icon(
                    summary == null
                        ? Icons.pause_circle_outline
                        : Icons.hourglass_disabled_outlined,
                    size: SpbSpacing.lg,
                    color: scheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('activity-status-text'),
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (detail != null)
            Text(
              detail,
              key: const ValueKey('activity-status-detail'),
              style: SpbType.listMeta(theme.textTheme)
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
