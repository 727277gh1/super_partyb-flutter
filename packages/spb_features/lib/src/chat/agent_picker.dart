import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// Agent 搜索弹层（大列表用，见 `AgentSwitcher` 的类文档）。
///
/// ## 为什么是独立的 widget 而不是 `PopupMenuButton` 的扩展
///
/// `PopupMenuButton.itemBuilder` 只能返回 `List<PopupMenuEntry>`，而过滤需要
/// 一个 `TextField` 与「输入变化时重建列表」的能力——那必须有 State。
///
/// ## 为什么键盘可达性是必须的（桌面端）
///
/// 用户从 AppBar 打开时手已经在键盘上（`Alt+Space` 悬浮窗那条链路的用户尤其
/// 如此）。故：输入框自动聚焦、↑↓ 移动高亮、Enter 选中、Esc 关闭（Dialog
/// 自带）。
///
/// ## 为什么保留分组（而不是只给一个平铺的过滤结果）
///
/// 搜索是「找不到时」的手段，分组是「浏览时」的结构，两者不互相替代。用户
/// 打开弹层后可能先看一眼分组，再决定搜什么。分组/过滤的判据都在
/// `spb_domain` 的 `groupAgents` / `filterAgentGroups`（纯逻辑，可无头单测）。
///
/// ## 为什么首行是「自动路由」
///
/// webapp 的 `AgentSelector.tsx` 与小程序的 `work-detail` 抽屉都把「自动路由」
/// 放在列表首项（`selectedAgentId === null`），它是**唯一能把本地选择清回去**
/// 的入口：选过某个 agent 之后，服务端绑定不会自动回退，只有清成 null 才会
/// 让下一条消息重新走 `auto_agent` 匹配（`routing.mode=auto`）。缺了它，用户
/// 一旦手选过就再也回不到自动路由。
class AgentPickerDialog extends StatefulWidget {
  const AgentPickerDialog({
    super.key,
    required this.groups,
    this.currentAgentId,
  });

  /// 已分组的完整列表（过滤在内部做，调用方不需预先过滤）。
  final List<AgentGroup> groups;

  /// 当前绑定的 agent。它在列表里**不可选**（见 [_submit]）。
  ///
  /// 为 null 表示「当前就是自动路由」，此时首行那一项同样不可选。
  final String? currentAgentId;

  @override
  State<AgentPickerDialog> createState() => _AgentPickerDialogState();
}

class _AgentPickerDialogState extends State<AgentPickerDialog> {
  final _controller = TextEditingController();
  late List<AgentGroup> _filtered = widget.groups;

  /// 键盘高亮的**平铺**序号（-1 = 无）。
  ///
  /// 用平铺序号而非 agent id：上下移动要跨组，按 id 查位置每次都得遍历。
  int _highlighted = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 过滤后的平铺行（键盘导航与渲染共用同一顺序）。
  ///
  /// 首位恒为 `null`，代表「自动路由」那一行——它不是 agent，但同样是可选
  /// 目标，放进同一序列才能让 ↑↓/Enter 一致地走到它（见 [_submit]）。
  List<Agent?> get _flat => [null, for (final g in _filtered) ...g.agents];

  void _onChanged(String value) {
    setState(() {
      _filtered = filterAgentGroups(widget.groups, value);
      // 过滤后旧高亮可能越界，或指向了**另一个** agent——直接清掉。
      // 保留一个「跳到了别的 agent」的高亮比没有高亮更危险：Enter 会切到
      // 用户没在看的那一个。
      _highlighted = -1;
    });
  }

  void _move(int delta) {
    final flat = _flat;
    if (flat.isEmpty) return;
    setState(() {
      if (_highlighted < 0) {
        _highlighted = delta > 0 ? 0 : flat.length - 1;
      } else {
        _highlighted = (_highlighted + delta).clamp(0, flat.length - 1);
      }
    });
  }

  void _submitHighlighted() {
    final flat = _flat;
    if (_highlighted < 0 || _highlighted >= flat.length) return;
    _submit(flat[_highlighted]);
  }

