import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

// fixture 镜像 PartyB chatexec/spec_json_example.json；客户端测试可独立运行。
void main() {
  for (final width in [360.0, 900.0]) {
    testWidgets('reminder 示例文件在 $width 宽度展示比较表、趋势与进度', (tester) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final raw = File('test/fixtures/spec_json_example.json')
          .readAsStringSync();
      final preview = resolveTextPreview(raw);
      expect(preview, isA<SpecTextPreview>());
      final doc = (preview as SpecTextPreview).doc;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SpecUiCard(doc: doc)),
          ),
        ),
      );
      expect(find.text('示例项目看板'), findsOneWidget);
      expect(find.text('方案 A'), findsOneWidget);
      expect(find.text('120'), findsOneWidget);
      expect(find.text('每日完成项'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.6,
      );
      final chart = SpecChartData.fromProps(
        doc.elements['trend']!.props,
        state: doc.state,
      );
      expect(chart.rows.length, 3);
      expect(chart.valueAt(1, chart.series.single), 18);
      expect(tester.takeException(), isNull);
    });
  }
}
