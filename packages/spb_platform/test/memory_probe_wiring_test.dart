import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 两端 `main.dart` 是否真的装了内存采样（docs/memory-audit.md §四）。
///
/// ## 为什么需要读源文件
///
/// `installMemoryProbe()` 是**进程级**副作用：它的效果只有在 `main()` 跑过之后
/// 才存在（诊断报告里多一个「## 内存采样」小节），而没有任何页面测试会经过
/// `main()`。于是「一端接了、另一端忘了」这种漏接线**编译期与测试期都静默**
/// ——这正是 AGENTS.md §6.17 记录的失败模式（`enableSearch: false` 曾让移动端
/// 搜索入口整块消失而两端测试全绿）。
///
/// Dart 在 AOT 下没有反射可用，故与 `event_types_consistency_test.dart` 同一
/// 手法：直接读源码文本，断言两个入口都调用了这两个接线点。
///
/// ⚠️ 本测试只钉「有没有接线」，不钉位置/顺序——顺序的理由（必须在
/// `configureImageCache()` 之后、`SpbLog.configure()` 之后）写在两端 `main()`
/// 的注释里，属于代码评审范畴。
void main() {
  /// 从本包目录出发定位两端入口（`packages/spb_platform` → 仓库根 → `apps/`）。
  File entryOf(String app) => File('../../apps/$app/lib/main.dart');

  test('桌面端与移动端都装了内存采样', () {
    for (final app in ['spb_desktop', 'spb_mobile']) {
      final file = entryOf(app);
      expect(file.existsSync(), isTrue, reason: '路径约定变了就改本测试，而不是让它静默跳过');
      final source = file.readAsStringSync();

      expect(
        source.contains('installMemoryProbe()'),
        isTrue,
        reason: '$app 没装内存采样：报告里不会有 RSS / 峰值 / imageCache 曲线',
      );
      expect(
        source.contains('installedMemoryProbe?.sample(force: true)'),
        isTrue,
        reason: '$app 的内存压力回调没留一笔采样——压力时刻往往正是峰值',
      );
    }
  });

  test('两端都在 configureImageCache 之后安装（基线才有参照意义）', () {
    for (final app in ['spb_desktop', 'spb_mobile']) {
      final source = entryOf(app).readAsStringSync();
      final cache = source.indexOf('configureImageCache()');
      final probe = source.indexOf('installMemoryProbe()');

      expect(cache, isNonNegative, reason: '$app 少了 configureImageCache');
      expect(
        probe,
        greaterThan(cache),
        reason: '首条采样就是基线：缓存配置之前采到的 imageCache 值没有参照意义',
      );
    }
  });
}
