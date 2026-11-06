import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_ui/spb_ui.dart';

/// 保存目标文本（空串 = 清除目标）。
typedef SaveGroupGoal = Future<void> Function(String goalText);

/// 开关「自动实现目标」。
typedef ToggleGroupGoalGate = Future<void> Function(bool enabled);

/// 保存最大自动轮次（调用方收到的值已 clamp 到 1..200）。
typedef SaveGroupMaxAutoTurns = Future<void> Function(int maxAutoTurns);

/// 重新生成对话标题（Go `210db5f3`：重置 title_generated 标记 + 标题回占位
/// 符，下一轮 turn 成功后 Title Gate 自动重新起名）。为 null 时不渲染入口。
typedef RegenerateGroupTitle = Future<void> Function();

// ⚠️ 群级「后续提问建议」/「习惯建议」开关（onToggleFollowUpSuggest /
// onToggleHabitSuggest）已随服务端重构移除（2026-11，Go `452cc432` /
// `47e9950e`）：两个 reminder 的准入迁到 `/me/preferences` 的个人运行时开关
// （个人偏好卡的「对话提醒开关」区块），不再是对话级设置。勿在此处重新接入
// 同名参数——服务端端点已不存在，接入即 404。

/// 保存语音回复配置。
///
/// ## 为什么是「可空字段」而不是一个完整的配置对象
///
/// 服务端 `PUT /chat/groups/:id/tts` **只应用提交的键**：只传子开关时不动总开关，
/// 传 `enabled: false` 时整块删除 `metadata.tts`。若这里固定提交一份完整配置
/// （像 webapp 那样 `{...config, ...patch}`），「只改思考播报」就会连带把总开关
/// 一起写一遍——在并发场景（另一台设备刚关了总开关）下会把对方的改动回滚。
///
/// 故本面板**只发变化的那一个键**，由调用方原样透传给 `ChatApi.setGroupTts`。
typedef SaveGroupTts = Future<void> Function({
  bool? enabled,
  bool? narrateThinking,
  String? narrationMode,
  bool? fileSummary,
});

/// 最大自动轮次的可调范围（与服务端 `chatgate/goal_gate_config.go` 的
/// `clampAnyInt(gate["max_auto_turns"], 20, 1, 200)` 及 webapp 常量一致）。
const int kMinMaxAutoTurns = 1;
const int kMaxMaxAutoTurns = 200;

/// 群设置面板：目标 + 三个 group 级 CAS 开关。
///
/// ## 它解决什么
///
/// 这三组配置在服务端是**专用 PUT 端点**（`chat_ext.go:83-89`）：
/// - `PUT /chat/groups/:gid/goal-gate`（`enabled` / `max_auto_turns`）
/// - `PUT /chat/groups/:gid/follow-up-suggest`
/// - `PUT /chat/groups/:gid/tts`
///
/// 在此之前客户端一个都没有入口，于是「自动实现目标」「后续提问建议」「语音回复」
/// 在 webapp 可达、在本客户端不可达——同一后端能力一端有、另一端没有。
///
/// ## 为什么不能走 `PATCH /chat/groups/:id` 的 metadata 通道
///
/// PATCH 是**整包替换**语义：只提交 `{goal_gate}` 会连带清掉 `metadata.tts` 等
/// 其它子系统写入的键（webapp 的历史 bug）。专用端点服务端做 CAS 读-改-写，
/// 既保留其它键，也不与 goal gate worker / 另一台设备等并发写者互相覆盖。
///
/// ## 为什么是注入式（不碰 spb_api）
///
/// 与 [GroupDeliverablesPanel] / [GroupGatePanel] 同一约定：页面只渲染 + 收集
/// 意图，HTTP 由 app 装配层注入。故可在无头环境用内存桩完整验证——本面板的
/// 全部交互（禁用态、clamp、子开关联动）都不需要 HTTP mock。
///
/// ## 为什么读值走 [ChatGroup] 的 getter 而不是面板自己解析 metadata
///
/// 键缺失 = 关闭、总开关关闭时子开关归零、`goal_gate` 需 `enabled &&
/// continue_until_done` 才算生效——这些口径分散在多个调用点就会漂移。集中到
/// `ChatGroup` 的只读 getter 后，面板与将来的其它入口共用同一份解析。
///
/// ## 为什么是 StatefulWidget
///
/// 两个输入框（目标文本、最大轮次）是**草稿**：用户可能改到一半就去点别的开关，
/// 此时不能把草稿丢掉、也不能自动提交。草稿与权威值分开放，只在
/// [didUpdateWidget] 看到权威值变化时（写成功后的 reload）才重新对齐。
class GroupSettingsPanel extends StatefulWidget {
  const GroupSettingsPanel({
    super.key,
    required this.group,
    required this.onSaveGoal,
    this.onToggleGoalGate,
    this.onSaveMaxAutoTurns,
    this.onSaveTts,
    this.onRegenerateTitle,
    this.busy = false,
    this.showHeader = true,
  });

