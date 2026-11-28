import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import '../support/golden_fonts.dart';
import '../support/spec_dashboard_fixture.dart';

void main() {
  setUpAll(loadGoldenFonts);

  for (final width in [360.0, 900.0]) {
    testWidgets('真实看板 ${width.toInt()}px 的布局、曲线和表格', (t) async {
      await t.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: SpbTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: const ValueKey('dashboard-golden'),
                child: Material(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SpecUiCard(doc: parseSpecUi(realDashboardSpec())),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('dashboard-golden')),
        matchesGoldenFile('goldens/spec_dashboard_${width.toInt()}.png'),
      );
    });
  }

  testWidgets('六类图表绘制基线覆盖负值、断点和 K 线', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    const types = ['line', 'area', 'bar', 'scatter', 'pie', 'candlestick'];
    final spec = <String, Object?>{
      'root': 'r',
      'elements': {
        'r': {
          'type': 'Grid',
          'props': {'columns': 2},
          'children': types,
        },
        for (final type in types)
          type: {
            'type': 'Chart',
            'props': {
              'title': type,
              'chartType': type,
              'height': 170,
              'data': [
                {
                  'name': 'A',
                  'value': 3,
                  'open': 38,
                  'close': 39,
                  'low': 37.5,
                  'high': 39.5,
                },
                {
                  'name': 'B',
                  'value': -2,
                  'open': 39,
                  'close': 38,
                  'low': 37,
                  'high': 40,
                },
                {
                  'name': 'C',
                  'value': null,
                  'open': 38,
                  'close': 38,
                  'low': 37.5,
                  'high': 39,
                },
                {
                  'name': 'D',
                  'value': 4,
                  'open': 38,
                  'close': 40,
                  'low': 38,
                  'high': 41,
                },
              ],
            },
          },
      },
    };
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: SpbTheme.light(),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('charts-golden'),
            child: Material(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SpecUiCard(doc: parseSpecUi(spec)),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('charts-golden')),
      matchesGoldenFile('goldens/spec_charts.png'),
    );
  });
}
