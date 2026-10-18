import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';

/// 编辑规则时的**增量补丁**。
///
/// ## 为什么是「只含改动字段」而不是一份完整快照
///
/// 服务端 `PATCH /api/habits/:pattern_id`（`habits_full.go` 的 `update`）以**现值
/// 为合并基准**，只覆盖请求里**真正出现**的字段。把未改动的字段也发过去有两个
/// 害处：
/// - `trigger_config` 一旦出现，服务端会**重算 `next_fire_at`**（按新配置推到
///   下一个周期）——只想改个名字却顺手把本次即将到期的触发推走了；
/// - `acceptance_level` 等服务端有默认值的字段被回写一遍，语义上多了一次
///   无意义的写。
///
/// 故本类用可空字段表示「未改动」，只有非 null 的才进请求体。
class HabitPatch {
  const HabitPatch({
    this.topicKey,
    this.acceptanceLevel,
    this.triggerConfig,
    this.preferredAgentId,
  });

  /// 新主题。服务端会 `TrimSpace` 并拒绝空串（400 `topic_key 无效`）。
  final String? topicKey;

  final HabitAcceptanceLevel? acceptanceLevel;

  /// 新的触发配置。非 null 即视为「已改动」——服务端据此重算下次触发时刻。
  final HabitTriggerConfig? triggerConfig;

  /// 新的优先 agent。
  ///
  /// ⚠️ **空串是「清除」，不是「未改动」**。服务端用 `json.RawMessage` 三态区分
  /// （nil=未传、`null`=清除、`"x"`=设置），而 `toNullString("")` 会把空串归成
  /// 「无效」——故空串与 `null` 等价，都是清除。未改动用 `null` 表示。
  final String? preferredAgentId;

  /// 是否一个字段都没改（调用方据此禁用保存按钮）。
  bool get isEmpty =>
      topicKey == null &&
      acceptanceLevel == null &&
      triggerConfig == null &&
      preferredAgentId == null;
}

/// 编辑既有习惯规则。
///
/// ## 为什么不复用 [HabitEditorDialog]（新建）
///
/// 两者的**数据流方向相反**：新建从空草稿构造一份完整配置；编辑要先从既有规则
/// 回填、再算出增量补丁。硬塞进一个类会让它同时持有「新建态 / 编辑态」两套默认
/// 值与两套提交逻辑——而新建那套的默认值（9:00、suggest_only）在编辑态下是**错的**
/// （会把用户既有的配置悄悄改成默认值）。
///
/// ## 哪些字段可编辑，由服务端决定
///
/// | 字段 | 可编辑 | 理由 |
/// |---|---|---|
/// | `topic_key` | ✅ | `update` 接受并做非空校验 |
/// | `acceptance_level` | ✅ | 同上，且枚举受服务端白名单约束 |
/// | `preferred_agent_id` | ✅ | 三态（设置 / 清除 / 不动） |
/// | `trigger_config`（时间型） | ✅ | 服务端按 pattern 的 `trigger_type` 分派重算 |
/// | `trigger_config`（盯梢型） | ❌ | 见下 |
///
/// ## 为什么盯梢型只读
///
/// `update` 重算 `next_fire_at` 时用的是**库里 pattern 的 `trigger_type`**
/// （`nextFireAtForPattern(pattern.TriggerType, cfgJSON)`），而不是请求里新配置
/// 的类型。若给一条 watch 规则提交 time_based 形状的 `trigger_config`，服务端会
/// 按 watch 口径去解 `cadence.initial_seconds`（不存在）→ 得到零值排程。
/// 类型本身也没有可改的入口（`update` 不接收 `trigger_type`）。
///
/// 故盯梢型规则的触发条件**只展示只读摘要**，不允许就地改。
class HabitEditDialog extends StatefulWidget {
  const HabitEditDialog({super.key, required this.habit});

  final UserHabit habit;

  /// 弹出编辑框。返回 null 表示用户取消。
  static Future<HabitPatch?> show(
    BuildContext context, {
    required UserHabit habit,
  }) => showDialog<HabitPatch>(
    context: context,
    builder: (_) => HabitEditDialog(habit: habit),
  );

  @override
  State<HabitEditDialog> createState() => _HabitEditDialogState();
}

class _HabitEditDialogState extends State<HabitEditDialog> {
  late final TextEditingController _topicController;
  late final TextEditingController _agentController;
  late HabitAcceptanceLevel _level;
  late TimeOfDay _time;

  /// 星期（1=周一 … 7=周日）。空 = 每天。
  late Set<int> _weekdays;

  /// 原始值快照（用于算增量补丁）。
  late final String _originTopic;
  late final HabitAcceptanceLevel _originLevel;
  late final String _originAgent;
  late final HabitTimeTriggerConfig? _originTime;

  /// 盯梢型：触发条件不可编辑（见类文档）。
  bool get _isWatch => widget.habit.triggerType == HabitTriggerType.watch;

