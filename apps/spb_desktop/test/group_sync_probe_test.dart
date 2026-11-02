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

/// 真 provider + 内存库。列表桩实际按查询下限过滤并分页，不能仅注册一个
/// 与实现相同的 URL，让错误的水位裁剪也得到测试期望的数据。
class _Ufs extends UfsApi {
  _Ufs() : super(Dio());

  final files = <UfsFileEntry>[];
  final queries = <({String? prefix, String? since, bool deleted, int page})>[];
  bool brokenPagination = false;

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
    queries.add((
      prefix: pathPrefix,
      since: updatedSince,
      deleted: includeDeleted,
      page: page,
    ));
    if (brokenPagination) return const UfsFilePage(items: [], total: 1000);
    final selected = files.where(
      (f) =>
          f.path.startsWith('$pathPrefix/') &&
          (includeDeleted || !f.isDeleted) &&
          (updatedSince == null ||
              (f.updatedAtRaw?.compareTo(updatedSince) ?? -1) >= 0),
    );
    return UfsFilePage(
      items: selected.skip((page - 1) * pageSize).take(pageSize).toList(),
      total: selected.length,
    );
  }
}

UfsFileEntry _file(
  String rel, {
  String at = '2026-10-21T08:00:00Z',
  String etag = 'v1',
  int size = 3,
  bool directory = false,
  bool deleted = false,
  String mime = 'text/markdown',
}) => UfsFileEntry.fromJson({
  'id': 'id-$rel',
  'path': '/workspace/groups/grp_1/$rel/',
  'name': rel.split('/').last,
  'size': size,
  'mime_type': mime,
  'is_directory': directory,
  'etag': etag,
  'updated_at': at,
  if (deleted) 'deleted_at': at,
});

