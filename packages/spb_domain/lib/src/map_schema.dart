/// map spec（`*.map.spec.json`，Map Schema v1）解析层——纯 Dart 模型与投影数学。
///
/// ## 这是什么（第三种 spec 文件格式）
///
/// 与 `JsonUiSchema`（`{root, elements}` 树形交互 UI，见 [SpecUiDocument]）、
/// `DashboardSchema`（`{x, y, w, h}` 网格）并列。map spec 顶层是
/// `type: "map"`，描述 `markers` + `routes`。
///
/// 生产方：`amap-lbs-skill` 等技能写 `*.map.spec.json` 到群工作区。
/// 消费方：webapp `MapSchemaRenderer` / 小程序原生 `<Map>` / 本客户端
/// （`spb_features` 的 `MapSpecCard`）。
///
/// ## 坐标系与序（**照抄上游，不要"纠正"**）
///
/// - 坐标 GCJ-02（高德 / 小程序 `<Map>` / webapp 高德一致，**无需转换**）；
/// - `polyline` 坐标对是 **[经度, 纬度]**（geojson / 高德惯例，**经度在前**）。
///
/// 这两条是本层的**契约**：写反了不会报错，只会把地图画到地球另一边。
///
/// ## 为什么放在 spb_domain
///
/// 解析 + **投影数学**都是纯逻辑：投影（经纬度 → 视口像素，等比缩放 + 居中）
/// 有真实的边界条件（单点、极小范围、跨零度），必须能脱离 Flutter 单测——
/// 放在渲染组件里就只能靠 golden 截图来验证数学了。
///
/// ## 安全约束（同 [parseSpecUi]：绝不抛异常）
///
/// spec 是服务端 payload，形状漂移不该炸掉预览对话框。故：
///
/// - 非法项**逐项丢弃**（不是整体失败）；
/// - 三个**条数上限**（见 [kMapMaxMarkers] 等）：`CustomPaint` 画 10 万个点的
///   Path 会把 UI 卡死。上限是「渲染安全」而非「协议约束」。
library;

import 'dart:math' as math;

/// 渲染的 marker 条数上限（超出丢弃）。
///
/// 真实产出是个位数到几十。上限只为挡住损坏/恶意 payload——`CustomPaint`
/// 画 10 万个点是**卡死 UI**，不是「慢一点」。
const int kMapMaxMarkers = 200;

/// 渲染的路线条数上限（超出丢弃）。
const int kMapMaxRoutes = 20;

/// 单条路线的坐标点数上限（超出按**等步长抽稀**，不是直接截断）。
///
/// 抽稀而非截断：截断会让长路线在视觉上「提前结束」，看起来像数据缺失；
/// 等步长保留首尾与整体走向，用户看到的是「粗略但完整」的轨迹。
const int kMapMaxPolylinePoints = 2000;

/// 一个地图标记点。
final class MapMarker {
  const MapMarker({
    required this.longitude,
    required this.latitude,
    this.id = '',
    this.title = '',
    this.description = '',
    this.category = '',
  });

  /// 经度（GCJ-02）。
  final double longitude;

  /// 纬度（GCJ-02）。
  final double latitude;

  final String id;
  final String title;
  final String description;

  /// POI 类别（景点 / 美食 / 酒店…）。空串表示未分类。
  final String category;

  /// 列表里显示的标题；无标题时退化为坐标（**不编造**占位文字）。
  String get displayTitle => title.isNotEmpty
      ? title
      : '${longitude.toStringAsFixed(5)},'
            '${latitude.toStringAsFixed(5)}';

  @override
  String toString() => 'MapMarker($displayTitle @ $longitude,$latitude)';
}

/// 一条路线。
final class MapRoute {
  const MapRoute({
    required this.polyline,
    this.id = '',
    this.mode = '',
    this.title = '',
    this.distanceMeters,
    this.durationSeconds,
  });

  /// 坐标点序列（**[经度, 纬度]**，见库文档）。
  final List<(double, double)> polyline;

  final String id;

  /// `walking` / `driving` / `riding` / `transfer`。空串表示未标注。
  final String mode;