  void _submit(Agent? agent) {
    // 自动路由：null 在这里是**选中项**，不是「取消」——取消由 `Navigator.pop`
    // 不传值表达（调用方收到 null 结果即视为取消，见 [AgentPick]）。
    if (agent == null) {
      if (widget.currentAgentId == null) return;
      Navigator.of(context).pop(const AgentPick.auto());
      return;
    }
    // 当前 agent 不可选。选择是纯本地的（见 `AgentSwitcher` 的类文档），故
    // 「选同一个」不会有任何变化——留着可点只会让用户怀疑「点了没反应」。
    if (agent.id == widget.currentAgentId) return;
    Navigator.of(context).pop(AgentPick.agent(agent.id));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submitHighlighted();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flat = _flat;
    // 0 已被「自动路由」占用，agent 行从 1 开始。
    var flatIndex = 1;

    return Dialog(
      key: const ValueKey('agent-picker'),
      child: ConstrainedBox(
        // 桌面窗口可能很矮（1080p @150% 缩放后工作区仅 680dp，见 AGENTS.md
        // §6.45），故用 maxHeight 而非固定高度。
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: Focus(
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SpbSpacing.md,
                  SpbSpacing.md,
                  SpbSpacing.md,
                  SpbSpacing.sm,
                ),
                child: TextField(
                  key: const ValueKey('agent-picker-search'),
                  controller: _controller,
                  autofocus: true,
                  onChanged: _onChanged,
                  decoration: const InputDecoration(
                    hintText: '搜索 Agent（名称 / 描述 / 标签）',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: SpbSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择后随下一条消息生效（沿用当前对话上下文）',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      // 只数 agent：自动路由不是一个「匹配结果」。
                      '${flat.length - 1}',
                      key: const ValueKey('agent-picker-count'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: SpbSpacing.md),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // 首行恒在：即使过滤结果为空，用户也要能把选择清回自动
                    // 路由（否则搜不到东西时唯一出路是关掉弹层）。
                    _row(
                      context,
                      key: const ValueKey('agent-option-auto'),
                      icon: Icons.auto_awesome_outlined,
                      label: '自动路由',
                      subtitle: '由平台按消息内容挑执行者',
                      index: 0,
                      isCurrent: widget.currentAgentId == null,
                      onTap: () => _submit(null),
                    ),
                    if (_filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(SpbSpacing.xl),
                        child: Text(
                          '没有匹配的 Agent',
                          key: ValueKey('agent-picker-empty'),
                        ),
                      ),
                    for (final g in _filtered) ...[
                      // 组头。全是未分组时不显示——那时它只是噪音。
                      if (g.name != ungroupedAgentLabel || _filtered.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            SpbSpacing.md,
                            SpbSpacing.sm,
                            SpbSpacing.md,
                            SpbSpacing.xs,
                          ),
                          child: Text(
                            g.name,
                            key: ValueKey('agent-picker-group-${g.name}'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      for (final a in g.agents)
                        _row(
                          context,
                          key: ValueKey('agent-option-${a.id}'),
                          icon: Icons.smart_toy_outlined,
                          label: a.label,
                          subtitle: a.description,
                          index: flatIndex++,
                          isCurrent: a.id == widget.currentAgentId,
                          onTap: () => _submit(a),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required String subtitle,
    required int index,
    required bool isCurrent,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final highlighted = index == _highlighted;
    return ListTile(
      key: key,
      dense: true,
      selected: highlighted,
      // 当前项：置灰且不可点。用 `enabled: false` 而不是把 onTap 设成
      // 空函数——前者连水波纹都没有，语义更准确（见 [_submit] 的注释）。
      enabled: !isCurrent,
      leading: Icon(
        isCurrent ? Icons.check_circle : icon,
        size: SpbSpacing.lg,
        color: isCurrent ? theme.colorScheme.primary : null,
      ),
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: isCurrent
          ? Text('当前', style: theme.textTheme.labelSmall)
          : null,
      onTap: isCurrent ? null : onTap,
    );
  }
}

/// 弹层的结果。
///
/// 为什么要一个包装类而不是直接 `pop(String?)`：`null` 已经被「用户取消」
/// （`Navigator.pop` 不传值）占用，而「自动路由」本身也要求把选择清成 null。
/// 两者混在一个 null 里，调用方就无法区分「关掉了弹层」与「选了自动路由」。
class AgentPick {
  const AgentPick.auto() : agentId = null;

  const AgentPick.agent(String this.agentId);

  /// 选中的 agent；null 表示**用户明确选了**自动路由。
  final String? agentId;
}
