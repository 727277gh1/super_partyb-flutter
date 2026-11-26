import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

import 'tool_call_tile.dart';

/// 当前轮次的统一展示口径，供主状态栏与两端动态面板共用。
///
/// 这里只读归约结果，不产出或修改 ConversationItem，避免展示折叠影响
/// 搜索、定位与终态判断（§5.8「派生信号不改归约」）。

/// 当前轮次的状态类别。
///
/// 它只影响**图标与颜色**（见 [TurnStatusStrip]），文案由
/// [TurnStatusSummary.text] 承载。
enum TurnStatusKind {
  /// 还没起跑：在等执行名额（`queue_state`）。
  queued,

  /// 上一轮失败，正在安排重试（`retry_scheduled`）。
  retrying,

  /// 轮次尚未终结，当前没有更具体的执行阶段。
  running,

  /// 已送达服务端、agent 尚未产出任何东西（`preparing`，见 [deriveTurnStatus]）。
  preparing,

  /// 有尚未返回结果、也未终结的工具调用。
  runningWithTools,

  /// 最近的内容是思考增量。
  thinking,

  /// 最近的内容是回复正文。
  replying,

  /// 长时间无进展（客户端看门狗，见 §5.8）。
  stalled,
}

/// 「当前轮次状态」的一句话摘要。
///
/// ## 为什么 `text` 与 `detail` 分开
///
/// 主文案回答当前阶段；时长、队列规模和累计调用数放进可展开的详情。
/// 状态判断只依赖主文案，详情在窄屏允许换行、滚动。
final class TurnStatusSummary {
  const TurnStatusSummary({
    required this.kind,
    required this.text,
    this.detail,
    this.spinner = true,
  });

  final TurnStatusKind kind;

  /// 主文案（必有）。
  final String text;

  /// 补充事实：队列规模、已运行时长、工具调用次数与最近工具名。
  final String? detail;

  /// 是否显示转圈。`stalled` 为 false——看门狗的含义是「我们没再收到进展」，
  /// 正文输出时也不转圈，流式内容本身已经提供动态反馈。
  final bool spinner;

  @override
  String toString() =>
      'TurnStatusSummary($kind, "$text"${detail == null ? '' : ', "$detail"'})';
}

/// 派生当前轮次状态；null 表示**没有进行中的轮次**（不该显示任何状态条）。
///
/// 超时、排队/重试优先于运行阶段；工具计数只作摘要，不能证明工具仍在执行。
/// [phase] 来自同轮时间线的最近一步，避免旧思考或旧工具覆盖新的正文。
TurnStatusSummary? deriveTurnStatus({
  required bool isStreaming,
  ExecutionStatus? executionStatus,
  TurnActivitySnapshot? activity,
  bool isStale = false,
  int toolCount = 0,
  String? lastToolName,
  String? activeToolName,
  TurnStatusKind? phase,
  bool isPreparing = false,
}) {
  if (!isStreaming) return null;
  if (isStale) {
    return const TurnStatusSummary(
      kind: TurnStatusKind.stalled,
      text: '长时间无进展 · 可能仍在后台运行',
      spinner: false,
    );
  }

  final elapsed = activity == null || activity.elapsedMs <= 0
      ? null
      : '已运行 ${formatTurnElapsed(activity.elapsedMs)}';
  if (executionStatus != null) {
    final total = executionStatus.queueTotal;
    final user = executionStatus.queueUser;
    return TurnStatusSummary(
      kind: executionStatus.kind == ExecutionStatusKind.retryScheduled
          ? TurnStatusKind.retrying
          : TurnStatusKind.queued,
      text: executionStatusLabel(executionStatus),
      detail: total != null && user != null ? '队列：总计 $total，你的 $user' : elapsed,
    );
  }

  final last = (lastToolName ?? '').trim();
  final details = <String>[
    if (elapsed != null) elapsed,
    if (toolCount > 0) '已调用 $toolCount 个工具',
    if (last.isNotEmpty)
      '最近：$last'
    else if (_lastEventLabelOrNull(activity) case final label?)
      label,
  ];
  final detail = details.isEmpty ? null : details.join(' · ');
  if (phase != null) {
    final active = (activeToolName ?? '').trim();
    return TurnStatusSummary(
      kind: phase,
      text: switch (phase) {
        TurnStatusKind.thinking => '思考中',
        TurnStatusKind.replying => '正在回复',
        TurnStatusKind.runningWithTools =>
          active.isEmpty ? '正在执行工具' : '正在执行工具 · $active',
        TurnStatusKind.preparing => '正在准备响应',
        _ => '执行中',
      },
      detail: detail,
      // 正文已经在流动，用静态图标保持状态可见，避免再叠一层动画。
      spinner: phase != TurnStatusKind.replying,
    );
  }
  if (toolCount > 0 || activity != null) {
    return TurnStatusSummary(
      kind: TurnStatusKind.running,
      text: '执行中',
      detail: detail,
    );
  }
  if (isPreparing) {
    return const TurnStatusSummary(
      kind: TurnStatusKind.preparing,
      text: '正在准备响应',
    );
  }
  return null;
}

