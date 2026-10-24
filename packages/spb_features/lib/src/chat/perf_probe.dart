import 'package:flutter/foundation.dart';

/// 对话页 build 路径的性能计数器（**只在测试里读**）。
///
/// ## 它解决什么问题
///
/// 「对话页每次 build 扫了多少条 item」「这次推送触发了几次跟随滚动」这类
/// 事实，在没有 `DISPLAY` 的本机（AGENTS.md §9）无法靠帧率验证，也**不能**
/// 靠毫秒断言——毫秒随机器、debug/release、并发负载漂移，写进测试就是
/// flaky。
///
/// 计数器给的是**结构事实**：修复前 `_streamingItem` 在一次 build 里被三个
/// 地方各调一次（3 次 O(n) 尾向扫描），修复后一次。这个数字与机器无关，
/// 能稳定钉住「不再回退」。
///
/// ## 为什么是静态计数器而不是依赖注入
///
/// 被计数的是 `State` 的私有方法（`_findStreamingItem` / `_displayRows` /
/// `_followBottom`），它们由页面自己调用，页面无法把自己「传进去」。静态
/// 计数器是唯一不需要改公开 API（`ConversationPage` 有 46 个具名参数，
/// 再加参数要动 `tools/check_wiring_parity.sh` 的豁免表）的通道。
///
/// 仓库已有同类先例：`RowLocateRegistry.length`、`formatTokenCount` /
/// `formatTurnElapsed` 都是 `@visibleForTesting` 的观测点。
///
/// ## 生产里的代价
///
/// 每次自增是一个 `int` 的 `++`，无分配、无分支。它**不会**被清零，故
/// 数值随运行时长单调增长——但生产路径**从不读取**它们，故不影响行为。
/// 不做 `kDebugMode` 门控：那会让「release 构建里计数器不生效」成为一条
/// 需要单独验证的差异，而它省下的那点开销测不出来。
abstract final class PerfProbe {
  /// build 期线性扫描**检查过的 item 条数**（不是扫描次数）。
  ///
  /// 计的是「`_findStreamingItem` 与 `_visibleActivityFor` 里每读一个 item
  /// 就 +1」，故它直接反映「一次 build 看了多少条历史」。
  ///
  /// 判据：`_items` 有 n 条、且其中**没有**流式项时，一次 build 至多 n 次
  /// （尾向扫描要走到头部才能确认「没有」）。修复前是 3n（三个调用点各扫
  /// 一遍全表）。
  static int visitedItems = 0;

  /// `_displayRows()` 真正重算了展示行的次数。
  ///
  /// `_items` 未变（`identical` 相同）时命中缓存，不计数。故「推一条 activity
  /// 事件触发 setState」应当增量为 0，「推一条新 item」增量为 1。
  static int displayRowsComputations = 0;

  /// `_followBottom` 实际被执行的次数（含「已在底部直接返回」的调用）。
  ///
  /// 用来钉住「一次 items 推送最多调度一次跟随」：修复前 `_onItems` 与
  /// `_onScroll` 各自 `addPostFrameCallback(_followBottom)`，同一帧的
  /// post-frame 阶段会连跑两次。
  static int followBottomCalls = 0;

  /// `AssistantMessageBubble.build` 的执行次数。
  ///
  /// 用于「流式期间未变气泡是否重复 build」的测量。
  static int assistantBubbleBuilds = 0;

  /// 全部清零。测试在 `setUp` 里调用（计数器是进程级的，会跨用例累积）。
  @visibleForTesting
  static void reset() {
    visitedItems = 0;
    displayRowsComputations = 0;
    followBottomCalls = 0;
    assistantBubbleBuilds = 0;
  }
}
