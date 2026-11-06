import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'agent_file_card.dart';
import 'agent_file_preview.dart';
import 'assistant_message_bubble.dart';
import 'thought_tile.dart';
import 'tool_call_tile.dart';

/// 拉取某个 turn 的完整详情（meta + 事件）。
///
/// ## 为什么入参是 `(groupId, turnId)` 而不是只有 `turnId`
///
/// 上游 `GET /chat/turns/:turn_id` **只返回 turn、不返回 events**
/// （`chat.go` 的 `getTurn` → `turnToDict(turn)`，见 issue `super_partyb#56`）。
/// 客户端因此要多拉一次 `GET /chat/groups/:group_id/timeline` 再按 turnId
/// 过滤，而 timeline 是**群级**端点——没有 groupId 就无从发起。
///
/// 调用方（`MyTurnsPage.onOpenTurn`）本来就同时拿到两个 id，故不额外加负担。
///
/// ## 上游 #56 若补了 events，这里改什么
///
/// 若 #56 的结论是「补 Go 实现返回 `{turn, events}`」，则本 typedef 的实现
/// 退化为单次 `getTurn` 调用，签名不变（仍收 groupId，只是不再用它）。
/// 这样调用方与测试都不必改——把「需要几个请求」这件事挡在装配层里。
typedef LoadTurnDetail = Future<TurnDetail> Function(
  String groupId,
  String turnId,
);

/// 详情加载用例与 [TurnDetail] 定义在 `spb_domain`（`turn_detail.dart`）：
/// 它是**用例**（两次 HTTP + 过滤 + 排序），不是渲染。本包只消费它。
///
/// 轮次详情：把「这一轮到底发生了什么」摊开。
///
/// ## 它解决什么
///
/// 「我的最近轮次」列表只有一行输入摘要 + 状态徽标，看不到 agent 实际回复了
/// 什么、调了哪些工具、有没有报错。webapp 有 `TurnDetailDrawer` 正是干这个的。
///
/// ## 与 `ConversationPage` 的关系：**故意不共用渲染分支**
///
/// 两者都渲染 `ChatEvent`，但取向不同：
///
/// | | `ConversationPage` | 本面板 |
/// |---|---|---|
/// | 输入 | 实时 SSE 缓冲（含未落库的 Transient 增量） | 已落库的历史事件 |
/// | 归约 | `EventReducer.reduce` 合并增量/配对工具 | **不归约**，逐事件原样列出 |
/// | 目的 | 「对话进行到哪了」 | 「这一轮服务端到底发了什么」 |
///
/// 归约会把「3 个 message 增量 + 1 个权威帧」压成一个气泡、把 `tool_call` 与
/// `tool_result` 合成一项——这正是对话页要的，但会让详情页**看不到原始事件
/// 序列**（而排障恰恰需要看原始序列）。故这里逐事件渲染，不做归约。
///
/// 复用零件（`AssistantMessageBubble` / `ThoughtTile` / `ToolCallTile` /
/// `AgentFileCard`）而不是重写：这些是**单个事件的渲染器**，与归约层无耦合。
///
/// ## 用户输入置顶
///
/// `turn.inputText` 单独一块置顶，且**不**依赖事件里有没有 `user_message`
/// （历史 turn 可能没有该事件，而 `input_text` 一定在 turn 行上）。对齐 webapp
/// `TurnDetailDrawer` 的做法。
class TurnDetailPanel extends StatelessWidget {
  const TurnDetailPanel({
    super.key,
    required this.detail,
    this.onDownloadAgentFile,
    this.onLoadThumbnailAgentFile,
    this.onOpenAgentFile,
    this.onRevealAgentFile,
    this.onPreviewAgentFile,
    this.onOpenLink,
  });

  /// 已加载的详情（meta + 事件）。
  ///
  /// 收一个整体而不是分开的 `turn` + `events`：调用方把加载结果原样递进来即可，
  /// 也让「两者同源」这件事在类型上显式（不可能传错配对）。
  final TurnDetail detail;

