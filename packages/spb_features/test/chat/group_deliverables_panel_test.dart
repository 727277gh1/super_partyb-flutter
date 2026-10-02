import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 交付物侧边栏（[GroupDeliverablesPanel]）的渲染与交互测试。
///
/// ## 这个测试防的是什么
///
/// 侧边栏展示的是「这个 group 现在有哪些文件」的权威快照。它的失败模式大多
/// **看起来正常**——不崩溃、不报错，只是内容不对或点了没反应：
///
/// - **切对话不重拉** → 用户切到另一个 group，看到的还是上一个的文件；
/// - **刷新令牌失效** → agent 刚产出的文件永远不出现（SSE 事件到了但列表不刷）；
/// - **失败静默** → 拉取失败显示空列表，用户以为「这个对话没有交付物」；
/// - **动作不可达** → 「打开 / 定位」在未下载时点了没反应，且没有解释。
///
/// 故逐条断言：加载 / 空 / 错三态、目录折叠展开、按 group 重拉、令牌刷新、
/// 下载防重复、打开/定位仅在下载后可用。
const _gid = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherGid = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

UfsFileEntry _file(
  String rel, {
  String? id,
  int size = 1024,
  String? mime = 'text/markdown',
  bool deleted = false,
  bool directory = false,
  String updatedAt = '2026-01-01T00:00:00Z',
  String? name,
  String gid = _gid,
}) => UfsFileEntry.fromJson({
  'id': id ?? 'id-$rel',
  'path': '/workspace/groups/$gid/$rel/',
  'name': name ?? rel.split('/').last,
  'size': size,
  'mime_type': mime,
  'is_directory': directory,
  if (deleted) 'deleted_at': '2026-02-01T00:00:00Z',
  'updated_at': updatedAt,
});

