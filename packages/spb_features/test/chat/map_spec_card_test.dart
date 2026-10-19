import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 真实产物：`super_partyb` 生产 workspace 的
/// `reports/route-changban-dashadong.map.spec.json`
/// （镜像自 `apps/miniapp/src/lib/__tests__/map-real.test.ts`）。
///
/// 回归基准：不是构造的边界情况，而是技能真实写出的形状。
Map<String, dynamic> realMapSpec() => {
  'type': 'map',
  'version': '1',
  'title': '公交路线',
  'description': '公交路线，共 5 个方案',
  'markers': [
    {
      'id': 'marker-1',
      'longitude': 113.349324,
      'latitude': 23.178369,
      'title': '起点',
      'description': '',
      'category': '',
    },
    {
      'id': 'marker-2',
      'longitude': 113.458515,
      'latitude': 23.106216,
      'title': '终点',
      'description': '',
      'category': '',
    },
  ],
  'routes': [
    {
      'id': 'route-1',
      'mode': 'transfer',
      'title': '公交路线',
      'polyline': [
        [113.349324, 23.178369],
        [113.458515, 23.106216],
      ],
    },
  ],
};

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('MapSpecCard（issue #12 的 map 项）', () {
    testWidgets('渲染标题、说明、路线与地点', (tester) async {
      final schema = parseMapSchema(realMapSpec())!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('公交路线'), findsWidgets);
      expect(find.text('公交路线，共 5 个方案'), findsOneWidget);

      // 地点：标题来自 marker.title。
      expect(find.text('起点'), findsOneWidget);
      expect(find.text('终点'), findsOneWidget);

      // 路线：模式被翻译成中文标签。
      expect(find.text('公交路线'), findsWidgets);
    });

    testWidgets('轨迹图画布被渲染（CustomPaint 存在）', (tester) async {
      final schema = parseMapSchema(realMapSpec())!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.byKey(const ValueKey('map-spec-canvas')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('轨迹图有语义标签（自绘区域对屏幕阅读器是空白的）', (tester) async {
      final schema = parseMapSchema(realMapSpec())!;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      // 标签要说明「这是什么的图」+ 规模，而不是逐点朗读。
      expect(
        find.bySemanticsLabel(RegExp('地图轨迹图.*2 个地点.*1 条路线')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('未注入 onOpenMarker 时地点行不可点（不渲染无反应的入口）', (tester) async {
      final schema = parseMapSchema(realMapSpec())!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('注入 onOpenMarker 后点击地点行上抛对应 marker', (tester) async {
      final schema = parseMapSchema(realMapSpec())!;
      final opened = <String>[];
      await tester.pumpWidget(
        _host(
          MapSpecCard(schema: schema, onOpenMarker: (m) => opened.add(m.title)),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('map-marker-marker-1')));
      await tester.pump();

      expect(opened, ['起点']);
    });

    testWidgets('仅 marker（无路线）也渲染', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'markers': [
          {'longitude': 113.3, 'latitude': 23.1, 'title': '孤点'},
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('孤点'), findsOneWidget);
      expect(find.text('路线'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仅路线（无 marker）也渲染', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'routes': [
          {
            'mode': 'walking',
            'polyline': [
              [113.3, 23.1],
              [113.4, 23.2],
            ],
          },
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('步行路线'), findsOneWidget);
      expect(find.text('地点'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('距离/耗时缺失时不编造（不显示「0 米」「未知」）', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'routes': [
          {
            'mode': 'driving',
            'polyline': [
              [113.3, 23.1],
              [113.4, 23.2],
            ],
          },
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('驾车'), findsOneWidget);
      expect(find.textContaining('0 米'), findsNothing);
      expect(find.textContaining('未知'), findsNothing);
    });

    testWidgets('距离/耗时存在时展示', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'routes': [
          {
            'mode': 'driving',
            'distanceMeters': 1500,
            'durationSeconds': 600,
            'polyline': [
              [113.3, 23.1],
              [113.4, 23.2],
            ],
          },
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('驾车 · 1.5 km · 约 10 分钟'), findsOneWidget);
    });

    testWidgets('不可渲染的 schema 渲染空（不崩）', (tester) async {
      // 手工构造空 schema（parseMapSchema 不会产出它——那是它的职责）。
      await tester.pumpWidget(_host(const MapSpecCard(schema: MapSchema())));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('map-spec-canvas')), findsNothing);
    });

    testWidgets('未知模式不编造标签（只显示「路线」）', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'routes': [
          {
            'mode': 'teleport',
            'polyline': [
              [113.3, 23.1],
              [113.4, 23.2],
            ],
          },
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      // 节标题「路线」+ 行标题「路线」= 2 处（都不含原始 mode 字符串）。
      expect(find.text('路线'), findsNWidgets(2));
      expect(find.textContaining('teleport'), findsNothing);
    });

    testWidgets('marker 无标题时显示坐标', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'markers': [
          {'longitude': 113.34932, 'latitude': 23.17837},
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('113.34932,23.17837'), findsOneWidget);
    });

    testWidgets('类别徽章渲染', (tester) async {
      final schema = parseMapSchema({
        'type': 'map',
        'markers': [
          {
            'longitude': 113.3,
            'latitude': 23.1,
            'title': '某景点',
            'category': '景点',
          },
        ],
      })!;
      await tester.pumpWidget(_host(MapSpecCard(schema: schema)));

      expect(find.text('景点'), findsOneWidget);
    });

    testWidgets('多点轨迹不崩（50 个 marker + 长路线）', (tester) async {
      // 包一层滚动宿主：真实用法里本卡片总是放在可滚动容器中（预览对话框的
      // `SingleChildScrollView`、时间线的列表项）。裸 Column 宿主下 50 行列表
      // 必然溢出——那是宿主的问题，不是卡片的。
      final schema = parseMapSchema({
        'type': 'map',
        'markers': [
          for (var i = 0; i < 50; i++)
            {
              'longitude': 113.0 + i * 0.01,
              'latitude': 23.0 + i * 0.005,
              'title': '点$i',
            },
        ],
        'routes': [
          {
            'polyline': [
              for (var i = 0; i < 500; i++)
                [113.0 + i * 0.001, 23.0 + i * 0.0005],
            ],
          },
        ],
      })!;
      await tester.pumpWidget(
        _host(SingleChildScrollView(child: MapSpecCard(schema: schema))),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('map-spec-canvas')), findsOneWidget);
      // 地点列表被封顶：50 行（每行约 34px）必须被压到 180px 内，
      // 否则卡片会撑到 1700px 高——作为内联卡片时直接溢出。
      final listBox = tester.renderObject<RenderBox>(
        find.byKey(const ValueKey('map-marker-list')),
      );
      expect(
        listBox.size.height,
        lessThanOrEqualTo(180.0),
        reason: '50 个地点必须内滚，不能把卡片撑高',
      );
    });
  });
}
