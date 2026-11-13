import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 保存当前时间线已排版的行高，避免 Sliver 用可见长短行的均值反复推算总高度。
/// 只持有 Key 和数值，不延长 Markdown / RenderObject 的生命周期。
class TimelineExtentCache {
  static const _unknownExtent = 120.0;

  final _measured = <Key, double>{};
  Map<Key, int> _indices = {};
  List<Key> _keys = const [];
  List<double> _sums = [0];
  Object? _layoutSignature;
  int _layoutVersion = 0;
  int get layoutVersion => _layoutVersion;

  void updateRows(List<Key> keys) {
    if (listEquals(keys, _keys)) return;
    _keys = keys;
    _indices = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    _measured.removeWhere((key, _) => !_indices.containsKey(key));
    _rebuildSums();
  }

  void updateLayout(Object signature) {
    if (_layoutSignature == signature) return;
    _layoutSignature = signature;
    _layoutVersion++;
    _measured.clear();
    _rebuildSums();
  }

  void clear() {
    _measured.clear();
    _indices = {};
    _keys = const [];
    _sums = [0];
    _layoutSignature = null;
    _layoutVersion++;
  }

  void record(Key key, double extent) {
    final index = _indices[key];
    if (index == null || !extent.isFinite || extent < 0) return;
    final previous = _measured[key] ?? _unknownExtent;
    _measured[key] = extent;
    final delta = extent - previous;
    if (delta == 0) return;
    // 树状数组让布局期间的单行更新、任意分页区间求和都为 O(log n)，
    // 不在每次滚轮事件里遍历整份历史。
    for (var i = index + 1; i < _sums.length; i += i & -i) {
      _sums[i] += delta;
    }
  }

  double extentBetween(int start, int end) => _prefix(end) - _prefix(start);

  double _prefix(int end) {
    var sum = 0.0;
    for (var i = end; i > 0; i -= i & -i) {
      sum += _sums[i];
    }
    return sum;
  }

  void _rebuildSums() {
    _sums = List<double>.filled(_keys.length + 1, 0);
    for (var i = 1; i < _sums.length; i++) {
      _sums[i] += _measured[_keys[i - 1]] ?? _unknownExtent;
      final parent = i + (i & -i);
      if (parent < _sums.length) _sums[parent] += _sums[i];
    }
  }
}

/// 两段 Sliver 共用同一份行高；前插历史与分界重排后按稳定 Key 复用测量值。
class TimelineChildDelegate extends SliverChildBuilderDelegate {
  TimelineChildDelegate(
    super.builder, {
    required this.extents,
    required this.start,
    required this.end,
    required this.reverse,
    this.trailingExtent = 0,
    required super.childCount,
    required super.findChildIndexCallback,
    required super.semanticIndexCallback,
  }) : super(addRepaintBoundaries: false);

  final TimelineExtentCache extents;
  final int start;
  final int end;
  final bool reverse;
  final double trailingExtent;

  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    if (lastIndex == childCount! - 1) return trailingScrollOffset;
    final remaining = reverse
        ? extents.extentBetween(start, end - lastIndex - 1)
        : extents.extentBetween(start + lastIndex + 1, end);
    return trailingScrollOffset + remaining + trailingExtent;
  }
}

/// 在正常布局中同步记录实际高度，不额外排帧、setState 或预先构建离屏消息。
class TimelineRowMeasure extends SingleChildRenderObjectWidget {
  TimelineRowMeasure({
    super.key,
    required this.rowKey,
    required this.extents,
    required super.child,
  }) : layoutVersion = extents.layoutVersion;

  final Key rowKey;
  final TimelineExtentCache extents;
  final int layoutVersion;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderTimelineRowMeasure(rowKey, extents, layoutVersion);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTimelineRowMeasure renderObject,
  ) {
    if (renderObject.rowKey != rowKey ||
        renderObject.extents != extents ||
        renderObject.layoutVersion != layoutVersion) {
      renderObject
        ..rowKey = rowKey
        ..extents = extents
        ..layoutVersion = layoutVersion
        ..markNeedsLayout();
    }
  }
}

class RenderTimelineRowMeasure extends RenderProxyBox {
  RenderTimelineRowMeasure(this.rowKey, this.extents, this.layoutVersion);

  Key rowKey;
  TimelineExtentCache extents;
  int layoutVersion;

  @override
  void performLayout() {
    super.performLayout();
    extents.record(rowKey, size.height);
  }
}
