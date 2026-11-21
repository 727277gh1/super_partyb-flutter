import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

void main() {
  testWidgets('发送后的用户附件可见并可打开预览', (tester) async {
    MessageAttachment? opened;
    const attachment = MessageAttachment(name: '截图.png', fileId: 'ufs1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageBubble(
            text: '',
            attachments: const [attachment],
            onPreviewAttachment: (file) => opened = file,
          ),
        ),
      ),
    );
    expect(find.text('截图.png'), findsOneWidget);
    await tester.tap(find.text('截图.png'));
    expect(opened?.fileId, 'ufs1');
    expect(tester.takeException(), isNull);
  });
  testWidgets('选择附件、失败保留草稿、重试同一提交、成功后清空', (tester) async {
    final dir = Directory.systemTemp.createTempSync('composer-attachment-');
    final file = File('${dir.path}/报告.txt')..writeAsStringSync('正文');
    addTearDown(() => dir.deleteSync(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'openFile' ? [file.path] : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final submissions = <ChatAttachmentSubmission>[];
    var fail = true;
    var textCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 320,
              child: MessageComposer(
                onSubmit: (_) => textCalls++,
                onNewSession: () async {},
                onSendAttachments: (submission) async {
                  submissions.add(submission);
                  if (fail) throw const ValidationError('上传失败，请重试');
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('composer-attach')));
    await tester.pumpAndSettle();
    expect(find.text('报告.txt'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '请总结');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('composer-send')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('上传失败，请重试'), findsOneWidget);
    expect(find.text('报告.txt'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '请总结',
    );
    expect(submissions.single.attachments.single.path, file.path);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pumpAndSettle();
    expect(submissions, hasLength(2));
    expect(identical(submissions.first, submissions.last), isTrue);
    expect(find.text('报告.txt'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(textCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