  /// 当前 group（**权威**状态；写操作成功后由 app 层用 `getGroup` 的结果替换）。
  final ChatGroup group;

  final SaveGroupGoal onSaveGoal;

  /// 为 null 时对应开关不渲染（侧边栏退化为只读/部分可用）。
  final ToggleGroupGoalGate? onToggleGoalGate;
  final SaveGroupMaxAutoTurns? onSaveMaxAutoTurns;
  final SaveGroupTts? onSaveTts;

  /// 重新生成标题入口。为 null 时**整个区块不渲染**（同其它可选回调：
  /// 不渲染而不是禁用）。
  final RegenerateGroupTitle? onRegenerateTitle;

  /// 是否有写操作在途。为 true 时全部控件禁用（防止并发提交把 CAS 打成 409）。
  final bool busy;

  /// 是否渲染自带标题行。作为 tab 内容时通常由 tab 标签承担标题，传 false。
  final bool showHeader;

  @override
  State<GroupSettingsPanel> createState() => _GroupSettingsPanelState();
}

class _GroupSettingsPanelState extends State<GroupSettingsPanel> {
  late final TextEditingController _goal;
  late final TextEditingController _maxTurns;

  @override
  void initState() {
    super.initState();
    _goal = TextEditingController(text: widget.group.currentGoalText);
    _maxTurns = TextEditingController(
      text: '${widget.group.goalGateMaxAutoTurns}',
    );
  }

  @override
  void didUpdateWidget(GroupSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只在**权威值真的变了**时对齐草稿。
    //
    // ## 为什么不能无条件 setState(controller.text = ...)
    //
    // 写成功后 app 层会用 getGroup 的结果替换 group，此时权威值变化 → 对齐是
    // 对的。但父层每次 build 都可能传一个新对象进来（例如 busy 翻转触发的
    // rebuild 顺带重建了 group 包装），无条件覆盖会把用户正在输入的草稿冲掉。
    final goal = widget.group.currentGoalText;
    if (goal != oldWidget.group.currentGoalText && goal != _goal.text) {
      _goal.text = goal;
    }
    final turns = widget.group.goalGateMaxAutoTurns;
    if (turns != oldWidget.group.goalGateMaxAutoTurns &&
        '$turns' != _maxTurns.text) {
      _maxTurns.text = '$turns';
    }
  }

  @override
  void dispose() {
    _goal.dispose();
    _maxTurns.dispose();
    super.dispose();
  }

  /// 目标是否已在服务端存在。
  ///
  /// 用**权威值**而非草稿：用户刚在输入框里打了字但还没保存时，服务端仍然没有
  /// 目标，此时开启 goal gate 必然 400 `goal_required`。故草稿不算数。
  bool get _hasGoal => widget.group.currentGoalText.isNotEmpty;