String? _lastEventLabelOrNull(TurnActivitySnapshot? activity) =>
    activity == null ? null : _lastEventLabel(activity);

/// 活动快照里的「最近一步」文案；无上一步时返回 null。
///
/// `last_event_type` 是服务端的事件类型名（`tool_call` / `thought` /
/// `message` …）。只翻译常用的几个，其余原样展示——**不猜**（猜错会给出
/// 错误的进展描述）。
String? _lastEventLabel(TurnActivitySnapshot activity) {
  final raw = (activity.lastEventType ?? '').trim();
  if (raw.isEmpty) return null;
  final label = switch (raw) {
    'tool_call' => '工具调用',
    'thought' => '思考',
    'message' => '回复',
    _ => raw,
  };
  return '最近：$label';
}

/// 排队 / 重试的横幅文案（判定链与 webapp `ChatMessageList.tsx` 一致）。
///
/// ⚠️ 重试分支**不看** `reason`：Go 的 `retry_scheduled.reason` 是执行器
/// stderr 原文（可能很长、含路径与噪声），拿它当文案会把横幅变成一堆日志。
/// webapp 同样只用 `attempt`。
String executionStatusLabel(ExecutionStatus s) {
  if (s.kind == ExecutionStatusKind.retryScheduled) {
    // attempt 缺失时退化为 1（与 webapp 的 `|| "1"` 一致）：
    // 宁可说「第 1 次」也不要拼出「第 null 次」。
    return '正在安排第 ${s.attempt ?? 1} 次重试';
  }
  return switch (s.reason) {
    'session_busy' => '正在等待当前会话完成',
    'user_concurrency_limit' => '正在等待用户并发额度',
    'global_concurrency_limit' => '正在等待执行资源',
    _ => '正在等待执行',
  };
}

/// 把毫秒时长格式化成「X 秒 / X 分 Y 秒 / X 小时」。
///
/// ## 为什么不用 `intl` 的 `DurationFormat`
///
/// 本仓库刻意不引入 locale 数据（AGENTS.md §6.12），且 `DurationFormat`
/// （非 `DateFormat`）在 0.19 需要手动构建 pattern，而本处只需要「中文、
/// 两个单位」这一种固定形态。
///
/// ## 与小程序 `formatDuration` 的关系
///
/// 小程序侧同类函数采用「只取最大单位」口径（`2 分` 而非 `2 分 5 秒`；
/// duration 只有 `seconds` 字段）。本函数采用同一口径，但把 ≥ 60s 拆成
/// 「X 分 Y 秒」：
///
/// - `formatDuration` 在这种输入下给出的是「7325 秒」，人脑得自己除 60；
/// - 空窗期动辄几分钟，这是用户唯一的时间参照，「2 分 2 秒」比「122 秒」好读。
///
/// 这是**有意偏离**（改善可读性，不是修正错误）。若将来要求逐字对齐，改成
/// 「只取最大单位」即可，判定逻辑已在下方分开。
///
/// 负数与缺失一律按 0 处理（服务端异常载荷不产出「已运行 -1 秒」）。
///
/// 不加 `@visibleForTesting`：它现在也是生产路径的公共取文案入口
/// （状态栏与动态面板共用）。
String formatTurnElapsed(int elapsedMs) {
  final totalSeconds = elapsedMs <= 0 ? 0 : (elapsedMs / 1000).round();
  if (totalSeconds < 60) return '$totalSeconds 秒';

  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (seconds == 0) return '$minutes 分钟';
  return '$minutes 分 $seconds 秒';
}

/// 一次尾向扫描得到的「本 turn 进度」。
///
/// ## 为什么放在这一层（而不是各端路由各算一遍）
///
/// 三个消费点都要同一份判据：对话页底部状态条、桌面侧边栏「动态」面板、
/// 移动端「动态」弹层。各写一遍就会出现「页面说还在跑、面板说已结束」。
///
/// ## 与归约层的关系
///
/// 它**只读** [ConversationItem]，不改任何东西（同 §5.8「派生信号不改归约」）。
final class TurnProgress {
  const TurnProgress({
    this.turnId,
    this.toolCount = 0,
    this.lastToolName,
    this.hasAgentContent = false,
    this.phase,
    this.activeToolName,
    this.tools = const [],
  });

