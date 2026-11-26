import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spb_data/spb_data.dart';
import 'package:spb_models/spb_models.dart';

UfsFileEntry entry(String id, {String group = 'grp_a', String? path}) =>
    UfsFileEntry(
      id: id,
      path: path ?? '/workspace/groups/$group/reports/$id.txt/',
      name: '$id.txt',
      mimeType: 'text/plain',
      size: 5,
    );

void main() {
  late Directory root;
  late DownloadedFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('spb_download_test_');
    store = DownloadedFileStore(() async => root);
  });
  tearDown(() async => root.delete(recursive: true));

  test('下载记录重启后仍可列出并读取，同路径远端条目不重复', () async {
    final file = entry('file_a');
    final path = await store.save('grp_a', file, utf8.encode('hello'));
    expect(path, endsWith('deliverables/grp_a/reports/file_a.txt'));

    final restored = DownloadedFileStore(() async => root);
    expect((await restored.merge('grp_a', [])).single.id, file.id);
    expect(await restored.read('grp_a', file), utf8.encode('hello'));
    expect(await restored.merge('grp_b', []), isEmpty);

    final remote = entry('remote_id', path: file.path);
    expect(await restored.merge('grp_a', [remote]), [remote]);
    final deleted = UfsFileEntry(
      id: file.id,
      path: file.path,
      size: 0,
      deletedAt: DateTime.utc(2026),
    );
    expect(await restored.merge('grp_a', [deleted]), [deleted]);
    expect(await restored.read('grp_a', deleted), isNull);
  });

  test('本地被删除时不再列出，读取返回 null 允许调用方回退远端', () async {
    final file = entry('file_a');
    final path = await store.save('grp_a', file, [1, 2, 3]);
    await File(path).delete();
    expect(await store.merge('grp_a', []), isEmpty);
    expect(await store.read('grp_a', file), isNull);
  });

  test('并发下载与失败后的下载都保留完整记录', () async {
    await Future.wait([
      store.save('grp_a', entry('one'), [1]),
      store.save('grp_a', entry('two'), [2]),
    ]);
    await expectLater(
      store.save(
        'grp_a',
        entry('bad', path: '/workspace/groups/grp_a/../bad/'),
        [0],
      ),
      throwsArgumentError,
    );
    await store.save('grp_a', entry('three'), [3]);
    final restored = DownloadedFileStore(() async => root);
    expect(
      (await restored.merge('grp_a', [])).map((file) => file.id),
      unorderedEquals(['one', 'two', 'three']),
    );
  });

  test('同路径更换 UFS id 后旧身份不能读到新文件', () async {
    final old = entry('old');
    final replacement = entry('new', path: old.path);
    await store.save('grp_a', old, [1]);
    await store.save('grp_a', replacement, [2, 3, 4, 5, 6]);
    expect(await store.read('grp_a', old), isNull);
    expect(await store.read('grp_a', replacement), [2, 3, 4, 5, 6]);
    expect((await store.merge('grp_a', [])).single.id, replacement.id);
  });

  test('旧的无账号索引目录不会被当前账号当作本地副本', () async {
    final old = File.fromUri(
      root.uri.resolve('agent/grp_a/reports/file_a.txt'),
    );
    await old.parent.create(recursive: true);
    await old.writeAsBytes([1, 2]);
    expect(await store.read('grp_a', entry('file_a')), isNull);
  });

  test('清单按实际磁盘文件统计，并把索引缺失文件纳入清理', () async {
    final indexed = entry('indexed');
    await store.save('grp_a', indexed, [1, 2, 3]);

    final orphan = File.fromUri(
      root.uri.resolve('deliverables/grp_a/reports/orphan.bin'),
    );
    await orphan.parent.create(recursive: true);
    await orphan.writeAsBytes([4, 5]);

    final inventory = await store.inventory();
    expect(inventory.totalFiles, 2);
    expect(inventory.totalBytes, 5);
    expect(inventory.groupIds, {'grp_a'});
    expect(
      inventory.files.map((file) => (file.relativePath, file.isIndexed)),
      unorderedEquals([
        ('reports/indexed.txt', true),
        ('reports/orphan.bin', false),
      ]),
    );
  });

  test('按文件删除只移除当前账号副本并更新索引', () async {
    final first = entry('first');
    const second = UfsFileEntry(
      id: 'second',
      path: '/workspace/groups/grp_a/reports/second.txt/',
      name: 'second.txt',
      mimeType: 'text/plain',
      size: 3,
    );
    await store.save('grp_a', first, [1, 2]);
    await store.save('grp_a', second, [3, 4, 5]);
    final inventory = await store.inventory();
    final selected = inventory.files.singleWhere(
      (file) => file.fileName == first.name,
    );

    final result = await store.removeFiles([selected.key]);
    expect(result.deletedFiles, 1);
    expect(result.deletedBytes, 2);
    expect(result.failures, isEmpty);
    expect(await store.read('grp_a', first), isNull);
    expect(await store.read('grp_a', second), [3, 4, 5]);
    expect((await store.inventory()).files.single.fileName, second.name);
  });

  test('拒绝删除穿越路径，其他选中项仍可部分成功', () async {
    final file = entry('safe');
    await store.save('grp_a', file, [1]);
    final outside = File.fromUri(root.uri.resolve('outside.txt'));
    await outside.writeAsString('keep');

    final result = await store.removeFiles([
      (groupId: 'grp_a', relativePath: '../outside.txt'),
      (groupId: 'grp_a', relativePath: 'reports/safe.txt'),
    ]);
    expect(result.deletedFiles, 1);
    expect(result.failures.keys, contains('grp_a/../outside.txt'));
    expect(await outside.readAsString(), 'keep');
  });

  test('只复用同一文件的同一修订，本地旧版本回退远端', () async {
    final original = UfsFileEntry(
      id: 'file_a',
      path: '/workspace/groups/grp_a/reports/file_a.txt/',
      size: 5,
      etag: 'etag-v1',
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await store.save('grp_a', original, utf8.encode('hello'), etag: 'etag-v1');
    final changed = UfsFileEntry(
      id: original.id,
      path: original.path,
      size: 5,
      etag: 'etag-v2',
      updatedAt: DateTime.utc(2026, 1, 2),
    );
    expect(await store.read('grp_a', changed), isNull);
    expect(await store.read('grp_a', original), utf8.encode('hello'));
  });

  test('索引损坏时从备份恢复，不能静默覆盖既有记录', () async {
    await store.save('grp_a', entry('one'), [1]);
    await store.save('grp_a', entry('two'), [2]);
    final index = File.fromUri(root.uri.resolve('.index/grp_a.json'));
    await index.writeAsString('{broken');

    final restored = DownloadedFileStore(() async => root);
    expect(
      (await restored.merge('grp_a', [])).map((file) => file.id),
      unorderedEquals(['one', 'two']),
    );
    await restored.save('grp_a', entry('three'), [3]);
    final afterSave = DownloadedFileStore(() async => root);
    expect(
      (await afterSave.merge('grp_a', [])).map((file) => file.id),
      unorderedEquals(['one', 'two', 'three']),
    );
  });

  test('没有可恢复的索引时拒绝覆盖坏记录，非法路径不能写出下载目录', () async {
    final index = File.fromUri(root.uri.resolve('.index/grp_a.json'));
    await index.parent.create(recursive: true);
    await index.writeAsString('{broken');
    await expectLater(
      store.save('grp_a', entry('good'), [1]),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      store.save('../escape', entry('bad', group: '../escape'), [1]),
      throwsArgumentError,
    );
  });

  test('流式下载按块落盘并在失败时不更新索引', () async {
    final path = await store.saveStream(
      'grp_a',
      entry('streamed'),
      Stream<List<int>>.fromIterable([
        [1, 2],
        [3, 4, 5],
      ]),
      etag: 'etag-stream',
    );
    expect(await File(path).readAsBytes(), [1, 2, 3, 4, 5]);
    expect(
      (await DownloadedFileStore(
        () async => root,
      ).merge('grp_a', [])).single.etag,
      'etag-stream',
    );

    await expectLater(
      store.saveStream(
        'grp_a',
        entry('failed'),
        Stream<List<int>>.error(StateError('network interrupted')),
      ),
      throwsStateError,
    );
    expect(
      (await DownloadedFileStore(
        () async => root,
      ).merge('grp_a', [])).map((file) => file.id),
      ['streamed'],
    );
    expect(
      await root
          .list(recursive: true)
          .where((entity) => entity.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
  });
}