  final String title;

  /// 距离（米）。null 表示未知（**不当作 0**——「0 米」与「不知道」是两回事）。
  final double? distanceMeters;

  /// 耗时（秒）。null 表示未知。
  final double? durationSeconds;

  /// 列表里显示的标题；无标题时退化为模式名（如「公交路线」）。
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final label = mapRouteModeLabel(mode);
    return label == null ? '路线' : '$label路线';
  }

  @override
  String toString() => 'MapRoute($displayTitle, ${polyline.length} pts)';
}

/// 解析完成的 map 文档。
final class MapSchema {
  const MapSchema({
    this.title = '',
    this.description = '',
    this.markers = const [],
    this.routes = const [],
  });

  final String title;
  final String description;
  final List<MapMarker> markers;
  final List<MapRoute> routes;

  /// 全部坐标点（markers + 所有 polyline）——投影的输入。
  List<(double, double)> collectPoints() => [
    for (final m in markers) (m.longitude, m.latitude),
    for (final r in routes) ...r.polyline,
  ];

  /// 是否可渲染（至少要有一个坐标点，否则是空图）。
  bool get isRenderable => collectPoints().isNotEmpty;
}

/// 路线模式的中文标签（未知模式返回 null，**不编造**标签）。
String? mapRouteModeLabel(String mode) => switch (mode.toLowerCase().trim()) {
  'walking' => '步行',
  'driving' => '驾车',
  'riding' => '骑行',
  'transfer' => '公交',
  _ => null,
};

/// 距离的人类可读形式（null / 非正数 → null，不显示）。
String? formatMapDistance(double? meters) {
  if (meters == null || meters <= 0 || !meters.isFinite) return null;
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${meters.round()} 米';
}

/// 耗时的人类可读形式（null / 非正数 → null）。
String? formatMapDuration(double? seconds) {
  if (seconds == null || seconds <= 0 || !seconds.isFinite) return null;
  final minutes = (seconds / 60).round();
  if (minutes >= 60) return '约 ${(minutes / 60).toStringAsFixed(1)} 小时';
  return '约 $minutes 分钟';
}

/// 高德 marker URI（web 端 / 移动端新标签页打开）。对齐 webapp `amapMarkerUrl`。
String amapMarkerUrl(MapMarker marker) {
  final name = marker.title.isEmpty
      ? ''
      : '&name=${Uri.encodeQueryComponent(marker.title)}';
  return 'https://uri.amap.com/marker'
      '?position=${marker.longitude},${marker.latitude}$name';
}

/// 宽松数值解析：num 直接用，String 尝试 parse，其余（含 NaN/Inf）→ null。
double? _asNum(Object? value) {
  if (value is num) {
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }
  if (value is String) {
    final t = value.trim();
    if (t.isEmpty) return null;
    final d = double.tryParse(t);
    return (d != null && d.isFinite) ? d : null;
  }
  return null;
}

/// 解析 `[经度, 纬度]` 坐标对（容忍长度 > 2 的数组，取前两项）。
(double, double)? _parseLngLat(Object? value) {
  if (value is! List || value.length < 2) return null;
  final lng = _asNum(value[0]);
  final lat = _asNum(value[1]);
  if (lng == null || lat == null) return null;
  return (lng, lat);
}

/// 解析 polyline：接受 `[[lng,lat],…]` 或高德 `"lng,lat;lng,lat"` 字符串。
///
/// 非法项**逐项跳过**（不是整条丢弃）——真实产出里混入个别坏点是有可能的，
/// 丢掉整条路线比丢掉一个点损失大得多。
///
/// 对齐 webapp `parsePolyline`（含字符串形态：`transfer` 等拿不到真实轨迹时
/// 上游会写起终点直线）。
List<(double, double)> parseMapPolyline(Object? value) {
  final out = <(double, double)>[];

  if (value is String) {
    for (final pair in value.split(';')) {
      final parts = pair.split(',');
      if (parts.length < 2) continue;
      final lng = _asNum(parts[0]);
      final lat = _asNum(parts[1]);
      if (lng == null || lat == null) continue;
      out.add((lng, lat));
    }
    return _simplifyPolyline(out);
  }

  if (value is! List) return const [];
  for (final item in value) {
    final point = _parseLngLat(item);
    if (point != null) out.add(point);
  }
  return _simplifyPolyline(out);
}

