import 'dart:async';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

class _Store implements ConfirmationReceiptStore {
  Map<String, ConfirmationReceipt> receipts = {};
  @override
  Future<T> exclusive<T>(Future<T> Function() action) => action();
  @override
  Future<Map<String, ConfirmationReceipt>> loadReceipts() async => {
    ...receipts,
  };
  @override
  Future<void> saveReceipts(Map<String, ConfirmationReceipt> value) async {
    receipts = {...value};
  }
}

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late NoticeCenter center;
  late _Store store;
  late List<LocalNotification> shown;
  late List<String> cancelled;
  late List<Map<String, Object?>> rows;
  late int generation;
  late bool focused;

  Map<String, Object?> notice({
    String kind = 'turn_completed',
    String version = '01',
    bool read = false,
  }) => {
    'id': 'n1',
    'kind': kind,
    'severity': 'info',
    'title': '服务端标题',
    'body': '服务端正文',
    'group_id': 'g1',
    'created_at': '2026-11-20T10:00:00Z',
    'updated_at': '2026-11-20T10:00:${version}Z',
    if (read) 'read_at': '2026-11-20T10:01:00Z',
  };

  setUp(() {
    dio = Dio();
    adapter = DioAdapter(dio: dio);
    rows = [notice()];
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          if (response.requestOptions.path == '/me/notices') {
            response.data = {'notices': rows, 'unread': 0};
          }
          handler.next(response);
        },
      ),
    );
    generation = 1;
    focused = false;
    shown = [];
    cancelled = [];
    store = _Store();
    adapter.onGet(
      '/me/notices',
      (s) => s.reply(200, {
        'notices': rows,
        // 故意不依赖未读数来决定是否读取内容。
        'unread': 0,
      }),
      queryParameters: {'limit': 200},
    );
    center = NoticeCenter(
      api: NoticesApi(dio),
      inbox: ConfirmationNotificationInbox(
        store: store,
        show: (n) async {
          shown.add(n);
          return true;
        },
        cancel: (id) async => cancelled.add(id),
        canNotify: () async => true,
      ),
      sessionVersion: () async => generation,
      isFocused: () => focused,
    );
  });
  tearDown(() {
    center.dispose();
    dio.close();
  });

  test('完成、失败及未来新增类型均由服务端驱动，同 ID 新版本仍通知', () async {
    await center.refresh();
    await center.refresh();
    expect(shown, hasLength(1));
    rows = [notice(kind: 'turn_failed', version: '02')];
    await center.refresh();
    rows = [notice(kind: 'future_kind', version: '03')];
    await center.refresh();
    expect(shown, hasLength(3));
    expect(shown.last.title, '服务端标题');
    expect(shown.last.payload, '/chat/g1');
  });

  test('前台不弹系统通知、不自动 ack，失焦后不补弹相同版本', () async {
    focused = true;
    await center.refresh();
    expect(center.snapshot.notices.single.isRead, isFalse);
    focused = false;
    await center.refresh();
    expect(shown, isEmpty);
    rows = [notice(version: '02')];
    await center.refresh();
    expect(shown, hasLength(1));
  });

  test('别端已读撤销横幅，服务端重新覆盖后再次通知', () async {
    await center.refresh();
    rows = [notice(version: '02', read: true)];
    await center.refresh();
    expect(cancelled, ['n1']);
    rows = [notice(version: '03')];
    await center.refresh();
    expect(shown, hasLength(2));
  });

  test('显式 ack 后刷新权威列表，失败保留未读并可重试', () async {
    await center.refresh();
    adapter.onPost(
      '/me/notices/read',
      (s) => s.reply(503, <String, Object?>{}),
      data: {
        'ids': ['n1'],
      },
    );
    await expectLater(center.markRead(ids: ['n1']), throwsA(isA<HttpError>()));
    expect(center.snapshot.notices.single.isRead, isFalse);
    adapter.onPost(
      '/me/notices/read',
      (s) => s.reply(200, {'updated': 1}),
      data: {
        'ids': ['n1'],
      },
    );
    rows = [notice(read: true)];
    await center.markRead(ids: ['n1']);
    expect(center.snapshot.notices.single.isRead, isTrue);
    expect(cancelled, ['n1']);
  });

  test('请求在途换账号，旧响应和旧界面的 ack 均丢弃', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          entered.complete();
          await release.future;
          handler.next(response);
        },
      ),
    );
    final pending = center.refresh();
    await entered.future;
    generation++;
    release.complete();
    await pending;
    await center.markRead(all: true);
    expect(shown, isEmpty);
    expect(center.snapshot.notices, isEmpty);
  });

  test('卸载后在途响应不能通知或写快照', () async {
    dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          center.dispose();
          handler.next(response);
        },
      ),
    );
    await center.refresh();
    expect(shown, isEmpty);
    expect(store.receipts, isEmpty);
  });
}
