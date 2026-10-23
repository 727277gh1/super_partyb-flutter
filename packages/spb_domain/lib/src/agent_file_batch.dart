import 'conversation_item.dart';

/// 聚合阈值：连续同秒段达到该数量才折叠成批量卡。
///
/// **取值 5，对齐 webapp `agent-file.ts:14` 的 `FILE_BATCH_MIN_COUNT`**（其注释
/// 说明「取值对齐小程序 `file-batches.FILE_BATCH_MIN_COUNT`：常规单次产出多在
/// 1–4 个」）。低于阈值逐条渲染，保留单文件的过程感。
///
/// 不硬编码在渲染层：这是**口径**（webapp / 小程序 / 客户端三端应一致），
/// 而口径属于领域层。
//
// 全大写而非常规的 lowerCamelCase：本常量是**跨仓库的同一个标识符**
// （webapp `agent-file.ts:14` / 小程序 `file-batches.ts` 同名）。保持一致让
// 「三端口径是否漂移」可以用一条 grep 跨仓库比对——这比遵守命名风格更重要。
// ignore: constant_identifier_names
const int FILE_BATCH_MIN_COUNT = 5;

/// 展示行：时间线渲染前的最后一步产物。
///
/// ## 为什么单独一个类型，而不是新增 `ConversationItem` 子类
///
/// [ConversationItem] 是**归约结果**（权威数据），而聚合纯属**展示形态**：
/// 同一条时间线，窗口宽时可能想逐条、窄时想折叠。把它写进归约结果会让
/// 「数据」与「这一帧怎么画」耦合，且 `ConversationItem` 是 sealed 家族
/// （新增子类会连带影响所有 `switch` 与 `inFlightTurnIds` 之类的遍历）。
///
/// 与 `#9` 超时兜底同一取向：**派生信号不改归约**。
sealed class TimelineDisplayRow {
  const TimelineDisplayRow();
}

/// 单条渲染：一个原始 [ConversationItem]（文件或任何非文件项）。
///
/// 非文件项也包一层，让「时间线 → 展示行」是一个**全量映射**（而不是只映射
/// 文件、其余靠调用方自己穿插）。这样渲染层只需一个 `switch`，不必同时维护
/// 「第几个原始项」与「第几个展示行」两套下标。
final class SingleItemRow extends TimelineDisplayRow {
  const SingleItemRow(this.item);

  final ConversationItem item;
}

/// 批量卡：一段连续同秒、同 turn 的 agent 文件（≥ [FILE_BATCH_MIN_COUNT] 个）。
final class AgentFileBatchRow extends TimelineDisplayRow {
  const AgentFileBatchRow({required this.files, required this.verb});

  /// 批内成员，保持时间线原始顺序（展开后按此顺序逐条渲染）。
  final List<AgentFileItem> files;

  /// 标题动词：`生成` / `更新` / `删除`（见 [agentFileBatchVerb]）。
  final String verb;

  int get count => files.length;
}

/// 一行在时间线搜索定位中占用的全部 `item.id`。
///
/// ## 为什么放在领域层
///
/// 「哪条 id 对应哪个定位点」是**口径**而非渲染细节：批量卡的每个成员都必须
/// 能被定位到同一张卡（见 `conversation_page.dart` 的 `_rowKeys` 注释），而
/// 页面用它做两件事——注册定位键、**回收**已不在时间线上的键（issue #39）。
/// 两处必须用同一份口径，否则回收会把仍在渲染的行的键删掉。
///
/// 纯函数、无 Flutter 依赖，故可在无头环境逐行断言。
List<String> locateIdsOf(TimelineDisplayRow row) => switch (row) {
  SingleItemRow(:final item) => [item.id],
  AgentFileBatchRow(:final files) => [for (final f in files) f.id],
};

/// 当前时间线上**全部**可用于定位的 `item.id`。
///
/// 页面用它与 `_rowKeys` 求差，回收已裁剪项的键：`_rowKeys` 只 `putIfAbsent`
/// 的话会随裁剪/切 group 持续累积（且旧 `GlobalKey` 会阻止 Element 回收）。
Set<String> locateIdsOfAll(List<TimelineDisplayRow> rows) => {
  for (final row in rows) ...locateIdsOf(row),
};

/// 事件的「秒」分组键：截断到秒，**不**用 `Date.parse`。
///
/// 对齐 webapp `secondOf` 的 `createdAt.slice(0, 19)`：那里刻意不解析日期，
/// 因为「同一秒」是**存储格式上的前缀相等**，而不是时间运算——用解析器会引入
/// 时区与格式差异（服务端存的是 RFC3339，但历史数据可能有别的形态）。
///
/// Dart 侧 [AgentFileItem.createdAt] 已经是解析后的 `DateTime`（归约器统一
/// `.toUtc()`），故这里取 `toIso8601String()` 的前 19 字符——得到
/// `2026-09-14T00:00:00`，与 webapp 的键**逐字符相同**。
String agentFileSecondOf(DateTime createdAt) {
  final s = createdAt.toUtc().toIso8601String();
  return s.length >= 19 ? s.substring(0, 19) : s;
}

