import 'conversation_item.dart';

/// 一个 turn 的对话项分组（供侧边栏按轮次呈现待办 / 工具调用）。
///
/// ## 为什么需要按 turn 分组
///
/// 待办面板（确认卡）与工具调用面板的核心 UX 是**按轮次聚合**：用户想看
/// 「这一轮我发了什么、agent 调了哪些工具、有哪些待我确认的」，而不是
/// 把所有 turn 的项摊成一长条扁平列表（那样确认卡散落各处，最新那条会被
/// 旧轮次的工具调用淹没）。对齐 webapp `groupTimelineByTurns` 的呈现。
class TurnGroup {
  const TurnGroup({required this.turnId, required this.items});

  /// 该轮的 turn id。空串表示无法归属的项（极少见，见 [groupItemsByTurn]）。
  final String turnId;

  /// 该轮的对话项，**按时间正序**（旧 → 新），与 [ConversationItem] 列表一致。
  final List<ConversationItem> items;

  /// 该轮的创建时间（取第一条项的 [ConversationItem.createdAt]）。
  DateTime get createdAt => items.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
      : items.first.createdAt;

  /// 该轮用户的输入文本（取该轮最后一条用户消息）。
  ///
  /// ## 为什么取「最后一条」而不是第一条
  ///
  /// 服务端会重发 `user_message`（同一 turnId），归约器按 turnId 原位合并，
  /// 故实际只有一条；但防御性地取最后一条，保证拿到正文最完整的版本
  /// （与 `_indexOfUserMessage` 的「取最近一条」取向一致）。
  String get userInput {
    UserMessageItem? last;
    for (final it in items) {
      if (it is UserMessageItem) last = it;
    }
    return last?.text ?? '';
  }

  /// 该轮待确认的卡片（未解决）。
  List<ConfirmationItem> get pendingConfirmations =>
      items.whereType<ConfirmationItem>().where((c) => !c.resolved).toList();

  /// 该轮的全部确认卡（含已解决，排障用）。
  List<ConfirmationItem> get confirmations =>
      items.whereType<ConfirmationItem>().toList();

  /// 该轮的工具调用。
  List<ToolCallItem> get toolCalls => items.whereType<ToolCallItem>().toList();
}

/// 把归约后的对话项按 [ConversationItem.turnId] 分组。
///
/// 组内保持时间正序（旧 → 新）。组间按**最新在前**排序（与侧边栏「最新轮次的
/// 待办排最前」一致），该排序基于「组内最后一条项的 [ConversationItem.createdAt]」
/// ——而非组的创建时间——因为同一 turn 在历史回填后可能有更早的项前插，
/// 排序应反映「用户视角的最新活动」。
///
/// ## 为什么不丢掉空 turnId 的项
///
/// 归约器给乐观回显 / 无归属提交的项可能留下空 turnId。**不丢弃**它们：
/// 丢弃会静默隐藏确认卡（用户根本不知道有个待确认），与归约器「宁可多展示
/// 也不静默丢」的取向一致。它们归入 `turnId == ''` 的组，UI 可决定如何展示。
///
/// 但绝大多数确认卡 / 工具调用都带 turnId（服务端在事件里填了），空 turnId
/// 的组只覆盖极少数边界情况。
List<TurnGroup> groupItemsByTurn(Iterable<ConversationItem> items) {
  final buckets = <String, List<ConversationItem>>{};
  for (final it in items) {
    buckets.putIfAbsent(it.turnId, () => <ConversationItem>[]).add(it);
  }

  final groups = buckets.entries
      .map((e) => TurnGroup(turnId: e.key, items: e.value))
      .toList();

  // 组内已是正序（按插入顺序，即事件到达顺序）。组间按最新活动倒序。
  groups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return groups;
}
