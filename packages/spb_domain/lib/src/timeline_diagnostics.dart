import 'package:meta/meta.dart';

import 'conversation_item.dart';

/// 一轮对话的正文统计（诊断用，**不含正文本身**）。
@immutable
class TurnTextStat {
  const TurnTextStat({
    required this.turnId,
    required this.chars,
    required this.items,
    required this.isStreaming,
  });

  /// 服务端 turn id（分组键）。
  final String turnId;

  /// 该轮**助手正文**的字符数（`String.length`，不是字节）。
  ///
  /// 只统计 [AssistantMessageItem]：用户消息由客户端发出、不会「消失在渲染里」，
  /// 工具卡的价值在入参/输出（另有搜索路径），正文才是用户报障时说的「那一大块」。
  final int chars;

  /// 该轮正文气泡的条数（一句回复被工具打断时会分成多段）。
  final int items;

  /// 该轮是否仍有段在流式（`isStreaming`）。
  final bool isStreaming;
}

/// 时间线的「数据面」快照：回答**「正文是不是在客户端就已经没了」**。
///
/// ## 为什么需要它
///
/// 「回复的大块内容消失」有两种完全不同的成因，肉眼与截图都分不开：
///
/// | 成因 | 判据 |
/// |---|---|
/// | 数据层：事件被裁 / 回放被截断 | 快照里 `assistant_chars` 本身就少；`trim_count` 涨过 |
/// | 渲染层：数据在、像素没画 | `assistant_chars` 正常，**对话内搜索仍能命中**那段文字 |
///
/// 报障时用户只能给一张截图，故必须有一条**数字证据**能区分两者。本快照
/// 就是那条证据：它进日志环形缓冲、进导出诊断报告，且**只在低频节点**采集
/// （一轮结束 / 裁剪 / 回放修复），不进每帧路径。
///
/// ## 为什么不带正文
///
/// 诊断报告会被用户贴进公开 issue（[SpbLog] 的脱敏只能处理「看起来像凭据」
/// 的串）。因此这里**只存数字与 id**：字符数、条数、globalSeq、group/turn id。
/// 单看这些无法还原用户内容，但足以定位「少的是哪一轮、少了多少」。
@immutable
class TimelineDiagnostics {
  const TimelineDiagnostics({
    required this.groupId,
    required this.bufferedEvents,
    required this.maxBufferEvents,
    required this.itemCount,
    required this.assistantChars,
    required this.turns,
    required this.oldestLoadedGlobalSeq,
    required this.newestBufferedGlobalSeq,
    required this.trimCount,
    required this.lastTrimDropped,
    required this.lastTrimKept,
    required this.lastTrimPerTurn,
    required this.fromCache,
    required this.replayGapRepairs,
    required this.sseCursorPresent,
  });

  /// 当前聚焦的 group（null = 全局模式，没有时间线）。
  final String? groupId;

  /// 缓冲区里的事件条数（合并后的）。
  final int bufferedEvents;

  /// 缓冲区上限（见 `ChatStreamController.maxBufferEvents`）。
  final int maxBufferEvents;

  /// 归约产出的对话项总数。
  final int itemCount;

  /// 全部助手正文的字符数合计。
  final int assistantChars;

  /// 逐轮统计（按字符数降序，便于一眼看出「最长的那条还在不在」）。
  final List<TurnTextStat> turns;

  /// 向上翻页的游标（`_oldestLoadedGlobalSeq`）。
  final int? oldestLoadedGlobalSeq;

  /// 缓冲区里见过的最大落库 `globalSeq`。
  ///
  /// 与 [oldestLoadedGlobalSeq] 一起构成「本地覆盖到哪一段」的区间。回放缺口
  /// 探测就比它和「服务端该 group 的最新 globalSeq」。
  final int? newestBufferedGlobalSeq;

  /// 本次聚焦期间发生过几次缓冲区裁剪（含单轮降级）。
  final int trimCount;

  /// 最近一次裁剪丢弃的事件条数。
  final int lastTrimDropped;

  /// 最近一次裁剪后保留的事件条数。
  final int lastTrimKept;

  /// 最近一次裁剪是否按**整轮**丢弃（false = 单轮超限的逐条降级）。
  final bool lastTrimPerTurn;

  /// 时间线是否来自本地缓存（离线回落）。
  final bool fromCache;

  /// 本次聚焦期间触发过几次「回放被截断 → timeline 整段回填」。
  final int replayGapRepairs;

  /// 连上时是否带得上游标（无游标 = 首次连接，服务端不会回放）。
  final bool sseCursorPresent;

  /// 只更新「计数与区间」这几个 **O(1)** 字段，其余（正文统计 / 逐轮明细）
  /// 保持原值。
  ///
  /// ## 为什么需要「部分更新」
  ///
  /// 缓冲满了之后**每来一条事件就裁一次**（见 `_recordTrim`），而每次都重算
  /// 全量快照要一次归约（2000 条实测 1767 µs，AGENTS.md §6.23）——那就把
  /// §6.23 刚消灭的 O(n²) 又请回来了。故拆成两档：
  ///
  /// | 字段 | 更新频率 | 代价 |
  /// |---|---|---|
  /// | 缓冲条数 / 裁剪次数 / 丢留条数 / globalSeq 区间 | **每次裁剪** | O(1) |
  /// | 正文总字符数 / 逐轮明细 | 首次裁剪 + 每 30s + 每轮 `done` | 一次归约 |
  ///
  /// 代价是 [assistantChars] 可能**比当前实际值大**（此后又裁掉了几轮）。
  /// 报告里判断「有没有被裁」以 [trimCount] 为准，字符数只用来看量级。
  TimelineDiagnostics withTrimStats({
    required int bufferedEvents,
    required int trimCount,
    required int lastTrimDropped,
    required int lastTrimKept,
    required bool lastTrimPerTurn,
    required int? oldestLoadedGlobalSeq,
    required int? newestBufferedGlobalSeq,
    required int replayGapRepairs,
    required bool sseCursorPresent,
    required bool fromCache,
  }) => TimelineDiagnostics(
    groupId: groupId,
    bufferedEvents: bufferedEvents,
    maxBufferEvents: maxBufferEvents,
    itemCount: itemCount,
    assistantChars: assistantChars,
    turns: turns,
    oldestLoadedGlobalSeq: oldestLoadedGlobalSeq,
    newestBufferedGlobalSeq: newestBufferedGlobalSeq,
    trimCount: trimCount,
    lastTrimDropped: lastTrimDropped,
    lastTrimKept: lastTrimKept,
    lastTrimPerTurn: lastTrimPerTurn,
    fromCache: fromCache,
    replayGapRepairs: replayGapRepairs,
    sseCursorPresent: sseCursorPresent,
  );

