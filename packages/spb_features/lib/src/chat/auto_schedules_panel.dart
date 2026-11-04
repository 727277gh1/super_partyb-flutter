import 'package:flutter/material.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

import 'auto_schedules.dart';

/// 加载当前 group 的自动续跑排程列表。
///
/// 装配层实现即 `AutoSchedulesUseCase.load(groupId)` 的薄包装。
typedef LoadAutoSchedules = Future<List<ChatTurnSchedule>> Function();

/// 停用当前 group 全部未触发的续跑排程，并返回**回读后的权威列表**。
///
/// 装配层实现即 `AutoSchedulesUseCase.stopAll(groupId)` 后取 `.items`。
///
/// ## 为什么回调返回列表而不是 void
///
/// 若返回 void，面板只能自己再 `load()` 一次——那会与用例内部的回读重复
/// （多两次请求），且两次读取之间服务端可能又变了，面板显示的反而可能是
/// 更旧的一份。让回调把用例刚读到的权威结果带回来，面板直接替换本地状态，
/// **一次读取、一个真相**。
///
/// 返回完整结果（含 `disabledCount`）而不是裸列表：停用端点的谓词是
/// `enabled=1 AND run_count < max_runs`，并发场景下「列表里有 3 条待触发」
/// 与「实际停用了 0 条」可能同时为真（另一端已先停用）——条数是唯一权威
/// 信号，面板据此给出「已停用 N 个 / 没有在途」的反馈。
typedef StopAllAutoSchedules = Future<AutoSchedulesStopResult> Function();

/// 自动续跑排程面板：查看 / 停用「Goal Gate 自动续跑」。
///
/// ## 它解决什么（为什么必须有这个面板）
///
/// 服务端在目标未达成时会排一批 `chat_turn_schedules` 行，到点自动接着跑。
/// 但这两个端点（列出 / 停用）在客户端**零调用方**——排程只写不读，用户既
/// 看不到「它还要自己跑几轮」，也没法取消。本面板把这条链路补完。
///
/// ## 与 [GroupGatePanel] 的分工（**不要合并**）
///
/// | 面板 | 回答的问题 | 端点 |
/// |---|---|---|
/// | [GroupGatePanel] | 「为什么停了 / 为什么还在跑」 | `GET /chat/groups/:id/gate-decisions` |
/// | 本面板 | 「它接下来还要自己跑几次，怎么叫停」 | `…/auto-schedules` + `…/auto-schedule/stop` |
///
/// 前者是**历史决策**（过去时），后者是**待触发排程**（将来时）。合并会让
/// 「已停用」与「已停止」两种状态混在一张表里，而它们对应不同的时间方向。
///
/// ## 「未注入回调 = 只读」
///
/// [onStopAll] 为 null 时**整个「停用全部」按钮不渲染**（不是禁用）：禁用按钮
/// 会让用户以为「本端支持但暂时不可用」，而真相是这一端没装配该能力。
/// 与 [GoalHistoryPanel] 同一约定。
///
/// ## 为什么数据靠注入、面板自己不碰 HTTP
///
/// 同 [GoalHistoryPanel] / [GoalTasksPanel] / [GroupDeliverablesPanel]：面板只
/// 渲染 + 收集意图，HTTP 由 app 装配层注入。故可在无头环境用内存桩完整验证。
class AutoSchedulesPanel extends StatefulWidget {
  const AutoSchedulesPanel({
    super.key,
    required this.load,
    this.onStopAll,
    this.busy = false,
    this.showHeader = true,
    this.emptyHint = '当前对话没有待触发的自动续跑',
    this.reloadToken,
  });

  /// 加载排程列表。
  final LoadAutoSchedules load;

  /// 停用全部待触发排程并返回回读后的列表。null 时不渲染停用入口。
  final StopAllAutoSchedules? onStopAll;

  /// 是否有写操作在途。为 true 时全部控件禁用（防并发提交互相覆盖）。
  final bool busy;

  /// 是否渲染自带标题行（tab 内容通常由 tab 标签承担标题）。
  final bool showHeader;

  /// 空列表时的提示。
  final String emptyHint;

  /// 切换对话时重新加载（Flutter 会复用本 State）。
  final Object? reloadToken;

  @override
  State<AutoSchedulesPanel> createState() => _AutoSchedulesPanelState();
}

class _AutoSchedulesPanelState extends State<AutoSchedulesPanel> {
  List<ChatTurnSchedule> _items = const [];
  bool _loading = false;
  String? _error;

