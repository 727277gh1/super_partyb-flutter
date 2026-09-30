import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

/// 把组件放进最小可用的 MaterialApp 里。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ErrorBanner', () {
    testWidgets('渲染文案，且调用方传入的 key 落在最外层容器上', (tester) async {
      await tester.pumpWidget(
        _host(
          const ErrorBanner(
            key: ValueKey('probe-error'),
            message: '会话已失效，请重新登录',
          ),
        ),
      );

      expect(find.text('会话已失效，请重新登录'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('probe-error')),
        findsOneWidget,
        reason: '页面用 key 断言「本页是否在报错」，key 必须由调用方控制',
      );
    });

    testWidgets('底色用 errorContainer（而非硬编码红色）', (tester) async {
      await tester.pumpWidget(_host(const ErrorBanner(message: 'x')));

      final scheme = Theme.of(tester.element(find.byType(ErrorBanner)))
          .colorScheme;
      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(ErrorBanner),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration! as BoxDecoration;

      expect(
        decoration.color,
        scheme.errorContainer,
        reason: '颜色必须走主题令牌，否则换主题时提示条不会跟着变',
      );
    });

    testWidgets('长文案不溢出（Expanded + 可换行）', (tester) async {
      final long = '失败原因：' * 40;
      await tester.pumpWidget(_host(ErrorBanner(message: long)));

      expect(tester.takeException(), isNull);
      expect(find.text(long), findsOneWidget);
    });
  });

  group('HintLine', () {
    testWidgets('三种等级各自渲染对应图标', (tester) async {
      final cases = <HintKind, IconData>{
        HintKind.info: Icons.check_circle_outline,
        HintKind.warn: Icons.info_outline,
        HintKind.error: Icons.error_outline,
      };

      for (final entry in cases.entries) {
        await tester.pumpWidget(_host(HintLine(hint: Hint('提示文本', entry.key))));
        expect(find.text('提示文本'), findsOneWidget);
        expect(
          find.byIcon(entry.value),
          findsOneWidget,
          reason: '${entry.key} 应对应 ${entry.value}',
        );
      }
    });

    testWidgets('长文案单行省略（不换行、不溢出）', (tester) async {
      final long = '很长的提示' * 100;
      await tester.pumpWidget(_host(HintLine(hint: Hint(long, HintKind.warn))));

      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text(long));
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, isNull, reason: '靠 overflow+Expanded 单行省略');
    });
  });

  group('SectionTitle', () {
    testWidgets('不传 style 时用主题的 titleSmall', (tester) async {
      await tester.pumpWidget(_host(const SectionTitle('同步目录')));

      final context = tester.element(find.byType(SectionTitle));
      final text = tester.widget<Text>(find.text('同步目录'));
      expect(text.style, Theme.of(context).textTheme.titleSmall);
    });

    testWidgets('highlight: true 时用 labelLarge + 主色（设置页那种标题）', (tester) async {
      await tester.pumpWidget(_host(const SectionTitle('账号', highlight: true)));

      final context = tester.element(find.byType(SectionTitle));
      final theme = Theme.of(context);
      final text = tester.widget<Text>(find.text('账号'));

      expect(
        text.style!.fontSize,
        theme.textTheme.labelLarge!.fontSize,
        reason: '上提前设置页用 labelLarge，合并时不能丢掉这个差异',
      );
      expect(
        text.style!.color,
        theme.colorScheme.primary,
        reason: '设置页标题必须带主色，否则与卡片内容分不出层次',
      );
    });

    testWidgets('默认无色（工作详情页那种标题）', (tester) async {
      await tester.pumpWidget(_host(const SectionTitle('步骤')));

      final context = tester.element(find.byType(SectionTitle));
      final text = tester.widget<Text>(find.text('步骤'));
      expect(text.style, Theme.of(context).textTheme.titleSmall);
      expect(
        text.style!.color,
        isNot(Theme.of(context).colorScheme.primary),
        reason: '默认变体不该染主色（详情页会与状态色打架）',
      );
    });

    testWidgets('底部留 SpbSpacing.sm 间距（标题与内容不贴死）', (tester) async {
      await tester.pumpWidget(_host(const SectionTitle('步骤')));

      final padding = tester.widget<Padding>(
        find.descendant(
          of: find.byType(SectionTitle),
          matching: find.byType(Padding),
        ),
      );
      expect(padding.padding, const EdgeInsets.only(bottom: SpbSpacing.sm));
    });
  });
}
