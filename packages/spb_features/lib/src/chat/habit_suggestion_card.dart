import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 习惯建议卡（`habit_suggestion_created` / `habit_suggestion_resolved`）。
///
/// ## 视觉与 [FeedbackRequestCard] / [ConfirmationCard] 同族
///
/// 三者都是「要用户作答的卡」：`Card + secondaryContainer` 底、左侧图标、
/// 按钮区、busy 行。差异化在图标与标题——反馈卡是征询、确认卡是流程阻塞、
/// 本卡是「发现了一个规律，要不要让它自动做」。
///
/// ## resolved 之后不隐藏、只置灰
///
/// 与另两张卡同理由：历史回看要能看到「当时建议过什么、我答了什么」。隐藏会
/// 让上下文缺失——用户回头翻聊天记录时看到的是自己莫名其妙多出的规则。
///
/// ## 为什么从领域对象渲染而不是解析 spec
///
/// 该事件的 payload 里**没有** spec（`BuildSuggestionCreatedPayload` 只有
/// rule_draft / recommendation / evidence），服务端在 IM 渠道另走
/// `agentfilerender` 渲染。故这里是唯一呈现路径，不存在「有 spec 不用」的问题。
class HabitSuggestionCard extends StatelessWidget {
  const HabitSuggestionCard({
    super.key,
    required this.suggestion,
    this.onAccept,
    this.onDismiss,
    this.onSnooze,
    this.busy = false,
  });

  final HabitSuggestionItem suggestion;

  /// 接受建议（服务端会建出 active pattern）。
  final VoidCallback? onAccept;

  /// 忽略（服务端写 24h 冷却窗口）。
  final VoidCallback? onDismiss;

  /// 稍后提醒。参数是选中的时长。
  final void Function(HabitSnoozeOption option)? onSnooze;

  /// 请求进行中：按钮禁用，避免重复提交（服务端 CAS 会挡，但连点会让 UI 闪两次）。
  final bool busy;

  bool get _interactive =>
      suggestion.canResolve &&
      !busy &&
      (onAccept != null || onDismiss != null || onSnooze != null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final resolved = !suggestion.canResolve;

    return Card(
      key: ValueKey('habit-suggestion-${suggestion.suggestionId}'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  resolved ? Icons.task_alt : Icons.auto_awesome,
                  size: SpbSpacing.lg,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: SpbSpacing.sm),
                Expanded(
                  child: Text(
                    '发现一个可固化的习惯',
                    style: textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (suggestion.confidence != null)
                  _ConfidenceChip(confidence: suggestion.confidence!),
              ],
            ),
            const SizedBox(height: SpbSpacing.sm),
            Text(
              _topicLabel(suggestion.topicKey),
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text(
              _scheduleLabel(suggestion),
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer.withValues(alpha: 0.8),
              ),
            ),
            if (suggestion.reasons.isNotEmpty) ...[
              const SizedBox(height: SpbSpacing.sm),
              ...suggestion.reasons.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: SpbSpacing.xxs),
                  child: Text(
                    '· $r',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: SpbSpacing.md),
            if (resolved)
              _ResolvedRow(suggestion: suggestion)
            else
              _ActionRow(
                enabled: _interactive,
                busy: busy,
                onAccept: onAccept,
                onDismiss: onDismiss,
                onSnooze: onSnooze,
              ),
          ],
        ),
      ),
    );
  }

  /// 主题展示名。
  ///
  /// topic_key 是机器键（`weekly-report` / `preference.coffee`），直接展示给
  /// 用户不友好；但**不能**编造一个中文名（服务端没有 topic 标题表）。折中：
  /// 把分隔符换成空格并保留原文，用户看到的是自己说过的话题关键词。
  static String _topicLabel(String topicKey) {
    if (topicKey.isEmpty) return '未命名习惯';
    return topicKey.replaceAll(RegExp(r'[._-]+'), ' ');
  }

  /// 触发节奏文案。
  ///
  /// 按 [HabitTriggerType] 分派：watch 没有钟点，用 time 形状渲染会得到
  /// 「凌晨 0 点」——一个用户从未表达过的时刻。
  static String _scheduleLabel(HabitSuggestionItem s) {
    final cfg = s.triggerConfig;
    if (cfg == null || cfg.isEmpty) {
      return s.triggerType == HabitTriggerType.watch ? '持续盯梢' : '未配置触发时间';
    }
    return cfg.summary;
  }
}

