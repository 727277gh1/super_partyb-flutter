import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// 静态看板图表共用原生 Canvas，桌面悬停和移动点击均可查看数据。
class SpecChart extends StatefulWidget {
  const SpecChart({super.key, required this.element, required this.state});
  final SpecUiElement element;
  final Map<String, Object?> state;

  @override
  State<SpecChart> createState() => _SpecChartState();
}

class _SpecChartState extends State<SpecChart> {
  late SpecChartData _data;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _readData();
  }

  @override
  void didUpdateWidget(SpecChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.element, widget.element) ||
        !identical(oldWidget.state, widget.state)) {
      _readData();
    }
  }

  void _readData() {
    _data = SpecChartData.fromProps(widget.element.props, state: widget.state);
    _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final element = widget.element;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = element.prop('title').isNotEmpty
        ? element.prop('title')
        : element.prop('label');
    final palette = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      scheme.error,
      scheme.primaryContainer,
      scheme.tertiaryContainer,
    ];
    final colors = [
      for (var i = 0; i < _data.series.length; i++)
        _seriesColor(_data.series[i].color) ?? palette[i % palette.length],
    ];
    final height = (element.propNum('height') ?? 280)
        .clamp(160, 600)
        .toDouble();
    final pie = _data.type == SpecChartType.pie;
    return Container(
      padding: const EdgeInsets.all(SpbSpacing.sm),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(SpbRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Text(title, style: SpbType.cardTitle(theme.textTheme)),
          if (_data.type == SpecChartType.unknown)
            Text('暂不支持的图表类型：${element.prop('chartType')}')
          else if (!_data.hasData)
            const Text('暂无有效图表数据')
          else ...[
            if (element.props['legend'] != false &&
                _data.type != SpecChartType.candlestick)
              Wrap(
                spacing: SpbSpacing.md,
                runSpacing: SpbSpacing.xs,
                children: [
                  for (
                    var i = 0;
                    i < (pie ? _data.rows.length : _data.series.length);
                    i++
                  )
                    if (!pie || _data.pieValueAt(i) > 0)
                      Text(
                        pie
                            ? '${_data.labelAt(i)} · ${_number(_data.pieValueAt(i))}'
                            : _data.series[i].name,
                        style: SpbType.listMeta(theme.textTheme)?.copyWith(
                          color: pie ? palette[i % palette.length] : colors[i],
                        ),
                      ),
                ],
              ),
            SizedBox(
              height: height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(constraints.maxWidth, height);
                  final painter = SpecChartPainter(
                    data: _data,
                    colors: colors,
                    palette: palette,
                    foreground: scheme.onSurface,
                    gridColor: scheme.outlineVariant,
                    showGrid: element.props['grid'] != false,
                    textStyle:
                        SpbType.listMeta(theme.textTheme) ?? const TextStyle(),
                    textScaler: MediaQuery.textScalerOf(context),
                    selected: _selected,
                  );
                  void select(Offset offset) {
                    final next = painter.indexAt(offset, size);
                    if (next != _selected) setState(() => _selected = next);
                  }

                  return Semantics(
                    label:
                        '${title.isEmpty ? '图表' : title}，${_data.rows.length} 条数据，可点击查看数值',
                    child: MouseRegion(
                      onHover: (event) => select(event.localPosition),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (event) => select(event.localPosition),
                        child: CustomPaint(
                          key: ValueKey('spec-chart-${element.id}'),
                          size: size,
                          painter: painter,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_selected case final int index)
              Text(
                _detail(index),
                key: ValueKey('spec-chart-detail-${element.id}'),
                style: theme.textTheme.bodySmall,
              ),
          ],
        ],
      ),
    );
  }

  String _detail(int index) {
    final candle = _data.type == SpecChartType.candlestick
        ? _data.candleAt(index)
        : null;
    final values = candle != null
        ? '开 ${_number(candle.open)} · 收 ${_number(candle.close)} · 低 ${_number(candle.low)} · 高 ${_number(candle.high)}'
        : _data.series
              .map(
                (s) =>
                    '${s.name} ${_data.valueAt(index, s) == null ? '—' : _number(_data.valueAt(index, s)!)}',
              )
              .join(' · ');
    return '${_data.labelAt(index)} · $values';
  }
}

