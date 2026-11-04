/// 全局图片解码缓存（`PaintingBinding.instance.imageCache`）的显式上限。
///
/// ## 它解决什么
///
/// 全仓的 `Image.memory` / `Image.network` 此前**没有传 `cacheWidth`**，图片
/// 按原始分辨率解码进全局 imageCache：一张 4000×3000 的截图预览 ≈ 48MB
/// 解码位图（宽×高×4 字节），几张就把默认缓存挤满；而缩略图虽显示为 48px
/// 方块，也按原图尺寸解码。这是「进入对话 / 滚动后内存从 ~100MB 涨到
/// ~300MB」的主要来源之一（docs/memory-audit.md G4）。
///
/// 本函数把 imageCache 从框架默认值改为**显式上限**：超过上限时按 LRU 逐出，
/// 且逐出决策受字节数（而非张数）驱动——与「解码位图才是内存大头」的事实
/// 对齐。32MB 对聊天场景（缩略图 + 偶发预览）足够，且低于 Flutter 框架
/// 默认的 100MB（`image_cache.dart` 的 `maximumSizeBytes` 默认值），属于收紧
/// 而非放宽。
///
/// ## 为什么放 `spb_platform`
///
/// `PaintingBinding` 来自 `package:flutter/`，而 `spb_core` 是纯 Dart 包
/// （AGENTS.md §4，`check_layering.sh` 强制）。平台相关装配（依赖绑定初始化
/// 时机）本就是本包职责（`installGlobalErrorHandlers` /
/// `installFrameTimingReporter` 同一取向）。
///
/// ## 为什么是函数而不是常量
///
/// 两端 `main()` 各调一次；测试需要注入不同上限值验证逐出行为，故 [limit]
/// 可注入。**重复调用是幂等的**：后调者覆盖前者的上限（同一全局对象上的
/// setter），无需防重入。
///
/// ## 调用时机约束
///
/// 必须在 `WidgetsFlutterBinding.ensureInitialized()` **之后**调用
/// （`PaintingBinding.instance` 才存在）。本函数不自行初始化绑定——初始化
/// 时机属于 `main()` 的编排职责（AGENTS.md 两端 main 的顺序注释），这里只
/// 做赋值，保持函数副作用面最小。
library;

import 'dart:ui' show FlutterView;

import 'package:flutter/painting.dart' show ImageCache, PaintingBinding;
import 'package:flutter/widgets.dart' show WidgetsBinding;

/// 默认上限：32MB 解码位图。
///
/// 依据：聊天场景的解码位图 = 时间线缩略图（~256px 级）+ 偶发单张预览大图。
/// 32MB ≈ 8 张 1080p 截图，低于框架默认 100MB，是**收紧**。可调（见
/// [configureImageCache] 的文档与 docs/memory-audit.md G4）。
const int kImageCacheMaxBytes = 32 * 1024 * 1024;

/// 把全局 imageCache 的字节上限设为 [limit]（默认 [kImageCacheMaxBytes]）。
///
/// - 必须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用；
/// - 幂等：重复调用以后者为准；
/// - 返回设置后的实际值（测试断言用，正常调用方可忽略）。
int configureImageCache({int limit = kImageCacheMaxBytes}) {
  final cache = _imageCache();
  cache.maximumSizeBytes = limit;
  return cache.maximumSizeBytes;
}

/// 取全局 imageCache。`imageCache` 定义在 `PaintingBinding` mixin 上；
/// `WidgetsFlutterBinding`（两端 main 的绑定）聚合了该 mixin，但静态类型
/// `WidgetsBinding` 看不到它——需要显式 narrowing。判据失败说明绑定不是
/// Flutter 实现（如纯 BindingBase），此时调用方必须在 ensureInitialized 之后。
ImageCache _imageCache() {
  final binding = WidgetsBinding.instance;
  assert(
    binding is PaintingBinding,
    '绑定未初始化或不含 PaintingBinding：必须先调 WidgetsFlutterBinding.ensureInitialized()',
  );
  return (binding as PaintingBinding).imageCache;
}

/// 计算解码上限（`cacheWidth`）：**逻辑显示宽度 × 设备像素比，向上取整**。
///
/// 解码出的位图不需要超过「屏幕上实际占用的物理像素」；超过的部分纯属
/// 浪费（缩略图卡 48px 方块、头像 32px 圆、预览不超过窗口宽）。传 0 表示
/// 「取屏幕宽」：
///
/// - `view` 不可得（无头测试早期）→ 退化为只按 [displayLogicalWidth] 自身
///   取整——宁可多解码一点，也不能让缩略图糊掉或抛异常（与 `agent_file_card`
///   「缩略图失败不阻断卡片」同一取向）；
/// - `view.devicePixelRatio` 异常值（≤0 或非法）→ 按 1.0 处理。
///
/// 返回值**至少为 1**（`cacheWidth: 0` 会让解码器按无限宽处理，等于没传）。
int imageDecodeCeilingFor({
  required double displayLogicalWidth,
  FlutterView? view,
}) {
  double dpr = 1.0;
  if (view != null) {
    final d = view.devicePixelRatio;
    if (d.isFinite && d > 0) dpr = d;
  }
  final px = (displayLogicalWidth * dpr).ceil();
  return px < 1 ? 1 : px;
}
