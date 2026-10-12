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

    testWidgets('onRetry 为 null 时不渲染按钮', (tester) async {
      await tester.pumpWidget(_host(const ErrorBanner(message: 'x')));

      expect(
        find.byType(TextButton),
        findsNothing,
        reason: '不可重试的错误渲染一个按了没用的按钮比不渲染更糟',
      );
    });

    testWidgets('注入 onRetry 时渲染按钮且点击回调生效', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(ErrorBanner(message: '本轮执行失败', onRetry: () => taps++)),
      );

      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('retryLabel 可自定义（对话页用「重发」）', (tester) async {
      await tester.pumpWidget(
        _host(ErrorBanner(message: 'x', onRetry: () {}, retryLabel: '重发')),
      );

      expect(find.text('重发'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('带按钮时长文案不溢出', (tester) async {
      final long = '失败原因：' * 40;
      await tester.pumpWidget(
        _host(ErrorBanner(message: long, onRetry: () {})),
      );

      expect(tester.takeException(), isNull);
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

  group('EmptyState', () {
    testWidgets('渲染文案', (tester) async {
      await tester.pumpWidget(_host(const EmptyState(message: '还没有对话')));

      expect(find.text('还没有对话'), findsOneWidget);
    });

    testWidgets('icon 为 null 时不渲染图标（对话页的空提示刻意不带图标）', (tester) async {
      // ## 这个断言防的是什么
      //
      // 对话页的空提示出现在输入框正上方，加图标会让「引导输入」看起来像
      // 「页面出错」。若组件给 icon 一个非空默认值，那个页面就会悄悄多出一个
      // 图标——而它的测试只断言文案，抓不到。
      await tester.pumpWidget(_host(const EmptyState(message: '还没有对话')));

      expect(
        find.descendant(
          of: find.byType(EmptyState),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
    });

    testWidgets('icon 非空时渲染图标', (tester) async {
      await tester.pumpWidget(
        _host(
          const EmptyState(message: '还没有对话', icon: Icons.chat_bubble_outline),
        ),
      );

      expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    });

    testWidgets('图标用弱化色 outline（空状态不是错误）', (tester) async {
      await tester.pumpWidget(
        _host(const EmptyState(message: 'x', icon: Icons.inbox)),
      );

      final scheme = Theme.of(tester.element(find.byType(EmptyState)))
          .colorScheme;
      final icon = tester.widget<Icon>(find.byIcon(Icons.inbox));
      expect(icon.color, scheme.outline, reason: '用 error 色会让用户以为页面出错了');
    });

    testWidgets('长文案居中换行（不溢出）', (tester) async {
      const long = '这是一段相当长的空状态提示文案，需要换行显示而不能溢出屏幕边界';
      await tester.pumpWidget(_host(const EmptyState(message: long)));

      final text = tester.widget<Text>(find.text(long));
      expect(text.textAlign, TextAlign.center);
      expect(tester.takeException(), isNull);
    });
  });

  group('ErrorState', () {
    testWidgets('渲染消息与重试按钮', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        _host(ErrorState(message: '加载失败', onRetry: () => retried++)),
      );

      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      expect(retried, 1);
    });

    testWidgets('onRetry 为 null 时不渲染按钮（不可重试的错误不该给按钮）', (tester) async {
      // 有些错误不可重试（参数非法、权限不足）。渲染一个按了也没用的「重试」
      // 比不渲染更糟——用户会反复点它。
      await tester.pumpWidget(_host(const ErrorState(message: '权限不足')));

      expect(find.text('权限不足'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ErrorState),
          matching: find.byType(FilledButton),
        ),
        findsNothing,
      );
    });

    testWidgets('图标用 error 色（与 EmptyState 的弱化色区分开）', (tester) async {
      await tester.pumpWidget(_host(const ErrorState(message: 'x')));

      final scheme = Theme.of(tester.element(find.byType(ErrorState)))
          .colorScheme;
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      expect(icon.color, scheme.error);
    });

    testWidgets('retryLabel 可定制', (tester) async {
      await tester.pumpWidget(
        _host(ErrorState(message: 'x', onRetry: () {}, retryLabel: '重新加载')),
      );

      expect(find.text('重新加载'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('与 ErrorBanner 的差别：整页居中而非内联卡片', (tester) async {
      // 两者都是「错误」，但排版必须不同——Banner 是嵌在别的布局里的一块
      // 底色，State 是占据整页的居中块。混用会让「局部错误」把整页顶掉。
      await tester.pumpWidget(_host(const ErrorState(message: 'x')));

      expect(
        find.descendant(
          of: find.byType(ErrorState),
          matching: find.byType(Center),
        ),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(
          of: find.byType(ErrorState),
          matching: find.byType(ErrorBanner),
        ),
        findsNothing,
      );
    });
  });

  group('HighlightedText', () {
    /// 取渲染后的富文本 spans。
    List<TextSpan> spansOf(WidgetTester tester) {
      final rich = tester.widget<Text>(find.byType(Text));
      return (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
    }

    /// 高亮样式（测试用它区分「命中」与「普通」span）。
    ///
    /// 必须显式传：`highlightStyle` 为 null 时组件退化为 `style`，此时
    /// 「高亮」在渲染上不可见——组件的行为是对的，但断言无从区分。
    const highlight = TextStyle(backgroundColor: Color(0xFF00FF00));

    testWidgets('高亮全部命中处（不止第一处）', (tester) async {
      await tester.pumpWidget(
        _host(
          const HighlightedText(
            text: 'todo 与 TODO',
            query: 'todo',
            highlightStyle: highlight,
          ),
        ),
      );

      final spans = spansOf(tester);
      final highlighted = spans.where((s) => s.style?.backgroundColor != null);
      expect(highlighted, hasLength(2));
      expect(highlighted.map((s) => s.text), ['todo', 'TODO']);
    });

    testWidgets('保留原文大小写（不高亮成小写）', (tester) async {
      await tester.pumpWidget(
        _host(
          const HighlightedText(
            text: 'ERROR',
            query: 'error',
            highlightStyle: highlight,
          ),
        ),
      );

      final highlighted = spansOf(tester)
          .where((s) => s.style?.backgroundColor != null);
      expect(highlighted.single.text, 'ERROR');
    });

    testWidgets('查询词为空 → 退化为普通 Text（不高亮、无 RichText）', (tester) async {
      await tester.pumpWidget(
        _host(const HighlightedText(text: '普通文本', query: '')),
      );

      final rich = tester.widget<Text>(find.byType(Text));
      expect(rich.textSpan, isNull, reason: '空查询不该构造 spans');
      expect(find.text('普通文本'), findsOneWidget);
    });

    testWidgets('文本为空 → 退化为普通 Text', (tester) async {
      await tester.pumpWidget(
        _host(const HighlightedText(text: '', query: 'x')),
      );

      expect(tester.widget<Text>(find.byType(Text)).textSpan, isNull);
    });

    testWidgets('无命中 → 单个未高亮 span，文本完整', (tester) async {
      await tester.pumpWidget(
        _host(const HighlightedText(text: 'hello', query: 'zzz')),
      );

      final spans = spansOf(tester);
      expect(spans, hasLength(1));
      expect(spans.single.text, 'hello');
      expect(spans.single.style?.backgroundColor, isNull);
    });

    testWidgets('含正则元字符的查询不抛异常（字面量匹配）', (tester) async {
      await tester.pumpWidget(
        _host(
          const HighlightedText(
            text: 'a ( b',
            query: '(',
            highlightStyle: highlight,
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final highlighted = spansOf(tester)
          .where((s) => s.style?.backgroundColor != null);
      expect(highlighted.single.text, '(');
    });

    testWidgets('toLowerCase 长度不变（切片下标可直接互用的前提）', (tester) async {
      // `HighlightedText` 用小写匹配的结果去切**原文**片段（保留原大小写），
      // 这依赖 Dart 的 `toLowerCase` 用简单大小写映射、长度不变。
      // 若某次 Dart 升级改成完整映射（如 `İ` → `i̇`），这里会失败并指向该假设。
      for (final s in ['İstanbul', 'ẞ', '中文ABC']) {
        expect(s.toLowerCase().length, s.length, reason: '前提：长度不变');
      }
    });

    testWidgets('非 ASCII 大小写字符也保留原文', (tester) async {
      await tester.pumpWidget(
        _host(
          const HighlightedText(
            text: 'İstanbul 之行',
            query: 'stanbul',
            highlightStyle: highlight,
          ),
        ),
      );

      final joined = spansOf(tester).map((s) => s.text).join();
      expect(joined, 'İstanbul 之行', reason: '切片不能错位或丢字');
      final highlighted = spansOf(tester)
          .where((s) => s.style?.backgroundColor != null);
      expect(highlighted.single.text, 'stanbul');
    });

    testWidgets('命中在开头与结尾时文本完整无丢字', (tester) async {
      await tester.pumpWidget(
        _host(const HighlightedText(text: 'ab cd ab', query: 'ab')),
      );

      final joined = spansOf(tester).map((s) => s.text).join();
      expect(joined, 'ab cd ab');
    });
  });
}
