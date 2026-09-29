import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 同步页测试。
///
/// ## 这个测试防的是什么
///
/// 同步页的失败模式全是「静默」的：
/// - 目录选了但没生效 → 用户以为选好了，同步却用旧目录（或报「未指定目录」）；
/// - **用户点「取消」被当成清空目录** → 配置丢失，且用户不知道为什么；
/// - 失败项只给数量不给文件名 → 用户无从判断要处理什么；
/// - 单文件失败被显示成「整轮失败」→ 用户以为什么都没同步，实际大部分成功了。
///
/// 故这里逐条断言目录状态、取消语义、计数展示与失败项明细。
void main() {
  /// 把同步页放进最小可用的 MaterialApp。
  Future<void> pumpSync(
    WidgetTester tester, {
    required PickSyncDirectory pickDirectory,
    required RunSyncAction runSync,
    String? initialLocalRoot,
    ValueChanged<String?>? onLocalRootChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          pickDirectory: pickDirectory,
          runSync: runSync,
          initialLocalRoot: initialLocalRoot,
          onLocalRootChanged: onLocalRootChanged,
        ),
      ),
    );
    await tester.pump();
  }

  /// 一份成功的报告。
  SyncReport okReport({
    int downloaded = 0,
    int notModified = 0,
    int deleted = 0,
    List<SyncFailure> failed = const [],
    Map<SyncSkipReason, int> skipped = const {},
  }) => SyncReport(
    downloaded: downloaded,
    notModified: notModified,
    deleted: deleted,
    failed: failed,
    skipped: skipped,
  );

  group('同步页：目录选择', () {
    testWidgets('未选目录时给出行动指引而非「未知」', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
      );

      expect(find.textContaining('尚未选择'), findsOneWidget);
    });

    testWidgets('已选目录时展示该路径', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        initialLocalRoot: '/home/u/deliverables',
      );

      expect(find.text('/home/u/deliverables'), findsOneWidget);
    });

    testWidgets('选择目录后展示新路径并回调上层', (tester) async {
      String? notified;
      await pumpSync(
        tester,
        pickDirectory: () async => '/home/u/new-root',
        runSync: () async => okReport(),
        initialLocalRoot: '/home/u/old-root',
        onLocalRootChanged: (v) => notified = v,
      );

      await tester.tap(find.byKey(const ValueKey('sync-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.text('/home/u/new-root'), findsOneWidget);
      expect(
        notified,
        '/home/u/new-root',
        reason: '目录变更必须回调出去，让上层在同一事务里重置同步状态',
      );
    });

    testWidgets('用户取消（返回 null）不得清空已有目录、不得报错', (tester) async {
      // 回归防线：把「取消」当成「清空」会让用户点一下取消就丢配置。
      var notified = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        initialLocalRoot: '/home/u/keep-me',
        onLocalRootChanged: (_) => notified++,
      );

      await tester.tap(find.byKey(const ValueKey('sync-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.text('/home/u/keep-me'), findsOneWidget, reason: '取消应保持原目录');
      expect(notified, 0, reason: '取消不该触发变更回调（否则会误清同步状态）');
      expect(find.byKey(const ValueKey('sync-error')), findsNothing);
    });

    testWidgets('目录选择器抛异常时显示错误条（不白屏）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => throw const PlatformError('无 GUI 环境'),
        runSync: () async => okReport(),
      );

      await tester.tap(find.byKey(const ValueKey('sync-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sync-error')), findsOneWidget);
      expect(find.textContaining('无 GUI 环境'), findsOneWidget);
    });
  });

  group('同步页：触发同步', () {
    testWidgets('未选目录时点同步提示先选目录，且不调用 runSync', (tester) async {
      // 回归防线：在发起前拦住，否则用户看到的是底层「未指定目录」错误，
      // 而实际需要知道的是「先去选目录」。
      var calls = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async {
          calls++;
          return okReport();
        },
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '没有目录就不该发起同步');
      expect(find.byKey(const ValueKey('sync-error')), findsOneWidget);
      expect(find.textContaining('请先选择同步目录'), findsOneWidget);
    });

    testWidgets('点同步调用 runSync 一次并展示结果', (tester) async {
      var calls = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async {
          calls++;
          return okReport(downloaded: 7);
        },
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byKey(const ValueKey('sync-report')), findsOneWidget);
      expect(find.text('同步完成'), findsOneWidget);
      expect(find.text('7 个'), findsOneWidget);
    });

    testWidgets('展示「下载 N / 跳过 M / 失败 K」三项计数', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(
          downloaded: 12,
          deleted: 3,
          skipped: {
            SyncSkipReason.mediaExcluded: 40,
            SyncSkipReason.machineGenerated: 67,
          },
          failed: const [SyncFailure('a.md', '下载失败：超时')],
        ),
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(find.text('12 个'), findsOneWidget, reason: '下载数');
      expect(find.text('3 个'), findsOneWidget, reason: '删除数');
      // 跳过 = 40 + 67
      expect(find.text('107 个'), findsOneWidget, reason: '跳过数应为各类之和');
      expect(find.text('1 个'), findsOneWidget, reason: '失败数');
      // 跳过明细分类展示
      expect(find.textContaining('媒体（未开启）'), findsOneWidget);
      expect(find.textContaining('机器生成产物'), findsOneWidget);
    });

    testWidgets('失败项逐条列出文件名与原因（不只给数量）', (tester) async {
      // 回归防线：只给「失败 2 个」用户无从判断要处理什么。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(
          downloaded: 5,
          failed: const [
            SyncFailure('reports/a.md', '下载失败：连接超时'),
            SyncFailure('reports/b.pdf', '写入失败：权限不足'),
          ],
        ),
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('reports/a.md'), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      expect(find.textContaining('reports/b.pdf'), findsOneWidget);
      expect(find.textContaining('权限不足'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sync-failure-reports/a.md')),
        findsOneWidget,
      );
    });

    testWidgets('单文件失败仍展示整轮结果（不误报为整轮失败）', (tester) async {
      // 失败不阻断其余文件：报告里同时有成功计数与失败项。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(
          downloaded: 5,
          failed: const [SyncFailure('x.md', '下载失败')],
        ),
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sync-report')), findsOneWidget);
      expect(find.text('5 个'), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-error')), findsNothing);
    });

    testWidgets('整轮失败（抛 SpbError）显示错误条而非结果卡', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => throw const NetworkError('连接超时'),
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sync-error')), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-report')), findsNothing);
    });

    testWidgets('同步中禁用按钮（防重复触发）', (tester) async {
      var calls = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async {
          calls++;
          // 永不完成，观察按钮是否禁用。
          await Future<void>.delayed(const Duration(seconds: 10));
          return okReport();
        },
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('sync-start-button')),
      );
      expect(button.onPressed, isNull, reason: '同步中按钮应禁用');
      expect(find.text('同步中…'), findsOneWidget);

      // 再点一次不应触发第二次。
      await tester.tap(
        find.byKey(const ValueKey('sync-start-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(calls, 1);

      // 收尾：让挂起的 future 完成，避免 pending timer。
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('换目录后清掉上一轮结果（结果描述的是旧目录）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => '/new',
        runSync: () async => okReport(downloaded: 9),
        initialLocalRoot: '/old',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-report')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sync-pick-directory')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sync-report')), findsNothing);
    });

    testWidgets('再次同步会覆盖上一轮结果（不叠加）', (tester) async {
      var n = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async {
          n++;
          return okReport(downloaded: n * 10);
        },
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();
      expect(find.text('10 个'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();
      expect(find.text('20 个'), findsOneWidget);
      expect(find.text('10 个'), findsNothing);
    });

    testWidgets('未变更与删除计数仅在非零时展示（避免噪音）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(downloaded: 1),
        initialLocalRoot: '/root',
      );

      await tester.tap(find.byKey(const ValueKey('sync-start-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sync-stat-not-modified')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('sync-stat-deleted')), findsNothing);
    });
  });

  group('同步页：单向语义', () {
    testWidgets('页面没有任何上传入口（单向同步）', (tester) async {
      // 反向同步会触发服务端 groupsync 的写入回路（emit agent.file.*
      // → 可能引发渲染推送/重跑），故不该存在上传按钮。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        initialLocalRoot: '/root',
      );

      expect(find.textContaining('不会上传本地改动'), findsOneWidget);
      expect(find.textContaining('上传'), findsOneWidget);
      // 除说明文案外不应有「上传」类按钮
      expect(find.widgetWithText(FilledButton, '上传'), findsNothing);
      expect(find.widgetWithText(TextButton, '上传'), findsNothing);
    });
  });
}