/// 批量卡标题动词：按批内**最新态**动作选词。
///
/// ## 为什么必须含删除
///
/// 只按「有没有 modified」判会让删除批显示成「生成了 N 个文件」——用户以为
/// 刚产出了 N 个文件，实际是刚被删掉 N 个。阶段优先级 `deleted > modified >
/// created` 与归约器 `_fileStageRank` 同一套（乱序到达时 action 只前进不后退）。
String agentFileBatchVerb(Iterable<AgentFileItem> files) {
  var best = 0; // created
  for (final f in files) {
    final rank = switch (f.action) {
      'deleted' => 2,
      'modified' => 1,
      _ => 0,
    };
    if (rank > best) best = rank;
  }
  return switch (best) {
    2 => '删除',
    1 => '更新',
    _ => '生成',
  };
}

/// 把时间线切成展示行：**连续同秒**段达阈值聚合成批量卡，否则逐条。
///
/// ## 聚合口径（照抄 webapp `groupFileEventsForDisplay`，勿自行发明）
///
/// | 规则 | 实现 |
/// |---|---|
/// | 阈值 | 段长 ≥ [FILE_BATCH_MIN_COUNT] 才聚合 |
/// | 分组键 | 同一 turn 内**同一秒**（[agentFileSecondOf]） |
/// | 连续性 | 只聚合**相邻**的同秒段；跨段不回溯 |
/// | TTS 排除 | `reports/tts/**`（`ttsKind != null`）永不参与聚合 |
///
/// ## 与 webapp 的一处必要差异：跨 turn 也要断段
///
/// webapp 的时间线**已按 turn 分组**（`ChatTurnGroup.fileEvents`），故它的
/// 循环里天然看不到跨 turn 的相邻。客户端的时间线是**扁平**的
/// `List<ConversationItem>`，所以必须显式把 `turnId` 纳入段键——否则「turn A
/// 的最后一秒」与「turn B 的第一秒」若恰好同秒就会被并成一批。
///
/// ## 非文件项也是断点
///
/// 一个 `ToolCallItem` 夹在两个文件之间时，这两个文件**不相邻**，不能合并
/// （否则「agent 先产了 3 个文件、调了个工具、又产了 3 个」会被折成一张卡，
/// 把中间的步骤藏起来）。
///
/// ## TTS 为什么是「断点 + 逐条」而不是「跳过」
///
/// TTS 分段是「同一 turn 的多段序列」，被批量卡吸收会丢失逐条顺序；而隐藏它们
/// 又会让语音产物在聊天页完全不可达（客户端尚无音频播放器，与 webapp 同一
/// 取舍，见其文件头注释）。故：先 flush 当前段（不让 TTS 插进文件批中间），
/// 再把它自己作为单条输出。
List<TimelineDisplayRow> groupFileEventsForDisplay(
  List<ConversationItem> items,
) {
  final rows = <TimelineDisplayRow>[];
  var run = <AgentFileItem>[];
  var runSecond = '';
  var runTurnId = '';

  void flush() {
    if (run.isEmpty) return;
    if (run.length >= FILE_BATCH_MIN_COUNT) {
      rows.add(
        AgentFileBatchRow(
          files: List<AgentFileItem>.unmodifiable(run),
          verb: agentFileBatchVerb(run),
        ),
      );
    } else {
      // 阈值以下逐条：保留单文件的过程感（一张「生成 3 个文件」的卡
      // 比三张卡更省地方，但也更看不见过程）。
      for (final f in run) {
        rows.add(SingleItemRow(f));
      }
    }
    run = <AgentFileItem>[];
  }

  for (final item in items) {
    // 1) 非文件项：断段 + 原样单条。
    if (item is! AgentFileItem) {
      flush();
      runSecond = '';
      runTurnId = '';
      rows.add(SingleItemRow(item));
      continue;
    }

    // 2) TTS 分段：断段 + 逐条（见上方文档）。
    if (item.ttsKind != null) {
      flush();
      runSecond = '';
      runTurnId = '';
      rows.add(SingleItemRow(item));
      continue;
    }

    // 3) 普通文件：同 turn 同秒才续段，否则先 flush 再起新段。
    final second = agentFileSecondOf(item.createdAt);
    if (run.isEmpty) {
      runSecond = second;
      runTurnId = item.turnId;
    } else if (second != runSecond || item.turnId != runTurnId) {
      flush();
      runSecond = second;
      runTurnId = item.turnId;
    }
    run.add(item);
  }

  flush();
  return rows;
}