  /// 没有进行中的轮次时的常量哨兵。
  static const TurnProgress none = TurnProgress();

  /// 进行中的 turn（流式标记判据，与 `EventReducer.inFlightTurnIds` 同源）。
  final String? turnId;

  /// 本 turn 的工具调用条数（0 表示这一轮还没调过工具）。
  final int toolCount;

  /// 最近一次工具名（倒序扫描首个命中）。
  final String? lastToolName;

  /// 本 turn 是否已有非空正文。
  final bool hasAgentContent;

  /// 最近一步的阶段；已完成工具之后先回到通用执行态，不能沿用更早正文。
  final TurnStatusKind? phase;
  final String? activeToolName;

  /// 与进度同一次扫描取得，只有展开详情时才构建工具卡。
  final List<ToolCallItem> tools;

  bool get isRunning => turnId != null;
}

/// 从时间线尾向扫出 [turnId] 这一轮的进度。
///
/// [turnId] 为 null / 空串时返回 [TurnProgress.none]（不扫描）。
///
/// ## 早退条件只能是 `turnId != 目标`
///
/// 同一 turn 的项在时间线上是连续的（归约器按事件顺序追加），故看到 turnId
/// 变化就说明扫完了。⭐ **不能**按类型早退（`is AssistantMessageItem`）：同一
/// turn 中间夹着 `ToolCallItem` / `ThoughtItem`，按类型早退会同时漏掉「工具轮
/// 之后的正文」与「本条计数」。
///
/// ## [onVisit] 只给页面的性能计数器用
///
/// 页面用 `PerfProbe` 计数器钉住「一次 build 扫了多少条」（§6.47）。
/// 本函数不依赖 Flutter，故不直接调计数器，而是交一个回调。
TurnProgress scanTurnProgress(
  List<ConversationItem> items, {
  required String? turnId,
  void Function()? onVisit,
}) {
  if (turnId == null || turnId.isEmpty) return TurnProgress.none;

  var toolCount = 0;
  String? lastToolName;
  var hasAgentContent = false;
  TurnStatusKind? phase;
  String? activeToolName;
  final tools = <ToolCallItem>[];

  for (var i = items.length - 1; i >= 0; i--) {
    onVisit?.call();
    final item = items[i];
    if (item.turnId != turnId) break;
    // 倒序扫描 → 第一次遇到的工具就是「最近」的一次。
    if (item is ToolCallItem) {
      toolCount++;
      lastToolName ??= item.name;
      tools.add(item);
      phase ??= TurnStatusKind.running;
      if (item.output == null && !item.isComplete) {
        activeToolName ??= item.name;
      }
    }
    if (item is AssistantMessageItem) {
      if (item.text.isNotEmpty) hasAgentContent = true;
      if (item.isStreaming) {
        phase ??= item.text.isEmpty
            ? TurnStatusKind.preparing
            : TurnStatusKind.replying;
      } else if (item.text.isNotEmpty) {
        // 权威正文已落地、终态尚未到达：不能重新显示更早的思考阶段。
        phase ??= TurnStatusKind.running;
      }
    }
    if (item is ThoughtItem) {
      phase ??= item.isStreaming
          ? TurnStatusKind.thinking
          : TurnStatusKind.running;
    }
  }

  return TurnProgress(
    turnId: turnId,
    toolCount: toolCount,
    lastToolName: lastToolName,
    hasAgentContent: hasAgentContent,
    phase: activeToolName != null ? TurnStatusKind.runningWithTools : phase,
    activeToolName: activeToolName,
    tools: tools.reversed.toList(growable: false),
  );
}

/// 从 [items] 尾向找出当前仍在生成的 turnId；null 表示没有进行中的轮次。
///
/// 与对话页的 `_findStreamingItem` 同一判据：正文/思考仍在流式，或工具
/// 尚未返回且未终结。面板拿不到页面私有状态，必须使用同一套判据。
///
/// ⚠️ 只看**最后**一个命中项：同 group 的 turn 串行执行，取最后一个即可
/// 回答「现在是不是还在跑」；若遗的是某个很久以前丢过 `done` 的 turn，
/// 面板会被永远判成运行中（§5.8 同一理由）。
String? streamingTurnIdOf(List<ConversationItem> items) {
  for (var i = items.length - 1; i >= 0; i--) {
    final item = items[i];
    final streaming = switch (item) {
      AssistantMessageItem(:final isStreaming) => isStreaming,
      ThoughtItem(:final isStreaming) => isStreaming,
      ToolCallItem(:final output, :final isComplete) =>
        output == null && !isComplete,
      _ => false,
    };
    if (streaming) return item.turnId.isEmpty ? null : item.turnId;
  }
  return null;
}

