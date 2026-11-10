import 'dart:math' as math;

import 'spec_binding.dart';

enum SpecChartType { line, bar, pie, area, scatter, candlestick, unknown }

double? specChartNumber(Object? value) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return n != null && n.isFinite ? n : null;
}

final class SpecChartSeries {
  const SpecChartSeries({
    required this.key,
    required this.name,
    this.color = '',
  });
  final String key;
  final String name;
  final String color;
}

final class SpecCandle {
  const SpecCandle(this.open, this.close, this.low, this.high);
  final double open;
  final double close;
  final double low;
  final double high;
}

/// 数据适配和数值范围独立于绘图，缺失数据保留为空而非补零。
final class SpecChartData {
  SpecChartData({
    required this.type,
    required this.rows,
    required this.xKey,
    required this.series,
  });

  final SpecChartType type;
  final List<Map<String, Object?>> rows;
  final String xKey;
  final List<SpecChartSeries> series;

  factory SpecChartData.fromProps(Map<String, Object?> props, {Object? state}) {
    final rawType = (props['chartType'] ?? props['type'] ?? '')
        .toString()
        .toLowerCase();
    final type = SpecChartType.values.firstWhere(
      (v) => v.name == rawType,
      orElse: () => SpecChartType.unknown,
    );
    final path = props['dataKey'];
    final rawData = path is String && path.startsWith('/')
        ? readSpecState(state, path)
        : props['data'];
    final rows = <Map<String, Object?>>[
      if (rawData is List<Object?>)
        for (final row in rawData)
          if (row is Map<Object?, Object?>)
            {
              for (final entry in row.entries)
                if (entry.key is String) entry.key! as String: entry.value,
            },
    ];
    final explicitX = props['xKey']?.toString() ?? '';
    final xKey = explicitX.isNotEmpty ? explicitX : _inferXKey(rows);
    final yKey = props['yKey']?.toString() ?? '';
    final rawSeries = props['series'];
    final series = <SpecChartSeries>[];
    if (rawSeries is List<Object?>) {
      for (final item in rawSeries) {
        if (item is! Map<Object?, Object?>) continue;
        final key = (item['key'] ?? item['dataKey'] ?? item['field'] ?? yKey)
            .toString();
        if (key.isEmpty) continue;
        series.add(
          SpecChartSeries(
            key: key,
            name: (item['name'] ?? item['label'] ?? key).toString(),
            color: item['color']?.toString() ?? '',
          ),
        );
      }
    }
    if (series.isEmpty) {
      final keys = <String>{};
      if (yKey.isNotEmpty) {
        keys.add(yKey);
      } else if (rows.any((r) => specChartNumber(r['value']) != null)) {
        keys.add('value');
      } else {
        // 真实指数看板只有 dataKey，没有 series；据数值列推断所有系列。
        for (final row in rows) {
          for (final entry in row.entries) {
            if (entry.key != xKey && specChartNumber(entry.value) != null) {
              keys.add(entry.key);
            }
          }
        }
      }
      series.addAll(keys.map((key) => SpecChartSeries(key: key, name: key)));
    }
    return SpecChartData(type: type, rows: rows, xKey: xKey, series: series);
  }

  String labelAt(int index) => rows[index][xKey]?.toString() ?? '${index + 1}';
  double? valueAt(int index, SpecChartSeries series) =>
      specChartNumber(rows[index][series.key]);

  SpecCandle? candleAt(int index) {
    final row = rows[index];
    double? read(List<String> keys) {
      for (final key in keys) {
        final value = specChartNumber(row[key]);
        if (value != null) return value;
      }
      return null;
    }

    final open = read(['open', 'Open', 'o', '开盘', '开盘价']);
    final close = read(['close', 'Close', 'c', '收盘', '收盘价']);
    final low = read(['low', 'Low', 'l', '最低', '最低价']);
    final high = read(['high', 'High', 'h', '最高', '最高价']);
    if (open == null ||
        close == null ||
        low == null ||
        high == null ||
        low > math.min(open, close) ||
        high < math.max(open, close)) {
      return null;
    }
    return SpecCandle(open, close, low, high);
  }

  double pieValueAt(int index) =>
      series.isEmpty ? 0 : math.max(0, valueAt(index, series.first) ?? 0);
  double get pieTotal =>
      List.generate(rows.length, pieValueAt).fold(0, (a, b) => a + b);

  bool get hasData {
    if (type == SpecChartType.pie) return pieTotal > 0;
    if (type == SpecChartType.candlestick) {
      return List.generate(rows.length, candleAt).any((v) => v != null);
    }
    return series.any(
      (s) => rows.any((r) => specChartNumber(r[s.key]) != null),
    );
  }

  /// 散点图有数值 X 时保留真实距离，其余图按类别等距。
  bool get hasNumericX =>
      type == SpecChartType.scatter &&
      rows.isNotEmpty &&
      rows.every((r) => specChartNumber(r[xKey]) != null);
  (double, double) get xRange {
    if (!hasNumericX) return (0, math.max(1, rows.length - 1).toDouble());
    final xs = rows.map((r) => specChartNumber(r[xKey])!);
    final min = xs.reduce(math.min);
    final max = xs.reduce(math.max);
    return min == max ? (min - 1, max + 1) : (min, max);
  }

  (double, double) get yRange {
    final values = <double>[];
    for (var i = 0; i < rows.length; i++) {
      if (type == SpecChartType.candlestick) {
        final candle = candleAt(i);
        if (candle != null) values.addAll([candle.low, candle.high]);
      } else {
        for (final s in series) {
          final value = valueAt(i, s);
          if (value != null) values.add(value);
        }
      }
    }
    if (values.isEmpty) return (0, 1);
    var min = values.reduce(math.min);
    var max = values.reduce(math.max);
    if (type != SpecChartType.candlestick) {
      min = math.min(0, min);
      max = math.max(0, max);
    }
    if (min == max) return (min - 1, max + 1);
    final pad = (max - min) * 0.05;
    return (
      min < 0 || type == SpecChartType.candlestick ? min - pad : min,
      max > 0 ? max + pad : max,
    );
  }
}

String _inferXKey(List<Map<String, Object?>> rows) {
  for (final key in [
    'date',
    'time',
    'period',
    'label',
    'name',
    'sector',
    'category',
    'symbol',
    'code',
    'index',
    'title',
  ]) {
    if (rows.any((r) => r.containsKey(key))) return key;
  }
  return 'name';
}
