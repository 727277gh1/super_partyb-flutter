import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_mobile/providers.dart';
import 'package:spb_mobile/router.dart';
import 'package:spb_platform/spb_platform.dart';

import 'support/mobile_harness.dart';

void main() {
  const channel = MethodChannel('com.atjog.spb/external_quick_capture');
  const clipboardLaunch = ExternalQuickCapture(
    text: '',
    files: [],
    readClipboard: true,
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('磁贴读取在首帧之后完成，编辑与前后台切换不重新读取，发送后关闭', (tester) async {
    final clipboard = Completer<Map<String, dynamic>>();
    var reads = 0;
    var finishes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'readClipboard') {
        reads++;
        return clipboard.future;
      }
      if (call.method == 'finish') finishes++;
      return null;
    });
    final h = await pumpApp(
      tester,
      externalQuickCapture: clipboardLaunch,
      beforePump: (adapter) {
        adapter.onPost('/me/quick-capture/enqueue', (server) {
          server.reply(202, {'accepted': true});
        }, data: Matchers.any);
      },
    );
    final sent = <String>[];
    h.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/quick-capture/enqueue')) {
            sent.add((options.data as Map)['input'] as String);
          }
          handler.next(options);
        },
      ),
    );
    h.router.go(SpbRoutes.overlay);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(reads, 1);
    clipboard.complete({'text': '刚复制的文字'});
    await tester.pumpAndSettle();
    expect(find.text('刚复制的文字'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('overlay-input')),
      '编辑后的问题',
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('编辑后的问题'), findsOneWidget);
    expect(sent, isEmpty, reason: '读取剪贴板不会自动发送');
    await tester.tap(find.byKey(const ValueKey('overlay-submit')));
    await tester.pumpAndSettle();
    expect(sent, ['编辑后的问题']);
    expect(finishes, 1);
  });

  testWidgets('未登录时磁贴不读取剪贴板，登录后再预填草稿', (tester) async {
    var reads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'readClipboard') {
        reads++;
        return {'text': '登录后可见的文字'};
      }
      return null;
    });
    final tokens = InMemoryTokenStore();
    final h = await pumpApp(
      tester,
      initialLocation: SpbRoutes.overlay,
      externalQuickCapture: clipboardLaunch,
      tokenStore: tokens,
    );
    expect(reads, 0);
    expect(h.router.routeInformationProvider.value.uri.path, SpbRoutes.login);
    await tokens.write(freshTokens());
    await h.container.read(authStateProvider.notifier).restore();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('登录后可见的文字'), findsOneWidget);
  });

  testWidgets('空剪贴板显示提示，手动输入仍可发送', (tester) async {
    var finishes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'readClipboard') {
        return {'error': '剪贴板没有文字，请先复制文字，或在这里直接输入。'};
      }
      if (call.method == 'finish') finishes++;
      return null;
    });
    await pumpApp(
      tester,
      initialLocation: SpbRoutes.overlay,
      externalQuickCapture: clipboardLaunch,
      beforePump: (adapter) {
        adapter.onPost('/me/quick-capture/enqueue', (server) {
          server.reply(202, {'accepted': true});
        }, data: Matchers.any);
      },
    );
    expect(find.textContaining('剪贴板没有文字'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('overlay-input')), '手动输入');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('overlay-submit')));
    await tester.pumpAndSettle();
    expect(finishes, 1);
  });

  testWidgets('应用锁定时不读取剪贴板', (tester) async {
    var reads = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'readClipboard') reads++;
      return {'text': '锁定时不可读取'};
    });
    final h = await pumpApp(tester, externalQuickCapture: clipboardLaunch);
    h.container.read(authStateProvider.notifier).lock();
    h.router.go(SpbRoutes.overlay);
    await tester.pumpAndSettle();
    expect(h.router.routeInformationProvider.value.uri.path, SpbRoutes.lock);
    expect(reads, 0);
    expect(find.text('锁定时不可读取'), findsNothing);
  });

  testWidgets('等待窗口焦点时仍可通过返回键关闭临时页', (tester) async {
    final clipboard = Completer<Map<String, dynamic>>();
    var finishes = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'readClipboard') return clipboard.future;
      if (call.method == 'finish') finishes++;
      return null;
    });
    final h = await pumpApp(tester, externalQuickCapture: clipboardLaunch);
    h.router.go(SpbRoutes.overlay);
    await tester.pump();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(finishes, 1);
    clipboard.complete({'text': ''});
    await tester.pumpAndSettle();
  });

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
