import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_domain/spb_domain.dart';

import 'package:drift/native.dart';

/// 「进入对话时判定是否需要同步」的真实实现（`checkGroupSyncNeedProvider`）。
///
/// ## 为什么这些用例不能省
///
/// 判定本身是纯函数（`groupSyncNeed`，在 `spb_domain` 里逐条测过）。本文件测的
/// 是**取数那一段**——它有四个易错点，且都不会被纯函数测试覆盖：
///
/// 1. **水位必须取本 group 的文件记录**（`groupSyncWatermark`），不能拿
///    workspace 游标比。定向同步（`SyncSingleGroupScope`）**不推进**游标，
///    拿它比会永远判 stale。
/// 2. **必须把水位当 `updated_since` 传给服务端**。UFS 只在带了它时才按
///    `updated_at DESC` 排序，否则按 `created_at DESC`——而 agent 覆盖写既有
///    文件只刷新 `updated_at`（`created_at` 不变）。不带的话 `page_size=1`
///    取到的是「最晚**创建**」而非「最晚**更新**」，覆盖写就判不出变化。
/// 3. **`page_size=1` 只够判定，不够统计**。判定命中后要再分页统计规模，
///    否则提示条只能写「有交付物未同步」而给不出数量。
/// 4. **统计要按同一水位过滤**。远端那一页里可能既有新文件也有已同步的旧文件，
///    把它们都算进去会让提示条报一个虚高的数字。
///
/// 这些错误在真实环境里表现为「提示条不出现」或「说了个错数字」——很难被
/// 注意到，也很难手测。
void main() {
  const groupId = 'grp_1';
  const root = '/workspace/groups/';

  late Dio dio;
  late DioAdapter adapter;
  late AppDatabase db;
  late DriftSyncStateStore store;
  late ProviderContainer container;

  Map<String, dynamic> file(String path, String updatedAt) => {
    'id': 'id-$path',
    'path': path,
    'name': path.split('/').last,
    'size': 3,
    'mime_type': 'text/markdown',
    'is_directory': false,
    'etag': 'W/"$updatedAt"',
    'updated_at': updatedAt,
  };

  /// 目录条目：列表里真实存在（group 根、`reports/` 等），但**永远同步不了**。
  Map<String, dynamic> dir(String path, String updatedAt) => {
    'id': 'id-$path',
    'path': path,
    'name': path.split('/').where((s) => s.isNotEmpty).last,
    'size': 0,
    'is_directory': true,
    'updated_at': updatedAt,
  };

  setUp(() {
    dio = createDio(baseUrl: 'https://api.test/ufs');
    adapter = DioAdapter(dio: dio);
    db = AppDatabase(NativeDatabase.memory());
    store = DriftSyncStateStore(db);
    container = ProviderContainer(
      overrides: [
        // 探测走 UFS 端点（`/api/files`），故覆盖 `ufsApiProvider` 而不是
        // `dioProvider`——后者是 PartyB API（`/pba`），打不到 UFS。
        ufsApiProvider.overrideWithValue(UfsApi(dio)),
        syncStateStoreProvider.overrideWithValue(store),
        // **必须**覆盖：`preferencesStoreProvider` 若不覆盖会去开**真实**的
        // `~/.local/share/super_partyb/sync.db`。而下面的 `configure` / 偏好
        // 写入会**永久污染开发机上的真实偏好**（实测：写入 `sync.since_days=1`
        // 后，后续所有用例因多了 `updated_since` 而报「无匹配路由」）。
        //
        // 覆盖成同一个内存库也顺带消除了 drift 的「同一进程建了两个
        // AppDatabase」告警。
        appDatabaseProvider.overrideWithValue(db),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 直接写偏好：`loadSyncSettingsProvider` 的真源是偏好 + 目录绑定。
  Future<void> configure({
    String? localRoot,
    SyncScopeConfig scope = const SyncScopeConfig(),
  }) async {
    final prefs = container.read(preferencesStoreProvider);
    await prefs.setString(scopePrefKey, scope.encode());
    if (localRoot != null) await store.bindLocalRoot(localRoot);
  }

  Future<GroupSyncCheckResult> check() =>
      container.read(checkGroupSyncNeedProvider)(groupId);

  /// 预置「本 group 已同步到 [at]」。
  ///
  /// ## 为什么是文件记录而不是游标
  ///
  /// 提示条上的「立即同步」跑的是 `SyncSingleGroupScope`，它**不推进**共享
  /// 游标（否则会越过其它 group 里未同步的文件，永久漏下载）。故判据必须
  /// 建在本 group 的文件记录水位上——拿游标比会永远判 stale。
  Future<void> seedWatermark(String at) => store.save(
    workspaceStateKey,
    SyncState(
      cursor: at,
      files: {'$groupId/reports/synced.md': SyncedFile(size: 1, updatedAt: at)},
    ),
  );

  /// 有水位时，探测与统计**都必须**带 `updated_since` + `include_deleted`。
  ///
  /// 写成函数而不是每处手抄：这两组参数是**同一个**判据的两个面（服务端据此
  /// 切排序并返回软删除条目），漏一处就是一个静默的判定缺陷。
  Map<String, dynamic> watermarkQuery(String at, {required int pageSize}) => {
    'owner_type': 'user',
    'path_prefix': '$root$groupId',
    'updated_since': at,
    'include_deleted': 'true',
    'page': 1,
    'page_size': pageSize,
  };

  /// 无水位（首次同步这个 group）时的探测参数：不带 `updated_since`。
  Map<String, dynamic> fullQuery({required int page, required int pageSize}) =>
      {
        'owner_type': 'user',
        'path_prefix': '$root$groupId',
        'page': page,
        'page_size': pageSize,
      };

  group('checkGroupSyncNeed：判定', () {
    test('远端有晚于水位的文件 → stale，且带上未同步条数', () async {
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/reports/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      // 命中后的统计（page_size=100）。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/reports/a.md', '2026-10-21T09:00:00Z'),
            file('$root$groupId/reports/b.md', '2026-10-21T09:30:00Z'),
          ],
          'total': 2,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 2);
    });

    test('既有文件被覆盖写（created_at 旧、updated_at 新）→ stale', () async {
      // ## 这是本组用例存在的核心场景
      //
      // agent 覆盖写既有交付物走的是「上传新版本」：`created_at` 不变，只有
      // `updated_at` 刷新（生产 7852 个 group 文件里 4978 个如此）。服务端在
      // **不带** `updated_since` 时按 `created_at DESC` 排序，于是
      // `page_size=1` 返回的是「最晚创建」的旧文件，`latestUpdatedAtOf` 得到
      // 一个早于水位的时刻 → 判 upToDate → 提示条永不出现。
      //
      // 这里的 mock 只在**带了 `updated_since`** 时才匹配，因此这条用例同时
      // 钉住「必须传该参数」与「覆盖写能被判出来」。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            {
              ...file(
                '$root$groupId/reports/README.md',
                '2026-10-21T09:00:00Z',
              ),
              // 覆盖写：创建于很久以前，刚刚才被重写。
              'created_at': '2026-06-01T00:00:00Z',
            },
          ],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/reports/README.md', '2026-10-21T09:00:00Z'),
          ],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(
        result.need,
        GroupSyncNeed.stale,
        reason: '覆盖写只刷新 updated_at；不带 updated_since 时排序按 created_at，判不出变化',
      );
      expect(result.pendingCount, 1);
    });

    test('远端最晚时间不晚于水位 → upToDate，且不再发统计请求', () async {
      // ## 为什么断言「不再发请求」
      //
      // 统计是命中后才付的成本。若漏了 `if (need != stale) return`，每次
      // 打开对话都会多拉一页 100 条——而绝大多数打开是未命中。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T10:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T10:00:00Z')],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T10:00:00Z', pageSize: 1),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.upToDate);
      // 未注册 page_size=100 的 mock：真发出去会抛「无匹配路由」，
      // 用例因此失败。这比计数更直接。
      expect(result.pendingCount, 0);
    });

    test('该 group 没有交付物 → unknown（不是 upToDate）', () async {
      await configure(localRoot: '/tmp/sync');
      adapter.onGet(
        '/api/files',
        (server) =>
            server.reply(200, {'items': <Map<String, dynamic>>[], 'total': 0}),
        queryParameters: fullQuery(page: 1, pageSize: 100),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
    });

    test('首次同步时最前面几条是目录 → 仍能判出 stale', () async {
      // 无水位时服务端按 `created_at DESC`（新建的目录往往排在最前）。若探测
      // 只拉 1 条并过滤目录，就会得到 unknown——即使下面明明有文件。
      await configure(localRoot: '/tmp/sync');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            dir('$root$groupId/newdir/', '2026-10-21T10:00:00Z'),
            file('$root$groupId/a.md', '2026-10-21T09:00:00Z'),
          ],
          'total': 2,
        }),
        queryParameters: fullQuery(page: 1, pageSize: 100),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            dir('$root$groupId/newdir/', '2026-10-21T10:00:00Z'),
            file('$root$groupId/a.md', '2026-10-21T09:00:00Z'),
          ],
          'total': 2,
        }),
        queryParameters: fullQuery(page: 1, pageSize: 100),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 1);
    });

    test('未配置同步目录 → unknown，且完全不发请求', () async {
      // 没目录时判定必然是 unknown（没有「本地」可比），探测只是白跑一次
      // HTTP。这条钉住「先判 canSync 再发请求」这个顺序。
      await configure();
      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
      // 没注册任何 mock：真发出去就会失败。
    });

    test('勾选模式下范围外的 group → unknown，且完全不发请求', () async {
      // 「立即同步」跑的是 `SyncSingleGroupScope`，它只按 `filter` 过滤、
      // **不看** `scope`。若不在探测层挡住范围外的 group，提示条会邀请用户
      // 下载一个他明确排除在外的对话。
      await configure(
        localRoot: '/tmp/sync',
        scope: const SyncScopeConfig(allGroups: false, groupIds: ['other']),
      );
      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
      // 没注册任何 mock：真发出去就会失败。
    });

    test('从未同步过（无水位）→ stale，且不带 updated_since', () async {
      // 无水位时本地什么都没有，判据不看具体时刻（见 `groupSyncNeed` 的
      // `local.isEmpty` 分支）。此时**不能**带 `updated_since`：带什么值都会
      // 漏掉一部分历史交付物，而用户以为同步完成了。
      //
      // 另：探测页大小是 100 而不是 1——服务端此时按 `created_at DESC` 且
      // 列表含目录，`page_size=1` 恰好取到一个目录就会误判 unknown。
      await configure(localRoot: '/tmp/sync');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: fullQuery(page: 1, pageSize: 100),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: fullQuery(page: 1, pageSize: 100),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 1);
    });

    test('只有目录条目 → unknown（目录永远同步不了）', () async {
      // UFS 列表包含目录（group 根、`reports/` 等）。`shouldSync` 第一条就
      // 跳过目录，故它不会被 `markSynced`、也不会抬水位。把它算进「最晚时间」
      // 会让一个「只多了几个空目录」的 group 被判 stale 且**永远追不上**。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [dir('$root$groupId/reports/', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
      expect(result.pendingCount, 0);
    });

    test('探测页只有目录但下面还有文件 → 仍判 stale（扩页重探）', () async {
      // ## 为什么这条必须存在
      //
      // 有水位时只拉一条（`page_size=1`）。若那一条恰是目录，过滤后就得到
      // `unknown`——即使后面明明有新文件。而目录的 `updated_at` **只在创建
      // 时设置**（UFS 不因写子文件而抬升它），故「水位之后新建的目录」正好
      // 会排在最前；`updated_at DESC` 在秒级同秒时排序不确定，目录与同秒
      // 新文件会争第一位——属真实 flakiness，不是理论边界。
      //
      // 首次同步的 100 条只修了「无水位」那一半。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [dir('$root$groupId/newdir/', '2026-10-21T09:30:00Z')],
          'total': 2,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      // 扩页重探（同样带 updated_since，只是页大小 100）。
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            dir('$root$groupId/newdir/', '2026-10-21T09:30:00Z'),
            file('$root$groupId/reports/a.md', '2026-10-21T09:00:00Z'),
          ],
          'total': 2,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(
        result.need,
        GroupSyncNeed.stale,
        reason: '第一条是目录不该得出 unknown——下面还有新文件',
      );
      expect(result.pendingCount, 1);
    });

    test('探测页只有一条目录且 total=1 → 不扩页（不浪费一次请求）', () async {
      // 与上一条互补：`total == 1` 说明真的只有它，扩页也只会拿到同一条。
      // 没注册 page_size=100 的 mock：真发出去会抛「无匹配路由」。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [dir('$root$groupId/reports/', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
    });

    test('探测页只有机器产物 → unknown（机器产物同样永远同步不了）', () async {
      // 与目录同一条理由：`shouldSync` 对 `reports/tts/**`、`.archive/**`
      // 也是「跳过且不记录」——它们不会 `markSynced`、不会抬水位。生产实测
      // 312 个 TTS 文件，故任何「最新变动是 TTS」的 group 都会永久 stale：
      // 提示条一直在，点同步却什么都不同步。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file(
              '$root$groupId/reports/tts/turn1/a.mp3',
              '2026-10-21T09:00:00Z',
            ),
          ],
          'total': 1,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
      expect(result.pendingCount, 0);
    });

    test('统计不把机器产物算进去', () async {
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/new.md', '2026-10-21T09:00:00Z')],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/new.md', '2026-10-21T09:00:00Z'),
            file(
              '$root$groupId/reports/tts/turn1/a.mp3',
              '2026-10-21T09:10:00Z',
            ),
            file(
              '$root$groupId/.archive/v1/snapshot.md',
              '2026-10-21T09:20:00Z',
            ),
          ],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(result.pendingCount, 1, reason: 'TTS 与 .archive 同步不了，不能报给用户');
    });

    test('sinceDays 与同步侧同口径：下限外的文件不算未同步', () async {
      // ## 为什么这条必须存在
      //
      // 同步侧把「已保存游标 / 本 group 水位」与 `sinceDays` 取更晚者
      // （`effectiveCursor`）。探测侧若只看水位不看 `sinceDays`，两边就会
      // 对「哪些算未同步」得出不同结论：用户设了「只拉最近 30 天」而该 group
      // 的文档全在 60 天前 → 探测按全量数得 stale，同步按 30 天下限列出 0 条
      // → 提示条报 N 个、同步报「已同步 0 个」、水位不前进 → **每次进对话
      // 永久重复提示**。
      //
      // 这里给一个很宽泛的下限（1 天），使 `lower = now - 1d` 远晚于远端
      // 那条文档 → 服务端按 `updated_since` 返回 0 条 → unknown。
      await configure(localRoot: '/tmp/sync');
      final prefs = container.read(preferencesStoreProvider);
      await prefs.setInt(sinceDaysPrefKey, value: 1);

      // 无水位（首次同步）+ sinceDays=1 → 仍应带 updated_since。
      // 用 `updated_since` 存在的查询参数匹配：若实现没传，这条用例会因
      // 「无匹配路由」而失败——比数字断言更直接。
      adapter.onGet(
        '/api/files',
        (server) =>
            server.reply(200, {'items': <Map<String, dynamic>>[], 'total': 0}),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'include_deleted': 'true',
          'page': 1,
          'page_size': 1,
          'updated_since': Matchers.any,
        },
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
    });
  });

  group('checkGroupSyncNeed：计数', () {
    test('统计按水位过滤，不把已同步的旧文件算进去', () async {
      // 服务端是 `updated_at >= 游标`，故等于水位的那个文件也会出现在清单里
      // （它可能就是抬升水位的那个）。全算进去会让提示条报虚高的数字。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/new.md', '2026-10-21T09:00:00Z')],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/new.md', '2026-10-21T09:00:00Z'),
            file('$root$groupId/old.md', '2026-10-21T07:00:00Z'),
            file('$root$groupId/at-cursor.md', '2026-10-21T08:00:00Z'),
          ],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 1, reason: '只有晚于水位的那个算未同步（等于水位的也已同步过）');
    });

    test('统计不把目录条目算进去', () async {
      // 与判定的口径必须一致：目录既不参与同步，也不该出现在「有 N 个交付物
      // 未同步」里——否则用户点「立即同步」后发现只下载了 1 个。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/new.md', '2026-10-21T09:00:00Z')],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/new.md', '2026-10-21T09:00:00Z'),
            dir('$root$groupId/reports/', '2026-10-21T09:10:00Z'),
            dir('$root$groupId/assets/', '2026-10-21T09:20:00Z'),
          ],
          'total': 3,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );

      final result = await check();
      expect(result.pendingCount, 1);
    });

    test('跨页累加', () async {
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 150,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [
            file('$root$groupId/a.md', '2026-10-21T09:00:00Z'),
            file('$root$groupId/b.md', '2026-10-21T09:10:00Z'),
          ],
          'total': 150,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/c.md', '2026-10-21T09:20:00Z')],
          'total': 150,
        }),
        queryParameters: {
          ...watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
          'page': 2,
        },
      );

      final result = await check();
      expect(result.pendingCount, 3);
    });

    test('计数达到上限后停止翻页（不为一个提示条拉几百页）', () async {
      // 首次全量生产实测 5666 条。若一直翻到 tail，光是显示「有 5666 个」
      // 就要发 57 次请求——而用户只需要知道「很多」。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1000,
        }),
        queryParameters: watermarkQuery('2026-10-21T08:00:00Z', pageSize: 1),
      );
      // 每页 100 条都晚于水位 → 5 页即达上限 500。
      for (var page = 1; page <= 5; page++) {
        adapter.onGet(
          '/api/files',
          (server) => server.reply(200, {
            'items': [
              for (var i = 0; i < 100; i++)
                file('$root$groupId/p$page-$i.md', '2026-10-21T09:00:00Z'),
            ],
            'total': 1000,
          }),
          queryParameters: {
            ...watermarkQuery('2026-10-21T08:00:00Z', pageSize: 100),
            'page': page,
          },
        );
      }
      // 第 6 页**故意不注册**：达到上限后不该再翻页。

      final result = await check();
      expect(result.pendingCount, GroupSyncCheckResult.countCap);
      expect(result.pendingCount, 500);
    });
  });
}
