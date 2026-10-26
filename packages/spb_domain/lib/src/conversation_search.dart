/// 对话内搜索（纯逻辑，无 IO、无 Flutter）。
///
/// ## 为什么是客户端过滤，而不是新的服务端端点
///
/// 服务端有两条**跨对话**搜索（`GET /users/:uid/chat/search` 按 `input_text`、
/// `GET /me/turns/search` 按输入文本），都由 `SearchPage` 消费。它们搜的是
/// **用户输入**，且是 `LIKE '%q%'` 全表扫描——对「在当前这段对话里找一句话」
/// 这个诉求有两个错位：
///
/// 1. **搜不到 agent 的回复**：`SearchChatTurnsByText` 的 SQL 只查
///    `chat_turns.input_text`。用户记得的是「agent 说过 X」，而不是「我说过 X」。
/// 2. **要新端点**：加「按 group + 全文」的服务端搜索意味着改 Go API，
///    而本仓库的硬约束是「Go API 一行不改」（AGENTS.md 开头）。
///
/// 而客户端手上**已经有**这份数据：对话页的 `_items` 就是归约后的完整时间线
/// （回填 200 条 + 实时流累积）。在本地过滤即可，零往返、零服务端改动。
///
/// ## 覆盖范围的边界（**必须如实告知用户**）
///
/// 过滤的是**已加载**的 items，不是服务端全量历史：
///
/// | 情况 | 表现 |
/// |---|---|
/// | 历史在 200 条以内 | 全量可见，搜索完整 |
/// | 历史更长且未滚到顶 | 只搜到已加载的部分 |
/// | 客户端从未连接过（离线且无缓存） | 无内容可搜 |
///
/// 故 [ConversationSearchResult.truncated] 表达「上方还有未加载的历史」，
/// UI 据此提示，而不是假装搜完了。**不谎报完整性**是本模块的设计前提。
library;

import 'conversation_item.dart';

/// 一条搜索命中。
///
/// [itemId] 是 [ConversationItem.id]，供 UI 用它滚动定位到该条。
class ConversationSearchHit {
  const ConversationSearchHit({
    required this.itemId,
    required this.item,
    required this.snippet,
    required this.matchStart,
    required this.matchLength,
  });

  /// 命中项的稳定 id（= `ConversationItem.id`）。
  final String itemId;

  /// 原始项，UI 据此决定展示哪类内容（用户气泡 / agent 回复 / 工具调用…）。
  final ConversationItem item;

  /// 命中处的上下文片段（已按 [kSearchSnippetRadius] 前后截取）。
  final String snippet;

  /// [snippet] 内命中词起点的索引（供高亮）。
  final int matchStart;

  /// [snippet] 内命中词长度（供高亮）。
  ///
  /// 与 [matchStart] 一起构成高亮区间。**不做大小写归一后重算**——命中位置是
  /// 在原文上按 [ConversationSearchResult.query] 的不区分大小写匹配得到的，
  /// 高亮长度用查询串本身的长度（ASCII 大小写同长，故成立）。
  final int matchLength;
}

/// 搜索结果的上下文半径（命中词前后各取多少字符）。
///
/// 40 是「一眼能看出这条在讲什么」的经验值：再短会把句子切在词组中间，再长
/// 会让列表条目高到一屏放不下几条。
const int kSearchSnippetRadius = 40;

/// 单次搜索最多返回的命中数。
///
/// 上限的意义不是性能（本地过滤很快），而是**可读性**：搜「的」会命中几乎
/// 每一条，列 500 条对用户毫无帮助。超过时 UI 提示「仅显示前 N 条」。
const int kConversationSearchMaxHits = 100;

/// 一次对话内搜索的结果。
class ConversationSearchResult {
  const ConversationSearchResult({
    required this.hits,
    required this.query,
    required this.totalMatches,
    this.upperHistoryUnloaded = false,
  });

  /// 命中列表（最多 [kConversationSearchMaxHits] 条，按时间升序）。
  final List<ConversationSearchHit> hits;

  /// 本次查询串（原样保留大小写，供高亮与展示）。
  final String query;

  /// 命中总数（可能大于 `hits.length`，见 [kConversationSearchMaxHits]）。
  final int totalMatches;

  /// 是否因 [kConversationSearchMaxHits] 上限而截断了 [hits]。
  bool get truncated => totalMatches > hits.length;

  /// 上方是否还有**未加载**的历史（调用方传入 `reachedOldest == false`）。
  ///
  /// 与 [truncated] 是两件事，**不要合并**：
  /// - [truncated]：搜完了已加载的内容，但命中太多，只列前 N 条；
  /// - [upperHistoryUnloaded]：已加载的内容搜完了，但**更早的历史还没拉下来**，
  ///   所以「没找到」不等于「不存在」。
  ///
  /// UI 对后者必须给出提示，否则用户会得出「这句话不在这个对话里」的错误结论。
  final bool upperHistoryUnloaded;

  /// 空结果（查询串为空）。
  static ConversationSearchResult empty(String query) =>
      ConversationSearchResult(hits: const [], query: query, totalMatches: 0);
}