  @override
  void initState() {
    super.initState();
    final h = widget.habit;
    _originTopic = h.topicKey;
    _originLevel = h.acceptanceLevel;
    _originAgent = h.preferredAgentId ?? '';
    _originTime = h.triggerConfig.time;

    _topicController = TextEditingController(text: h.topicKey);
    _agentController = TextEditingController(text: h.preferredAgentId ?? '');
    // `unknown` 不是合法提交值（服务端白名单只有三个），回退到服务端默认。
    _level = h.acceptanceLevel == HabitAcceptanceLevel.unknown
        ? HabitAcceptanceLevel.suggestOnly
        : h.acceptanceLevel;

    final t = h.triggerConfig.time;
    // 回填既有触发时刻；缺失时用 9:00（与新建对话框同默认）。
    _time = TimeOfDay(hour: t?.firstHour ?? 9, minute: t?.firstMinute ?? 0);
    _weekdays = {...?t?.weekdays};
  }

  @override
  void dispose() {
    _topicController.dispose();
    _agentController.dispose();
    super.dispose();
  }

  /// 算出增量补丁（**public 供测试读**，与 `HabitSuggestionEditor.buildPatch` 同做法）。
  HabitPatch buildPatch() {
    final topic = _topicController.text.trim();
    final agent = _agentController.text.trim();
    return HabitPatch(
      // 空主题不算改动：服务端会 400，让按钮禁用而不是提交后报错。
      topicKey: (topic.isNotEmpty && topic != _originTopic) ? topic : null,
      acceptanceLevel: _level != _originLevel ? _level : null,
      triggerConfig: _triggerConfigChanged() ? _buildTriggerConfig() : null,
      preferredAgentId: agent != _originAgent ? agent : null,
    );
  }

  bool _triggerConfigChanged() {
    if (_isWatch) return false;
    final origin = _originTime;
    if (origin == null) {
      // 原来没有时间配置：只要用户动了时间/星期，就算改动。
      return true;
    }
    if (_time.hour != (origin.firstHour ?? 9) ||
        _time.minute != (origin.firstMinute ?? 0)) {
      return true;
    }
    final a = _weekdays.toList()..sort();
    final b = origin.weekdays.toList()..sort();
    if (a.length != b.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return true;
    }
    return false;
  }

  /// 构造提交用的触发配置。
  ///
  /// 只填 `times`（服务端会据它同步顶层 hour/minute 影子字段）与排序后的
  /// `weekday`——与 `HabitEditorDialog` 新建时同一形状，避免两条路径产出的
  /// 配置在服务端归一化时走不同分支。
  HabitTriggerConfig _buildTriggerConfig() => HabitTriggerConfig(
    triggerType: HabitTriggerType.timeBased,
    time: HabitTimeTriggerConfig(
      times: [HabitTimeOfDay(hour: _time.hour, minute: _time.minute)],
      weekdays: _weekdays.toList()..sort(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final patch = buildPatch();
    // 主题为空是硬错误（服务端 400），其余情况「没改动」则没什么可提交。
    final canSubmit = _topicController.text.trim().isNotEmpty && !patch.isEmpty;

    return AlertDialog(
      key: const ValueKey('habit-edit-dialog'),
      title: const Text('编辑习惯'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('habit-edit-topic'),
              controller: _topicController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '主题',
                helperText: '如 weekly-report、preference.coffee',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: SpbSpacing.lg),
            Text('执行方式', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: SpbSpacing.xs),
            // RadioListTile.groupValue / onChanged 在 Flutter 3.32 起已弃用，
            // 改由祖先 RadioGroup 统一持有选中值与回调（与新建对话框一致）。
            RadioGroup<HabitAcceptanceLevel>(
              groupValue: _level,
              onChanged: (v) => setState(() => _level = v ?? _level),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final l in HabitAcceptanceLevel.values)
                    if (l != HabitAcceptanceLevel.unknown)
                      RadioListTile<HabitAcceptanceLevel>(
                        key: ValueKey('habit-edit-level-${l.wire}'),
                        value: l,
                        title: Text(l.label),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                ],
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            if (_isWatch)
              _WatchReadOnly(summary: widget.habit.triggerConfig.summary)
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '触发时间',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('habit-edit-time'),
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: _time,
                      );
                      if (picked != null && mounted) {
                        setState(() => _time = picked);
                      }
                    },
                    child: Text(_time.format(context)),
                  ),
                ],
              ),
              const SizedBox(height: SpbSpacing.xs),
              Text(
                '重复（不选 = 每天）',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: SpbSpacing.xs),
              Wrap(
                spacing: SpbSpacing.xs,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      key: ValueKey('habit-edit-weekday-$d'),
                      label: Text(
                        const ['一', '二', '三', '四', '五', '六', '日'][d - 1],
                      ),
                      selected: _weekdays.contains(d),
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _weekdays.add(d);
                        } else {
                          _weekdays.remove(d);
                        }
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: SpbSpacing.lg),
            TextField(
              key: const ValueKey('habit-edit-agent'),
              controller: _agentController,
              decoration: const InputDecoration(
                labelText: '优先 Agent（可选）',
                helperText: '留空 = 走默认路由',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('habit-edit-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('habit-edit-save'),
          onPressed: canSubmit ? () => Navigator.of(context).pop(patch) : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 盯梢型触发条件的只读展示（见 [HabitEditDialog] 类文档）。
class _WatchReadOnly extends StatelessWidget {
  const _WatchReadOnly({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('habit-edit-watch-readonly'),
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('触发节奏（不可编辑）', style: textTheme.labelLarge),
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            summary,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            '盯梢型规则的间隔由指数退避策略维护，服务端不接收就地修改。',
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
