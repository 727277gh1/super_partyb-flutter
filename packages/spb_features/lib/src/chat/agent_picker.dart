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
class AgentPickerDialog extends StatefulWidget {
  const AgentPickerDialog({
    super.key,
    required this.groups,
    this.currentAgentId,
  });

  /// 已分组的完整列表（过滤在内部做，调用方不需预先过滤）。
  final List<AgentGroup> groups;

  /// 当前绑定的 agent。它在列表里**不可选**（见 [_submit]）。
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

  /// 过滤后的平铺 agent（键盘导航与渲染共用同一顺序）。
  List<Agent> get _flat => [for (final g in _filtered) ...g.agents];

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

  void _submit(Agent agent) {
    // 当前 agent 不可选。选择是纯本地的（见 `AgentSwitcher` 的类文档），故
    // 「选同一个」不会有任何变化——留着可点只会让用户怀疑「点了没反应」。
    if (agent.id == widget.currentAgentId) return;
    Navigator.of(context).pop(agent.id);
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
    var flatIndex = 0;

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
                        '选择后随下一条消息生效（旧会话上下文会断开）',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      '${flat.length}',
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
                child: flat.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(SpbSpacing.xl),
                        child: Text(
                          '没有匹配的 Agent',
                          key: ValueKey('agent-picker-empty'),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final g in _filtered) ...[
                            // 组头。全是未分组时不显示——那时它只是噪音。
                            if (g.name != ungroupedAgentLabel ||
                                _filtered.length > 1)
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
                                a,
                                index: flatIndex++,
                                isCurrent: a.id == widget.currentAgentId,
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
    BuildContext context,
    Agent agent, {
    required int index,
    required bool isCurrent,
  }) {
    final theme = Theme.of(context);
    final highlighted = index == _highlighted;
    return ListTile(
      key: ValueKey('agent-option-${agent.id}'),
      dense: true,
      selected: highlighted,
      // 当前 agent：置灰且不可点。用 `enabled: false` 而不是把 onTap 设成
      // 空函数——前者连水波纹都没有，语义更准确（见 [_submit] 的注释）。
      enabled: !isCurrent,
      leading: Icon(
        isCurrent ? Icons.check_circle : Icons.smart_toy_outlined,
        size: SpbSpacing.lg,
        color: isCurrent ? theme.colorScheme.primary : null,
      ),
      title: Text(agent.label, overflow: TextOverflow.ellipsis),
      subtitle: agent.description.isEmpty
          ? null
          : Text(
              agent.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: isCurrent
          ? Text('当前', style: theme.textTheme.labelSmall)
          : null,
      onTap: isCurrent ? null : () => _submit(agent),
    );
  }
}
