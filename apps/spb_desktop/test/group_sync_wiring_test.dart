import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:spb_desktop/providers.dart';

import 'support/desktop_harness.dart';

/// 「进入对话时按需同步」的桌面端接线。
///
/// ## 为什么要从 router 层测（而不是只测提示条组件）
///
/// 提示条组件自己的测试（`spb_features/test/sync/group_sync_hint_test.dart`）
/// 自己传参，**接不接线它不管**——与 issue #33 的移动端搜索入口同一类假绿。
/// 这里从真实的 `_ChatPage` 出发，断言「打开对话 → 判定 → 提示条出现 →
/// 点立即同步 → 真的跑了一轮同步」这条完整链路。
///
/// ## 为什么默认结果要在 harness 里注入
///
/// 真实实现会读同步设置 + 打 UFS 列表端点。默认设置里 `onGroupOpen` 是关的，
/// 故真实实现会提前返回——但那要先 await 一次异步读设置，于是每个对话页
/// 用例都多一次微任务往返。注入恒定结果让这条路径对既有用例完全透明。
void main() {
  const groupId = 'grp_1';

  void mockChat(DioAdapter adapter, String groupId) {
    adapter.onGet(
      '/chat/groups/$groupId',
      (server) => server.reply(200, {
        'id': groupId,
        'title': '测试对话',
        'user_id': 'usr_TEST',
        'created_at': '2026-10-21T08:00:00Z',
        'updated_at': '2026-10-21T08:00:00Z',
        'status': 'active',
        'metadata': <String, dynamic>{},
      }),
    );
    adapter.onGet(
      '/users/usr_TEST/chat/messages/pending',
      (server) => server.reply(200, {'items': <Map<String, dynamic>>[]}),
    );
    adapter.onGet(
      '/chat/groups/$groupId/timeline',
      (server) => server.reply(200, {
        'items': <Map<String, dynamic>>[],
        'next_cursor': null,
      }),
    );
  }

  /// 打开一个对话页并等判定/加载落定。
  Future<TestHarness> openChat(
    WidgetTester tester, {
    GroupSyncCheck? check,
    LoadSyncSettings? loadSyncSettings,
    GroupSyncRun? runSync,
    RunSyncAction? runFullSync,
    bool mockGroups = false,
    void Function(GroupSyncThrottle)? seedThrottle,
  }) async {
    final harness = await pumpApp(
      tester,
      initialLocation: '/chat/$groupId',
      mockGroups: mockGroups,
      checkGroupSyncNeed: check,
      loadSyncSettings: loadSyncSettings,
      runGroupSync: runSync,
      runSync: runFullSync,
      seedThrottle: seedThrottle,
      beforePump: (adapter) => mockChat(adapter, groupId),
    );
    // 对话页在 postFrameCallback 里解析 userId → 聚焦 → 判定，需真实轮次。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  group('进入对话时的同步判定', () {
    testWidgets('判定命中 → 渲染提示条并显示未同步条数', (tester) async {
      await openChat(
        tester,
        check: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.stale,
          pendingCount: 7,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
      );

      expect(find.byKey(const ValueKey('group-sync-hint')), findsOneWidget);
      expect(find.text('本对话有 7 个交付物未同步到本地'), findsOneWidget);
    });

    testWidgets('判定未命中 → 不渲染提示条', (tester) async {
      await openChat(
        tester,
        check: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.upToDate,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
      );

      expect(find.byKey(const ValueKey('group-sync-hint')), findsNothing);
    });

    testWidgets('开关关着 → 完全不探测（连设置都不读也可以）', (tester) async {
      // ## 为什么这条重要
      //
      // 不探测即零开销。若把门控写反（先探测再判开关），每个对话都会多一次
      // HTTP——而用户根本没开这个功能。
      var probed = 0;
      await openChat(
        tester,
        check: (String groupId) async {
          probed++;
          return GroupSyncCheckResult(
            groupId: groupId,
            need: GroupSyncNeed.stale,
            pendingCount: 1,
          );
        },
        loadSyncSettings: () async =>
            const SyncSettings(localRoot: '/tmp/spb-sync'),
      );

      expect(probed, 0, reason: 'onGroupOpen 默认关，不应探测');
      expect(find.byKey(const ValueKey('group-sync-hint')), findsNothing);
    });

    testWidgets('没有同步目录 → 不探测（判定必然是 unknown，白跑一次 HTTP）', (tester) async {
      var probed = 0;
      await openChat(
        tester,
        check: (String groupId) async {
          probed++;
          return GroupSyncCheckResult(
            groupId: groupId,
            need: GroupSyncNeed.stale,
          );
        },
        loadSyncSettings: () async =>
            const SyncSettings(auto: AutoSyncConfig(onGroupOpen: true)),
      );

      expect(probed, 0);
    });

    testWidgets('冷却期内的 group 直接不探测（连 HTTP 都不发）', (tester) async {
      // ## 为什么必须有冷却
      //
      // 被过滤掉的文件（媒体 / reports/tts / 超体积）**不推游标**，故判定会
      // 长期命中。没有冷却的话用户每次点进这个对话都触发一轮全范围同步。
      //
      // ## 为什么这条用例要「预置」节流器
      //
      // 页面自己不会重探（`_syncCheck` 清空后没有触发点），故只能预先让
      // 节流器记下这个 group，再打开对话断言「一次探测都没跑」。这样钉住的
      // 是**路由层真的调了 `allows`**——若把那个检查删掉，探测照样会发生。
      var probed = 0;

      await pumpApp(
        tester,
        initialLocation: '/chat/$groupId',
        mockGroups: false,
        checkGroupSyncNeed: (String gid) async {
          probed++;
          return GroupSyncCheckResult(
            groupId: gid,
            need: GroupSyncNeed.stale,
            pendingCount: 2,
          );
        },
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        // 预先记下这个 group（模拟「刚才已经试过」）。
        beforePump: (adapter) => mockChat(adapter, groupId),
        seedThrottle: (throttle) => throttle.markTriggered(groupId),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();

      expect(probed, 0, reason: '冷却期内不该探测（连 HTTP 都不该发）');
      expect(find.byKey(const ValueKey('group-sync-hint')), findsNothing);
    });

    testWidgets('判定命中后记录冷却（同一容器内该 group 被挡住）', (tester) async {
      // 与上一条互补：上一条钉「冷却生效时不再探」，这一条钉「命中后确实记了」。
      // 缺任一条都会让「冷却」这个机制可以静默失效（只记不查 / 只查不记）。
      final harness = await openChat(
        tester,
        check: (String gid) async => GroupSyncCheckResult(
          groupId: gid,
          need: GroupSyncNeed.stale,
          pendingCount: 2,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
      );

      final throttle = harness.container.read(groupSyncThrottleProvider);
      expect(throttle.allows(groupId), isFalse);
    });

    testWidgets('判定为 upToDate 时不消耗冷却期', (tester) async {
      // ## 为什么这条重要
      //
      // 若 `markTriggered` 挪到判定之前（或无条件调用），那么「进来时没有
      // 新文件」也会把冷却期耗掉——用户之后真的产生了新文件，再进来却不提示。
      final harness = await openChat(
        tester,
        check: (String gid) async =>
            GroupSyncCheckResult(groupId: gid, need: GroupSyncNeed.upToDate),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
      );

      final throttle = harness.container.read(groupSyncThrottleProvider);
      expect(throttle.allows(groupId), isTrue);
    });
  });

  group('提示条上的动作', () {
    testWidgets('点「立即同步」跑一轮同步，成功后提示条消失', (tester) async {
      var syncRuns = 0;
      await openChat(
        tester,
        check: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.stale,
          pendingCount: 3,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        runSync: (String gid) async {
          syncRuns++;
          return SyncReport(downloaded: 3);
        },
      );

      await tester.tap(find.byKey(const ValueKey('group-sync-hint-sync')));
      await tester.pumpAndSettle();

      expect(syncRuns, 1);
      expect(find.byKey(const ValueKey('group-sync-hint')), findsNothing);
    });

    testWidgets('点「立即同步」走的是**定向**同步，不是全范围同步', (tester) async {
      // ## 为什么必须钉住这条
      //
      // 两个动作长得像但代价差两个数量级：全范围首次是 5666 条 / 4.7 GB，
      // 定向只是这个对话的几十个文件。而它们**都返回 SyncReport**，
      // 光断言「同步跑了一次」分不出来（这里 `fullRuns` 恒为 0 才是关键）。
      var fullRuns = 0;
      String? targetedGroup;
      await openChat(
        tester,
        check: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.stale,
          pendingCount: 3,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        runSync: (String gid) async {
          targetedGroup = gid;
          return SyncReport(downloaded: 3);
        },
        runFullSync: () async {
          fullRuns++;
          return SyncReport();
        },
      );

      await tester.tap(find.byKey(const ValueKey('group-sync-hint-sync')));
      await tester.pumpAndSettle();

      expect(fullRuns, 0, reason: '点提示条不该跑全范围同步');
      expect(targetedGroup, groupId, reason: '定向同步收到的应是当前对话的 id');
    });

    testWidgets('点「忽略」只清掉提示条，不触发同步', (tester) async {
      var syncRuns = 0;
      await openChat(
        tester,
        check: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.stale,
          pendingCount: 3,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        runSync: (String gid) async {
          syncRuns++;
          return SyncReport();
        },
      );

      await tester.tap(find.byKey(const ValueKey('group-sync-hint-dismiss')));
      await tester.pumpAndSettle();

      expect(syncRuns, 0, reason: '忽略不是同步');
      expect(find.byKey(const ValueKey('group-sync-hint')), findsNothing);
    });

    testWidgets('点「立即同步」成功后本地索引被刷新（交付物立即可打开）', (tester) async {
      // ## 这条防的是什么
      //
      // `deliverableLocalIndexProvider` 是 `FutureProvider`，**读完就缓存**。
      // 同步刚往同步目录写了文件，若不 invalidate，提示条会消失、SnackBar 会
      // 说「已同步 1 个交付物」，但侧边栏里那个文件仍然显示为「未同步」——
      // 用户点了同步却找不到能打开的那几个。
      //
      // ## 为什么必须从 router 层测
      //
      // `resolveLocalDeliverableProvider` 的接线点在 `router.dart` 的侧边栏
      // tab 里。页面测试自己传 `resolveLocalPath`，**接不接线它不管**——
      // 与 issue #33 的移动端搜索入口同一类假绿。
      const gid = 'grp_wire';
      const rel = 'reports/a.md';

      late Directory root;
      late AppDatabase db;
      late DriftSyncStateStore store;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('spb-wire-');
        final file = File(p.join(root.path, gid, rel));
        await file.parent.create(recursive: true);
        await file.writeAsString('# a\n');
        db = AppDatabase(NativeDatabase.memory());
        store = DriftSyncStateStore(db);
        // 先绑目录再写状态：bindLocalRoot 在目录**变化**时会清空状态。
        await store.bindLocalRoot(root.path);
      });
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      final harness = await pumpApp(
        tester,
        initialLocation: '/chat/$gid',
        mockGroups: false,
        database: db,
        checkGroupSyncNeed: (String groupId) async => GroupSyncCheckResult(
          groupId: groupId,
          need: GroupSyncNeed.stale,
          pendingCount: 1,
        ),
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        runGroupSync: (String groupId) async {
          // 模拟真实同步：往索引里写一条记录（文件已在磁盘上）。
          await store.save(
            workspaceStateKey,
            SyncState(files: {'$groupId/$rel': const SyncedFile(size: 4)}),
          );
          return SyncReport(downloaded: 1);
        },
        beforePump: (adapter) => mockChat(adapter, gid),
      );

      // autoDispose：不持一个监听，`read` 拿到的实例读完即释放，断言就没有
      // 「刷新前 / 刷新后」的对比可言了。
      final sub = harness.container.listen(
        resolveLocalDeliverableProvider(gid),
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();

      final entry = ufsFile(gid, rel);
      expect(
        harness.container.read(resolveLocalDeliverableProvider(gid))(entry),
        isNull,
        reason: '前置条件：同步前索引里没有这条记录',
      );

      await tester.tap(find.byKey(const ValueKey('group-sync-hint-sync')));
      await tester.pumpAndSettle();
      // 索引是异步重读的（invalidate → FutureProvider 重新执行）。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();

      expect(
        harness.container.read(resolveLocalDeliverableProvider(gid))(entry),
        p.join(root.path, gid, rel),
        reason: '同步成功后必须重新读到索引，否则文件仍显示为「未同步」',
      );
    });
  });

  group('解析/聚焦在途时切对话', () {
    testWidgets('新 group 的探测不会被丢掉（重跑一轮）', (tester) async {
      // ## 这条防的是什么
      //
      // `_resolveUserAndFocus` 有一个「正在解析」守卫（防止重复进入）。
      // 修复前它在途期间**直接 return**：`didUpdateWidget` 换 groupId 时
      // 新的一次请求被整个丢弃，且没有重试点——于是新对话的同步探测永远
      // 不跑，用户看到的是「提示条不出现」。
      //
      // 修复后用「重跑一次」标志：在途期间只置标志，本轮结束后再跑一轮。
      //
      // ## 为什么必须从 router 层测
      //
      // 缺陷在 `_ChatPageState` 的私有方法里，只有「真的切路由」才会触发
      // `didUpdateWidget`。页面测试拿不到这个生命周期。
      final first = Completer<GroupSyncCheckResult>();
      final probed = <String>[];

      final harness = await pumpApp(
        tester,
        initialLocation: '/chat/grp_1',
        mockGroups: false,
        checkGroupSyncNeed: (String groupId) {
          probed.add(groupId);
          if (groupId == 'grp_1') return first.future;
          return Future<GroupSyncCheckResult>.value(
            GroupSyncCheckResult(
              groupId: groupId,
              need: GroupSyncNeed.upToDate,
            ),
          );
        },
        loadSyncSettings: () async => const SyncSettings(
          localRoot: '/tmp/spb-sync',
          auto: AutoSyncConfig(onGroupOpen: true),
        ),
        beforePump: (adapter) {
          mockChat(adapter, 'grp_1');
          mockChat(adapter, 'grp_2');
        },
      );

      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
      expect(probed, ['grp_1'], reason: '前置条件：grp_1 的探测还挂在那里');

      // 在 grp_1 的探测还没返回时切到 grp_2。
      harness.router.go('/chat/grp_2');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(probed, ['grp_1'], reason: '在途期间不该并发探测 grp_2（会与上一轮抢同一个标志）');

      first.complete(
        const GroupSyncCheckResult(
          groupId: 'grp_1',
          need: GroupSyncNeed.upToDate,
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();

      expect(probed, [
        'grp_1',
        'grp_2',
      ], reason: '在途期间被请求的那一轮必须补跑，否则新对话的探测静默丢失');
    });
  });
}