  /// 轮次元数据（`detail.turn` 的便捷访问）。
  ChatTurn get turn => detail.turn;

  /// 该轮的事件（`detail.events` 的便捷访问）。空列表时渲染空提示
  /// （**不是**白屏，见 [_emptyEvents]）。
  List<ChatEvent> get events => detail.events;

  /// 文件类事件（`agent.file.*`）的交互回调，与 `ConversationPage` 同名同义
  /// （类型也一致：`OpenAgentFile` / `RevealAgentFile` / `AgentFilePreviewCallbacks`）。
  /// 未注入时 `AgentFileCard` 自行不渲染对应菜单项。
  final Future<void> Function(AgentFileItem file)? onDownloadAgentFile;

  /// 缩略图回调。卡片侧无参，故本面板在调用处把 file 闭包进去。
  final Future<List<int>?> Function(AgentFileItem file)?
  onLoadThumbnailAgentFile;

  final OpenAgentFile? onOpenAgentFile;
  final RevealAgentFile? onRevealAgentFile;
  final AgentFilePreviewCallbacks? onPreviewAgentFile;

  /// 点击 Markdown 链接。详情页是只读视图，通常不注入（不传则链接不可点）。
  ///
  /// 签名与 `GptMarkdown.onLinkTap` 一致：`(url, title)`。
  final void Function(String url, String title)? onOpenLink;

  /// 按 per-turn `seq` 升序排列。
  ///
  /// ## 为什么用 `seq` 而不是 `globalSeq`
  ///
  /// 详情页的语义是「这一轮内部的先后」，而 `seq` 正是**每轮从 1 重来**的
  /// 轮内序（见 `ChatEvent.seq` 文档）——它天然给出「用户输入 → 思考 → 工具 →
  /// 回复」的正确顺序。
  ///
  /// `globalSeq` 也能定序（且跨轮唯一），但 Transient 事件**不落库、它为
  /// null**（本面板虽只处理落库事件，仍防御性地用 `seq` 优先）。
  ///
  /// ## 两级回退
  ///
  /// 1. `seq` 相同时（异常载荷、或全部为 0）用 `globalSeq`；
  /// 2. 再相同则用 `createdAt`。
  ///
  /// 不用 `createdAt` 作**主**键：它只有毫秒精度，同毫秒内的多条事件无法定序
  /// ——这正是 `globalSeq` 存在的理由。
  ///
  /// ## 与 `LoadTurnDetailUseCase` 的排序重复是**有意**的
  ///
  /// 用例已排过一次（过滤路径拿到的是 `global_seq` 序，必须重排）。这里再排
  /// 一次是幂等的，且能让「直接构造 [TurnDetail] 的调用方」（测试、将来从别的
  /// 来源拿事件）也得到正确顺序——不依赖上游是否排过。
  List<ChatEvent> get sortedEvents {
    final list = detail.events.toList()
      ..sort((a, b) {
        final bySeq = a.seq.compareTo(b.seq);
        if (bySeq != 0) return bySeq;
        final byGlobal = (a.globalSeq ?? 0).compareTo(b.globalSeq ?? 0);
        if (byGlobal != 0) return byGlobal;
        return a.createdAt.compareTo(b.createdAt);
      });
    return list;
  }

  /// 该轮的文件类事件（`agent.file.*`）转成可渲染的文件项。
  ///
  /// 复用 [AgentFileItem.fromEvent]（与归约器**同一个**工厂），故删除态、
  /// TTS 判定、展示名回退等规则与对话页完全一致——不会出现「同一个文件在
  /// 对话页显示已删除、在详情页还能下载」这类漂移。
  List<AgentFileItem> get agentFiles => [
    for (final e in sortedEvents)
      if (e.eventType.startsWith(EventTypes.agentFilePrefix))
        ?AgentFileItem.fromEvent(e),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = sortedEvents;

    return ListView(
      key: const ValueKey('turn-detail-panel'),
      padding: SpbSpacing.pagePadding,
      children: [
        _meta(context),
        const SizedBox(height: SpbSpacing.md),
        _userInput(context, theme),
        const SizedBox(height: SpbSpacing.md),
        Text(
          '事件流（${sorted.length}）',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: SpbSpacing.sm),
        if (sorted.isEmpty)
          _emptyEvents(context, theme)
        else
          for (final e in sorted)
            Padding(
              // 稳定 key：同一事件的 Element 可被复用，展开态等本地状态不会
              // 在父级重建时错位到另一条事件上。
              key: ValueKey('turn-event-${e.eventId}'),
              padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
              child: _eventCard(context, e),
            ),
      ],
    );
  }

