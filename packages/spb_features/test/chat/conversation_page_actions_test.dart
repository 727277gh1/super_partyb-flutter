import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_design/spb_design.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// ConversationPage 失败 turn 重发 / 对话内搜索（issue #31）
///
/// ⚠️ 本文件由 `conversation_page_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `test/support/conversation_page_harness.dart`。
void main() {
  setUpHarness();
  tearDownHarness();

  group('ConversationPage 失败 turn 重发', () {
    /// 推一条 user_message + 一条 error（同一 turn）。
    Future<void> pushFailedTurn(
      WidgetTester tester, {
      required String turnId,
      String input = '帮我看看这个报错',
      Map<String, dynamic> extra = const {},
    }) async {
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: 'e_user',
          turnId: turnId,
          payload: {'input': input, ...extra},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.error,
        sseEvent(
          EventTypes.error,
          id: 'e_err',
          turnId: turnId,
          seq: 2,
          payload: {'message': '执行器崩溃'},
        ),
      );
    }

    testWidgets('错误条带「重发」按钮，点击回调带上原输入与 agent', (tester) async {
      mockTimeline();
      await startController(tester);
      final calls = <({String text, String? agentId})>[];
      await pumpPage(
        tester,
        onRetryTurn: (text, agentId) async {
          calls.add((text: text, agentId: agentId));
        },
      );

      await pushFailedTurn(
        tester,
        turnId: 'turn_err',
        extra: {'agent_id': 'agt_x'},
      );

      expect(find.text('重发'), findsOneWidget);
      await tester.tap(find.text('重发'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.text, '帮我看看这个报错');
      // agent_id 来自本地回显的 payload，重发时原样带上。
      expect(calls.single.agentId, 'agt_x');
    });

    testWidgets('未注入 onRetryTurn → 不渲染重发按钮', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      await pushFailedTurn(tester, turnId: 'turn_err');

      expect(find.text('重发'), findsNothing);
    });

    testWidgets('找不到同 turn 的原输入时不发请求（不拿别的文本乱发）', (tester) async {
      mockTimeline();
      await startController(tester);
      final calls = <String>[];
      await pumpPage(tester, onRetryTurn: (text, _) async => calls.add(text));

      // 只有 error，没有对应的 user_message。
      await pushEvent(
        tester,
        EventTypes.error,
        sseEvent(
          EventTypes.error,
          id: 'e_orphan',
          turnId: 'turn_orphan',
          payload: {'message': 'boom'},
        ),
      );

      // 按钮仍在（有 turnId + 已注入），但点击后不发请求。
      await tester.tap(find.text('重发'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
    });

    testWidgets('重发失败 → 提示「重发失败」，不崩', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        onRetryTurn: (_, _) async => throw const HttpError(500, '服务端挂了'),
      );

      await pushFailedTurn(tester, turnId: 'turn_err');

      await tester.tap(find.text('重发'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('重发失败'), findsOneWidget);
    });

    testWidgets('turnId 为空的 error 不渲染按钮（无法定位原输入）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, onRetryTurn: (_, _) async {});

      await pushEvent(
        tester,
        EventTypes.error,
        sseEvent(
          EventTypes.error,
          id: 'e_no_turn',
          turnId: '',
          payload: {'message': 'boom'},
        ),
      );

      expect(find.text('重发'), findsNothing);
    });
  });

  group('ConversationPage 对话内搜索', () {
    /// 推一条 user_message + 一条 message（同一 turn）。
    /// ## 为什么必须带 `start` 事件
    ///
    /// 归约器用 `currentAssistantIdx` 跟踪「当前流式段落」。`message` 事件
    /// （无论增量帧还是权威帧）都会**替换或追加到那一段**，而不是新建一项。
    /// 只有 `start` 事件会把它置空（「新 turn 开始」）。
    ///
    /// 若省略 `start`，第二个 turn 的权威帧会**覆盖第一个 turn 的回复**
    /// （`items[1]` 仍是 asst1，`copyWith(text:)` 直接把它的文本换掉）——
    /// 表现为「第一条回复凭空消失」。真实 SSE 每个 turn 都会发 `start`，
    /// 故测试也必须发。
    ///
    /// ## 为什么 seq 必须显式递增
    ///
    /// 归约器按 `globalSeq` 排序；两个 turn 都用默认 `seq: 1` 会让
    /// turn_2 的用户消息排到 turn_1 的回复**之前**，于是「第一条回复」的
    /// 归属被搅乱，断言会指向错误的气泡。
    Future<void> pushTurn(
      WidgetTester tester, {
      required String turnId,
      required String input,
      required String reply,
      required int baseSeq,
      String userEventId = 'e_user',
      String msgEventId = 'e_msg',
    }) async {
      await pushEvent(
        tester,
        EventTypes.start,
        sseEvent(
          EventTypes.start,
          id: 'e_start_$turnId',
          turnId: turnId,
          seq: baseSeq,
          payload: {'status': 'running'},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.userMessage,
        sseEvent(
          EventTypes.userMessage,
          id: userEventId,
          turnId: turnId,
          seq: baseSeq + 1,
          payload: {'input': input},
        ),
      );
      await pushEvent(
        tester,
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: msgEventId,
          turnId: turnId,
          seq: baseSeq + 2,
          payload: {'text': reply, 'is_final': true},
        ),
      );
    }

    testWidgets('未开启 enableSearch → 不渲染搜索入口', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);

      expect(
        find.byKey(const ValueKey('conversation-search-open')),
        findsNothing,
        reason: '默认关闭：移动端 AppBar 无余量（issue #31），未接线的调用方不该被撑破',
      );
    });

    testWidgets('开启 enableSearch → AppBar 出现搜索入口，点击打开面板', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      final open = find.byKey(const ValueKey('conversation-search-open'));
      expect(open, findsOneWidget);

      await tester.tap(open);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
      );
    });

    testWidgets('能搜到 agent 的回复（服务端搜索做不到这一点）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await pushTurn(
        tester,
        turnId: 'turn_1',
        input: '帮我看看这个报错',
        reply: '这个报错来自空指针解引用',
        baseSeq: 1,
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '空指针',
      );
      await tester.pumpAndSettle();

      // 关键：命中的是 agent 回复，而不是用户输入。
      expect(
        find.byKey(const ValueKey('conversation-search-hit-e_msg')),
        findsOneWidget,
        reason:
            '服务端 SearchChatTurnsByText 只查 input_text，搜不到回复——'
            '这正是本地过滤存在的理由',
      );
      expect(find.text('1 条结果'), findsOneWidget);
    });

    testWidgets('无命中 → 空状态且带上查询词', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await pushTurn(
        tester,
        turnId: 'turn_1',
        input: '你好',
        reply: '你好，有什么可以帮你',
        baseSeq: 1,
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '不存在的词',
      );
      await tester.pumpAndSettle();

      expect(find.text('没有找到「不存在的词」'), findsOneWidget);
    });

    testWidgets('点击命中项 → 关闭面板并滚动到该条', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await pushTurn(
        tester,
        turnId: 'turn_1',
        input: '第一条消息',
        reply: '第一条回复',
        baseSeq: 1,
      );
      await pushTurn(
        tester,
        turnId: 'turn_2',
        input: '第二条消息',
        reply: '第二条回复',
        baseSeq: 10,
        userEventId: 'e_user2',
        msgEventId: 'e_msg2',
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '第一条回复',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('conversation-search-hit-e_msg')),
      );
      await tester.pumpAndSettle();

      // 面板必须关掉：否则 ensureVisible 会把目标滚到被弹层遮住的位置。
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsNothing,
      );
      expect(find.text('第一条回复'), findsOneWidget);
    });

    testWidgets('上方仍有未加载历史 → 面板顶部给出范围提示', (tester) async {
      // 让 loadOlder 返回 true（= 还有更早历史）并触发一次，使 _reachedOldest 保持 false。
      // 这里直接不触发翻页：`_reachedOldest` 初值就是 false，即「上方可能还有」。
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true, onLoadOlder: () async => true);

      await pushTurn(
        tester,
        turnId: 'turn_1',
        input: '你好',
        reply: '你好呀',
        baseSeq: 1,
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '你好',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-scope-notice')),
        findsOneWidget,
        reason: '不提示的话，用户会把「没搜到」误读成「这句话不存在」',
      );
      expect(find.textContaining('更早的历史尚未加载'), findsOneWidget);
    });

    testWidgets('已翻到最早 → 不显示范围提示', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        enableSearch: true,
        // 返回 false = 已到最早，于是 `_reachedOldest` 变 true。
        onLoadOlder: () async => false,
      );

      // 必须先有**可滚动**的内容：内容不足一屏时 `_onScroll` 根本不会触发
      // （`maxScrollExtent == 0`，没有滚动通知），`onLoadOlder` 永远不会被调。
      for (var i = 0; i < 40; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_fill_$i',
            turnId: 'turn_fill_$i',
            seq: i + 1,
            payload: {'input': '填充第 \$i 条内容'},
          ),
        );
      }

      // 滚到顶触发一次翻页 → onLoadOlder 返回 false → `_reachedOldest = true`。
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, 4000),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '你好',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-scope-notice')),
        findsNothing,
      );
    });

    testWidgets('命中过多 → 摘要说明「仅显示前 N 条」', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      // 超过 kConversationSearchMaxHits（100）条命中。
      //
      // ⚠️ 必须用**不同 turn**：同一 turn 内的多条 `message` 是流式增量，
      // 归约器会把它们**合并成一个** `AssistantMessageItem`（这正是「同一 turn
      // 全部 message 事件拼接即完整回复」的语义）。用同一 turn 推 105 条只会
      // 得到 1 个命中项。
      for (var i = 0; i < 105; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_bulk_$i',
            turnId: 'turn_bulk_$i',
            seq: 100 + i,
            payload: {'input': '重复命中词'},
          ),
        );
      }

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '重复命中词',
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('共 105 条'), findsOneWidget);
      expect(find.textContaining('仅显示前 100 条'), findsOneWidget);
    });

    testWidgets('搜索期间到达的新消息也能被搜到（每次查询现读）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();

      // 面板已打开，此时新消息到达。
      await pushTurn(
        tester,
        turnId: 'turn_late',
        input: '迟到的提问',
        reply: '迟到的回答里有关键词',
        baseSeq: 1,
      );

      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '关键词',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-hit-e_msg')),
        findsOneWidget,
        reason: 'readItems 每次查询时现读 _items，故弹层打开期间的新消息也在范围内',
      );
    });

    testWidgets('关闭按钮关掉面板', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsNothing,
      );
    });
  });

  group('ConversationPage 对话内搜索的载体（#132）', () {
    testWidgets('桌面主题用 Dialog，移动端用底部弹层', (tester) async {
      mockTimeline();
      await startController(tester);

      // 移动端（默认）：保持 `showModalBottomSheet` 的键盘与安全区行为。
      await pumpPage(tester, enableSearch: true);
      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      expect(
        find.byType(BottomSheet),
        findsOneWidget,
        reason: '移动端的搜索面板就是底部弹层（AGENTS.md §6.10）',
      );
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
      await tester.pumpAndSettle();

      // 桌面：鼠标操作不该从屏幕底部升起 sheet。
      await pumpPage(
        tester,
        enableSearch: true,
        theme: SpbTheme.lightFor(TargetPlatform.linux),
      );
      // ⚠️ `MaterialApp` 把主题包在 `AnimatedTheme` 里：不等它跑完，
      // `Theme.of(context).platform` 仍是上一帧（默认 android）的值，页面会
      // 误走移动端分支。
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      expect(
        find.byType(Dialog),
        findsOneWidget,
        reason: '桌面端用居中对话框（与 agent_switcher 的选人弹层同取向）',
      );
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('conversation-search-close')),
        findsOneWidget,
        reason: '对话框遮罩之外没有「下滑关闭」这种手势，必须有明确关闭入口',
      );
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
      );
      // 初始焦点：打开就能打字（键盘用户不必先按 Tab 摸黑找输入框）。
      expect(
        tester
            .state<EditableTextState>(
              find.descendant(
                of: find.byKey(const ValueKey('conversation-search-field')),
                matching: find.byType(EditableText),
              ),
            )
            .widget
            .focusNode
            .hasFocus,
        isTrue,
        reason: '搜索框 `autofocus: true`，两种载体都成立',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      // 焦点返回：`ModalRoute` 在退场后把焦点还给下层路由。断言「焦点没悬空」
      // ——若它停在一个已经 `dispose` 的节点上，后续 Tab 会无处可去。
      //
      // 不断言「焦点回到搜索按钮」：测试里是鼠标点击打开的，点击本身不给按钮
      // 焦点（桌面端 `InkWell` 只在键盘激活时 requestFocus），故还原目标本来
      // 就是下层路由的焦点域。
      final primary = FocusManager.instance.primaryFocus;
      expect(primary, isNotNull, reason: '关闭后焦点不能凭空消失');
      expect(
        primary!.context?.mounted ?? true,
        isTrue,
        reason: '焦点不能留在已销毁的路由节点上',
      );
    });

    testWidgets('桌面对话框：Esc 可关闭（键盘用户的退路）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        enableSearch: true,
        theme: SpbTheme.lightFor(TargetPlatform.linux),
      );
      // ⚠️ `MaterialApp` 把主题包在 `AnimatedTheme` 里：不等它跑完，
      // `Theme.of(context).platform` 仍是上一帧（默认 android）的值，页面会
      // 误走移动端分支。
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byType(Dialog),
        findsNothing,
        reason: '`ModalRoute` 默认把 DismissIntent 映射到 maybePop，Esc 应当能关',
      );
    });

    testWidgets('取消搜索 → 不定位（不因「上一次命中」残留而乱滚）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      for (var i = 0; i < 12; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_fill_$i',
            turnId: 'turn_fill_$i',
            seq: i + 1,
            payload: {'input': '填充第 $i 条内容'},
          ),
        );
      }
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final startPixels = position.pixels;
      expect(position.maxScrollExtent, greaterThan(0), reason: '场景前提：可滚动');

      // 搜出命中项但**不点**，直接关掉面板。
      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '填充第 3 条内容',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-search-hit-e_fill_3')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('conversation-search-close')));
      await tester.pumpAndSettle();

      expect(
        position.pixels,
        startPixels,
        reason: '没选中任何命中项时不该滚动。异步返回后必须检查结果为空（并检查 mounted）',
      );
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsNothing,
      );
    });

    testWidgets('命中后等弹层退场完成才定位（不是 pop 完就滚）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, enableSearch: true);

      // 场景前提：命中项在内容**中间**，而初始视图（自动追底）停在末尾。
      // 于是「居中定位」必须真的往上滚一段——滚动距离为 0 的场景下，
      // 「定位在退场之后才开始」这条断言是空转的。
      //
      // 也不能让命中项太多：目标行一旦滚出构建范围，`_scrollToItem` 会走
      // 「请向上滚动后重试」的分支，同样不产生滚动。
      for (var i = 0; i < 12; i++) {
        await pushEvent(
          tester,
          EventTypes.userMessage,
          sseEvent(
            EventTypes.userMessage,
            id: 'e_fill_$i',
            turnId: 'turn_fill_$i',
            seq: i + 1,
            payload: {'input': '填充第 $i 条内容'},
          ),
        );
      }

      await tester.tap(find.byKey(const ValueKey('conversation-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        '填充第 3 条内容',
      );
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      final startPixels = position.pixels;
      final field = find.byKey(const ValueKey('conversation-search-field'));

      await tester.tap(
        find.byKey(const ValueKey('conversation-search-hit-e_fill_3')),
      );

      // 逐帧推进，记录「面板仍在树上时滚动是否已经开始」。
      //
      // 这正是旧实现与新实现的分界：`Navigator.push` 的 Future 在 pop 的瞬间
      // 就完成（`Route.popped`），若不等 `route.completed`，定位会在退场动画
      // 期间就跑起来，目标被仍在退场的弹层压住。
      var movedWhileSheetVisible = false;
      var lastPixels = position.pixels;
      for (var i = 0; i < 120; i++) {
        final sheetVisible = field.evaluate().isNotEmpty;
        await tester.pump(const Duration(milliseconds: 16));
        if (sheetVisible && (position.pixels - lastPixels).abs() > 0.5) {
          movedWhileSheetVisible = true;
        }
        lastPixels = position.pixels;
        if (!sheetVisible && !tester.binding.hasScheduledFrame) break;
      }
      await tester.pumpAndSettle();

      expect(
        movedWhileSheetVisible,
        isFalse,
        reason: '定位必须等弹层完全退场（`route.completed`）之后才开始',
      );
      expect(
        position.pixels,
        isNot(startPixels),
        reason: '对照断言：本场景确实需要滚动，否则上面那条断言是空转',
      );
      expect(field, findsNothing);
      expect(find.text('填充第 3 条内容'), findsOneWidget);
    });
  });
}