  /// 日志字段（snake_case，与 Go API 的 slog 约定一致）。
  ///
  /// ⚠️ 键名是**报告契约**：报障时人工比对客户端日志与服务端日志靠它。
  Map<String, Object?> toLogFields() {
    final longest = turns.isEmpty ? null : turns.first;
    return {
      'group_id': groupId ?? '',
      'buffered_events': bufferedEvents,
      'max_buffer_events': maxBufferEvents,
      'items': itemCount,
      'assistant_chars': assistantChars,
      'turn_count': turns.length,
      if (longest != null) 'longest_turn_chars': longest.chars,
      if (longest != null) 'longest_turn_id': longest.turnId,
      'oldest_loaded_global_seq': oldestLoadedGlobalSeq,
      'newest_buffered_global_seq': newestBufferedGlobalSeq,
      'trim_count': trimCount,
      'last_trim_dropped': lastTrimDropped,
      'last_trim_kept': lastTrimKept,
      'last_trim_per_turn': lastTrimPerTurn,
      'from_cache': fromCache,
      'replay_gap_repairs': replayGapRepairs,
      'sse_cursor_present': sseCursorPresent,
    };
  }

  /// 导出诊断报告里的「## 时间线快照」小节（一行一个键值）。
  ///
  /// [turnLimit] 限制逐轮明细的条数：报告是给人看的，列 200 轮没有意义。
  List<String> toReportLines({int turnLimit = 10}) {
    final lines = <String>[
      'group_id: ${groupId ?? '(全局模式)'}',
      '缓冲事件: $bufferedEvents / $maxBufferEvents',
      '对话项: $itemCount（其中助手正文 $assistantChars 字符）',
      '覆盖区间: globalSeq ${oldestLoadedGlobalSeq ?? '?'} .. '
          '${newestBufferedGlobalSeq ?? '?'}',
      '裁剪: 共 $trimCount 次，最近一次丢 $lastTrimDropped 条、'
          '留 $lastTrimKept 条（${lastTrimPerTurn ? '按整轮' : '单轮逐条降级'}）',
      '回放缺口修复: $replayGapRepairs 次；连上时${sseCursorPresent ? '有' : '无'}游标',
      '数据来源: ${fromCache ? '本地缓存（离线）' : '网络'}',
    ];
    if (turns.isEmpty) {
      lines.add('逐轮正文: （空）');
      return lines;
    }
    lines.add('逐轮正文（按字符数降序，最多 $turnLimit 轮）:');
    for (final t in turns.take(turnLimit)) {
      lines.add(
        '  - ${t.turnId.isEmpty ? '(无 turnId)' : t.turnId}: '
        '${t.chars} 字符 / ${t.items} 段'
        '${t.isStreaming ? '（流式中）' : ''}',
      );
    }
    if (turns.length > turnLimit) {
      lines.add('  … 另有 ${turns.length - turnLimit} 轮未列出');
    }
    return lines;
  }
}

/// 进程内「最近一份时间线快照」。
///
/// ## 为什么是静态单例（而不是走 provider）
///
/// 导出诊断报告发生在**设置页**，而 [ChatStreamController] 是
/// `Provider.autoDispose.family`——离开对话页即释放，生成报告时它**通常已经
/// 没了**。要从页面拿实时快照，就得把控制器生命周期改成常驻（多一条长连接、
/// 移动端持续耗电），代价远大于收益。
///
/// 故由控制器在低频节点把**纯数字快照**写到这里，报告直接读最近一份。这与
/// `PerfProbe`（性能计数）/ `EndpointGuard.instance`（端点状态）是同一取向：
/// 这类「进程级观测值」不属于某一棵 widget 树。
///
/// ## 为什么可以静态持有（不泄漏、不涉密）
///
/// - **容量有界**：只保留最近一份，字段全是数字与 id；
/// - **不含正文**：见 [TimelineDiagnostics] 的说明；
/// - **退出即失**：不落盘。用户登出后残留的只有上一个账号的 group/turn id 与
///   字符数，不构成内容泄漏，但 `reset()` 仍会在需要时清掉（测试与登出）。
class TimelineProbe {
  TimelineProbe._();

  static TimelineDiagnostics? _latest;

  /// 最近一份快照（未采集过为 null）。
  static TimelineDiagnostics? get latest => _latest;

  /// 记录一份快照（后写覆盖先写）。
  static void record(TimelineDiagnostics diagnostics) {
    _latest = diagnostics;
  }

  /// 清空（测试隔离 / 登出）。
  @visibleForTesting
  static void reset() {
    _latest = null;
  }
}
