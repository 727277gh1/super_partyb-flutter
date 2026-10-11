/// 文件预览类型判定（纯逻辑，无 IO、无 Flutter）。
///
/// ## 口径真源
///
/// 对齐 webapp `apps/webapp/src/lib/workbench/file-preview.ts` 的
/// `loadAgentFilePreview` + `isInlinePreviewableFile`（`lib/api/file-service.ts`）。
///
/// webapp 支持**六类**预览：
///
/// | 类型 | 本客户端 |
/// |---|---|
/// | `text` | ✅ 已实现 |
/// | `image` | ✅ 已实现 |
/// | `external`（跳 UFS 预览页） | ✅ 已实现 |
/// | `spec`（`{root, elements}` 结构化表单） | ✅ 已实现（内容层判定，见 [resolveTextPreview]） |
/// | `map`（`{type:"map", markers, routes}`） | ✅ 已实现（见 [MapTextPreview] / `MapSpecCard`） |
/// | `dashboard`（网格格式） | ❌ 未实现（issue #12 剩余项，见下） |
///
/// `spec` / `map` 与 `dashboard`（网格格式）**不是一个决策**：客户端已有
/// `SpecUiCard` + [parseSpecUi]，缺的只是「从任意 JSON 里把 schema 提取出来」，
/// 故由 [extractSpecSchemaFromUnknown] 补上；`map` 的渲染器由
/// [parseMapSchema] / `MapProjection`（纯 Dart）与 `MapSpecCard`（绘制）承载。
/// 两者**都不需要**引入新渲染器/新依赖。
///
/// ## ⚠️ `dashboard` / `map` 的真实成本（2026-10 核实，修正早期判断）
///
/// 早期注释写的是「需**各自的渲染技术栈**」「`map` 需**底图**」——**与上游实测
/// 不符**，容易把一件小活估成需要引 SDK 的大活：
///
/// - **`map`**：webapp `MapSchemaRenderer.tsx` 自称「一期轻量实现：SVG 归一化
///   轨迹图（**无底图、无高德 JS key 依赖**）」，实现只有 ~25 行投影数学
///   （经纬度 → SVG 坐标，等比缩放 + 居中）＋ marker 列表 ＋「在高德地图打开」
///   外链。**没有地图 SDK，没有瓦片，没有密钥。** ✅ 已按此落地：见
///   [parseMapSchema] / [MapProjection]（纯 Dart，可无图形环境测）与
///   `spb_features` 的 `MapSpecCard`（`CustomPaint`）。
/// - **`dashboard`**：webapp 有**两个不同**的渲染器，别混为一谈——
///   ① `DashboardRenderer.tsx`（`{type:"dashboard", components:[{type,layout}]}`
///   网格布局）只认 **3 个**组件类型（`stat-cards` / `table` / `chart`，共 364 行）；
///   ② `JsonUiSchemaRenderer.tsx`（`{root, elements}`，即本客户端的 `spec`）。
///   且**上游真实产出的 `dashboard.spec.json` 用的是 ②的形状**（见 `super_partyb`
///   `apps/miniapp/src/lib/spec-demo-fixtures.ts` 的 `realDashboardDoc`，注释自称
///   「bcc 工作区实际产出的 dashboard.spec.json 回归基准」，里面是
///   `Stack`/`Grid`/`Metric`/`Chart`/`Alert`/`Table` 的 `root`/`elements` 结构）——
///   **不是** ①的网格格式。网格格式**无已知生产者**，故不做。
///
/// ## 由此暴露的真实缺陷（issue #27，**已修**）
///
/// 上述真实看板**已被本客户端识别为 `spec`**（`resolveTextPreview` 命中），但
/// 渲染结果是**一行「（不支持的组件类型：unknown）」**——因为它的容器类型
/// `Stack` / `Grid` 与叶子 `Chart` / `Table` 都不在本客户端的 12 个白名单里，
/// 而 [SpecUiCard] 的 `unknown` 分支**不递归 children**，于是连白名单内的
/// `Metric`（「上证指数 3864.37」）也一起被吞掉。
///
/// 对照 webapp `JsonUiSchemaRenderer.renderFallback`：它在未知类型时**会**渲染
/// `element.children`（`element.children.length > 0 && renderChildren(...)`）。
/// 故这不是「webapp 也不支持」，而是**本客户端的降级策略比上游更保守**。
///
/// 已按该对照修正：未知类型**有子元素时照常下钻**，仅叶子留占位标记，且占位符
/// 打印**原始 type 字符串**（`SpecUiElement.rawType`）而不是塌缩后的 `unknown`。
/// 同一份真实看板的可见文本从 `[（不支持的组件类型：unknown）]` 变为
/// `[上证指数, 3864.37, …]`。
///
/// 识别不出来时**一律退化为 `text`**（见 [resolveTextPreview]），而不是假装
/// 识别出来推给 `external`——后者会让用户从「能看原文」退化成「跳出去」。
library;

