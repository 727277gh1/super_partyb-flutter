import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_design/spb_design.dart';

import 'support/contrast.dart';

/// 文字角色 / 实际背景的**对比度**断言（issue #127）。
///
/// ## 为什么单独一份，而不是塞进 `tokens_test.dart`
///
/// `tokens_test.dart` 钉的是**字号**（下界与相对顺序）。字号合格不代表读得清：
/// 12px 的 `outline` 压在 `surface` 上是 4.27:1，卡在 WCAG AA 的 4.5 之下——
/// 这是**颜色**问题，且任何现有测试都不会红（golden 只比像素、不设阈值）。
///
/// ## 为什么「角色表」不能单独承担回归保护
///
/// 这张表只证明**令牌组合**安全。组件若把文字色改回 `outline`、或给小字叠上
/// `alpha: 0.7`，表里全是合法角色、测试仍然全绿。所以真实使用点的样式断言
/// 住在各组件自己的测试里（`pending_confirmations_page_test.dart`、
/// `workspace_sync_reviews_section_test.dart`、`habit_suggestion_card_test.dart`、
/// `contract_drift_rows_test.dart`）：移除实际修复后那边必须变红。
///
/// ## 半透明为什么必须合成后再比
///
/// `onSecondaryContainer` 对 `secondaryContainer` 是 7.20:1（合格），
/// 叠上 `alpha: 0.8` 后实际渲染只有 4.45:1（不合格）。名义颜色骗人，
/// 合成后的颜色才是用户看到的。
void main() {
  /// 本仓文字会用到的**背景**角色（页面底 / 卡片底 / 容器底）。
  Map<String, Color> backgrounds(ColorScheme s) => {
    'surface': s.surface,
    'surfaceContainerLow': s.surfaceContainerLow,
    'surfaceContainer': s.surfaceContainer,
    'secondaryContainer': s.secondaryContainer,
    'errorContainer': s.errorContainer,
    'primaryContainer': s.primaryContainer,
  };

  /// **可用**的文字角色：与上表任一背景组合都必须 ≥ 4.5。
  ///
  /// ⚠️ 不要把 `outline` / `outlineVariant` 加进来：它们是 M3 的**边框**角色，
  /// 浅色主题下对 surface 只有 4.27:1 / 更差。下面有一条断言专门钉住这件事。
  Map<String, Color> textRoles(ColorScheme s) => {
    'onSurface': s.onSurface,
    'onSurfaceVariant': s.onSurfaceVariant,
    'onSecondaryContainer': s.onSecondaryContainer,
    'onErrorContainer': s.onErrorContainer,
    'onPrimaryContainer': s.onPrimaryContainer,
    // 强调色在本仓确实当文字用（链接、状态词），实测均 ≥ 4.99。
    'primary': s.primary,
    'secondary': s.secondary,
    'error': s.error,
    'tertiary': s.tertiary,
  };

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final scheme =
        (brightness == Brightness.light ? SpbTheme.light() : SpbTheme.dark())
            .colorScheme;

    group('${brightness.name} 主题', () {
      test('文字角色 × 实际背景都达到 AA 4.5', () {
        for (final role in textRoles(scheme).entries) {
          for (final bg in backgrounds(scheme).entries) {
            final ratio = contrastRatio(role.value, bg.value);
            expect(
              ratio,
              greaterThanOrEqualTo(wcagAAForNormalText),
              reason:
                  '${role.key} / ${bg.key} = ${ratio.toStringAsFixed(2)}'
                  '，低于 AA 下界 $wcagAAForNormalText（12px 小字读不清）',
            );
          }
        }
      });

      test('outline / outlineVariant 不得当文字色（它们是 M3 的边框角色）', () {
        // M3 把 `outline` 定义为**边框**角色。它在浅色主题对 surface 只有
        // 4.27:1，在深色主题对 secondaryContainer 只有 2.94:1——两个主题各自
        // 踩在一处真实背景上。#127 的两处就是把 outline 当成「淡一点的文字色」
        // 顺手用掉了，而那种用法不会让任何测试变红。
        final outline = contrastRatio(scheme.outline, scheme.surface);
        final outlineOnContainer = contrastRatio(
          scheme.outline,
          scheme.secondaryContainer,
        );
        if (brightness == Brightness.light) {
          expect(
            outline,
            lessThan(wcagAAForNormalText),
            reason:
                'outline/surface 实测 ${outline.toStringAsFixed(2)}，'
                '本条断言的意义就是拦住它被当文字色',
          );
        } else {
          expect(
            outlineOnContainer,
            lessThan(wcagAAForNormalText),
            reason:
                'outline/secondaryContainer 实测 ${outlineOnContainer.toStringAsFixed(2)}',
          );
        }
        // 无论哪个主题，outline 都比同位置的合法文字角色暗一截：没有理由选它。
        expect(
          contrastRatio(scheme.outlineVariant, scheme.surface),
          lessThan(outline),
        );
        expect(
          outline,
          lessThan(contrastRatio(scheme.onSurfaceVariant, scheme.surface)),
        );
      });

      test('小字叠加透明度只会更差：0.8 在浅色主题跌破 AA（§6.78 规则 3）', () {
        final bg = scheme.secondaryContainer;
        final plain = contrastRatio(scheme.onSecondaryContainer, bg);
        final a8 = contrastRatio(
          scheme.onSecondaryContainer.withValues(alpha: 0.8),
          bg,
        );
        final a7 = contrastRatio(
          scheme.onSecondaryContainer.withValues(alpha: 0.7),
          bg,
        );

        expect(plain, greaterThanOrEqualTo(wcagAAForNormalText));
        expect(a8, lessThanOrEqualTo(plain), reason: '叠加透明度不可能提高对比度');
        expect(a7, lessThan(a8));
        if (brightness == Brightness.light) {
          // 浅色是本仓的默认主题，也是 #127 实测不合格的那一端。
          expect(a8, lessThan(wcagAAForNormalText));
          expect(a7, lessThan(wcagAAForNormalText));
        }
      });
    });
  }

  test('主题种子色未换（换 seed 会整体移动这些比值）', () {
    // 上面几组断言全部建立在 `ColorScheme.fromSeed(0xFF5B6ABF)` 之上。
    // 换种子色是有意的设计变更，但必须重跑本文件确认没有角色跌破 AA——
    // 这条断言的作用就是「逼人来重跑」，而不是把色值钉死。
    final scheme = SpbTheme.light().colorScheme;
    expect(
      contrastRatio(scheme.onSurfaceVariant, scheme.surface).toStringAsFixed(1),
      '8.9',
      reason: '基线漂移提示：本文件的其余阈值都依赖这套色值',
    );
  });
}
