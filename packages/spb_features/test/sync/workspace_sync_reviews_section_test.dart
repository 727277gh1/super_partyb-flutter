import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/contrast.dart';

/// `WorkspaceSyncReviewsSection` 测试（设置页「交付物同步」标签里的待确认项区块）。
///
/// ## 这个测试防的是什么
///
/// 这个区块是「文件被 groupsync 挂起」的**唯一**可见处，失败模式全是静默的：
/// - 常态（无待确认项）渲染出一块空卡片 → 用户以为出了别的问题；
/// - 「服务端未启用」与「没有待确认项」混成同一种展示 → 用户以为是自己的文件没问题；
/// - 点「同步」后不刷新 → 已处理的项留在列表里，用户重复点；
/// - 409（快照已变）当成普通错误 → 用户反复点同一份过期列表，永远失败；
/// - 轮询失败清空列表 → 用户以为文件已经被处理了。
void main() {
  WorkspaceSyncReviewEntry entry(
    String id, {
    String groupId = 'grp_1',
    String groupTitle = '月度报表',
    String path = 'reports',
    bool directory = true,
    WorkspaceSyncReviewReason reason = WorkspaceSyncReviewReason.tooManyFiles,
    int fileCount = 620,
    int totalBytes = 12 * 1048576,
    List<String> samples = const ['a.md', 'b.md'],
    String revision = 'rev1',
  }) => WorkspaceSyncReviewEntry(
    groupId: groupId,
    groupTitle: groupTitle,
    review: WorkspaceSyncReview(
      id: id,
      groupId: groupId,
      path: path,
      directory: directory,
      reason: reason,
      fileCount: fileCount,
      totalBytes: totalBytes,
      samples: samples,
      revision: revision,
    ),
  );

  WorkspaceSyncReviewsSnapshot snapshot(
    List<WorkspaceSyncReviewEntry> entries, {
    int failedGroups = 0,
    bool enabled = true,
    Set<String>? queriedGroupIds,
  }) => WorkspaceSyncReviewsSnapshot(
    entries: entries,
    failedGroups: failedGroups,
    enabled: enabled,
    // 真实实现由 collectWorkspaceSyncReviews 按「查过的 group」填；这里缺省
    // 用条目自带的 groupId 推出同样的集合（否则 todo.changed 的短路判据在
    // 测试里恒为「范围外」）。
    queriedGroupIds: queriedGroupIds ?? {for (final e in entries) e.groupId},
  );

  Future<void> pumpSection(
    WidgetTester tester, {
    required LoadSyncReviewsAction load,
    required ResolveSyncReviewAction resolve,
    Duration pollInterval = Duration.zero,
    Stream<TodoChange>? todoChanges,
    Duration coalesceWindow = Duration.zero,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkspaceSyncReviewsSection(
                load: load,
                resolve: resolve,
                pollInterval: pollInterval,
                todoChanges: todoChanges,
                coalesceWindow: coalesceWindow,
              ),
            ],
          ),
        ),
      ),
    );
    // 首次 load 是异步的：等它落地。
    await tester.pump();
    await tester.pump();
  }

  /// 点一个可能位于视口外的控件（区块住在设置页的可滚动列表里）。
  ///
  /// 不能直接 `tester.tap(byKey(...))`：13 条待确认项时「显示更多」在视口下方，
  /// 直接点会命中错误的位置。与 `sync_run_section_test.dart` 的 `tapVisible` 同一做法。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('群名与路径样例达到 AA，且不靠透明度拉层次（#127）', (tester) async {
    // 12px 的群名原先叠 `alpha: 0.8`（4.45:1）、路径样例叠 0.7（3.54:1），
    // 都在 WCAG AA 的 4.5 之下；而同列相邻字段用的都是不透明原色。
    await pumpSection(
      tester,
      load: () async => snapshot([entry('r1')]),
      resolve: (e, a) async {},
    );

    expectTextReadable(
      tester,
      find.byKey(const ValueKey('sync-review-group-r1')),
    );
    expectTextReadable(tester, find.text('a.md'));

    final groupStyle = tester
        .widget<Text>(find.byKey(const ValueKey('sync-review-group-r1')))
        .style!;
    expect(groupStyle.color!.a, 1.0, reason: '小字不得叠加透明度（§6.78 规则 3）；层次用字重');
    expect(groupStyle.fontWeight, FontWeight.w600, reason: '层次改由字重承担');
  });

  testWidgets('常态（没有待确认项）整块不渲染', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot(const []),
      resolve: (e, a) async {},
    );

    expect(find.byKey(const ValueKey('sync-reviews-card')), findsNothing);
    expect(find.textContaining('待确认的同步项'), findsNothing);
  });

  testWidgets('有项时展示路径 / 原因 / 数量与体积 / 对话标题', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot([entry('dir:grp_1:reports')]),
      resolve: (e, a) async {},
    );

    expect(find.byKey(const ValueKey('sync-reviews-card')), findsOneWidget);
    expect(find.text('reports'), findsOneWidget);
    expect(find.text('待同步文件数量超过单批上限'), findsOneWidget);
    expect(find.text('620 个文件 · 12.0 MiB'), findsOneWidget);
    expect(find.text('月度报表'), findsOneWidget);
    // 目录级挂起时列出样本文件名（用户要知道是哪几个文件）。
    expect(find.text('a.md'), findsOneWidget);
    expect(find.text('b.md'), findsOneWidget);
  });

  testWidgets('根路径 `.` 显示为「工作区根目录」', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot([entry('r1', path: '.')]),
      resolve: (e, a) async {},
    );

    expect(find.text('工作区根目录'), findsOneWidget);
    expect(find.text('.'), findsNothing);
  });

  testWidgets('点「同步」提交 action=sync，并刷新列表', (tester) async {
    var loads = 0;
    var resolved = 0;
    WorkspaceSyncReviewAction? action;

    await pumpSection(
      tester,
      load: () async {
        loads++;
        // 第一次有待确认项，处理后服务端不再返回它。
        return loads == 1 ? snapshot([entry('r1')]) : snapshot(const []);
      },
      resolve: (e, a) async {
        resolved++;
        action = a;
      },
    );

    await tapVisible(tester, find.byKey(const ValueKey('sync-review-sync-r1')));

    expect(resolved, 1);
    expect(action, WorkspaceSyncReviewAction.sync);
    expect(loads, greaterThanOrEqualTo(2), reason: '处理后必须刷新，否则列表残留已处理项');
    // 处理后列表空了，但成功提示还在（用户要看到「我这一下点对了」）。
    expect(find.byKey(const ValueKey('sync-reviews-notice')), findsOneWidget);
    expect(find.textContaining('已确认同步'), findsOneWidget);
  });

  testWidgets('点「忽略」提交 action=ignore', (tester) async {
    WorkspaceSyncReviewAction? action;
    await pumpSection(
      tester,
      load: () async => snapshot([entry('r1')]),
      resolve: (e, a) async => action = a,
    );

    await tapVisible(
      tester,
      find.byKey(const ValueKey('sync-review-ignore-r1')),
    );

    expect(action, WorkspaceSyncReviewAction.ignore);
  });

  testWidgets('409（快照已变）提示「请重新确认」并刷新，不显示为普通错误', (tester) async {
    var loads = 0;
    await pumpSection(
      tester,
      load: () async {
        loads++;
        return snapshot([entry('r1', revision: loads == 1 ? 'rev1' : 'rev2')]);
      },
      resolve: (e, a) async => throw const HttpError(409, '待处理文件已变化，请刷新后重试'),
    );

    await tapVisible(tester, find.byKey(const ValueKey('sync-review-sync-r1')));

    expect(loads, greaterThanOrEqualTo(2));
    expect(find.textContaining('待处理项已变化'), findsOneWidget);
    // 不是错误色那一行：409 是用户可以继续处理的状态（刷新后重列）。
    expect(
      find.byKey(const ValueKey('sync-reviews-inline-error')),
      findsNothing,
    );
  });

  testWidgets('其他失败（如 503 未启用）如实展示为错误', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot([entry('r1')]),
      resolve: (e, a) async => throw const HttpError(503, '文件同步未启用'),
    );

    await tapVisible(tester, find.byKey(const ValueKey('sync-review-sync-r1')));

    expect(
      find.byKey(const ValueKey('sync-reviews-inline-error')),
      findsOneWidget,
    );
    expect(find.text('文件同步未启用'), findsOneWidget);
  });

  testWidgets('部分对话查询失败时如实说明覆盖不全', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot([entry('r1')], failedGroups: 2),
      resolve: (e, a) async {},
    );

    expect(find.byKey(const ValueKey('sync-reviews-partial')), findsOneWidget);
    expect(find.textContaining('2 个对话'), findsOneWidget);
  });

  testWidgets('首次加载失败时给带重试的错误横幅', (tester) async {
    var loads = 0;
    await pumpSection(
      tester,
      load: () async {
        loads++;
        if (loads == 1) throw const HttpError(500, '网关暂时不可用');
        return snapshot([entry('r1')]);
      },
      resolve: (e, a) async {},
    );

    expect(find.byKey(const ValueKey('sync-reviews-error')), findsOneWidget);
    expect(find.text('网关暂时不可用'), findsOneWidget);

    await tapVisible(tester, find.text('重试'));

    expect(find.byKey(const ValueKey('sync-reviews-card')), findsOneWidget);
  });

  testWidgets('轮询失败不清空已有列表（用户可能以为文件已被处理）', (tester) async {
    var loads = 0;
    await pumpSection(
      tester,
      load: () async {
        loads++;
        if (loads == 1) return snapshot([entry('r1')]);
        throw const NetworkError('连接中断');
      },
      resolve: (e, a) async {},
      pollInterval: const Duration(milliseconds: 200),
    );

    expect(find.byKey(const ValueKey('sync-review-r1')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();

    expect(loads, greaterThanOrEqualTo(2), reason: '轮询应已触发');
    expect(
      find.byKey(const ValueKey('sync-review-r1')),
      findsOneWidget,
      reason: '旧列表必须保留',
    );
    expect(
      find.byKey(const ValueKey('sync-reviews-inline-error')),
      findsOneWidget,
    );

    // 收尾：停掉轮询定时器（否则测试结束时会留下 pending timer）。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('超过 10 项时先显示 10 条，点「显示更多」后展开', (tester) async {
    await pumpSection(
      tester,
      load: () async => snapshot([for (var i = 0; i < 13; i++) entry('r$i')]),
      resolve: (e, a) async {},
    );

    expect(find.byKey(const ValueKey('sync-review-r9')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-review-r10')), findsNothing);
    expect(find.byKey(const ValueKey('sync-reviews-more')), findsOneWidget);

    await tapVisible(tester, find.byKey(const ValueKey('sync-reviews-more')));

    expect(find.byKey(const ValueKey('sync-review-r12')), findsOneWidget);
  });

  testWidgets('未注入回调时同步区块不渲染待确认区（装配层没接就不显示）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SyncRunSection(
                runSync: () async => SyncReport(),
                localRoot: '/tmp/sync',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('sync-reviews-card')), findsNothing);
  });

  testWidgets('注入回调时同步区块渲染待确认区', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SyncRunSection(
                runSync: () async => SyncReport(),
                localRoot: '/tmp/sync',
                loadSyncReviews: () async => snapshot([entry('r1')]),
                resolveSyncReview: (e, a) async {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('sync-reviews-card')), findsOneWidget);
  });

  group('todo.changed 即时重拉（事件只做失效通知）', () {
    /// 造一条通知（默认属于本次查询集里的 grp_1）。
    TodoChange change(String groupId) =>
        TodoChange(groupId: groupId, op: TodoChangeOp.created);

    testWidgets('同组通知到达 → 立即重拉一次，不必等轮询', (tester) async {
      var loads = 0;
      final events = StreamController<TodoChange>.broadcast();
      addTearDown(events.close);

      await pumpSection(
        tester,
        load: () async {
          loads++;
          return snapshot([entry('r1')]);
        },
        resolve: (e, a) async {},
        todoChanges: events.stream,
      );
      expect(loads, 1, reason: '挂载时先取一次');

      events.add(change('grp_1'));
      await tester.pump();
      await tester.pump();

      expect(loads, 2);
    });

    testWidgets('范围外 group 的通知不重拉（重拉也查不到内容）', (tester) async {
      var loads = 0;
      final events = StreamController<TodoChange>.broadcast();
      addTearDown(events.close);

      await pumpSection(
        tester,
        load: () async {
          loads++;
          // 上一轮只查了 grp_1。
          return snapshot([entry('r1', groupId: 'grp_1')]);
        },
        resolve: (e, a) async {},
        todoChanges: events.stream,
      );

      events.add(change('grp_other'));
      await tester.pump();
      await tester.pump();

      expect(loads, 1, reason: '同步范围里没有 grp_other，刷了也白刷');
    });

    testWidgets('groupId 缺失的通知保守重拉（不确定范围）', (tester) async {
      var loads = 0;
      final events = StreamController<TodoChange>.broadcast();
      addTearDown(events.close);

      await pumpSection(
        tester,
        load: () async {
          loads++;
          return snapshot([entry('r1')]);
        },
        resolve: (e, a) async {},
        todoChanges: events.stream,
      );

      events.add(change(''));
      await tester.pump();
      await tester.pump();

      expect(loads, 2);
    });

    testWidgets('合并窗口内连发多条只重拉一次（一次扫描会连发 N 条）', (tester) async {
      var loads = 0;
      final events = StreamController<TodoChange>.broadcast();
      addTearDown(events.close);

      await pumpSection(
        tester,
        load: () async {
          loads++;
          return snapshot([entry('r1')]);
        },
        resolve: (e, a) async {},
        todoChanges: events.stream,
        coalesceWindow: const Duration(milliseconds: 400),
      );

      events.add(change('grp_1'));
      await tester.pump();
      events.add(change('grp_1'));
      events.add(change('grp_1'));
      await tester.pump();
      // 窗口未到时不得已经重拉。
      expect(loads, 1);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(loads, 2, reason: '三条事件合并成一次重拉');
    });

    testWidgets('首屏加载失败（没有快照）时收到通知 → 重拉并恢复', (tester) async {
      var loads = 0;
      final events = StreamController<TodoChange>.broadcast();
      addTearDown(events.close);

      await pumpSection(
        tester,
        load: () async {
          loads++;
          // 首屏失败 → 快照为 null（此时没有查询集可比）。
          if (loads == 1) throw const NetworkError('网关抖动');
          return snapshot([entry('r1')]);
        },
        resolve: (e, a) async {},
        todoChanges: events.stream,
      );
      expect(loads, 1);
      expect(find.byKey(const ValueKey('sync-reviews-error')), findsOneWidget);

      events.add(change('grp_1'));
      await tester.pump();
      await tester.pump();

      expect(loads, 2, reason: '没有快照时无法判断范围，宁可多刷一次');
      expect(
        find.byKey(const ValueKey('sync-reviews-card')),
        findsOneWidget,
        reason: '重拉成功应替换掉错误横幅',
      );
    });

    testWidgets('未注入事件流时行为不变（不崩、不重拉）', (tester) async {
      var loads = 0;
      await pumpSection(
        tester,
        load: () async {
          loads++;
          return snapshot([entry('r1')]);
        },
        resolve: (e, a) async {},
      );

      await tester.pump(const Duration(seconds: 1));

      expect(loads, 1);
      expect(find.byKey(const ValueKey('sync-reviews-card')), findsOneWidget);
    });
  });
}
