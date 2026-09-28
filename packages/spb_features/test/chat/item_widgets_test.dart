import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('MessageComposer 键盘行为', () {
    testWidgets('Enter 发送（回调收到文本且输入框被清空）', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '你好');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, ['你好']);
      // 清空很重要：否则用户会以为没发出去而重复发送。
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('Shift+Enter 换行，不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '第一行');
      await tester.pump();

      // 按住 Shift 再按 Enter。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(submitted, isEmpty, reason: 'Shift+Enter 不应触发发送');
    });

    testWidgets('空输入按 Enter 不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, isEmpty);
    });

    testWidgets('纯空白输入按 Enter 不发送（trim 后为空）', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, isEmpty);
    });

    testWidgets('提交的文本被 trim', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '  你好  ');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(submitted, ['你好']);
    });

    testWidgets('Esc 清空输入且不发送', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _host(MessageComposer(onSubmit: submitted.add, autofocus: true)),
      );

      await tester.enterText(find.byType(TextField), '要丢弃的内容');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(submitted, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('发送按钮：空输入时禁用，有文本时可用', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(_host(MessageComposer(onSubmit: submitted.add)));

      // 空输入 → 禁用。
      final sendButton = find.byKey(const ValueKey('composer-send'));
      expect(
        tester.widget<IconButton>(sendButton).onPressed,
        isNull,
        reason: '空输入时发送按钮应禁用',
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      expect(tester.widget<IconButton>(sendButton).onPressed, isNotNull);

      await tester.tap(sendButton);
      await tester.pump();
      expect(submitted, ['x']);
    });

    testWidgets('onSubmit 为 null 时输入框禁用', (tester) async {
      await tester.pumpWidget(_host(const MessageComposer(onSubmit: null)));

      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });
  });

  group('UserMessageBubble', () {
    testWidgets('渲染文本且右对齐', (tester) async {
      await tester.pumpWidget(_host(const UserMessageBubble(text: '用户说的话')));

      expect(find.text('用户说的话'), findsOneWidget);
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
    });
  });

  group('AssistantMessageBubble', () {
    testWidgets('渲染文本', (tester) async {
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '助手的回复')),
      );

      expect(find.text('助手的回复'), findsOneWidget);
    });

    testWidgets('流式且文本为空时显示「正在生成」占位', (tester) async {
      // 空文本 + 流式中：必须给占位，否则是 0 高度气泡（用户以为卡住）。
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '', isStreaming: true)),
      );

      expect(find.text('正在生成…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 让动画控制器停下，避免 pending timer 警告。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('流式中显示光标（WidgetSpan），非流式用纯文本', (tester) async {
      await tester.pumpWidget(
        _host(const AssistantMessageBubble(text: '半句话', isStreaming: true)),
      );
      // 流式：文本 + 一个 WidgetSpan 光标。
      // 用稳定 key 定位，不用 FadeTransition 类型——MaterialApp 自身也会
      // 注入多个 FadeTransition（路由过渡），按类型断言会误判。
      expect(
        find.byKey(const ValueKey('assistant-streaming-cursor')),
        findsOneWidget,
      );

      await tester.pumpWidget(_host(const AssistantMessageBubble(text: '半句话')));
      // 非流式：无光标。
      expect(
        find.byKey(const ValueKey('assistant-streaming-cursor')),
        findsNothing,
      );
    });
  });

  group('ThoughtTile（可折叠）', () {
    testWidgets('默认折叠，展开后显示全文', (tester) async {
      await tester.pumpWidget(_host(const ThoughtTile(text: '第一行思考\n第二行思考')));

      expect(find.text('思考过程'), findsOneWidget);
      // 默认折叠：全文不可见。
      expect(find.text('第一行思考\n第二行思考'), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();

      expect(find.text('第一行思考\n第二行思考'), findsOneWidget);
    });

    testWidgets('流式中标题为「思考中…」', (tester) async {
      await tester.pumpWidget(
        _host(const ThoughtTile(text: '思考内容', isStreaming: true)),
      );

      expect(find.text('思考中…'), findsOneWidget);
    });

    testWidgets('长首行摘要被截断', (tester) async {
      final long = '很长的第一行' * 20;
      await tester.pumpWidget(_host(ThoughtTile(text: long)));

      // 摘要截断到 60 字符 + 省略号，故完整长串不应出现在摘要里。
      expect(find.text(long), findsNothing);
    });
  });

  group('ToolCallTile', () {
    testWidgets('执行中显示「执行中」且带进度指示', (tester) async {
      await tester.pumpWidget(
        _host(const ToolCallTile(name: 'bash', output: null)),
      );

      expect(find.text('bash'), findsOneWidget);
      expect(find.text('执行中'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('完成显示「完成」；展开后可见参数与结果', (tester) async {
      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'read',
            args: {'path': '/tmp/a.txt'},
            output: 'file contents',
            isComplete: true,
          ),
        ),
      );

      expect(find.text('完成'), findsOneWidget);
      // 折叠态看不到参数与结果。
      expect(find.text('参数'), findsNothing);

      await tester.tap(find.text('read'));
      await tester.pumpAndSettle();

      expect(find.text('参数'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      // 参数以缩进 JSON 呈现。
      expect(find.textContaining('/tmp/a.txt'), findsOneWidget);
      expect(find.text('file contents'), findsOneWidget);
    });

    testWidgets('输出含 error 特征时显示「失败」', (tester) async {
      await tester.pumpWidget(
        _host(
          const ToolCallTile(
            name: 'bash',
            output: 'Error: command not found',
            isComplete: true,
          ),
        ),
      );

      expect(find.text('失败'), findsOneWidget);
    });
  });

  group('ConfirmationCard', () {
    testWidgets('渲染问题与选项按钮', (tester) async {
      await tester.pumpWidget(
        _host(
          const ConfirmationCard(
            question: '是否继续执行？',
            options: ['继续', '取消'],
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('需要你的确认'), findsOneWidget);
      expect(find.text('是否继续执行？'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('点击选项回调携带该选项文案', (tester) async {
      final resolved = <String>[];
      await tester.pumpWidget(
        _host(
          ConfirmationCard(
            question: '选一个',
            options: const ['A', 'B'],
            onResolve: resolved.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('confirmation-option-B')));
      await tester.pump();

      expect(resolved, ['B']);
    });

    testWidgets('options 为空时退化为默认「继续 / 取消」', (tester) async {
      // 服务端 confirmation_required 的 payload 可能只给 recommendation，
      // 不给 options（见 BuildConfirmationRequiredPayload）。此时必须给兜底按钮，
      // 否则卡片是一个无法操作的死块。
      await tester.pumpWidget(
        _host(
          const ConfirmationCard(
            question: '无选项',
            options: [],
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('继续'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });

    testWidgets('resolved 时按钮禁用且标题变为「已确认」', (tester) async {
      final resolved = <String>[];
      await tester.pumpWidget(
        _host(
          ConfirmationCard(
            question: '已处理',
            options: const ['继续'],
            resolved: true,
            onResolve: resolved.add,
          ),
        ),
      );

      expect(find.text('已确认'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);
      expect(resolved, isEmpty);
    });

    testWidgets('busy 时禁用按钮并显示「提交中」', (tester) async {
      await tester.pumpWidget(
        _host(
          ConfirmationCard(
            question: '提交中',
            options: const ['继续'],
            busy: true,
            onResolve: _noop,
          ),
        ),
      );

      expect(find.text('提交中…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('onResolve 为 null 时按钮禁用（只读展示）', (tester) async {
      await tester.pumpWidget(
        _host(const ConfirmationCard(question: '只读', options: ['继续'])),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirmation-option-继续')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('FollowUpChips', () {
    testWidgets('渲染建议 chip 且点击回调携带文本', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(
        _host(
          FollowUpChips(suggestions: const ['继续深入', '换个方案'], onTap: tapped.add),
        ),
      );

      expect(find.text('继续深入'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('follow-up-换个方案')));
      await tester.pump();

      expect(tapped, ['换个方案']);
    });

    testWidgets('空建议列表渲染为空白（不占高度）', (tester) async {
      await tester.pumpWidget(_host(const FollowUpChips(suggestions: [])));

      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('onTap 为 null 时 chip 不可点', (tester) async {
      await tester.pumpWidget(
        _host(const FollowUpChips(suggestions: ['只读建议'])),
      );

      final chip = tester.widget<ActionChip>(
        find.byKey(const ValueKey('follow-up-只读建议')),
      );
      expect(chip.onPressed, isNull);
    });
  });
}

void _noop(String _) {}
