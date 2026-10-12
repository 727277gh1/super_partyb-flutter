import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 习惯建议的「编辑并接受」对话框。
///
/// ## 字段集由服务端下发，客户端**不得**自行扩大
///
/// 真源是 `workers/habit/timeline_events.go:52` 的 `SuggestionEditableFields`
/// （`topic_key` / `trigger_config` / `preferred_agent_id` / `delivery_group_id`），
/// 随 `habit_suggestion_created` 事件的 payload 经
/// [HabitSuggestionItem.editableFields] 抵达。
///
/// 为什么不写死：`applyPatternPatch` 对**不认识**的键静默忽略（见
/// [HabitApi.resolveSuggestion] 的注释），客户端多带一个键不会报错，只会得到
/// 「保存成功但配置没变」——一个极难排查的静默失效。故这里只渲染
/// [HabitSuggestionItem.editableFields] 里出现的键。
///
/// ## `delivery_group_id` 在白名单里但本编辑器不渲染
///
/// 与 webapp 的 `HabitSuggestionEditor` 一致：改投递群需要一个群选择器（并
/// 承担「选到没有权限的群」的校验），而候选自带的投递群通常是正确的。故不渲染
/// 也不放进 patch——**未出现的键保留候选值**，语义正好是「不动它」。
///
/// ## 提交的 patch 是**增量**，不是整包替换
///
/// `applyPatternPatch` 的合并语义：出现的键覆盖候选值，未出现的保留。故只改
/// 了主题时不必回填触发配置——回填反而会把用户在别处的修改覆盖掉。
///
/// ## watch 候选的节奏不可编辑
///
/// watch（盯梢）型没有钟点，其 `cadence`/`stop` 是抽取阶段的产物。让用户手改
/// `initial_seconds`/`factor` 需要一整套校验，而白名单也没有为这些子字段提供
/// 语义。故 watch 只展示只读摘要，提交时**原样回传**候选配置（外加
/// `trigger_type: watch`）——不回传会让服务端按 time_based 重建出一条
/// 「每周一 09:00」的钟点任务，与用户意图相反。
class HabitSuggestionEditor extends StatefulWidget {
  const HabitSuggestionEditor({
    super.key,
    required this.suggestion,
    this.busy = false,
  });

  final HabitSuggestionItem suggestion;

  /// 请求在途：控件与按钮禁用，防重复提交。
  ///
  /// 由调用方传入：提交本身发生在对话框**关闭之后**（patch 经
  /// [Navigator.pop] 交回），所以「提交中」的状态属于调用方的卡片，不属于
  /// 本对话框。
  final bool busy;

  @override
  State<HabitSuggestionEditor> createState() => _HabitSuggestionEditorState();
}

/// 打开编辑器对话框，返回用户提交的 patch（取消时为 null）。
///
/// 用返回值而不是回调：关闭时机属于对话框自己的状态机（取消要关、提交要带着
/// patch 关），调用方只关心「改成了什么」。且返回值让「取消」天然不触发任何
/// 请求——回调形式下必须额外判空。
Future<Map<String, dynamic>?> showHabitSuggestionEditor(
  BuildContext context, {
  required HabitSuggestionItem suggestion,
  bool busy = false,
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => HabitSuggestionEditor(suggestion: suggestion, busy: busy),
  );
}

class _HabitSuggestionEditorState extends State<HabitSuggestionEditor> {
  /// 星期名（索引 1..7 = 周一..周日，对齐 ISO weekday 与服务端）。
  ///
  /// 索引 0 占位不用：服务端 `weekday` 是 1-based（`isoweekday`），
  /// 传 0 会被 `jsonIntSlice` 收下但引擎算不出触发时间。
  static const _weekdayNames = ['', '一', '二', '三', '四', '五', '六', '日'];

  late TextEditingController _topicKey;
  late TextEditingController _hour;
  late TextEditingController _minute;
  late TextEditingController _agentId;
  late Set<int> _weekdays;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(HabitSuggestionEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了建议（同一对话框实例被复用）时重置表单，否则会把上一条的值带过来。
    if (oldWidget.suggestion.suggestionId != widget.suggestion.suggestionId) {
      _reset();
    }
  }

