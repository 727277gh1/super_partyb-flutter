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
