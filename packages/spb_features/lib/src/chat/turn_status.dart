import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 「当前这一轮在干什么」的统一口径。
///
/// ## 为什么需要一个独立模块
///
/// 同一件事有**三个**消费点，而它们此前各写一份：
///
/// | 消费点 | 形态 |
/// |---|---|
/// | `ConversationPage` 底部槽位（排队/重试横幅） | 细条 |
/// | `ConversationPage` 底部槽位（活动指示） | 细条 |
/// | 侧边栏「动态」面板的状态行 | 面板内一行 |
///
/// 三处若各写一套文案，「排队中」在不同位置会变成不同说法，用户会以为是两件
/// 不同的事。故文案与判据都收在这里，UI 只管渲染。
///
/// ## 与归约层的关系
///
/// 本模块**只读**归约结果（[ExecutionStatus] / [TurnActivitySnapshot] /
/// `toolCount` 等派生量），不产出也不修改 [ConversationItem]——与 §5.8
/// 「派生信号不改归约」同一取向。

/// 当前轮次的状态类别。
///
/// 它只影响**图标与颜色**（见 [TurnStatusStrip]），文案由
/// [TurnStatusSummary.text] 承载。
enum TurnStatusKind {
  /// 还没起跑：在等执行名额（`queue_state`）。
  queued,

  /// 上一轮失败，正在安排重试（`retry_scheduled`）。
  retrying,

  /// 已起跑，还没有正文，也没有工具调用。
  running,

  /// 已送达服务端、agent 尚未产出任何东西（`preparing`，见 [deriveTurnStatus]）。
  preparing,

  /// 已起跑且已在调用工具（本模块新增的一档，见 [deriveTurnStatus]）。
  runningWithTools,

  /// 长时间无进展（客户端看门狗，见 §5.8）。
  stalled,
}

/// 「当前轮次状态」的一句话摘要。
///
/// ## 为什么 `text` 与 `detail` 分开
///
/// 主文案回答「它在等 / 在跑 / 不动了」，右侧补充回答「跑到哪了」。窄屏下
/// 补充项会被省略号截断（`detail` 是**可丢**的），故它不能承载判定信息——
/// 把「已调用 12 个工具」整体塞进 `detail` 会让关键信息在窄屏消失。
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

  /// 右侧补充（可丢）：`最近：bash` / `已运行 2 分 5 秒`。
  final String? detail;

  /// 是否显示转圈。`stalled` 为 false——看门狗的含义是「我们没再收到进展」，
  /// 继续转圈会与「长时间无进展」自相矛盾（见 `_StaleTurnNotice`）。
  final bool spinner;

  @override
  String toString() =>
      'TurnStatusSummary($kind, "$text"${detail == null ? '' : ', "$detail"'})';
}

/// 派生当前轮次状态；null 表示**没有进行中的轮次**（不该显示任何状态条）。
///
/// ## 优先级（自高到低）
///
/// 1. [TurnStatusKind.stalled] —— 看门狗已判定无进展。它是**关于前两者的
///    结论**，压过一切：此时「排队中」「已调用 8 个工具」都是过期信息。
/// 2. [ExecutionStatus] —— 排队 / 重试。它们表示「还没开始跑」，
///    优先于「已经在跑」的证据（与 [ExecutionStatus] 类文档的分工一致）。
/// 3. 有工具调用 → [TurnStatusKind.runningWithTools]。
/// 4. [TurnActivitySnapshot] → [TurnStatusKind.running]。
/// 5. [isPreparing]（已送达、agent 未动）→ [TurnStatusKind.preparing]。
/// 6. 都没有 → null（流式正文本身在动，再加一条状态只是噪声——这是既有
///    `_visibleActivityFor` 的取舍，本轮保留）。
///
/// ## 关于 [toolCount] 为什么可以不传
///
/// 它来自 `_items` 的尾向扫描（不是事件），页面已经算过一次（见
/// `_findStreamingItem` 的「一次扫描」约定）。面板拿不到 items 时传 0 即可，
/// 会退化成第 4/5 档——不会错，只是少了「已调用 N 个工具」这层细节。
TurnStatusSummary? deriveTurnStatus({
  required bool isStreaming,
  ExecutionStatus? executionStatus,
  TurnActivitySnapshot? activity,
  bool isStale = false,
  int toolCount = 0,
  String? lastToolName,
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
    return TurnStatusSummary(
      kind: executionStatus.kind == ExecutionStatusKind.retryScheduled
          ? TurnStatusKind.retrying
          : TurnStatusKind.queued,
      text: executionStatusLabel(executionStatus),
      detail: elapsed,
    );
  }

  if (toolCount > 0) {
    // 「最近：bash」只在有名字时出现——拼出「最近：null」比不说更糟
    // （同 [TurnActivitySnapshot.lastEventType] 的取向）。
    final last = (lastToolName ?? '').trim();
    return TurnStatusSummary(
      kind: TurnStatusKind.runningWithTools,
      text: '已调用 $toolCount 个工具',
      detail: last.isEmpty ? elapsed : '最近：$last',
    );
  }

  if (activity != null) {
    return TurnStatusSummary(
      kind: TurnStatusKind.running,
      text: '执行中 · 已运行 ${formatTurnElapsed(activity.elapsedMs)}',
      detail: _lastEventLabel(activity),
    );
  }

  // 兵底：结构上这一轮尚未结束，但拿不到任何正面证据（与看门狗武装计时器
  // 同一判据：`LastTurnRunState.preparing`）。
  //
  // 文案逐字对齐 webapp `Workbench.streamInitialPreparingTitle`（"正在准备响应"）：
  // 两端口径一致，用户跨端对照时不会以为是两件事。
  //
  // 注意它**不是** `ExecutionStatus` 的兵底：那一条只在服务端发了
  // `queue_state` / `retry_scheduled` 时才有值，而这里覆盖的是「连那条都没
  // 有」的空窗（排队事件缺失 / 服务端还没开始排队）。
  if (isPreparing) {
    return const TurnStatusSummary(
      kind: TurnStatusKind.preparing,
      text: '正在准备响应',
    );
  }

  return null;
}

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
/// （`_TurnActivityIndicator` 与 [TurnStatusStrip] 都调它）。
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

  for (var i = items.length - 1; i >= 0; i--) {
    onVisit?.call();
    final item = items[i];
    if (item.turnId != turnId) break;
    // 倒序扫描 → 第一次遇到的工具就是「最近」的一次。
    if (item is ToolCallItem) {
      toolCount++;
      lastToolName ??= item.name;
    }
    if (item is AssistantMessageItem && item.text.isNotEmpty) {
      hasAgentContent = true;
    }
  }

  return TurnProgress(
    turnId: turnId,
    toolCount: toolCount,
    lastToolName: lastToolName,
    hasAgentContent: hasAgentContent,
  );
}

