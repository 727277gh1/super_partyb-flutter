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
      ('svg 按 mime', 'image/svg+xml', 'a.svg', null, FilePreviewKind.image),
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
    test('image/svg+xml 归 image（而非 external）', () {
      // svg 是 markup，但 webapp 的 isImageFile 先命中 `image/` 前缀，
      // 故它归 image 而不是被 markup 那条规则推去 external。
      expect(
        resolvePreviewKind(mimeType: 'image/svg+xml', fileName: 'a.svg'),
        FilePreviewKind.image,
      );
    });

    test('扩展名是图片但 mime 是 text/plain → 仍归 image', () {
      // 服务端偶尔把 svg 报成 text/plain；不按扩展名兜底会让它走 text，
      // 用户看到的是一坨 XML 而不是图。
      expect(
        resolvePreviewKind(mimeType: 'text/plain', fileName: 'icon.svg'),
        FilePreviewKind.image,
      );
    });
  });

  group('resolveTextPreviewKind：本轮一律退化 text（无 JSON-UI 渲染器）', () {
    test('合法 JSON 仍按 text 呈现（不是 external、不是 spec）', () {
      // 这是本轮**有意**的退化：webapp 会把命中 schema 的 JSON 交给
      // DashboardRenderer/MonacoEditorLazy；客户端没有这些渲染器，
      // 故把原文交给用户看。若误返回 external，JSON 文件会从
      // 「能看原文」退化成「跳 UFS 预览页」——比现在更差。
      expect(resolveTextPreviewKind('{"a":1}'), FilePreviewKind.text);
    });

    test('形似 map / dashboard / spec 的 JSON 也仍是 text', () {
      expect(
        resolveTextPreviewKind('{"type":"map","center":[1,2],"markers":[]}'),
        FilePreviewKind.text,
      );
      expect(
        resolveTextPreviewKind('{"widgets":[{"x":0,"y":0,"w":2,"h":1}]}'),
        FilePreviewKind.text,
      );
      expect(
        resolveTextPreviewKind('{"root":{"type":"page"},"elements":[]}'),
        FilePreviewKind.text,
      );
    });

    test('非 JSON 与空串也是 text', () {
      expect(resolveTextPreviewKind('hello'), FilePreviewKind.text);
      expect(resolveTextPreviewKind(''), FilePreviewKind.text);
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
}
