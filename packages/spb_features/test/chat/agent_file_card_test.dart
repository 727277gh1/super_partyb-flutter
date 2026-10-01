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
}
