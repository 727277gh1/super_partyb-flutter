import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_ui/spb_ui.dart';

/// 对话内搜索面板（底部弹层内容）。
///
/// ## 为什么是弹层而不是新路由
///
/// 与 AGENTS.md §6.10 的两端载体约定一致，且这里还有一个更硬的理由：搜索命中
/// 之后要**滚回时间线的某一条**，那需要对话页的 `ScrollController` 与 `_items`。
/// 新路由会得到另一个 `_ChatPage` 实例（State 不共享），滚不动原页面。弹层与
/// 对话页在同一棵树上，回调直接闭包捕获页面 State。
///
/// ## 为什么在弹层里做本地过滤，而不是调服务端搜索
///
/// 见 `spb_domain` 的 `conversation_search.dart` 文件头：服务端两条搜索都只查
/// `chat_turns.input_text`（搜不到 agent 回复），且新增端点要改 Go API。
/// 而对话页手上**已经有**归约后的完整时间线，本地过滤零往返。
///
/// ## 覆盖范围的边界（**如实告知**）
///
/// 搜的是**已加载**的 items，不是服务端全量历史。`upperHistoryUnloaded` 为真
/// 时面板顶部给出提示——不提示会让用户把「没搜到」误读成「这句话不存在」。
class ConversationSearchSheet extends StatefulWidget {
  const ConversationSearchSheet({
    super.key,
    required this.readItems,
    required this.onOpenHit,
    this.upperHistoryUnloaded = false,
  });

  /// 读取当前时间线（每次查询时调用，故弹层打开期间到达的新消息也可被搜到）。
  final List<ConversationItem> Function() readItems;

  /// 点击命中项。调用方负责关闭弹层并滚动到该条。
  final void Function(ConversationSearchHit hit) onOpenHit;

  /// 时间线上方是否还有未加载的历史（见类文档）。
  final bool upperHistoryUnloaded;

  @override
  State<ConversationSearchSheet> createState() =>
      _ConversationSearchSheetState();
}

class _ConversationSearchSheetState extends State<ConversationSearchSheet> {
  final _controller = TextEditingController();
  ConversationSearchResult? _result;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 本地过滤，**不需要防抖**。
  ///
  /// `SearchPage` 的 300ms 防抖是为服务端 LIKE 全表扫描准备的；这里是内存里
  /// 一次线性扫描（几百条），逐键实时过滤才是正确的交互（打字即见结果）。
  void _onChanged(String value) {
    setState(() {
      _result = searchConversationItems(
        widget.readItems(),
        value,
        upperHistoryUnloaded: widget.upperHistoryUnloaded,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = _result;
    final query = _controller.text.trim();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          // 搜索输入框：贴弹层顶部，自带关闭按钮（弹层的拖拽条在其上方）。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpbSpacing.md,
              0,
              SpbSpacing.sm,
              SpbSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('conversation-search-field'),
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: '在本对话中搜索',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: _onChanged,
                  ),
                ),
                const SizedBox(width: SpbSpacing.sm),
                IconButton(
                  key: const ValueKey('conversation-search-close'),
                  icon: const Icon(Icons.close),
                  tooltip: '关闭搜索',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          // 「上方还有未加载的历史」提示：只要用户开始搜索就显示，与是否命中
          // 无关——它修饰的是**搜索范围**，而不是搜索结果。
          if (widget.upperHistoryUnloaded && query.isNotEmpty)
            const _ScopeNotice(),
          if (result != null && query.isNotEmpty) _SummaryLine(result: result),
          const Divider(height: 1),
          Expanded(child: _buildResults(context, result, query, scheme)),
        ],
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    ConversationSearchResult? result,
    String query,
    ColorScheme scheme,
  ) {
    if (query.isEmpty) {
      return const EmptyState(
        icon: Icons.search_outlined,
        message: '输入关键字，在本对话已加载的内容中查找',
      );
    }
    if (result == null || result.hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_outlined,
        message: '没有找到「$query」',
      );
    }

    return ListView.separated(
      itemCount: result.hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final hit = result.hits[index];
        return _HitTile(
          key: ValueKey('conversation-search-hit-${hit.itemId}'),
          hit: hit,
          query: query,
          onTap: () => widget.onOpenHit(hit),
        );
      },
    );
  }
}

/// 搜索范围提示（上方仍有未加载历史）。
class _ScopeNotice extends StatelessWidget {
  const _ScopeNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('conversation-search-scope-notice'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.md,
        vertical: SpbSpacing.sm,
      ),
      color: scheme.surfaceContainerHighest,
      child: Text(
        '只搜索了已加载的内容，更早的历史尚未加载',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 命中数摘要（含「已截断」提示）。
class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.result});

  final ConversationSearchResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 截断时把「共 N 条」也说出来，否则用户会以为总共只有列出来的这些。
    final text = result.truncated
        ? '共 ${result.totalMatches} 条，仅显示前 ${result.hits.length} 条'
        : '${result.totalMatches} 条结果';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.md,
        vertical: SpbSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          key: const ValueKey('conversation-search-summary'),
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 单条命中：类型标签 + 高亮片段。
class _HitTile extends StatelessWidget {
  const _HitTile({
    super.key,
    required this.hit,
    required this.query,
    required this.onTap,
  });

  final ConversationSearchHit hit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (String label, IconData icon) = _kindOf(hit.item);

    return ListTile(
      onTap: onTap,
      // 类型标签贴左：命中列表里「这是谁说的」比「说了什么」更先被需要——
      // 用户找的是「agent 说过的那句」。
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: SpbSpacing.xxs),
        child: HighlightedText(
          text: hit.snippet,
          query: query,
          style: theme.textTheme.bodyMedium,
          maxLines: 3,
          highlightStyle: theme.textTheme.bodyMedium?.copyWith(
            backgroundColor: scheme.primaryContainer,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }

  /// 项类型 → （展示标签, 图标）。
  ///
  /// 与 `conversation_search.dart` 的 `_searchableText` 同属「按 sealed 类型
  /// 分派」：这里覆盖的是**全部**子类（含不参与搜索的那些），因为
  /// [ConversationSearchHit.item] 理论上可能是任何项——搜索只决定「哪些项被
  /// 搜」，展示必须对每种类型都有答案，否则会落到兜底文案。
  static (String, IconData) _kindOf(ConversationItem item) => switch (item) {
    UserMessageItem() => ('我', Icons.person_outline),
    AssistantMessageItem() => ('助手', Icons.smart_toy_outlined),
    ThoughtItem() => ('思考', Icons.psychology_outlined),
    ToolCallItem() => ('工具', Icons.build_outlined),
    ErrorItem() => ('错误', Icons.error_outline),
    DiagnosticNoticeItem() => ('诊断', Icons.info_outline),
    AgentFileItem() => ('文件', Icons.insert_drive_file_outlined),
    ConfirmationItem() => ('确认', Icons.help_outline),
    FeedbackRequestItem() => ('反馈', Icons.feedback_outlined),
    FollowUpSuggestionItem() => ('建议', Icons.lightbulb_outline),
    GoalProgressItem() => ('目标', Icons.flag_outlined),
    GoalGateStoppedItem() => ('目标', Icons.flag_outlined),
    ScheduleCreatedItem() => ('排程', Icons.schedule_outlined),
    HabitSuggestionItem() => ('习惯', Icons.repeat_outlined),
    HabitAutoRunItem() => ('习惯', Icons.repeat_outlined),
    RoutingNoticeItem() => ('归属', Icons.alt_route_outlined),
  };
}
