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
/// | `text` | ✅ 本轮实现 |
/// | `image` | ✅ 本轮实现 |
/// | `external`（跳 UFS 预览页） | ✅ 本轮实现 |
/// | `spec` / `dashboard` / `map` | ❌ **需 JSON 结构化渲染器，本轮有意不做** |
///
/// 后三类需要仪表盘 / 地图 / 结构化表单这类重型渲染组件，且要先决定
/// 「是否引入 JSON 结构化渲染器」——那是 issue #12 的决策点，**不属于本 issue**。
/// 故本轮对 JSON 内容**一律退化为 `text`**（见 [resolveTextPreviewKind]），
/// 而不是假装识别不出来（那样会把它推给 `external`，用户反而看不到内容）。
library;

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

/// 内容层判定：文本内容的**呈现形态**。
///
/// ## 本轮恒为 [FilePreviewKind.text]（有意为之）
///
/// webapp 的 `resolveTextPreview` 会尝试 JSON 解析并依次识别地图 →
/// 仪表盘 → 通用结构化表单 schema，命中则交给对应渲染器。
/// 本客户端**没有**这些渲染器（见库文档的六类对照表），故本轮一律返回
/// `text`——把 JSON 原样展示给用户。
///
/// ## 为什么保留这个函数而不是直接写死 text
///
/// 它把「内容层判定」这个**扩展点**显式留在代码里：将来接入 JSON 结构化渲染器时，
/// 改动落在这一个函数内（返回值扩展为结构化表单 / 仪表盘 / 地图），调用方与类型判定的
/// 上层逻辑都不用动。若现在不写，接线的人得重新推导「判定链该在哪一层」。
///
/// ⚠️ **不要**在没有渲染器的情况下让它返回 `external`：那会让 JSON 文件从
/// 「能看原文」退化成「跳到 UFS 预览页」——比现在更差。
FilePreviewKind resolveTextPreviewKind(String content) {
  // 预留：JSON.parse → 地图 schema → 仪表盘 schema → 通用结构化表单 schema。
  // 本轮无渲染器，故无论内容是什么都按纯文本呈现。
  return FilePreviewKind.text;
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
