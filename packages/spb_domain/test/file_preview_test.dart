import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 文件预览类型判定（`resolvePreviewKind` / `buildTextPreview`）测试。
///
/// ## 这个测试防的是什么
///
/// 判定错了不会报错、不会崩——只是**用错误的方式展示文件**：
///
/// - 把 `text/html` 当内联文本 → 用户看到一坨标签（webapp 明确排除 markup）；
/// - 把二进制当文本 → 满屏乱码（比「跳到 UFS 预览页」更糟）；
/// - 漏判图片 → 图片永远走 external，用户要跳出去才能看图；
/// - 大文本静默截断 → 用户以为报告是完整的，实际少了一半。
///
/// 口径真源是 webapp `lib/api/file-service.ts` 的 `isInlinePreviewableFile` /
/// `isImageFile` 与 `lib/workbench/file-preview.ts` 的 `loadAgentFilePreview`。
/// 三端（webapp / 小程序 / 客户端）必须一致。
void main() {
  group('归一化工具', () {
    test('normalizeMimeType 剥掉 charset 参数并转小写', () {
      expect(
        normalizeMimeType('text/markdown; charset=utf-8'),
        'text/markdown',
      );
      expect(normalizeMimeType('  Application/JSON  '), 'application/json');
      expect(normalizeMimeType(null), '');
      expect(normalizeMimeType(''), '');
    });

    test('fileExtensionOf 取末段扩展名（剥 query/fragment）', () {
      expect(fileExtensionOf('a/b/report.MD'), '.md');
      expect(fileExtensionOf('a/b/archive.tar.gz'), '.gz');
      expect(fileExtensionOf('noext'), '');
      expect(fileExtensionOf('a.b/c'), '', reason: '点在最后一段斜杠之前 → 无扩展名');
      expect(fileExtensionOf('x.png?v=2'), '.png');
      expect(fileExtensionOf('x.png#frag'), '.png');
    });

    test('fileExtensionsOf 给出全部候选扩展名（复合扩展名）', () {
      expect(fileExtensionsOf('config.env.example'), [
        '.example',
        '.env.example',
      ]);
      expect(fileExtensionsOf('a/b/simple.md'), ['.md']);
      expect(fileExtensionsOf('archive.tar.gz'), ['.gz', '.tar.gz']);
      // 隐藏文件（整名以点开头）：webapp 的 getFileExtensions 返回**空**——
      // 它的首段规则要求 `lastDot > 0`，而 `.gitignore` 的 lastDot 就是 0。
      // 故 `.gitignore` 不靠扩展名判定，只能靠 mime 或「不在白名单 → external」。
      expect(fileExtensionsOf('.gitignore'), isEmpty);
      expect(fileExtensionsOf('a/b/.env'), isEmpty);
    });
  });

  group('resolvePreviewKind：text / image / external 判定表', () {
    // 表驱动：(描述, mime, fileName, relativePath, 期望 kind)
    final cases = <(String, String?, String, String?, FilePreviewKind)>[
      // ---- image ----
      ('png 按 mime', 'image/png', 'a.png', 'out/a.png', FilePreviewKind.image),
      ('jpeg 按 mime', 'image/jpeg', 'a.jpg', null, FilePreviewKind.image),
      // svg **不是** image（2026-11，参考小程序）：Flutter 无 svg 解码器，
      // 且它是主动内容，走预览会话。详见下方「判定顺序」组的说明。
      ('svg 按 mime', 'image/svg+xml', 'a.svg', null, FilePreviewKind.external),
      ('mime 缺失但扩展名是图片', null, 'a.png', null, FilePreviewKind.image),
      (
        'mime 是 octet-stream 但扩展名是图片',
        'application/octet-stream',
        'a.webp',
        null,
        FilePreviewKind.image,
      ),
      (
        'mime 带参数',
        'image/png; charset=binary',
        'a.png',
        null,
        FilePreviewKind.image,
      ),
      ('扩展名大写', null, 'A.PNG', null, FilePreviewKind.image),

      // ---- text：text/* 前缀 ----
      ('text/plain', 'text/plain', 'notes', null, FilePreviewKind.text),
      (
        'text/markdown',
        'text/markdown; charset=utf-8',
        'a.md',
        null,
        FilePreviewKind.text,
      ),
      ('text/csv', 'text/csv', 'a.csv', null, FilePreviewKind.text),
      ('text/x-python', 'text/x-python', 'a.py', null, FilePreviewKind.text),

      // ---- text：数据型 MIME 白名单 ----
      (
        'application/json',
        'application/json',
        'a.json',
        null,
        FilePreviewKind.text,
      ),
      (
        'application/x-ndjson',
        'application/x-ndjson',
        'a.jsonl',
        null,
        FilePreviewKind.text,
      ),
      (
        'application/x-yaml',
        'application/x-yaml',
        'a.yaml',
        null,
        FilePreviewKind.text,
      ),
      (
        'application/toml',
        'application/toml',
        'a.toml',
        null,
        FilePreviewKind.text,
      ),
      (
        'application/sql',
        'application/sql',
        'a.sql',
        null,
        FilePreviewKind.text,
      ),
      (
        'application/javascript',
        'application/javascript',
        'a.js',
        null,
        FilePreviewKind.text,
      ),
      ('+json 后缀', 'application/vnd.api+json', 'a', null, FilePreviewKind.text),
      ('+yaml 后缀', 'application/vnd.foo+yaml', 'a', null, FilePreviewKind.text),

      // ---- text：扩展名白名单（mime 不可信时兜底）----
      ('无 mime 但 .go', null, 'main.go', null, FilePreviewKind.text),
      ('无 mime 但 .md', null, 'README.md', null, FilePreviewKind.text),
      (
        'octet-stream 但 .ts',
        'application/octet-stream',
        'a.ts',
        null,
        FilePreviewKind.text,
      ),
      (
        '用 relativePath 判扩展名',
        'application/octet-stream',
        'noext',
        'out/a.py',
        FilePreviewKind.text,
      ),
      // `.env.example` 在 webapp 的**宽**白名单（TEXT_PREVIEW_FILE_EXTENSIONS，
      // 供 Workbench 文档面板用）里，但**不在内联白名单**里——故时间线里
      // 它走 external。这里刻意与 webapp 的内联口径保持一致。
      (
        'octet-stream 但 .env.example → external（不在内联白名单）',
        'application/octet-stream',
        'config.env.example',
        null,
        FilePreviewKind.external,
      ),
      (
        '用 relativePath 判扩展名',
        'application/octet-stream',
        'noext',
        'out/a.py',
        FilePreviewKind.text,
      ),

      // ---- external：markup / 样式（webapp 明确不内联）----
      ('text/html 不内联', 'text/html', 'a.html', null, FilePreviewKind.external),
      ('text/css 不内联', 'text/css', 'a.css', null, FilePreviewKind.external),
      (
        '无 mime 但 .html（不在内联扩展名表）',
        null,
        'a.html',
        null,
        FilePreviewKind.external,
      ),
      ('无 mime 但 .css', null, 'a.css', null, FilePreviewKind.external),
      (
        'application/xml（非 +xml 后缀）',
        'application/xml',
        'a.xml',
        null,
        FilePreviewKind.external,
      ),
      // 隐藏文件：扩展名候选为空 → 既非图片也非内联文本 → external。
      (
        '无 mime 的 .gitignore',
        null,
        '.gitignore',
        null,
        FilePreviewKind.external,
      ),
      ('无 mime 的 .env', null, '.env', null, FilePreviewKind.external),

      // ---- external：二进制 / Office / 压缩包 ----
      ('pdf', 'application/pdf', 'a.pdf', null, FilePreviewKind.external),
      (
        'docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'a.docx',
        null,
        FilePreviewKind.external,
      ),
      ('zip', 'application/zip', 'a.zip', null, FilePreviewKind.external),
      (
        'octet-stream 无扩展名',
        'application/octet-stream',
        'blob',
        null,
        FilePreviewKind.external,
      ),
      (
        '未知类型',
        'application/x-weird',
        'a.weird',
        null,
        FilePreviewKind.external,
      ),
      ('视频', 'video/mp4', 'a.mp4', null, FilePreviewKind.external),
      ('音频', 'audio/mpeg', 'a.mp3', null, FilePreviewKind.external),
    ];

    for (final (desc, mime, name, rel, expected) in cases) {
      test('$desc → ${expected.name}', () {
        expect(
          resolvePreviewKind(mimeType: mime, fileName: name, relativePath: rel),
          expected,
        );
      });
    }
  });

  group('判定顺序：image 优先于 text', () {
    test('image/svg+xml 归 external（Flutter 解不了 SVG，走预览会话）', () {
      // 2026-11 改动（参考小程序）：SVG 不再是 image。
      // 理由两条：Flutter 的 Image.memory 没有 svg 解码器（判成 image 只会拿到
      // 「图片加载失败」）；SVG 是可携带脚本的主动内容，小程序也把它送 UFS
      // 独立预览域（preview.ts 的 isSvgFile 分支）。
      expect(
        resolvePreviewKind(mimeType: 'image/svg+xml', fileName: 'a.svg'),
        FilePreviewKind.external,
      );
      expect(
        resolveExternalPreviewChannel(
          mimeType: 'image/svg+xml',
          fileName: 'a.svg',
        ),
        ExternalPreviewChannel.htmlSession,
      );
    });

    test('扩展名是 svg 但 mime 是 text/plain → external + htmlSession', () {
      // 服务端偶尔把 svg 报成 text/plain；无论按 mime 还是扩展名，都不能
      // 落到 text（用户看到的是一坨 XML）也不能落到 mediaAccess（401/403）。
      expect(
        resolvePreviewKind(mimeType: 'text/plain', fileName: 'icon.svg'),
        FilePreviewKind.external,
      );
      expect(
        resolveExternalPreviewChannel(
          mimeType: 'text/plain',
          fileName: 'icon.svg',
        ),
        ExternalPreviewChannel.htmlSession,
      );
    });
  });

  group('resolveExternalPreviewChannel：external 的三条物理通道', () {
    // 判据镜像小程序 `previewMode()`（super_partyb apps/go-api miniapp_artifacts.go）。
    final cases = <(String, String?, String, ExternalPreviewChannel)>[
      // 主动内容 → 一次性预览会话
      (
        'html mime',
        'text/html',
        'index.html',
        ExternalPreviewChannel.htmlSession,
      ),
      (
        'xhtml mime',
        'application/xhtml+xml',
        'a.xhtml',
        ExternalPreviewChannel.htmlSession,
      ),
      (
        'html 扩展名 + 错 mime',
        'application/octet-stream',
        'page.html',
        ExternalPreviewChannel.htmlSession,
      ),
      (
        'svg mime',
        'image/svg+xml',
        'a.svg',
        ExternalPreviewChannel.htmlSession,
      ),
      ('svgz 扩展名', null, 'a.svgz', ExternalPreviewChannel.htmlSession),
      // 媒体签名 URL
      (
        'pdf mime',
        'application/pdf',
        'report',
        ExternalPreviewChannel.mediaAccess,
      ),
      (
        'pdf 扩展名',
        'application/octet-stream',
        '报告.pdf',
        ExternalPreviewChannel.mediaAccess,
      ),
      ('视频 mime', 'video/mp4', 'demo', ExternalPreviewChannel.mediaAccess),
      (
        '音频扩展名',
        'application/octet-stream',
        'voice.mp3',
        ExternalPreviewChannel.mediaAccess,
      ),
      (
        '图片扩展名 + 错 mime',
        'text/plain',
        'shot.png',
        ExternalPreviewChannel.mediaAccess,
      ),
      // 其余 → 旧预览页
      (
        'docx',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'a.docx',
        ExternalPreviewChannel.legacyPreviewPage,
      ),
      (
        'zip',
        'application/zip',
        'a.zip',
        ExternalPreviewChannel.legacyPreviewPage,
      ),
      (
        '未知二进制',
        'application/octet-stream',
        'blob',
        ExternalPreviewChannel.legacyPreviewPage,
      ),
      (
        'css（非主动内容但也不内联）',
        'text/css',
        'a.css',
        ExternalPreviewChannel.legacyPreviewPage,
      ),
    ];
    for (final (desc, mime, name, expected) in cases) {
      test(desc, () {
        expect(
          resolveExternalPreviewChannel(mimeType: mime, fileName: name),
          expected,
        );
      });
    }

    test('Office 文档不能走 mediaAccess（UFS isMediaMime 只放行 pdf/图像/音视频）', () {
      // 走 mediaAccess 会拿到 415「该文件类型不支持媒体访问」——那是把
      // 「本可以打开的文件」变成一句错误。故 docx/xlsx/pptx 归旧预览页。
      for (final name in ['a.docx', 'a.xlsx', 'a.pptx']) {
        expect(
          resolveExternalPreviewChannel(
            mimeType: 'application/octet-stream',
            fileName: name,
          ),
          ExternalPreviewChannel.legacyPreviewPage,
        );
      }
    });
  });

  group('isMarkdownTextPreview：渲染器选择（Markdown vs 等宽纯文本）', () {
    // 表驱动：(描述, mime, fileName, 期望)
    final cases = <(String, String?, String, bool)>[
      ('md 按扩展名', 'text/plain', 'README.md', true),
      ('mdx 按扩展名', null, 'page.mdx', true),
      ('markdown 扩展名不在文本白名单 → 非 markdown', null, 'doc.markdown', false),
      ('大写扩展名', null, 'README.MD', true),
      ('text/markdown 按 mime', 'text/markdown', 'noext', true),
      ('带 charset 的 mime', 'text/markdown; charset=utf-8', 'noext', true),
      ('text/x-markdown 按 mime', 'text/x-markdown', 'noext', true),
      ('mime 是 text/plain 且无 md 后缀', 'text/plain', 'a.txt', false),
      ('json 不是 markdown', 'application/json', 'a.json', false),
      ('log 不是 markdown', 'text/plain', 'a.log', false),
      ('csv 不是 markdown', 'text/csv', 'a.csv', false),
      ('无扩展名且无 mime', null, 'noext', false),
      ('mime 为 null 时按扩展名兜底', null, 'guide.md', true),
      ('复合扩展名末段命中', null, 'notes.md.bak', false),
    ];

    for (final (desc, mime, name, expected) in cases) {
      test('$desc → $expected', () {
        expect(isMarkdownTextPreview(mimeType: mime, fileName: name), expected);
      });
    }

    test('markdown 必须是可内联文本的子集（否则渲染器选不到）', () {
      // 不变量：能 Markdown 渲染的文件，必然先通过 text 判定。
      // 若两者脱钩，会出现「选了 Markdown 渲染但压根走不到 text 分支」。
      for (final name in ['a.md', 'a.mdx']) {
        expect(
          isInlineTextPreviewable(mimeType: null, fileName: name),
          isTrue,
          reason: '$name 应在文本白名单里',
        );
        expect(isMarkdownTextPreview(mimeType: null, fileName: name), isTrue);
      }
    });
  });

  group('resolveTextPreview：内容层判定（spec 文档 or 原文）', () {
    test('裸 spec schema → SpecTextPreview', () {
      final payload = resolveTextPreview(
        '{"root":"page","elements":{"page":{"type":"page"}}}',
      );
      expect(payload, isA<SpecTextPreview>());
      expect((payload as SpecTextPreview).doc.root?.id, 'page');
    });

    test('嵌套在 content 字段里的 schema 也能识别（深度下探）', () {
      final payload = resolveTextPreview(
        '{"content":"{\\"root\\":\\"r\\",\\"elements\\":{\\"r\\":{\\"type\\":\\"card\\"}}}"}',
      );
      expect(payload, isA<SpecTextPreview>());
    });

    test('markdown 围栏里的 schema 能识别（LLM 产出形态）', () {
      final payload = resolveTextPreview(
        '说明文字\n```json\n{"root":"r","elements":{"r":{"type":"card"}}}\n```\n尾巴',
      );
      expect(payload, isA<SpecTextPreview>());
    });

    test('合法 JSON 但不是 spec → 原文（不退 external）', () {
      final payload = resolveTextPreview('{"a":1}');
      expect(payload, isA<PlainTextPreview>());
      expect((payload as PlainTextPreview).text.content, '{"a":1}');
    });

    test('形似 map / dashboard 的 JSON → 原文（归 issue #12 待决策）', () {
      expect(
        resolveTextPreview('{"type":"map","center":[1,2],"markers":[]}'),
        isA<PlainTextPreview>(),
      );
      expect(
        resolveTextPreview('{"widgets":[{"x":0,"y":0,"w":2,"h":1}]}'),
        isA<PlainTextPreview>(),
      );
    });

    test('悬空 root 的 schema → 原文（空对话框比原文更差）', () {
      // `parseSpecUi` 容忍悬空 root（root 为 null），但那样的文档交给
      // SpecUiCard 会渲染 SizedBox.shrink()——用户看到空白对话框。
      final payload = resolveTextPreview(
        '{"root":"missing","elements":{"other":{"type":"card"}}}',
      );
      expect(payload, isA<PlainTextPreview>());
    });

    test('elements 是 List（旧用例形态）→ 原文', () {
      // 既有用例：`{"root":{"type":"page"},"elements":[]}` 的 elements
      // 是 List，parseSpecUi 本就会返回 null。
      expect(
        resolveTextPreview('{"root":{"type":"page"},"elements":[]}'),
        isA<PlainTextPreview>(),
      );
    });

    test('非 JSON 与空串 → 原文', () {
      expect(resolveTextPreview('hello'), isA<PlainTextPreview>());
      expect(resolveTextPreview(''), isA<PlainTextPreview>());
    });

    test('大文本截断在原文分支仍生效（不静默截断）', () {
      final payload = resolveTextPreview('a' * (kTextPreviewMaxChars + 10));
      expect(payload, isA<PlainTextPreview>());
      final text = (payload as PlainTextPreview).text;
      expect(text.truncated, isTrue);
      expect(text.originalLength, kTextPreviewMaxChars + 10);
    });
  });

  group('extractSpecSchemaFromUnknown：深度下探与边界', () {
    test('直接命中的 schema 原样返回', () {
      final schema = extractSpecSchemaFromUnknown(
        '{"root":"r","elements":{"r":{"type":"card"}}}',
      );
      expect(schema, isNotNull);
      expect(schema!['root'], 'r');
    });

    test('priorityKeys 优先：content 里的 schema 先于其它键被找到', () {
      final schema = extractSpecSchemaFromUnknown(
        '{"other":{"root":"x","elements":{"x":{"type":"card"}}},'
        '"content":{"root":"r","elements":{"r":{"type":"text"}}}}',
      );
      // content 在 priorityKeys 里，other 不在；故应命中 content 的那个。
      expect(schema, isNotNull);
      expect(schema!['root'], 'r');
    });

    test('priorityKeys 未命中时遍历其余键（fallback）', () {
      final schema = extractSpecSchemaFromUnknown(
        '{"customField":{"root":"r","elements":{"r":{"type":"card"}}}}',
      );
      expect(schema, isNotNull);
      expect(schema!['root'], 'r');
    });

    test('数组里逐项下探，取第一个命中的', () {
      final schema = extractSpecSchemaFromUnknown(
        '[{"a":1},{"root":"r","elements":{"r":{"type":"card"}}}]',
      );
      expect(schema, isNotNull);
    });

    test('深度超过 5 截断（第 6 层放弃）', () {
      // 构造 depth=6 的嵌套：每层一个键，最内层才是 schema。
      // depth 从 0 起算，故 6 层包裹后内层 schema 位于 depth=6 > 5 → 放弃。
      Object? nested = '{"root":"r","elements":{"r":{"type":"card"}}}';
      for (var i = 0; i < 6; i++) {
        nested = {'k$i': nested};
      }
      expect(extractSpecSchemaFromUnknown(nested), isNull);
    });

    test('深度 5 以内可达（边界内）', () {
      Object? nested = '{"root":"r","elements":{"r":{"type":"card"}}}';
      for (var i = 0; i < 4; i++) {
        nested = {'k$i': nested};
      }
      expect(extractSpecSchemaFromUnknown(nested), isNotNull);
    });

    test('null 与标量 → null', () {
      expect(extractSpecSchemaFromUnknown(null), isNull);
      expect(extractSpecSchemaFromUnknown(42), isNull);
      expect(extractSpecSchemaFromUnknown(''), isNull);
    });

    test('悬空 root 不算命中', () {
      expect(
        extractSpecSchemaFromUnknown(
          '{"root":"missing","elements":{"x":{"type":"card"}}}',
        ),
        isNull,
      );
    });

    test('围栏与首尾大括号切片两种字符串形态', () {
      expect(
        extractSpecSchemaFromUnknown(
          '前言\n```\n{"root":"r","elements":{"r":{"type":"card"}}}\n```',
        ),
        isNotNull,
      );
      expect(
        extractSpecSchemaFromUnknown(
          '前言 {"root":"r","elements":{"r":{"type":"card"}}} 后语',
        ),
        isNotNull,
      );
    });
  });

  group('buildTextPreview：截断必须可被察觉（不静默截断）', () {
    test('短文本：不截断，原样返回', () {
      final p = buildTextPreview('hello');
      expect(p.content, 'hello');
      expect(p.truncated, isFalse);
      expect(p.originalLength, 5);
      expect(p.omittedLength, 0);
    });

    test('恰好等于上限：不截断（边界）', () {
      final p = buildTextPreview('a' * 100, maxChars: 100);
      expect(p.truncated, isFalse);
      expect(p.content.length, 100);
      expect(p.omittedLength, 0);
    });

    test('超出一个字符：截断且 omittedLength 为 1（边界）', () {
      final p = buildTextPreview('a' * 101, maxChars: 100);
      expect(p.truncated, isTrue);
      expect(p.content.length, 100);
      expect(p.originalLength, 101);
      expect(p.omittedLength, 1);
    });

    test('远超上限：截断到上限，且如实报告原始长度', () {
      // 只报「已截断」而不报规模，用户无法判断是漏了一行还是漏了 10 万行。
      final p = buildTextPreview('x' * 10000, maxChars: 256);
      expect(p.content.length, 256);
      expect(p.truncated, isTrue);
      expect(p.originalLength, 10000);
      expect(p.omittedLength, 9744);
      expect(p.content, 'x' * 256);
    });

    test('默认上限是 kTextPreviewMaxChars', () {
      final p = buildTextPreview('y' * (kTextPreviewMaxChars + 10));
      expect(p.content.length, kTextPreviewMaxChars);
      expect(p.truncated, isTrue);
      expect(p.omittedLength, 10);
    });

    test('非正上限退回默认上限（防止配置写错就展示全量）', () {
      final p = buildTextPreview('z' * 10, maxChars: 0);
      expect(p.truncated, isFalse, reason: '10 字符远小于默认上限');
      expect(buildTextPreview('z' * 10, maxChars: -5).content, 'z' * 10);
    });

    test('多字节字符按码元截断，不会切出半个字符的崩溃', () {
      // 中文按 UTF-16 码元计（每字 1 个码元），截断点落在字符边界上。
      final p = buildTextPreview('中' * 100, maxChars: 50);
      expect(p.content.length, 50);
      expect(p.content.runes.length, 50);
      expect(p.truncated, isTrue);
    });
  });

  group('compact 变体判据（shouldPreferCompactVideo）', () {
    // 这些判据错了不会报错：只是「该压缩的没压缩（移动数据上多下几十 MB）」
    // 或「不该压缩的压缩了（图片细节被压掉 / 音频白拿一次 415 再回落）」。
    const big = kCompactVideoMinBytes;
    const small = kCompactVideoMinBytes - 1;

    test('视频且超过阈值 → 要压缩版', () {
      expect(
        shouldPreferCompactVideo(
          mimeType: 'video/mp4',
          fileName: 'recording.mp4',
          sizeBytes: big,
        ),
        isTrue,
        reason: '阈值本身算「够大」：边界取 >= 而不是 >',
      );
    });

    test('视频但小于阈值 → 走原片（多一次变体判定反而更慢）', () {
      expect(
        shouldPreferCompactVideo(
          mimeType: 'video/quicktime',
          fileName: 'clip.mov',
          sizeBytes: small,
        ),
        isFalse,
      );
    });

    test('体积未知（删除事件）→ 走原片', () {
      expect(
        shouldPreferCompactVideo(
          mimeType: 'video/mp4',
          fileName: 'gone.mp4',
          sizeBytes: null,
        ),
        isFalse,
      );
    });

    test('音频再大也不压缩（UFS 没有 audio 的 compact 产物）', () {
      expect(
        shouldPreferCompactVideo(
          mimeType: 'audio/mpeg',
          fileName: 'long.mp3',
          sizeBytes: 200 * 1024 * 1024,
        ),
        isFalse,
      );
    });

    test('图片再大也不压缩（点开要的是原图）', () {
      expect(
        shouldPreferCompactVideo(
          mimeType: 'image/png',
          fileName: 'huge.png',
          sizeBytes: 200 * 1024 * 1024,
        ),
        isFalse,
      );
    });

    test('mime 缺失/octet-stream 时按扩展名兜底判定视频', () {
      for (final mime in [null, '', 'application/octet-stream']) {
        expect(
          shouldPreferCompactVideo(
            mimeType: mime,
            fileName: 'workspace/clip.MKV',
            sizeBytes: big,
          ),
          isTrue,
          reason: 'workspace sync 上传可能丢 Content-Type（mime=$mime）',
        );
      }
      expect(
        shouldPreferCompactVideo(
          mimeType: 'application/octet-stream',
          fileName: 'notes.pdf',
          sizeBytes: big,
        ),
        isFalse,
      );
    });
  });
}