import 'dart:convert';

import 'map_schema.dart';
import 'spec_ui.dart';

/// 尝试把整段文本解析成 JSON（失败返回 null）。
///
/// **只解析顶层**，不做「从字符串里抠 JSON」的猜测（那是
/// [extractSpecSchemaFromUnknown] 的职责，用于**嵌套** schema）。
/// map spec 是顶层格式，故这里只认「整段就是一份 JSON」。
Object? _tryDecodeJson(String content) {
  final trimmed = content.trim();
  // 快速排除：非 `{`/`[` 开头的不可能是 JSON 对象/数组（省一次异常）。
  if (trimmed.isEmpty || (trimmed[0] != '{' && trimmed[0] != '[')) return null;
  try {
    return jsonDecode(trimmed);
  } on Object {
    return null;
  }
}

/// 预览形态。三态即本轮全部能力（见库文档的六类对照表）。
enum FilePreviewKind {
  /// 内联展示文本内容（数据型文本 + 源码，见 [isInlineTextPreviewable]）。
  text,

  /// 内联展示图片（缩略图或原图字节 → `Image.memory`）。
  image,

  /// 无法内联：交给 UFS 的预览页（由 app 层拼 URL 并打开）。
  external,
}

/// 文本预览的字符上限（约 200 KB 的 UTF-16 码元）。
///
/// ## 为什么需要上限
///
/// 一次 turn 可能产出数 MB 的日志/JSON。把整串塞进 `Text` 会让首帧布局耗时
/// 到秒级（`TextPainter` 要整段测量）。上限保证对话框**必然**能开。
///
/// ## 为什么不是「静默截断」
///
/// 静默截断是最坏的形态：用户看到一份「完整的」报告，实际少了后面一半，而
/// 界面上没有任何迹象。故 [buildTextPreview] 会带上 [TextPreview.truncated]
/// 与原始长度，UI **必须**据此给出明确提示（见 `showAgentFilePreview`）。
const int kTextPreviewMaxChars = 200 * 1024;

/// 图片扩展名（对齐 webapp `IMAGE_FILE_EXTENSIONS`）。
///
/// 含 `.svg`：`image/svg+xml` 的 mime 已命中 `image/` 前缀，但有些服务端把
/// svg 报成 `text/plain` 或空 mime，故按扩展名兜一层。
const Set<String> _imageExtensions = {
  '.apng',
  '.avif',
  '.bmp',
  '.gif',
  '.ico',
  '.jpg',
  '.jpeg',
  '.png',
  '.svg',
  '.webp',
};

/// 可内联的数据型文本 MIME（对齐 webapp `INLINE_TEXT_MIME_TYPES`）。
///
/// ⚠️ 这里**只放数据/源码**，不含 `text/html`、`text/css`、`image/svg+xml`
/// ——webapp 明确把这些 markup/样式文件排除在内联之外（结构渲染易乱、
/// CSS 单独看无意义），统一跳 UFS 预览页。
const Set<String> _inlineTextMimeTypes = {
  'application/json',
  'application/ld+json',
  'application/manifest+json',
  'application/x-ndjson',
  'application/sql',
  'application/toml',
  'application/x-yaml',
  'application/yaml',
  'application/x-sh',
  'application/javascript',
  'application/x-javascript',
  'application/typescript',
};

