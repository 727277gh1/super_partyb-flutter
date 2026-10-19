import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// 记录实际发出的请求（query 键名与 headers）。
///
/// ## 为什么不用 DioAdapter 的 `queryParameters` 匹配
///
/// 那只能断言「匹配上了」，失败信息是「no mock found」，看不出实际发了什么。
/// 而本文件的核心断言恰恰是**query 键名**（`path_prefix` 而非 `pathPrefix`）
/// ——键名写错时 DioAdapter 只会说「未命中」，排查成本高。
///
/// 用拦截器把真实请求原样记下来，断言就能直接给出「期望 X 实际 Y」。
class _RequestRecorder extends Interceptor {
  final requests = <RequestOptions>[];

  RequestOptions get last => requests.last;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    handler.next(options);
  }
}

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late _RequestRecorder recorder;
  late UfsApi api;

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/ufs');
    recorder = _RequestRecorder();
    // 拦截器必须在 DioAdapter 之前记录：DioAdapter 命中后就直接返回了。
    dio.interceptors.insert(0, recorder);
    adapter = DioAdapter(dio: dio);
    api = UfsApi(dio);
  });

  /// `model.FileResponse` 的真实形状（`internal/model/model.go`）。
  Map<String, dynamic> fileResponseShape({
    String id = 'file_1',
    String path = 'grp_1/reports/a.md',
    int size = 1234,
    String? mimeType = 'text/markdown',
    String? etag = 'W/"abc123"',
    String updatedAt = '2026-03-01T00:00:00Z',
    String? deletedAt,
    bool isDirectory = false,
  }) => {
    'id': id,
    'owner_type': 'user',
    'owner_id': 'usr_1',
    'parent_id': null,
    'name': 'a.md',
    'path': path,
    'is_directory': isDirectory,
    'size': size,
    'mime_type': mimeType,
    'is_public': false,
    'metadata_json': <String, dynamic>{},
    'uploaded_by': 'usr_1',
    'created_at': '2026-02-01T00:00:00Z',
    'updated_at': updatedAt,
    if (deletedAt != null) 'deleted_at': deletedAt,
    if (etag != null) 'etag': etag,
  };

  group('UFS listFiles', () {
    test('query 键名对齐服务端（snake_case，不是 camelCase）', () async {
      // 回归防线：Go 侧读的是 path_prefix / updated_since / include_deleted /
      // exclude_prefix / page_size。写成 pathPrefix 不会报错——服务端只是
      // 忽略未知参数，于是「过滤没生效」而列表照常返回，极难发现。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
      );

      await api.listFiles(
        pathPrefix: 'grp_1/',
        updatedSince: '2026-03-01T00:00:00Z',
        includeDeleted: true,
        excludePrefix: ['reports/tts/', 'tmp/'],
        page: 2,
        pageSize: 50,
      );

      final q = recorder.last.uri.queryParametersAll;
      expect(q['path_prefix'], ['grp_1/']);
      expect(q['updated_since'], ['2026-03-01T00:00:00Z']);
      expect(q['include_deleted'], ['true']);
      // exclude_prefix 可重复传递（服务端用 Query()["exclude_prefix"] 收多个）。
      expect(q['exclude_prefix'], ['reports/tts/', 'tmp/']);
      expect(q['page'], ['2']);
      expect(q['page_size'], ['50']);
      expect(q['owner_type'], ['user']);

      // 反向断言：不得出现 camelCase 键名。
      expect(q.keys, isNot(contains('pathPrefix')));
      expect(q.keys, isNot(contains('updatedSince')));
      expect(q.keys, isNot(contains('includeDeleted')));
      expect(q.keys, isNot(contains('excludePrefix')));
      expect(q.keys, isNot(contains('pageSize')));
    });

    test('默认参数：不传 include_deleted（避免看起来像已开启）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
      );

      await api.listFiles();

      final q = recorder.last.uri.queryParametersAll;
      expect(q.containsKey('include_deleted'), isFalse);
      expect(q.containsKey('path_prefix'), isFalse);
      expect(q.containsKey('updated_since'), isFalse);
      expect(q.containsKey('exclude_prefix'), isFalse);
      expect(q['owner_type'], ['user']);
      expect(q['page'], ['1']);
      expect(q['page_size'], ['20']);
    });

    test('解析 {items,total} 与条目字段', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            fileResponseShape(),
            fileResponseShape(
              id: 'file_2',
              path: 'grp_1/reports/b.md',
              size: 7,
              mimeType: null,
              etag: null,
              deletedAt: '2026-03-02T00:00:00Z',
            ),
          ],
          'total': 42,
        }),
      );

      final page = await api.listFiles(includeDeleted: true);

      expect(page.items, hasLength(2));
      expect(page.total, 42, reason: 'total 是服务端匹配总数，不能丢');
      expect(page.hasMore(page: 1, pageSize: 20), isTrue);

      final a = page.items.first;
      expect(a.id, 'file_1');
      expect(a.path, 'grp_1/reports/a.md');
      expect(a.size, 1234);
      expect(a.mimeType, 'text/markdown');
      expect(a.etag, 'W/"abc123"');
      expect(a.isDirectory, isFalse);
      expect(a.isDeleted, isFalse);
      expect(a.updatedAt, isNotNull);

      final b = page.items[1];
      expect(b.mimeType, isNull);
      expect(b.etag, isNull, reason: 'omitempty 缺失的 etag 应为 null');
      expect(b.isDeleted, isTrue, reason: 'deleted_at 非空 = 远端已删除');
    });

    test('total 与 items 不一致时以 total 判断还有下一页', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [fileResponseShape()],
          'total': 1,
        }),
      );

      final page = await api.listFiles();
      expect(page.hasMore(page: 1, pageSize: 20), isFalse);
      expect(page.hasMore(page: 2, pageSize: 1), isFalse);
    });

    test('4xx 显式抛 HttpError（不静默解析成空对象）', () async {
      // 回归防线：createDio 的 validateStatus 放行 <500，不判状态码的话
      // `404 {"error":"..."}` 会被 fromJson 解析成「字段全空的对象」，
      // 表现为「同步拿到了 0 个文件」而不是报错。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(404, {'error': 'not found'}),
      );

      await expectLater(
        api.listFiles(),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('403 抛 AuthError（凭证问题，不是请求问题）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(403, {'error': 'forbidden'}),
      );

      await expectLater(api.listFiles(), throwsA(isA<AuthError>()));
    });

    test('5xx 抛 HttpError（可重试）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        api.listFiles(),
        throwsA(
          isA<HttpError>().having(
            (e) => e.isServerError,
            'isServerError',
            isTrue,
          ),
        ),
      );
    });
  });

  group('UFS download', () {
    test('200：返回字节内容与 etag', () async {
      adapter.onGet(
        '/api/files/file_1/download',
        (server) => server.reply(
          200,
          // 必须是 Uint8List：http_mock_adapter 只对 Uint8List 走
          // fromBytes，普通 List<int> 会被 jsonEncode 成字符串，
          // 于是 dio 把它当 bytes 解析时类型不匹配而抛。
          Uint8List.fromList([104, 101, 108, 108, 111]), // "hello"
          headers: {
            'etag': ['W/"abc123"'],
            'content-type': ['text/markdown'],
          },
        ),
      );

      final result = await api.download('file_1');

      expect(result.notModified, isFalse);
      expect(result.bytes, [104, 101, 108, 108, 111]);
      expect(result.length, 5);
      expect(result.etag, 'W/"abc123"');
      expect(result.contentType, 'text/markdown');
    });

    test('304：返回「未变更」而不是抛错，且不带内容', () async {
      // 这是本任务的关键断言：304 是正常业务结果（缓存命中）。
      // 若不显式判状态码，304 会带着空正文正常返回，被当成
      // 「下载到了 0 字节文件」→ 把本地已有文件覆盖成空文件。
      adapter.onGet(
        '/api/files/file_1/download',
        (server) => server.reply(
          304,
          Uint8List(0),
          headers: {
            'etag': ['W/"abc123"'],
          },
        ),
      );

      final result = await api.download('file_1', ifNoneMatch: 'W/"abc123"');

      expect(result.notModified, isTrue);
      expect(result.bytes, isNull, reason: '304 不得带内容');
      expect(result.length, 0);
      expect(result.etag, 'W/"abc123"', reason: '304 仍应回传 etag 供更新本地记录');
    });

    test('If-None-Match 头按传入值发送', () async {
      adapter.onGet(
        '/api/files/file_1/download',
        (server) => server.reply(
          200,
          Uint8List.fromList([1]),
          headers: {
            'etag': ['W/"new"'],
          },
        ),
      );

      await api.download('file_1', ifNoneMatch: 'W/"old"');

      expect(recorder.last.headers['If-None-Match'], 'W/"old"');
      // 用 bytes 响应类型：默认 json 会尝试解析二进制/文本内容并破坏它。
      expect(recorder.last.responseType, ResponseType.bytes);
    });

    test('不传 ifNoneMatch 时不发送该头', () async {
      adapter.onGet(
        '/api/files/file_1/download',
        (server) => server.reply(
          200,
          Uint8List.fromList([1]),
          headers: {
            'etag': ['W/"x"'],
          },
        ),
      );

      await api.download('file_1');

      expect(recorder.last.headers.containsKey('If-None-Match'), isFalse);
    });

    test('404 显式抛 HttpError', () async {
      adapter.onGet(
        '/api/files/missing/download',
        (server) => server.reply(404, {'error': '文件不存在'}),
      );

      await expectLater(
        api.download('missing'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('etag 原样保留（不剥 W/ 前缀或引号）', () async {
      // 服务端 etagMatch 同时处理强弱 etag；客户端改写会让下一轮
      // If-None-Match 匹配不上，于是每次都要重下。
      adapter.onGet(
        '/api/files/file_1/download',
        (server) => server.reply(
          200,
          Uint8List.fromList([1]),
          headers: {
            'etag': ['W/"a-b"'],
          },
        ),
      );

      final result = await api.download('file_1');
      expect(result.etag, 'W/"a-b"');
    });
  });

  group('UFS getFile', () {
    test('解析单条目', () async {
      adapter.onGet(
        '/api/files/file_1',
        (server) => server.reply(200, fileResponseShape()),
      );

      final entry = await api.getFile('file_1');
      expect(entry.id, 'file_1');
      expect(entry.path, 'grp_1/reports/a.md');
    });

    test('404 显式抛 HttpError', () async {
      adapter.onGet(
        '/api/files/nope',
        (server) => server.reply(404, {'error': '文件不存在'}),
      );

      await expectLater(api.getFile('nope'), throwsA(isA<HttpError>()));
    });
  });

  group('UFS thumbnail', () {
    test('200：返回图片字节，且用 bytes 响应类型与默认 256 档位', () async {
      adapter.onGet(
        '/api/files/file_1/thumbnails/256',
        (server) => server.reply(
          200,
          Uint8List.fromList([137, 80, 78, 71]), // PNG magic
          headers: {
            'content-type': ['image/png'],
            'x-thumbnail-width': ['256'],
          },
        ),
      );

      final bytes = await api.thumbnail('file_1');

      expect(bytes, [137, 80, 78, 71]);
      // 用 bytes 响应类型：默认 json 会拿 PNG 去按 JSON 解析并破坏内容。
      expect(recorder.last.responseType, ResponseType.bytes);
    });

    test('size 参数拼进路径（合法档位由服务端把关）', () async {
      adapter.onGet(
        '/api/files/file_1/thumbnails/64',
        (server) => server.reply(200, Uint8List.fromList([1])),
      );

      await api.thumbnail('file_1', size: 64);

      expect(recorder.last.path, '/api/files/file_1/thumbnails/64');
    });

    test('304：返回 null（无正文可渲染，不是错误）', () async {
      // `validateStatus` 放行所有 <500，304 会带空正文正常返回。不显式判
      // 就会变成「取到 0 字节图片」→ `Image.memory` 抛异常。
      adapter.onGet(
        '/api/files/file_1/thumbnails/256',
        (server) => server.reply(304, Uint8List(0)),
      );

      expect(await api.thumbnail('file_1'), isNull);
    });

    test('501 缩略图服务未启用：返回 null 而非抛错', () async {
      // 这是本任务的关键断言：501 是部署未启用该能力时的**正常**响应。
      // 抛错会让一张图就让整卡显示失败，且可能被误当成「下载失败」。
      adapter.onGet(
        '/api/files/file_1/thumbnails/256',
        (server) => server.reply(501, {'error': '缩略图服务未启用'}),
      );

      expect(await api.thumbnail('file_1'), isNull);
    });

    test('400 尺寸无效：抛 HttpError（带状态码便于定位）', () async {
      adapter.onGet(
        '/api/files/file_1/thumbnails/999',
        (server) => server.reply(400, {'error': '缩略图尺寸无效'}),
      );

      await expectLater(
        api.thumbnail('file_1', size: 999),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 400),
        ),
      );
    });

    test('404 显式抛 HttpError（不静默当成无缩略图）', () async {
      // 404 与 501 语义不同：501 是「本部署没这能力」（预期内），
      // 404 是「文件不在了」（异常）。混为一谈会掩盖真实问题。
      adapter.onGet(
        '/api/files/missing/thumbnails/256',
        (server) => server.reply(404, {'error': '文件不存在'}),
      );

      await expectLater(
        api.thumbnail('missing'),
        throwsA(
          isA<HttpError>().having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });
  });
}
