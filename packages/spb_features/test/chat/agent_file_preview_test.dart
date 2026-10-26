import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [showAgentFilePreview] 的渲染分支测试（issue #8：text / image / external）。
///
/// ## 这里防的是什么
///
/// 预览的失败模式**不会抛异常**，只会「用错的方式展示」：
///
/// - 大文本静默截断 → 用户以为报告完整（本组有专门用例断言提示条存在）；
/// - external 类型误走取数 → 卡在转圈（没有 `openExternal` 时也应有可读说明）；
/// - 未注入能力时仍渲染入口 → 点了没反应。
///
/// 取数走注入回调，不发起真实网络（无头环境无法验证真实渲染）。
AgentFileItem _file({
  String action = 'created',
  String? ufsFileId = 'ufs_001',
  String? mimeType = 'text/markdown',
  String displayName = 'report.md',
  String fileName = 'report.md',
  String relativePath = 'out/report.md',
  TtsStreamKind? ttsKind,
}) => AgentFileItem(
  id: relativePath,
  createdAt: DateTime.utc(2024, 3, 5),
  relativePath: relativePath,
  fileName: fileName,
  displayName: displayName,
  action: action,
  ufsFileId: ufsFileId,
  mimeType: mimeType,
  ttsKind: ttsKind,
);

/// 一个 1x1 的合法 PNG（最小可解码图片，用于 `Image.memory` 分支）。
final _pngBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==',
  ),
);

