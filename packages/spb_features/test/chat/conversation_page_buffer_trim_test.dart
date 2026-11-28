import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 「多轮对话之后，查看大块正文时向下滚动会丢内容」的回归测试。
///
/// ## 用户看到的现象
///
/// 聊了几轮（其中有一条很长的回复），回头往上翻到那条长回复的中间继续往下
/// 滚——**那一大块正文消失了**，时间线上直接跳到别的内容。
///
/// ## 根因（不是渲染问题，是数据被裁掉了）
///
/// 服务端每个 token 发一条 `transient: true` 的增量事件（`pigo_core.go` 的
/// `flushEventTransient`），一个长回复就上千条。而 [ChatStreamController]
/// 的缓冲区上限是 2000 条（`maxBufferEvents`），超了就从**头部逐条**丢。
///
/// `EventReducer.reduce` 是**全量重算**——丢头部等于把归约的输入掐掉一截：
///
/// - 整轮对话从时间线上消失（丢的那一段里含 `user_message` / `start`）；
/// - 某条回复的开头被截掉（只丢了它的前几百条增量）；
/// - 流式期间 item 的 `id` 每来一条事件就变一次（id 取自「首条幸存的增量」
///   的 eventId）→ `ValueKey(item.id)` 抖动 → `AssistantMessageBubble` 的
///   Element 被销毁重建 → `gpt_markdown` 的增量解析状态全丢 → 气泡先塌成
///   十几像素再一个字一个字重新长出来。
///
/// 修复见 `chat_stream_controller.dart` 的 `_coalesceIntoTail`（紧邻同类
/// 增量先合并）与 `_turnBoundaryAtOrAfter`（裁剪按**整轮**丢）。
///
/// ## 为什么这组用例必须在**页面**层
///
/// 领域层的用例（`spb_domain/test/chat_stream_controller_history_test.dart`
/// 的「流式增量合并 + 按轮裁剪」组）只断言归约结果。而用户看到的是
/// **widget 树**——若页面层的 `_displayRows` / 定位键回收 / 气泡缓存里有
/// 独立的缺陷，归约结果正确也照样会空白。故这里两条都断。
void main() {
  setUpHarness();
  tearDownHarness();

  /// 一段够长（远超一屏）、带可辨识开头标记的 Markdown。
  String bigBody(String tag) => [
    '## $tag 的开头标记',
    for (var i = 0; i < 40; i++)
      '第 $i 段：$tag 的正文占位内容，用来把这段回复撑得足够高，'
          '好让用户能滚到它的中间去看。',
  ].join('\n\n');

  /// 推一条**已完结**（非 transient）的助手回复。
  ///
  /// 必须先推 `start`：归约层靠它把 `currentAssistantIdx` 置空，否则连续
  /// 几条 `message` 会被判成「同一段落」（见 `event_reducer.dart`）。
  Future<void> pushReply(
    WidgetTester tester, {
    required String id,
    required String turnId,
    required String text,
    required int seq,
  }) async {
    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: 'start_$id',
        turnId: turnId,
        payload: const {},
        seq: seq,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: id,
        turnId: turnId,
        payload: {'text': text},
        seq: seq + 1,
      ),
    );
  }

  /// 一次性推 [count] 条流式增量，**中间不 pump**。
  ///
  /// 真实 SSE 事件之间隔着网络往返，天然是 N 个独立的事件循环轮次；这里
  /// 用「一个 `runAsync` 里连续 push + 末尾等几个真实轮次」模拟同一批到达
  /// 的突发。不用 `pushEvent`：它每条都 `pump()`，2100 条会把用例拖到分钟级。
  Future<void> pushIncrements(
    WidgetTester tester, {
    required String turnId,
    required int count,
    String Function(int i)? textOf,
  }) async {
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        sse.push(
          EventTypes.message,
          sseEvent(
            EventTypes.message,
            id: 'inc_$i',
            turnId: turnId,
            payload: {'content': textOf?.call(i) ?? '段$i。'},
            transient: true,
            seq: i,
          ),
        );
      }
      // 归约被合并到一个零延迟 `Timer`，且它落在**真实**时区（见
      // `pushEvent` 的文档）——`tester.pump()` 永远跑不到它。
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
  }

  /// 归约结果里所有助手回复的正文。
  List<String> assistantTexts() => controller.snapshot
      .whereType<AssistantMessageItem>()
      .map((i) => i.text)
      .toList();

  /// 树上（含 offstage / keep-alive）是否有正文包含 [needle] 的气泡。
  ///
  /// 不用 `find.textContaining`：`GptMarkdown` 把一段 Markdown 渲染成多个
  /// `RichText`，跨段的字符串拼不回来（见 `conversation_page_perf_test.dart`
  /// 的同名说明）。
  bool mountedBubbleWithText(WidgetTester tester, String needle) => tester
      .widgetList<AssistantMessageBubble>(
        find.byType(AssistantMessageBubble, skipOffstage: false),
      )
      .any((w) => w.text.contains(needle));

  /// 时间线（视口最大的那个竖向 `Scrollable`）的滚动位置。
  ScrollPosition timelinePosition(WidgetTester tester) {
    final states = tester
        .stateList<ScrollableState>(
          find.byType(Scrollable, skipOffstage: false),
        )
        .where((s) => s.position.axis == Axis.vertical)
        .toList();
    states.sort(
      (a, b) =>
          b.position.viewportDimension.compareTo(a.position.viewportDimension),
    );
    return states.first.position;
  }

  testWidgets('用户正读着一大块正文时，后续流式增量不得把它挤掉', (tester) async {
    // 视口做小一点，长正文必须真的可滚动，才能复现「滚到中间」。
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // ① 第一轮：一条很长的已完结回复（用户等下要回头看的就是它）。
    final big = bigBody('大正文');
    await pushReply(tester, id: 'r0', turnId: 'turn_0', text: big, seq: 1);
    await tester.pumpAndSettle();
    expect(assistantTexts(), hasLength(1), reason: '前置：第一轮的回复已就位');

    // ② 用户滚到大正文的**中间**（不是底部——底部会触发跟随滚动）。
    final position = timelinePosition(tester);
    expect(position.maxScrollExtent, greaterThan(0), reason: '前置：内容必须真的可滚动');
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pumpAndSettle();

    // ③ 第二轮开始流式输出：2100 条增量（**超过** 2000 条缓冲上限）。
    //
    // 修复前：这 2100 条把缓冲区顶到 2102 条 → 从头部逐条丢 102 条 →
    // `turn_0` 的 `start` + `message` 正好在头部 → 用户正在读的那块正文
    // **从归约结果里消失**（实测 scratch：`[h] 归约结果里还有大正文: false`）。
    await pushIncrements(tester, turnId: 'turn_1', count: 2100);
    await tester.pumpAndSettle();

    expect(
      controller.bufferedEventCount,
      lessThanOrEqualTo(ChatStreamController.maxBufferEvents),
      reason: '缓冲上限是硬约束，不能被流式增量突破',
    );

    // ④ 核心断言：大正文必须**还在**（数据层 + widget 层都断）。
    expect(
      assistantTexts().any((t) => t.contains('大正文 的开头标记')),
      isTrue,
      reason:
          '用户正在读的大块正文被缓冲区裁剪挤掉了——'
          '这正是「多轮之后向下滚动内容丢失」的根因。'
          '实测修复前 assistantTexts=${assistantTexts().map((t) => t.length).toList()}',
    );
    expect(
      mountedBubbleWithText(tester, '大正文 的开头标记'),
      isTrue,
      reason: '数据层还在，但 widget 层也必须真的把它渲染出来',
    );

    // ⑤ 第二轮自己的正文也必须是完整的（合并不得丢字）。
    final second = assistantTexts().firstWhere((t) => t.contains('段0。'));
    expect(second, contains('段2099。'), reason: '合并后的正文结尾不得丢失');
    expect(
      second.indexOf('段0。'),
      lessThan(second.indexOf('段1。')),
      reason: '合并必须保持顺序',
    );
  });

  testWidgets('单轮流式 2100 条增量：item id 恒定、正文从第一段开始', (tester) async {
    // 这一条钉的是「流式期间气泡塌掉再重新长出来」的成因：item 的 `id` 取自
    // **首条幸存增量**的 eventId。缓冲区一旦从头部丢事件，id 就变成
    // `inc_100` 之类，`ValueKey(item.id)` 抖动 → Element 销毁重建 →
    // `gpt_markdown` 的 `_engine.reset()` → 气泡先塌成十几像素再重新打字。
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: 'start_1',
        turnId: 'turn_1',
        payload: const {},
      ),
    );
    await pushIncrements(tester, turnId: 'turn_1', count: 2100);
    await tester.pumpAndSettle();

    final item = controller.snapshot.whereType<AssistantMessageItem>().single;
    expect(
      item.id,
      'inc_0',
      reason: 'item id 必须是**首条**增量的 eventId；变成 inc_N 就说明头部被裁了',
    );
    expect(
      item.text.startsWith('段0。'),
      isTrue,
      reason: '正文开头被截掉了（实测修复前从「段100。」开始）',
    );
    expect(item.text, endsWith('段2099。'));
    expect(item.isStreaming, isTrue, reason: '还没收到权威帧 / done，应仍是流式态');

    // 气泡必须真的把这 2100 段渲染出来，而不是塌成一行占位。
    expect(
      mountedBubbleWithText(tester, '段0。'),
      isTrue,
      reason: '首段必须在气泡里（修复前首段已被裁掉，永远渲染不出来）',
    );
  });
}
