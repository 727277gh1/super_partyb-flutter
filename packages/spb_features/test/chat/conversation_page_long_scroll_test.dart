import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import '../support/conversation_page_harness.dart';

void main() {
  setUpHarness();
  tearDownHarness();

  testWidgets(
    '多条长回复生成后从末尾上翻，正文持续绘制',
    (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      mockTimeline();
      await startController(tester);
      await pumpPage(tester);
      for (var reply = 0; reply < 16; reply++) {
        final turnId = 'long-turn-$reply';
        await pushEvent(
          tester,
          'start',
          sseEvent(
            'start',
            id: 'start-$reply',
            turnId: turnId,
            seq: reply * 3 + 1,
          ),
        );
        await pushEvent(
          tester,
          'message',
          sseEvent(
            'message',
            id: 'reply-$reply',
            turnId: turnId,
            seq: reply * 3 + 2,
            payload: {
              'text': [
                for (var paragraph = 0; paragraph < 40; paragraph++) ...[
                  '## 回复 $reply 第 $paragraph 段',
                  '长回复正文 **强调** `code`，反复向上滚动也应完整显示。' * 8,
                  if (paragraph % 8 == 0)
                    '```text\n${List.filled(30, 'long code block content').join('\n')}\n```',
                ],
              ].join('\n\n'),
            },
          ),
        );
        await pushEvent(
          tester,
          'done',
          sseEvent(
            'done',
            id: 'done-$reply',
            turnId: turnId,
            seq: reply * 3 + 3,
          ),
        );
      }
      await tester.pumpAndSettle();
      final list = find.byType(CustomScrollView).first;
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first,
          )
          .position;
      for (var attempt = 0; attempt < 10; attempt++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        if (position.extentAfter < 1) break;
      }
      expect(position.extentAfter, lessThan(1));
      expect(
        controller.snapshot.whereType<AssistantMessageItem>(),
        hasLength(16),
      );

      // 不先滚到顶部预热：覆盖逐条收到回复后，直接从末尾回看最近几条的路径。
      final initialPixels = position.pixels;
      for (var step = 0; step < 60; step++) {
        if (defaultTargetPlatform == TargetPlatform.android) {
          await tester.drag(list, const Offset(0, 280));
        } else {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(list),
              scrollDelta: const Offset(0, -280),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (step % 10 == 0) {
          final darkPixels = await _countBodyPixels(tester);
          expect(darkPixels, greaterThan(1000), reason: '第 $step 次上翻正文必须可见');
        }
      }
      expect(position.pixels, lessThan(initialPixels - 10000));
      expect(
        controller.snapshot.whereType<AssistantMessageItem>(),
        hasLength(16),
      );
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.android,
    }),
  );

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
    final list = find.byType(CustomScrollView).first;
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
          final darkPixels = await _countBodyPixels(tester);
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

Future<int?> _countBodyPixels(WidgetTester tester) => tester.runAsync(() async {
  final layer = tester.binding.renderViews.single.debugLayer! as OffsetLayer;
  final image = await layer.toImage(const Rect.fromLTWH(40, 150, 750, 300));
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
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
