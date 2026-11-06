import 'package:flutter/material.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';

/// map spec（`*.map.spec.json`）渲染卡：SVG 归一化轨迹图 + 路线/地点列表。
///
/// 对齐 webapp `MapSchemaRenderer`（**一期轻量实现**）：
///
/// | 能力 | 本实现 | 说明 |
/// |---|---|---|
/// | 轨迹图 | ✅ `CustomPaint` | **无底图、无地图 SDK、无密钥**——只有投影数学 |
/// | marker 列表 | ✅ | 有 `onOpenMarker` 时每行可点（跳高德） |
/// | 路线列表 | ✅ | 模式 / 距离 / 耗时，缺失项**不编造** |
/// | 高德跳转 | 回调上抛 | 拼 URL 的职责在装配层（同 `onAction` 的既有约定） |
///
/// ## 为什么不需要地图 SDK（这是核实过的结论）
///
/// webapp 的实现自称「SVG 归一化轨迹图（无底图、无高德 JS key 依赖）」，核心
/// 只有投影数学（经纬度 → 视口像素，等比缩放 + 居中）。本组件把它照搬到
/// `CustomPaint`——**零新依赖**。曾经把这件事估成「需引 SDK / 底图」是错的
/// （见 `AGENTS.md` §6.9.4）。
///
/// ## 无底图是有意的，不是「还没做」
///
/// 底图（瓦片）意味着：网络请求、第三方服务条款、离线不可用、可能的位置精度
/// 泄露。归一化轨迹图回答的是「这些点在哪、相对关系如何、路线怎么走」——这是
/// 产物要表达的东西。要看真实地图，用户点一行走「在高德地图打开」。
class MapSpecCard extends StatelessWidget {
  const MapSpecCard({super.key, required this.schema, this.onOpenMarker});

  /// 解析后的 map 文档（[MapSchema.isRenderable] 为 false 时整体不渲染）。
  final MapSchema schema;

  /// 点击地点行时上抛（装配层负责拼 [amapMarkerUrl] 并打开浏览器）。
  /// null 时列表行**不可点**（不渲染成一个点了没反应的入口）。
  final void Function(MapMarker marker)? onOpenMarker;

