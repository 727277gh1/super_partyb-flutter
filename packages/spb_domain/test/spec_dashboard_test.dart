import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

void main() {
  test('嵌套 props、数组和 JSON Pointer 转义读取同一状态快照', () {
    final state = <String, Object?>{
      'a/b': {'~title': '明细'},
      'rows': [
        {'name': '甲', 'value': 12},
      ],
    };
    final doc = parseSpecUi({
      'root': 'r',
      'state': state,
      'elements': {
        'r': {
          'type': 'Table',
          'props': {
            'title': {r'$state': '/a~1b/~0title'},
            'rows': {r'$bindState': '/rows'},
            'columns': [
              {
                'key': 'name',
                'label': {r'$state': '/rows/0/name'},
              },
            ],
          },
        },
      },
    })!;
    expect(doc.root!.prop('title'), '明细');
    expect(doc.root!.props['rows'], state['rows']);
    expect(doc.root!.props['columns'], [
      {'key': 'name', 'label': '甲'},
    ]);
    expect(readSpecState(state, '/rows/-1'), isNull);
    expect(readSpecState(state, '/rows/9'), isNull);
    expect(readSpecState(state, '/missing'), isNull);
    expect(state['a/b'], {'~title': '明细'});
  });

  test('状态绑定损坏或过深时保留空值，不显示绑定对象、不抛异常', () {
    Object? nested = 'x';
    for (var i = 0; i < 100; i++) {
      nested = {'a': nested};
    }
    expect(
      () => resolveSpecValue(nested, const <String, Object?>{}),
      returnsNormally,
    );
    final doc = parseSpecUi({
      'root': 'r',
      'state': {
        'rows': [1],
      },
      'elements': {
        'r': {
          'type': 'Text',
          'props': {r'$state': '/rows'},
        },
      },
    })!;
    expect(doc.root!.props, isEmpty);
    expect(
      resolveSpecValue({r'$state': '/missing'}, const <String, Object?>{}),
      isNull,
    );
  });

  test('初始可见性支持 false、eq/neq、truthy、exists，零值能正确比较', () {
    const state = {'count': 0, 'ready': false};
    expect(specValueVisible(false, state), isFalse);
    expect(specValueVisible({r'$state': '/count', 'eq': 0}, state), isTrue);
    expect(specValueVisible({r'$state': '/count', 'neq': 0}, state), isFalse);
    expect(
      specValueVisible({r'$state': '/ready', 'truthy': false}, state),
      isTrue,
    );
    expect(
      specValueVisible({r'$state': '/missing', 'exists': false}, state),
      isTrue,
    );
    expect(
      specValueVisible({r'$state': '/count', 'exists': true}, state),
      isTrue,
    );
  });

  test('生产看板 dataKey 没有 series 时自动推断多条数值系列', () {
    final data = SpecChartData.fromProps(
      {'chartType': 'line', 'dataKey': '/data/closes'},
      state: {
        'data': {
          'closes': [
            {'date': '7/16', 'sh': 3882.41, 'sz': 14488.65},
            {'date': '7/17', 'sh': 3764.16, 'sz': 13706.88},
          ],
        },
      },
    );
    expect(data.xKey, 'date');
    expect(data.series.map((s) => s.key), ['sh', 'sz']);
    expect(data.valueAt(1, data.series.first), 3764.16);
    expect(data.hasData, isTrue);
  });

  test('series 别名和名称保留，缺失和非法数值不补零', () {
    final data = SpecChartData.fromProps({
      'chartType': 'area',
      'series': [
        {'field': 'v', 'label': '价格', 'color': '#123456'},
      ],
      'data': [
        {'name': 'A', 'v': '2.5'},
        {'name': 'B'},
        {'name': 'C', 'v': 'NaN'},
        {'name': 'D', 'v': double.infinity},
      ],
    });
    expect(data.series.single.name, '价格');
    expect(data.series.single.color, '#123456');
    expect(List.generate(4, (i) => data.valueAt(i, data.series.single)), [
      2.5,
      null,
      null,
      null,
    ]);
  });

  test('负值柱状图包含零基线，K 线范围只覆盖实际价格', () {
    final bars = SpecChartData.fromProps({
      'chartType': 'bar',
      'data': [
        {'value': -3},
        {'value': 5},
      ],
    });
    expect(bars.yRange.$1, lessThan(-3));
    expect(bars.yRange.$2, greaterThan(5));
    final candles = SpecChartData.fromProps({
      'chartType': 'candlestick',
      'data': [
        {'date': 'A', '开盘': 38, '收盘': 39, '最低': 37, '最高': 40},
        {'date': 'B', 'o': 39, 'c': 38, 'l': 37.5, 'h': 39.5},
        {'date': '坏值', 'open': 38, 'close': 40, 'low': 39, 'high': 41},
      ],
    });
    expect(candles.candleAt(0)!.open, 38);
    expect(candles.candleAt(1)!.close, 38);
    expect(candles.candleAt(2), isNull);
    expect(candles.yRange.$1, greaterThan(35));
    expect(candles.yRange.$2, lessThan(42));
  });

  test('散点图保留数值 X 的距离，单点和平价范围可绘制', () {
    final scatter = SpecChartData.fromProps({
      'chartType': 'scatter',
      'xKey': 'x',
      'yKey': 'y',
      'data': [
        {'x': 1, 'y': 3},
        {'x': 100, 'y': 4},
      ],
    });
    expect(scatter.hasNumericX, isTrue);
    expect(scatter.xRange, (1.0, 100.0));
    final flat = SpecChartData.fromProps({
      'chartType': 'candlestick',
      'data': [
        {'open': 5, 'close': 5, 'low': 5, 'high': 5},
      ],
    });
    expect(flat.yRange.$2 - flat.yRange.$1, greaterThan(0));
  });

  test('饼图只计正值；未知类型和空数据可识别', () {
    final pie = SpecChartData.fromProps({
      'chartType': 'pie',
      'data': [
        {'value': 3},
        {'value': -5},
        {'value': null},
        {'value': 7},
      ],
    });
    expect(pie.pieTotal, 10);
    expect(pie.pieValueAt(1), 0);
    expect(SpecChartData.fromProps({'chartType': 'line'}).hasData, isFalse);
    expect(
      SpecChartData.fromProps({'chartType': 'radar'}).type,
      SpecChartType.unknown,
    );
  });
}
