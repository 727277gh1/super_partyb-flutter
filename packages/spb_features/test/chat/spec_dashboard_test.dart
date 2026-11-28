import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_features/src/chat/spec_chart.dart';

import '../support/spec_dashboard_fixture.dart';

Widget host(Map<String, Object?> spec, {double scale = 1}) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SpecUiCard(doc: parseSpecUi(spec)),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('布局允许复用同一叶子引用，环引用仍被阻断', (t) async {
    await t.pumpWidget(
      host({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'Row',
            'children': ['a', 'r', 'a'],
          },
          'a': {
            'type': 'Text',
            'props': {'text': '复用节点'},
          },
        },
      }),
    );
    expect(find.text('复用节点'), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });
  testWidgets('真实看板的图、表、状态取值均通过文件预览使用的 Renderer 呈现', (t) async {
    await t.pumpWidget(host(realDashboardSpec()));
    expect(find.byType(DataTable), findsOneWidget);
    expect(
      find.byKey(const ValueKey('spec-chart-trend-chart')),
      findsOneWidget,
    );
    expect(find.text('3764.16'), findsOneWidget);
    expect(find.textContaining('不支持的组件'), findsNothing);
    final chart =
        t
                .widget<CustomPaint>(
                  find.byKey(const ValueKey('spec-chart-trend-chart')),
                )
                .painter!
            as SpecChartPainter;
    expect(chart.data.series.map((s) => s.key), ['sh', 'sz', 'cyb']);
    expect(chart.data.rows.length, 4);
    expect(t.takeException(), isNull);
  });

  testWidgets('Grid 桌面三列、窄屏及大字号换行，不产生 overflow', (t) async {
    addTearDown(() => t.binding.setSurfaceSize(null));
    final spec = realDashboardSpec();
    spec['root'] = 'kpi-row';
    await t.binding.setSurfaceSize(const Size(900, 800));
    await t.pumpWidget(host(spec));
    expect(
      t.getTopLeft(find.text('上证指数')).dy,
      t.getTopLeft(find.text('创业板指')).dy,
    );
    await t.binding.setSurfaceSize(const Size(360, 800));
    await t.pumpWidget(host(spec, scale: 2));
    expect(
      t.getTopLeft(find.text('深证成指')).dy,
      greaterThan(t.getTopLeft(find.text('上证指数')).dy),
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('Row 横排、Column 纵排，隐藏节点不占布局位置', (t) async {
    Map<String, Object?> spec(String type) => {
      'root': 'r',
      'state': {'first': '一', 'second': '二'},
      'elements': {
        'r': {
          'type': type,
          'children': ['a', 'hidden', 'b'],
        },
        'a': {
          'type': 'Text',
          'props': {
            'text': {r'$state': '/first'},
          },
        },
        'b': {
          'type': 'Text',
          'props': {
            'text': {r'$bindState': '/second'},
          },
        },
        'hidden': {
          'type': 'Text',
          'visible': false,
          'props': {'text': '隐藏'},
        },
      },
    };
    await t.pumpWidget(host(spec('Row')));
    expect(t.getTopLeft(find.text('一')).dy, t.getTopLeft(find.text('二')).dy);
    expect(find.text('隐藏'), findsNothing);
    await t.pumpWidget(host(spec('Column')));
    expect(
      t.getTopLeft(find.text('二')).dy,
      greaterThan(t.getTopLeft(find.text('一')).dy),
    );
  });

  testWidgets('宽表横向滚动并分页，缺失单元格不显示 null', (t) async {
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.binding.setSurfaceSize(const Size(360, 800));
    await t.pumpWidget(
      host({
        'root': 'r',
        'elements': {
          'r': {
            'type': 'Table',
            'props': {
              'columns': [
                {'id': 'name', 'title': '项目名称'},
                {'field': 'value', 'label': '超长列标题用于验证滚动'},
                {'key': 'missing', 'label': '备注'},
              ],
              'rows': [
                {'name': '第一个', 'value': 1},
                {
                  'name': '第二个',
                  'value': {'a': true},
                },
              ],
              'pageSize': 1,
            },
          },
        },
      }),
    );
    expect(find.text('第一个'), findsOneWidget);
    expect(find.text('null'), findsNothing);
    await t.tap(find.byTooltip('下一页'));
    await t.pump();
    expect(find.text('第一个'), findsNothing);
    expect(find.text('第二个'), findsOneWidget);
    expect(find.text('{"a":true}'), findsOneWidget);
    final horizontal = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    await t.drag(horizontal, const Offset(-200, 0));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  for (final type in ['line', 'area', 'bar', 'scatter', 'pie', 'candlestick']) {
    testWidgets('$type 绘制且点击可查看实际数值', (t) async {
      await t.pumpWidget(
        host({
          'root': 'r',
          'elements': {
            'r': {
              'type': 'Chart',
              'props': {
                'chartType': type,
                'height': 180,
                'data': [
                  {
                    'name': 'A',
                    'value': 3,
                    'open': 3,
                    'close': 4,
                    'low': 2,
                    'high': 5,
                  },
                  {
                    'name': 'B',
                    'value': 6,
                    'open': 4,
                    'close': 3,
                    'low': 2.5,
                    'high': 4.5,
                  },
                ],
              },
            },
          },
        }),
      );
      final canvas = find.byKey(const ValueKey('spec-chart-r'));
      expect(canvas, findsOneWidget);
      await t.tapAt(t.getCenter(canvas) + const Offset(10, 0));
      await t.pump();
      expect(find.byKey(const ValueKey('spec-chart-detail-r')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('图表缺数据与未知类型有明确提示，更新数据时清理旧选中值', (t) async {
    Map<String, Object?> spec(String type, List<Object?> data) => {
      'root': 'r',
      'elements': {
        'r': {
          'type': 'Chart',
          'props': {'chartType': type, 'data': data},
        },
      },
    };
    await t.pumpWidget(
      host(
        spec('line', [
          {'value': 7},
        ]),
      ),
    );
    await t.tap(find.byKey(const ValueKey('spec-chart-r')));
    await t.pump();
    await t.pumpWidget(host(spec('line', [])));
    expect(find.text('暂无有效图表数据'), findsOneWidget);
    expect(find.byKey(const ValueKey('spec-chart-detail-r')), findsNothing);
    await t.pumpWidget(host(spec('radar', [])));
    expect(find.text('暂不支持的图表类型：radar'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
