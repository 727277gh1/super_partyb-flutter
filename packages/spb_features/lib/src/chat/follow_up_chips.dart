import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';

/// 一条后续提问建议的完整语义（文案 + 可选的适用 agent）。
///
/// agent_id 来自 Go `followUpSuggestionInput`（服务端已校验为 active）：
/// 点击建议时除追加文本外还应把选中 Agent 切过去——「按建议追问」与
/// 「由谁回答」一致，对齐 webapp FollowUpSuggestCard。
class FollowUpSuggestion {
  const FollowUpSuggestion({required this.text, this.agentId});

  final String text;

  /// 建议适用的 agent。null 表示未标注（保持原有行为，不切 agent）。
  final String? agentId;
}

/// 后续提问建议（`follow_up_suggested`）。
///
/// ## 用 ActionChip 而非按钮
///
/// 建议是「轻量快捷入口」而非「必须做的决定」，chip 的视觉权重更低、
/// 更省纵向空间（可并排多个）。见 `docs/flutter-component-research.md` §3.3。
///
/// ## 点击即发送
///
/// 点 chip 直接把建议文本作为下一条消息发出（与 webapp 一致），
/// 不是「填进输入框让用户再按一次发送」——多一步操作没有价值，
/// 因为建议本身就是完整可发送的语句。
///
/// ## 动作语义对齐 webapp
///
/// 服务端 spec 给的建议按钮动作是 `copy_text`（点击复制问题，可修改后再发送），
/// webapp 的处理是「优先回填输入框（onAppend），剪贴板为降级」。本组件的
/// [onAppend] 与 [onSelectAgent] 即这两个注入点：两个都为 null 时退化为
/// 旧的「点击即发送」行为（[onTap]），保证既有调用方不受影响。
class FollowUpChips extends StatelessWidget {
  const FollowUpChips({
    super.key,
    required this.suggestions,
    this.richSuggestions = const [],
    this.onTap,
    this.onAppend,
    this.onSelectAgent,
  });

  /// 纯文本建议（旧调用方：没有 agent 标注的简单场景）。
  ///
  /// 与 [richSuggestions] 二选一：后者优先（含 agent 标注）。
  final List<String> suggestions;

  /// 带语义的建议（agent 标注）。为空时用 [suggestions]。
  final List<FollowUpSuggestion> richSuggestions;

  /// 点击某个建议时的回调（旧路径）。为 null 且未注入 append 时 chip 不可点。
  final void Function(String suggestion)? onTap;

  /// 追加文本进输入框（对齐 webapp copy_text 的 onAppend 路径）。
  final void Function(String text)? onAppend;

  /// 把选中 Agent 切到 [FollowUpSuggestion.agentId]（先切人再追加，
  /// 与用户「选人再提问」的直觉一致）。
  final void Function(String agentId)? onSelectAgent;

  /// 传给 [onTap] 的展示文案（建议全文）。
  String _textOf(FollowUpSuggestion s) => s.text;

  @override
  Widget build(BuildContext context) {
    // richSuggestions 优先：reducer 产出的 FollowUpSuggestionItem 走这条，
    // 旧的纯文本调用方（测试、无标注场景）走 suggestions。
    final items = richSuggestions.isNotEmpty
        ? richSuggestions
        : [for (final s in suggestions) FollowUpSuggestion(text: s)];
    if (items.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: SpbSpacing.xs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: SpbSpacing.sm,
          runSpacing: SpbSpacing.sm,
          children: [
            for (final s in items)
              ActionChip(
                key: ValueKey('follow-up-${_textOf(s)}'),
                avatar: Icon(
                  Icons.arrow_forward,
                  size: SpbSpacing.lg,
                  color: scheme.primary,
                ),
                label: Text(_textOf(s)),
                onPressed: _handleTap(s),
              ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _handleTap(FollowUpSuggestion s) {
    // 新语义（对齐 webapp）：有 onAppend 时「切 Agent → 追加文本」；
    // 两个回调都缺（旧调用方）时退化为 onTap 即发送。
    if (onAppend != null || onSelectAgent != null) {
      return () {
        if (s.agentId != null) onSelectAgent?.call(s.agentId!);
        onAppend?.call(_textOf(s));
      };
    }
    if (onTap == null) return null;
    return () => onTap!(_textOf(s));
  }
}
