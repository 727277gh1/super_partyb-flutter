import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/conversation_page_harness.dart';

void main() {
  setUpHarness();
  tearDownHarness();

  testWidgets('已读过的长短消息往返滚动，列表总高度不随可见行变化', (tester) async {
    mockTimeline();
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': [
          for (var i = 0; i < 48; i++)
            sseEvent(
              'user_message',
              id: 'row-$i',
              turnId: 'turn-$i',
              seq: i + 1,
              payload: {
                'input': i % 8 == 0 ? '长消息 $i\n${'正文内容\n' * 35}' : '短消息 $i',
              },
            ),
        ],
      }),
      queryParameters: {'limit': 200},
    );
    await startController(tester);
    await pumpPage(tester);
    await tester.pumpAndSettle();
    final list = find.byType(CustomScrollView).first;
    final position = tester.widget<CustomScrollView>(list).controller!.position;

    // 逐屏经过全部内容，避免把尚未排版的行高误差与已读内容的估算抖动混在一起。
    position.pointerScroll(-position.maxScrollExtent);
    await tester.pumpAndSettle();
    for (var step = 0; step < 150; step++) {
      position.pointerScroll(300);
      await tester.pumpAndSettle();
      if (position.extentAfter < 1) break;
    }
    expect(position.extentAfter, lessThan(1));
    final total = position.maxScrollExtent - position.minScrollExtent;
    expect(total, greaterThan(5000));

    for (var step = 0; step < 150; step++) {
      position.pointerScroll(-240);
      await tester.pumpAndSettle();
      expect(
        position.maxScrollExtent - position.minScrollExtent,
        closeTo(total, 1),
        reason: '第 $step 次上滚：消息和布局宽度均未变，滚动条比例应保持稳定',
      );
      if (position.extentBefore < 1) break;
    }
    expect(position.extentBefore, lessThan(1));
    for (var step = 0; step < 150; step++) {
      position.pointerScroll(240);
      await tester.pumpAndSettle();
      expect(
        position.maxScrollExtent - position.minScrollExtent,
        closeTo(total, 1),
        reason: '再次下滚也须复用此前测量的行高',
      );
      if (position.extentAfter < 1) break;
    }
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩窄窗口后按新宽度重测，后续往返滚动不沿用旧行高', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    mockTimeline();
    adapter.onGet(
      '/chat/groups/grp_1/timeline',
      (server) => server.reply(200, {
        'items': [
          for (var i = 0; i < 20; i++)
            sseEvent(
              'user_message',
              id: 'wrap-$i',
              turnId: 'turn-$i',
              seq: i + 1,
              payload: {'input': i % 4 == 0 ? '根据窗口宽度换行的正文。' * 100 : '短消息 $i'},
            ),
        ],
      }),
      queryParameters: {'limit': 200},
    );
    await startController(tester);
    await pumpPage(tester);
    await tester.pumpAndSettle();
    final position = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView).first)
        .controller!
        .position;

    Future<double> readAll() async {
      for (var i = 0; i < 200; i++) {
        position.pointerScroll(-300);
        await tester.pumpAndSettle();
        if (position.extentBefore < 1) break;
      }
      expect(position.extentBefore, lessThan(1));
      for (var i = 0; i < 200; i++) {
        position.pointerScroll(300);
        await tester.pumpAndSettle();
        if (position.extentAfter < 1) break;
      }
      expect(position.extentAfter, lessThan(1));
      return position.maxScrollExtent - position.minScrollExtent;
    }

    final wideTotal = await readAll();
    tester.view.physicalSize = const Size(460, 700);
    await tester.pumpAndSettle();
    final narrowTotal = await readAll();
    expect(narrowTotal, greaterThan(wideTotal * 1.2));
    for (var i = 0; i < 200; i++) {
      position.pointerScroll(-250);
      await tester.pumpAndSettle();
      expect(
        position.maxScrollExtent - position.minScrollExtent,
        closeTo(narrowTotal, 1),
      );
      if (position.extentBefore < 1) break;
    }
    expect(position.extentBefore, lessThan(1));
    expect(tester.takeException(), isNull);
  });
}