  @override
  void dispose() {
    _topicKey.dispose();
    _hour.dispose();
    _minute.dispose();
    _agentId.dispose();
    super.dispose();
  }

  void _reset() {
    final s = widget.suggestion;
    final time = s.triggerConfig?.time;
    _topicKey = TextEditingController(text: s.topicKey);
    _hour = TextEditingController(
      text: (time?.firstHour ?? _defaultHour).toString(),
    );
    _minute = TextEditingController(text: (time?.firstMinute ?? 0).toString());
    _agentId = TextEditingController(text: s.preferredAgentId ?? '');
    // 空 weekdays 在服务端语义里是「每天」（见 HabitTimeTriggerConfig.summary），
    // 但**不能**把空数组提交成「每天」——服务端对空数组视为「无该键」而保留
    // 候选值。故这里把「每天」显式展开成 1..7。
    _weekdays = (time == null || time.weekdays.isEmpty)
        ? {1, 2, 3, 4, 5, 6, 7}
        : time.weekdays.where((d) => d >= 1 && d <= 7).toSet();
  }

  static const _defaultHour = 9;

  bool get _editable => widget.suggestion.canEdit;

  bool _canEditField(String field) =>
      _editable && widget.suggestion.editableFields.contains(field);

  bool get _isWatch => widget.suggestion.triggerType == HabitTriggerType.watch;

  /// 是否可以提交。
  ///
  /// 两个条件：
  /// - 服务端确实给了可编辑字段（否则提交出的 patch 是 `{}`，与「直接接受」
  ///   等价）；
  /// - 时间型至少选一天：空数组会让服务端保留候选的 weekday（静默忽略用户
  ///   操作）。这里**阻止提交并说明原因**，而不是像 webapp 那样静默回填成
  ///   `[1]`——后者会在候选本是周三时把规则悄悄改成周一。
  bool get _canSubmit {
    if (widget.busy || !_editable) return false;
    if (_canEditField('trigger_config') && !_isWatch && _weekdays.isEmpty) {
      return false;
    }
    return true;
  }

  /// 组装 patch：**只含** editableFields 里出现的键。
  Map<String, dynamic> buildPatch() {
    final patch = <String, dynamic>{};

    if (_canEditField('topic_key')) {
      patch['topic_key'] = _topicKey.text.trim();
    }

    if (_canEditField('trigger_config')) {
      if (_isWatch) {
        // 原样回传候选配置 + trigger_type（缺它会被按 time_based 重建）。
        patch['trigger_config'] = {
          ...?widget.suggestion.triggerConfig?.toJson(),
          'trigger_type': HabitTriggerType.watch.wire,
        };
      } else {
        patch['trigger_config'] = {
          // 传 times 数组（服务端 normalize 会同步顶层 hour/minute 供 SQL 查重；
          // 只传顶层 hour 也能被 applyPatternPatch 认，但 times 是前端统一形态）。
          'times': [
            {
              'hour': _clampInt(_hour.text, 0, 23, _defaultHour),
              'minute': _clampInt(_minute.text, 0, 59, 0),
            },
          ],
          // 已排序，便于服务端与日志比对。
          'weekday': _weekdays.toList()..sort(),
        };
      }
    }

    if (_canEditField('preferred_agent_id')) {
      final v = _agentId.text.trim();
      // ⚠️ 空串发 **null** 而不是 `''`：服务端把 null 解释为「清除指定 agent」，
      // 而空串会被 `strings.TrimSpace` 成空值后同样清空——两者效果相同，但
      // null 是 webapp 的既有形态，且语义更明确（见 applyPatternPatch 的注释）。
      patch['preferred_agent_id'] = v.isEmpty ? null : v;
    }

    return patch;
  }

