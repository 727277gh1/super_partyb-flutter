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
/// 是**取数那一段**——它有三个易错点，且都不会被纯函数测试覆盖：
///
/// 1. **水位必须取本 group 的文件记录**（`groupSyncWatermark`），不能拿
///    workspace 游标比。定向同步（`SyncSingleGroupScope`）**不推进**游标，
///    拿它比会永远判 stale。
/// 2. **`page_size=1` 只够判定，不够统计**。判定命中后要再分页统计规模，
///    否则提示条只能写「有交付物未同步」而给不出数量。
/// 3. **统计要按同一水位过滤**。远端那一页里可能既有新文件也有已同步的旧文件，
///    把它们都算进去会让提示条报一个虚高的数字。
///
/// 这些错误在真实环境里表现为「提示条说了个错数字」——很难被注意到，也很难
/// 手测（需要恰好有未同步文件）。
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
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 直接写偏好：`loadSyncSettingsProvider` 的真源是偏好 + 目录绑定。
  Future<void> configure({String? localRoot}) async {
    final prefs = container.read(preferencesStoreProvider);
    await prefs.setString(scopePrefKey, const SyncScopeConfig().encode());
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

  group('checkGroupSyncNeed：判定', () {
    test('远端有晚于游标的文件 → stale，且带上未同步条数', () async {
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/reports/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 100,
        },
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 2);
    });

    test('远端最晚时间不晚于游标 → upToDate，且不再发统计请求', () async {
      // ## 为什么断言「不再发请求」
      //
      // 统计是命中后才付的成本。若漏了 `if (need != stale) return`，每次
      // 打开对话都会多拉一页 100 条——而绝大多数打开是未命中。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T10:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
    });

    test('未配置同步目录 → unknown，且完全不发请求', () async {
      // 没目录时判定必然是 unknown（没有「本地」可比），探测只是白跑一次
      // HTTP。这条钉住「先判 canSync 再发请求」这个顺序。
      await configure();
      final result = await check();
      expect(result.need, GroupSyncNeed.unknown);
      // 没注册任何 mock：真发出去就会失败。
    });

    test('从未同步过（无游标）→ stale', () async {
      await configure(localRoot: '/tmp/sync');
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/a.md', '2026-10-21T09:00:00Z')],
          'total': 1,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 100,
        },
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 1);
    });
  });

  group('checkGroupSyncNeed：计数', () {
    test('统计按游标过滤，不把已同步的旧文件算进去', () async {
      // 远端那一页通常**既有**新文件也有已同步的旧文件（列表按 updated_at
      // 倒序，但一页 100 条会跨过游标）。全算进去会让提示条报虚高的数字。
      await configure(localRoot: '/tmp/sync');
      await seedWatermark('2026-10-21T08:00:00Z');

      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/new.md', '2026-10-21T09:00:00Z')],
          'total': 3,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 100,
        },
      );

      final result = await check();
      expect(result.need, GroupSyncNeed.stale);
      expect(result.pendingCount, 1, reason: '只有晚于游标的那个算未同步（等于游标的也已同步过）');
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 100,
        },
      );
      adapter.onGet(
        '/api/files',
        (server) => server.reply(200, {
          'items': [file('$root$groupId/c.md', '2026-10-21T09:20:00Z')],
          'total': 150,
        }),
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 2,
          'page_size': 100,
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
        queryParameters: {
          'owner_type': 'user',
          'path_prefix': '$root$groupId',
          'page': 1,
          'page_size': 1,
        },
      );
      // 每页 100 条都晚于游标 → 5 页即达上限 500。
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
            'owner_type': 'user',
            'path_prefix': '$root$groupId',
            'page': page,
            'page_size': 100,
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
