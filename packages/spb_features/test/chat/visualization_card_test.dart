import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/src/chat/visualization_card.dart';
import 'package:spb_models/spb_models.dart';

VisualizationItem item({int version = 1, int revision = 1}) =>
    VisualizationItem(
      id: 'e$revision',
      createdAt: DateTime(2026),
      groupId: 'g',
      reference: VisualizationPublished.fromJson({
        'event_version': version,
        'artifact_id': 'a',
        'revision': revision,
        'profile': 'partyb.readonly',
        'schema_version': 1,
        'title': '报告',
        'summary': '保留结论',
      }),
    );

void main() {
  testWidgets('未知版本保留摘要且不读取正文', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VisualizationCard(
            item: item(version: 2),
            load: (_, _, _) async => throw StateError('不应加载'),
          ),
        ),
      ),
    );
    expect(find.text('保留结论'), findsOneWidget);
    expect(find.text('当前客户端暂不支持此报告版本。'), findsOneWidget);
    expect(find.text('查看报告'), findsNothing);
  });
  testWidgets('固定 revision 加载失败保留摘要，重试显示共享样例', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    final content = jsonDecode(
      File('test/fixtures/readonly-v1.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: VisualizationCard(
              item: item(),
              load: (group, artifact, revision) async {
                expect((group, artifact, revision), ('g', 'a', 1));
                attempts++;
                return VisualizationRevision.fromJson({
                  ...content,
                  'group_id': 'g',
                  'artifact_id': 'a',
                  'revision': attempts == 1 ? 2 : 1,
                  'status': 'published',
                });
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看报告'));
    await tester.pumpAndSettle();
    expect(find.text('报告加载失败。'), findsOneWidget);
    expect(find.text('保留结论'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('报告加载失败。'), findsNothing);
    expect(find.text('销售额'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