/// 可内联的文本扩展名（对齐 webapp `INLINE_TEXT_FILE_EXTENSIONS`）。
const Set<String> _inlineTextExtensions = {
  '.txt',
  '.log',
  '.csv',
  '.md',
  '.mdx',
  '.yaml',
  '.yml',
  '.toml',
  '.json',
  '.jsonl',
  '.py',
  '.ts',
  '.tsx',
  '.js',
  '.jsx',
  '.mjs',
  '.cjs',
  '.go',
  '.rs',
  '.java',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.cs',
  '.rb',
  '.sh',
  '.bash',
  '.zsh',
  '.sql',
};

/// 归一化 MIME：去掉 `;charset=…` 参数、去空白、转小写。
///
/// 与 webapp `normalizeMimeType` 同义。服务端常返回
/// `text/markdown; charset=utf-8`，不剥参数会让集合查找全部落空。
String normalizeMimeType(String? value) {
  final raw = value ?? '';
  final semi = raw.indexOf(';');
  final head = semi >= 0 ? raw.substring(0, semi) : raw;
  return head.trim().toLowerCase();
}

/// 路径/文件名的扩展名（小写，含点）。无扩展名返回空串。
///
/// 与 webapp `getFileExtension` 同义：先剥 `?query` / `#fragment`，
/// 再取最后一个点之后的部分；点在最后一段斜杠之前时视为无扩展名。
String fileExtensionOf(String value) {
  final normalized = value.split('?').first.split('#').first;
  final lastSlash = normalized.lastIndexOf('/');
  final lastDot = normalized.lastIndexOf('.');
  if (lastDot <= lastSlash) return '';
  return normalized.substring(lastDot).toLowerCase();
}

/// 一个文件名的**全部**候选扩展名（对齐 webapp `getFileExtensions`）。
///
/// ## 为什么不止一个
///
/// 复合扩展名要能同时命中两段：`config.env.example` 的候选是
/// `.example`（末段）与 `.env.example`（首段起）——webapp 的文本白名单里有
/// `.env.example`，只取末段会漏掉。
///
/// 规则（照抄 webapp）：
/// - 末段（最后一个点起）——总是候选；
/// - 首段（第一个点起），当它与末段不同；
/// - 隐藏文件（首个字符就是点，如 `.gitignore`）——整名作为候选。
List<String> fileExtensionsOf(String value) {
  final normalized = value.split('?').first.split('#').first;
  final lastSlash = normalized.lastIndexOf('/');
  final fileName = normalized.substring(lastSlash + 1);
  final firstDot = fileName.indexOf('.');
  final lastDot = fileName.lastIndexOf('.');

  final out = <String>[];
  if (lastDot > 0) out.add(fileName.substring(lastDot).toLowerCase());
  if (firstDot > 0 && firstDot != lastDot) {
    out.add(fileName.substring(firstDot).toLowerCase());
  }
  if (firstDot == 0 && lastDot > 0) out.add(fileName.toLowerCase());
  return out;
}

/// 是否为图片（mime 前缀 `image/`，或扩展名命中 [._imageExtensions]）。
bool isImagePreviewable({String? mimeType, required String fileName}) {
  if (normalizeMimeType(mimeType).startsWith('image/')) return true;
  final name = fileName.toLowerCase();
  return fileExtensionsOf(name).any(_imageExtensions.contains);
}

/// 是否可**内联**为文本（数据型文本 + 源码；不含 html/css/svg/xml）。
///
/// 判据顺序（对齐 webapp `isInlinePreviewableFile`）：
/// 1. `text/*`，但排除 `text/html` 与 `text/css`；
/// 2. 数据型 MIME 白名单；
/// 3. `+json` / `+yaml` 后缀（如 `application/vnd.foo+json`）；
/// 4. 扩展名白名单。
bool isInlineTextPreviewable({String? mimeType, required String fileName}) {
  final mime = normalizeMimeType(mimeType);

  if (mime.startsWith('text/')) {
    // markup / 样式不内联（与 webapp 同判据）。`image/svg+xml` 不在此分支，
    // 它由 [isImagePreviewable] 归为 image。
    if (mime == 'text/html' || mime == 'text/css') return false;
    return true;
  }
  if (_inlineTextMimeTypes.contains(mime)) return true;
  if (mime.endsWith('+json') || mime.endsWith('+yaml')) return true;

  final name = fileName.toLowerCase();
  return fileExtensionsOf(name).any(_inlineTextExtensions.contains);
}