  /// 把字符串数字约束到 [min, max]，非法值回退 [fallback]。
  ///
  /// 与 webapp 的 `clampInt` 同口径：输入框内容随时可能是空串/半截输入。
  static int _clampInt(String raw, int min, int max, int fallback) {
    final n = int.tryParse(raw.trim());
    if (n == null) return fallback;
    return n < min ? min : (n > max ? max : n);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final textTheme = Theme.of(context).textTheme;

    return AlertDialog(
      key: const ValueKey('habit-suggestion-editor'),
      title: const Text('编辑并接受'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('只提交你改过的内容，其余保持建议的原值。', style: textTheme.bodySmall),
            const SizedBox(height: SpbSpacing.md),

            if (_canEditField('topic_key')) ...[
              TextField(
                key: const ValueKey('habit-edit-topic-key'),
                controller: _topicKey,
                enabled: !widget.busy,
                decoration: const InputDecoration(
                  labelText: '习惯主题',
                  helperText: '用于标识这个习惯，如 weekly-report',
                ),
              ),
              const SizedBox(height: SpbSpacing.md),
            ],

            if (_canEditField('trigger_config'))
              if (_isWatch)
                _WatchReadOnly(cadence: s.triggerConfig?.watch)
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('habit-edit-hour'),
                        controller: _hour,
                        enabled: !widget.busy,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: '时',
                          helperText: '0-23',
                        ),
                      ),
                    ),
                    const SizedBox(width: SpbSpacing.sm),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('habit-edit-minute'),
                        controller: _minute,
                        enabled: !widget.busy,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: const InputDecoration(
                          labelText: '分',
                          helperText: '0-59',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SpbSpacing.md),
                Text('重复', style: textTheme.labelLarge),
                const SizedBox(height: SpbSpacing.xs),
                Wrap(
                  spacing: SpbSpacing.xs,
                  runSpacing: SpbSpacing.xs,
                  children: [
                    for (var day = 1; day <= 7; day++)
                      FilterChip(
                        key: ValueKey('habit-edit-weekday-$day'),
                        label: Text('周${_weekdayNames[day]}'),
                        selected: _weekdays.contains(day),
                        onSelected: widget.busy
                            ? null
                            : (on) => setState(() {
                                if (on) {
                                  _weekdays.add(day);
                                } else {
                                  _weekdays.remove(day);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: SpbSpacing.xs),
                // 空选时给出原因，而不是让用户对着一个禁用的按钮猜。
                if (_weekdays.isEmpty)
                  Text(
                    '请至少选择一天（全部取消会让服务端算不出下次触发）',
                    key: const ValueKey('habit-edit-weekday-error'),
                    style: textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: SpbSpacing.md),
              ],

            if (_canEditField('preferred_agent_id')) ...[
              TextField(
                key: const ValueKey('habit-edit-agent-id'),
                controller: _agentId,
                enabled: !widget.busy,
                decoration: const InputDecoration(
                  labelText: '指定 Agent',
                  helperText: '留空表示不指定（由路由自行选择）',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('habit-edit-cancel'),
          onPressed: widget.busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('habit-edit-submit'),
          onPressed: _canSubmit
              ? () => Navigator.of(context).pop(buildPatch())
              : null,
          child: widget.busy
              ? const SizedBox(
                  width: SpbSpacing.lg,
                  height: SpbSpacing.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存并接受'),
        ),
      ],
    );
  }
}

/// watch 候选的只读节奏说明。
///
/// 为什么不给输入框：`initial_seconds` / `factor` / `max_seconds` 不在
/// `editable_fields` 里，且手改它们需要一整套校验（factor 必须 > 1、
/// max ≥ initial 等）。展示清楚「它是什么节奏」比给一个会被忽略的输入框有用。
class _WatchReadOnly extends StatelessWidget {
  const _WatchReadOnly({required this.cadence});

  final HabitWatchTriggerConfig? cadence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final c = cadence ?? const HabitWatchTriggerConfig();
    return Container(
      key: const ValueKey('habit-edit-watch-readonly'),
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.visibility_outlined, size: SpbSpacing.lg),
              const SizedBox(width: SpbSpacing.xs),
              Text('盯梢型：按节奏反复检查', style: textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: SpbSpacing.xs),
          Text(c.summary, style: textTheme.bodySmall),
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            '节奏由系统根据历史抽取，暂不支持手动调整。',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