/// 在已加载的时间线里搜索 [query]。
///
/// ## 搜哪些字段
///
/// 只搜**用户可读的文本**，按「用户会怎么记得这句话」挑选：
///
/// | 项类型 | 是否搜 | 搜什么 |
/// |---|---|---|
/// | [UserMessageItem] | ✅ | 用户输入原文 |
/// | [AssistantMessageItem] | ✅ | agent 回复正文 |
/// | [ThoughtItem] | ✅ | 思考过程（用户能展开看到，就该能搜到） |
/// | [ToolCallItem] | ✅ | 工具名 + 参数 + 输出（排障时最常搜「哪个命令跑过」） |
/// | [ErrorItem] | ✅ | 错误消息（「上次那个报错」是很自然的检索意图） |
/// | [DiagnosticNoticeItem] | ✅ | 诊断说明 |
/// | [AgentFileItem] | ✅ | 文件名（「那个文件叫什么」） |
/// | 其余（确认卡 / 建议 / 进度 / 习惯…） | ❌ | 它们是**交互控件或状态**，不是对话内容 |
///
/// 排除确认卡等的理由：搜「同意」会命中一堆按钮文案，而用户找的是「我说过
/// 同意」那条消息。把控件文案算进来会让命中列表被噪声淹没。
///
/// ## 大小写与空白
///
/// [query] 会先 `trim()`：全空白视为空查询（返回 [ConversationSearchResult.empty]）。
/// 匹配**不区分大小写**（`toLowerCase` 比较），这对英文技术词是必需的
/// （搜 `error` 要能命中 `Error`）。
///
/// ## 为什么不用正则
///
/// 用户输入里 `(`、`[`、`*` 很常见（代码片段、路径通配）。把它们当正则会让
/// 「搜一个括号」变成语法错误或意外匹配。这里一律按**字面量子串**处理。
ConversationSearchResult searchConversationItems(
  List<ConversationItem> items,
  String query, {
  bool upperHistoryUnloaded = false,
  int maxHits = kConversationSearchMaxHits,
}) {
  final q = query.trim();
  if (q.isEmpty) return ConversationSearchResult.empty(query);

  final needle = q.toLowerCase();
  final hits = <ConversationSearchHit>[];
  var total = 0;

  for (final item in items) {
    final text = _searchableText(item);
    if (text == null || text.isEmpty) continue;

    // 直接用小写串的下标去切**原文**片段。这依赖一个前提：Dart 的
    // `toLowerCase` 用简单大小写映射（长度不变），故两串下标一一对应。
    // 该前提由测试钉住（`conversation_search_test.dart` 的「toLowerCase
    // 长度不变」）——若语言运行时改成完整映射（如 `İ` → `i̇`），测试会失败。
    final idx = text.toLowerCase().indexOf(needle);
    if (idx < 0) continue;

    total++;
    if (hits.length >= maxHits) continue;

    // 截取上下文窗口。左右各留 kSearchSnippetRadius，并在切口加省略号——
    // 不加的话用户会以为片段就是完整消息。
    final start = (idx - kSearchSnippetRadius).clamp(0, text.length);
    final end = (idx + q.length + kSearchSnippetRadius).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';

    hits.add(
      ConversationSearchHit(
        itemId: item.id,
        item: item,
        snippet: '$prefix${text.substring(start, end)}$suffix',
        // 高亮起点要算上省略号占的位。
        matchStart: idx - start + prefix.length,
        matchLength: q.length,
      ),
    );
  }

  return ConversationSearchResult(
    hits: hits,
    query: q,
    totalMatches: total,
    upperHistoryUnloaded: upperHistoryUnloaded,
  );
}

/// 取一项的可搜索文本；返回 null 表示「此项不参与搜索」。
///
/// 显式 switch（而非 `if (item is X)` 链）是刻意的：`ConversationItem` 是
/// `sealed`，新增子类时编译器会在这里报错，迫使作者回答「它该不该被搜到」。
/// 用 `is` 链则新类型会静默落到「不搜」——那正是「搜不到但没人知道为什么」的成因。
String? _searchableText(ConversationItem item) => switch (item) {
  UserMessageItem(:final text) => text,
  AssistantMessageItem(:final text) => text,
  ThoughtItem(:final text) => text,
  // 工具调用：名称 + 参数 + 输出拼成一个可搜串。分开搜没有意义——
  // 用户记得的是「跑过 npm test」，而这三者分属不同字段。
  ToolCallItem(:final name, :final args, :final output) => [
    name,
    if (args != null) args.toString(),
    if (output != null) output,
  ].join('\n'),
  ErrorItem(:final message) => message,
  DiagnosticNoticeItem(:final content) => content,
  // 文件卡：搜展示名（`nice_name` 优先）与真实文件名，两者都试——
  // 用户可能记得「那个报告」也可能记得 `report.md`。
  AgentFileItem(:final displayName, :final fileName) =>
    displayName == fileName ? fileName : '$displayName\n$fileName',
  // 其余是交互控件 / 状态 / 建议：不参与搜索（见函数文档）。
  _ => null,
};
