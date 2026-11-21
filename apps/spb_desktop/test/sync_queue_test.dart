import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

class _BlockedUfs extends UfsApi {
  _BlockedUfs() : super(Dio());
  final started = Completer<void>();
  final release = Completer<void>();
  final prefixes = <String?>[];
  bool failFirst = false;
  int downloads = 0;

  @override
  Future<UfsFilePage> listFiles({
    String? pathPrefix,
    String? updatedSince,
    bool includeDeleted = false,
    List<String> excludePrefix = const [],
    int page = 1,
    int pageSize = 20,
    String ownerType = 'user',
  }) async {
    prefixes.add(pathPrefix);
    if (prefixes.length == 1) {
      started.complete();
      await release.future;
      if (failFirst) throw const NetworkError('offline');
    }
    final files = [
      for (final gid in ['g1', 'g2'])
        UfsFileEntry.fromJson({
          'id': gid,
          'name': 'a.md',
          'path': '/workspace/groups/$gid/a.md/',
          'size': 1,
          'etag': 'v1',
          'updated_at': '2026-01-01T00:00:00Z',
        }),
    ].where((f) => f.path.startsWith(pathPrefix!)).toList();
    return UfsFilePage(items: files, total: files.length);
  }

  @override
  Future<UfsDownload> download(String fileId, {String? ifNoneMatch}) async {
    downloads++;
    return const UfsDownload(notModified: false, bytes: [65]);
  }
}

void main() {
  late Directory root;
  late AppDatabase db;
  late DriftSyncStateStore store;
  late _BlockedUfs ufs;
  late ProviderContainer container;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('spb-sync-queue-');
    db = AppDatabase(NativeDatabase.memory());
    store = DriftSyncStateStore(db);
    ufs = _BlockedUfs();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncStateStoreProvider.overrideWithValue(store),
        ufsApiProvider.overrideWithValue(ufs),
        loadSyncSettingsProvider.overrideWithValue(
          () async => SyncSettings(localRoot: root.path),
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
    await root.delete(recursive: true);
  });

  test('两个 group 串行读写真实 drift 状态，排队期间保持 busy', () async {
    final run = container.read(runGroupSyncActionProvider);
    final first = run('g1');
    await ufs.started.future;
    final second = run('g2');
    await Future<void>.delayed(Duration.zero);
    expect(ufs.prefixes, ['/workspace/groups/g1']);
    expect(container.read(syncInFlightProvider), isTrue);
    ufs.release.complete();
    await Future.wait([first, second]);
    expect(
      (await store.load(workspaceStateKey)).files.keys,
      containsAll(['g1/a.md', 'g2/a.md']),
    );
    expect(await File('${root.path}/g1/a.md').readAsString(), 'A');
    expect(await File('${root.path}/g2/a.md').readAsString(), 'A');
    expect(container.read(syncInFlightProvider), isFalse);
  });

  test('定向与全量共用队列，后续全量看到已保存记录且不重下', () async {
    final targeted = container.read(runGroupSyncActionProvider)('g1');
    await ufs.started.future;
    final full = container.read(runSyncActionProvider)();
    await Future<void>.delayed(Duration.zero);
    expect(ufs.prefixes.length, 1);
    ufs.release.complete();
    await Future.wait([targeted, full]);
    expect(ufs.downloads, 2, reason: 'g1 由定向下载，后续全量只下载 g2');
    expect((await store.load(workspaceStateKey)).files.length, 2);
    expect(container.read(syncInFlightProvider), isFalse);
  });

  test('全量在先时定向同样等待，不能覆盖全量写入的其他 group', () async {
    final full = container.read(runSyncActionProvider)();
    await ufs.started.future;
    final targeted = container.read(runGroupSyncActionProvider)('g1');
    await Future<void>.delayed(Duration.zero);
    expect(ufs.prefixes.length, 1);
    ufs.release.complete();
    await Future.wait([full, targeted]);
    expect(ufs.downloads, 2);
    expect((await store.load(workspaceStateKey)).files.length, 2);
  });

  test('同一 group 的重复触发复用 Future', () async {
    final run = container.read(runGroupSyncActionProvider);
    final first = run('g1');
    await ufs.started.future;
    final second = run('g1');
    expect(identical(first, second), isTrue);
    ufs.release.complete();
    await Future.wait([first, second]);
    expect(ufs.prefixes.length, 1);
  });

  test('上一轮异常不堵塞后续 group，也不留下永久 busy', () async {
    ufs.failFirst = true;
    final run = container.read(runGroupSyncActionProvider);
    final first = run('g1');
    final rejected = expectLater(first, throwsA(isA<NetworkError>()));
    await ufs.started.future;
    final second = run('g2');
    ufs.release.complete();
    await rejected;
    expect((await second).downloaded, 1);
    expect((await store.load(workspaceStateKey)).contains('g2/a.md'), isTrue);
    expect(container.read(syncInFlightProvider), isFalse);
    expect((await run('g1')).downloaded, 1, reason: '异常后同 group 可重新触发');
  });
}