/// 置信度徽标。
///
/// 展示成百分比而非小数：`0.72` 对用户没有意义，`72%` 才有。
class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.confidence});

  final double confidence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = (confidence.clamp(0.0, 1.0) * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: scheme.onSecondaryContainer.withValues(alpha: 0.1),
        borderRadius: SpbRadius.cardAll,
      ),
      child: Text(
        '置信度 $pct%',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// 未处理时的按钮行。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.enabled,
    required this.busy,
    this.onAccept,
    this.onDismiss,
    this.onSnooze,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onDismiss;
  final void Function(HabitSnoozeOption option)? onSnooze;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: SpbSpacing.sm,
      runSpacing: SpbSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onAccept != null)
          FilledButton(
            key: const ValueKey('habit-accept'),
            onPressed: enabled ? onAccept : null,
            child: const Text('让它自动做'),
          ),
        if (onSnooze != null)
          PopupMenuButton<HabitSnoozeOption>(
            key: const ValueKey('habit-snooze'),
            enabled: enabled,
            tooltip: '稍后提醒',
            onSelected: onSnooze,
            itemBuilder: (context) => [
              for (final o in HabitSnoozeOption.values)
                PopupMenuItem(value: o, child: Text(o.label)),
            ],
            // 不用 OutlinedButton 作 child：它的 onPressed 必须为 null
            // （点击由 PopupMenuButton 接管），那会让按钮渲染成**禁用态**
            // （灰字 + 灰边框），用户以为不可点。用自绘外观与
            // OutlinedButton 视觉对齐，但不受 enabled 状态影响。
            child: _OutlinedLikeButton(
              enabled: enabled,
              icon: Icons.schedule,
              label: '稍后',
            ),
          ),
        if (onDismiss != null)
          TextButton(
            key: const ValueKey('habit-dismiss'),
            onPressed: enabled ? onDismiss : null,
            child: const Text('忽略'),
          ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(left: SpbSpacing.xs),
            child: SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

/// 外观模仿 `OutlinedButton`、但不受 `enabled` 影响的自绘按钮。
///
/// 用途：作为 [PopupMenuButton] 的 `child`——点击由外层接管，内层不能用
/// 真的 Button（`onPressed: null` 会渲染成禁用态）。
class _OutlinedLikeButton extends StatelessWidget {
  const _OutlinedLikeButton({
    required this.enabled,
    required this.icon,
    required this.label,
  });

  final bool enabled;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.onSecondaryContainer
        : scheme.onSecondaryContainer.withValues(alpha: 0.38);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.lg,
        vertical: SpbSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border.all(
          color: scheme.onSecondaryContainer.withValues(
            alpha: enabled ? 0.5 : 0.12,
          ),
        ),
        borderRadius: SpbRadius.inputAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SpbSpacing.lg, color: color),
          const SizedBox(width: SpbSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// 已处理后的结果行。
class _ResolvedRow extends StatelessWidget {
  const _ResolvedRow({required this.suggestion});

  final HabitSuggestionItem suggestion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final style = textTheme.bodySmall?.copyWith(
      color: scheme.onSecondaryContainer.withValues(alpha: 0.8),
    );

    final (icon, label) = switch (suggestion.userFeedback) {
      HabitUserFeedback.accepted => (
        Icons.check_circle_outline,
        suggestion.resolvedPatternId != null ? '已采纳，习惯已生效' : '已采纳',
      ),
      HabitUserFeedback.dismissed => (Icons.block, '已忽略'),
      HabitUserFeedback.snoozed => (
        Icons.schedule,
        suggestion.snoozeUntil != null
            ? '已延后至 ${_formatTime(suggestion.snoozeUntil!)}'
            : '已延后',
      ),
      _ => (Icons.info_outline, '已处理'),
    };

    return Row(
      children: [
        Icon(icon, size: SpbSpacing.lg, color: scheme.onSecondaryContainer),
        const SizedBox(width: SpbSpacing.sm),
        Expanded(child: Text(label, style: style)),
      ],
    );
  }

  static String _formatTime(DateTime t) {
    final local = t.toLocal();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${p2(local.hour)}:${p2(local.minute)}';
  }
}
