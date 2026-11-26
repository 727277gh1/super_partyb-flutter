/// 系统内存压力信号的接线（docs/memory-audit.md G9）。
///
/// ## 它解决什么
///
/// Android/iOS 在系统内存吃紧时会向应用发 `memoryPressure` 信号
/// （`SystemChannels.system`，由框架派发给 `WidgetsBindingObserver` 的
/// `didHaveMemoryPressure`）。此前**全仓没有任何接收方**——移动端是最需要
/// 这条信号的端（内存最紧张），但收到压力时应用什么都不做，直到被系统杀掉。
///
/// ## 框架已经做了一半，我们补另一半（实测确认）
///
/// 收到压力时 `RendererBinding.handleMemoryPressure()` 会**先**调
/// `imageCache.clear()`（`rendering/binding.dart`），然后才遍历 observer。
/// 所以单看 `clear()` 我们是重复的。但 `clear()` **不碰 live images**
/// （还有外部 listener 的图，例如正显示在屏幕上的预览大图）——实测：
///
/// ```
/// 清空前: size=1 live=1
/// clear(): size=0 live=1   ← 框架只做到这里
/// clearLiveImages(): size=0 live=0  ← 本模块补的
/// ```
///
/// 而「用户正盯着一张 4000×3000 预览图」恰恰是移动端最容易 OOM 的场景。
/// 故本模块两件事：
///
/// 1. `imageCache.clear()`——保留（对框架当前行为是幂等防御；若将来框架改动，
///    这里仍然兜住）；
/// 2. `imageCache.clearLiveImages()`——**只在这里**，是真实增量；
/// 3. `onRelease`——app 层的页面级可再生缓存（气泡 widget 缓存 / 缩略图
///    Future 记忆）。
///
/// **不**清任何持久化状态（离线缓存库 / 同步状态 / outbox）——那些不是
/// 「内存」，清掉会丢用户数据。
///
/// ## 为什么是「进程级监听」而不是各页面自己 observer
///
/// 页面级 observer 的注册时机随路由出入漂移，容易漏。这里在**进程级**注册
/// 一次、活到进程结束，与 `SpbEndpoints.changes.listen`（main.dart 既有注释
/// 「订阅不取消是有意的」）同一取向。
///
/// ## 为什么放 `spb_platform`
///
/// 依赖 `WidgetsBinding`（Flutter 绑定），纯 Dart 包放不了（§4 分层）；它是
/// 平台信号接线，与 `installGlobalErrorHandlers` / `configureImageCache`
/// 同一职责族。
library;

import 'package:flutter/painting.dart' show imageCache;
import 'package:flutter/widgets.dart'
    show WidgetsBinding, WidgetsBindingObserver;

/// 注册进程级内存压力监听。
///
/// - [onRelease]：app 层的页面级缓存清理（清 `_bubbleCache` /
///   `_thumbnailMemo` 等）。**必须幂等且不抛**——压力信号可能短时间连发。
/// - 返回一个解绑函数（测试用）；生产调用方通常不取消（进程级监听）。
///
/// 桌面端没有这条系统信号（Linux/Windows/macOS 的 Flutter 引擎不派发
/// `didHaveMemoryPressure`），注册后不产生任何效果——故两端可以**无差别**
/// 调用，无需平台分支。
void Function() installMemoryPressureHandler({void Function()? onRelease}) {
  final observer = _MemoryPressureObserver(onRelease: onRelease);
  WidgetsBinding.instance.addObserver(observer);
  return () => WidgetsBinding.instance.removeObserver(observer);
}

class _MemoryPressureObserver with WidgetsBindingObserver {
  _MemoryPressureObserver({this.onRelease});

  final void Function()? onRelease;

  @override
  void didHaveMemoryPressure() {
    // 框架的 `RendererBinding.handleMemoryPressure()` 已经调过 `clear()`；
    // 这里再调一次是幂等防御（见类文档「框架已经做了一半」）。
    imageCache.clear();
    // 真正独有的那一环：连带释放「还有 listener 的图」（正在显示的预览大图）。
    imageCache.clearLiveImages();
    onRelease?.call();
  }
}
