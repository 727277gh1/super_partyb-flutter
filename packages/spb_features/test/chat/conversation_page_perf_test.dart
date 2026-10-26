import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show CacheExtentStyle, ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 对话页 build 期成本的**结构**回归测试。
///
/// ## 为什么断言计数器而不是毫秒
///
/// 本机无 `DISPLAY`、无真机（AGENTS.md §9），毫秒随机器、debug/release、
/// 并发负载漂移——写进断言就是 flaky。计数器给的是**结构事实**（一次 build
/// 扫了多少条 item、展示行缓存是否命中、跟随滚动调度了几次），与机器无关。
///
/// 三个用例各自钉住一条「会静默回退」的改造：
///
/// 1. 每次 build 对 `_items` 的完整线性扫描至多一遍（修复前 `_streamingItem`
///    被 `_staleTurnItem` / `_canCancelTurn` / `_visibleActivity` 各调一次）；
/// 2. 展示行（`groupFileEventsForDisplay` + `locateIdsOfAll`）按 `identical`
///    缓存，同一份 `_items` 的多次 build 只算一次；
/// 3. 一帧内的多次推送只调度一次跟随滚动（修复前每次 `_onItems` 各排一个
///    post-frame 回调，后一个动画会取消前一个）。
void main() {
  setUpHarness();
  tearDownHarness();

  setUp(PerfProbe.reset);

  /// 推 n 条用户消息，**不 pump**（让它们全落在同一帧，模拟真实 SSE 的
  /// 「多个事件轮次之间没有新帧」）。
  ///
  /// 用 `user_message` 而不是 `executor_started`：前者产 `UserMessageItem`
  /// （无 `isStreaming`），正是「整条历史都没有流式项」这个最坏场景——尾向
  /// 扫描必须走到头部才能确认「没有」。
  Future<void> pushNoPump(WidgetTester tester, int n, {int from = 0}) async {
    await tester.runAsync(() async {
      for (var i = from; i < from + n; i++) {
        sse.push(
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'u$i',
            turnId: 'turn_$i',
            seq: i + 1,
            payload: {'input': '问题 $i'},
          ),
        );
      }
      // 归约被合并到一个零延迟 `Timer`，且它落在**真实**时区（见
      // `pushEvent` 的文档），故要多等几个真实轮次让每次推送各自完成。
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  /// 触发一次**纯 build**（`_items` 不变），用于测量「一次 build 的成本」。
  ///
  /// 用 `staleTurnIds` 通道而不是再推一条消息：它只 `setState`，不动 `_items`
  /// ——于是展示行缓存命中，测量到的 `visitedItems` 全部来自流式项扫描。
  ///
  /// ⚠️ **`tester.pump()` 本身不会触发 build**（实测：连续三次静止 pump 后
  /// `visitedItems` 仍为 0）。必须真的有一次 `setState`。
  Future<void> triggerBuild(WidgetTester tester, int tick) async {
    await tester.runAsync(() async {
      staleController.add(
        tick.isEven ? const {'tick_even'} : const {'tick_odd'},
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets('无流式项时，一次 build 至多扫 1 遍 items（修复前 3 遍）', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    const n = 200;
    await pushNoPump(tester, n);
    await tester.pump();
    expect(controller.snapshot, hasLength(n), reason: '前置：200 条历史都在');

    // 先让新 items 渲染出来，再清零计数器——否则首次布局的扫描会混进测量。
    await triggerBuild(tester, 0);
    PerfProbe.reset();

    // 两次纯 build（`_items` 不变，展示行命中缓存）。
    await triggerBuild(tester, 1);
    await triggerBuild(tester, 2);

    expect(
      PerfProbe.visitedItems,
      greaterThanOrEqualTo(n),
      reason: '两次 build 至少要扫一遍才能确认「没有流式项」——若为 0，说明计数器没接上',
    );
    expect(
      PerfProbe.visitedItems,
      lessThanOrEqualTo(2 * n),
      reason:
          '两次 build 至多各扫 1 遍。修复前 `_streamingItem` 被 '
          '_staleTurnItem / _canCancelTurn / _visibleActivity 各调一次，'
          '实测约 3n/次 build。',
    );
  });

  testWidgets('同一份 items 的多次 build 只算一次展示行', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);
    await pushNoPump(tester, 5);
    await tester.pump();

    PerfProbe.reset();

    // 两次纯 build：`_items` 实例没变，两次都应命中缓存。
    await triggerBuild(tester, 1);
    await triggerBuild(tester, 2);
    expect(
      PerfProbe.displayRowsComputations,
      0,
      reason: 'items 未变（identical 相同）时必须命中缓存',
    );

    // 一次推送 → 一次重算，随后的第二次 build 命中缓存。
    await pushNoPump(tester, 1, from: 100);
    await tester.pump();
    expect(PerfProbe.displayRowsComputations, 1, reason: 'items 变了必须重算一次');
    await tester.pump();
    expect(
      PerfProbe.displayRowsComputations,
      1,
      reason: '重算后紧跟着的那次 build 必须命中缓存（不能每次 build 都全量分组）',
    );
  });

  testWidgets('一帧内多次 items 推送只调度一次跟随滚动', (tester) async {
    // 视口刻意做小：内容必须真的可滚动，`_following` 才会是 true。
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 足够多才能把 `maxScrollExtent` 撑过一屏。
    await pushNoPump(tester, 30);
    await tester.pumpAndSettle();
    PerfProbe.reset();

    // ── 一帧内 5 次推送 ────────────────────────────────────────────────
    //
    // 每次都各自跑完一个事件循环轮次（`pushNoPump` 里那个 `runAsync`），
    // 于是 `_onItems` 被调用 5 次——但**中间不 pump**，它们全落在同一帧。
    //
    // ⚠️ 这正是流式回复的真实形态：`_emit` 的合并只合并「同一轮次内」的
    // 缓冲变更（issue #44），而真实 SSE 事件之间隔着网络往返，天然是 5 个
    // 独立轮次 → 5 次 `_onItems`。
    //
    // ⚠️ 不能用 `pushEvent`：它内部会 `pump()`，每次都把去重标记消耗掉，
    // 于是**修复前也会绿**（实测确认过）。
    for (var i = 100; i < 105; i++) {
      await pushNoPump(tester, 1, from: i);
    }
    expect(controller.snapshot, hasLength(35), reason: '前置：5 条都到了');

    await tester.pump();

    expect(
      PerfProbe.followBottomCalls,
      lessThanOrEqualTo(1),
      reason:
          '5 次 `_onItems` 各自 addPostFrameCallback 会让跟随滚 5 次；'
          '后 4 次会取消前一个动画并从当前位置重来，视觉上抖一下',
    );
  });

  // ── Markdown 气泡常驻（keep-alive） ────────────────────────────────
  //
  // 动机：`GptMarkdown` 的解析缓存（`_settled` 前缀）按 Element 存活。
  // `ListView.builder` 的子项滚出 `cacheExtent` 就 dispose，缓存全丢——
  // 滚回来要重新解析。实测（本机 2026-10，debug）60 段 8900 字符的冷重建
  // **441.6 ms**，而 Element 复用（暖重建）只需 **30.3 ms**。
  //
  // 但常驻**必须有界**：`RenderSliverMultiBoxAdaptor` 每帧仍要布局
  // keep-alive 的子项，2000 条历史全常驻比它要解决的问题更贵。

  /// 一段够长（>= 400 字符）、含多段落的 Markdown。
  ///
  /// 段落数刻意做多：`GptMarkdown` 的解析成本几乎与段数成线性，短文本测不出
  /// 「重新解析」这个行为。长度刻意推到 500 上下——必须稳过
  /// `_keepAliveMinChars`（400），否则用例测的是「短气泡不常驻」那条路径。
  String longMarkdown(String tag) => [
    '## $tag',
    for (var i = 0; i < 12; i++) '第 $i 段正文，$tag 的占位内容用来把长度推过阈值，再补一些字让它足够长。',
    '- 列表项 A',
    '- 列表项 B',
    '```dart',
    'final x = 1;',
    '```',
  ].join('\n\n');

  /// 推一段**已完结**（非 transient）的助手回复。
  ///
  /// ## 为什么要先推一个 `start`
  ///
  /// 归约层对 `message` 有三分支（`event_reducer.dart`）：增量帧追加、权威帧
  /// 替换、**非流式 message 独立成项**。而「非流式」判定依赖
  /// `isAuthoritativeFrame`——它要求本段已有进行中的段落。没有前置 `start`
  /// 时连续几条 `message` 会被判成「同一个段落」，实测 3 条消息只得到 1 个
  /// `AssistantMessageItem`（后两条覆盖前一条）。
  ///
  /// `start` 会把 `currentAssistantIdx` 置空（「新 turn 开始」），于是下一条
  /// `message` 独立成项——这正是真实时间线里「每轮一条回复」的形态。
  ///
  /// 不用 `pushStreamingMessage`：流式项会持续重建，测不到「Element 是否
  /// 被销毁」这个变量。
  Future<void> pushReply(
    WidgetTester tester, {
    required String id,
    required String text,
    required int seq,
  }) async {
    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: 'start_$id',
        turnId: 'turn_$id',
        payload: const {},
        seq: 1000 + seq,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: id,
        turnId: 'turn_$id',
        payload: {'text': text},
        seq: seq,
      ),
    );
  }

  /// 树上（含 offstage）是否还有某个正文包含 [needle] 的气泡。
  ///
  /// 不用 `find.textContaining`：`GptMarkdown` 把一段 Markdown 渲染成**多个**
  /// `RichText`（标题 / 段落 / 列表各一段），且 `RichText.text.toPlainText()`
  /// 不会把跨段的字符串拼回来——实测 `find.textContaining('目标回复')` 在气泡
  /// 明明可见时也返回 0。直接看 widget 的 `text` 字段才可靠。
  bool mountedBubbleWithText(WidgetTester tester, String needle) => tester
      .widgetList<AssistantMessageBubble>(
        find.byType(AssistantMessageBubble, skipOffstage: false),
      )
      .any((w) => w.text.contains(needle));

  /// 视口内（含 `cacheExtent`）的气泡数量。
  int visibleBubbleCount(WidgetTester tester) =>
      find.byType(AssistantMessageBubble).evaluate().length;

  /// 视口内（含 `cacheExtent`）是否还有某个正文包含 [needle] 的气泡。
  ///
  /// 与 [mountedBubbleWithText] 的区别：后者连 keep-alive 的 offstage 子项
  /// 也算。判「有没有滚出视口」必须用这个。
  bool visibleBubbleWithText(WidgetTester tester, String needle) => tester
      .widgetList<AssistantMessageBubble>(find.byType(AssistantMessageBubble))
      .any((w) => w.text.contains(needle));

  /// 时间线的滚动位置。
  ///
  /// ⚠️ 不能写 `find.byType(Scrollable).first`：页面上还有别的可滚动区域
  /// （输入框等），`.first` 的命中顺序不稳定。时间线是**视口最大**的那个。
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

  int mountedBubbleCount(WidgetTester tester) => find
      .byType(AssistantMessageBubble, skipOffstage: false)
      .evaluate()
      .length;

  testWidgets('长 Markdown 气泡常驻数量有上界，且不随历史长度增长', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    Future<void> pushReplies(int from, int to) async {
      for (var i = from; i < to; i++) {
        await pushReply(
          tester,
          id: 'r$i',
          text: longMarkdown('回复 $i'),
          seq: i + 1,
        );
      }
      await tester.pumpAndSettle();
    }

    // ① 20 条长回复（都超过 `_keepAliveMinChars`）。
    await pushReplies(0, 20);
    // ⚠️ 必须在推完内容之后再取位置：`_items` 为空时时间线渲染的是
    // `EmptyState`（根本没有 `Scrollable`），此时拿到的是输入区那个。
    final position = timelinePosition(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(position.viewportDimension * 2),
      reason: '前置：20 条长回复必须远超一屏',
    );

    // 滚到顶部：尾部窗口里的那 12 条已全部滚出视口。
    position.jumpTo(0);
    await tester.pumpAndSettle();

    final mounted20 = mountedBubbleCount(tester);
    final visible20 = visibleBubbleCount(tester);
    expect(
      mounted20,
      lessThan(20),
      reason:
          '必须真的发生了回收——否则这个用例证明不了「有界」。'
          '实测 mounted=$mounted20, visible=$visible20',
    );
    // `_keepAliveWindow` 是页面的私有常量，这里按它的契约写死 12。
    // 上界 = 窗口 12 + 视口内（`cacheExtent` 通常还会多带 1–2 条，故 +2）。
    expect(
      mounted20,
      lessThanOrEqualTo(12 + visible20 + 2),
      reason:
          '常驻必须有界：窗口 12 + 视口内（含 cacheExtent）。'
          '实测 mounted=$mounted20, visible=$visible20',
    );

    // ② 再推 20 条（共 40）。尾部窗口整体前移，原先那 12 条必须被释放
    //    ——若 `didUpdateWidget` 漏了 `updateKeepAlive()`，它们会永久常驻，
    //    常驻数随历史长度线性增长。
    await pushReplies(20, 40);
    position.jumpTo(0);
    await tester.pumpAndSettle();

    final mounted40 = mountedBubbleCount(tester);
    final visible40 = visibleBubbleCount(tester);
    expect(
      mounted40,
      lessThanOrEqualTo(mounted20 + visible40 + 2),
      reason:
          '历史翻倍后常驻数不得跟着翻倍（这正是「有界」的含义）。'
          '实测 mounted20=$mounted20 → mounted40=$mounted40, '
          'visible40=$visible40',
    );
    expect(mounted40, lessThan(40), reason: '40 条历史里必须只留窗口内那几条');
  });

  testWidgets('长气泡滚出视口再滚回：不重新 build（Element 未销毁）', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 一条够长的回复（会被纳入常驻窗口）+ 足够多的填充行把它顶出视口。
    //
    // ⚠️ 填充用 `user_message`（短、无 Markdown）：它们不会挤进常驻窗口
    // （判据是 `AssistantMessageItem` + 长度），故目标气泡稳定留在窗口里。
    await pushReply(tester, id: 'r0', text: longMarkdown('目标回复'), seq: 1);
    for (var i = 0; i < 30; i++) {
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          'user_message',
          id: 'u$i',
          turnId: 'turn_u$i',
          payload: {'input': '填充问题 $i'},
          seq: 100 + i,
        ),
      );
    }
    await tester.pumpAndSettle();

    final position = timelinePosition(tester);
    expect(
      position.maxScrollExtent,
      greaterThan(position.viewportDimension * 2),
      reason: '前置：必须有足够内容把它滚出视口',
    );
    expect(mountedBubbleWithText(tester, '目标回复'), isTrue, reason: '前置：初始时它在树上');

    // 滚到底让它滚出视口。
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      visibleBubbleWithText(tester, '目标回复'),
      isFalse,
      reason: '前置：必须真的滚出视口（否则测不到「滚回来」）',
    );
    expect(
      mountedBubbleWithText(tester, '目标回复'),
      isTrue,
      reason: '前置：滚出视口后仍**在树上**（keep-alive 生效的直接证据）',
    );

    PerfProbe.reset();

    // 滚回顶部：若 Element 已被销毁，这里会重新 build（重新解析 Markdown）。
    position.jumpTo(0);
    await tester.pumpAndSettle();

    expect(mountedBubbleWithText(tester, '目标回复'), isTrue, reason: '前置：滚回来了');
    expect(
      PerfProbe.assistantBubbleBuilds,
      0,
      reason:
          '长气泡被 keep-alive 后 Element 不销毁，滚回来只重新布局、不重建。'
          '若 > 0，说明 keep-alive 没生效（`wantKeepAlive` 为 false，或 '
          '`super.build(context)` 没调）。',
    );
  });

  // ── 流式期间未变气泡不重建 ────────────────────────────────────────
  //
  // 动机：`SliverChildBuilderDelegate.shouldRebuild` **恒为 true**
  // （`scroll_delegate.dart`），故父级每一次 `setState` 都会重建全部已挂载行。
  // 而本页 `setState` 的来源里，流式增量 / `turn_activity` 心跳 / `ttsStatus`
  // / `_staleTurnIds` 都与「历史气泡的内容」无关。
  //
  // 实测（本机 2026-10，debug）：5 条已完成长气泡 + 1 条流式气泡，推**一条**
  // 流式增量 → `assistantBubbleBuilds` 增量 **6**（全部重建）；一条
  // `turn_activity` 心跳同样 **6**。而单个长气泡的**暖**重建实测 16.9–30.3 ms
  // （冷重建 68–441 ms）——6 个就是一次明显掉帧。
  //
  // 修法：`_bubbleCache`（`item.id` → (指纹, widget 实例)）。命中时交回**同一
  // 实例**，`Element.updateChild` 的 `child.widget == newWidget` 分支命中，
  // 子树连 `build` 都不跑。

  testWidgets('流式增量只重建变化的那条气泡，其余不动', (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 5 条已完结的长回复（各自独立 turn）。
    const finished = 5;
    for (var i = 0; i < finished; i++) {
      await pushReply(
        tester,
        id: 'r$i',
        text: longMarkdown('回复 $i'),
        seq: i + 1,
      );
    }
    // 1 条流式段落（尾部，正在接收增量）。
    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: 'start_s',
        turnId: 'turn_s',
        payload: const {},
        seq: 900,
      ),
    );
    await pushStreamingMessage(
      tester,
      id: 'e_stream',
      turnId: 'turn_s',
      text: '正在生成',
      seq: 1,
    );
    await tester.pumpAndSettle();

    // 前置：6 条都在树上（5 条长回复都超过常驻阈值，故全被 keep-alive）。
    expect(
      mountedBubbleCount(tester),
      finished + 1,
      reason: '前置：5 条长回复 + 1 条流式',
    );

    PerfProbe.reset();

    // 推一条流式增量：尾部那条的 `text` 变长，其余 5 条内容不变。
    await pushStreamingMessage(
      tester,
      id: 'e_stream2',
      turnId: 'turn_s',
      text: '，继续写一点',
      seq: 2,
    );
    await tester.pumpAndSettle();

    // 这个数字就是验收标准要的「非尾部气泡的 build 次数」——6 条里只有 1 条
    // 该重建，故修复后为 1；修复前实测为 6。
    debugPrint(
      '[perf] 一条流式增量后 assistantBubbleBuilds = '
      '${PerfProbe.assistantBubbleBuilds}（共 ${finished + 1} 条气泡，'
      '其中 $finished 条内容未变）',
    );

    expect(
      PerfProbe.assistantBubbleBuilds,
      1,
      reason:
          '只有尾部那条的 `text` 变了，其余 5 条指纹相同 → 必须复用 widget '
          '实例。修复前实测 6（全部重建）。',
    );

    // 与气泡内容**无关**的状态更新同理：`turn_activity` 心跳只驱动底部的
    // 活动指示条，不该让任何气泡重建。
    PerfProbe.reset();
    await pushEvent(
      tester,
      EventTypes.turnActivity,
      sseEvent(
        EventTypes.turnActivity,
        id: 'act1',
        turnId: 'turn_s',
        payload: const {'tool': 'bash'},
        transient: true,
        seq: 3,
      ),
    );
    await tester.pumpAndSettle();

    debugPrint(
      '[perf] 一条 turn_activity 心跳后 assistantBubbleBuilds = '
      '${PerfProbe.assistantBubbleBuilds}',
    );

    expect(
      PerfProbe.assistantBubbleBuilds,
      0,
      reason:
          '心跳与气泡内容无关（修复前实测 6）。若为 0，说明缓存指纹没有把'
          '「与气泡无关的状态」误算进去。',
    );
  });

  testWidgets('短气泡不常驻：滚出视口即销毁', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // 短回复（远低于 400 字符阈值）。
    const shortText = '好的，收到';
    expect(shortText.length, lessThan(400), reason: '前置：必须低于阈值');
    await pushReply(tester, id: 'short', text: shortText, seq: 1);

    for (var i = 0; i < 30; i++) {
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          'user_message',
          id: 'u$i',
          turnId: 'turn_u$i',
          payload: {'input': '填充问题 $i'},
          seq: 100 + i,
        ),
      );
    }
    await tester.pumpAndSettle();

    final position = timelinePosition(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // `skipOffstage: false` 会连 keep-alive 的（不在视口内的）子项一起找
    // ——若它仍存在，说明被错误地常驻了。
    expect(
      mountedBubbleWithText(tester, shortText),
      isFalse,
      reason: '短气泡低于 `_keepAliveMinChars`，滚出视口必须被销毁',
    );
  });

  // ── 预建范围（scrollCacheExtent）──────────────────────────────────
  //
  // 默认值只预建 250 **像素**，而本时间线的行高差异极大。快速滚动时新行
  // 来不及预解析，Markdown 的冷解析全压在帧内——表现为「多数帧很轻快、
  // 每隔十几帧突然卡一下」。
  //
  // 实测（本机 2026-10，debug；60 条 4 段 Markdown，60 帧 × 150px）：
  // 默认 250px 有 6/60 帧超 16.7ms，`viewport(1.5)` 降到 0/60。
  //
  // ⚠️ 这条**不能**断言帧耗时（毫秒随机器与 debug/release 漂移）。改为
  // 断言「预建范围确实大于默认值」这个**结构事实**：它一旦被改回固定小像素，
  // 上面那组实测数据就不再成立，而没有任何功能测试会变红。

  testWidgets('时间线的预建范围大于默认 250px（滚动预解析的前置条件）', (tester) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // ⚠️ 必须先 `startController` + `mockTimeline` 再 `pumpPage`：
    // `pumpPage` 只挂载页面，`_items` 要等控制器的快照推送。少了这一步
    // 页面渲染的是 `EmptyState`（没有 `ListView`），`find` 会命中 0 个。
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);
    await pushNoPump(tester, 3);
    await tester.pump();
    expect(controller.snapshot, isNotEmpty, reason: '前置：时间线必须有内容');

    final listView = tester.widget<ListView>(
      find.byType(ListView, skipOffstage: false).first,
    );
    final extent = listView.scrollCacheExtent;
    expect(
      extent,
      isA<ScrollCacheExtent>(),
      reason: '必须显式设置预建范围；留 null 会退回 250px 默认值',
    );
    // `CacheExtentStyle.viewport` 表示按视口倍数缩放（不是固定像素）。
    expect(
      extent!.style,
      CacheExtentStyle.viewport,
      reason: '固定像素在矮屏上预建过多、高屏上过少，应按视口比例',
    );
    expect(
      extent.value,
      greaterThanOrEqualTo(1.0),
      reason: '1.0 屏与默认 250px 在实测中同样是 6/60 超时帧，必须更大',
    );
  });
}
