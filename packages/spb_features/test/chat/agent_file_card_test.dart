import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// [AgentFileCard] 的渲染与交互测试。
///
/// 卡片是纯 UI：下载/缩略图都靠注入回调，不发起真实网络（无头环境无法验证）。
AgentFileItem _file({
  String action = 'created',
  String? ufsFileId = 'ufs_001',
  String mimeType = 'text/markdown',
  int? sizeBytes = 3585,
  String displayName = 'QWEN.md',
  String fileName = 'QWEN.md',
  TtsStreamKind? ttsKind,
}) => AgentFileItem(
  id: 'QWEN.md',
  createdAt: DateTime.utc(2024, 3, 5),
  relativePath: 'QWEN.md',
  fileName: fileName,
  displayName: displayName,
  action: action,
  ufsFileId: ufsFileId,
  mimeType: mimeType,
  sizeBytes: sizeBytes,
  ttsKind: ttsKind,
);

void main() {
  testWidgets('created 卡渲染展示名、生命周期徽标与下载按钮', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(file: _file(), onDownload: (_) async {}),
        ),
      ),
    );

    expect(find.text('QWEN.md'), findsOneWidget);
    expect(find.text('已生成'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
  });

  testWidgets('点击下载按钮调用回调且只一次（防重复）', (t) async {
    var calls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(
            file: _file(),
            onDownload: (_) async {
              calls++;
            },
          ),
        ),
      ),
    );

    await t.tap(find.byIcon(Icons.download_outlined));
    await t.pump();
    expect(calls, 1);
  });

  testWidgets('deleted 卡置灰且下载按钮禁用', (t) async {
    var calls = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(
            file: _file(action: 'deleted', ufsFileId: null),
            onDownload: (_) async {
              calls++;
            },
          ),
        ),
      ),
    );

    expect(find.text('已删除'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    // deleted 时下载按钮不渲染（而非渲染一个禁用按钮）。
    expect(find.byIcon(Icons.download_outlined), findsNothing);
    expect(calls, 0);
  });

  testWidgets('modified 卡显示「已更新」徽标', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(
            file: _file(action: 'modified'),
            onDownload: (_) async {},
          ),
        ),
      ),
    );

    expect(find.text('已更新'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('图片类文件显示图片图标，文档类显示文档图标', (t) async {
    // 图片（无缩略图回调 → 退化为图标，不发起网络）。
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(file: _file(mimeType: 'image/png')),
        ),
      ),
    );
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);

    // 文档。
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentFileCard(file: _file(mimeType: 'application/pdf')),
        ),
      ),
    );
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
  });

  group('打开 / 定位菜单', () {
    /// 展开行尾菜单并返回其中的菜单项文字。
    Future<List<String>> openMenu(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      return t
          .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
          .map((e) => (e.child as Text).data ?? '')
          .toList();
    }

    testWidgets('注入 onOpen/onReveal 后菜单出现两项', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(),
              onOpen: (_) async => true,
              onReveal: (_) async => true,
            ),
          ),
        ),
      );

      expect(await openMenu(t), ['用默认程序打开', '在文件管理器中定位']);
    });

    testWidgets('未注入回调时不渲染菜单（行为与现在完全一致）', (t) async {
      // 移动端就是这样：`NoopDesktopCapabilities` 下接上只会让用户点「打开」
      // 得到「无法打开文件」，故宁可整个菜单不出现。
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AgentFileCard(file: _file())),
        ),
      );

      expect(find.byKey(const ValueKey('agent-file-menu')), findsNothing);
    });

    testWidgets('只注入 onOpen 时菜单只出现打开（不渲染点了没反应的项）', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(file: _file(), onOpen: (_) async => true),
          ),
        ),
      );

      expect(await openMenu(t), ['用默认程序打开']);
    });

    testWidgets('已删除的文件：菜单项出现但禁用', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(action: 'deleted', ufsFileId: null),
              onOpen: (_) async => true,
              onReveal: (_) async => true,
            ),
          ),
        ),
      );

      // 禁用而非隐藏：让用户看到「动作存在但现在不可用」。
      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      for (final item in t.widgetList<PopupMenuItem<String>>(
        find.byType(PopupMenuItem<String>),
      )) {
        expect(item.enabled, isFalse, reason: 'UFS 已软删，点了会 404');
      }
    });

    testWidgets('无 ufsFileId 的文件：菜单项禁用', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(ufsFileId: null),
              onOpen: (_) async => true,
            ),
          ),
        ),
      );

      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      expect(
        t
            .widget<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
            .enabled,
        isFalse,
        reason: '无从定位本地副本',
      );
    });

    testWidgets('点「打开」调用回调且只一次（防重复）', (t) async {
      var calls = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(),
              onOpen: (_) async {
                calls++;
                return true;
              },
            ),
          ),
        ),
      );

      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('用默认程序打开'));
      await t.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('回调返回 false → 提示「无法打开文件」（不静默无响应）', (t) async {
      // issue #6 的验收项：「文件未下载到本地时打开应有明确反馈」
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(file: _file(), onOpen: (_) async => false),
          ),
        ),
      );

      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('用默认程序打开'));
      await t.pumpAndSettle();

      expect(find.text('无法打开文件'), findsOneWidget);
    });

    testWidgets('回调抛异常 → 提示且卡片仍可用', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(),
              onReveal: (_) async => throw StateError('boom'),
              onDownload: (_) async {},
            ),
          ),
        ),
      );

      await t.tap(find.byKey(const ValueKey('agent-file-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('在文件管理器中定位'));
      await t.pumpAndSettle();

      expect(find.textContaining('定位失败'), findsOneWidget);
      // 失败不阻断卡片：下载仍可用。
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    });

    testWidgets('deleted 卡不渲染下载按钮，但菜单仍在（项禁用）', (t) async {
      // 与 issue #6 的取向一致：「禁用」而非隐藏菜单项（让用户看到动作存在
      // 但现在不可用）。下载按钮则是既有行为：deleted 时整个不渲染。
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(action: 'deleted', ufsFileId: null),
              onOpen: (_) async => true,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.download_outlined), findsNothing);
      expect(find.byKey(const ValueKey('agent-file-menu')), findsOneWidget);
    });
  });

  group('语音产物', () {
    testWidgets('reply 语音条目默认展开显示大小与下载按钮', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(
                ttsKind: TtsStreamKind.reply,
                mimeType: 'audio/mpeg',
                sizeBytes: 53079,
              ),
              onDownload: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('回复语音'), findsOneWidget);
      expect(find.text('51.8 KB'), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      // 回复语音不折叠 → 无展开/收起按钮。
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('narration 默认折叠（不显示大小与下载），点开后才出现', (t) async {
      var calls = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(
                ttsKind: TtsStreamKind.narration,
                mimeType: 'audio/mpeg',
                sizeBytes: 12000,
              ),
              onDownload: (_) async {
                calls++;
              },
            ),
          ),
        ),
      );

      expect(find.text('思考填充语'), findsOneWidget);
      // 折叠时不显示大小、不显示下载按钮。
      expect(find.text('11.7 KB'), findsNothing);
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      // 有展开箭头。
      expect(find.byIcon(Icons.expand_more), findsOneWidget);

      // 点开。
      await t.tap(find.byIcon(Icons.expand_more));
      await t.pumpAndSettle();

      expect(find.text('11.7 KB'), findsOneWidget);
      // 展开后下载按钮出现。
      await t.tap(find.byIcon(Icons.download_outlined));
      await t.pump();
      expect(calls, 1);
    });

    testWidgets('filesummary 语音条目渲染「文件播报」标签', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(
                ttsKind: TtsStreamKind.filesummary,
                mimeType: 'audio/mpeg',
                sizeBytes: 8000,
              ),
              onDownload: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('文件播报'), findsOneWidget);
      expect(find.text('7.8 KB'), findsOneWidget);
    });
  });

  group('预览入口（issue #8）', () {
    testWidgets('未注入 onPreview 时不渲染预览按钮（行为与现在一致）', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(file: _file(), onDownload: (_) async {}),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('agent-file-preview')), findsNothing);
    });

    testWidgets('注入能力后渲染预览按钮，点击弹出对话框', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(),
              onDownload: (_) async {},
              onPreview: AgentFilePreviewCallbacks(
                loadBytes: (_) async => [104, 105],
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('agent-file-preview')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('agent-file-preview')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('agent-file-preview-dialog')),
        findsOneWidget,
      );
    });

    testWidgets('已删除文件：预览按钮禁用（点了会 404）', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(action: 'deleted'),
              onDownload: (_) async {},
              onPreview: AgentFilePreviewCallbacks(
                loadBytes: (_) async => [104],
              ),
            ),
          ),
        ),
      );

      final btn = t.widget<IconButton>(
        find.byKey(const ValueKey('agent-file-preview')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('无 ufsFileId：预览按钮禁用', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(ufsFileId: null),
              onDownload: (_) async {},
              onPreview: AgentFilePreviewCallbacks(
                loadBytes: (_) async => [104],
              ),
            ),
          ),
        ),
      );

      final btn = t.widget<IconButton>(
        find.byKey(const ValueKey('agent-file-preview')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('只有 openExternal 能力（无 loadBytes）也渲染预览按钮', (t) async {
      // 移动端可以只接跳转、不接取数；hasAny 必须认这个组合。
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentFileCard(
              file: _file(mimeType: 'application/pdf', fileName: 'a.pdf'),
              onDownload: (_) async {},
              onPreview: AgentFilePreviewCallbacks(
                openExternal: (_) async => true,
              ),
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('agent-file-preview')), findsOneWidget);
    });
  });
}