  bool get _busy => widget.busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      key: const ValueKey('group-settings-panel'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.sm),
      children: [
        if (widget.showHeader) _title(context),
        _titleSection(context),
        const Divider(height: SpbSpacing.lg),
        _goalSection(context),
        const Divider(height: SpbSpacing.lg),
        _goalGateSection(context, theme),
        const Divider(height: SpbSpacing.lg),
        _ttsSection(context, theme),
        // 对话 ID：**放在最后**——它是低频的调试/报障信息，不该把常用设置
        // 挤到更下面。id 为空（占位 group、列表事件快照缺字段）时整节省略，
        // 渲染一行空白 + 一个复制空串的按钮比不渲染更糟。
        if (widget.group.id.isNotEmpty) ...[
          const Divider(height: SpbSpacing.lg),
          _idSection(context, theme),
        ],
      ],
    );
  }

  Widget _title(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpbSpacing.md,
        0,
        SpbSpacing.md,
        SpbSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(
            Icons.tune,
            size: SpbSpacing.lg,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Text('对话设置', style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }

  // ==================== 标题 ====================

  /// 标题区块：重新生成入口（Go `210db5f3`）。
  ///
  /// 只在装配层注入 [GroupSettingsPanel.onRegenerateTitle] 时渲染。
  /// 手动改名走列表菜单（`RenameGroup`），会打 title_generated 标记
  /// （gate 永不覆盖）；这里是另一条路：**放弃自动标题、让它重新起**。
  /// 两者语义不同，不能互替。
  Widget _titleSection(BuildContext context) {
    final cb = widget.onRegenerateTitle;
    if (cb == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return _section(
      context,
      children: [
        _label(context, '标题'),
        const SizedBox(height: SpbSpacing.xxs),
        Text(
          '自动起的标题不满意？重置后，下一轮对话完成时会重新生成。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SpbSpacing.xs),
        OutlinedButton(
          key: const ValueKey('group-title-regenerate'),
          onPressed: _busy ? null : cb,
          child: const Text('重新生成标题'),
        ),
      ],
    );
  }

  // ==================== 目标 ====================

  Widget _goalSection(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _goal.text.trim();
    final changed = draft != widget.group.currentGoalText.trim();

    return _section(
      context,
      children: [
        _label(context, '目标'),
        const SizedBox(height: SpbSpacing.xs),
        TextField(
          key: const ValueKey('group-goal-field'),
          controller: _goal,
          enabled: !_busy,
          maxLines: 3,
          minLines: 2,
          textInputAction: TextInputAction.newline,
          // 草稿变化要重建（保存按钮的可用态依赖它），但不提交任何请求。
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            hintText: '描述这个对话当前要完成的目标',
            border: OutlineInputBorder(borderRadius: SpbRadius.inputAll),
            isDense: true,
          ),
        ),
        const SizedBox(height: SpbSpacing.xxs),
        Text(
          '清空后保存即清除目标（旧目标会归档保留，其任务不受影响）',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SpbSpacing.xs),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            key: const ValueKey('group-goal-save'),
            // 文本没变时禁用：避免双击留下一串内容相同的 goal 版本
            // （「goal 变更 = 新建行」语义下旧行只能归档，不可逆）。
            onPressed: (!changed || _busy)
                ? null
                : () => widget.onSaveGoal(draft),
            child: const Text('保存'),
          ),
        ),
      ],
    );
  }

  // ==================== 自动实现目标 ====================

  Widget _goalGateSection(BuildContext context, ThemeData theme) {
    final onToggle = widget.onToggleGoalGate;
    final onSaveTurns = widget.onSaveMaxAutoTurns;
    if (onToggle == null && onSaveTurns == null) {
      return const SizedBox.shrink();
    }

    final enabled = widget.group.goalGateEnabled;
    // 无目标时**本地禁用**开关：服务端 enable 时会校验非空 goal，
    // 空则 400 goal_required。让用户点一个必然失败的开关是坏交互。
    final canToggle = _hasGoal && !_busy;

    return _section(
      context,
      children: [
        _switchRow(
          key: const ValueKey('group-goal-gate-switch'),
          title: '自动实现目标',
          subtitle: '开启后，Agent 会持续自动续跑直到目标达成',
          value: enabled,
          onChanged: (onToggle == null || !canToggle) ? null : onToggle,
        ),
        if (!_hasGoal)
          _hint(
            context,
            '请先设置目标',
            key: const ValueKey('group-goal-gate-needs-goal'),
          ),
        if (onSaveTurns != null) ...[
          const SizedBox(height: SpbSpacing.xs),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('group-max-turns-field'),
                  controller: _maxTurns,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _submitMaxTurns(),
                  decoration: const InputDecoration(
                    labelText: '最大自动轮次（$kMinMaxAutoTurns-$kMaxMaxAutoTurns）',
                    border: OutlineInputBorder(
                      borderRadius: SpbRadius.inputAll,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: SpbSpacing.xs),
              TextButton(
                key: const ValueKey('group-max-turns-save'),
                onPressed: _busy ? null : _submitMaxTurns,
                child: const Text('保存'),
              ),
            ],
          ),
          _hint(context, '达到上限后自动续跑暂停，发一条新消息即可恢复'),
        ],
      ],
    );
  }

  /// 提交最大轮次：本地 clamp 到 `1..200`。
  ///
  /// ## 为什么要本地 clamp（服务端也会 clamp）
  ///
  /// 服务端对越界值是**夹取而非报错**，所以不 clamp 也不会失败——但会让「用户
  /// 输入 0，界面显示 0，服务端存 1」这种不一致残留下来，用户下次看到的是 1，
  /// 却记得自己填过 0。本地夹取后再发，界面与服务端始终一致。
  ///
  /// 非法输入（空串、纯符号——后者已被 inputFormatter 拦掉）回退到当前生效值。
  void _submitMaxTurns() {
    final parsed = int.tryParse(_maxTurns.text.trim());
    final clamped = parsed == null
        ? widget.group.goalGateMaxAutoTurns
        : parsed.clamp(kMinMaxAutoTurns, kMaxMaxAutoTurns);
    _maxTurns.text = '$clamped';
    if (clamped == widget.group.goalGateMaxAutoTurns) return;
    widget.onSaveMaxAutoTurns?.call(clamped);
  }

  // ==================== 语音回复 ====================

  // 「后续提问建议」与「习惯建议」两个区块已随群级开关端点移除（2026-11）：
  // 准入迁到个人偏好（`/me/preferences` 运行时开关），此处不再渲染。

  Widget _ttsSection(BuildContext context, ThemeData theme) {
    final onSave = widget.onSaveTts;
    if (onSave == null) return const SizedBox.shrink();

    final enabled = widget.group.ttsEnabled;

    return _section(
      context,
      children: [
        _switchRow(
          key: const ValueKey('group-tts-switch'),
          title: '语音回复',
          subtitle: '把 Agent 的文本回复合成为语音',
          value: enabled,
          // 只发 `enabled`：服务端负责「关闭时整块删除 metadata.tts」的删除语义。
          onChanged: _busy ? null : (v) => onSave(enabled: v),
        ),
        // 子开关只在总开关开启时可用：未开启语音回复时它们是无效配置。
        // 用「禁用并置灰」而非「隐藏」——用户能看到有哪些能力，也不会因为
        // 开关消失而以为界面出错（与 AppBar 停止按钮同一取舍）。
        _switchRow(
          key: const ValueKey('group-tts-narrate-switch'),
          title: '思考阶段播报',
          subtitle: '模型思考较久时先播一句进展，避免等待期间静默',
          value: widget.group.ttsNarrateThinking,
          enabled: enabled,
          onChanged: _busy ? null : (v) => onSave(narrateThinking: v),
        ),
        Padding(
          padding: const EdgeInsets.only(
            left: SpbSpacing.md,
            top: SpbSpacing.xxs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '播报内容',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: enabled && widget.group.ttsNarrateThinking
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 模式只在「思考播报已开启」时可选：服务端对只传 narration_mode
              // 的请求，仅在 narrate_thinking 已开启时才写入（否则会留下
              // narrate_thinking 缺失但 narration_mode 存在的畸形配置）。
              SegmentedButton<String>(
                key: const ValueKey('group-tts-mode'),
                segments: const [
                  ButtonSegment(value: 'filler', label: Text('固定短句')),
                  ButtonSegment(value: 'summary', label: Text('中文摘要')),
                ],
                selected: {widget.group.ttsNarrationMode},
                showSelectedIcon: false,
                onSelectionChanged:
                    (_busy || !enabled || !widget.group.ttsNarrateThinking)
                    ? null
                    : (sel) => onSave(narrationMode: sel.first),
              ),
            ],
          ),
        ),
        _switchRow(
          key: const ValueKey('group-tts-file-switch'),
          title: '文件产出播报',
          subtitle: 'Agent 生成文档（Markdown / 网页 / PDF 等）时播报到件通知',
          value: widget.group.ttsFileSummary,
          enabled: enabled,
          onChanged: _busy ? null : (v) => onSave(fileSummary: v),
        ),
        _hint(context, '思考播报与文件播报还需服务端已启用对应能力才会生效'),
      ],
    );
  }

  // ==================== 对话 ID ====================

  /// 对话 ID 行：可读 + 可选中 + 一键复制。
  ///
  /// ## 为什么需要它
  ///
  /// `group_id` 是**唯一能把客户端现象与服务端对上号**的标识：日志里
  /// （`对话历史回填完成 groupId=…`）、导出诊断报告的「时间线快照」小节、
  /// 服务端 slog 字段、UFS 工作区路径 `/workspace/groups/{gid}/` 全都用它。
  /// 但它在本客户端此前**任何界面都不显示**——用户报障时只能口述「那个对话」，
  /// 开发者要拿 id 只能去翻本地 `app.log`。
  ///
  /// ## 为什么放这里（而不是列表页 / AppBar / 新的调试面板）
  ///
  /// - 面板已经持有**权威** [ChatGroup]（`group.id`），不需要新回调、不需要新
  ///   provider，两端 router 现有的接线就能带出来——于是也没有 §6.17「两端接线
  ///   不一致」的失败面。
  /// - 原 `GroupDebugPanel` 已删（§6.54），不要为一条只读文本重开一个面板。
  ///
  /// ## 为什么复制 + 可选中两者都给
  ///
  /// id 是长随机串：截断显示下「选中复制」容易漏字符，故给显式复制按钮；
  /// 但 `SelectableText` 保留——只想肉眼核对前缀的人不该被迫点按钮。
  /// 复制走 [CopyIconButton]（纯剪贴板，不发请求），不新增注入参数。
  Widget _idSection(BuildContext context, ThemeData theme) {
    return _section(
      context,
      children: [
        _label(context, '对话 ID'),
        const SizedBox(height: SpbSpacing.xxs),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                key: const ValueKey('group-id-value'),
                widget.group.id,
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: SpbSpacing.xxs),
            CopyIconButton(
              key: const ValueKey('group-id-copy'),
              text: widget.group.id,
              tooltip: '复制对话 ID',
            ),
          ],
        ),
        _hint(context, '报障或对照服务端日志时用这个 ID'),
      ],
    );
  }

  // ==================== 通用小部件 ====================

  Widget _section(BuildContext context, {required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _label(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _switchRow({
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
    bool enabled = true,
  }) {
    return SwitchListTile(
      key: key,
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: value,
      // `enabled: false` 时即使 onChanged 非空也要禁用（总开关关闭 → 子开关
      // 不可操作）。两件事分开表达：`enabled` 是「这项配置当前是否有效」，
      // `onChanged == null` 是「本端没有接这个动作」。
      onChanged: enabled ? onChanged : null,
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _hint(BuildContext context, String text, {Key? key}) {
    final theme = Theme.of(context);
    return Padding(
      key: key,
      padding: const EdgeInsets.only(
        left: SpbSpacing.md,
        top: SpbSpacing.xxs,
        bottom: SpbSpacing.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: SpbSpacing.md + 2,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: SpbSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 群设置面板的加载态 / 失败态。
///
/// ## 为什么需要它（不能只用 `CircularProgressIndicator`）
///
/// 拉取 `GET /chat/groups/:id` 失败时若仍渲染进度指示器，用户看到的是
/// **永不结束的转圈**——既不知道出了问题，也没法重试。且无限动画会让
/// `pumpAndSettle` 永不收敛（测试超时、真实环境持续重绘耗电）。
///
/// 故失败时渲染原因 + 重试按钮；成功前才转圈。
class GroupSettingsLoading extends StatelessWidget {
  const GroupSettingsLoading({super.key, this.error, this.onRetry});

  /// 加载失败原因（可直接展示）。为 null 表示正在加载。
  final String? error;

  /// 重试回调。为 null 时失败态不显示重试按钮。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = error;
    if (message == null) {
      return const Center(
        key: ValueKey('group-settings-loading'),
        child: CircularProgressIndicator(),
      );
    }
    return Center(
      key: const ValueKey('group-settings-error'),
      child: Padding(
        padding: const EdgeInsets.all(SpbSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.error,
              size: SpbSpacing.xl,
            ),
            const SizedBox(height: SpbSpacing.sm),
            Text(
              '读取对话设置失败',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SpbSpacing.xs),
            Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: SpbSpacing.md),
              OutlinedButton.icon(
                key: const ValueKey('group-settings-retry'),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: SpbSpacing.lg),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