/// 挂一个能弹出对话框的宿主，并立即调用 [showAgentFilePreview]。
Future<void> _pumpPreview(
  WidgetTester t, {
  required AgentFileItem file,
  AgentFilePreviewCallbacks? onPreview,
}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAgentFilePreview(
              context: context,
              file: file,
              onPreview: onPreview,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  group('未注入能力：入口不渲染 / 不弹窗', () {
    testWidgets('onPreview 为 null 时不弹对话框', (t) async {
      await _pumpPreview(t, file: _file(), onPreview: null);
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsNothing,
      );
    });

    testWidgets('两个回调都为 null（hasAny 假）时不弹对话框', (t) async {
      // 关键：`hasAny` 为假必须**拦住**，否则会弹出一个永远取不到内容的框。
      await _pumpPreview(
        t,
        file: _file(),
        onPreview: const AgentFilePreviewCallbacks(),
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsNothing,
      );
    });
  });

  group('text 分支', () {
    testWidgets('渲染文本内容与等宽字体，无截断提示', (t) async {
      // 用 `.txt` 驱动等宽分支：`.md` 现在走 Markdown 渲染器（见下组）。
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'a.txt',
          relativePath: 'out/a.txt',
          displayName: 'a.txt',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('# 标题\n正文'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsOneWidget,
      );
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('文本'), findsOneWidget);
      final text = t.widget<SelectableText>(
        find.byKey(const ValueKey('agent-file-preview-text')),
      );
      expect(text.data, '# 标题\n正文');
      // 小内容不显示截断提示。
      expect(
        find.byKey(const ValueKey('agent-file-preview-truncated')),
        findsNothing,
      );
    });

    testWidgets('大文本：截断且**显示**提示（不静默截断）', (t) async {
      // 这是 issue 的核心验收项。用 maxChars 之上的内容驱动默认上限分支。
      final big = 'x' * (kTextPreviewMaxChars + 500);
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'a.txt',
          relativePath: 'out/a.txt',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(big),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-truncated')),
        findsOneWidget,
      );
      // 提示必须说清规模（只说「已截断」用户无法判断漏了多少）。
      expect(find.textContaining('共 ${big.length} 字符'), findsOneWidget);
      expect(find.textContaining('省略 500 字符'), findsOneWidget);
      expect(find.textContaining('完整内容请下载查看'), findsOneWidget);

      final text = t.widget<SelectableText>(
        find.byKey(const ValueKey('agent-file-preview-text')),
      );
      expect(text.data!.length, kTextPreviewMaxChars);
    });

    testWidgets('非法 UTF-8 字节不崩，退化为可读文本（allowMalformed）', (t) async {
      // 服务端把二进制报成 text/* 是常见误报。不加 allowMalformed 会抛
      // FormatException，用户看到「加载失败」而不是「文件里有乱码」。
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'a.txt',
          relativePath: 'out/a.txt',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => [0xFF, 0xFE, 0x41],
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-error')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsOneWidget,
      );
    });
  });

  group('Markdown 分支（issue #15：渲染器选择）', () {
    testWidgets('.md 用 GptMarkdown 渲染，不再展示字面标记', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/markdown',
          fileName: 'report.md',
          relativePath: 'out/report.md',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('# 标题\n\n正文'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-markdown')),
        findsOneWidget,
      );
      // 关键：走了 Markdown 渲染器，就不该再有等宽纯文本分支。
      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsNothing,
      );
      // `# 标题` 被渲染成标题：字面串（含 `# ` 前缀）不应作为整段文本出现。
      expect(find.text('# 标题'), findsNothing);
      expect(find.textContaining('标题'), findsWidgets);
    });

    testWidgets('mime 为 text/plain 但扩展名是 .md → 仍走 Markdown', (t) async {
      // 服务端常报通用 text/plain，此时只能靠扩展名。漏判会让 README 显示
      // 成一堆 `#`、`**` 标记。
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'README.md',
          relativePath: 'README.md',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('## 二级标题'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-markdown')),
        findsOneWidget,
      );
      expect(find.text('## 二级标题'), findsNothing);
    });

    testWidgets('.txt 仍是等宽纯文本（Markdown 渲染会吃掉 # 与 *）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'notes.txt',
          relativePath: 'notes.txt',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('# 这不是标题\n* 也不是列表'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-markdown')),
        findsNothing,
      );
      final text = t.widget<SelectableText>(
        find.byKey(const ValueKey('agent-file-preview-text')),
      );
      expect(text.data, '# 这不是标题\n* 也不是列表');
    });

    testWidgets('超长 .md：截断提示仍可见（Markdown 渲染不能省掉它）', (t) async {
      // Markdown 渲染后页面看起来「很完整」，比纯文本更容易让人以为这就是全部。
      final big = '# 报告\n${'x' * (kTextPreviewMaxChars + 10)}';
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/markdown',
          fileName: 'big.md',
          relativePath: 'out/big.md',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(big),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-truncated')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-markdown')),
        findsOneWidget,
      );
    });
  });

  group('image 分支', () {
    testWidgets('mime 是 image/* 时渲染 Image.memory', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'image/png',
          fileName: 'a.png',
          relativePath: 'a.png',
        ),
        onPreview: AgentFilePreviewCallbacks(loadBytes: (_) async => _pngBytes),
      );

      expect(find.text('图片'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-file-preview-image')),
        findsOneWidget,
      );
      // 图片分支不该出现文本框。
      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsNothing,
      );
    });

    testWidgets('图片字节损坏时退化为错误提示，不抛异常', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'image/png',
          fileName: 'a.png',
          relativePath: 'a.png',
        ),
        onPreview: AgentFilePreviewCallbacks(loadBytes: (_) async => [1, 2, 3]),
      );
      await t.pumpAndSettle();

      // errorBuilder 产出的提示（具体文案见实现）。
      expect(find.textContaining('无法解码'), findsOneWidget);
    });
  });

  group('external 分支', () {
    testWidgets('html 类型直接给跳转入口，不取数', (t) async {
      var loaded = false;
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/html',
          fileName: 'page.html',
          relativePath: 'page.html',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async {
            loaded = true;
            return utf8.encode('x');
          },
          openExternal: (_) async => true,
        ),
      );

      expect(find.text('外部预览'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-file-preview-external')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-open-external')),
        findsOneWidget,
      );
      expect(loaded, isFalse, reason: 'external 不该发起取数');
    });

    testWidgets('点击跳转按钮调用 openExternal 且只一次', (t) async {
      var calls = 0;
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/pdf',
          fileName: 'a.pdf',
          relativePath: 'a.pdf',
        ),
        onPreview: AgentFilePreviewCallbacks(
          openExternal: (_) async {
            calls++;
            return true;
          },
        ),
      );

      await t.tap(
        find.byKey(const ValueKey('agent-file-preview-open-external')),
      );
      await t.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('openExternal 返回 false 时给 SnackBar 反馈（不静默）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/pdf',
          fileName: 'a.pdf',
          relativePath: 'a.pdf',
        ),
        onPreview: AgentFilePreviewCallbacks(openExternal: (_) async => false),
      );

      await t.tap(
        find.byKey(const ValueKey('agent-file-preview-open-external')),
      );
      await t.pumpAndSettle();
      expect(find.text('无法打开预览页'), findsOneWidget);
    });

    testWidgets('未注入 openExternal 时不给按钮，改为可读说明', (t) async {
      // 只接了 loadBytes 的移动端场景：external 类型没有出路，
      // 但也不能弹一个点了没反应的按钮。
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/pdf',
          fileName: 'a.pdf',
          relativePath: 'a.pdf',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('x'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-open-external')),
        findsNothing,
      );
      expect(find.textContaining('未提供外部预览入口'), findsOneWidget);
      expect(find.textContaining('下载'), findsOneWidget);
    });
  });

  group('spec 分支（issue #14：内容层识别）', () {
    testWidgets('文本内容是 spec schema → 渲染 SpecUiCard（不渲染原文）', (t) async {
      // `{root, elements}` 形状：root 指向 elements 里存在的元素。
      const spec =
          '{"root":"r","elements":{"r":{"type":"card",'
          '"props":{"title":"报告"},'
          '"children":["t"]},"t":{"type":"text",'
          '"props":{"content":"正文"}}}}';
      await _pumpPreview(
        t,
        // 用 `.md` 驱动：spec 优先于 Markdown（issue #15 的关键约束）。
        file: _file(
          mimeType: 'text/markdown',
          fileName: 'spec.md',
          relativePath: 'out/spec.md',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(spec),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-spec')),
        findsOneWidget,
      );
      // SpecUiCard 按 type 分派渲染出 title 与正文。
      expect(find.text('报告'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
      // 识别为 spec 时不该同时展示原文或 Markdown。
      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-markdown')),
        findsNothing,
      );
    });

    testWidgets('JSON 非法（非 spec）→ 仍渲染原文，不空白', (t) async {
      // 关键回归：spec 识别失败**必须**退回原文。若误走 _SpecPayload 分支，
      // 用户看到的是空对话框（SpecUiCard 对 null/悬空 root 渲染 shrink）。
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'a.json',
          relativePath: 'a.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('{"a":1,"b":[2,3]}'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-spec')),
        findsNothing,
      );
      final text = t.widget<SelectableText>(
        find.byKey(const ValueKey('agent-file-preview-text')),
      );
      expect(text.data, '{"a":1,"b":[2,3]}');
    });

    testWidgets('悬空 root 的 schema → 原文（不退化成空对话框）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'a.json',
          relativePath: 'a.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(
            '{"root":"missing","elements":{"x":{"type":"card"}}}',
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-spec')),
        findsNothing,
      );
    });
  });

  group('map 分支（issue #12：map spec）', () {
    /// 真实产物：`super_partyb` 生产 workspace 的
    /// `reports/route-changban-dashadong.map.spec.json`。
    const mapSpec =
        '{"type":"map","version":"1","title":"公交路线",'
        '"markers":[{"id":"marker-1","longitude":113.349324,'
        '"latitude":23.178369,"title":"起点"},'
        '{"id":"marker-2","longitude":113.458515,'
        '"latitude":23.106216,"title":"终点"}],'
        '"routes":[{"id":"route-1","mode":"transfer",'
        '"title":"公交路线","polyline":[[113.349324,23.178369],'
        '[113.458515,23.106216]]}]}';

    testWidgets('文本内容是 map spec → 渲染 MapSpecCard（不渲染原文）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'route.json',
          relativePath: 'out/route.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(mapSpec),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-map')),
        findsOneWidget,
      );
      expect(find.text('起点'), findsOneWidget);
      expect(find.text('终点'), findsOneWidget);
      // 识别为 map 时不该同时展示原文或 spec 分支。
      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-spec')),
        findsNothing,
      );
    });

    testWidgets('未注入 openMapMarker → 地点行不可点（不渲染无反应的入口）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'route.json',
          relativePath: 'out/route.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(mapSpec),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-map')),
        findsOneWidget,
      );
      // 用 marker key 而不是 `find.byType(InkWell)`：对话框自身也有 InkWell
      // （关闭按钮等），按类型断言会把它们算进来。
      expect(find.byKey(const ValueKey('map-marker-marker-1')), findsNothing);
      expect(find.text('地点'), findsOneWidget);
    });

    testWidgets('注入 openMapMarker → 点击地点行上抛该 marker', (t) async {
      final opened = <String>[];
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'route.json',
          relativePath: 'out/route.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(mapSpec),
          openMapMarker: (m) async {
            opened.add(m.title);
            return true;
          },
        ),
      );

      // 对话框内容可滚动，地点行可能不在首屏——先滚到可见再点。
      final row = find.byKey(const ValueKey('map-marker-marker-1'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      await t.tap(row);
      await t.pumpAndSettle();

      expect(opened, ['起点']);
    });

    testWidgets('openMapMarker 返回 false → 提示「无法打开地图」（不静默）', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'route.json',
          relativePath: 'out/route.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(mapSpec),
          openMapMarker: (_) async => false,
        ),
      );

      final row = find.byKey(const ValueKey('map-marker-marker-1'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      await t.tap(row);
      await t.pumpAndSettle();

      // 点了没反应是最差的降级——必须有可读反馈。
      expect(find.text('无法打开地图'), findsOneWidget);
    });

    testWidgets('openMapMarker 抛异常 → 提示，不把异常弹出对话框', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'route.json',
          relativePath: 'out/route.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode(mapSpec),
          openMapMarker: (_) async => throw StateError('boom'),
        ),
      );

      final row = find.byKey(const ValueKey('map-marker-marker-1'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      await t.tap(row);
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.textContaining('打开地图失败'), findsOneWidget);
    });

    testWidgets('空壳 map（type=map 无坐标）→ 退回原文，不变成空图', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'application/json',
          fileName: 'a.json',
          relativePath: 'a.json',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('{"type":"map"}'),
        ),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-map')),
        findsNothing,
      );
    });

    testWidgets('只配 openMapMarker 时预览入口仍不渲染（hasAny 不含它）', (t) async {
      // 关键：它只在**已打开**的预览框里用得上，不能单独让入口出现，
      // 否则会弹出一个取不到内容的空框。
      await _pumpPreview(
        t,
        file: _file(),
        onPreview: AgentFilePreviewCallbacks(openMapMarker: (_) async => true),
      );

      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsNothing,
      );
    });
  });

  group('取数失败', () {
    testWidgets('loadBytes 返回 null → 错误提示（不是无限转圈）', (t) async {
      await _pumpPreview(
        t,
        file: _file(),
        onPreview: AgentFilePreviewCallbacks(loadBytes: (_) async => null),
      );
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('agent-file-preview-error')),
        findsOneWidget,
      );
      expect(find.textContaining('未能取到文件内容'), findsOneWidget);
      expect(find.textContaining('可改用「下载」后查看'), findsOneWidget);
    });

    testWidgets('loadBytes 抛异常 → 错误提示（异常不冒泡）', (t) async {
      await _pumpPreview(
        t,
        file: _file(),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => throw StateError('boom'),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('agent-file-preview-error')),
        findsOneWidget,
      );
      expect(find.textContaining('加载失败'), findsOneWidget);
    });
  });

  group('关闭', () {
    testWidgets('点关闭按钮收起对话框', (t) async {
      await _pumpPreview(
        t,
        file: _file(
          mimeType: 'text/plain',
          fileName: 'a.txt',
          relativePath: 'out/a.txt',
        ),
        onPreview: AgentFilePreviewCallbacks(
          loadBytes: (_) async => utf8.encode('hi'),
        ),
      );
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsOneWidget,
      );

      await t.tap(find.byKey(const ValueKey('agent-file-preview-close')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsNothing,
      );
    });
  });
}
