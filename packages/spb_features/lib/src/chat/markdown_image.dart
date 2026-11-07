/// Markdown 内联图片的解码降采样（docs/memory-audit.md G10）。
///
/// ## 它解决什么
///
/// `gpt_markdown` 的**默认**图片路径是
/// `Image(image: NetworkImage(url))`（1.3.4 `shared_render.dart` 的
/// `imageSpan`），**没有** `cacheWidth`/`ResizeImage`——于是 agent 回复里
/// 贴一张 4000×3000 的截图，就按原图分辨率解码 ≈ 48MB 位图进全局
/// `imageCache`。而它显示在气泡里，逻辑宽最多 ~1024dp。
///
/// 与 `agent_file_card` / `agent_file_preview` / 头像三处同一个病、同一个
/// 药方（[imageDecodeCeilingFor]）：解码宽取「显示尺寸 × DPR」的物理像素，
/// 再大纯属浪费。**这是全仓最后一处未降采样的 `Image`**。
///
/// ## 为什么必须由我们接管整个图片 widget
///
/// 插件的 `imageBuilder` 是**唯一**钩子，它替换的是整个图片 widget（含
/// loading/error 占位与尺寸盒子），不是只换 provider。故本文件复刻默认
/// 实现的三件事，保证视觉与默认路径一致：
///
/// 1. `SizedBox(width, height)` —— Markdown alt 里写的 `=宽x高` 是**逻辑**
///    尺寸，默认实现用它做紧约束；
/// 2. `fit: BoxFit.fill` —— 默认实现的 `imageStyle.fit ?? BoxFit.fill`；本仓库
///    的 `_styleSheet` 未设置 `ImageStyle`，故默认值即 fill。**若将来给
///    `GptMarkdownStyleSheet.image` 设了 fit，这里必须跟着改**；
/// 3. loading / error 占位用插件自己的 `CustomImageLoading` / `CustomImageError`
///    （深 import 自 `custom_widgets/custom_error_image.dart`——它没有从
///    `gpt_markdown.dart` 导出，但正是默认路径用的那两个组件，复用才谈得上
///    「视觉一致」。插件若挪走该文件，编译期报错，不会静默降级）。
///
/// ## `data:` URL 为什么要有自己的缓存
///
/// 插件默认路径支持 `data:image/png;base64,...`，并为它维护一份 32 条/32MB
/// 的字节 LRU（`_dataUrlCache`）。那份缓存是**私有**的：接管 `imageBuilder`
/// 就等于接管了这条路径，不补一份就会退化——`MemoryImage` 的相等性是**字节
/// 列表同一性**，每帧重新 `base64Decode` 会得到一个全新 provider（缓存永不
/// 命中，流式回复里每帧重解码并闪一下）。故 [kDataUrlMemoMaxEntries] /
/// [kDataUrlMemoMaxBytes] 与插件同级（32 / 32MB），仍是有界的。
///
/// ## 折衷（诚实记录）
///
/// - **只限宽、不限高**：`cacheWidth` 是「宽度上限」，超宽图按比例缩小；但
///   一张极窄极高的图（如 200×20000 的长截图）解码后仍可能很高。真正的
///   上界由全局 `imageCache` 的 32MB 上限（`configureImageCache`）兜底——
///   同时限高会改变图片的**显示尺寸**（解码尺寸即内在尺寸），那不是优化而是
///   改行为。
/// - **超宽窗口略糊**：解码宽封顶 `kImageDecodeCeilingLogicalWidth`（1024dp），
///   窗口更宽时图片被插值放大。与预览图同一取舍。
/// - **横向 DPR 变化会重解码**：`ResizeImage` 的缓存键含解码宽，把窗口拖到
///   另一块不同缩放比的屏幕会多解码一次（一次性的，不是持续成本）。
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/custom_widgets/custom_error_image.dart'
    show CustomImageError, CustomImageLoading;
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// `data:` URL 解码缓存的上限：条数。
///
/// 与插件原实现（`gpt_markdown` 的 `_dataUrlCacheEntries`）同级，理由见文件
/// 头「data: URL 为什么要有自己的缓存」。
const int kDataUrlMemoMaxEntries = 32;

/// `data:` URL 解码缓存的上限：字节总数。
const int kDataUrlMemoMaxBytes = 32 * 1024 * 1024;

/// 已解码的 `data:` URL 字节，按 LRU 排列（最近使用在尾部）。
///
/// 键是**完整 URL 字符串**：同一张内联图在流式重建里 URL 不变，故命中的是
/// 同一份字节列表，`MemoryImage` 的相等性因此稳定。
final LinkedHashMap<String, Uint8List> _dataUrlMemo =
    LinkedHashMap<String, Uint8List>();
int _dataUrlMemoBytes = 0;

/// 清空 `data:` URL 缓存（仅测试用：避免用例之间互相污染）。
@visibleForTesting
void clearDataUrlImageMemo() {
  _dataUrlMemo.clear();
  _dataUrlMemoBytes = 0;
}

