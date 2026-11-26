import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 深链锚点（`?turn=<turnId>`）在**页面层**的行为回归。
///
/// ## 这个文件防的是什么
///
/// `turn_anchor_test.dart` 只能证明纯函数算得对；钉不住「页面真的按它落位」：
/// 页面若把锚点参数丢掉、或落位后又立刻被「新事件滚到底」拽回去，纯逻辑测试
/// 仍全绿。而这类缺陷的现场表现是**用户点了链接看到对话末尾**——没有异常、
/// 没有日志。
///
/// 故这里断言的是三件**用户可见**的事：
///
/// 1. 命中历史轮次 → 该轮被高亮，且视口**不在底部**（真的跳上去了）；
/// 2. 锚点态下新事件到达 → 视口**不动**（不被拽回底部），并给出「回到最新」；
/// 3. 越界 / 即最后一轮 → 说话 + 不移动视口，而不是静默停在某处。
///
/// ⚠️ 夹具用**真实形态**的 turnId（32 位 hex，对齐 Go `chatid.NewID`）。
///
/// ⚠️ 本机是无头 LXC：这些用例证明状态机与落位参数正确，**不能**证明真机上
/// 「换分界行」那次跳变的观感（见 `docs/development.md` 的验证边界）。
void main() {
  setUpHarness();
  tearDownHarness();
  setUp(() {
    PerfProbe.reset();
    SpbLog.clearRecentLogs();
  });

  /// 真实形态的 turn id（hex）。`turnA` = 首轮，`turnC` = 从未加载过的轮次。
  const turnA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const turnC = 'cccccccccccccccccccccccccccccccc';

  /// 时间线的滚动位置。
  ///
  /// 必须从 `CustomScrollView` 的 controller 取，不能 `find.byType(Scrollable).first`：
  /// 页面上还有别的可滚动区域（输入框、弹出层）。
  ScrollPosition timelinePosition(WidgetTester tester) => tester
      .widget<CustomScrollView>(find.byType(CustomScrollView).first)
      .controller!
      .position;

  bool atBottom(WidgetTester tester) {
    final position = timelinePosition(tester);
    return position.extentAfter <= 1;
  }

  /// 推一轮完整对话（`start` → `user_message` → `message` → `done`），
  /// 返回用户消息与回复的 eventId。
  ///
  /// ## 为什么必须**按真实顺序**推四个事件
  ///
  /// 归约器把「流式段落」记在 `currentAssistantIdx` 里，只有 `start` 会把它清空
  /// （见 `event_reducer.dart` 的 `EventTypes.start` 分支）。少推 `start`，下一轮的
  /// `message` 就会被当成**同一段的权威帧**原地替换上一轮的回复——夹具于是只剩
  /// 一条回复，而测试仍然“绿”（历史没有被真正堆起来）。这是我在本文件里踩过的
  /// 坑：先用 2 个事件堆 10 轮，结果只有 11 个 item。
  ///
  /// `done` 让该轮进入 `completedTurns`（失败/执行中的视觉状态不同，混进来会让
  /// 快照与断言不稳）。
  Future<List<String>> pushTurn(
    WidgetTester tester, {
    required String turnId,
    required String input,
    required int seq,
    int lines = 12,
  }) async {
    final short = turnId.substring(0, 8);
    final userId = '$short-user-$seq';
    final assistantId = '$short-reply-$seq';
    await pushEvent(
      tester,
      EventTypes.start,
      sseEvent(
        EventTypes.start,
        id: '$short-start-$seq',
        turnId: turnId,
        seq: seq,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.userMessage,
      sseEvent(
        EventTypes.userMessage,
        id: userId,
        turnId: turnId,
        payload: {'input': input},
        seq: seq + 1,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.message,
      sseEvent(
        EventTypes.message,
        id: assistantId,
        turnId: turnId,
        payload: {
          'text': List.generate(
            lines,
            (i) => '$input 的第 $i 段回复正文。',
          ).join('\n\n'),
        },
        seq: seq + 2,
      ),
    );
    await pushEvent(
      tester,
      EventTypes.done,
      sseEvent(
        EventTypes.done,
        id: '$short-done-$seq',
        turnId: turnId,
        seq: seq + 3,
      ),
    );
    return [userId, assistantId];
  }

  testWidgets('锚点命中历史轮次：落到该轮并高亮，新事件不再把视口拽回底部', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);

    // 先堆出「远超一屏」的历史，让第一轮落在视口外（未构建的行）。
    final ids = <List<String>>[];
    for (var i = 0; i < 10; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    TurnAnchorOutcome? outcome;
    await pumpPage(
      tester,
      anchorTurnId: turnA,
      onAnchorResolved: (o) => outcome = o,
    );
    await tester.pumpAndSettle();

    expect(outcome, TurnAnchorOutcome.jumped);
    // 该轮的两行（用户消息 + 回复）都被高亮：高亮按**行**渲染，键按行主键唯一。
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[1]}')),
      findsOneWidget,
    );
    // 真的跳上去了，而且是**贴顶**落到该轮（不是「安静地停在对话末尾」）。
    // 断言落点的绝对 dy，而不是「不在底部」：后者在「页面本来就停在顶部」时
    // 也成立，等于什么都没证明。
    final anchoredDy = tester.getTopLeft(find.text('第 0 轮')).dy;
    expect(anchoredDy, lessThan(120));
    // 下方仍有大量内容（这就是「从这一轮往下读」的语境）。
    expect(timelinePosition(tester).extentAfter, greaterThan(500));
    // 锚点态才有「回到最新」。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    // 新事件到达：跟随已关，视口不能被拽回底部（这正是 webapp 的
    // `followOutput` 在锚点态要关掉的那件事）。
    await pushTurn(tester, turnId: _hex(99), input: '锚点之后的新一轮', seq: 900);
    await tester.pumpAndSettle();
    // 视口**逐像素没动**：这才是「不被拽回底部」的强断言。
    // （只断言「不在底部」会让「本来就没跟随」的缺陷漏过去。）
    expect(tester.getTopLeft(find.text('第 0 轮')).dy, closeTo(anchoredDy, 1));
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );

    // 「回到最新」：清锚点 + 回底部。
    await tester.tap(find.byKey(const ValueKey('conversation-back-to-latest')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);
  });

  testWidgets('用户自己滚回底部 → 退出锚点态（高亮与「回到最新」都消失）', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    final ids = <List<String>>[];
    for (var i = 0; i < 8; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    await pumpPage(tester, anchorTurnId: turnA);
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsOneWidget,
    );

    // 手动滚到底（等价于用户自己往下翻到最新）。
    timelinePosition(tester).jumpTo(timelinePosition(tester).maxScrollExtent);
    await tester.pumpAndSettle();

    // 锚点态按「用户在不在那一轮」判定，而不是按「曾经跳没跳过」：滚到底就是
    // 离开了那一轮，高亮与入口都该消失（否则会一直挂着一个无用按钮）。
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 且**不会**被下一批 items 拽回那一轮（已滚到底 = 恢复跟随）。
    await pushTurn(tester, turnId: _hex(99), input: '滚回底部后的新消息', seq: 900);
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(ValueKey('turn-highlight-${ids.first[0]}')),
      findsNothing,
    );
  });

  testWidgets('锚点越界：不移动视口，只提示一次', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    // 堆到**必须滚动**的高度：否则 `atBottom` 在「内容不满一屏」时恒真，
    // 「越界不移动视口」就成了一条永远成立的断言。
    for (var i = 0; i < 6; i++) {
      await pushTurn(
        tester,
        turnId: i == 0 ? turnA : _hex(i),
        input: '第 $i 轮',
        seq: i * 4 + 1,
      );
    }

    final outcomes = <TurnAnchorOutcome>[];
    await pumpPage(
      tester,
      anchorTurnId: turnC, // 从未加载过的轮次
      onAnchorResolved: outcomes.add,
    );
    await tester.pumpAndSettle();

    expect(outcomes, [TurnAnchorOutcome.missing]);
    expect(find.textContaining('不在已加载的消息范围'), findsOneWidget);
    // 不移动视口：越界时停在底部（首屏的正常落点），而不是停在顶部/半空。
    expect(atBottom(tester), isTrue);
    // 失败态同样升格为常驻提示卡（issue #87 回归）：没有补页通道（未注入
    // onLoadOlder），但用户仍需一个出口。
    expect(
      find.byKey(const ValueKey('conversation-anchor-notice')),
      findsOneWidget,
    );
    // 越界不进锚点态 → 不该出现「回到最新」。
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 后续事件不重复提示（按锚点值去重），也不补跳（v1 作用域只有已加载）。
    await pushTurn(tester, turnId: _hex(77), input: '新的一轮', seq: 700);
    await tester.pumpAndSettle();
    expect(find.textContaining('不在已加载的消息范围'), findsOneWidget);
    expect(atBottom(tester), isTrue);
  });

  testWidgets('锚点即最后一轮：按「跟随最新」处理（不高亮、不钉住滚动）', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    // 同上：内容必须超过一屏，「仍在跟随」才是有意义的断言。
    final ids = <List<String>>[];
    for (var i = 0; i < 6; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }
    final first = ids.first;
    final last = ids.last;
    // 锚点指向**最后一轮**（用它的 turnId，与「第 N 轮」序号无关）。
    final lastTurnId = _hex(5);

    TurnAnchorOutcome? outcome;
    await pumpPage(
      tester,
      anchorTurnId: lastTurnId,
      onAnchorResolved: (o) => outcome = o,
    );
    await tester.pumpAndSettle();

    expect(outcome, TurnAnchorOutcome.followingLatest);
    expect(find.byKey(ValueKey('turn-highlight-${last[0]}')), findsNothing);
    expect(find.byKey(ValueKey('turn-highlight-${first[0]}')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);

    // 内容真的超过一屏（上面的 `atBottom` 不是「无滚动」时恒真）。
    expect(timelinePosition(tester).maxScrollExtent, greaterThan(100));

    // 仍跟随：新一轮到达后依旧在底部（锚点没有把它钉在旧位置）。
    await pushTurn(tester, turnId: turnC, input: '新的最后一轮', seq: 900);
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
  });

  testWidgets('换锚点值 / 切对话：锚点态重置', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    final ids = <List<String>>[];
    for (var i = 0; i < 8; i++) {
      ids.add(
        await pushTurn(
          tester,
          turnId: i == 0 ? turnA : _hex(i),
          input: '第 $i 轮',
          seq: i * 4 + 1,
        ),
      );
    }

    // 无锚点进入：正常跟到底部（这是「已经在对话里」的基线，也是下面
    // 「从底部被送到历史某一轮」这条最常用路径的起点）。
    await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(timelinePosition(tester).maxScrollExtent, greaterThan(100));
    expect(atBottom(tester), isTrue);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );

    // 同一个 State 被复用（只换锚点值）：必须从底部**跳上去**，而不是停在原处
    // 或安静地什么也不做。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_1',
      anchorTurnId: _hex(1),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[1][0]}')), findsOneWidget);
    expect(timelinePosition(tester).extentAfter, greaterThan(500));
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );

    // 再换锚点值（这一次目标行在底部视口外 → 走「搬分界行」的落位原语）：
    // 必须重新定位，而不是停在旧锚点。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_1',
      anchorTurnId: _hex(5),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[1][0]}')), findsNothing);
    expect(find.byKey(ValueKey('turn-highlight-${ids[5][0]}')), findsOneWidget);

    // 换对话（historyKey 变 + 不带锚点，即从列表点进另一个对话）→ 锚点态与
    // 高亮全部清掉，且重新回到「跟随最新」。
    //
    // ⚠️ 若换对话时**仍**带着同一个锚点值（URL 里就写着 `?turn=`），页面会拿它
    // 在新对话里重新解析——这是对的：锚点是 URL 的一部分，它描述的是「这个对话
    // 的某一轮」而不是「上一次定位的结论」。故这里故意不传锚点。
    await rebuildPage(
      tester,
      onLoadOlder: () async => false,
      historyKey: 'grp_2',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('turn-highlight-${ids[5][0]}')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsNothing,
    );
    expect(atBottom(tester), isTrue);
  });

  // ==================== 越界自动补页（issue #108）====================

  /// 挂一页「更早的历史」（`GET timeline` 的响应形态）。
  ///
  /// 夹具刻意用**最扁的形状**：每个 `seq` 两条事件（`user_message` + `done`），
  /// 本组用例验证的是「补页与落位的协作」，不是归约器对一轮内多种事件的归并
  /// （那在 `conversation_page_timeline_test.dart`）。
  ///
  /// ⚠️ `done` **不能省**：只有 `start`/`done` 会让轮次进入「执行中 / 已结束」，
  /// 而缺 `done` 的轮次会被控制器的超时兠底（`_syncStaleWatch`）挂上一个 5 分钟
  /// 定时器——用例结束时变成「A Timer is still pending」这种与断言无关的失败。
  ///
  /// 每页 50 个 seq = 100 条事件 ≥ `controller.loadOlder` 的 `limit(50)`，于是
  /// `hasMore` 为 true——补页会继续。
  ///
  /// [cursorLog] 非 null 时把**被请求的游标**按到达顺序记进去（`null` = 首屏）：
  /// 补页次数与顺序是本组用例的核心断言，而它只能从「服务端收到哪个 cursor」
  /// 看出来（从页面侧数回调次数会被落位后那次滚动翻页混进来）。
  void mockPage(int start, int end, {int? before, List<int?>? cursorLog}) {
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) {
        cursorLog?.add(before);
        return server.reply(200, {
          'items': [
            for (var seq = start; seq <= end; seq++) ...[
              sseEvent(
                EventTypes.userMessage,
                id: 'e$seq',
                turnId: _hex(seq),
                seq: seq * 2,
                payload: {'input': '第 $seq 条'},
              ),
              sseEvent(
                EventTypes.done,
                id: 'e${seq}d',
                turnId: _hex(seq),
                seq: seq * 2 + 1,
              ),
            ],
          ],
        });
      },
      queryParameters: {
        'limit': before == null ? 200 : 50,
        if (before != null) 'before_global_seq': '$before',
      },
    );
  }

  /// 推进「补页 → items → 落位」的链。
  ///
  /// 每一轮要两件事同时发生，故不能只 `pumpAndSettle`：
  ///
  /// - **真实时区**里等 dio mock 的响应（补页走 `controller.loadOlder`，那是
  ///   真 HTTP 栈；FakeAsync 时区里永远不会完成——见 harness 的 pushEvent 注释）；
  /// - **FakeAsync 时区**里 `pump`：归约器的零延迟 Timer、post-frame 重试、
  ///   `endOfFrame` 都不是真实计时器。
  ///
  /// 多轮是必要的：目标轮在第 3 页时，链条是「请求页 2 → items → 重判 → 请求
  /// 页 3 → items → 搬分界行 → 精调」，每环各占一帧。
  Future<void> driveBackfill(WidgetTester tester, {int rounds = 14}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // 收尾：把还挂着的零延迟/短定时器泵干净。不泵会把「还有 pending Timer」
    // 留给测试框架，在末尾报成与本用例无关的失败（实测踩过）。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  testWidgets('锚点越界自动补页：目标轮在第 3 页也能落到该轮并高亮', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 服务端收到的游标（null = 首屏），按到达顺序。
    final cursors = <int?>[];
    mockTimeline();
    mockPage(101, 135, cursorLog: cursors); // 首屏：只拿到最近的 35 轮
    mockPage(51, 100, before: 202, cursorLog: cursors); // 补页 1
    mockPage(1, 50, before: 102, cursorLog: cursors); // 补页 2：目标轮在这里
    // 视口落到历史顶部后，既有的「在顶部就翻页」会再要一页；不挂上 mock 会让
    // dio 报 NetworkError，把用例的失败原因搞模糊。
    mockPage(1, 0, before: 2, cursorLog: cursors);
    await startController(tester);

    final outcomes = <TurnAnchorOutcome>[];
    await pumpPage(
      tester,
      anchorTurnId: _hex(5),
      onLoadOlder: () => controller.loadOlder(),
      onAnchorResolved: outcomes.add,
    );
    await driveBackfill(tester);

    expect(outcomes, [TurnAnchorOutcome.jumped]);
    // 补页顺序：首屏 → 101 → 51（目标轮所在页）。若补页没停或顺序反了，这里
    // 会先出现别的游标——这是「命中即止」在**服务端侧**的证据。
    expect(cursors.take(3), [
      null,
      202,
      102,
    ], reason: '目标轮在第 3 页：只应补两页，且游标逐页向前推');
    // 高亮落到该轮（按行渲染，行键 = 该条事件的 id）。
    expect(find.byKey(const ValueKey('turn-highlight-e5')), findsOneWidget);
    // 真的落上去了：贴顶（alignment: 0），且下方仍有大量内容。
    expect(tester.getTopLeft(find.text('第 5 条')).dy, lessThan(120));
    expect(timelinePosition(tester).extentAfter, greaterThan(300));
    expect(
      find.byKey(const ValueKey('conversation-back-to-latest')),
      findsOneWidget,
    );
  });

  testWidgets('自动补页有上界：页数用尽仍未命中 → 提示一次「已向上加载」', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    mockPage(101, 135);
    mockPage(51, 100, before: 202);
    mockPage(1, 50, before: 102);
    await startController(tester);

    var requests = 0;
    final outcomes = <TurnAnchorOutcome>[];
    await pumpPage(
      tester,
      // 任何一页都没有这个 turnId。
      anchorTurnId: _hex(4242),
      // 上限压到 2 页：不靠堆几十页真数据来验证「有界」。
      anchorBackfillPages: 2,
      onLoadOlder: () {
        requests++;
        return controller.loadOlder();
      },
      onAnchorResolved: outcomes.add,
    );
    await driveBackfill(tester);

    expect(requests, 2, reason: '上限 2 页：第 3 次不应再发请求');
    expect(outcomes, [TurnAnchorOutcome.missing]);
    // 文案要与「根本没法补页」区分：用户知道我们真的往上找过了。
    expect(find.textContaining('已向上加载更早的历史'), findsOneWidget);
    expect(atBottom(tester), isTrue);
    // 失败态有常驻提示卡（issue #87 回归）：SnackBar 会消失，但用户需要
    // 一个出口把锚点交出去——否则页面永远钉在底部、不跟随新消息。
    expect(
      find.byKey(const ValueKey('conversation-anchor-notice')),
      findsOneWidget,
    );
    // 点它 = 放弃锚点：常驻卡消失、恢复跟随（新一轮到达能拽回底部）。
    await tester.tap(find.byKey(const ValueKey('conversation-anchor-notice')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('conversation-anchor-notice')),
      findsNothing,
    );
    await pushTurn(tester, turnId: _hex(78), input: '放弃锚点后的新一轮', seq: 901);
    await tester.pumpAndSettle();
    expect(atBottom(tester), isTrue, reason: '放弃锚点后恢复跟随');

    // 再推一轮新消息：不重复提示（按锚点值去重）、也不乱拉历史。
    await pushTurn(tester, turnId: _hex(77), input: '补页之后的新一轮', seq: 900);
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.textContaining('已向上加载更早的历史'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('conversation-anchor-notice')),
      findsNothing,
      reason: '已放弃锚点：提示不再回来（除非换了新的锚点值）',
    );
    expect(atBottom(tester), isTrue);
  });

  testWidgets('补页期间用户自己滚走 → 不再替他补页、不抢视口', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    mockTimeline();
    mockPage(101, 135);
    mockPage(51, 100, before: 202);
    await startController(tester);

    var requests = 0;
    await pumpPage(
      tester,
      anchorTurnId: _hex(4242),
      onLoadOlder: () async {
        requests++;
        // 用户在这期间自己上翻（停在半空），不再处于「跟随最新」。
        //
        // 只能 `jumpTo`，不能在这里 `tester.pump()`：这个回调是在 post-frame
        // 里被调的，帧阶段不是 idle，再泵一帧会直接断言失败。
        final position = timelinePosition(tester);
        position.jumpTo(position.maxScrollExtent * 0.5);
        return true; // 服务端还有更早的历史，但我们已不该继续拉
      },
    );
    await driveBackfill(tester);

    expect(requests, 1, reason: '用户接管视口后必须停手：继续补页会在他读的位置上方不停插内容');
    // 视口停在用户放的地方，没有被锚点或补页抢回底部。
    expect(atBottom(tester), isFalse);
    expect(timelinePosition(tester).extentAfter, greaterThan(100));
  });
}

/// 生成一个真实形态的 turnId（32 位 hex），避免用例之间撞 id。
String _hex(int n) => n.toRadixString(16).padLeft(32, '0');