void main() {
  const gid = 'grp_1';
  late AppDatabase db;
  late DriftSyncStateStore store;
  late ProviderContainer container;
  late _Ufs ufs;
  late SyncSettings settings;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = DriftSyncStateStore(db);
    ufs = _Ufs();
    settings = const SyncSettings(localRoot: '/unused');
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        syncStateStoreProvider.overrideWithValue(store),
        loadSyncSettingsProvider.overrideWithValue(() async => settings),
        ufsApiProvider.overrideWithValue(ufs),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<GroupSyncCheckResult> check() =>
      container.read(checkGroupSyncNeedProvider)(gid);
  Future<void> seed(Map<String, SyncedFile> files) => store.save(
    workspaceStateKey,
    SyncState(cursor: '2026-10-22T00:00:00Z', files: files),
  );

  test('首次同步：按 group 前缀列举，计数并包括删除信息', () async {
    ufs.files.addAll([_file('a.md'), _file('b.md')]);
    final result = await check();
    expect(result.need, GroupSyncNeed.stale);
    expect(result.pendingCount, 2);
    expect(ufs.queries.single.prefix, '/workspace/groups/$gid');
    expect(ufs.queries.single.since, isNull);
    expect(ufs.queries.single.deleted, isTrue);
  });

  test('较旧失败项仍算待同步，不能被最大成功时间或共享游标截掉', () async {
    await seed({
      '$gid/new.md': const SyncedFile(
        size: 3,
        etag: 'v1',
        updatedAt: '2026-10-21T09:00:00Z',
      ),
    });
    ufs.files.addAll([
      _file('old.md'),
      _file('new.md', at: '2026-10-21T09:00:00Z'),
    ]);
    final result = await check();
    expect(result.need, GroupSyncNeed.stale);
    expect(result.pendingCount, 1);
    expect(ufs.queries.single.since, isNull);
  });

  test('同秒 etag 改变仍判 stale', () async {
    await seed({
      '$gid/a.md': const SyncedFile(
        size: 3,
        etag: 'old',
        updatedAt: '2026-10-21T08:00:00Z',
      ),
    });
    ufs.files.add(_file('a.md', etag: 'new'));
    expect((await check()).pendingCount, 1);
  });

  test('同秒新增文件不能因已有另一份成功记录而漏判', () async {
    await seed({
      '$gid/a.md': const SyncedFile(
        size: 3,
        etag: 'v1',
        updatedAt: '2026-10-21T08:00:00Z',
      ),
    });
    ufs.files.addAll([_file('a.md'), _file('b.md')]);
    expect((await check()).pendingCount, 1);
  });

  test('已同步版本按 etag 跳过，旧文件覆盖写按新 etag 计数', () async {
    await seed({
      '$gid/a.md': const SyncedFile(size: 3, etag: 'v1'),
      '$gid/b.md': const SyncedFile(size: 3, etag: 'v1'),
    });
    ufs.files.addAll([_file('a.md'), _file('b.md', etag: 'v2')]);
    expect((await check()).pendingCount, 1);
  });

  test('全部版本一致：upToDate，不发额外统计请求', () async {
    await seed({'$gid/a.md': const SyncedFile(size: 3, etag: 'v1')});
    ufs.files.add(_file('a.md'));
    expect((await check()).need, GroupSyncNeed.upToDate);
    expect(ufs.queries.length, 1);
  });

  test('没有文件：upToDate', () async {
    expect((await check()).need, GroupSyncNeed.upToDate);
  });

  test('未配置目录时不发请求', () async {
    settings = const SyncSettings();
    expect((await check()).need, GroupSyncNeed.unknown);
    expect(ufs.queries, isEmpty);
  });

  test('勾选范围外的 group 不发请求', () async {
    settings = settings.copyWith(
      scope: const SyncScopeConfig(allGroups: false, groupIds: ['other']),
    );
    expect((await check()).need, GroupSyncNeed.unknown);
    expect(ufs.queries, isEmpty);
  });

  test('首 100 条都是目录，第二页交付物仍被找到', () async {
    ufs.files.addAll([
      for (var i = 0; i < 100; i++) _file('dir$i', directory: true),
      _file('real.md'),
    ]);
    expect((await check()).pendingCount, 1);
    expect(ufs.queries.map((q) => q.page), [1, 2]);
  });

  test('前两页都是机器产物，第三页仍继续扫描', () async {
    ufs.files.addAll([
      for (var i = 0; i < 200; i++) _file('reports/tts/$i.mp3'),
      _file('real.md'),
    ]);
    expect((await check()).pendingCount, 1);
    expect(ufs.queries.map((q) => q.page), [1, 2, 3]);
  });

  test('只有目录和机器产物时不提示', () async {
    ufs.files.addAll([
      _file('dir', directory: true),
      _file('reports/tts/a.mp3'),
      _file('.archive/snapshot.md'),
      _file('_attachments/a.md'),
    ]);
    expect((await check()).need, GroupSyncNeed.upToDate);
  });

  test('媒体与体积过滤跟随真实同步计划，不虚报待同步数', () async {
    settings = settings.copyWith(
      filter: const SyncFilterConfig(maxFileSize: 10),
    );
    ufs.files.addAll([
      _file('image.png', mime: 'image/png'),
      _file('large.md', size: 11),
      _file('real.md'),
    ]);
    expect((await check()).pendingCount, 1);
  });

  test('删除只计入有本地记录的文件，且优先于媒体体积过滤', () async {
    await seed({'$gid/known.png': const SyncedFile(size: 999)});
    ufs.files.addAll([
      _file('known.png', deleted: true, mime: 'image/png', size: 999),
      _file('never-downloaded.md', deleted: true),
    ]);
    expect((await check()).pendingCount, 1);
  });

  test('无 updated_at 但版本未知的文件也应提示', () async {
    ufs.files.add(
      UfsFileEntry.fromJson({
        'id': 'a',
        'path': '/workspace/groups/$gid/a.md/',
        'name': 'a.md',
        'size': 3,
      }),
    );
    expect((await check()).pendingCount, 1);
  });

  test('sinceDays 是唯一查询下限，不受成功文件时间影响', () async {
    settings = settings.copyWith(sinceDays: 30);
    final recent = unixToRfc3339(nowUnix() - 60);
    await seed({
      '$gid/recent.md': SyncedFile(size: 3, etag: 'v1', updatedAt: recent),
    });
    ufs.files.addAll([
      _file('old.md', at: '2000-01-01T00:00:00Z'),
      _file('new.md', at: recent),
    ]);
    final result = await check();
    expect(result.pendingCount, 1);
    final lower = DateTime.parse(ufs.queries.single.since!);
    expect(DateTime.now().difference(lower).inDays, 30);
  });

  test('跨页累计有效动作数，已同步文件不计数', () async {
    ufs.files.addAll([for (var i = 0; i < 120; i++) _file('$i.md')]);
    await seed({'$gid/0.md': const SyncedFile(size: 3, etag: 'v1')});
    expect((await check()).pendingCount, 119);
    expect(ufs.queries.length, 2);
  });

  test('达到 500 个待处理动作即停止扫描', () async {
    ufs.files.addAll([for (var i = 0; i < 600; i++) _file('$i.md')]);
    expect((await check()).pendingCount, GroupSyncCheckResult.countCap);
    expect(ufs.queries.length, 5);
  });

  test('空页却声称还有更多时明确报错，不得当作已同步', () async {
    ufs.brokenPagination = true;
    await expectLater(check(), throwsA(isA<ParseError>()));
    expect(ufs.queries.length, 1);
  });
}