  /// 顶部 meta：状态 + 来源 + 时间 + 计数。
  Widget _meta(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = turn;

    // 与 `MyTurnsPage._statusBadge` 同一映射（含英式 `cancelled` 的拼写防御）。
    final (Color bg, String label) = switch (t.status) {
      'failed' => (scheme.errorContainer, '失败'),
      'cancelled' || 'canceled' => (scheme.surfaceContainerHighest, '已取消'),
      'running' || 'queued' => (scheme.tertiaryContainer, '进行中'),
      'pending' => (scheme.secondaryContainer, '待确认'),
      _ => (scheme.secondaryContainer, '已完成'),
    };
    final effectiveBg = t.errorCount > 0 && t.status != 'failed'
        ? scheme.errorContainer
        : bg;

    return Wrap(
      key: const ValueKey('turn-detail-meta'),
      spacing: SpbSpacing.sm,
      runSpacing: SpbSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _chip(theme, effectiveBg, label),
        if (t.channel != null && t.channel!.isNotEmpty)
          _chip(theme, scheme.surfaceContainerHighest, t.channel!),
        if (t.errorCount > 0)
          _chip(theme, scheme.errorContainer, '${t.errorCount} 个错误'),
        Text(
          _formatTime(t.createdAt),
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _chip(ThemeData theme, Color bg, String text) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: SpbSpacing.xs,
      vertical: SpbSpacing.xxs,
    ),
    decoration: BoxDecoration(color: bg, borderRadius: SpbRadius.cardAll),
    child: Text(text, style: theme.textTheme.labelSmall),
  );

  /// 用户输入置顶（不依赖事件里有没有 `user_message`）。
  Widget _userInput(BuildContext context, ThemeData theme) {
    final input = turn.inputText;
    return Container(
      key: const ValueKey('turn-detail-input'),
      width: double.infinity,
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '用户输入',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SpbSpacing.xxs),
          // 空输入给占位而不是留白（异常 turn 可能没有 input_text）。
          SelectableText(input.isEmpty ? '（空）' : input),
        ],
      ),
    );
  }

  /// 事件为空时的提示。
  ///
  /// ## 为什么必须有它（而不是让列表空着）
  ///
  /// 空事件**是正常结果**，不是错误：上游 `GET /chat/turns/:id` 不返回 events
  /// （issue `super_partyb#56`），本面板的事件来自 timeline 的本地过滤——若该
  /// turn 的事件已被 timeline 的分页窗口甩出去（或 turn 刚建、事件尚未落库），
  /// 过滤结果就是空。留白会让用户以为「页面坏了」，故给一句明确说明。
  Widget _emptyEvents(BuildContext context, ThemeData theme) {
    return Padding(
      key: const ValueKey('turn-detail-events-empty'),
      padding: const EdgeInsets.symmetric(vertical: SpbSpacing.xxl),
      child: Column(
        children: [
          Icon(
            Icons.inbox_outlined,
            size: SpbSpacing.xxl,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: SpbSpacing.sm),
          Text(
            '这一轮没有可展示的事件',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            '事件可能已超出时间线窗口，或尚未落库。',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 单个事件的渲染分支。
  ///
  /// 分支顺序即优先级：先按类型判 `error` / `message`，再按前缀判文件事件，
  /// 最后落到通用卡。**不做归约**（见类文档「故意不共用渲染分支」）。
  Widget _eventCard(BuildContext context, ChatEvent e) {
    // 错误事件：单独醒目样式（红色），文案取 `errorMessage`。
    if (e.eventType == EventTypes.error) {
      return _errorCard(context, e);
    }
    // agent 正文：复用对话页的气泡（含 Markdown 渲染）。
    // 详情页是历史快照，一律按「已完成」渲染（`isStreaming: false`）——
    // 事件已落库，不存在还在累积的增量段。
    if (e.eventType == EventTypes.message) {
      return AssistantMessageBubble(
        text: e.text,
        isStreaming: false,
        onLinkTap: onOpenLink,
      );
    }
    if (e.eventType == EventTypes.thought) {
      return ThoughtTile(text: e.text);
    }
    if (e.eventType == EventTypes.toolCall) {
      // ## 为什么配对的 `tool_result` 缺失时要给占位文本（而不是留 null）
      //
      // `ToolCallTile` 的 `isRunning` 判据是 `output == null`——传 null 会渲染
      // **无限转圈的「执行中」**。在对话页这是对的（结果真的还没回来），但详情
      // 页是**历史快照**：一个 2024 年的工具调用不可能还在跑。转圈会让用户以为
      // 卡住了（测试也因无限动画而 `pumpAndSettle` 超时，是同一个问题的信号）。
      //
      // 占位文案说明的是**事实**：结果不在本次加载到的事件里（上游不返回 events，
      // 见 `super_partyb#56`；或结果被 timeline 分页窗口甩出去了）。不写
      // 「失败」——没有证据。
      return ToolCallTile(
        name: e.toolName ?? '（未知工具）',
        args: e.toolArgs,
        output: e.toolOutput ?? '（结果未在本次加载的事件中）',
        isComplete: true,
      );
    }
    if (e.eventType == EventTypes.toolResult) {
      return ToolCallTile(
        name: e.toolName ?? '（未知工具）',
        output: e.toolOutput,
        isComplete: true,
      );
    }
    // 文件事件：复用 AgentFileCard（它自己处理删除态、缩略图、菜单项）。
    //
    // `fromEvent` 返回 null（路径不可归一 / created 无 fileId 等异常载荷）
    // 时落到通用卡，**不静默丢弃**——详情页的职责是把服务端发的都摊开。
    if (e.eventType.startsWith(EventTypes.agentFilePrefix)) {
      final file = AgentFileItem.fromEvent(e);
      if (file != null) {
        return AgentFileCard(
          file: file,
          onDownload: onDownloadAgentFile,
          // 卡片侧 `onLoadThumbnail` 无参，故把 file 闭包进去（与对话页同做法）。
          onLoadThumbnail:
              onLoadThumbnailAgentFile == null || (file.ufsFileId ?? '').isEmpty
              ? null
              : () => onLoadThumbnailAgentFile!(file),
          onOpen: onOpenAgentFile,
          onReveal: onRevealAgentFile,
          onPreview: onPreviewAgentFile,
        );
      }
    }
    // 用户消息：置顶块已展示 input_text，这里只做一条轻量标注，避免正文重复。
    if (e.eventType == EventTypes.userMessage) {
      return _plainCard(context, e, '用户消息', e.text);
    }
    // 其余（start / done / 状态类）统一走通用卡。
    return _plainCard(context, e, e.eventType, e.text);
  }

  Widget _errorCard(BuildContext context, ChatEvent e) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final msg = e.errorMessage ?? e.text;
    return Container(
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: SpbSpacing.lg,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: SpbSpacing.xs),
              Text(
                '错误',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ],
          ),
          if (msg.isNotEmpty) ...[
            const SizedBox(height: SpbSpacing.xs),
            SelectableText(
              msg,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ],
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            _formatTime(e.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }

  /// 通用事件卡：类型名 + 正文（若有）+ 时间。
  ///
  /// 不渲染 payload 的完整 JSON（webapp 会 `JSON.stringify(payload)`）：那是
  /// 排障视图的做法，在移动端窄屏上会变成一坨不可读的文本。这里只展示服务端
  /// 已给的**文本字段**（`ChatEvent.text` 已按 text/content/message 回退取值）。
  Widget _plainCard(
    BuildContext context,
    ChatEvent e,
    String title,
    String body,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (e.source.isNotEmpty)
                Text(
                  e.source,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: SpbSpacing.xxs),
            SelectableText(body, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: SpbSpacing.xxs),
          Text(
            _formatTime(e.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 绝对时间（详情页是「回看」，相对时间会误导——「3 小时前」不如
  /// 「03-05 12:00」精确，且回看昨天的轮次时相对时间没有参照价值）。
  static String _formatTime(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}

/// 详情视图的**加载壳**：负责「加载中 / 失败重试 / 成功渲染」三态。
///
/// ## 为什么需要它（而不是让两端各自写一遍）
///
/// 两端装配都要「点一行 → 发两次请求 → 弹层展示」。若把加载态写在各自的
/// `router.dart` 里，两份 `FutureBuilder` 的分支（转圈、错误+重试、成功）
/// 会各自漂移——典型症状是「桌面端失败能重试、移动端只能关掉重开」。
/// 放在本包（两端共用）只有一份。
///
/// ## 为什么不把它塞进 [TurnDetailPanel]
///
/// [TurnDetailPanel] 是**纯渲染**（收一个已加载的 `TurnDetail`），这样它的测试
/// 不需要任何 HTTP mock，也不受 fake async 影响。加载态涉及真实 I/O，混进来
/// 会让「渲染测试」变成「异步集成测试」。故拆成两个组件，本壳负责编排。
class TurnDetailSheet extends StatefulWidget {
  const TurnDetailSheet({
    super.key,
    required this.groupId,
    required this.turnId,
    required this.load,
    this.onDownloadAgentFile,
    this.onLoadThumbnailAgentFile,
    this.onOpenAgentFile,
    this.onRevealAgentFile,
    this.onPreviewAgentFile,
    this.onOpenLink,
  });

  final String groupId;
  final String turnId;

  /// 加载详情（装配层注入 `LoadTurnDetailUseCase.call`）。
  final LoadTurnDetail load;

  /// 透传给 [TurnDetailPanel]（见其文档）。
  final Future<void> Function(AgentFileItem file)? onDownloadAgentFile;
  final Future<List<int>?> Function(AgentFileItem file)?
  onLoadThumbnailAgentFile;
  final OpenAgentFile? onOpenAgentFile;
  final RevealAgentFile? onRevealAgentFile;
  final AgentFilePreviewCallbacks? onPreviewAgentFile;
  final void Function(String url, String title)? onOpenLink;

  @override
  State<TurnDetailSheet> createState() => _TurnDetailSheetState();
}

class _TurnDetailSheetState extends State<TurnDetailSheet> {
  TurnDetail? _detail;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.load(widget.groupId, widget.turnId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: ValueKey('turn-detail-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null) {
      // 失败给重试而不是只给一句错误：一次网络抖动不该逼用户关掉弹层重进。
      return Center(
        key: const ValueKey('turn-detail-error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: SpbSpacing.xxl),
            const SizedBox(height: SpbSpacing.sm),
            Padding(
              padding: SpbSpacing.pagePadding,
              child: Text(
                '$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: SpbSpacing.sm),
            OutlinedButton(
              key: const ValueKey('turn-detail-retry'),
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return TurnDetailPanel(
      detail: _detail!,
      onDownloadAgentFile: widget.onDownloadAgentFile,
      onLoadThumbnailAgentFile: widget.onLoadThumbnailAgentFile,
      onOpenAgentFile: widget.onOpenAgentFile,
      onRevealAgentFile: widget.onRevealAgentFile,
      onPreviewAgentFile: widget.onPreviewAgentFile,
      onOpenLink: widget.onOpenLink,
    );
  }
}