/// 传给 `GptMarkdown(imageBuilder: ...)` 的图片构造器（docs/memory-audit.md
/// G10）。
///
/// 签名与插件的 `ImageBuilder` typedef 一致：
/// `Widget Function(BuildContext, String url, double? width, double? height)`。
Widget markdownImageBuilder(
  BuildContext context,
  String url,
  double? width,
  double? height,
) {
  final provider = _providerFor(url);
  final Widget child;
  if (provider == null) {
    // 解不出来（非法 base64 / 空数据）：与「网络图 404」同一个占位，
    // 不抛异常、不阻断整条回复的渲染。
    child = const CustomImageError();
  } else {
    child = Image(
      image: ResizeImage(
        provider,
        // 解码上限（docs/memory-audit.md G10）：宽度上限 = 显示逻辑宽 × DPR。
        width: imageDecodeCeilingFor(
          displayLogicalWidth: _ceilingLogicalWidth(context, width),
          view: View.maybeOf(context),
        ),
      ),
      // 与插件默认实现一致（见文件头第 2 条）。
      fit: BoxFit.fill,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        final total = progress.expectedTotalBytes;
        return CustomImageLoading(
          // 插件默认实现不 clamp；这里夹到 [0,1] 防止某些服务端给出的
          // 累计字节数超过总长时占位组件收到越界值。
          progress: total == null
              ? 1
              : (progress.cumulativeBytesLoaded / total).clamp(0.0, 1.0),
        );
      },
      errorBuilder: (context, error, stackTrace) => const CustomImageError(),
    );
  }

  // 尺寸盒子：`=宽x高` 是逻辑像素的紧约束；都没写时原样传递（不约束），
  // 与插件默认实现的 `SizedBox(width: width, height: height, ...)` 一致。
  return SizedBox(width: width, height: height, child: child);
}

/// 解码宽度的**逻辑**上限：取「Markdown 声明的宽」与「基准上限」的较小者。
///
/// 未声明宽时退到视口宽（图片不会比窗口更宽），视口也拿不到时用基准值
/// （宁可多解码一点，不让图糊）。
double _ceilingLogicalWidth(BuildContext context, double? declaredWidth) {
  if (declaredWidth != null && declaredWidth.isFinite && declaredWidth > 0) {
    return declaredWidth < kImageDecodeCeilingLogicalWidth
        ? declaredWidth
        : kImageDecodeCeilingLogicalWidth;
  }
  final viewport = MediaQuery.maybeSizeOf(context)?.width;
  if (viewport == null || !viewport.isFinite || viewport <= 0) {
    return kImageDecodeCeilingLogicalWidth;
  }
  return viewport < kImageDecodeCeilingLogicalWidth
      ? viewport
      : kImageDecodeCeilingLogicalWidth;
}

/// URL → provider。`data:` 走 [MemoryImage]（带字节 LRU），其余走
/// [NetworkImage]（与插件默认一致）。null = 这条 URL 不是可渲染的图片。
ImageProvider<Object>? _providerFor(String url) {
  if (!_isDataUrl(url)) return NetworkImage(url);
  final bytes = _dataUrlBytes(url);
  return bytes == null ? null : MemoryImage(bytes);
}

bool _isDataUrl(String url) =>
    url.length > 5 && url.substring(0, 5).toLowerCase() == 'data:';

/// 取 `data:` URL 的解码字节（命中则提升为最近使用）。null = 不是有效图片。
Uint8List? _dataUrlBytes(String url) {
  final cached = _dataUrlMemo.remove(url);
  if (cached != null) {
    _dataUrlMemo[url] = cached;
    return cached;
  }

  final comma = url.indexOf(',');
  if (comma < 0 || comma == url.length - 1) return null;

  final Uint8List bytes;
  try {
    bytes = base64Decode(url.substring(comma + 1));
  } on FormatException catch (e) {
    // 非法 base64 按「这不是一张图」处理：交给 CustomImageError 占位。
    // 用 debug 而非 warn——流式回复里同一段坏数据每帧都会重建，warn 会把
    // 500 条环形缓冲冲干净，反而看不到出事前后的上下文。
    SpbLog.debug('Markdown data: URL 解码失败', {'error': '$e'});
    return null;
  }
  if (bytes.isEmpty) return null;

  _dataUrlMemo[url] = bytes;
  _dataUrlMemoBytes += bytes.length;
  while (_dataUrlMemo.length > kDataUrlMemoMaxEntries ||
      _dataUrlMemoBytes > kDataUrlMemoMaxBytes) {
    if (_dataUrlMemo.isEmpty) break;
    final oldest = _dataUrlMemo.keys.first;
    _dataUrlMemoBytes -= _dataUrlMemo.remove(oldest)!.length;
  }
  return bytes;
}
