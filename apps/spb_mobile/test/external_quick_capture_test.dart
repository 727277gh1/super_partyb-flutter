import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_mobile/router.dart';
import 'package:spb_platform/spb_platform.dart';

import 'support/mobile_harness.dart';

void main() {
  testWidgets('外部文字和截图预填，发送失败留在草稿，成功后结束临时 Activity', (tester) async {
    var finishes = 0;
    var enqueues = 0;
    const channel = MethodChannel('com.atjog.spb/external_quick_capture');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'finish') finishes++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final h = await pumpApp(
      tester,
      externalQuickCapture: ExternalQuickCapture(
        text: '解释截图',
        files: [
          DroppedFile.fromBytes(name: '截图.png', bytes: [1, 2, 3]),
        ],
      ),
      beforePump: (adapter) {
        adapter.onPost(
          '/me/quick-capture/attachments',
          (server) => server.reply(503, {'error': '上传暂不可用'}),
          data: Matchers.any,
        );
        adapter.onPost('/me/quick-capture/enqueue', (server) {
          server.reply(202, {'accepted': true});
        }, data: Matchers.any);
      },
    );
    h.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/quick-capture/enqueue')) enqueues++;
          handler.next(options);
        },
      ),
    );
    h.router.go(SpbRoutes.overlay);
    await tester.pumpAndSettle();
    expect(find.text('解释截图'), findsOneWidget);
    expect(find.text('截图.png'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('overlay-submit')));
    await tester.pumpAndSettle();
    expect(finishes, 0);
    expect(enqueues, 0, reason: '不能只发文字并丢掉分享的截图');
    expect(find.text('解释截图'), findsOneWidget);
    expect(find.text('截图.png'), findsOneWidget);
    h.adapter.onPost(
      '/me/quick-capture/attachments',
      (server) => server.reply(201, {
        'file_id': 'shared-file',
        'file_name': '截图.png',
        'size': 3,
      }),
      data: Matchers.any,
    );
    await tester.tap(find.byKey(const ValueKey('overlay-submit')));
    await tester.pumpAndSettle();
    expect(enqueues, 1);
    expect(finishes, 1);
  });

  testWidgets('外部草稿按系统返回需确认，取消离开时不调用结束', (tester) async {
    var finishes = 0;
    const channel = MethodChannel('com.atjog.spb/external_quick_capture');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'finish') finishes++;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final h = await pumpApp(
      tester,
      externalQuickCapture: const ExternalQuickCapture(
        text: '选中的文字',
        files: [],
      ),
    );
    h.router.go(SpbRoutes.overlay);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('overlay-discard-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('overlay-discard-cancel')));
    await tester.pumpAndSettle();
    expect(finishes, 0);
    expect(find.text('选中的文字'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overlay-discard-confirm')));
    await tester.pumpAndSettle();
    expect(finishes, 1);
  });
}
