import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import '../support/conversation_page_harness.dart';

void main() {
  setUpHarness();
  tearDownHarness();

  testWidgets('长正文从底部向上滚到中段：不复用整行绘制层，正文仍可见', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    mockTimeline();
    await startController(tester);
    final text = [
      for (var i = 0; i < 180; i++) ...[
        '## 第 $i 段 paragraph-$i',
        '这是长回复的正文，包含 **强调** 和 `inline code`。'
                ' This reply occupies many screens. ' *
            3,
        if (i % 20 == 0) '```text\nexample output\nsecond line\n```',
      ],
    ].join('\n\n');
    await pushEvent(
      tester,
      'message',
      sseEvent(
        'message',
        id: 'long',
        turnId: 'long-turn',
        payload: {'text': text},
      ),
    );
    await pushEvent(
      tester,
      'done',
      sseEvent('done', id: 'done', turnId: 'long-turn', seq: 2),
    );
    for (var i = 0; i < 20; i++) {
      await pushEvent(
        tester,
        'user_message',
        sseEvent(
          'user_message',
          id: 'u$i',
          turnId: 't$i',
          seq: i + 3,
          payload: {'text': 'filler $i'},
        ),
      );
    }
    await pumpPage(tester);
    await tester.pumpAndSettle();
    final list = find.byType(ListView).first;
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(0);
    await tester.pumpAndSettle();
    final bubble = find.byType(AssistantMessageBubble);
    final height = tester.getSize(bubble).height;
    expect(height, greaterThan(position.viewportDimension * 10));

    // 数据、挂载和高度都正常时，整行缓存依然可能在设备 GPU 上空白。
    // 因此必须断言绘制边界，不能只检查 snapshot / find.byType。
    RenderObject? ancestor = tester.renderObject(bubble).parent;
    while (ancestor != null && !ancestor.isRepaintBoundary) {
      ancestor = ancestor.parent;
    }
    expect(
      ancestor,
      isA<RenderViewport>(),
      reason: '正文直接由视口绘制，不能再被整条超高行的 RepaintBoundary 截住',
    );

    // 先走到底，建立真实高度；再从底部逐屏上翻，经过正文中段。
    for (var i = 0; i < 200; i++) {
      position.jumpTo(position.pixels + 500);
      await tester.pumpAndSettle();
      if (position.extentAfter == 0) break;
    }
    expect(position.extentAfter, 0);
    var capturedMiddle = false;
    for (var i = 0; i < 200 && position.pixels > 0; i++) {
      await tester.drag(list, const Offset(0, 280));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        controller.snapshot.whereType<AssistantMessageItem>().single.text,
        text,
      );
      if (position.pixels < height - 700 && position.pixels > 700) {
        expect(bubble, findsOneWidget);
        final rect = tester.getRect(bubble);
        expect(rect.top, lessThan(100));
        expect(rect.bottom, greaterThan(500));
        if (!capturedMiddle && position.pixels < height / 2) {
          capturedMiddle = true;
          // 截视口中部，避开 AppBar / 输入框，检查真正绘出的文字像素。
          // 软件渲染无法复现所有 GPU 缓存故障；这个断言只保证该路径有正文。
          final darkPixels = await tester.runAsync(() async {
            final layer =
                tester.binding.renderViews.single.debugLayer! as OffsetLayer;
            final image = await layer.toImage(
              const Rect.fromLTWH(40, 150, 750, 300),
            );
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              var count = 0;
              for (var p = 0; p < bytes.length; p += 4) {
                if (bytes[p] < 100 &&
                    bytes[p + 1] < 100 &&
                    bytes[p + 2] < 100 &&
                    bytes[p + 3] > 0) {
                  count++;
                }
              }
              return count;
            } finally {
              image.dispose();
            }
          });
          expect(darkPixels, greaterThan(1000), reason: '正文中段不能只有气泡底色');
        }
      }
    }
    expect(capturedMiddle, isTrue, reason: '必须确实从下方经过长正文中段');
  });

  testWidgets('普通消息仍有独立重绘边界', (tester) async {
    mockTimeline();
    await startController(tester);
    await pushEvent(
      tester,
      'user_message',
      sseEvent('user_message', id: 'user', payload: {'text': '普通消息'}),
    );
    await pumpPage(tester);
    await tester.pumpAndSettle();
    RenderObject? ancestor = tester
        .renderObject(find.byType(UserMessageBubble))
        .parent;
    while (ancestor != null && !ancestor.isRepaintBoundary) {
      ancestor = ancestor.parent;
    }
    expect(ancestor, isA<RenderRepaintBoundary>());
  });
}