void main() {
  /// 把面板放进最小可用的 MaterialApp（含 Scaffold，SnackBar 需要它）。
  Future<void> pumpPanel(
    WidgetTester tester, {
    required Future<List<UfsFileEntry>> Function() loadFiles,
    String groupId = _gid,
    Object? reloadToken,
    DownloadDeliverable? onDownload,
    OpenLocalDeliverable? onOpen,
    RevealLocalDeliverable? onReveal,
    ResolveLocalDeliverable? resolveLocalPath,
    Size size = const Size(420, 900),
  }) async {
    // 面板是纵向列表，需要足够高度让多个条目一次性构建
    // （ListView 惰性构建，屏幕外的条目在 widget 树里不存在）。
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupDeliverablesPanel(
            groupId: groupId,
            loadFiles: loadFiles,
            reloadToken: reloadToken,
            onDownload: onDownload,
            onOpen: onOpen,
            onReveal: onReveal,
            resolveLocalPath: resolveLocalPath,
          ),
        ),
      ),
    );
    // 让 initState 里的 _load() 完成。
    await tester.pumpAndSettle();
  }

  // =========================================================================
  group('加载态与三态渲染', () {
    testWidgets('首次加载显示 spinner，完成后显示文件', (tester) async {
      final completer = Completer<List<UfsFileEntry>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(
              groupId: _gid,
              loadFiles: () => completer.future,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('deliverables-loading')),
        findsOneWidget,
      );

      completer.complete([_file('README.md')]);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('deliverables-loading')), findsNothing);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('空清单显示空态提示', (tester) async {
      await pumpPanel(tester, loadFiles: () async => const []);

      expect(find.byKey(const ValueKey('deliverables-empty')), findsOneWidget);
      expect(find.text('这个对话还没有交付物'), findsOneWidget);
    });

    testWidgets('加载失败显示错误 + 重试按钮', (tester) async {
      await pumpPanel(tester, loadFiles: () async => throw StateError('boom'));

      expect(find.byKey(const ValueKey('deliverables-error')), findsOneWidget);
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.byKey(const ValueKey('deliverables-retry')), findsOneWidget);
    });

    testWidgets('重试成功后显示内容（错误态可恢复）', (tester) async {
      var attempt = 0;
      await pumpPanel(
        tester,
        loadFiles: () async {
          attempt++;
          if (attempt == 1) throw StateError('boom');
          return [_file('README.md')];
        },
      );

      expect(find.byKey(const ValueKey('deliverables-error')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('deliverables-retry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('deliverables-error')), findsNothing);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('头部显示文件计数（不含目录）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [
          _file('reports', directory: true),
          _file('reports/a.md'),
          _file('reports/b.md'),
        ],
      );

      expect(find.text('2 个文件'), findsOneWidget);
    });
  });

  // =========================================================================
  group('目录树', () {
    testWidgets('嵌套目录按层级默认展开（仅顶层）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('reports/2026/spec.md')],
      );

      // 只有顶层目录默认展开：reports 展开后可见 2026，
      // 而 2026 是第二层、默认折叠，故 spec.md 此时不可见。
      expect(find.text('reports'), findsOneWidget);
      expect(find.text('2026'), findsOneWidget);
      expect(find.text('spec.md'), findsNothing);

      // 展开第二层后文件出现。
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      expect(find.text('spec.md'), findsOneWidget);
    });

    testWidgets('点击目录可折叠 / 展开', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('reports/spec.md')],
      );

      expect(find.text('spec.md'), findsOneWidget);

      await tester.tap(find.text('reports'));
      await tester.pumpAndSettle();
      expect(find.text('spec.md'), findsNothing, reason: '折叠后子项应隐藏');

      await tester.tap(find.text('reports'));
      await tester.pumpAndSettle();
      expect(find.text('spec.md'), findsOneWidget, reason: '再次点击应展开');
    });

    testWidgets('顶层文件直接显示，不套目录', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md'), _file('QWEN.md')],
      );

      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('QWEN.md'), findsOneWidget);
    });
  });

  // =========================================================================
  group('按 group 重拉', () {
    testWidgets('groupId 变化时重新加载', (tester) async {
      var calls = 0;
      Future<List<UfsFileEntry>> load() async {
        calls++;
        return [_file('README.md')];
      }

      // 手动 pump 两次以模拟 groupId 变化（pumpPanel 每次都是新 widget 树，
      // 需要同树内更新才能触发 didUpdateWidget）。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(groupId: _gid, loadFiles: load),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(groupId: _otherGid, loadFiles: load),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '切对话必须重拉');
    });

    testWidgets('reloadToken 变化时重新加载（SSE 事件驱动刷新）', (tester) async {
      var calls = 0;
      Future<List<UfsFileEntry>> load() async {
        calls++;
        return [_file('README.md')];
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(
              groupId: _gid,
              loadFiles: load,
              reloadToken: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(
              groupId: _gid,
              loadFiles: load,
              reloadToken: 2,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '令牌变化必须重拉（agent 产出新文件）');
    });

    testWidgets('groupId 与令牌都不变时不重拉（避免每次 rebuild 都请求）', (tester) async {
      var calls = 0;
      Future<List<UfsFileEntry>> load() async {
        calls++;
        return [_file('README.md')];
      }

      Widget build() => MaterialApp(
        home: Scaffold(
          body: GroupDeliverablesPanel(
            groupId: _gid,
            loadFiles: load,
            reloadToken: 1,
          ),
        ),
      );

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      // 换一个 loadFiles 闭包身份，但 groupId / token 不变。
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(calls, 1, reason: '闭包身份变化不应触发重拉');
    });

    testWidgets('手动刷新按钮触发重拉', (tester) async {
      var calls = 0;
      await pumpPanel(
        tester,
        loadFiles: () async {
          calls++;
          return [_file('README.md')];
        },
      );
      expect(calls, 1);

      await tester.tap(find.byKey(const ValueKey('deliverables-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });
  });

  // =========================================================================
  group('下载', () {
    testWidgets('无下载回调时不渲染操作菜单', (tester) async {
      await pumpPanel(tester, loadFiles: () async => [_file('README.md')]);

      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('有下载回调时渲染菜单，下载调用回调一次', (tester) async {
      var calls = 0;
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async {
          calls++;
          return '/tmp/${f.name}';
        },
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.textContaining('已下载到'), findsOneWidget);
    });

    testWidgets('下载失败显示提示且不崩溃', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => throw StateError('network down'),
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(find.textContaining('下载失败'), findsOneWidget);
    });
  });

  // =========================================================================
  group('打开与定位（依赖下载后的本地路径）', () {
    testWidgets('未下载时「打开」菜单项禁用', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onOpen: (_) async => true,
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isFalse, reason: '未下载前无本地路径，不可打开');
    });

    testWidgets('下载后「打开」变为可用并调用回调', (tester) async {
      var opened = '';
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onOpen: (path) async {
          opened = path;
          return true;
        },
      );

      // 先下载。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      // 再打开。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用默认程序打开'));
      await tester.pumpAndSettle();

      expect(opened, '/tmp/a.md');
    });

    testWidgets('未下载时「在文件管理器中定位」菜单项禁用', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onReveal: (_) async => true,
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '在文件管理器中定位'),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('下载后定位调用回调', (tester) async {
      var revealed = '';
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onReveal: (path) async {
          revealed = path;
          return true;
        },
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在文件管理器中定位'));
      await tester.pumpAndSettle();

      expect(revealed, '/tmp/a.md');
    });

    testWidgets('切对话清空本地路径（旧 group 的路径不应泄漏到新 group）', (tester) async {
      var opened = false;
      // 第二个 group 的条目路径要带它自己的 gid，否则会被（正确地）过滤掉。
      Future<List<UfsFileEntry>> load() async => [_file('README.md')];
      Future<List<UfsFileEntry>> loadOther() async => [
        _file('README.md', gid: _otherGid),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(
              groupId: _gid,
              loadFiles: load,
              onDownload: (f) async => '/tmp/a.md',
              onOpen: (_) async {
                opened = true;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 下载，使本地路径就位。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      // 切 group：同一文件 id 的本地路径必须被清掉。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GroupDeliverablesPanel(
              groupId: _otherGid,
              loadFiles: loadOther,
              onDownload: (f) async => '/tmp/a.md',
              onOpen: (_) async {
                opened = true;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isFalse, reason: '切 group 后本地路径应已清空');
      expect(opened, isFalse);
    });
  });

  // =========================================================================
  group('已同步则直接打开（同步索引优先于下载记录）', () {
    testWidgets('已同步的交付物不下载即可打开，且路径来自同步索引', (tester) async {
      var opened = '';
      var downloads = 0;
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        // 提供下载回调以证明「无需调用它」：面板不应为了打开而先下载。
        onDownload: (f) async {
          downloads++;
          return '/tmp/downloaded.md';
        },
        onOpen: (path) async {
          opened = path;
          return true;
        },
        // 同步索引命中 → 直接给本地路径。
        resolveLocalPath: (f) => '/sync/root/$_gid/README.md',
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      // 菜单项必须**已可用**（未下载也能打开）。
      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isTrue, reason: '已同步的文件应可直接打开');

      await tester.tap(find.text('用默认程序打开'));
      await tester.pumpAndSettle();

      expect(opened, '/sync/root/$_gid/README.md');
      expect(downloads, 0, reason: '已同步的文件不应触发下载');
    });

    testWidgets('已同步的交付物不下载即可定位', (tester) async {
      var revealed = '';
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onReveal: (path) async {
          revealed = path;
          return true;
        },
        resolveLocalPath: (f) => '/sync/root/$_gid/README.md',
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在文件管理器中定位'));
      await tester.pumpAndSettle();

      expect(revealed, '/sync/root/$_gid/README.md');
    });

    testWidgets('单击行直接打开已同步的文件', (tester) async {
      var opened = '';
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onOpen: (path) async {
          opened = path;
          return true;
        },
        resolveLocalPath: (f) => '/sync/root/$_gid/README.md',
      );

      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(opened, '/sync/root/$_gid/README.md');
    });

    testWidgets('未同步的文件仍禁用「打开」（索引返回 null）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onOpen: (_) async => true,
        // 未同步：实现方返回 null。
        resolveLocalPath: (f) => null,
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isFalse, reason: '未同步且未下载 → 无本地路径');
    });

    testWidgets('同步索引优先于下载记录（两者都有时用同步目录那份）', (tester) async {
      var opened = '';
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/app/support/downloads/a.md',
        onOpen: (path) async {
          opened = path;
          return true;
        },
        resolveLocalPath: (f) => '/sync/root/$_gid/README.md',
      );

      // 先下载（写入面板自己的下载记录）。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      // 再打开：应指向同步目录，而不是刚下载的应用目录。
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用默认程序打开'));
      await tester.pumpAndSettle();

      expect(opened, '/sync/root/$_gid/README.md');
    });

    testWidgets('同步索引返回空串视为未同步（不打开空路径）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onOpen: (_) async => true,
        resolveLocalPath: (f) => '',
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      final item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isFalse);
    });

    testWidgets('未提供同步索引时退化为「仅下载后可用」（不报错）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [_file('README.md')],
        onDownload: (f) async => '/tmp/a.md',
        onOpen: (_) async => true,
        // resolveLocalPath 不传。
      );

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      var item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isFalse, reason: '无索引时未下载 → 不可打开');

      // 下载后仍可打开（原有行为不受影响）。
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      item = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, '用默认程序打开'),
      );
      expect(item.enabled, isTrue);
    });

    testWidgets('切对话后索引按新 group 重新查询（不沿用旧 group 的结果）', (tester) async {
      // 索引回调按 groupId 返回不同路径，模拟真实装配里的 family 键。
      var opened = '';
      final queried = <String>[];

      Widget build(String gid) => MaterialApp(
        home: Scaffold(
          body: GroupDeliverablesPanel(
            groupId: gid,
            loadFiles: () async => [_file('README.md', gid: gid)],
            onOpen: (path) async {
              opened = path;
              return true;
            },
            resolveLocalPath: (f) {
              queried.add(gid);
              return '/sync/root/$gid/README.md';
            },
          ),
        ),
      );

      await tester.pumpWidget(build(_gid));
      await tester.pumpAndSettle();

      await tester.pumpWidget(build(_otherGid));
      await tester.pumpAndSettle();

      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();

      expect(opened, '/sync/root/$_otherGid/README.md');
      expect(queried, contains(_otherGid));
    });
  });

  // =========================================================================
  group('文件类型图标', () {
    testWidgets('图片 / 文本 / 未知类型各有图标', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [
          _file('a.png', mime: 'image/png'),
          _file('b.md', mime: 'text/markdown'),
          _file('c.bin', mime: 'application/octet-stream'),
        ],
      );

      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    });
  });

  // =========================================================================
  group('已删除条目', () {
    testWidgets('软删文件默认不出现（侧边栏展示「现在有什么」）', (tester) async {
      await pumpPanel(
        tester,
        loadFiles: () async => [
          _file('alive.md'),
          _file('gone.md', deleted: true),
        ],
      );

      expect(find.text('alive.md'), findsOneWidget);
      expect(find.text('gone.md'), findsNothing);
      // 计数也只算活着的。
      expect(find.text('1 个文件'), findsOneWidget);
    });
  });
}
