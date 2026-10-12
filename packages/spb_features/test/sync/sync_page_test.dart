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
    ScanDirtyFilesAction? scanDirtyFiles,
    UploadChangesAction? uploadChanges,
    String? initialLocalRoot,
    ValueChanged<String?>? onLocalRootChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncPage(
          pickDirectory: pickDirectory,
          runSync: runSync,
          scanDirtyFiles: scanDirtyFiles,
          uploadChanges: uploadChanges,
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

  /// 无脏文件、无异常的扫描结果。
  ///
  /// 默认 `unchanged: 3`（`scanned` 非零）→ 摘要为「没有本地改动（已比对 3 个）」。
  /// 传 `unchanged: 0` 则是「本地没有已同步的文件」（另一条文案分支）。
  LocalDirtyScanResult emptyScan({int unchanged = 3}) => LocalDirtyScanResult(
    dirty: const [],
    unchanged: unchanged,
    undetectable: 0,
    filtered: const {},
    failed: const [],
  );

  /// 一个脏文件。
  LocalDirtyFile dirty(String relPath, int size) => LocalDirtyFile(
    relPath: relPath,
    groupId: relPath.split('/').first,
    localSize: size,
  );

  /// 含若干脏文件的扫描结果。
  LocalDirtyScanResult scanWith(List<LocalDirtyFile> files) =>
      LocalDirtyScanResult(
        dirty: files,
        unchanged: 0,
        undetectable: 0,
        filtered: const {},
        failed: const [],
      );

  /// 点击某个控件（先滚动到可见处）。
  ///
  /// ## 为什么必须 ensureVisible
  ///
  /// 页面主体是 ListView；回传区块在下方，脏文件多时提交按钮会落在视口外。
  /// 直接 `tap` 会「未命中」而**不报错**（只打一条 warning），测试会以为点了
  /// 但实际没点——表现为后续断言莫名失败。这里统一先滚入视口。
  Future<void> tapVisible(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

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

  group('同步页：单向语义与回传入口', () {
    testWidgets('未注入回传回调时页面没有任何上传入口', (tester) async {
      // 自动同步永远是 UFS → 本地单向（反向自动同步会触发服务端 groupsync
      // 的写入回路，emit agent.file.* → 可能引发渲染推送/重跑）。回传必须是
      // 显式动作，故装配层没接回调时入口不出现。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        initialLocalRoot: '/root',
      );

      expect(find.textContaining('自动同步不会上传本地改动'), findsOneWidget);
      expect(find.byKey(const ValueKey('upload-section')), findsNothing);
      expect(find.byKey(const ValueKey('upload-scan-button')), findsNothing);
      expect(find.byKey(const ValueKey('upload-submit-button')), findsNothing);
    });

    testWidgets('文案把两条通道说清（自动不回传 / 回传是显式动作）', (tester) async {
      // 回归防线：旧文案是「单向同步：只把远端拉下来，不会上传本地改动」
      // ——它没说「那我想让 agent 知道怎么办」，用户会以为改动永远上不去。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        initialLocalRoot: '/root',
      );

      expect(
        find.textContaining('自动同步不会上传本地改动；可用「回传改动」把选中的修改显式交给 agent'),
        findsOneWidget,
      );
    });

    testWidgets('注入回传回调后才展示入口', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => emptyScan(),
        uploadChanges: (_) async => const UploadReport(),
        initialLocalRoot: '/root',
      );

      expect(find.byKey(const ValueKey('upload-section')), findsOneWidget);
      expect(find.text('回传改动'), findsWidgets);
      expect(find.byKey(const ValueKey('upload-scan-button')), findsOneWidget);
    });
  });

  group('同步页：回传改动', () {
    testWidgets('扫描前不展示空态（避免「扫描没做完」与「没改动」混淆）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => emptyScan(),
        uploadChanges: (_) async => const UploadReport(),
        initialLocalRoot: '/root',
      );

      expect(find.byKey(const ValueKey('upload-empty')), findsNothing);
      expect(find.byKey(const ValueKey('upload-submit-button')), findsNothing);
    });

    testWidgets('无脏文件时扫描后显示空态', (tester) async {
      var scans = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async {
          scans++;
          return emptyScan();
        },
        uploadChanges: (_) async => const UploadReport(),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));

      expect(scans, 1);
      expect(find.byKey(const ValueKey('upload-empty')), findsOneWidget);
      expect(find.textContaining('没有本地改动'), findsOneWidget);
      // 空态下不该有提交按钮（没东西可传）。
      expect(find.byKey(const ValueKey('upload-submit-button')), findsNothing);
    });

    testWidgets('有脏文件时逐条渲染路径与字节数，且默认全选', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 120),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/specs/b.spec.json', 340),
        ]),
        uploadChanges: (_) async => const UploadReport(),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));

      // 逐条：路径 + 体积（用户需要知道传的是什么、多大）。
      expect(
        find.byKey(
          const ValueKey(
            'upload-file-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
          ),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('reports/a.md'), findsOneWidget);
      expect(find.textContaining('120 字节'), findsOneWidget);
      expect(find.textContaining('specs/b.spec.json'), findsOneWidget);
      expect(find.textContaining('340 字节'), findsOneWidget);

      // 默认全选 + 按钮显示选中数。
      expect(find.text('回传选中的 2 个改动'), findsOneWidget);
      final boxes = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect(boxes.every((b) => b.value == true), isTrue);
    });

    testWidgets('取消勾选后提交只传剩下的文件', (tester) async {
      // 回归防线：设计文档 §6「不搞一键全传黑箱」——勾选必须真正生效。
      Set<String>? sent;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 120),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/b.md', 200),
        ]),
        uploadChanges: (only) async {
          sent = only;
          return const UploadReport();
        },
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));

      // 取消第一个。
      await tapVisible(
        tester,
        const ValueKey(
          'upload-file-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
        ),
      );
      expect(find.text('回传选中的 1 个改动'), findsOneWidget);

      await tapVisible(tester, const ValueKey('upload-submit-button'));

      expect(sent, {'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/b.md'});
    });

    testWidgets('全部取消勾选时提交按钮禁用（不发起空回传）', (tester) async {
      var calls = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 120),
        ]),
        uploadChanges: (_) async {
          calls++;
          return const UploadReport();
        },
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      await tapVisible(
        tester,
        const ValueKey(
          'upload-file-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
        ),
      );

      final btn = tester.widget<FilledButton>(
        find.byKey(const ValueKey('upload-submit-button')),
      );
      expect(btn.onPressed, isNull);
      expect(calls, 0);
    });

    testWidgets('结果按各终态逐条渲染：已回传 / 冲突已物化 / 走快速捕获 / 已跳过 / 失败', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 10),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/b.md', 20),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/c.pdf', 30),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/d.md', 40),
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/e.md', 50),
        ]),
        uploadChanges: (_) async => const UploadReport(
          items: [
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.uploaded,
              notified: true,
            ),
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/b.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.conflictMaterialized,
              conflictPath: '_conflict/2026-09-30T12-00-00Z-b.md.conflict',
              notified: true,
            ),
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/c.pdf',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.fallbackQuickCapture,
              notified: true,
            ),
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/d.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.skippedRemoteDeleted,
              reason: '远端已没有这个文件',
            ),
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/e.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.failed,
              reason: '上传失败（HTTP 400）：路径被拒',
            ),
          ],
        ),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      await tapVisible(tester, const ValueKey('upload-submit-button'));

      expect(find.byKey(const ValueKey('upload-report')), findsOneWidget);
      expect(find.text('回传完成'), findsOneWidget);

      // 成功类文案说「已回传」而不是「已同步」（上传响应无 etag，本地还没对齐）。
      // 逐条行里断言：摘要行也含「已回传」字样，故用 descendant 定位到该条目。
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'upload-result-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
            ),
          ),
          matching: find.text('已回传'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('已同步'), findsNothing);

      // 冲突条目必须把副本路径亮出来（用户要去比对两份）。
      expect(
        find.textContaining('_conflict/2026-09-30T12-00-00Z-b.md.conflict'),
        findsOneWidget,
      );
      // 413 兜底条目说明走了附件通道（摘要行也含该字样，故限定到条目内）。
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'upload-result-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/c.pdf',
            ),
          ),
          matching: find.textContaining('已改走附件通道'),
        ),
        findsOneWidget,
      );
      // 跳过与失败条目给出原因。
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'upload-result-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/d.md',
            ),
          ),
          matching: find.textContaining('远端已没有这个文件'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey(
              'upload-result-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/e.md',
            ),
          ),
          matching: find.textContaining('路径被拒'),
        ),
        findsOneWidget,
      );

      // 逐条 key 与 relPath 对应。
      for (final name in ['a.md', 'b.md', 'c.pdf', 'd.md', 'e.md']) {
        expect(
          find.byKey(
            ValueKey(
              'upload-result-a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/$name',
            ),
          ),
          findsOneWidget,
        );
      }
    });

    testWidgets('上传成功但通知失败 → 明确提示 agent 还不知道', (tester) async {
      // 回归防线：把「已上传但没通知」显示成完全成功，用户会以为
      // agent 已经知道了而不再处理。
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 10),
        ]),
        uploadChanges: (_) async => const UploadReport(
          items: [
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.uploaded,
            ),
          ],
        ),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      await tapVisible(tester, const ValueKey('upload-submit-button'));

      expect(
        find.byKey(const ValueKey('upload-notify-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('未能通知 agent'), findsOneWidget);
    });

    testWidgets('扫描抛 SpbError 时显示错误条（不白屏、不展示空态）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => throw const PlatformError('目录不可读'),
        uploadChanges: (_) async => const UploadReport(),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));

      expect(find.byKey(const ValueKey('sync-error')), findsOneWidget);
      expect(find.textContaining('目录不可读'), findsOneWidget);
      expect(find.byKey(const ValueKey('upload-empty')), findsNothing);
    });

    testWidgets('回传抛 SpbError 时显示错误条', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 10),
        ]),
        uploadChanges: (_) async => throw const NetworkError('连接超时'),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      await tapVisible(tester, const ValueKey('upload-submit-button'));

      expect(find.byKey(const ValueKey('sync-error')), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      expect(find.byKey(const ValueKey('upload-report')), findsNothing);
    });

    testWidgets('重新扫描会清掉上一轮报告与勾选', (tester) async {
      // 回归防线：报告描述的是上一轮提交，新扫描后仍显示会让用户以为
      // 刚扫描出来的这批已经回传过了。
      var n = 0;
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 10 + n++),
        ]),
        uploadChanges: (_) async => const UploadReport(
          items: [
            UploadItemResult(
              relPath: 'a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md',
              groupId: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
              outcome: UploadOutcome.uploaded,
              notified: true,
            ),
          ],
        ),
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      await tapVisible(tester, const ValueKey('upload-submit-button'));
      expect(find.byKey(const ValueKey('upload-report')), findsOneWidget);

      await tapVisible(tester, const ValueKey('upload-scan-button'));

      expect(find.byKey(const ValueKey('upload-report')), findsNothing);
      expect(find.text('回传选中的 1 个改动'), findsOneWidget);
    });

    testWidgets('回传进行中禁用扫描与提交（防重复提交）', (tester) async {
      await pumpSync(
        tester,
        pickDirectory: () async => null,
        runSync: () async => okReport(),
        scanDirtyFiles: () async => scanWith([
          dirty('a1b2c3d4e5f60718293a4b5c6d7e8f90/reports/a.md', 10),
        ]),
        uploadChanges: (_) async {
          await Future<void>.delayed(const Duration(seconds: 10));
          return const UploadReport();
        },
        initialLocalRoot: '/root',
      );

      await tapVisible(tester, const ValueKey('upload-scan-button'));
      // 提交后进入 uploading 态（不 settle，保持进行中），按钮禁用断言见下。
      final submitFinder = find.byKey(const ValueKey('upload-submit-button'));
      await tester.ensureVisible(submitFinder);
      await tester.pumpAndSettle();
      await tester.tap(submitFinder);
      await tester.pump();

      expect(find.text('回传中…'), findsOneWidget);
      final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('upload-submit-button')),
      );
      expect(submit.onPressed, isNull);
      final scanBtn = tester.widget<TextButton>(
        find.byKey(const ValueKey('upload-scan-button')),
      );
      expect(scanBtn.onPressed, isNull);

      // 收尾：让挂起的 future 完成，避免 pending timer。
      await tester.pump(const Duration(seconds: 11));
    });
  });
}
