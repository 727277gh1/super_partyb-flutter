/// 轮次导航条（时间线右侧竖置刻度条）的数据投影（纯逻辑，无 IO、无 Flutter）。
///
/// ## 为什么在领域层
///
/// 「已加载的时间线里有哪几轮、每格标签取哪句话」是**口径**而不是渲染细节：
/// 它与深链锚点（[turn_anchor.dart]）、按轮次分组（[turn_group.dart]）必须
/// 用同一套判据——否则会出现「导航条里有这一轮，点进去却提示找不到」。
/// 而刻度、hover、滚动都是渲染层的事，放在 `spb_features`。
///
/// ## 作用域与深链一致：只覆盖**已加载**的轮次
///
/// 服务端的轮次枚举接口（`GET /chat/groups/:gid/turns`）是
/// `ORDER BY created_at DESC LIMIT ?` 且无游标，问不出「这个对话一共几轮」。
/// 故导航条只投影手上这份 timeline：滚动/翻页把更早的轮次载入后，刻度随之增加
/// （与 webapp `buildTurnNav` 同一取向，见 `chat.md` §6.94）。
library;

import 'agent_file_batch.dart';
import 'conversation_item.dart';
import 'turn_anchor.dart';

/// 每格标签默认保留的字符数。
///
/// 刻度条 hover 面板的宽度是固定的（[kTurnRailLabelMaxChars] × 12px 左右），
/// 只够一眼扫过——所以「问题原文」在这里就被截断，而不是靠渲染时 ellipsis
/// 兜底：两者叠加会让「到底保留了几个字」取决于字体度量，跨端/跨语言不可复现。
const int kTurnRailLabelMaxChars = 24;

/// 该轮没有用户消息时的占位（异常载荷：历史裁剪掉了轮首、或纯 agent 事件轮）。
const String kTurnRailEmptyLabel = '（无输入）';

/// 导航条上的一格。
class TurnRailEntry {
  const TurnRailEntry({
    required this.turnId,
    required this.label,
    required this.createdAt,
    required this.index,
    this.isLatest = false,
  });

  /// 归一化后的 turn id（[normalizeTurnAnchor] 的输出）：可直接与页面上的
  /// `anchorTurnId` / 锚点态字段比较。
  final String turnId;

  /// 该轮用户输入的摘要（已折叠空白、已按 [kTurnRailLabelMaxChars] 截断）。
  final String label;

  /// 该轮**第一条**项的时间（与 `TurnGroup.createdAt` 同口径）。
  final DateTime createdAt;

  /// 在**已加载**轮次里的序号，1 起、旧 → 新。
  ///
  /// ## 为什么显示序号而不是「第几条消息」
  ///
  /// 它是「我在这段历史的第几轮」的唯一稳定参照：消息条数会随流式追加变化，
  /// 而轮次序号不跳。序号只在当前加载范围内有效（翻页后会整体后移），
  /// 故**不能**拿它当跳转键（跳转键必须是 [turnId]，见 [turn_anchor.dart]）。
  final int index;

  /// 是否已加载区间里的最后一轮（点它就是「跟随最新」）。
  final bool isLatest;
}

/// 把一段文本压成单行并只保留前 [maxChars] 个字符。
///
/// - **折叠空白**：轮次摘要常含换行/缩进（用户粘多段文本），不折叠会让面板
///   某一行突然变高，甚至把别的轮次挤出视野；
/// - **按 runes 截断**：`String.substring` 会切碎代理对（emoji、
///   部分 CJK 扩展平面字符），渲染出 `�`；按码位截断至少不会产生乱码；
/// - **超长才加省略号**：等于 `maxChars` 时不加，避免「刚好 24 字也带 …」的假信号。
String truncateTurnLabel(String raw, {int maxChars = kTurnRailLabelMaxChars}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '';
  if (maxChars <= 0) return '';
  final runes = flat.runes;
  if (runes.length <= maxChars) return flat;
  final head = String.fromCharCodes(runes.take(maxChars));
  return '$head…';
}

/// 从已加载的对话项投影出导航条的轮次列表（**旧 → 新**，与消息流同序）。
///
/// ## 为什么是「旧 → 新」而不是像 `groupItemsByTurn` 那样最新在前
///
/// 两者的用途相反：`groupItemsByTurn` 供「待办 / 工具调用」面板用，那里关心
/// 「最新的待处理」故最新在前；导航条是**目录**，顺序必须与消息流一致，
/// 否则用户按刻度上下来回穿梭时会发现相邻两格在正文里的相对位置也是反的。
///
/// ## 为什么不丢空 turnId 的项
///
/// 与 [isLatestTurn] 同口径：`turnId` 归一后为 null 的项（乐观回显、无归属
/// 确认卡）**不参与**投影。它们既不属于任何一轮，也不该在目录里占一格——
/// 占一格会得到「点进去什么都不发生」的死格。
///
/// ## 一轮的标签取「该轮最后一条用户消息」
///
/// 服务端会重发 `user_message`（同一 turnId），归约器按 turnId 原位合并，
/// 实际只有一条；这里防御性地取最后一条，保证拿到正文最完整的版本
/// （与 `TurnGroup.userInput` 同一取向）。
List<TurnRailEntry> buildTurnRailEntries(
  Iterable<ConversationItem> items, {
  int maxChars = kTurnRailLabelMaxChars,
}) {
  final order = <String>[];
  final createdAt = <String, DateTime>{};
  final lastUserText = <String, String>{};

  for (final item in items) {
    final turnId = normalizeTurnAnchor(item.turnId);
    if (turnId == null) continue;
    if (!createdAt.containsKey(turnId)) {
      order.add(turnId);
      createdAt[turnId] = item.createdAt;
    }
    if (item is UserMessageItem) lastUserText[turnId] = item.text;
  }

  final entries = <TurnRailEntry>[];
  for (var i = 0; i < order.length; i++) {
    final turnId = order[i];
    final label = truncateTurnLabel(
      lastUserText[turnId] ?? '',
      maxChars: maxChars,
    );
    entries.add(
      TurnRailEntry(
        turnId: turnId,
        label: label.isEmpty ? kTurnRailEmptyLabel : label,
        createdAt: createdAt[turnId]!,
        index: i + 1,
        isLatest: i == order.length - 1,
      ),
    );
  }
  return entries;
}

/// 该行属于哪一轮（归一化后的 turn id；无归属返回 null）。
///
/// ## 为什么放在领域层
///
/// 一行可能是单条项、文件批量卡或工具调用折叠卡，三种形态取轮次的字段名不同。
/// 页面需要它的地方有两处（锚点高亮、导航条「视口顶部在哪一轮」），口径必须
/// 一致，故与 [locateIdsOf] 一样落在领域层。
String? turnIdOfRow(TimelineDisplayRow row) => switch (row) {
  SingleItemRow(:final item) => normalizeTurnAnchor(item.turnId),
  AgentFileBatchRow(:final files) => normalizeTurnAnchor(files.first.turnId),
  ToolCallBatchRow(:final calls) => normalizeTurnAnchor(calls.first.turnId),
};
