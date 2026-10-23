import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
