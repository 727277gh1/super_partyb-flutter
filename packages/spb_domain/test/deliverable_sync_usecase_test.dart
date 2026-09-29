import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 内存落盘桩。
class _Sink implements FileSink {
  final written = <String, List<int>>{};

  @override
  Future<void> write(String relPath, List<int> bytes) async =>
      written[relPath] = bytes;

  @override
  Future<void> delete(String relPath) async => written.remove(relPath);
}

/// 内存状态库。
class _Store implements SyncStateStore {
  final data = <String, SyncState>{};
  int saves = 0;

  @override
  Future<SyncState> load(String key) async => data[key] ?? SyncState.empty;

  @override
  Future<void> save(String key, SyncState state) async {
    saves++;
    data[key] = state;
  }

  @override
  Future<void> reset(String key) async => data.remove(key);

  @override
  Future<void> resetAll() async => data.clear();
}

/// 记录调用的下载桩。
class _Downloader implements FileDownloader {
  final calls = <(String, String?)>[];

  @override
  Future<SyncDownloadResult> download(
    String fileId, {
    String? ifNoneMatch,
  }) async {
    calls.add((fileId, ifNoneMatch));
    return SyncDownloadResult.downloaded([1, 2, 3]);
  }
}

Map<String, dynamic> _file(String path, {String? etag = 'W/"1"'}) => {
  'id': 'id-$path',
  'path': path,
  'name': path.split('/').last,
  'size': 3,
  'mime_type': 'text/markdown',
  'is_directory': false,
  if (etag != null) 'etag': etag,
  'updated_at': '2026-05-01T00:00:00Z',
};

void main() {
  late Dio dio;
  late DioAdapter adapter;
  late _Store store;
  late _Sink sink;
  late _Downloader downloader;
  late DeliverableSyncUseCase useCase;

  const gid = 'g1';
  const root = '/workspace/groups/';

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/ufs');
    adapter = DioAdapter(dio: dio);
    store = _Store();
    sink = _Sink();
    downloader = _Downloader();
    useCase = DeliverableSyncUseCase(
      ufs: UfsApi(dio),
      stateStore: store,
      sink: sink,
      downloader: downloader,
      pageSize: 2,
    );
  });

  const scope = SyncGroupScope(gid);
  const filter = SyncFilterConfig(maxFileSize: 0, includeMedia: true);

  group('同步用例：分页拉取', () {
    test('拉完所有页再执行（不逐页推进游标）', () async {
      // 回归防线：逐页执行会中途推进游标，后续页里 updated_at 早于新游标的
      // 条目下一轮增量再也拉不到 —— 永久漏更新。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md'), _file('/workspace/groups/g1/b.md')],
          'total': 3,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/c.md')],
          'total': 3,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 2,
          'page_size': 2,
        },
      );

      final report = await useCase.run(scope: scope, filter: filter);

      expect(report.downloaded, 3, reason: '三页条目都要下载（不能只处理第一页）');
      expect(sink.written.keys.toSet(), {'a.md', 'b.md', 'c.md'});
      expect(store.saves, 1, reason: '整轮只写一次状态');
    });

    test('本页为空则终止（即使 total 声称还有更多）', () async {
      // 防服务端 total 异常导致客户端死循环。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'total': 999,
        }),
      );

      final report = await useCase.run(scope: scope, filter: filter);
      expect(report.downloaded, 0);
    });

    test('total 恰好是 pageSize 整数倍时不多发空请求', () async {
      // 只注册第 1 页的 mock：若实现多发一次第 2 页请求，DioAdapter 会因
      // 「no mock found」报错。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md'), _file('/workspace/groups/g1/b.md')],
          'total': 2,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      final report = await useCase.run(scope: scope, filter: filter);
      expect(report.downloaded, 2);
    });
  });

  group('同步用例：增量与删除', () {
    test('首次全量：不带 updated_since', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': [], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      await useCase.run(scope: scope, filter: filter);
      // 命中即证明 query 里没有 updated_since（否则 mock 不匹配）。
      expect(true, isTrue);
    });

    test('有游标时带 updated_since（增量）', () async {
      await store.save(
        syncStateKeyFor(scope),
        SyncState(cursor: '2026-04-01T00:00:00Z'),
      );

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': [], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'updated_since': '2026-04-01T00:00:00Z',
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      await useCase.run(scope: scope, filter: filter);
      expect(true, isTrue);
    });

    test('始终带 include_deleted=true（删除只能靠 deleted_at 感知）', () async {
      // 不加这个参数，远端删除的条目根本不出现在清单里，
      // 本地副本永远不会被清理。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': [], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      await useCase.run(scope: scope, filter: filter);
      expect(true, isTrue);
    });

    test('状态键用 workspaceStateKey（单 group 用 groupId）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md')],
          'total': 1,
        }),
      );

      await useCase.run(scope: scope, filter: filter);
      expect(store.data.containsKey(gid), isTrue);
      expect(store.data.containsKey(workspaceStateKey), isFalse);
    });
  });

  group('同步用例：状态持久化', () {
    test('成功后状态落盘（游标推进）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md')],
          'total': 1,
        }),
      );

      await useCase.run(scope: scope, filter: filter);
      expect(store.data[gid]!.cursor, '2026-05-01T00:00:00Z');
      expect(store.data[gid]!.contains('a.md'), isTrue);
    });

    test('列表请求失败时状态不变（不推进游标）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(500, {'error': 'boom'}),
      );

      await expectLater(
        useCase.run(scope: scope, filter: filter),
        throwsA(isA<SpbError>()),
      );
      expect(store.saves, 0, reason: '拿不到清单就不该写状态');
      expect(store.data, isEmpty);
    });
  });

  group('同步用例：304 映射', () {
    test('UfsDownload.notModified 映射为「未变更」而非 0 字节内容', () async {
      // 回归防线：若把 304 当成 0 字节内容，引擎会把本地已有文件覆盖成空文件。
      final notModifiedDio = createDio(baseUrl: 'https://api.test/ufs');
      final nmAdapter = DioAdapter(dio: notModifiedDio);
      nmAdapter.onGet(
        '/api/files/id-x/download',
        (server) => server.reply(304, null),
      );

      final d = UfsFileDownloader(UfsApi(notModifiedDio));
      final result = await d.download('id-x', ifNoneMatch: 'W/"1"');
      expect(result.notModified, isTrue);
      expect(result.bytes, isNull);
    });
  });
}