  /// 轨迹图画布尺寸。
  ///
  /// 固定视口 + `AspectRatio` 由外层保证宽度自适应：投影需要**确定的**像素
  /// 空间才能算 scale，用 `LayoutBuilder` 的实时尺寸会让「同一份 spec 在不同
  /// 窗口宽度下投影不同」——那本身没错，但会让 golden 基线不稳定。故固定
  /// 内部分辨率，由 `CustomPaint` 的 `size` 缩放显示。
  static const double canvasWidth = 560;
  static const double canvasHeight = 300;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!schema.isRenderable) return const SizedBox.shrink();

    final projection = MapProjection.build(
      schema.collectPoints(),
      width: canvasWidth,
      height: canvasHeight,
    );
    if (projection == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (schema.title.isNotEmpty || schema.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: SpbSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (schema.title.isNotEmpty)
                  Text(schema.title, style: theme.textTheme.titleSmall),
                if (schema.description.isNotEmpty)
                  Text(
                    schema.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(SpbRadius.sm),
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: AspectRatio(
              aspectRatio: canvasWidth / canvasHeight,
              child: CustomPaint(
                key: const ValueKey('map-spec-canvas'),
                painter: _MapPainter(
                  schema: schema,
                  projection: projection,
                  routeColors: _routeColors(scheme),
                  markerColor: scheme.error,
                  labelColor: scheme.onSurfaceVariant,
                ),
                // 无障碍：轨迹图对屏幕阅读器是完全空白的自绘区域，必须给
                // 语义标签（同 `SpecUiCard` 的进度条，issue #24 的同一判据）。
                // 内容由下方的路线/地点列表承载，故这里只报「这是什么」。
                child: Semantics(
                  label: _semanticsLabel(),
                  container: true,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        if (schema.routes.isNotEmpty) ...[
          const SizedBox(height: SpbSpacing.sm),
          _sectionHeader(context, Icons.route_outlined, '路线'),
          for (var i = 0; i < schema.routes.length; i++)
            _RouteRow(
              route: schema.routes[i],
              color: _routeColors(scheme)[i % _routeColors(scheme).length],
            ),
        ],
        if (schema.markers.isNotEmpty) ...[
          const SizedBox(height: SpbSpacing.sm),
          _sectionHeader(
            context,
            Icons.place_outlined,
            onOpenMarker == null ? '地点' : '地点（点击在高德地图打开）',
          ),
          // 地点列表**封顶 + 内滚**（对齐 webapp 的 `max-h-[180px] overflow-y-auto`）。
          //
          // 不封顶的话，一个 200 个地点的 spec 会把卡片撑到几千像素高——在预览
          // 对话框里尚可滚动，但作为**内联卡片**（未来若接到时间线）会直接溢出。
          // 地图本身（轨迹图）才是主要内容，列表是索引。
          ConstrainedBox(
            key: const ValueKey('map-marker-list'),
            constraints: const BoxConstraints(maxHeight: _markerListMaxHeight),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final marker in schema.markers)
                    _MarkerRow(
                      marker: marker,
                      onTap: onOpenMarker == null
                          ? null
                          : () => onOpenMarker!(marker),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 地点列表的最大高度（对齐 webapp 的 `max-h-[180px]`）。
  static const double _markerListMaxHeight = 180;

  /// 语义标签：说清「这是什么的图」与规模，不逐点朗读（列表已承载细节）。
  String _semanticsLabel() {
    final parts = <String>['地图轨迹图'];
    if (schema.title.isNotEmpty) parts.add(schema.title);
    if (schema.markers.isNotEmpty) parts.add('${schema.markers.length} 个地点');
    if (schema.routes.isNotEmpty) parts.add('${schema.routes.length} 条路线');
    return parts.join('，');
  }

  static List<Color> _routeColors(ColorScheme scheme) => [
    scheme.primary,
    scheme.tertiary,
    scheme.secondary,
    scheme.error,
    scheme.onSurfaceVariant,
  ];

  static Widget _sectionHeader(
    BuildContext context,
    IconData icon,
    String label,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: SpbSpacing.xxs),
      child: Row(
        children: [
          Icon(
            icon,
            size: SpbSpacing.md,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: SpbSpacing.xxs),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 轨迹图画笔：先路线后 marker（marker 压在上层，不被线条盖住）。
class _MapPainter extends CustomPainter {
  const _MapPainter({
    required this.schema,
    required this.projection,
    required this.routeColors,
    required this.markerColor,
    required this.labelColor,
  });

  final MapSchema schema;
  final MapProjection projection;
  final List<Color> routeColors;
  final Color markerColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 内部分辨率固定，画布可能被缩放显示——按比例映射。
    final sx = size.width / MapSpecCard.canvasWidth;
    final sy = size.height / MapSpecCard.canvasHeight;
    canvas.save();
    canvas.scale(sx, sy);

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < schema.routes.length; i++) {
      final route = schema.routes[i];
      if (route.polyline.length < 2) continue;
      final path = Path();
      for (var j = 0; j < route.polyline.length; j++) {
        final (lng, lat) = route.polyline[j];
        final p = projection.project(lng, lat);
        if (j == 0) {
          path.moveTo(p.x, p.y);
        } else {
          path.lineTo(p.x, p.y);
        }
      }
      linePaint.color = routeColors[i % routeColors.length];
      canvas.drawPath(path, linePaint);
    }

    final dotPaint = Paint()..color = markerColor;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xFFFFFFFF);
    for (final marker in schema.markers) {
      final p = projection.project(marker.longitude, marker.latitude);
      canvas.drawCircle(Offset(p.x, p.y), 5, dotPaint);
      canvas.drawCircle(Offset(p.x, p.y), 5, ringPaint);
      if (marker.title.isNotEmpty) {
        // 标签直接画在画布上（不做命中测试/换行）：它是**辅助**信息，
        // 完整标题由下方列表承载。
        final tp = TextPainter(
          text: TextSpan(
            text: marker.title,
            style: TextStyle(fontSize: 11, color: labelColor),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 120);
        tp.paint(canvas, Offset(p.x + 8, p.y - 6));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.schema != schema ||
      old.projection != projection ||
      old.markerColor != markerColor;
}

/// 地点行。可点时整行是 `InkWell`（有 `onTap`），不可点时是纯展示。
class _MarkerRow extends StatelessWidget {
  const _MarkerRow({required this.marker, this.onTap});

  final MapMarker marker;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xxs,
        vertical: SpbSpacing.xxs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.place, size: SpbSpacing.md, color: scheme.error),
          const SizedBox(width: SpbSpacing.xxs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  marker.displayTitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (marker.description.isNotEmpty)
                  Text(
                    marker.description,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (marker.category.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SpbSpacing.xs,
                vertical: SpbSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(SpbRadius.sm),
              ),
              child: Text(marker.category, style: theme.textTheme.labelSmall),
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(
      key: ValueKey(
        'map-marker-${marker.id.isEmpty ? marker.displayTitle : marker.id}',
      ),
      onTap: onTap,
      borderRadius: BorderRadius.circular(SpbRadius.sm),
      child: row,
    );
  }
}

/// 路线行：色点 + 标题 + 模式/距离/耗时（缺失项不显示）。
class _RouteRow extends StatelessWidget {
  const _RouteRow({required this.route, required this.color});

  final MapRoute route;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // 缺失项**不编造**：不知道距离就不写「0 米」，不写「未知距离」占位。
    final meta = [
      mapRouteModeLabel(route.mode),
      formatMapDistance(route.distanceMeters),
      formatMapDuration(route.durationSeconds),
    ].whereType<String>().join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpbSpacing.xxs,
        vertical: SpbSpacing.xxs,
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: SpbSpacing.xs),
          Expanded(
            child: Text(
              route.displayTitle,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (meta.isNotEmpty)
            Text(
              meta,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