/// 超过 [kMapMaxPolylinePoints] 时按**等步长**抽稀（保留首尾）。
List<(double, double)> _simplifyPolyline(List<(double, double)> points) {
  if (points.length <= kMapMaxPolylinePoints) return points;
  final out = <(double, double)>[];
  final step = points.length / kMapMaxPolylinePoints;
  for (var i = 0; i < kMapMaxPolylinePoints - 1; i++) {
    out.add(points[(i * step).floor()]);
  }
  // 末点必须保留：否则轨迹看起来「没画完」。
  out.add(points.last);
  return out;
}

MapMarker? _parseMarker(Object? value) {
  if (value is! Map) return null;
  final lng = _asNum(value['longitude']);
  final lat = _asNum(value['latitude']);
  // 无坐标的 marker 丢弃（对齐 Go 侧 `parseMapSpec` 的容错：title-only 丢弃）。
  if (lng == null || lat == null) return null;
  return MapMarker(
    longitude: lng,
    latitude: lat,
    id: value['id']?.toString() ?? '',
    title: value['title']?.toString() ?? '',
    description: value['description']?.toString() ?? '',
    category: value['category']?.toString() ?? '',
  );
}

MapRoute? _parseRoute(Object? value) {
  if (value is! Map) return null;
  final polyline = parseMapPolyline(value['polyline']);
  if (polyline.isEmpty) return null;
  return MapRoute(
    polyline: polyline,
    id: value['id']?.toString() ?? '',
    mode: value['mode']?.toString() ?? '',
    title: value['title']?.toString() ?? '',
    distanceMeters: _asNum(value['distanceMeters']),
    durationSeconds: _asNum(value['durationSeconds']),
  );
}

/// 识别 + 解析 map spec。
///
/// ## 判据（对齐 webapp `isMapSchema` / Go `parseMapSpec`）
///
/// 1. 是 Map；
/// 2. 顶层 `type` 大小写不敏感等于 `map`；
/// 3. `markers` 与 `routes` 解析后**至少有一项有效**。
///
/// 三者缺一返回 null。第 3 条是关键：`{type: "map"}` 这种空壳若不拦，
/// 预览对话框会变成一张空图（比原文差）。
///
/// ## 为什么只看**顶层** type（不做深度下探）
///
/// webapp 的 `resolveTextPreview` 对 map 调的是 `normalizeMapSchema(parsed)`
/// ——**顶层**判定，不像 `spec` 那样深度扫（`extractSchemaFromUnknown`）。
/// 这是有意的：`type: "map"` 这个标记太泛，深度下探会把「任意 JSON 里嵌了
/// 一个 `{type:'map'}` 的配置对象」误判成地图。**故此处严格对齐，不下探。**
MapSchema? parseMapSchema(Object? value) {
  if (value is! Map) return null;
  if (value['type']?.toString().toLowerCase().trim() != 'map') return null;

  final rawMarkers = value['markers'];
  final rawRoutes = value['routes'];
  final markerList = rawMarkers is List ? rawMarkers : const <dynamic>[];
  final routeList = rawRoutes is List ? rawRoutes : const <dynamic>[];

  final markers = <MapMarker>[];
  for (final raw in markerList) {
    if (markers.length >= kMapMaxMarkers) break;
    final m = _parseMarker(raw);
    if (m != null) markers.add(m);
  }

  final routes = <MapRoute>[];
  for (final raw in routeList) {
    if (routes.length >= kMapMaxRoutes) break;
    final r = _parseRoute(raw);
    if (r != null) routes.add(r);
  }

  if (markers.isEmpty && routes.isEmpty) return null;

  return MapSchema(
    title: value['title']?.toString() ?? '',
    description: value['description']?.toString() ?? '',
    markers: markers,
    routes: routes,
  );
}

