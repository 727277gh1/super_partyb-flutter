import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/src/chat/timeline_extent_cache.dart';

void main() {
  const a = ValueKey('a');
  const b = ValueKey('b');
  const c = ValueKey('c');

  test('前插和重排按行身份保留实测高度，裁剪后不保留旧行', () {
    final cache = TimelineExtentCache()..updateRows([a, b]);
    cache.record(a, 40);
    cache.record(b, 2000);
    cache.updateRows([c, b, a]);
    cache.record(c, 300);
    expect(cache.extentBetween(0, 3), 2340);
    expect(cache.extentBetween(1, 3), 2040);
    expect(cache.extentBetween(2, 3), 40);

    cache.updateRows([a, c]);
    cache.record(b, 5000);
    expect(cache.extentBetween(0, 2), 340);
    // 被裁掉的行再次出现时不能拿旧测量值冒充当前排版结果。
    cache.updateRows([b]);
    expect(cache.extentBetween(0, 1), isNot(2000));
  });

  test('字号或宽度变化后重测全部行，同一布局的重复构建保留测量', () {
    final cache = TimelineExtentCache()
      ..updateRows([a, b])
      ..updateLayout((800, 1.0));
    cache.record(a, 50);
    cache.record(b, 2500);
    cache.updateLayout((800, 1.0));
    expect(cache.extentBetween(0, 2), 2550);
    cache.updateLayout((400, 1.5));
    cache.record(a, 120);
    cache.record(b, 6000);
    expect(cache.extentBetween(0, 2), 6120);
    cache.clear();
    cache.updateRows([a, b]);
    expect(cache.extentBetween(0, 2), isNot(6120));
  });

  test('流式增长与折叠收缩只更新对应行，所有区间与实际行高一致', () {
    final keys = [for (var i = 0; i < 31; i++) ValueKey(i)];
    final heights = [for (var i = 0; i < 31; i++) (i + 1) * 53.0];
    final cache = TimelineExtentCache()..updateRows(keys);
    for (var i = 0; i < keys.length; i++) {
      cache.record(keys[i], heights[i]);
    }
    heights[7] = 4200;
    cache.record(keys[7], heights[7]);
    heights[20] = 30;
    cache.record(keys[20], heights[20]);
    for (var start = 0; start < keys.length; start++) {
      for (var end = start; end <= keys.length; end++) {
        expect(
          cache.extentBetween(start, end),
          heights.sublist(start, end).fold(0.0, (sum, height) => sum + height),
        );
      }
    }
  });
}
