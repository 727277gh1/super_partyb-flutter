import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/src/settings/notice_center_card.dart';

class _Store implements ConfirmationReceiptStore {
  Map<String, ConfirmationReceipt> rows = {};
  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<Map<String, ConfirmationReceipt>> loadReceipts() async => rows;
  @override
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> receipts) async {
    rows = receipts;
  }
}

void main() {
  testWidgets('显示失败与过期确认通知，显式已读并跳转，刷新失败可见', (tester) async {
    final dio = Dio();
    final adapter = DioAdapter(dio: dio);
    var read = false;
    var fail = false;
    var writes = 0;
    String? opened;
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.requestOptions.path == '/me/notices') {
            response.statusCode = fail ? 503 : 200;
            response.data = {
              'notices': [
                {
                  'id': 'n1',
                  'kind': 'confirmation_required',
                  'severity': 'warning',
                  'title': '服务端确认通知',
                  'body': '确认内容',
                  'group_id': 'g1',
                  'data': {'expires_at': '2020-01-01T00:00:00Z'},
                  'created_at': '2026-11-20T10:00:00Z',
                  if (read) 'read_at': '2026-11-20T10:01:00Z',
                },
              ],
              'unread': read ? 0 : 1,
            };
          } else {
            read = true;
            writes++;
          }
          handler.next(response);
        },
      ),
    );
    adapter.onGet(
      '/me/notices',
      (s) => s.reply(200, <String, Object?>{}),
      queryParameters: {'limit': 200},
    );
    adapter.onPost(
      '/me/notices/read',
      (s) => s.reply(200, {'updated': 1}),
      data: {
        'ids': ['n1'],
      },
    );
    final center = NoticeCenter(
      api: NoticesApi(dio),
      inbox: ConfirmationNotificationInbox(
        store: _Store(),
        show: (_) async => true,
        cancel: (_) async {},
        canNotify: () async => true,
      ),
      sessionVersion: () async => 1,
      isFocused: () => true,
    );
    addTearDown(center.dispose);
    addTearDown(dio.close);
    await tester.runAsync(center.refresh);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NoticeCenterCard(
            center: center,
            onOpen: (route) => opened = route,
          ),
        ),
      ),
    );
    expect(find.text('通知中心 · 1 条未读'), findsOneWidget);
    expect(find.text('确认内容（已失效，仅作记录）'), findsOneWidget);
    expect(writes, 0);
    await tester.tap(find.text('查看对话'));
    expect(opened, '/chat/g1');
    expect(writes, 0);
    await tester.tap(find.text('标记已读'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('标记已读'), findsNothing);
    fail = true;
    await tester.runAsync(center.refresh);
    await tester.pump();
    expect(find.text('通知暂时无法加载，请重试'), findsOneWidget);
  });
}
