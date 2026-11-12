import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 用可换行布局承载变高的报告卡片，窄屏不固定卡片高度。
class SpecLayout extends StatelessWidget {
  const SpecLayout({super.key, required this.element, required this.children});
  final SpecUiElement element;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = specLayoutGap(
      element.props['gap'] ??
          element.props['gutter'] ??
          element.props['spacing'],
    );
    final horizontal =
        element.type == SpecUiType.row ||
        (element.type == SpecUiType.stack &&
            element.prop('direction') == 'horizontal');
    if (element.type != SpecUiType.grid && !horizontal) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: switch (element.prop('align')) {
          'start' => CrossAxisAlignment.start,
          'center' => CrossAxisAlignment.center,
          'end' => CrossAxisAlignment.end,
          _ => CrossAxisAlignment.stretch,
        },
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: gap),
            children[i],
          ],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final requested = element.type == SpecUiType.grid
            ? (element.propNum('columns') ?? 2).clamp(1, 12).toInt()
            : math.max(1, children.length);
        // 放大字体时同步降低列数，避免移动端指标和标题互相挤压。
        final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final fitting = math.max(
          1,
          ((width + gap) / (160 * scale + gap)).floor(),
        );
        final columns = math.min(requested, fitting);
        final cellWidth = math.max(
          0.0,
          (width - gap * (columns - 1)) / columns,
        );
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          alignment: switch (element.prop('justify')) {
            'center' => WrapAlignment.center,
            'end' => WrapAlignment.end,
            'between' => WrapAlignment.spaceBetween,
            _ => WrapAlignment.start,
          },
          crossAxisAlignment: switch (element.prop('align')) {
            'center' => WrapCrossAlignment.center,
            'end' => WrapCrossAlignment.end,
            _ => WrapCrossAlignment.start,
          },
          children: [
            for (final child in children)
              SizedBox(width: cellWidth, child: child),
          ],
        );
      },
    );
  }
}

double specLayoutGap(Object? value) {
  if (value is num && value.isFinite) return value.toDouble().clamp(0, 64);
  return switch (value) {
    'xs' => SpbSpacing.xs,
    'sm' => SpbSpacing.sm,
    'lg' => SpbSpacing.lg,
    'xl' => SpbSpacing.xl,
    _ => SpbSpacing.md,
  };
}
