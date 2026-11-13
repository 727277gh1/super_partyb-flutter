import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';

/// `spb_design` 设计令牌与主题的契约测试。
///
/// ## 这个测试防的是什么
///
/// 令牌文件是**纯常量表**，没有逻辑，因此长期无人测试——但它出错的后果是
/// **视觉层面的**，而且极难在 code review 里发现：
///
///   1. **单调性被破坏**：有人把 `SpbSpacing.md` 从 12 改成 6（「看着太宽了」），
///      于是 `md < sm`。布局代码里 `Spacing.sm + Spacing.md` 这类叠加值全错，
///      表现为「某些间距莫名其妙比预期小」，而没有任何报错。
///   2. **栅格被破坏**：`SpbSpacing` 文档明说「用 4 的倍数，避免 0.5px 累积
///      误差」。改成 10 或 14 后，在高 DPI 屏上会出现半像素渲染。
///   3. **主题构建抛异常**：`SpbTheme.light()` 在 `main()` 里被调用一次，
///      抛了就是**白屏启动失败**。且它依赖 `ColorScheme.fromSeed`，
///      对 seed 色有约束（不能是纯黑/纯白等极端值）。
///
/// 故这里把「令牌表的结构约束」和「主题可构建」钉成可执行的回归。
void main() {
  group('SpbSpacing 令牌', () {
    test('全部为正数（零或负间距是布局 bug 的常见来源）', () {
      const values = {
        'xxs': SpbSpacing.xxs,
        'xs': SpbSpacing.xs,
        'sm': SpbSpacing.sm,
        'md': SpbSpacing.md,
        'lg': SpbSpacing.lg,
        'xl': SpbSpacing.xl,
        'xxl': SpbSpacing.xxl,
        'xxxl': SpbSpacing.xxxl,
      };
      values.forEach((name, v) {
        expect(v, greaterThan(0), reason: 'SpbSpacing.$name 必须为正');
      });
    });

    test('严格单调递增（xxs < xs < sm < … < xxxl）', () {
      // 破坏单调性会让「用更大的令牌 = 更大间距」这一心智模型失效。
      const seq = [
        SpbSpacing.xxs,
        SpbSpacing.xs,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.lg,
        SpbSpacing.xl,
        SpbSpacing.xxl,
        SpbSpacing.xxxl,
      ];
      for (var i = 1; i < seq.length; i++) {
        expect(
          seq[i],
          greaterThan(seq[i - 1]),
          reason: '第 $i 项 ${seq[i]} 应大于前一项 ${seq[i - 1]}',
        );
      }
    });

    test('全部是 4 的倍数（文档声明的栅格约束）', () {
      // 这是**有意的设计约束**（避免高 DPI 下的半像素误差），不是巧合。
      const values = [
        SpbSpacing.xxs,
        SpbSpacing.xs,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.lg,
        SpbSpacing.xl,
        SpbSpacing.xxl,
        SpbSpacing.xxxl,
      ];
      for (final v in values) {
        // xxs = 2 是唯一的例外（文档写的是「8pt 栅格」但 xxs 为 2）。
        // 断言为「2 的倍数」覆盖全部取值，并额外确认除 xxs 外都是 4 的倍数。
        expect(v % 2, 0, reason: '$v 应为偶数');
      }
      const fourMultiples = [
        SpbSpacing.xs,
        SpbSpacing.sm,
        SpbSpacing.md,
        SpbSpacing.lg,
        SpbSpacing.xl,
        SpbSpacing.xxl,
        SpbSpacing.xxxl,
      ];
      for (final v in fourMultiples) {
        expect(v % 4, 0, reason: '$v 应为 4 的倍数');
      }
    });

    test('复合 EdgeInsets 用的是令牌值（不是硬编码数字）', () {
      // 若有人把 `EdgeInsets.all(lg)` 改成 `EdgeInsets.all(16)`，视觉不变但
      // 令牌失去意义——改令牌将不再影响这些组件。断言它们**相等**即可钉住。
      expect(
        SpbSpacing.bubblePadding,
        const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
      );
      expect(SpbSpacing.pagePadding, const EdgeInsets.all(SpbSpacing.lg));
      expect(SpbSpacing.cardPadding, const EdgeInsets.all(SpbSpacing.md));
    });
  });

  group('SpbRadius 令牌', () {
    test('为正且递增（xs < sm < md < lg < pill）', () {
      const seq = [
        SpbRadius.xs,
        SpbRadius.sm,
        SpbRadius.md,
        SpbRadius.lg,
        SpbRadius.pill,
      ];
      for (var i = 0; i < seq.length; i++) {
        expect(seq[i], greaterThan(0));
        if (i > 0) expect(seq[i], greaterThan(seq[i - 1]));
      }
    });

    test('pill 大到足以形成胶囊（大于任何实际控件高度的一半）', () {
      // pill 的语义是「完全圆头」。若被改小（如 24），在 48px 高的按钮上
      // 就不再是胶囊了。用一个宽松但有效力的下界钉住。
      expect(SpbRadius.pill, greaterThanOrEqualTo(100));
    });

    test('复合 BorderRadius 用对应令牌', () {
      expect(
        SpbRadius.cardAll,
        const BorderRadius.all(Radius.circular(SpbRadius.md)),
      );
      expect(
        SpbRadius.bubbleAll,
        const BorderRadius.all(Radius.circular(SpbRadius.lg)),
      );
      expect(
        SpbRadius.inputAll,
        const BorderRadius.all(Radius.circular(SpbRadius.sm)),
      );
    });
  });

  group('SpbDuration 令牌', () {
    test('为正且递增（instant < fast < normal < slow）', () {
      const seq = [
        SpbDuration.instant,
        SpbDuration.fast,
        SpbDuration.normal,
        SpbDuration.slow,
      ];
      for (var i = 0; i < seq.length; i++) {
        expect(seq[i], greaterThan(Duration.zero));
        if (i > 0) expect(seq[i], greaterThan(seq[i - 1]));
      }
    });

    test('全部短于 500ms（文档：桌面端应比移动端更快）', () {
      // 桌面端鼠标操作无「手指抬起」延迟，沿用移动端时长（常 300–500ms）
      // 会显得拖沓。若有人把 normal 改成 500ms 以上，这条会挂。
      const seq = [
        SpbDuration.instant,
        SpbDuration.fast,
        SpbDuration.normal,
        SpbDuration.slow,
      ];
      for (final d in seq) {
        expect(d, lessThan(const Duration(milliseconds: 500)));
      }
    });
  });

  group('SpbBreakpoints', () {
    test('递增（compact < medium < expanded）', () {
      expect(SpbBreakpoints.compact, lessThan(SpbBreakpoints.medium));
      expect(SpbBreakpoints.medium, lessThan(SpbBreakpoints.expanded));
    });

    test('三档互斥且覆盖全宽度（边界不重叠、无空隙）', () {
      // 这是最容易写错的一处：`isMedium` 的上界用的是 expanded 而非 medium
      // （文档明说中档是「列表 + 内容」，在 medium 与 expanded 之间）。
      // 若三档有重叠，同一宽度会同时命中两档，布局分支取决于判断顺序；
      // 若有空隙，某些宽度三档全不命中，界面直接空白。
      const widths = [
        0.0,
        1.0,
        SpbBreakpoints.compact - 1,
        SpbBreakpoints.compact,
        SpbBreakpoints.compact + 1,
        SpbBreakpoints.medium,
        SpbBreakpoints.expanded - 1,
        SpbBreakpoints.expanded,
        SpbBreakpoints.expanded + 1,
        4000.0,
      ];

      for (final w in widths) {
        final hits = [
          SpbBreakpoints.isCompact(w),
          SpbBreakpoints.isMedium(w),
          SpbBreakpoints.isExpanded(w),
        ].where((x) => x).length;
        expect(hits, 1, reason: '宽度 $w 应恰好命中一档，实际命中 $hits 档');
      }
    });

    test('边界归属：compact 含下界、expanded 含下界、medium 在两者之间', () {
      // 具体归属（左闭右开）写死，防止「顺手」调整边界语义。
      expect(SpbBreakpoints.isCompact(SpbBreakpoints.compact - 0.1), isTrue);
      expect(SpbBreakpoints.isCompact(SpbBreakpoints.compact), isFalse);
      expect(SpbBreakpoints.isMedium(SpbBreakpoints.compact), isTrue);
      expect(SpbBreakpoints.isMedium(SpbBreakpoints.expanded), isFalse);
      expect(SpbBreakpoints.isExpanded(SpbBreakpoints.expanded), isTrue);
    });
  });

  group('SpbTheme 密度分支（§6.77）', () {
    // 与 localize 同源的真实字号：裸 ThemeData 的 textTheme fontSize 为
    // null（见 SpbType 组顶部的说明），必须经 ThemeData.localize 才拿得到。
    TextTheme resolved(ThemeData theme) => ThemeData.localize(
      theme,
      theme.typography.geometryThemeFor(ScriptCategory.englishLike),
    ).textTheme;

    test('桌面端：全局 compact + ListTile 级 compact + 标题钉在 14px', () {
      final theme = SpbTheme.lightFor(TargetPlatform.linux);
      expect(theme.visualDensity, VisualDensity.compact);
      expect(theme.listTileTheme.visualDensity, VisualDensity.compact);
      expect(
        theme.listTileTheme.dense,
        isNot(true),
        reason: 'dense 在 M3 下会硬改字号，禁用',
      );

      final title = resolved(theme);
      expect(title.titleSmall?.fontSize, 14.0);
    });

    test('移动端：standard 密度（触控目标 ≥48dp），不设 ListTile 级覆盖', () {
      for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
        final theme = SpbTheme.lightFor(p);
        expect(theme.visualDensity, VisualDensity.standard, reason: '$p');
        expect(theme.listTileTheme.visualDensity, isNull, reason: '$p');
        expect(theme.listTileTheme.dense, isNot(true), reason: '$p');
      }
    });

    test('ListTile 标题样式只设桌面端（移动端用 M3 默认 bodyLarge）', () {
      expect(
        SpbTheme.lightFor(TargetPlatform.linux).listTileTheme.titleTextStyle,
        isNotNull,
      );
      expect(
        SpbTheme.lightFor(TargetPlatform.android).listTileTheme.titleTextStyle,
        isNull,
      );
    });

    test('明暗两套的分支一致（dark 不会漏掉分支）', () {
      expect(
        SpbTheme.darkFor(TargetPlatform.linux).visualDensity,
        VisualDensity.compact,
      );
      expect(
        SpbTheme.darkFor(TargetPlatform.android).visualDensity,
        VisualDensity.standard,
      );
    });

    testWidgets('移动端单行 ListTile 实际高度 ≥48dp（触控目标下界）', (tester) async {
      // 摘掉 dense + 回到 standard 的全部意义就在这一条：移动端手指能点中。
      // 若将来有人把 dense 或 compact 加回移动端分支，这里会挂。
      await tester.pumpWidget(
        MaterialApp(
          theme: SpbTheme.lightFor(TargetPlatform.android),
          home: const Scaffold(body: ListTile(title: Text('行'))),
        ),
      );
      final height = tester.getSize(find.byType(ListTile)).height;
      expect(height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('桌面端单行 ListTile 维持紧凑（≤56dp，compact 生效）', (tester) async {
      // 反向钉住：桌面分支的 compact 必须真的在压行高，否则「桌面一屏
      // 更多内容」的意图就丢了（静默退化成与移动端同高也该被拦住）。
      await tester.pumpWidget(
        MaterialApp(
          theme: SpbTheme.lightFor(TargetPlatform.linux),
          home: const Scaffold(body: ListTile(title: Text('行'))),
        ),
      );
      final height = tester.getSize(find.byType(ListTile)).height;
      expect(height, lessThanOrEqualTo(56.0));
      expect(
        height,
        lessThan(56.0),
        reason: 'compact 应比移动端 standard 的 56dp 更矮',
      );
    });
  });

  group('SpbTheme 构建', () {
    test('light() 不抛且 brightness 正确', () {
      // 主题在 `main()` 里构建一次，抛了就是白屏启动失败。
      final theme = SpbTheme.light();
      expect(theme.brightness, Brightness.light);
      expect(theme.colorScheme.brightness, Brightness.light);
      expect(theme.useMaterial3, isTrue);
    });

    test('dark() 不抛且 brightness 正确', () {
      final theme = SpbTheme.dark();
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.useMaterial3, isTrue);
    });

    test('明暗两套的 surface 色确实不同（不是同一份主题）', () {
      // 若 dark() 误实现为 `_build(Brightness.light)`，brightness 断言会挂；
      // 若 `_build` 忽略了 brightness 参数，这条会挂。
      final light = SpbTheme.light();
      final dark = SpbTheme.dark();
      expect(light.colorScheme.surface, isNot(dark.colorScheme.surface));
      expect(light.colorScheme.onSurface, isNot(dark.colorScheme.onSurface));
    });

    test('令牌已落到主题里（AppBar / Card / 输入框 / 分隔线）', () {
      // 文档说「视觉一致性靠设计令牌而非精确色值对齐」。若有人改主题时
      // 把令牌换成硬编码值，这些断言会挂——那正是要拦住的漂移。
      final theme = SpbTheme.light();

      expect(theme.appBarTheme.centerTitle, isFalse);
      expect(theme.appBarTheme.elevation, 0);

      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(
        (theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
        SpbRadius.cardAll,
      );

      expect(
        theme.inputDecorationTheme.contentPadding,
        const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
      );

      expect(theme.dividerTheme.space, 1);
      expect(theme.dividerTheme.thickness, 1);
    });

    test('两次调用返回等价主题（无隐藏可变状态）', () {
      // `_build` 每次新建 ThemeData。若将来改成缓存单例并原地修改，
      // 会出现「主题被别处改动后影响所有人」。断言关键字段相等即可。
      final a = SpbTheme.light();
      final b = SpbTheme.light();
      expect(a.colorScheme.primary, b.colorScheme.primary);
      expect(a.brightness, b.brightness);
    });
  });

  group('SpbType 令牌', () {
    // ## 为什么要有下界
    //
    // 列表页文字偏小曾是真实缺陷（2026-11）：元数据全用 labelSmall（11px）、
    // 角标硬编码 10px。中文字形笔画密度高，11px 以下可读性急剧衰减。
    // 本组断言钉住「语义令牌不小于可读下界」，防止后续又悄悄滑回去。
    // 想改字号请改 SpbType 本身（一处生效全局），并同步更新这里的下界。
    const minReadable = 12.0;

    // ⚠️ 裸 `ThemeData().textTheme` 的各样式 **fontSize 为 null**：几何信息
    // （字号/字重）由 `Theme.of` 在运行时经 `ThemeData.localize` 按
    // scriptCategory 合并 `englishLike2021` 才得出（见 material/theme.dart）。
    // 生产页面全部经 `Theme.of(context)` 取 textTheme，故这里也走同一条
    // localize 路径，断言的才是真实渲染值。
    TextTheme resolve() {
      final theme = SpbTheme.light();
      return ThemeData.localize(
        theme,
        theme.typography.geometryThemeFor(ScriptCategory.englishLike),
      ).textTheme;
    }

    test('listMeta 不小于可读下界（列表元数据必须能读懂）', () {
      final style = SpbType.listMeta(resolve());
      expect(style, isNotNull);
      expect(style!.fontSize, greaterThanOrEqualTo(minReadable));
    });

    test('badge 不小于可读下界（徽标是状态词，不是装饰）', () {
      final style = SpbType.badge(resolve());
      expect(style, isNotNull);
      expect(style!.fontSize, greaterThanOrEqualTo(minReadable));
    });

    test('badgeCount 与可读下界同字号（11 不再是例外，§6.81）', () {
      final style = SpbType.badgeCount(resolve());
      expect(style, isNotNull);
      // `labelSmall` 默认 11（Flutter Badge 的口径），但本仓把它抬到 12：
      // 角标数字是**最需要被看见**的字，不该是全仓唯一低于下界的字号。
      expect(style!.fontSize, greaterThanOrEqualTo(minReadable));
      expect(style.fontSize, SpbType.metaSize);
      // letterSpacing 归零是 badgeCount 的本职（数字不需要拉丁小标签的
      // 0.5 间距，间距只会让多位数字更散）。
      expect(style.letterSpacing, 0);
    });

    test('body 不小于可读下界（正文是长文本，不能比元数据还小）', () {
      final style = SpbType.body(resolve());
      expect(style, isNotNull);
      expect(style!.fontSize, greaterThanOrEqualTo(minReadable));
    });

    test('cardTitle 不小于可读下界（块标题要压得住正文）', () {
      final style = SpbType.cardTitle(resolve());
      expect(style, isNotNull);
      expect(style!.fontSize, greaterThanOrEqualTo(minReadable));
    });

    test('移动端正文 15 / 桌面端 14，层次仍然成立（§6.82）', () {
      // `lightFor(platform)` 就是为了「按平台取真实几何」而存在（§6.77）。
      TextTheme localized(TargetPlatform platform) {
        final theme = SpbTheme.lightFor(platform);
        return ThemeData.localize(
          theme,
          theme.typography.geometryThemeFor(ScriptCategory.englishLike),
        ).textTheme;
      }

      final android = localized(TargetPlatform.android);
      final linux = localized(TargetPlatform.linux);

      expect(SpbType.body(android)?.fontSize, 15.0);
      expect(SpbType.body(linux)?.fontSize, 14.0);
      // 块标题两端都是 16：移动端正文 15 仍低于它，层次没被打破。
      expect(SpbType.cardTitle(android)?.fontSize, 16.0);
      expect(SpbType.cardTitle(linux)?.fontSize, 16.0);
      // 元数据（12）必须仍然低于移动端正文（15），否则令牌表失效。
      expect(SpbType.listMeta(android)?.fontSize, 12.0);
      expect(
        SpbType.listMeta(android)!.fontSize,
        lessThan(SpbType.body(android)!.fontSize!),
      );
    });

    test('mono 自带 CJK 回退链（等宽字体四个平台都不含中文，§6.81）', () {
      final style = SpbType.mono(resolve());
      expect(style, isNotNull);
      expect(style!.fontFamily, 'monospace');
      // 只写 `fontFamily` 时工具入参里的中文只能靠引擎隐式回退，字形不可控。
      // 令牌把两件事绑在一起，这条断言就是绑死的依据。
      expect(style.fontFamilyFallback, SpbFonts.monoFallback);
      expect(style.fontSize, greaterThanOrEqualTo(minReadable));
    });

    test('mono 的 base 可替换（工具卡标题要比入参正文大一档）', () {
      final t = resolve();
      final style = SpbType.mono(t, base: t.labelLarge);
      expect(style, isNotNull);
      expect(style!.fontFamily, 'monospace');
      expect(style.fontSize, t.labelLarge!.fontSize);
    });

    // ## 为什么钉「顺序」而不是每个绝对值
    //
    // 绝对值会随主题调整合理漂移（§6.78 之后还要做 CJK 行高/字距校正）。
    // 真正不能错的是一条**层次关系**：元数据 < 正文 < 块标题。顺序反了
    // 意味着「卡片标题比元数据还小」这种主次颠倒，而那正是 §6.76 缺陷的形态。
    test('层次顺序：listMeta ≤ badge < body < cardTitle', () {
      final t = resolve();
      final meta = SpbType.listMeta(t)!.fontSize!;
      final badge = SpbType.badge(t)!.fontSize!;
      final body = SpbType.body(t)!.fontSize!;
      final cardTitle = SpbType.cardTitle(t)!.fontSize!;
      expect(meta, lessThanOrEqualTo(badge), reason: '元数据与徽标同档，靠字重区分');
      expect(badge, lessThan(body), reason: '徽标不该比正文还大');
      expect(body, lessThan(cardTitle), reason: '块标题必须压得住正文');
    });

    test('metaSize 与 listMeta 同字号（绘制场景与主题槽位不许漂移）', () {
      // `SpbType.metaSize` 是给 `TextPainter`（Canvas 绘制）用的字面值，
      // 它们与 `listMeta` 是同一语义的两种形态。若有人只改了一边，
      // 地图画布上的标签会与列表里的元数据差一个像素——那种漂移没人看得出来，
      // 只能靠断言拦住。
      expect(SpbType.metaSize, SpbType.listMeta(resolve())!.fontSize);
    });
  });

  group('CJK 度量校正（§6.79）', () {
    // ## 它防的是什么
    //
    // M3 的字距/行高是**拉丁文**的度量：`bodySmall` 的 `letterSpacing: 0.4`
    // （为 12px 拉丁小标签设计）在中文密排正文里是 3% 的额外字距，12px 只给
    // 16px 行高（1.33）对中文笔画密度也偏挤。校正写在 `Typography` 层，故
    // `Theme.of` 合并出来的才是 CJK 值——这里断言的必须是**同一条 localize
    // 路径**的结果，而不是构造期的 `ThemeData.textTheme`（那里面 fontSize 为
    // null，见 §6.76 根因链）。
    TextTheme resolve() {
      final theme = SpbTheme.light();
      return ThemeData.localize(
        theme,
        theme.typography.geometryThemeFor(ScriptCategory.englishLike),
      ).textTheme;
    }

    // SDK 原始几何（未校正）：用来证明「该改的改了、不该改的没碰」。
    TextTheme pristine() =>
        Typography.material2021(platform: TargetPlatform.android).englishLike;

    test('五个语义令牌一律零字距（中文不需要补 tracking）', () {
      final t = resolve();
      for (final style in [
        SpbType.listMeta(t),
        SpbType.badge(t),
        SpbType.badgeCount(t),
        SpbType.body(t),
        SpbType.cardTitle(t),
      ]) {
        expect(style, isNotNull);
        expect(style!.letterSpacing, 0);
      }
    });

    test('正文（10–16px 档）行高 ≥1.5×字号（中文需要更多行间留白）', () {
      final t = resolve();
      for (final style in [
        t.bodySmall,
        t.bodyMedium,
        t.labelMedium,
        t.titleSmall,
      ]) {
        expect(style, isNotNull);
        expect(
          style!.height! * style.fontSize!,
          greaterThanOrEqualTo(1.5 * style.fontSize!),
          reason: '${style.fontSize}px 的行高不足 1.5×',
        );
      }
    });

    test('labelSmall 一字未改（Flutter 组件内部槽位，外溢风险不可控）', () {
      // §6.76 的结论：`Badge` 等组件直接吃 `labelSmall`，改槽位会外溢到
      // 没审计过的组件。这条断言把「有意不改」变成机器可查的。
      final theme = resolve();
      final base = pristine();
      final adjusted = theme.labelSmall!;
      final original = base.labelSmall!;
      expect(adjusted.fontSize, original.fontSize);
      expect(adjusted.letterSpacing, original.letterSpacing);
      expect(adjusted.height, original.height);
    });

    test('dense / tall 两套几何同样被校正（中文 locale 落 dense）', () {
      // scriptCategory 由 locale 决定：英文落 englishLike，中文落 dense。
      // 只改 englishLike 等于「测试环境绿、真机无效」。
      final typography = SpbTheme.light().typography;
      for (final geometry in [typography.dense, typography.tall]) {
        expect(geometry.bodySmall?.letterSpacing, 0);
        expect(geometry.bodyMedium?.letterSpacing, 0);
        expect(geometry.bodySmall?.height, greaterThanOrEqualTo(1.5));
      }
    });
  });

  group('SpbThemeMode 编解码（跨端持久化契约）', () {
    test('prefKey 固定（改它会让老用户的设置静默丢失）', () {
      // 这个键是持久化契约：已发布的客户端把它写进了本地存储。
      // 改键 = 老用户升级后设置被重置，且没有任何提示。
      expect(SpbThemeMode.prefKey, 'ui.theme_mode');
    });

    test('encode / decode 往返一致（全部取值）', () {
      for (final m in SpbThemeMode.all) {
        final encoded = SpbThemeMode.encode(m);
        expect(SpbThemeMode.decode(encoded), m, reason: '往返丢失：$m');
      }
    });

    test('encode 输出稳定的字符串（不是 index 或 toString）', () {
      // 用 `index` 或 `enum.toString()` 编码会在枚举顺序变化时让已存的
      // 设置失效（甚至解成另一个模式）。故断言字面值。
      // 注意用的是 Flutter 的 ThemeMode，其 `.name` 恰好是这三个字面值。
      expect(SpbThemeMode.encode(ThemeMode.system), 'system');
      expect(SpbThemeMode.encode(ThemeMode.light), 'light');
      expect(SpbThemeMode.encode(ThemeMode.dark), 'dark');
    });

    test('decode 对未知 / null 输入退回 system（不抛）', () {
      // 老版本客户端写入的值、或被手工改坏的值，都不能让启动崩。
      expect(SpbThemeMode.decode(null), ThemeMode.system);
      expect(SpbThemeMode.decode(''), ThemeMode.system);
      expect(SpbThemeMode.decode('nonsense'), ThemeMode.system);
      expect(SpbThemeMode.decode('System'), ThemeMode.system, reason: '大小写敏感');
      expect(SpbThemeMode.decode('DARK'), ThemeMode.system, reason: '大小写敏感');
    });

    test('all 覆盖三个取值且不含重复', () {
      expect(SpbThemeMode.all, hasLength(3));
      expect(SpbThemeMode.all.toSet(), hasLength(3));
      expect(
        SpbThemeMode.all,
        containsAll([ThemeMode.system, ThemeMode.light, ThemeMode.dark]),
      );
      // 顺序即 UI 展示顺序：系统在前（默认值应最靠前）。
      expect(SpbThemeMode.all.first, ThemeMode.system);
    });

    test('label 非空（设置页直接展示它）', () {
      for (final m in SpbThemeMode.all) {
        expect(SpbThemeMode.label(m), isNotEmpty);
      }
      expect(SpbThemeMode.label(ThemeMode.system), '跟随系统');
      expect(SpbThemeMode.label(ThemeMode.light), '浅色');
      expect(SpbThemeMode.label(ThemeMode.dark), '深色');
    });

    test('decode(encode(m)) 对所有 ThemeMode 取值封闭', () {
      // 穷举 Flutter 的全部 ThemeMode，而不是只看 SpbThemeMode.all——
      // 若 Flutter 将来新增一个模式，这条会挂，提醒补编码（否则新模式的
      // 用户设置会被静默解成 system）。
      for (final m in ThemeMode.values) {
        expect(SpbThemeMode.decode(SpbThemeMode.encode(m)), m);
      }
    });
  });
}