/// Markdown 的 MIME 白名单（判定是否用 Markdown 渲染器呈现文本）。
const Set<String> _markdownMimeTypes = {'text/markdown', 'text/x-markdown'};

/// Markdown 扩展名（小写，含点）。
///
/// 必须与 [_inlineTextExtensions] 的 Markdown 项**保持一致**：`.markdown` 不在
/// 文本白名单里（对齐 webapp `INLINE_TEXT_FILE_EXTENSIONS`），故也不能在这里——
/// 否则会出现「判为 Markdown 渲染但压根走不到 text 分支」的死项。
const Set<String> _markdownExtensions = {'.md', '.mdx'};

/// 是否应以 **Markdown 渲染**（而不是等宽纯文本）呈现该文本内容。
///
/// ## 为什么是独立函数而不是并进 [isInlineTextPreviewable]
///
/// 两者判的是不同问题：[isInlineTextPreviewable] 答「能不能内联看」，本函数答
/// 「看的时候用什么渲染器」。`.md` 两者都命中，但 `.txt` 只命中前者——若合并，
/// 就再也分不出该用哪种渲染方式。
///
/// ## 为什么判 mime **或**扩展名
///
/// 服务端报的 mime 常是通用的 `text/plain`（尤其 UFS 上传时未探测），此时只能
/// 靠扩展名。反之扩展名可能被剥（无后缀的下载），此时只能靠 mime。任一命中即可。
///
/// 与 webapp `WorkbenchFeed.tsx` 对 `text` 预览一律走 `MarkdownRenderer` 的做法
/// **不完全相同**：webapp 是无条件 Markdown 渲染，客户端保留等宽纯文本分支——
/// 对 `.log` / `.csv` 这类内容，Markdown 渲染会把 `#`、`*` 当语法吃掉，反而不如
/// 纯文本忠实。故只在确实声明是 Markdown 时才切渲染器。
bool isMarkdownTextPreview({String? mimeType, required String fileName}) {
  if (_markdownMimeTypes.contains(normalizeMimeType(mimeType))) return true;
  return fileExtensionsOf(fileName.toLowerCase())
      .any(_markdownExtensions.contains);
}

/// 判定预览形态。**这是本轮对外的唯一入口。**
///
/// 顺序即语义（对齐 webapp `loadAgentFilePreview`）：
/// 1. 图片 → [FilePreviewKind.image]；
/// 2. 可内联文本 → [FilePreviewKind.text]；
/// 3. 其余（PDF / Office / 压缩包 / html / css / 未知二进制）→
///    [FilePreviewKind.external]。
///
/// ## 为什么「其余」是 external 而不是「不支持」
///
/// webapp 的取舍：不认识的类型不报错，而是把用户送到 UFS 预览页——那里能渲染
/// PDF、Office 等。报错等于「这个文件你永远看不到内容」；跳转至少留了出路。
/// 这也满足 issue 的验收项「不认识的类型 → 退化到外部跳转，不报错」。
FilePreviewKind resolvePreviewKind({
  String? mimeType,
  required String fileName,
  String? relativePath,
}) {
  // 用 relativePath 优先（含扩展名更完整，如 `a/b/config.env.example`）；
  // 为空时退回 fileName。webapp 用的是 `file.path || file.name`。
  final pathForExt = (relativePath == null || relativePath.isEmpty)
      ? fileName
      : relativePath;

  if (isImagePreviewable(mimeType: mimeType, fileName: pathForExt)) {
    return FilePreviewKind.image;
  }
  if (isInlineTextPreviewable(mimeType: mimeType, fileName: pathForExt)) {
    return FilePreviewKind.text;
  }
  return FilePreviewKind.external;
}