Color? _seriesColor(String raw) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(raw)) return null;
  return Color(0xff000000 | int.parse(raw.substring(1), radix: 16));
}

String _number(double value) {
  if (value.abs() >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

/// 投影与命中检测共用范围，点击的数据点不会与绘制位置错位。
class SpecChartPainter extends CustomPainter {
  SpecChartPainter({
    required this.data,
    required this.colors,
    required this.palette,
    required this.foreground,
    required this.gridColor,
    required this.showGrid,
    required this.textStyle,
    required this.textScaler,
    this.selected,
  });

  final SpecChartData data;
  final List<Color> colors;
  final List<Color> palette;
  final Color foreground;
  final Color gridColor;
  final bool showGrid;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final int? selected;

  Rect _plot(Size size) => Rect.fromLTRB(
    math.min(62, size.width * 0.25),
    16,
    math.max(1, size.width - 16),
    math.max(20, size.height - 40),
  );

  double _x(int i, Rect plot, bool numericX, (double, double) range) {
    if (numericX) {
      return plot.left +
          (specChartNumber(data.rows[i][data.xKey])! - range.$1) /
              (range.$2 - range.$1) *
              plot.width;
    }
    return plot.left + (i + 0.5) / data.rows.length * plot.width;
  }

  int? indexAt(Offset offset, Size size) {
    if (data.rows.isEmpty) return null;
    if (data.type == SpecChartType.pie) {
      final center = Offset(size.width / 2, size.height / 2);
      final delta = offset - center;
      if (delta.distance > math.min(size.width, size.height) * 0.42 ||
          data.pieTotal <= 0) {
        return null;
      }
      final angle =
          (math.atan2(delta.dy, delta.dx) + math.pi / 2) % (math.pi * 2);
      var accumulated = 0.0;
      final total = data.pieTotal;
      for (var i = 0; i < data.rows.length; i++) {
        accumulated += data.pieValueAt(i) / total * math.pi * 2;
        if (angle < accumulated) return i;
      }
      return null;
    }
    final plot = _plot(size);
    if (!plot.contains(offset)) return null;
    final numericX = data.hasNumericX;
    final range = data.xRange;
    var nearest = 0;
    var distance = double.infinity;
    for (var i = 0; i < data.rows.length; i++) {
      final next = (_x(i, plot, numericX, range) - offset.dx).abs();
      if (next < distance) {
        nearest = i;
        distance = next;
      }
    }
    return nearest;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!data.hasData || size.width <= 0 || size.height <= 0) return;
    if (data.type == SpecChartType.pie) {
      final radius = math.min(size.width, size.height) * 0.42;
      final center = Offset(size.width / 2, size.height / 2);
      final total = data.pieTotal;
      var start = -math.pi / 2;
      for (var i = 0; i < data.rows.length; i++) {
        final sweep = data.pieValueAt(i) / total * math.pi * 2;
        if (sweep <= 0) continue;
        final rect = Rect.fromCircle(center: center, radius: radius);
        canvas.drawArc(
          rect,
          start,
          sweep,
          true,
          Paint()..color = palette[i % palette.length],
        );
        if (selected == i) {
          canvas.drawArc(
            rect,
            start,
            sweep,
            true,
            Paint()
              ..color = foreground
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3,
          );
        }
        start += sweep;
      }
      return;
    }
    final plot = _plot(size);
    final range = data.yRange;
    final numericX = data.hasNumericX;
    final xRange = data.xRange;
    double y(double value) =>
        plot.bottom - (value - range.$1) / (range.$2 - range.$1) * plot.height;
    double x(int index) => _x(index, plot, numericX, xRange);
    final axisPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final value = range.$1 + (range.$2 - range.$1) * i / 4;
      final dy = y(value);
      if (showGrid) {
        canvas.drawLine(
          Offset(plot.left, dy),
          Offset(plot.right, dy),
          axisPaint,
        );
      }
      _text(
        canvas,
        _number(value),
        Offset(0, dy - 8),
        plot.left - 5,
        TextAlign.right,
      );
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axisPaint);
    final tickCount = math.max(
      1,
      math.min(data.rows.length, (plot.width / 80).floor()),
    );
    for (var tick = 0; tick < tickCount; tick++) {
      final i = tickCount == 1
          ? 0
          : (tick * (data.rows.length - 1) / (tickCount - 1)).round();
      _text(
        canvas,
        data.labelAt(i),
        Offset(
          (x(i) - 36).clamp(0, math.max(0, size.width - 72)),
          plot.bottom + 6,
        ),
        math.min(72, size.width),
        TextAlign.center,
      );
    }
    canvas.save();
    canvas.clipRect(plot.inflate(2));
    if (data.type == SpecChartType.candlestick) {
      for (var i = 0; i < data.rows.length; i++) {
        final candle = data.candleAt(i);
        if (candle == null) continue;
        final paint = Paint()
          ..color = candle.close >= candle.open ? palette[0] : palette[3]
          ..strokeWidth = 1.5;
        canvas.drawLine(
          Offset(x(i), y(candle.high)),
          Offset(x(i), y(candle.low)),
          paint,
        );
        final width = math.min(24.0, plot.width / data.rows.length * 0.6);
        final top = math.min(y(candle.open), y(candle.close));
        final height = math.max(1.5, (y(candle.close) - y(candle.open)).abs());
        canvas.drawRect(
          Rect.fromLTWH(x(i) - width / 2, top, width, height),
          paint,
        );
      }
    } else {
      for (var s = 0; s < data.series.length; s++) {
        final paint = Paint()
          ..color = colors[s]
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        final segment = <Offset>[];
        void flush() {
          if (segment.isEmpty) return;
          final path = Path()..moveTo(segment.first.dx, segment.first.dy);
          for (final point in segment.skip(1)) {
            path.lineTo(point.dx, point.dy);
          }
          if (data.type == SpecChartType.area) {
            final fill = Path.from(path)
              ..lineTo(segment.last.dx, y(0))
              ..lineTo(segment.first.dx, y(0))
              ..close();
            canvas.drawPath(
              fill,
              Paint()..color = colors[s].withValues(alpha: 0.18),
            );
          }
          canvas.drawPath(path, paint);
          if (data.rows.length <= 100) {
            for (final point in segment) {
              canvas.drawCircle(point, 2.5, Paint()..color = colors[s]);
            }
          }
          segment.clear();
        }

        for (var i = 0; i < data.rows.length; i++) {
          final value = data.valueAt(i, data.series[s]);
          if (value == null) {
            flush();
            continue;
          }
          final point = Offset(x(i), y(value));
          if (data.type == SpecChartType.bar) {
            final groupWidth = plot.width / data.rows.length * 0.75;
            final width = groupWidth / data.series.length;
            canvas.drawRect(
              Rect.fromLTRB(
                x(i) - groupWidth / 2 + s * width,
                math.min(y(0), point.dy),
                x(i) -
                    groupWidth / 2 +
                    (s + 1) * width -
                    math.min(1, width * 0.1),
                math.max(y(0), point.dy),
              ),
              Paint()..color = colors[s],
            );
          } else if (data.type == SpecChartType.scatter) {
            canvas.drawCircle(point, 3.5, Paint()..color = colors[s]);
          } else {
            segment.add(point);
          }
        }
        flush();
      }
    }
    if (selected case final int i) {
      canvas.drawLine(
        Offset(x(i), plot.top),
        Offset(x(i), plot.bottom),
        Paint()..color = foreground.withValues(alpha: 0.5),
      );
    }
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String value,
    Offset offset,
    double width,
    TextAlign align,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: textStyle.copyWith(color: foreground),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      textScaler: textScaler,
      maxLines: 1,
      ellipsis: '…',
    )..layout(minWidth: width, maxWidth: width);
    painter.paint(canvas, offset);
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant SpecChartPainter oldDelegate) =>
      !identical(data, oldDelegate.data) ||
      selected != oldDelegate.selected ||
      foreground != oldDelegate.foreground ||
      gridColor != oldDelegate.gridColor ||
      showGrid != oldDelegate.showGrid ||
      textStyle != oldDelegate.textStyle ||
      textScaler != oldDelegate.textScaler ||
      !listEquals(colors, oldDelegate.colors) ||
      !listEquals(palette, oldDelegate.palette);
}
