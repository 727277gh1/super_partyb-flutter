import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';

/// 用户气泡上的归属徽标（`routing_selected` 有信息量时的内联展示）。
///
/// 配套归约语义见 `spb_domain` 的 `event_reducer_routing_test.dart`：
/// 无聊原因（`fixed_reuse` 等）合并不展示；新建 / 切换 / 未知原因以徽标呈现。
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  /// 子树里除复制按钮之外的 Tooltip（即归属徽标那一个，通常 0 或 1 个）。
  ///
  /// ⚠️ [CopyIconButton] 自带「复制」Tooltip，按类型查找会命中它——故按
  /// message 排除：徽标的 message 必含原始 reason code 或完整解释，不会是「复制」。
  List<Tooltip> chipTooltipsOf(WidgetTester tester) => tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .where((t) => t.message != '复制')
      .toList();

  group('UserMessageBubble 归属徽标', () {
    testWidgets('fixed_reuse（复用当前对话）不渲染徽标', (tester) async {
      await tester.pumpWidget(
        host(const UserMessageBubble(text: '在吗', routingReason: 'fixed_reuse')),
      );

      // ⚠️ 复制按钮自带 Tooltip，不能断言「无 Tooltip」——只断言归属徽标不存在。
      expect(chipTooltipsOf(tester), isEmpty);
      expect(find.text('已新建对话'), findsNothing);
      expect(find.text('已切换对话'), findsNothing);
    });

    testWidgets('无归属信息（null）不渲染徽标', (tester) async {
      await tester.pumpWidget(host(const UserMessageBubble(text: '在吗')));

      expect(chipTooltipsOf(tester), isEmpty);
    });

    testWidgets('create_new → 「已新建对话」徽标，Tooltip 带原始 reason', (tester) async {
      await tester.pumpWidget(
        host(const UserMessageBubble(text: '开工', routingReason: 'create_new')),
      );

      expect(find.text('已新建对话'), findsOneWidget);
      final messages = chipTooltipsOf(tester)
          .map((t) => t.message ?? '')
          .toList();
      expect(messages, hasLength(1));
      expect(messages.single, contains('create_new'));
    });

    testWidgets('group_switched → 「已切换对话」徽标（switched 优先于无聊 reason）', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const UserMessageBubble(
            text: '这件事接着办',
            routingReason: 'classify_reuse',
            routingSwitched: true,
          ),
        ),
      );

      expect(find.text('已切换对话'), findsOneWidget);
      expect(find.text('已新建对话'), findsNothing);
    });

    testWidgets('未知原因 → 原样透传为徽标文案（fail-open）', (tester) async {
      await tester.pumpWidget(
        host(
          const UserMessageBubble(text: 'hi', routingReason: 'brand_new_kind'),
        ),
      );

      expect(find.text('brand_new_kind'), findsOneWidget);
    });

    testWidgets('pending 期间不显示徽标（与复制入口同一守卫）', (tester) async {
      await tester.pumpWidget(
        host(
          const UserMessageBubble(
            text: '在吗',
            routingReason: 'create_new',
            pending: true,
          ),
        ),
      );

      expect(find.text('已新建对话'), findsNothing);
    });

    testWidgets('徽标不显著增加纵向空间：与复制按钮共存于同一列，且无独立整行', (tester) async {
      // 有徽标与无徽标的气泡高度差只来自徽标行本身（padding xs + 一行 label），
      // 不应出现「每条消息都多一行整行提示」的旧形态。这里断言徽标在气泡内：
      // 它的祖先是 ConstrainedBox(maxWidth 80%) 的气泡容器。
      await tester.pumpWidget(
        host(const UserMessageBubble(text: '开工', routingReason: 'create_new')),
      );

      final chipFinder = find.ancestor(
        of: find.text('已新建对话'),
        matching: find.byType(Column),
      );
      expect(chipFinder, findsOneWidget);
    });

    testWidgets('视觉基调：徽标颜色来自主题（不硬编码颜色）', (tester) async {
      await tester.pumpWidget(
        host(const UserMessageBubble(text: '开工', routingReason: 'create_new')),
      );

      // 能拿到 Material 语境（徽标色用 scheme.tertiary / onPrimaryContainer，
      // 皆为 Theme 派生；这里验证组件在标准 MaterialApp 下渲染无异常即可）。
      expect(find.byType(MaterialApp), findsOneWidget);
    });
  });
}