/// 状态条 / 面板用：把快照与进度合成为一个摘要。
///
/// 与 [deriveTurnStatus] 的区别：本函数**自己**接受整份时间线与 `turnId`，
/// 供拿不到页面私有派生量的装配层（两端 router 的面板）使用。
///
TurnStatusSummary? deriveTurnStatusFor({
  required List<ConversationItem> items,
  required String? turnId,
  Map<String, TurnActivitySnapshot> activities = const {},
  Set<String> staleTurnIds = const {},
  ExecutionStatus? executionStatus,
  void Function()? onVisit,
}) {
  final progress = scanTurnProgress(
    items,
    turnId: executionStatus?.turnId ?? turnId,
    onVisit: onVisit,
  );
  if (!progress.isRunning) return null;

  return deriveTurnStatus(
    isStreaming: true,
    executionStatus: executionStatus,
    activity: activities[progress.turnId!],
    isStale: staleTurnIds.contains(progress.turnId),
    toolCount: progress.toolCount,
    lastToolName: progress.lastToolName,
    activeToolName: progress.activeToolName,
    phase: progress.phase,
  );
}

/// 当前轮次的唯一动态状态栏；详情按需展开，避免多个工具同时转圈。
class TurnStatusStrip extends StatefulWidget {
  const TurnStatusStrip({
    super.key,
    required this.summary,
    this.tools = const [],
    this.showCancel = false,
    this.onCancel,
  });

  final TurnStatusSummary summary;
  final List<ToolCallItem> tools;
  final bool showCancel;
  final VoidCallback? onCancel;

  @override
  State<TurnStatusStrip> createState() => _TurnStatusStripState();
}

class _TurnStatusStripState extends State<TurnStatusStrip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final summary = widget.summary;
    final detail = summary.detail;
    final hasDetails = detail != null || widget.tools.isNotEmpty;
    final animate = summary.spinner && !MediaQuery.disableAnimationsOf(context);

    return Material(
      key: const ValueKey('conversation-turn-status'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: SizedBox(
                    width: SpbSpacing.lg,
                    height: SpbSpacing.lg,
                    child: animate
                        ? CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSecondaryContainer,
                          )
                        : Icon(
                            turnStatusIcon(summary.kind),
                            size: SpbSpacing.lg,
                            color: scheme.onSecondaryContainer,
                          ),
                  ),
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: SpbSpacing.sm,
                    ),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        summary.text,
                        key: const ValueKey('conversation-turn-status-text'),
                        style: textTheme.bodySmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
                if (hasDetails)
                  Semantics(
                    expanded: _expanded,
                    child: IconButton(
                      key: const ValueKey('conversation-turn-details-toggle'),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: _expanded ? '收起详情' : '查看详情',
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ),
                  ),
                if (widget.showCancel)
                  IconButton(
                    key: const ValueKey('conversation-cancel-turn'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: '停止生成',
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
              ],
            ),
            if (_expanded && hasDetails)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.3,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.tools.length + (detail == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (detail != null && index == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
                        child: Text(
                          detail,
                          key: const ValueKey(
                            'conversation-turn-status-detail',
                          ),
                          style: SpbType.listMeta(textTheme)
                              ?.copyWith(color: scheme.onSecondaryContainer),
                        ),
                      );
                    }
                    final toolIndex = index - (detail == null ? 0 : 1);
                    final tool = widget.tools[toolIndex];
                    return ToolCallTile(
                      // 异常回填可能缺失 id，索引保证同轮详情仍有唯一键。
                      key: ValueKey((tool.id, toolIndex)),
                      name: tool.name,
                      args: tool.args,
                      output: tool.output,
                      isComplete: tool.isComplete,
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

/// 详情面板与减少动态效果模式使用相同的静态阶段图标。
IconData turnStatusIcon(TurnStatusKind kind) => switch (kind) {
  TurnStatusKind.stalled => Icons.hourglass_disabled_outlined,
  TurnStatusKind.thinking => Icons.psychology_outlined,
  TurnStatusKind.replying => Icons.edit_outlined,
  TurnStatusKind.runningWithTools => Icons.build_outlined,
  TurnStatusKind.retrying => Icons.refresh,
  TurnStatusKind.queued || TurnStatusKind.preparing => Icons.hourglass_empty,
  TurnStatusKind.running => Icons.play_circle_outline,
};