/// 文本内容层判定的结果：原文，或识别出的 spec 文档。
///
/// ## 为什么不是给 [FilePreviewKind] 加一个 `spec` 值
///
/// [resolvePreviewKind] 判的是 **mime / 扩展名**（这个文件是什么格式），
/// 本类型判的是**内容**（这段字节里装的是什么）。两者是不同维度：一个
/// `.json` 文件既可能是 spec 也可能只是一份配置。塞进同一枚举会让
/// [resolvePreviewKind] 的穷尽 switch 也被迫处理 spec，语义错位。
///
/// ## 为什么是 sealed 而不是「nullable 字段」
///
/// 调用方（预览对话框）必须对两种形态**都**给出渲染分支，且两者互斥。
/// sealed + 穷尽 switch 让「将来新增一种形态」变成编译错误，而不是运行时空白。
sealed class TextPreviewPayload {
  const TextPreviewPayload();
}

/// 原文呈现（spec 识别失败时的**唯一**出路）。
final class PlainTextPreview extends TextPreviewPayload {
  const PlainTextPreview(this.text);

  /// 已裁剪的原文（见 [buildTextPreview]）。
  final TextPreview text;
}

/// spec 结构化呈现（交给 `SpecUiCard`）。
final class SpecTextPreview extends TextPreviewPayload {
  const SpecTextPreview(this.doc);

  /// 已解析的文档。构造时保证 `doc.root != null`（见 [resolveTextPreview]）。
  final SpecUiDocument doc;
}

/// map spec 呈现（交给 `MapSpecCard`，issue #12 的 `map` 项）。
///
/// 与 [SpecTextPreview] 并列而非「塞进 spec」：map 是**顶层 `type: "map"` +
/// `markers`/`routes`** 的独立格式（见 [MapSchema]），与 `{root, elements}`
/// 树形 UI 不兼容。webapp 也是两个并列分支（`MapSchemaRenderer` /
/// `JsonUiSchemaRenderer`）。
final class MapTextPreview extends TextPreviewPayload {
  const MapTextPreview(this.schema);

  /// 已解析的文档。构造时保证 [MapSchema.isRenderable]（见 [resolveTextPreview]）。
  final MapSchema schema;
}

/// 内容层判定：把解码后的文本分成「map 文档」「spec 文档」或「原文」。
///
/// 对齐 webapp `file-preview.ts` 的 `resolveTextPreview`（含 map 分支；
/// dashboard 仍不做——网格格式无已知生产者，见库文档）。
///
/// ## 判定顺序（与 webapp 一致：map → spec）
///
/// map 先判：它的特征最明确（顶层 `type: "map"` + 坐标），且
/// [parseMapSchema] **只认顶层**、不做深度下探（见其文档）。反过来的话，
/// 一份含 `{type:'map'}` 字段的 spec 会被 [extractSpecSchemaFromUnknown]
/// 的深度扫描先抢走。
///
/// ## 识别失败必须退回原文
///
/// ⚠️ 这是本函数的**硬约束**：解析失败绝不能变成空白对话框。
/// `SpecUiCard` 在 `doc` 为 null 或 `root` 悬空时渲染 `SizedBox.shrink()`，
/// 用户看到的是空对话框——比原文差得多。故这里只在 `root` 确实存在时返回
/// [SpecTextPreview]（[extractSpecSchemaFromUnknown] 已校验），map 只在
/// [MapSchema.isRenderable] 时返回 [MapTextPreview]。
///
/// ## 为什么识别失败不退 `external`
///
/// 那会让 JSON 文件从「能看原文」退化成「跳 UFS 预览页」——比识别不出来更差。
TextPreviewPayload resolveTextPreview(String content) {
  // 顶层 JSON 解析失败 → 原文（map 是顶层格式，必须先有可解析的 JSON）。
  final decoded = _tryDecodeJson(content);
  if (decoded != null) {
    final map = parseMapSchema(decoded);
    if (map != null && map.isRenderable) return MapTextPreview(map);
  }

  final schema = extractSpecSchemaFromUnknown(content);
  if (schema != null) {
    final doc = parseSpecUi(schema);
    // `root != null`：悬空 root 会让 SpecUiCard 渲染空对话框，不如给原文。
    if (doc != null && doc.root != null) return SpecTextPreview(doc);
  }
  return PlainTextPreview(buildTextPreview(content));
}

