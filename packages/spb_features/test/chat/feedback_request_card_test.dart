import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';

/// 包一层 MaterialApp（组件依赖 Theme 与 Directionality）。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('归属反馈卡：渲染', () {
    testWidgets('按 options 标签渲染按钮（语义真源在 options，非 spec）', (tester) async {
      await tester.pumpWidget(
        _host(
          const FeedbackRequestCard(
            question: '这条消息我归到了《团队周报》，准确吗？',
            options: ['准确', '不准确'],
            onResolve: null,
          ),
        ),
      );

      expect(find.text('这条消息我归到了《团队周报》，准确吗？'), findsOneWidget);
      expect(find.byKey(const ValueKey('feedback-option-准确')), findsOneWidget);
      expect(find.byKey(const ValueKey('feedback-option-不准确')), findsOneWidget);
    });

    testWidgets('options 为空时退化为默认两项（异常载荷仍可读可答）', (tester) async {
      await tester.pumpWidget(
        _host(
          const FeedbackRequestCard(
            question: '准确吗？',
            options: [],
            onResolve: null,
          ),
        ),
      );

      expect(find.text('准确'), findsOneWidget);
      expect(find.text('不准确'), findsOneWidget);
    });
  });

  group('归属反馈卡：回调语义', () {
    testWidgets('点「准确」传出 correct=true，「不准确」传出 false', (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(
        _host(
          FeedbackRequestCard(
            question: '准确吗？',
            options: const ['准确', '不准确'],
            onResolve: seen.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('feedback-option-准确')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('feedback-option-不准确')));
      await tester.pump();

      expect(seen, [true, false]);
    });

    testWidgets('onResolve 为 null 时按钮禁用（只读展示）', (tester) async {
      await tester.pumpWidget(
        _host(
          const FeedbackRequestCard(
            question: '准确吗？',
            options: ['准确', '不准确'],
            onResolve: null,
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull, reason: '没有回执通道时不得给一个点了没反应的按钮');
    });
  });

  group('归属反馈卡：状态禁用', () {
    testWidgets('busy 时按钮禁用（避免重复提交）', (tester) async {
      await tester.pumpWidget(
        _host(
          FeedbackRequestCard(
            question: '准确吗？',
            options: const ['准确', '不准确'],
            busy: true,
            onResolve: (_) {},
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('正在记录…'), findsOneWidget);
    });

    testWidgets('resolved 时按钮禁用且标题变为已反馈（不隐藏，保留历史上下文）', (tester) async {
      await tester.pumpWidget(
        _host(
          FeedbackRequestCard(
            question: '准确吗？',
            options: const ['准确', '不准确'],
            resolved: true,
            onResolve: (_) {},
          ),
        ),
      );

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('feedback-option-准确')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('已反馈'), findsOneWidget);
    });
  });

  group('isCorrectOption（label → bool 映射）', () {
    test('肯定与否定词映射正确', () {
      expect(FeedbackRequestCard.isCorrectOption('准确'), isTrue);
      expect(FeedbackRequestCard.isCorrectOption('正确'), isTrue);
      expect(FeedbackRequestCard.isCorrectOption('不准确'), isFalse);
      // 未知文案按「不准确」处理：宁可记为负面标注（会被复核），
      // 也不要把错误归属记成正确（污染标定数据且无人发现）。
      expect(FeedbackRequestCard.isCorrectOption('换个对话'), isFalse);
    });
  });
}
