import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_ui/spb_ui.dart';

import 'support/golden_fonts.dart';
import 'support/golden_host.dart';

/// `spb_ui` 组件的 golden 测试（issue #25）。
///
/// ## 为什么只给这 4 个组件加（而不是全仓铺开）
///
/// golden 是**维护负担**：每次有意改样式都要 `--update-goldens` 更新基线，
/// 且基线 PNG 占仓库体积。故只给「**稳定 + 纯展示 + 改错代价高**」的组件加：
///
/// | 组件 | 为什么值得锁 |
/// |---|---|
/// | `ErrorBanner` | 错误提示的**可读性**直接决定用户能否看懂出了什么事 |
/// | `ErrorState` | 整页错误 + 重试按钮；按钮位置/尺寸错了用户点不到 |
/// | `EmptyState` | 三个页面共用的空态；图标缺失或文案溢出在这里现形 |
/// | `HintLine` | 三种 `HintKind` 的**颜色语义**（info/warn/error）——改错会误导 |
/// | `SectionTitle` | 间距令牌 `SpbSpacing.sm` 的唯一直观验证点 |
///
/// **不给** `CopyIconButton` 加：它有异步状态（复制中/已复制/复位），
/// 渲染结果依赖计时器，基线会 flaky。它的逻辑已有单测覆盖。
///
/// ## 基线图里的中文是 tofu（空心方块）——这是**预期**
///
/// SDK 不带 CJK 字体（见 `support/golden_fonts.dart` 的说明）。golden 锁的是
/// **布局**：方块与真字形在位置、尺寸、换行点上完全一致。要看懂文案的断言用
/// `spb_ui_test.dart` 里的 `find.text`，两者分工明确。
///
/// ## 更新基线
///
/// ```bash
/// cd packages/spb_ui
/// flutter test --update-goldens test/golden_test.dart
/// ```
///
/// ⚠️ 更新前**先确认 diff 是你有意改的**。基线图放在 `test/goldens/`，
/// 应随代码一起提交并在 PR 里审阅（`git diff --stat` 会显示 PNG 变更）。
void main() {
  setUpAll(loadGoldenFonts);

  group('ErrorBanner golden', () {
    testWidgets('浅色主题', (tester) async {
      await tester.pumpWidget(
        goldenHost(
          const ErrorBanner(message: '会话已失效，请重新登录'),
          size: const Size(400, 120),
        ),
      );

      await expectLater(
        find.byType(ErrorBanner),
        matchesGoldenFile('goldens/error_banner_light.png'),
      );
    });

    testWidgets('深色主题', (tester) async {
      await tester.pumpWidget(
        goldenHostDark(
          const ErrorBanner(message: '会话已失效，请重新登录'),
          size: const Size(400, 120),
        ),
      );

      await expectLater(
        find.byType(ErrorBanner),
        matchesGoldenFile('goldens/error_banner_dark.png'),
      );
    });
  });

  group('ErrorState golden', () {
    testWidgets('带重试按钮', (tester) async {
      await tester.pumpWidget(
        goldenHost(
          ErrorState(message: '加载失败，请稍后重试', onRetry: () {}),
          size: const Size(400, 240),
        ),
      );

      await expectLater(
        find.byType(ErrorState),
        matchesGoldenFile('goldens/error_state_with_retry.png'),
      );
    });

    testWidgets('无重试按钮（不可重试的错误）', (tester) async {
      // 这一对是**承重**的：`onRetry == null` 时不渲染按钮，否则用户会反复
      // 点一个按了也没用的按钮。两张基线的**高度差**就是「按钮真的没了」的
      // 可视化证据（逻辑断言在 spb_ui_test.dart 里）。
      await tester.pumpWidget(
        goldenHost(
          const ErrorState(message: '权限不足'),
          size: const Size(400, 240),
        ),
      );

      await expectLater(
        find.byType(ErrorState),
        matchesGoldenFile('goldens/error_state_no_retry.png'),
      );
    });
  });

  group('EmptyState golden', () {
    testWidgets('带图标', (tester) async {
      await tester.pumpWidget(
        goldenHost(
          const EmptyState(message: '还没有对话', icon: Icons.chat_bubble_outline),
          size: const Size(400, 200),
        ),
      );

      await expectLater(
        find.byType(EmptyState),
        matchesGoldenFile('goldens/empty_state_with_icon.png'),
      );
    });

    testWidgets('无图标（对话页的空提示刻意不带图标）', (tester) async {
      await tester.pumpWidget(
        goldenHost(
          const EmptyState(message: '还没有对话，输入消息开始吧'),
          size: const Size(400, 200),
        ),
      );

      await expectLater(
        find.byType(EmptyState),
        matchesGoldenFile('goldens/empty_state_no_icon.png'),
      );
    });
  });

  group('HintLine golden', () {
    testWidgets('三种语义等级的颜色', (tester) async {
      // 颜色语义是 HintLine 的全部价值所在：info=tertiary、warn=secondary、
      // error=error。改错会让「成功」看起来像「警告」。
      await tester.pumpWidget(
        goldenHost(
          const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HintLine(hint: Hint('已保存', HintKind.info)),
              SizedBox(height: 8),
              HintLine(hint: Hint('部分文件被跳过', HintKind.warn)),
              SizedBox(height: 8),
              HintLine(hint: Hint('上传失败', HintKind.error)),
            ],
          ),
          size: const Size(400, 140),
        ),
      );

      await expectLater(
        find.byType(HintLine).first,
        matchesGoldenFile('goldens/hint_line_kinds.png'),
      );
    });
  });

  group('SectionTitle golden', () {
    testWidgets('间距令牌 SpbSpacing.sm', (tester) async {
      await tester.pumpWidget(
        goldenHost(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [SectionTitle('步骤'), Text('第一项')],
          ),
          size: const Size(400, 120),
        ),
      );

      await expectLater(
        find.byType(SectionTitle),
        matchesGoldenFile('goldens/section_title.png'),
      );
    });
  });
}