/// 归一化后的视口坐标（像素）。
typedef MapPixel = ({double x, double y});

/// 经纬度 → 视口像素的**等比**投影（保方向不失真）。
///
/// ## 为什么是等比而不是分别拉伸
///
/// 分别把经度、纬度拉满视口会让轨迹**形状失真**：一条南北向的直线会被拉成
/// 45°，用户据此判断方向会错。等比缩放保证「形状与真实一致，只是缩放与居中」。
///
/// ## 三个边界
///
/// - **单点 / 极小范围**：跨度下限 [kMinSpan]（0.002°，约 200 米）——否则
///   除零，且单点会被放大到整个视口（看起来像「范围很大」）；
/// - **空点集**：构造返回 null（调用方不渲染 SVG）；
/// - **纬度翻转**：纬度向上、屏幕 y 轴向下，故用 `maxLat - lat`。
final class MapProjection {
  const MapProjection._({
    required this.centerLng,
    required this.centerLat,
    required this.spanLng,
    required this.spanLat,
    required this.scale,
    required this.offsetX,
    required this.offsetY,
  });

  /// 跨度下限（度）。0.002° ≈ 200 米，足够让单点不除零、也不被放大成「大范围」。
  static const double kMinSpan = 0.002;

  /// 视口内边距（像素）。
  static const double kPadding = 16;

  /// 有效投影框的中心（数据包围盒中心；跨度被 [kMinSpan] 抬高时不变）。
  final double centerLng;
  final double centerLat;

  /// 有效跨度（已施加 [kMinSpan] 下限）。
  final double spanLng;
  final double spanLat;

  final double scale;
  final double offsetX;
  final double offsetY;

  /// 从点集构造投影。空点集（或全部坐标非法）返回 null。
  static MapProjection? build(
    List<(double, double)> points, {
    required double width,
    required double height,
  }) {
    if (points.isEmpty) return null;

    var minLng = double.infinity;
    var maxLng = double.negativeInfinity;
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    for (final (lng, lat) in points) {
      minLng = math.min(minLng, lng);
      maxLng = math.max(maxLng, lng);
      minLat = math.min(minLat, lat);
      maxLat = math.max(maxLat, lat);
    }
    if (!minLng.isFinite || !maxLat.isFinite) return null;

    // 以**数据包围盒中心**为基准施加跨度下限（而不是从 min 角固定）。
    //
    // ## 为什么不是 `offsetX + (lng - minLng) * scale`（webapp 的写法）
    //
    // webapp 在跨度被抬高时把数据锚在包围盒的 **min 角**：单点会被画到视口
    // 左上角（实测 x=146, y=16 而视口是 560×300），看起来像「范围很大、点在
    // 角落里」。以中心为基准后单点落在视口正中，而**跨度未被抬高时两者完全
    // 等价**（`center - span/2 == min`）——即真实多点的产物逐像素一致。
    final centerLng = (minLng + maxLng) / 2;
    final centerLat = (minLat + maxLat) / 2;
    final spanLng = math.max(maxLng - minLng, kMinSpan);
    final spanLat = math.max(maxLat - minLat, kMinSpan);
    final innerW = width - kPadding * 2;
    final innerH = height - kPadding * 2;
    if (innerW <= 0 || innerH <= 0) return null;

    final scale = math.min(innerW / spanLng, innerH / spanLat);
    final offsetX = kPadding + (innerW - spanLng * scale) / 2;
    final offsetY = kPadding + (innerH - spanLat * scale) / 2;

    return MapProjection._(
      centerLng: centerLng,
      centerLat: centerLat,
      spanLng: spanLng,
      spanLat: spanLat,
      scale: scale,
      offsetX: offsetX,
      offsetY: offsetY,
    );
  }

  /// 投影单个点。
  MapPixel project(double lng, double lat) => (
    x: offsetX + (lng - (centerLng - spanLng / 2)) * scale,
    // 纬度向上、SVG/Canvas y 轴向下。
    y: offsetY + ((centerLat + spanLat / 2) - lat) * scale,
  );
}
