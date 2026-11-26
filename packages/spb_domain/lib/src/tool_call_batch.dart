/// 时间线**展示层**的连续工具调用折叠。
///
/// 与 [groupFileEventsForDisplay] 同取向：**只改展示形态，不改归约结果**。
///
/// ## 为什么绝不能在归约层折叠
///
/// `ConversationItem` 是**数据**，折叠只是「这一帧怎么画」。一旦在归约层把
/// N 条 `ToolCallItem` 合成一条：
///
/// 1. **对话内搜索会静默失效**——`conversation_search.dart` 的
///    `_searchableTextFor` 会搜工具名 + 参数 + 输出，用户明确要求「折叠不能
///    让搜索静默失效」。数据里没了条目，搜索就会报「没有命中」，而用户无法
///    区分「没有」与「被折叠了」。
/// 2. **搜索定位会失效**——命中项拿到的 id 在时间线里不存在，只能退化成
///    「请向上滚动」。
/// 3. **看门狗会误判**——`EventReducer.inFlightTurnIds` 把未完成的
///    `ToolCallItem` 算作「turn 仍在跑」的证据（长工具期间既无正文也无思考）。
///    合并成一条就丢掉了逐条的 `output == null` 状态。
///
/// 故本文件与 `agent_file_batch.dart` 一样，输入是归约结果、输出是展示行，
/// 且**不丢任何 item**（[locateIdsOf] 对折叠行返回全部成员 id）。
library;

import 'agent_file_batch.dart';
import 'conversation_item.dart';

/// 连续工具调用折叠成一张卡的最小条数。
///
/// 取 **5**，与 [FILE_BATCH_MIN_COUNT] 同值。理由与文件批量卡同构：两三次
/// 工具调用是正常对话节奏（折叠反而藏信息），一二十条才是噪声。
// ignore: constant_identifier_names
const int TOOL_CALL_BATCH_MIN_COUNT = 5;

/// 归约结果 → 时间线展示行（**页面唯一入口**）。
///
/// = 先按文件聚合，再把剩下的连续工具调用折叠。两趟的顺序不能反：文件聚合
/// 会把非文件项当断点，工具调用聚合把非工具行当断点，二者互不干扰，但反过来
/// 做会让「文件批 + 工具批」的边界判定多一趟无用的形状转换。
List<TimelineDisplayRow> groupTimelineForDisplay(
  List<ConversationItem> items,
) => groupToolCallsForDisplay(groupFileEventsForDisplay(items));

/// 把连续、同 turn 的工具调用行折叠成 [ToolCallBatchRow]。
///
/// [rows] 是**展示行**（通常是 [groupFileEventsForDisplay] 的输出），故文件
/// 批量卡本身就是一个断点——不会把工具调用吸进文件批，也不会被文件批打断
/// 之外的顺序。
///
/// ## 口径
///
/// | 规则 | 结论 | 为什么 |
/// |---|---|---|
/// | 断点 | 任何非「单条工具调用」的行（正文、思考、文件卡、确认卡……） | 用户读的是正文，折叠必须只在「连着全是工具」的区间内发生 |
/// | 分组键 | 同一 `turnId` | 同一 turn 内的连续调用才是「一段工作」；跨 turn 合并会把两件事说成一件（与文件批同理） |
/// | `turnId` 为空 | **不折叠**，整段按单条渲染 | 空 turnId 意味着「归属未知」，此时相邻两条可能来自不同 turn，合并就是在撒谎。宁可不折叠 |
/// | 阈值 | 折叠后 ≥ [TOOL_CALL_BATCH_MIN_COUNT] 才成卡 | 与文件批同一取向：不足阈值就原样吐出，保持逐条渲染 |
/// | 时间 | **不参与判定** | 工具调用是串行的，一批 20 次横跨几分钟；按秒分组会让阈值永不满足（详见 [ToolCallBatchRow] 的对照表） |
List<TimelineDisplayRow> groupToolCallsForDisplay(
  List<TimelineDisplayRow> rows,
) {
  final out = <TimelineDisplayRow>[];
  // 当前累积的工具调用批（存原行对象，不足阈值时原样退回，保持身份）。
  var run = <SingleItemRow>[];
  var runTurnId = '';

  void flush() {
    if (run.isEmpty) return;
    if (run.length >= TOOL_CALL_BATCH_MIN_COUNT) {
      out.add(
        ToolCallBatchRow(
          calls: [for (final row in run) row.item as ToolCallItem],
        ),
      );
    } else {
      out.addAll(run);
    }
    run = <SingleItemRow>[];
    runTurnId = '';
  }

  for (final row in rows) {
    // 只有「单条工具调用」能进批；`turnId` 为空的也不能进（见口径表）。
    final tool =
        row is SingleItemRow &&
            row.item is ToolCallItem &&
            (row.item.turnId).isNotEmpty
        ? row
        : null;
    if (tool == null) {
      flush();
      out.add(row);
      continue;
    }
    final turnId = tool.item.turnId;
    if (run.isNotEmpty && turnId != runTurnId) flush();
    run.add(tool);
    runTurnId = turnId;
  }
  flush();
  return out;
}
