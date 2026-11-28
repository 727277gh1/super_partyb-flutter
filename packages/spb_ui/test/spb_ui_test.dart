import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';

/// 把组件放进最小可用的 MaterialApp 里。
Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ErrorBanner', () {
    testWidgets('移动端重试按钮至少 48dp，浅深主题均可点击', (tester) async {
      var retries = 0;
      for (final theme in [SpbTheme.light(), SpbTheme.dark()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Center(
                child: ErrorBanner(message: '下载失败', onRetry: () => retries++),
              ),
            ),
          ),
        );
        final retry = find.byType(TextButton);
        expect(tester.getSize(retry).shortestSide, greaterThanOrEqualTo(48));
        await tester.tap(retry);
      }
      expect(retries, 2);
    });
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

    testWidgets('category 作为分类徽标渲染在正文之上，与正文分开', (tester) async {
      // 徽标回答「哪一类失败」（来自服务端 code），正文永远是 message；
      // 两者混在一起就会变成客户端在造句。
      await tester.pumpWidget(
        _host(
          const ErrorBanner(
            message: '执行被内存上限 1024 MB 打断（OOM），本轮未完成',
            category: '内存不足',
          ),
        ),
      );

      expect(find.text('内存不足'), findsOneWidget);
      expect(find.text('执行被内存上限 1024 MB 打断（OOM），本轮未完成'), findsOneWidget);
    });

    testWidgets('category 为 null 时不渲染徽标（历史事件 / 未知 code）', (tester) async {
      await tester.pumpWidget(_host(const ErrorBanner(message: 'x')));

      expect(find.text('执行失败'), findsNothing);
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('detail 默认折叠，点「技术详情」后展开（可选中复制）', (tester) async {
      // `detail` 是执行器原样给的诊断串（含英文 / 路径），默认展示会把
      // 它当成用户要读的正文；折叠后只在排障时展开。
      await tester.pumpWidget(
        _host(
          const ErrorBanner(
            message: '模型服务限流，稍后重试',
            detail: 'transport: upstream 429',
          ),
        ),
      );

      expect(find.text('技术详情'), findsOneWidget);
      expect(find.text('transport: upstream 429'), findsNothing);

      await tester.tap(find.text('技术详情'));
      await tester.pump();

      expect(find.text('transport: upstream 429'), findsOneWidget);
      expect(find.text('收起技术详情'), findsOneWidget);
    });

    testWidgets('detail 为 null / 空串时不渲染折叠入口', (tester) async {
      for (final detail in [null, '', '   ']) {
        await tester.pumpWidget(
          _host(ErrorBanner(message: 'x', detail: detail)),
        );

        expect(find.text('技术详情'), findsNothing, reason: '$detail');
      }
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

  /// 「技术详情」折叠按钮的触控目标（#129）。
  ///
  /// ## 修复前的实测
  ///
  /// `minimumSize: Size(0, SpbSpacing.lg)` + `padding: EdgeInsets.zero` +
  /// `tapTargetSize: shrinkWrap` 三者叠加后，真实命中区只有 56×21dp（1.0 字号）。
  /// 同一个 Banner 里的「重试」按钮早就按端分档了，这个折叠按钮漏了。
  ///
  /// ## 为什么量的是 `TextButton` 自己的尺寸
  ///
  /// 命中区必须落在**接收点击的组件**上。外面套一个大盒子看着够大，但盒子
  /// 不参与 hit testing，点上去什么也不会发生——这类「假达标」只有 `tapAt`
  /// 能抓出来，所以下面还有一条边缘点击用例。
  group('触控目标（#129）', () {
    const detail = 'transport: upstream 429';

    Future<Size> detailButtonSize(WidgetTester tester, ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(
              child: ErrorBanner(message: '本轮失败', detail: detail),
            ),
          ),
        ),
      );
      // `MaterialApp` 用 `AnimatedTheme` 过渡主题：pump 一次拿到的还是上一个
      // 主题的值（连续切换移动/桌面时会把两档测成同一档）。
      await tester.pumpAndSettle();
      return tester.getSize(find.widgetWithText(TextButton, '技术详情'));
    }

    testWidgets('技术详情按钮移动端命中区 ≥48dp，桌面端保持紧凑', (tester) async {
      final mobile = await detailButtonSize(tester, SpbTheme.light());
      expect(mobile.width, greaterThanOrEqualTo(48));
      expect(mobile.height, greaterThanOrEqualTo(48));

      final desktop = await detailButtonSize(
        tester,
        SpbTheme.lightFor(TargetPlatform.linux),
      );
      expect(desktop.height, lessThan(48), reason: '桌面端鼠标操作，保持紧凑（与「重试」按钮同一分支）');
    });

    testWidgets('命中区上缘（文字之外）点击也能展开技术详情', (tester) async {
      await detailButtonSize(tester, SpbTheme.light());
      final rect = tester.getRect(find.widgetWithText(TextButton, '技术详情'));

      await tester.tapAt(Offset(rect.center.dx, rect.top + 2));
      await tester.pump();

      expect(find.text(detail), findsOneWidget, reason: '扩展出来的命中区必须真的能点');
      expect(find.text('收起技术详情'), findsOneWidget);
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

  /// 整页状态面的约束矩阵（#126）。
  ///
  /// ## 为什么必须用 2.0 倍字号 + 320dp
  ///
  /// §6.80 决定**不** clamp 系统字号，320dp 又是当前最小的常见手机宽度。
  /// 修复前实测：`ErrorState` 在这些条件下溢出 191dp、`EmptyState` 溢出 127dp，
  /// 而当时的测试全绿——因为没有任何一条用例同时设过窄屏与大字号。
  group('状态面的约束与滚动（#126）', () {
    /// 一百来字的真实错误文案（`SpbError.message` 的典型长度，含 URL）。
    const longMessage =
        '连接服务器失败（https://dever.example.com/pba/chat/groups）：'
        'connection timed out after 12s。请检查网络后重试；'
        '如果仍然失败，请联系管理员并提供上面这行完整提示，以便定位是网络、'
        '网关还是服务端的问题。';

    /// 以指定逻辑尺寸 + 系统字号渲染。尺寸与字号都按真实宿主的方式注入
    /// （`platformDispatcher` → `MaterialApp` 派生 `MediaQuery`）。
    Future<void> pumpSized(
      WidgetTester tester,
      Widget child, {
      Size size = const Size(320, 640),
      double textScale = 2.0,
    }) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.binding.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: SpbTheme.light(),
          home: Scaffold(body: child),
        ),
      );
    }

    testWidgets('ErrorState 320×640 @2.0：长文案不溢出，可滚到重试按钮并点击', (tester) async {
      var retried = 0;
      await pumpSized(
        tester,
        ErrorState(
          key: const ValueKey('probe-error-state'),
          message: longMessage,
          onRetry: () => retried++,
          retryKey: const ValueKey('probe-retry'),
        ),
      );

      // 溢出在测试里是硬失败：有 RenderFlex overflow 就会在这里抛。
      expect(tester.takeException(), isNull);
      expect(find.text(longMessage), findsOneWidget);

      // 只断言「不抛异常」不够：按钮必须真的可达、可点。
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('probe-retry')),
        120,
      );
      await tester.tap(find.byKey(const ValueKey('probe-retry')));
      expect(retried, 1);
    });

    testWidgets('EmptyState 320×640 @2.0：长文案不溢出，原文完整可见', (tester) async {
      await pumpSized(
        tester,
        const EmptyState(message: longMessage, icon: Icons.chat_bubble_outline),
      );

      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text(longMessage));
      expect(text.maxLines, isNull, reason: '空态文案不截断');
    });

    testWidgets('320×640 @1.0：长文案与短文案都不溢出（字号不是唯一变量）', (tester) async {
      for (final message in [longMessage, '还没有对话']) {
        await pumpSized(
          tester,
          EmptyState(message: message, icon: Icons.inbox),
          textScale: 1.0,
        );
        expect(tester.takeException(), isNull, reason: message);
      }
    });

    testWidgets('375×812 与桌面 720×600 不回归', (tester) async {
      await pumpSized(
        tester,
        const ErrorState(message: longMessage, retryLabel: '重试'),
        size: const Size(375, 812),
      );
      expect(tester.takeException(), isNull);

      await pumpSized(
        tester,
        const EmptyState(message: longMessage),
        size: const Size(720, 600),
        textScale: 1.0,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('有界高度下短文案仍垂直居中', (tester) async {
      await pumpSized(
        tester,
        const EmptyState(message: '还没有对话'),
        textScale: 1.0,
      );

      final center = tester.getCenter(find.text('还没有对话'));
      expect(center.dy, closeTo(320, 1), reason: '短内容应居中而不是贴顶');
    });

    testWidgets('嵌在 ListView 里（无界高度）不产生无限尺寸异常，按内容自然布局', (tester) async {
      // GroupListPage 就是这样用的：空列表也要能下拉刷新。
      await pumpSized(
        tester,
        ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            EmptyState(message: '还没有对话', icon: Icons.chat_bubble_outline),
          ],
        ),
        textScale: 1.0,
      );

      expect(tester.takeException(), isNull);
      final size = tester.getSize(find.byType(EmptyState));
      expect(
        size.height,
        lessThan(320),
        reason: '无界高度下不应拿 minHeight = infinity 去撑满',
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

  group('SpbLogo', () {
    testWidgets('按传入尺寸渲染，且资源路径带包前缀', (tester) async {
      await tester.pumpWidget(_host(const SpbLogo(size: 48)));

      final image = tester.widget<Image>(
        find.descendant(of: find.byType(SpbLogo), matching: find.byType(Image)),
      );
      expect(image.width, 48);
      expect(image.height, 48);
      expect(
        (image.image as AssetImage).assetName,
        'packages/spb_ui/assets/brand/logo.png',
        reason: '包内资源必须带 packages/<pkg>/ 前缀，否则运行时找不到',
      );
    });

    testWidgets('装饰性：不进入语义树（旁边已有标题文案）', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const SpbLogo(size: 48)));

      expect(
        find.descendant(
          of: find.byType(SpbLogo),
          matching: find.bySemanticsLabel(RegExp('.')),
        ),
        findsNothing,
        reason: '纯装饰标志不该被屏幕阅读器念出来',
      );
      handle.dispose();
    });

    testWidgets('大图用 md 圆角、小图用 sm 圆角', (tester) async {
      await tester.pumpWidget(_host(const SpbLogo(size: 64)));
      final big = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
      expect(big.borderRadius, SpbRadius.cardAll);

      await tester.pumpWidget(_host(const SpbLogo(size: 16)));
      final small = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
      expect(
        small.borderRadius,
        const BorderRadius.all(Radius.circular(SpbRadius.sm)),
      );
    });
  });
}