/// 从 [items] 尾向找出当前仍在生成的 turnId；null 表示没有进行中的轮次。
///
/// 与对话页的 `_findStreamingItem` 同一判据（只看 `AssistantMessageItem` /
/// `ThoughtItem` 的 `isStreaming`）：面板只能拿到 items，拿不到页面的私有
/// 派生量，两边判据不同就会“页面说还在跑、面板说已结束”。
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
/// [showActivityWithContent]：对话页的细条在已有正文时**不**显示活动快照
/// （噪声）；而面板是「现在在干什么」的集中视图，即使正文在流式也照显示。
TurnStatusSummary? deriveTurnStatusFor({
  required List<ConversationItem> items,
  required String? turnId,
  Map<String, TurnActivitySnapshot> activities = const {},
  Set<String> staleTurnIds = const {},
  ExecutionStatus? executionStatus,
  bool showActivityWithContent = true,
  void Function()? onVisit,
}) {
  final progress = scanTurnProgress(items, turnId: turnId, onVisit: onVisit);
  if (!progress.isRunning) return null;

  final hasContent = progress.hasAgentContent && !showActivityWithContent;
  return deriveTurnStatus(
    isStreaming: true,
    executionStatus: executionStatus,
    activity: hasContent ? null : activities[progress.turnId!],
    isStale: staleTurnIds.contains(progress.turnId),
    toolCount: progress.toolCount,
    lastToolName: progress.lastToolName,
  );
}

/// 轮次状态细条（对话页底部槽位用）。
///
/// ## 为什么与 `_ExecutionStatusBar` / `_TurnActivityIndicator` 并存而不合并
///
/// 那两个组件是既有实现、各自有用例钉住视觉与 key。本轮只**新增**「有工具
/// 调用」这一档（[TurnStatusKind.runningWithTools]），故共用一个轻量渲染器：
/// 文案由 [deriveTurnStatus] 统一给出，避免第四份文案副本。
///
/// ## 为什么 spinner 可关
///
/// `stalled` 档不转圈：看门狗的含义恰恰是「我们没再收到进展」，继续转圈会
/// 与文案自相矛盾（同 `_StaleTurnNotice` 的取向）。
class TurnStatusStrip extends StatelessWidget {
  const TurnStatusStrip({super.key, required this.summary});

  final TurnStatusSummary summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final detail = summary.detail;

    return Material(
      key: const ValueKey('conversation-turn-status'),
      // 与活动指示 / 执行等待同用 secondaryContainer：同一槽位的互斥状态。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: summary.spinner
                  ? CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSecondaryContainer,
                    )
                  // 不转圈时占住同宽，避免文案左右跳动。
                  : Icon(
                      Icons.hourglass_disabled_outlined,
                      size: SpbSpacing.lg,
                      color: scheme.onSecondaryContainer,
                    ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                summary.text,
                key: const ValueKey('conversation-turn-status-text'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (detail != null)
              Text(
                detail,
                key: const ValueKey('conversation-turn-status-detail'),
                style: SpbType.listMeta(textTheme)
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
          ],
        ),
      ),
    );
  }
}
