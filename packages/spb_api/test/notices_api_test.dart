import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `NoticesApi` 的契约测试（`/me/notices`）。
///
/// ## 这个测试防的是什么
///
/// 通知中心与后台通知都靠这三个端点。四类错误会静默出错：
///
/// 1. **4xx 不抛**——`createDio` 的 `validateStatus` 放行 <500，不判状态码时
///    `{"error":"通知暂不可用"}` 会被解析成「字段全空的通知」；
/// 2. **`data` 是字符串映射**——`expires_at` 在 `data_json` 里，格式不保证，
///    解析失败必须降级为 null 而不是抛；
/// 3. **未知 `kind` / `severity`**——服务端会加新 kind，客户端不能因此崩；
/// 4. **批量 ack 的 404 不是错误**——全部 id 失效时服务端返回 404，客户端应
///    当作「这批 id 过期了」，下一轮重试，而不是弹错误。
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late NoticesApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = NoticesApi(dio);
  });

  Map<String, dynamic> noticeShape({
    String id = 'n1',
    String kind = 'confirmation_required',
    String? severity = 'warning',
    Map<String, String>? data,
    String? readAt,
  }) => {
    'id': id,
    'kind': kind,
    'severity': severity,
    'title': '需要你确认',
    'body': '需要确认是否继续重试',
    'data': data ?? {'confirmation_id': 'c1', 'expires_at': '2026-11-17T12:10:00Z'},
    'group_id': 'g1',
    'created_at': '2026-11-17T12:00:00Z',
    'updated_at': '2026-11-17T12:00:00Z',
    if (readAt != null) 'read_at': readAt,
  };

  group('list', () {
    test('解析 notices 与 unread，并把 data 当作字符串映射', () async {
      adapter.onGet(
        '/me/notices',
        (server) => server.reply(200, {
          'notices': [noticeShape()],
          'unread': 1,
        }),
        queryParameters: {'limit': 50},
      );

      final result = await api.list();
      expect(result.unread, 1);
      expect(result.notices, hasLength(1));
      final n = result.notices.single;
      expect(n.id, 'n1');
      expect(n.confirmationId, 'c1');
      expect(n.deepLinkGroupId, 'g1');
      expect(n.isRead, isFalse);
      // expires_at 在 data_json 里，解析成 DateTime（UTC 12:10 → 本地时间）。
      expect(n.cardExpiresAt, isNotNull);
    });

    test('unreadOnly 时带上 unread_only=1', () async {
      adapter.onGet(
        '/me/notices',
        (server) => server.reply(200, {'notices': <Object>[], 'unread': 0}),
        queryParameters: {'limit': 20, 'unread_only': '1'},
      );
      final result = await api.list(limit: 20, unreadOnly: true);
      expect(result.notices, isEmpty);
    });

    test('未知 severity 降级为 info，未知 kind 不抛', () async {
      adapter.onGet(
        '/me/notices',
        (server) => server.reply(200, {
          'notices': [
            noticeShape(kind: 'turn_completed', severity: 'brand_new_level'),
          ],
          'unread': 1,
        }),
        queryParameters: {'limit': 50},
      );
      final n = (await api.list()).notices.single;
      expect(n.kind, 'turn_completed');
      expect(n.severity, 'info');
    });

    test('data 里的 expires_at 格式非法时降级为 null，不抛', () async {
      adapter.onGet(
        '/me/notices',
        (server) => server.reply(200, {
          'notices': [
            noticeShape(data: {'expires_at': 'not-a-timestamp'}),
          ],
          'unread': 1,
        }),
        queryParameters: {'limit': 50},
      );
      final n = (await api.list()).notices.single;
      expect(n.cardExpiresAt, isNull);
      expect(n.isCardExpiredAt(DateTime.now()), isFalse);
    });

    test('4xx 抛 HttpError（否则错误体会被解析成空列表）', () async {
      adapter.onGet(
        '/me/notices',
        (server) => server.reply(503, {'error': '通知暂不可用'}),
        queryParameters: {'limit': 50},
      );
      expect(api.list(), throwsA(isA<HttpError>()));
    });
  });

  test('unreadCount 解析 unread', () async {
    adapter.onGet(
      '/me/notices/unread-count',
      (server) => server.reply(200, {'unread': 3}),
    );
    expect(await api.unreadCount(), 3);
  });

  group('markRead', () {
    test('部分成功返回 updated 与 missing', () async {
      adapter.onPost(
        '/me/notices/read',
        (server) => server.reply(200, {
          'status': 'ok',
          'updated': 1,
          'missing': ['gone'],
        }),
        data: {
          'ids': ['n1', 'gone'],
        },
      );
      final r = await api.markRead(ids: ['n1', 'gone']);
      expect(r.updated, 1);
      expect(r.missing, ['gone']);
      expect(r.isAllMissing, isFalse);
    });

    test('404 归一为「全部失效」而不是抛错', () async {
      adapter.onPost(
        '/me/notices/read',
        (server) => server.reply(404, {'error': '通知不存在'}),
        data: {
          'ids': ['gone-1', 'gone-2'],
        },
      );
      final r = await api.markRead(ids: ['gone-1', 'gone-2']);
      expect(r.updated, 0);
      expect(r.missing, ['gone-1', 'gone-2']);
      expect(r.isAllMissing, isTrue);
    });

    test('all=true 时发 {all: true}', () async {
      adapter.onPost(
        '/me/notices/read',
        (server) => server.reply(200, {'status': 'ok', 'updated': 2}),
        data: {'all': true},
      );
      final r = await api.markRead(all: true);
      expect(r.updated, 2);
    });

    test('空 ids 且非 all 直接抛 400，不发请求', () async {
      expect(api.markRead(), throwsA(isA<HttpError>()));
    });
  });
}