/// 从字符串里抽取 schema 时，扫描的字符上限。
///
/// 与 [kTextPreviewMaxChars] 同值：超过这个长度时深度遍历一个巨型 JSON
/// 只是白烧 CPU（用户的注意力也不在末尾）。webapp 用独立的
/// `MAX_JSON_SCAN_CHARS = 120_000`；此处复用文本上限，避免多一个需要单独
/// 解释的常量。
const int _kSpecScanMaxChars = kTextPreviewMaxChars;

/// 提取 schema 时的深度上限（对齐 webapp `extractSchemaFromUnknown`）。
const int _kSpecExtractMaxDepth = 5;

/// 优先尝试的键（对齐 webapp 的 `priorityKeys`）。
///
/// 命中顺序即优先级：先试这些语义明确的容器键，未命中再遍历其余键
/// （覆盖嵌套在自定义字段下的 schema）。
const List<String> _specPriorityKeys = [
  'schema',
  'ui_schema',
  'uiSchema',
  'json',
  'data',
  'result',
  'output',
  'content',
  'text',
  'value',
];

/// 从任意 JSON 值里深度下探，提取 `{root, elements}` 形状的 spec schema。
///
/// 对齐 webapp `json-ui-schema.ts` 的 `extractSchemaFromUnknown`。返回**原始
/// Map**（而非 [SpecUiDocument]），以便与 [parseSpecUi] 的输入形态一致。
///
/// ## 判定顺序
///
/// 1. `depth > 5` 或 null → 放弃（防止损坏数据导致无限下探）；
/// 2. 字符串 → 抽 JSON 候选（整体 / ```json 围栏 / 首尾大括号切片），逐个递归；
/// 3. 数组 → 逐项递归（取第一个命中的）；
/// 4. 当前值本身是合法 schema → 返回；
/// 5. 按 [_specPriorityKeys] 递归；
/// 6. 遍历其余键递归。
///
/// ## 「合法 schema」的判据
///
/// 必须能通过 [parseSpecUi]，**且** `elements[root]` 存在。后者是对齐 webapp
/// 的关键：`parseSpecUi` 容忍悬空 root（返回 document 但 `root` 为 null），
/// 而那样的 document 交给 `SpecUiCard` 会渲染成空对话框——比原文更差。
Map<String, Object?>? extractSpecSchemaFromUnknown(
  Object? value, {
  int depth = 0,
}) {
  if (depth > _kSpecExtractMaxDepth || value == null) return null;

  if (value is String) {
    for (final candidate in _jsonCandidatesFromString(value)) {
      final schema = extractSpecSchemaFromUnknown(candidate, depth: depth + 1);
      if (schema != null) return schema;
    }
    return null;
  }

  if (value is List) {
    for (final item in value) {
      final schema = extractSpecSchemaFromUnknown(item, depth: depth + 1);
      if (schema != null) return schema;
    }
    return null;
  }

  final direct = _normalizeSpecSchema(value);
  if (direct != null) return direct;

  if (value is Map) {
    for (final key in _specPriorityKeys) {
      if (!value.containsKey(key)) continue;
      final schema = extractSpecSchemaFromUnknown(value[key], depth: depth + 1);
      if (schema != null) return schema;
    }
    for (final key in value.keys) {
      if (_specPriorityKeys.contains(key)) continue;
      final schema = extractSpecSchemaFromUnknown(value[key], depth: depth + 1);
      if (schema != null) return schema;
    }
  }

  return null;
}

