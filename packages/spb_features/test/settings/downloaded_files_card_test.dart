import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

const _groupA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _groupB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

DownloadedFileRecord _record(
  String groupId,
  String relativePath, {
  int size = 3,
  bool indexed = true,
}) => DownloadedFileRecord(
  groupId: groupId,
  relativePath: relativePath,
  fileName: relativePath.split('/').last,
  sizeBytes: size,
  isIndexed: indexed,
);

void main() {
  testWidgets('账号下载目录切换后重新读取统计', (tester) async {
    final loader = ValueNotifier<LoadDownloadedFiles>(
      () async => DownloadedFileInventory([_record(_groupA, 'a.txt')]),
    );
    addTearDown(loader.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<LoadDownloadedFiles>(
            valueListenable: loader,
            builder: (context, loadFiles, _) => DownloadedFilesCard(
              loadFiles: loadFiles,
              deleteFiles: (_) async => const DownloadedFileCleanupResult(
                deletedFiles: 0,
                deletedBytes: 0,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 个文件'), findsOneWidget);

    final nextInventory = Completer<DownloadedFileInventory>();
    loader.value = () => nextInventory.future;
    await tester.pump();

    expect(find.text('1 个文件'), findsNothing);
    final clearButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('settings-clear-downloaded-files')),
    );
    expect(clearButton.onPressed, isNull);

    nextInventory.complete(
      DownloadedFileInventory([
        _record(_groupB, 'b.txt'),
        _record(_groupB, 'c.txt'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 个文件'), findsOneWidget);
    expect(find.text('1 个对话'), findsOneWidget);
  });

  testWidgets('显示当前账号用量，清理全部必须确认且说明只影响本机', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var records = <DownloadedFileRecord>[
      _record(_groupA, 'reports/a.txt', size: 3),
      _record(_groupB, 'reports/b.txt', size: 5, indexed: false),
    ];
    var deleteCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadedFilesCard(
            loadFiles: () async => DownloadedFileInventory(records),
            deleteFiles: (keys) async {
              deleteCalls++;
              final selected = keys.toSet();
              final deleted = records
                  .where((file) => selected.contains(file.key))
                  .toList();
              records = records
                  .where((file) => !selected.contains(file.key))
                  .toList();
              return DownloadedFileCleanupResult(
                deletedFiles: deleted.length,
                deletedBytes: deleted.fold(
                  0,
                  (sum, file) => sum + file.sizeBytes,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 个文件'), findsOneWidget);
    expect(find.text('2 个对话'), findsOneWidget);
    expect(find.text('8 B'), findsOneWidget);
    expect(find.text('含索引缺失文件'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('settings-clear-downloaded-files')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('只删除本机下载副本'), findsOneWidget);
    expect(deleteCalls, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 0);

    await tester.tap(
      find.byKey(const ValueKey('settings-clear-downloaded-files')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleteCalls, 1);
    expect(records, isEmpty);
    expect(find.text('当前账号没有下载副本'), findsOneWidget);
  });

  testWidgets('按对话查看后可单独删除文件，索引缺失项也可清理', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var records = <DownloadedFileRecord>[
      _record(_groupA, 'reports/a.txt', size: 3),
      _record(_groupA, 'reports/b.txt', size: 4, indexed: false),
    ];
    final removed = <DownloadedFileKey>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadedFilesCard(
            loadFiles: () async => DownloadedFileInventory(records),
            deleteFiles: (keys) async {
              final selected = keys.toSet();
              removed.addAll(selected);
              final deleted = records
                  .where((file) => selected.contains(file.key))
                  .toList();
              records = records
                  .where((file) => !selected.contains(file.key))
                  .toList();
              return DownloadedFileCleanupResult(
                deletedFiles: deleted.length,
                deletedBytes: deleted.fold(
                  0,
                  (sum, file) => sum + file.sizeBytes,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings-manage-downloaded-files')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloaded-group-$_groupA')));
    await tester.pumpAndSettle();
    expect(find.text('reports/b.txt · 4 B · 索引缺失'), findsOneWidget);

    await tester.tap(find.byTooltip('删除此下载副本').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(removed, [(groupId: _groupA, relativePath: 'reports/b.txt')]);
    expect(find.text('reports/b.txt · 4 B · 索引缺失'), findsNothing);
    expect(records.length, 1);
  });
}
