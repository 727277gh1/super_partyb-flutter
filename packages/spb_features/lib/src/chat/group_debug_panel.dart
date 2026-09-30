import 'package:flutter/material.dart';

import 'package:spb_domain/spb_domain.dart';

import 'group_gate_panel.dart';
import 'group_tool_calls_panel.dart';

/// 诊断面板：工具调用 + Gate 决策，上下分栏。
///
/// ## 为什么把两者放在同一个 tab
///
/// 它们是同一个问题的两面：「agent 为什么自己又跑了一轮 / 为什么停下来」。
/// 工具调用回答「它做了什么」，Gate 决策回答「它为什么决定继续/停止」。
/// 排障时通常要对照看（比如「它调了 build 工具、然后 gate 判定任务完成」），
/// 分到两个 tab 会强迫用户来回切换。对齐 webapp 的 `debug` tab 结构
/// （`WorkbenchToolCallsPanel` + `WorkbenchGatePanel` 上下堆叠）。
///
/// ## 为什么是上下分栏而非单一滚动列表
///
/// 两个子面板各自是 `ListView`（数据量可能很大，各自独立滚动更稳）。
/// 若强行合并成一个滚动列表，需要把两者拆成 sliver，改动面大且丢失各自
/// 的滚动位置。上下分栏让两者独立滚动，且都能保留各自位置。
///
/// ## 分栏比例
///
/// 工具调用通常条目更多、更常看，给更大权重（flex 3:2）。
class GroupDebugPanel extends StatelessWidget {
  const GroupDebugPanel({
    super.key,
    required this.toolCalls,
    required this.decisions,
    this.toolCallsFlex = 3,
    this.decisionsFlex = 2,
  });

  final List<ToolCallItem> toolCalls;
  final List<GateDecision> decisions;

  /// 上下分栏的弹性比例。
  final int toolCallsFlex;
  final int decisionsFlex;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('debug-panel'),
      children: [
        Expanded(
          flex: toolCallsFlex,
          child: GroupToolCallsPanel(toolCalls: toolCalls),
        ),
        const Divider(height: 1),
        Expanded(
          flex: decisionsFlex,
          child: GroupGatePanel(decisions: decisions),
        ),
      ],
    );
  }
}