/// 当前值是否本身就是一个合法 schema；是则返回其 `Map<String, Object?>` 形态。
Map<String, Object?>? _normalizeSpecSchema(Object? candidate) {
  if (candidate is! Map) return null;
  final doc = parseSpecUi(candidate);
  // 悬空 root 不算命中（见 extractSpecSchemaFromUnknown 的说明）。
  if (doc == null || doc.root == null) return null;
  return candidate.map((key, value) => MapEntry(key.toString(), value));
}

/// 从字符串里抽取可能的 JSON 候选（对齐 webapp `extractJsonCandidatesFromString`）。
///
/// 三种来源，按可靠性排序：
/// 1. 整串就是一个 JSON；
/// 2. Markdown 围栏 ```json ... ``` 里的内容（LLM 产出常见）；
/// 3. 首尾大括号之间的切片（前后夹了说明文字时）。
List<Object?> _jsonCandidatesFromString(String value) {
  final text = value.trim();
  if (text.isEmpty) return const [];

  final clipped = text.length > _kSpecScanMaxChars
      ? text.substring(0, _kSpecScanMaxChars)
      : text;
  final candidates = <Object?>[];

  final direct = _tryParseJson(clipped);
  if (direct != null) candidates.add(direct);

  for (final match in _fencedJsonPattern.allMatches(clipped)) {
    final inner = (match.group(1) ?? '').trim();
    final parsed = _tryParseJson(inner);
    if (parsed != null) candidates.add(parsed);
  }

  final firstBrace = clipped.indexOf('{');
  final lastBrace = clipped.lastIndexOf('}');
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    final parsed = _tryParseJson(clipped.substring(firstBrace, lastBrace + 1));
    if (parsed != null) candidates.add(parsed);
  }

  return candidates;
}

/// ```json ... ``` 围栏（大小写不敏感，`json` 标记可省）。
final RegExp _fencedJsonPattern = RegExp(
  r'```(?:json)?\s*([\s\S]*?)```',
  caseSensitive: false,
);

/// JSON 解析，失败返回 null（**不抛异常**：候选里混着非 JSON 是常态）。
Object? _tryParseJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// 文本预览的裁剪结果。
///
/// [truncated] 必须被 UI 消费（给出「已截断，仅显示前 N 字符」之类的提示）。
/// 这正是 issue 要求的「大文本截断且有明确提示，不静默截断」——把提示责任
/// 放在数据上，而不是靠调用方记得。
class TextPreview {
  const TextPreview({
    required this.content,
    required this.truncated,
    required this.originalLength,
  });

  /// 实际展示的文本（已裁剪到 [kTextPreviewMaxChars] 以内）。
  final String content;

  /// true = 原文更长，[content] 只是前缀。
  final bool truncated;

  /// 原始字符数（未截断时等于 `content.length`）。
  ///
  /// 用于提示里的「共 N 字符」——只说「已截断」而不说原始规模，
  /// 用户无法判断是漏了一行还是漏了 10 万行。
  final int originalLength;

  /// 被丢弃的字符数（未截断时为 0）。
  int get omittedLength => originalLength - content.length;
}

/// 把解码后的文本裁到 [kTextPreviewMaxChars]，并标记是否截断。
///
/// 调用方负责先把字节解码成字符串（用 `utf8.decode(bytes, allowMalformed: true)`，
/// 否则遇到非法 UTF-8 会抛异常而不是退化为可读内容）。
///
/// ## 为什么截断发生在解码之后
///
/// 字节级截断会切碎多字节字符（UTF-8 一个汉字 3 字节），得到一个尾部的替换
/// 字符。字符级截断虽然省不了下载流量（`UfsApi.download` 返回完整字节），
/// 但保证显示内容干净。省流量需要 `Range` 请求，那是 `UfsApi` 的改动，
/// 不在本 issue 范围。
TextPreview buildTextPreview(
  String content, {
  int maxChars = kTextPreviewMaxChars,
}) {
  final limit = maxChars <= 0 ? kTextPreviewMaxChars : maxChars;
  if (content.length <= limit) {
    return TextPreview(
      content: content,
      truncated: false,
      originalLength: content.length,
    );
  }
  return TextPreview(
    content: content.substring(0, limit),
    truncated: true,
    originalLength: content.length,
  );
}
