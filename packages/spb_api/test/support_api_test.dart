import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late SupportApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/pba');
    adapter = DioAdapter(dio: dio);
    api = SupportApi(dio);
  });

  final supportCase = <String, dynamic>{
    'case_ref': 'case-1',
    'subject': '页面无法打开',
    'description': '打开工作区时提示超时',
    'status': 'queued',
    'created_at': '2026-11-28T03:00:00Z',
    'updated_at': '2026-11-28T03:00:00Z',
  };

  test('list parses user-scoped cases and optional incident status', () async {
    adapter.onGet(
      '/me/support/cases',
      (server) => server.reply(200, {
        'items': [
          {...supportCase, 'incident_status': 'resolved'},
        ],
      }),
    );

    final items = await api.list();
    expect(items, hasLength(1));
    expect(items.single.caseRef, 'case-1');
    expect(items.single.incidentStatus, 'resolved');
    expect(items.single.createdAt.toUtc(), DateTime.utc(2026, 11, 28, 3));
  });

  test('submit accepts HTTP 202 and sends only the contract fields', () async {
    adapter.onPost(
      '/me/support/cases',
      (server) => server.reply(202, supportCase),
      data: {'subject': '页面无法打开', 'description': '打开工作区时提示超时'},
    );

    final created = await api.submit(
      subject: '页面无法打开',
      description: '打开工作区时提示超时',
    );
    expect(created.caseRef, 'case-1');
    expect(created.status, 'queued');
  });

  test('non-2xx responses remain errors', () async {
    adapter.onPost(
      '/me/support/cases',
      (server) => server.reply(503, {'error': 'support_unavailable'}),
      data: {'subject': 'x', 'description': 'y'},
    );
    await expectLater(
      api.submit(subject: 'x', description: 'y'),
      throwsA(isA<HttpError>()),
    );
  });
}
