import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:spb_features/spb_features.dart';

void main() {
  Widget host({
    required bool streaming,
    void Function(String, String)? onLink,
  }) => MaterialApp(
    home: Scaffold(
      body: AssistantMessageBubble(
        text: '已完成的段落\n\n[打开链接](https://example.com)\n\n末尾正文',
        isStreaming: streaming,
        onLinkTap: onLink,
      ),
    ),
  );

  testWidgets('流式结束保留 Markdown 解析 State，正文从禁选切换为可选', (tester) async {
    await tester.pumpWidget(host(streaming: true));
    await tester.pumpAndSettle();
    final markdown = find.byType(GptMarkdown);
    // GptMarkdown 本身无 State；必须检查其内部解析器，而不是只比较外层 Element。
    final parser = find.descendant(
      of: markdown,
      matching: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_IncrementalMdView',
      ),
    );
    final before = tester.state(parser);
    final text = find.text('已完成的段落');
    final paragraph = tester.widget<Text>(text);
    expect(SelectionContainer.maybeOf(tester.element(text)), isNull);

    await tester.pumpWidget(host(streaming: false));
    await tester.pumpAndSettle();

    expect(tester.state(parser), same(before), reason: '结束时不得销毁解析器及其增量缓存');
    expect(tester.widget<Text>(text), same(paragraph), reason: '已定型段落的缓存也应保留');
    expect(SelectionContainer.maybeOf(tester.element(text)), isNotNull);
    final selection = tester.state<SelectionAreaState>(
      find.byType(SelectionArea),
    );
    selection.selectableRegion.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.descendant(of: text, matching: find.byType(RichText)),
          )
          .selections,
      [const TextSelection(baseOffset: 0, extentOffset: '已完成的段落'.length)],
      reason: '启用后必须真正接入 SelectionArea，不能仅有非空 registrar',
    );
    await tester.pumpWidget(host(streaming: true));
    await tester.pumpAndSettle();
    expect(tester.state(parser), same(before));
    expect(SelectionContainer.maybeOf(tester.element(text)), isNull);
  });

  testWidgets('已缓存的链接始终调用最新回调，包括从 null 启用', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(streaming: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      host(streaming: false, onLink: (_, _) => calls.add('first')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开链接', findRichText: true));
    await tester.pumpWidget(
      host(streaming: false, onLink: (_, _) => calls.add('second')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开链接', findRichText: true));
    await tester.pumpWidget(host(streaming: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开链接', findRichText: true));
    expect(calls, ['first', 'second']);
  });
}