  /// 停用操作的一次性反馈（成功后显示，下一次加载/停用/换对话时清除）。
  /// null = 无反馈。与 [_error] 互斥（同一次操作要么成功要么失败）。
  String? _notice;

  /// 停用操作在途（与 [AutoSchedulesPanel.busy] 分开：后者是父层共享的 busy，
  /// 本面板自己的按钮点击不该让设置面板也跟着转圈）。
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(AutoSchedulesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      // 换对话：先清空，避免短暂显示上一个 group 的排程——那些行的
      // `meta.group_id` 指向别的对话，停用按钮会让用户以为在停本对话的。
      setState(() {
        _items = const [];
        _error = null;
        _notice = null;
      });
      _reload();
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      // 重新拉取意味着用户看到了当前真实状态——上一次停用的反馈已过时。
      _notice = null;
    });
    try {
      final items = await widget.load();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on AutoSchedulesFailure catch (e) {
      // 用例已把错误翻译成可直接展示的文案（见 `describeAutoSchedulesError`）。
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on SpbError catch (e) {
      // 纵深防御：装配层若注入的是裸 `ChatApi` 调用（未经用例翻译），
      // 这里兜住，至少给出一句话而不是崩溃。
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 停用全部待触发排程。
  ///
  /// ## 为什么用回调返回的列表直接替换本地状态（而不是再 `load()` 一次）
  ///
  /// 见 [StopAllAutoSchedules] 的文档：用例内部已经回读过权威列表，再拉一次
  /// 是重复请求，且两次之间可能又变了。直接替换，一次读取、一个真相。
  Future<void> _stopAll() async {
    final stop = widget.onStopAll;
    if (stop == null || _stopping || widget.busy) return;
    setState(() {
      _stopping = true;
      _error = null;
    });
    try {
      final result = await stop();
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _stopping = false;
        // 反馈（Go b2a54b5a 语义：stop 只停 goal_gate 排程）：
        // - disabledCount == 0 → 没有在途的自动续跑（并发下另一端已停用，
        //   或条目在点击与服务端之间已被触发），不是错误。
        // - disabledCount > 0 → 已停用 N 个。
        _notice = result.disabledCount > 0
            ? '已停用 ${result.disabledCount} 个自动续跑排程'
            : '没有在途的自动续跑排程';
      });
    } on AutoSchedulesFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _stopping = false;
      });
    } on SpbError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _stopping = false;
      });
    }
  }

  /// 是否存在**服务端停用谓词会命中**的条目。
  ///
  /// ## 为什么用 [ChatTurnSchedule.isPending] 而不是裸 `enabled`
  ///
  /// 停用端点的 SQL 谓词是 `enabled = 1 AND run_count < max_runs AND …`。
  /// 一个 `enabled: true` 但次数已用尽的行**不会被撤销**——若按裸 `enabled`
  /// 判可点，用户点下去得到「已停用 0 条」，看起来像功能坏了。
  /// [ChatTurnSchedule.isPending] 与服务端同口径。
  bool get _hasPending => _items.any((s) => s.isPending);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 加载/停用失败：给一条可重试的窄条，不静默成「没有排程」。
    if (_error != null) {
      return Center(
        key: const ValueKey('auto-schedules-error'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: SpbSpacing.xxl,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                '自动续跑加载失败：$_error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: SpbSpacing.sm),
              TextButton(
                key: const ValueKey('auto-schedules-retry'),
                onPressed: _loading ? null : _reload,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 首帧加载中：转圈而非空占位（空占位会被误读为「确实没有排程」）。
    if (_loading && _items.isEmpty) {
      return const Center(
        key: ValueKey('auto-schedules-loading'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: SizedBox(
            width: SpbSpacing.xl,
            height: SpbSpacing.xl,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return Center(
        key: const ValueKey('auto-schedules-empty'),
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.schedule,
                size: SpbSpacing.xxl,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: SpbSpacing.sm),
              Text(
                widget.emptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final pendingCount = _items.where((s) => s.isPending).length;

    return ListView.builder(
      key: const ValueKey('auto-schedules-list'),
      padding: SpbSpacing.pagePadding,
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showHeader)
                  Text(
                    '自动续跑（${_items.length}）',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                // 停用入口：未注入回调时**整个不渲染**（见类文档）。
                if (widget.onStopAll != null)
                  Padding(
                    padding: const EdgeInsets.only(top: SpbSpacing.xs),
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('auto-schedules-stop-all'),
                      // 无可撤销项时禁用：点下去只会得到「已停用 0 条」。
                      onPressed: (_hasPending && !_stopping && !widget.busy)
                          ? _stopAll
                          : null,
                      icon: _stopping
                          ? const SizedBox(
                              width: SpbSpacing.lg,
                              height: SpbSpacing.lg,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cancel_outlined),
                      label: Text(
                        _hasPending ? '停用全部待触发（$pendingCount）' : '停用全部待触发',
                      ),
                    ),
                  ),
                // 一次性反馈：停用成功后给一句（含 disabledCount == 0 的
                // 「没有在途」——那也是有效结论，不能静默）。
                if (_notice != null)
                  Padding(
                    key: const ValueKey('auto-schedules-notice'),
                    padding: const EdgeInsets.only(top: SpbSpacing.xs),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: SpbSpacing.md,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: SpbSpacing.xs),
                        Expanded(
                          child: Text(
                            _notice!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }
        return _AutoScheduleRow(schedule: _items[index - 1]);
      },
    );
  }
}

/// 一条自动续跑排程。
class _AutoScheduleRow extends StatelessWidget {
  const _AutoScheduleRow({required this.schedule});

  final ChatTurnSchedule schedule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      key: ValueKey('auto-schedule-${schedule.id}'),
      margin: const EdgeInsets.only(bottom: SpbSpacing.sm),
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // message 是排程触发时要发的内容——用户据此判断「它还要继续做什么」，
            // 故放主文本位（与 goal 面板把 goalText 放主位同一取舍）。
            Text(
              schedule.message.isEmpty ? '（无内容）' : schedule.message,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: SpbSpacing.xs),
            Wrap(
              spacing: SpbSpacing.xs,
              runSpacing: SpbSpacing.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // triggerReason 用 wire 值而非中文标签：它与服务端
                // `dedupe_key LIKE 'goal_gate:%'` 的判定直接对应，
                // 运维/排查时要能对上字面值（与 GoalHistoryPanel 的
                // tasks_source 同一理由）。
                _Meta(text: schedule.triggerReason),
                _Chip(
                  key: ValueKey('auto-schedule-state-${schedule.id}'),
                  label: schedule.isPending
                      ? '待触发'
                      : (schedule.enabled ? '已用尽' : '已停用'),
                  color: schedule.isPending
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                _Meta(text: '${schedule.runCount}/${schedule.maxRuns} 轮'),
                if (schedule.isPending && schedule.nextRunAt != null)
                  _Meta(text: '下次 ${_formatTimestamp(schedule.nextRunAt!)}'),
              ],
            ),
            // 上次失败原因：有就显示（否则用户只看到「它停在那」，不知道是
            // 因为报错还是因为轮次用尽）。新 DTO（Go `b2a54b5a`）的
            // `last_error` 是 parseJSON 解析过的**对象**（原 JSON 文本已不可得），
            // 故压缩成单行文本展示；可能是任意形状，不能假设有 `error` 键。
            if (schedule.lastError != null) ...[
              const SizedBox(height: SpbSpacing.xs),
              Text(
                _describeScheduleError(schedule.lastError!),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// `nextRunAt` → `YYYY-MM-DD HH:MM`（本地时区）。
  ///
  /// 不引 `intl`：本面板只需要一种固定格式（与 `GoalHistoryPanel` 同一取舍）。
  /// `ChatTurnSchedule.fromJson` 已把时间转成本地时区，故这里直接读字段。
  static String _formatTimestamp(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p2(t.month)}-${p2(t.day)} '
        '${p2(t.hour)}:${p2(t.minute)}';
  }

  /// 把 `last_error` 对象压成单行文本（新 DTO 是 parseJSON 解析过的任意 JSON
  /// 值，形状不可假设）。Map 优先取常见键，其余形态直接 toString。
  static String _describeScheduleError(Object error) {
    if (error is Map) {
      for (final key in const ['error', 'message', 'reason']) {
        final v = error[key];
        if (v is String && v.isNotEmpty) return v;
      }
    }
    final s = error.toString();
    return s;
  }
}

/// 状态徽标。
class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.sm,
        vertical: SpbSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: SpbRadius.cardAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 行内的次要元信息（triggerReason / 轮次 / 时间）。
class _Meta extends StatelessWidget {
  const _Meta({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
