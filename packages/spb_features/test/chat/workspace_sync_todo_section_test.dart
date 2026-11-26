import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

/// 待办面板里的「工作区待处理」区块（对齐 webapp `WorkspaceSyncTodoSection`）。
///
/// ## 这个测试防的是什么
///
/// | 错误 | 后果 |
/// |---|---|
/// | 没有待确认项时渲染一块空卡片 | 待办面板常态变长，用户以为出了别的问题 |
/// | 409 当普通失败 | 用户反复点同一份过期列表，永远失败（服务端语义是「只批准当时那份快照」） |
/// | 归因查不到标题就编一个 | 用户以为这批文件是那一轮产出的，实际服务端没归因 |
/// | 「同步」文案说「已下载」 | 确认只是批准上传，文件还要等 worker 传完 + 下一轮同步 |
void main() {
  WorkspaceSyncReview review(
    String id, {
    String path = 'reports',
    bool directory = true,
    WorkspaceSyncReviewReason reason = WorkspaceSyncReviewReason.tooManyFiles,
    int fileCount = 620,
    int totalBytes = 12 * 1048576,
    List<String> samples = const ['a.md', 'b.md'],
    String revision = 'rev1',
    String turnId = '',
  }) => WorkspaceSyncReview(
    id: id,
    path: path,
    directory: directory,
    reason: reason,
    fileCount: fileCount,
    totalBytes: totalBytes,
    samples: samples,
    revision: revision,
    turnId: turnId,
  );

  Future<void> pumpSection(
    WidgetTester tester, {
    List<WorkspaceSyncReview> items = const [],
    Future<void> Function(
      WorkspaceSyncReview review,
      WorkspaceSyncReviewAction action,
    )?
    resolve,
    Map<String, String> turnLabels = const {},
    bool enabled = true,
    bool loading = false,
    String? error,
    Future<void> Function()? onRetry,
    int visibleLimit = 10,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkspaceSyncTodoSection(
                items: items,
                resolve: resolve ?? (r, a) async {},
                turnLabels: turnLabels,
                enabled: enabled,
                loading: loading,
                error: error,
                onRetry: onRetry,
                visibleLimit: visibleLimit,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('没有待处理项时整块不渲染（常态不占屏幕）', (tester) async {
    await pumpSection(tester);

    expect(find.byKey(const ValueKey('sync-todo-section')), findsNothing);
  });

  testWidgets('服务端未启用 groupsync 时整块不渲染（用户无从处理）', (tester) async {
    await pumpSection(tester, items: [review('r1')], enabled: false);

    expect(find.byKey(const ValueKey('sync-todo-section')), findsNothing);
  });

  testWidgets('展示路径 / 原因 / 数量与体积 / 样本文件名', (tester) async {
    await pumpSection(tester, items: [review('dir:g:reports')]);

    expect(find.byKey(const ValueKey('sync-todo-section')), findsOneWidget);
    expect(find.text('工作区待处理（1）'), findsOneWidget);
    expect(find.text('reports'), findsOneWidget);
    expect(find.text('待同步文件数量超过单批上限 · 620 个文件 · 12.0 MiB'), findsOneWidget);
    expect(find.text('a.md'), findsOneWidget);
    expect(find.text('b.md'), findsOneWidget);
  });

  testWidgets('根路径 `.` 显示为「工作区根目录」', (tester) async {
    await pumpSection(tester, items: [review('dir:g:.', path: '.')]);

    expect(find.text('工作区根目录'), findsOneWidget);
  });

  testWidgets('点「同步这个目录」提交 action=sync，成功后提示并重拉', (tester) async {
    final calls = <WorkspaceSyncReviewAction>[];
    var retries = 0;

    await pumpSection(
      tester,
      items: [review('dir:g:reports')],
      resolve: (r, action) async => calls.add(action),
      onRetry: () async => retries++,
    );

    await tester.tap(
      find.byKey(const ValueKey('sync-todo-sync-dir:g:reports:rev1')),
    );
    await tester.pump();

    expect(calls, [WorkspaceSyncReviewAction.sync]);
    expect(find.text('已确认同步，文件会在下一轮同步后出现在本地'), findsOneWidget);
    expect(retries, 1, reason: '动作完成后必须重拉（状态由 GET 决定）');
  });

  testWidgets('点「忽略」提交 action=ignore，提示里不说「已删除」', (tester) async {
    final calls = <WorkspaceSyncReviewAction>[];

    await pumpSection(
      tester,
      items: [review('file:g:a.pdf', directory: false)],
      resolve: (r, action) async => calls.add(action),
    );

    await tester.tap(
      find.byKey(const ValueKey('sync-todo-ignore-file:g:a.pdf:rev1')),
    );
    await tester.pump();

    expect(calls, [WorkspaceSyncReviewAction.ignore]);
    expect(find.text('已忽略，这些文件不再提示（仍留在工作区）'), findsOneWidget);
  });

  testWidgets('409（快照已变）标 stale 并重拉，不当普通失败', (tester) async {
    var retries = 0;
    await pumpSection(
      tester,
      items: [review('dir:g:reports')],
      resolve: (r, a) async => throw const HttpError(409, '快照已变'),
      onRetry: () async => retries++,
    );

    await tester.tap(
      find.byKey(const ValueKey('sync-todo-sync-dir:g:reports:rev1')),
    );
    await tester.pump();

    expect(find.text('待处理项已变化，已刷新列表，请重新确认'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync-todo-stale-dir:g:reports:rev1')),
      findsOneWidget,
      reason: '这一条要被打上「已变化」，用户才知道该看哪一条',
    );
    expect(retries, 1, reason: '409 不该让用户重试旧列表');
  });

  testWidgets('其他失败如实展示为错误（仍重拉，错误不丢）', (tester) async {
    var retries = 0;
    await pumpSection(
      tester,
      items: [review('dir:g:reports')],
      resolve: (r, a) async => throw const HttpError(503, '文件同步未启用'),
      onRetry: () async => retries++,
    );

    await tester.tap(
      find.byKey(const ValueKey('sync-todo-sync-dir:g:reports:rev1')),
    );
    await tester.pump();

    expect(find.text('文件同步未启用'), findsOneWidget);
    // 成败都重拉（真源只有 GET 一个）：错误是本组件的状态，刷新只换列表。
    expect(retries, 1, reason: '失败后也要重拉，否则别处已处理掉的条目会挂到下一轮轮询');
    expect(find.text('文件同步未启用'), findsOneWidget, reason: '重拉不能把动作错误盖成「列表加载完成」');
  });

  testWidgets('加载失败时展示错误行并请求重试', (tester) async {
    var retries = 0;
    await pumpSection(
      tester,
      items: [review('dir:g:reports')],
      error: '网关抖动',
      onRetry: () async => retries++,
    );

    expect(find.text('网关抖动'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('归因：查到标题显示标题，查不到退化为短 id', (tester) async {
    await pumpSection(
      tester,
      items: [review('r_known', turnId: 'turn_abcdef123456')],
      turnLabels: {'turn_abcdef123456': '整理本周周报'},
    );

    expect(find.text('来自「整理本周周报」'), findsOneWidget);
  });

  testWidgets('归因：没有标题时显示短 id（不编造）', (tester) async {
    await pumpSection(
      tester,
      items: [review('r_unknown', turnId: 'turn_abcdef123456')],
    );

    expect(find.text('来自轮次 turn_abc…'), findsOneWidget);
  });

  testWidgets('归因：没有 turn_id 时不显示这一行', (tester) async {
    await pumpSection(tester, items: [review('r_none')]);

    expect(find.textContaining('来自'), findsNothing);
  });

  testWidgets('超过上限时先显示前 N 条，点「显示更多」后展开', (tester) async {
    await pumpSection(
      tester,
      // 路径补零才能按字典序排出 0..12 的顺序（排序按 path）。
      items: [
        for (var i = 0; i < 13; i++)
          review('r$i', path: 'p${i.toString().padLeft(2, '0')}/'),
      ],
      visibleLimit: 10,
    );

    expect(find.byKey(const ValueKey('sync-todo-r9:rev1')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-todo-r10:rev1')), findsNothing);

    // 「显示更多」在 10 张卡片之后，可能落在视口外：先滚到可见再点。
    await tester.ensureVisible(find.byKey(const ValueKey('sync-todo-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-todo-more')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('sync-todo-r12:rev1')), findsOneWidget);
  });

  testWidgets('处理中禁用全部按钮（防重复提交）', (tester) async {
    final gate = Completer<void>();
    await pumpSection(
      tester,
      items: [
        review('r1'),
        review('r2', path: 'other/'),
      ],
      resolve: (r, a) => gate.future,
    );

    await tester.tap(find.byKey(const ValueKey('sync-todo-sync-r1:rev1')));
    await tester.pump();

    expect(find.text('处理中…'), findsOneWidget);
    final other = tester.widget<FilledButton>(
      find.byKey(const ValueKey('sync-todo-sync-r2:rev1')),
    );
    expect(other.onPressed, isNull, reason: '同一时刻只允许提交一条');

    gate.complete();
    await tester.pump();
  });
}
