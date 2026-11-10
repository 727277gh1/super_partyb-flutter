import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

final _timeline = find.byWidgetPredicate(
  (widget) => widget is ScrollView && widget.controller != null,
);

ScrollPosition _position(WidgetTester tester) =>
    tester.widget<ScrollView>(_timeline).controller!.position;

Map<String, dynamic> _message(int seq, {bool long = false}) => sseEvent(
  EventTypes.userMessage,
  id: 'u$seq',
  turnId: 'turn_$seq',
  seq: seq,
  payload: {'input': long ? '历史 $seq\n${'不等高的历史正文。\n' * 30}' : '消息 $seq'},
);

void _mockPage(int start, int end, {int? before}) {
  adapter.onGet(
    '/chat/groups/grp_1/timeline',
    (server) => server.reply(200, {
      'items': [
        for (var seq = start; seq <= end; seq++)
          _message(seq, long: before != null && seq.isEven),
      ],
    }),
    queryParameters: {
      'limit': before == null ? 200 : 50,
      if (before != null) 'before_global_seq': '$before',
    },
  );
}

Future<void> _loadPage(WidgetTester tester) async {
  await tester.runAsync(() async {
    await controller.loadOlder();
    // items 在 handler 完成后由归约计时器发布。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

void main() {
  setUpHarness();
  tearDownHarness();

  testWidgets('连续前插不等高历史，首帧与稳定后都保持可见消息位置', (tester) async {
    mockTimeline();
    _mockPage(101, 135);
    _mockPage(51, 100, before: 101);
    _mockPage(1, 50, before: 51);
    await startController(tester);
    var gate = Completer<bool>();
    var calls = 0;
    await pumpPage(
      tester,
      onLoadOlder: () {
        calls++;
        return gate.future;
      },
    );
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(60);
    await tester.pumpAndSettle();
    expect(calls, 1);

    final anchor = find.text('消息 103');
    expect(tester.getRect(anchor).overlaps(tester.getRect(_timeline)), isTrue);
    final before = tester.getTopLeft(anchor).dy;
    await _loadPage(tester);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    gate.complete(true);
    await tester.pump();
    gate = Completer<bool>();

    // 读到已经加载的历史，再加载下一页；不能只保护初始快照。
    // 新页尚未全部排版，minScrollExtent 仍有估算部分；逐屏向上读到真实顶部。
    for (var step = 0; step < 100; step++) {
      position.pointerScroll(-500);
      await tester.pumpAndSettle();
      if (position.extentBefore < 1) break;
    }
    expect(position.extentBefore, lessThan(1));
    position.pointerScroll(60);
    await tester.pumpAndSettle();
    expect(calls, 2, reason: '加载后的顶部位于负偏移，仍须触发下一页');
    final olderAnchor = find.text('消息 51');
    final olderBefore = tester.getTopLeft(olderAnchor).dy;
    await _loadPage(tester);
    expect(tester.getTopLeft(olderAnchor).dy, closeTo(olderBefore, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(olderAnchor).dy, closeTo(olderBefore, 0.1));
    expect(tester.takeException(), isNull);
    gate.complete(false);
    await tester.pump();
  });

  testWidgets('等待历史期间继续阅读并收到 SSE，按最新阅读位置保持且不追底', (tester) async {
    mockTimeline();
    _mockPage(101, 135);
    _mockPage(51, 100, before: 101);
    await startController(tester);
    final gate = Completer<bool>();
    await pumpPage(tester, onLoadOlder: () => gate.future);
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(60);
    await tester.pumpAndSettle();
    position.pointerScroll(260);
    await tester.pumpAndSettle();
    final anchor = find.text('消息 107');
    final before = tester.getTopLeft(anchor).dy;
    await pushEvent(tester, EventTypes.userMessage, _message(136));
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));

    // 模拟 handler 先完成，items 后发布，不能靠 Future 完成时补偿一次。
    gate.complete(true);
    await tester.pump();
    await _loadPage(tester);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    expect(position.extentAfter, greaterThan(100));

    // 用户主动回到底部之后，自动跟随仍能恢复。
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    await pushEvent(tester, EventTypes.userMessage, _message(137));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
  });

  testWidgets('历史返回时仍在拖动，手势和当前可见消息的位置都保留', (tester) async {
    mockTimeline();
    _mockPage(101, 135);
    _mockPage(51, 100, before: 101);
    await startController(tester);
    final gate = Completer<bool>();
    await pumpPage(tester, onLoadOlder: () => gate.future);
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(100);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(_timeline));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    final anchor = find.text('消息 105');
    final before = tester.getTopLeft(anchor).dy;
    await _loadPage(tester);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(tester.getTopLeft(anchor).dy, closeTo(before - 40, 0.1));
    await gesture.up();
    gate.complete(false);
    await tester.pumpAndSettle();
  });

  testWidgets('分页拼接把开头四个工具折成批量卡，后面的可见正文不跳动', (tester) async {
    mockTimeline();
    List<Map<String, dynamic>> tool(int seq) => [
      sseEvent(
        EventTypes.toolCall,
        id: 'tool$seq',
        seq: seq * 2,
        payload: {
          'tool_call_id': 'call$seq',
          'name': '读取文件',
          'arguments': {'path': 'file$seq.txt'},
        },
      ),
      sseEvent(
        EventTypes.toolResult,
        id: 'result$seq',
        seq: seq * 2 + 1,
        payload: {'tool_call_id': 'call$seq', 'output': '完成'},
      ),
    ];
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': [
          for (var i = 101; i <= 104; i++) ...tool(i),
          for (var i = 210; i <= 240; i++) _message(i),
        ],
      }),
      queryParameters: {'limit': 200},
    );
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': [...tool(99), ...tool(100)],
      }),
      queryParameters: {'limit': 50, 'before_global_seq': '202'},
    );
    await startController(tester);
    final gate = Completer<bool>();
    await pumpPage(tester, onLoadOlder: () => gate.future);
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(60);
    await tester.pumpAndSettle();
    final anchor = find.text('消息 210');
    expect(tester.getRect(anchor).overlaps(tester.getRect(_timeline)), isTrue);
    final before = tester.getTopLeft(anchor).dy;
    await _loadPage(tester);
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
    expect(tester.takeException(), isNull);
    gate.complete(false);
    await tester.pump();
  });

  testWidgets('切对话后旧请求完成，不覆盖新对话的并发与终止状态', (tester) async {
    mockTimeline();
    _mockPage(101, 135);
    await startController(tester);
    final oldGate = Completer<bool>();
    await pumpPage(
      tester,
      historyKey: 'old',
      onLoadOlder: () => oldGate.future,
    );
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(60);
    await tester.pumpAndSettle();
    final newGate = Completer<bool>();
    var calls = 0;
    await rebuildPage(
      tester,
      historyKey: 'new',
      onLoadOlder: () {
        calls++;
        return calls == 1 ? newGate.future : Future.value(false);
      },
    );
    position.jumpTo(80);
    await tester.pump();
    expect(calls, 1, reason: '旧请求在途也不能阻止新对话翻页');
    oldGate.complete(false);
    await tester.pump();
    position.jumpTo(90);
    await tester.pump();
    expect(calls, 1, reason: '旧请求的 finally 不能解除新请求的并发保护');
    newGate.complete(true);
    await tester.pump();
    position.jumpTo(100);
    await tester.pump();
    expect(calls, 2, reason: '旧请求返回 false 不能终止新对话翻页');
  });
}
