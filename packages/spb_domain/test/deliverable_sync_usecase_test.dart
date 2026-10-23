import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 内存落盘桩。
class _Sink implements FileSink, LocalFileReader {
  final written = <String, List<int>>{};

  /// 模拟上次同步留下的本地副本（[exists] 为真）。
  final preExisting = <String>{};

  @override
  Future<void> write(String relPath, List<int> bytes) async =>
      written[relPath] = bytes;

  @override
  Future<void> delete(String relPath) async => written.remove(relPath);

  @override
  Future<bool> exists(String relPath) async =>
      written.containsKey(relPath) || preExisting.contains(relPath);

  /// 读取已写入的字节；preExisting 模拟的「磁盘上有但状态外」的文件无法提供
  /// 内容（测试里不记录），同样抛错。
  @override
  Future<List<int>> readBytes(String relPath) async {
    final bytes = written[relPath];
    if (bytes == null) {
      throw Exception('桩中无该文件内容：$relPath');
    }
    return bytes;
  }
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
    return const SyncDownloadResult.downloaded([1, 2, 3]);
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
  // 单 group 范围收窄到该 group 的子树（见 `_pathPrefixFor`）。
  const groupPrefix = '$root$gid';

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
          'items': [
            _file('/workspace/groups/g1/a.md'),
            _file('/workspace/groups/g1/b.md'),
          ],
          'total': 3,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
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
          'path_prefix': groupPrefix,
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
          'items': [
            _file('/workspace/groups/g1/a.md'),
            _file('/workspace/groups/g1/b.md'),
          ],
          'total': 2,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
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
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
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
        const SyncState(cursor: '2026-04-01T00:00:00Z'),
      );

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
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
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
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

  group('同步用例：列举前缀按范围收窄', () {
    test('单 group 只列该 group 的子树（不拉整个 workspace）', () async {
      // ## 为什么这条重要
      //
      // 「进入对话时同步该 group 的文档」若仍列全 workspace，就还是把
      // 5666 条元数据拉一遍——用户感知不到「只同步这个对话」。
      //
      // 这里只注册 group 前缀的 mock：若实现仍用全前缀，DioAdapter 会因
      // 「no mock found」失败（比断言更直接）。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      final report = await useCase.run(scope: scope, filter: filter);
      expect(report.downloaded, 1);
    });

    test('workspace 范围仍列全 workspace（前缀不收窄）', () async {
      // 选中若干 group 的过滤在 `SyncScope.relativePath` 里做（未选中的记为
      // invalidPath）。若为它也收窄成多个前缀，就得分多次列举再合并——
      // 而「多次列举 + 单游标」正是漏文件的经典来源。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/ga/a.md')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      await useCase.run(
        scope: const SyncGroupsScope(['ga']),
        filter: const SyncFilterConfig(),
      );
    });
  });

  group('同步用例：定向同步（SyncSingleGroupScope）', () {
    test('不推进游标，但文件记录照常合并', () async {
      // ## 为什么这是「只同步一个 group」能安全的前提
      //
      // 全部 / 勾选若干共用 `__workspace__` 单个游标。若定向同步也推进它，
      // 游标就会越过其它 group 里从未同步过的文件——它们此后再也不出现在
      // 增量清单里（`updated_since` 过滤），**永久漏下载而报告显示成功**。
      //
      // 本 group 无文件记录 → 水位为空 → 不带 `updated_since`（全量列本 group
      // 子树，代价仅一页元数据，且靠 etag 命中跳过已有文件）。
      await store.save(
        workspaceStateKey,
        const SyncState(cursor: '2026-04-01T00:00:00Z'),
      );

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
          'include_deleted': 'true',
          'page': 1,
          'page_size': 2,
        },
      );

      final report = await useCase.run(
        scope: const SyncSingleGroupScope(gid),
        filter: const SyncFilterConfig(),
      );

      expect(report.downloaded, 1);
      final saved = store.data[workspaceStateKey]!;
      expect(
        saved.cursor,
        '2026-04-01T00:00:00Z',
        reason: '定向同步不得推进游标（保持原值，不是清空）',
      );
      expect(
        saved.contains('g1/a.md'),
        isTrue,
        reason: '文件记录要照常写（后续全范围同步靠 etag 命中跳过，不重复下载）',
      );
    });

    test('时间下限用**本 group 水位**，不用共享游标', () async {
      // ## 为什么这不能是共享游标
      //
      // 共享游标是「整个 workspace 已同步到哪」，可能远晚于本 group 的进度
      // （用户刚把本 group 勾进范围、或上一轮全范围同步时它被过滤）。拿它
      // 当下限会把本 group 真正缺失的旧文件**过滤掉**——而判定
      // （`checkGroupSyncNeedProvider`）用的是本 group 水位，于是会出现
      // 「提示条说有 3 个未同步，点下去下载 0 个且报告成功」。
      //
      // 用本 group 水位是**更宽**的下限（水位 ≤ 共享游标），不会多漏文件；
      // 重复列出的靠 etag 命中跳过。
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: '2026-05-01T00:00:00Z',
          files: {
            'g1/old.md': SyncedFile(size: 1, updatedAt: '2026-04-01T00:00:00Z'),
          },
        ),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {'items': <dynamic>[], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
          'include_deleted': 'true',
          // 共享游标是 05-01，这里必须是本 group 水位的 04-01。
          'updated_since': '2026-04-01T00:00:00Z',
          'page': 1,
          'page_size': 2,
        },
      );

      await useCase.run(
        scope: const SyncSingleGroupScope(gid),
        filter: const SyncFilterConfig(),
      );
    });

    test('共享游标晚于本 group 进度时，不拿它过滤本 group 的文件', () async {
      // 回归防线：曾经用 `state.cursor` 当下限，于是「共享游标已到 05-01，
      // 但本 group 只同步过 04-01 的文件」时，04-01 之后、05-01 之前的那些
      // 文件永远不会被拉下来——报告却显示成功。
      await store.save(
        workspaceStateKey,
        const SyncState(
          cursor: '2026-05-01T00:00:00Z',
          files: {
            'g1/old.md': SyncedFile(size: 1, updatedAt: '2026-04-01T00:00:00Z'),
          },
        ),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/missed.md')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': groupPrefix,
          'include_deleted': 'true',
          'updated_since': '2026-04-01T00:00:00Z',
          'page': 1,
          'page_size': 2,
        },
      );

      final report = await useCase.run(
        scope: const SyncSingleGroupScope(gid),
        filter: const SyncFilterConfig(),
      );

      expect(report.downloaded, 1);
      expect(store.data[workspaceStateKey]!.contains('g1/missed.md'), isTrue);
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

    test('状态里有记录但本地文件已被删 → 走无条件请求，文件重新落盘', () async {
      // ## 端到端回归（真实 bug）
      //
      // 原实现只看 `state.contains(relPath)`（「曾经同步过」），不看磁盘。
      // 用户手动删掉文件后，引擎仍带 If-None-Match → 服务端 304 → 判为
      // 「未变更」跳过写入 → 文件永远回不来，报告却显示成功。
      //
      // 本用例走完整链路（UfsApi + 分页 + 引擎 + 状态落盘），只 mock HTTP。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'updated_since': '2026-04-01T00:00:00Z',
          'page': 1,
          'page_size': 2,
        },
      );

      // 预置状态：etag 与远端一致（看起来「已同步」），但磁盘上没有文件。
      store.data[workspaceStateKey] = const SyncState(
        cursor: '2026-04-01T00:00:00Z',
        files: {'g1/a.md': SyncedFile(etag: 'W/"1"', size: 3)},
      );
      expect(sink.preExisting, isEmpty, reason: '磁盘上确实没有这个文件');

      final report = await useCase.run(
        scope: const SyncWorkspaceScope(),
        filter: const SyncFilterConfig(),
      );

      expect(
        downloader.calls.single.$2,
        isNull,
        reason: '本地无副本时必须发无条件请求，否则 304 会把文件判成「未变更」',
      );
      expect(report.downloaded, 1);
      expect(sink.written.containsKey('g1/a.md'), isTrue);
    });

    test('本地确有副本时才带 If-None-Match（省流量）', () async {
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [_file('/workspace/groups/g1/a.md', etag: 'W/"2"')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': root,
          'include_deleted': 'true',
          'updated_since': '2026-04-01T00:00:00Z',
          'page': 1,
          'page_size': 2,
        },
      );

      // 状态里 etag 较旧 → 会下载；磁盘上真有文件 → 应带条件头。
      store.data[workspaceStateKey] = const SyncState(
        cursor: '2026-04-01T00:00:00Z',
        files: {'g1/a.md': SyncedFile(etag: 'W/"1"', size: 3)},
      );
      sink.preExisting.add('g1/a.md');

      await useCase.run(
        scope: const SyncWorkspaceScope(),
        filter: const SyncFilterConfig(),
      );

      expect(downloader.calls.single.$2, 'W/"2"');
    });
  });
}
