import 'package:test/test.dart';

import 'package:spb_domain/spb_domain.dart';

/// 真实产物：`super_partyb` 生产 workspace 实际产出的
/// `reports/route-changban-dashadong.map.spec.json`
/// （镜像自 `apps/miniapp/src/lib/__tests__/map-real.test.ts` 的 `raw`）。
///
/// 这是**回归基准**：它不是构造出来的边界情况，而是技能（amap-lbs-skill）
/// 真实写出来的形状。
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

void main() {
  group('parseMapSchema（顶层 type=map + markers/routes）', () {
    test('真实产物被解析（markers + routes 都在）', () {
      final schema = parseMapSchema(realMapSpec())!;

      expect(schema.title, '公交路线');
      expect(schema.description, '公交路线，共 5 个方案');
      expect(schema.markers, hasLength(2));
      expect(schema.routes, hasLength(1));
      expect(schema.markers[0].title, '起点');
      expect(schema.markers[0].longitude, 113.349324);
      expect(schema.markers[0].latitude, 23.178369);
      expect(schema.routes[0].mode, 'transfer');
      expect(schema.routes[0].polyline, hasLength(2));
      expect(schema.isRenderable, isTrue);
    });

    test('collectPoints = markers + 所有 polyline 点', () {
      final schema = parseMapSchema(realMapSpec())!;
      // 2 个 marker + 1 条 2 点路线 = 4（与小程序端 `collectPoints` 的断言一致）。
      expect(schema.collectPoints(), hasLength(4));
    });

    test('type 大小写不敏感（MAP / Map / map）', () {
      for (final t in ['map', 'Map', 'MAP', ' map ']) {
        expect(
          parseMapSchema({'type': t, 'markers': realMapSpec()['markers']}),
          isNotNull,
          reason: 'type=$t 应被识别',
        );
      }
    });

    test('非 map type / 非 Map 输入 → null', () {
      expect(parseMapSchema(null), isNull);
      expect(parseMapSchema('not a map'), isNull);
      expect(parseMapSchema(<Object>[]), isNull);
      expect(
        parseMapSchema({'type': 'dashboard', 'markers': <dynamic>[]}),
        isNull,
      );
      expect(
        parseMapSchema({'markers': realMapSpec()['markers']}),
        isNull,
        reason: '缺 type',
      );
    });

    test('空壳（type=map 但无有效 markers/routes）→ null', () {
      // 若不拦，预览对话框会变成一张空图——比原文差。
      expect(parseMapSchema({'type': 'map'}), isNull);
      expect(
        parseMapSchema({
          'type': 'map',
          'markers': <dynamic>[],
          'routes': <dynamic>[],
        }),
        isNull,
      );
      expect(
        parseMapSchema({
          'type': 'map',
          'markers': [
            {'title': '只有标题没有坐标'},
          ],
        }),
        isNull,
        reason: '无坐标的 marker 被丢弃（对齐 Go 侧容错）',
      );
    });

    test('只有 markers 或只有 routes 都能渲染', () {
      expect(
        parseMapSchema({
          'type': 'map',
          'markers': [
            {'longitude': 113.3, 'latitude': 23.1},
          ],
        }),
        isNotNull,
      );
      expect(
        parseMapSchema({
          'type': 'map',
          'routes': [
            {
              'polyline': [
                [113.3, 23.1],
                [113.4, 23.2],
              ],
            },
          ],
        }),
        isNotNull,
      );
    });

    test('**只认顶层** type，不做深度下探', () {
      // webapp 对 map 调 `normalizeMapSchema(parsed)`——顶层判定，不像 spec
      // 那样深度扫。否则「任意 JSON 里嵌了一个 {type:"map"} 的配置对象」
      // 会被误判成地图。
      expect(
        parseMapSchema({
          'config': {
            'type': 'map',
            'markers': [
              {'longitude': 1, 'latitude': 2},
            ],
          },
        }),
        isNull,
      );
    });
  });

  group('parseMapPolyline（两种形态 + 坏点跳过）', () {
    test('数组形态 [[lng,lat],…]', () {
      expect(
        parseMapPolyline([
          [113.3, 23.1],
          [113.4, 23.2],
        ]),
        [(113.3, 23.1), (113.4, 23.2)],
      );
    });

    test('高德字符串形态 "lng,lat;lng,lat"', () {
      expect(parseMapPolyline('113.3,23.1;113.4,23.2'), [
        (113.3, 23.1),
        (113.4, 23.2),
      ]);
    });

    test('字符串形态里的坏项被跳过（不丢整条）', () {
      expect(parseMapPolyline('113.3,23.1;oops;113.4,23.2;1,2,3'), [
        (113.3, 23.1),
        (113.4, 23.2),
        (1.0, 2.0),
      ]);
    });

    test('数组形态里的坏项被逐项跳过', () {
      expect(
        parseMapPolyline([
          [113.3, 23.1],
          'not a pair',
          [113.4],
          [113.5, 23.3],
        ]),
        [(113.3, 23.1), (113.5, 23.3)],
      );
    });

    test('字符串数值被接受（服务端可能写 "113.3"）', () {
      expect(parseMapPolyline('113.3,23.1'), [(113.3, 23.1)]);
    });

    test('NaN / Infinity 被丢弃', () {
      expect(parseMapPolyline('NaN,23.1'), isEmpty);
      expect(parseMapPolyline('113.3,Infinity'), isEmpty);
    });

    test('超长 polyline 按等步长抽稀，且保留首尾', () {
      final long = [
        for (var i = 0; i < 10000; i++) [113.0 + i * 0.0001, 23.0],
      ];
      final out = parseMapPolyline(long);

      expect(out.length, kMapMaxPolylinePoints);
      expect(out.first, (113.0, 23.0), reason: '首点必须保留');
      expect(out.last, (113.0 + 9999 * 0.0001, 23.0), reason: '末点必须保留');
    });
  });

  group('条数上限（渲染安全）', () {
    test('markers 超限被截断', () {
      final schema = parseMapSchema({
        'type': 'map',
        'markers': [
          for (var i = 0; i < kMapMaxMarkers + 50; i++)
            {'longitude': 113.0 + i * 0.001, 'latitude': 23.0},
        ],
      })!;

      expect(schema.markers.length, kMapMaxMarkers);
    });

    test('routes 超限被截断', () {
      final schema = parseMapSchema({
        'type': 'map',
        'routes': [
          for (var i = 0; i < kMapMaxRoutes + 10; i++)
            {
              'polyline': [
                [113.0, 23.0],
                [113.1, 23.1],
              ],
            },
        ],
      })!;

      expect(schema.routes.length, kMapMaxRoutes);
    });
  });

  group('MapProjection（等比投影数学）', () {
    const w = 560.0;
    const h = 300.0;

    test('空点集 → null（调用方不渲染）', () {
      expect(MapProjection.build(const [], width: w, height: h), isNull);
    });

    test('单点不除零，且落在视口中心', () {
      final p = MapProjection.build([(113.3, 23.1)], width: w, height: h)!;
      final px = p.project(113.3, 23.1);

      expect(px.x, closeTo(w / 2, 0.01));
      expect(px.y, closeTo(h / 2, 0.01));
    });

    test('跨度下限生效：极近的两点不被放大到满屏', () {
      // 相差 0.000001°（约 10 厘米）——若无跨度下限，scale 会巨大。
      final p = MapProjection.build(
        [(113.300000, 23.100000), (113.300001, 23.100001)],
        width: w,
        height: h,
      )!;
      final a = p.project(113.300000, 23.100000);
      final b = p.project(113.300001, 23.100001);

      expect((b.x - a.x).abs(), lessThan(w / 10));
    });

    test('等比缩放：南北向直线投影后仍垂直（不失真）', () {
      // 若分别把经度/纬度拉满视口，这条线会被拉斜。
      final p = MapProjection.build(
        [(113.3, 23.0), (113.3, 24.0)],
        width: w,
        height: h,
      )!;
      final a = p.project(113.3, 23.0);
      final b = p.project(113.3, 24.0);

      expect(a.x, closeTo(b.x, 0.001), reason: '同经度必须同 x');
      expect(a.y, isNot(closeTo(b.y, 1)), reason: '纬度不同必须 y 不同');
    });

    test('纬度方向：北在上（纬度大的 y 更小）', () {
      final p = MapProjection.build(
        [(113.3, 23.0), (113.3, 24.0)],
        width: w,
        height: h,
      )!;

      final south = p.project(113.3, 23.0);
      final north = p.project(113.3, 24.0);
      expect(north.y, lessThan(south.y), reason: 'SVG/Canvas y 轴向下');
    });

    test('所有投影点落在视口内（含 padding）', () {
      final points = <(double, double)>[
        (113.349324, 23.178369),
        (113.458515, 23.106216),
        (113.2, 23.3),
      ];
      final p = MapProjection.build(points, width: w, height: h)!;

      for (final (lng, lat) in points) {
        final px = p.project(lng, lat);
        expect(px.x, greaterThanOrEqualTo(0));
        expect(px.x, lessThanOrEqualTo(w));
        expect(px.y, greaterThanOrEqualTo(0));
        expect(px.y, lessThanOrEqualTo(h));
      }
    });

    test('真实产物的投影可算出有限坐标', () {
      final schema = parseMapSchema(realMapSpec())!;
      final p = MapProjection.build(
        schema.collectPoints(),
        width: w,
        height: h,
      )!;

      for (final (lng, lat) in schema.collectPoints()) {
        final px = p.project(lng, lat);
        expect(px.x.isFinite, isTrue);
        expect(px.y.isFinite, isTrue);
      }
    });

    test('退化视口（宽高小于 padding）→ null 而非负 scale', () {
      expect(
        MapProjection.build([(1, 2), (3, 4)], width: 10, height: 10),
        isNull,
      );
    });
  });

  group('展示辅助（不编造缺失信息）', () {
    test('marker 无标题时退化为坐标（不写「未命名」）', () {
      const m = MapMarker(longitude: 113.34932, latitude: 23.17837);
      expect(m.displayTitle, '113.34932,23.17837');
    });

    test('route 无标题时退化为模式名', () {
      expect(
        const MapRoute(polyline: [], mode: 'transfer').displayTitle,
        '公交路线',
      );
      expect(const MapRoute(polyline: []).displayTitle, '路线');
    });

    test('未知模式不编造标签（保留原文）', () {
      expect(mapRouteModeLabel('teleport'), isNull);
      expect(const MapRoute(polyline: [], mode: 'teleport').displayTitle, '路线');
    });

    test('距离/耗时的 null 与非正数都不显示', () {
      expect(formatMapDistance(null), isNull);
      expect(formatMapDistance(0), isNull);
      expect(formatMapDistance(-5), isNull);
      expect(formatMapDistance(500), '500 米');
      expect(formatMapDistance(1500), '1.5 km');

      expect(formatMapDuration(null), isNull);
      expect(formatMapDuration(0), isNull);
      expect(formatMapDuration(90), '约 2 分钟');
      expect(formatMapDuration(7200), '约 2.0 小时');
    });

    test('amapMarkerUrl 拼接（有/无标题）', () {
      expect(
        amapMarkerUrl(const MapMarker(longitude: 113.3, latitude: 23.1)),
        'https://uri.amap.com/marker?position=113.3,23.1',
      );
      expect(
        amapMarkerUrl(
          const MapMarker(longitude: 113.3, latitude: 23.1, title: '起点'),
        ),
        contains('name=%E8%B5%B7%E7%82%B9'),
      );
    });
  });

  group('resolveTextPreview 的 map 分支（issue #12）', () {
    test('真实 map spec → MapTextPreview', () {
      final payload = resolveTextPreview(
        '{"type":"map","markers":[{"longitude":113.3,"latitude":23.1}]}',
      );
      expect(payload, isA<MapTextPreview>());
      expect((payload as MapTextPreview).schema.markers, hasLength(1));
    });

    test('map 优先于 spec（含 type=map 的 {root,elements} 也走 map）', () {
      // map 的判据是顶层 type；spec 的判据是 {root, elements}。两者理论上
      // 可同时满足（罕见），此时按 webapp 的顺序 map 先判。
      final payload = resolveTextPreview(
        '{"type":"map","root":"r","elements":{"r":{"type":"text"}},'
        '"markers":[{"longitude":113.3,"latitude":23.1}]}',
      );
      expect(payload, isA<MapTextPreview>());
    });

    test('空壳 map 退回原文（不变成空图）', () {
      final payload = resolveTextPreview('{"type":"map"}');
      expect(payload, isA<PlainTextPreview>());
    });

    test('带坐标但 markers 全非法的 map 退回原文', () {
      final payload = resolveTextPreview(
        '{"type":"map","markers":[{"title":"无坐标"}]}',
      );
      expect(payload, isA<PlainTextPreview>());
    });

    test('非 JSON 文本仍退回原文', () {
      expect(resolveTextPreview('hello'), isA<PlainTextPreview>());
      expect(resolveTextPreview(''), isA<PlainTextPreview>());
    });

    test('既有 spec 识别不受影响（回归）', () {
      final payload = resolveTextPreview(
        '{"root":"r","elements":{"r":{"type":"card"}}}',
      );
      expect(payload, isA<SpecTextPreview>());
    });

    test('深层嵌套的 {type:map} 不被当作 map（仍走 spec 或原文）', () {
      final payload = resolveTextPreview(
        '{"config":{"type":"map","markers":[{"longitude":1,"latitude":2}]}}',
      );
      expect(payload, isNot(isA<MapTextPreview>()));
    });
  });
}
