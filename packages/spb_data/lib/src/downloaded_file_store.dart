import 'dart:convert';
import 'dart:io';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 两个下载入口共用持久化记录；只记录成功落盘的文件，不参与同步游标。
class DownloadedFileStore {
  DownloadedFileStore(this._downloadsDirectory);

  final Future<Directory> Function() _downloadsDirectory;
  final _entries = <String, Map<String, UfsFileEntry>>{};
  final _unrecoverableIndexes = <String>{};
  Future<void> _writes = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        // 单次失败由调用方处理，不能阻塞后续保存或清理。
      },
    );
    return result;
  }

  bool _validGroupId(String groupId) =>
      isValidPathSegment(groupId) && !groupId.contains('/');

  File _child(Directory root, String relativePath) => File.fromUri(
    root.uri.resolve(
      relativePath.split('/').map(Uri.encodeComponent).join('/'),
    ),
  );

  Future<Map<String, UfsFileEntry>> _readIndex(
    File index,
    String groupId,
  ) async {
    final decoded = jsonDecode(await index.readAsString()) as List<dynamic>;
    final entries = <String, UfsFileEntry>{};
    for (final value in decoded) {
      final file = UfsFileEntry.fromJson(value as Map<String, dynamic>);
      if (file.id.isNotEmpty && groupRelativePath(file.path, groupId) != null) {
        entries[file.id] = file;
      }
    }
    return entries;
  }

  Future<Map<String, UfsFileEntry>> _load(String groupId) async {
    if (!_validGroupId(groupId)) return {};
    final cached = _entries[groupId];
    if (cached != null) return cached;
    final root = await _downloadsDirectory();
    final index = _child(root, '.index/$groupId.json');
    final backup = _child(root, '.index/$groupId.json.bak');
    try {
      if (await index.exists()) {
        return _entries[groupId] = await _readIndex(index, groupId);
      }
      return _entries[groupId] = await backup.exists()
          ? await _readIndex(backup, groupId)
          : <String, UfsFileEntry>{};
    } on Object catch (e) {
      if (await backup.exists()) {
        try {
          final recovered = await _readIndex(backup, groupId);
          SpbLog.warn('下载索引损坏，已从备份恢复', {'group': groupId});
          return _entries[groupId] = recovered;
        } on Object catch (backupError) {
          SpbLog.warn('下载索引及备份均不可读', {
            'group': groupId,
            'error': '$e',
            'backup_error': '$backupError',
          });
        }
      } else {
        SpbLog.warn('读取下载索引失败', {'group': groupId, 'error': '$e'});
      }
      _unrecoverableIndexes.add(groupId);
      return <String, UfsFileEntry>{};
    }
  }

  Future<void> _writeIndex(
    Directory root,
    String groupId,
    Map<String, UfsFileEntry> entries,
  ) async {
    final index = _child(root, '.index/$groupId.json');
    await index.parent.create(recursive: true);
    final indexPart = File('${index.path}.part');
    final backupPart = File('${index.path}.bak.part');
    try {
      await indexPart.writeAsString(
        jsonEncode([
          for (final entry in entries.values)
            {
              'id': entry.id,
              'path': entry.path,
              'name': entry.name,
              'size': entry.size,
              'mime_type': entry.mimeType,
              'etag': entry.etag,
              'created_at': entry.createdAt?.toIso8601String(),
              'updated_at':
                  entry.updatedAtRaw ?? entry.updatedAt?.toIso8601String(),
              'metadata_json': entry.metadata,
            },
        ]),
        flush: true,
      );
      // 先提交一份完整索引，主文件切换中断时仍有可恢复版本。
      await indexPart.copy(backupPart.path);
      await backupPart.rename('${index.path}.bak');
      await indexPart.rename(index.path);
    } on Object {
      for (final temporary in [indexPart, backupPart]) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } on Object {
          // 保留原始索引错误；遗留临时索引不会被当作有效记录读取。
        }
      }
      rethrow;
    }
  }

  /// 保留 group 内目录结构，并串行提交索引，避免同时下载时互相覆盖记录。
  Future<String> save(
    String groupId,
    UfsFileEntry file,
    List<int> bytes, {
    String? etag,
  }) => _save(
    groupId,
    file,
    etag: etag,
    write: (part) async {
      await part.writeAsBytes(bytes, flush: true);
      return bytes.length;
    },
  );

  /// 流式落盘，峰值内存限制为传输块大小。
  Future<String> saveStream(
    String groupId,
    UfsFileEntry file,
    Stream<List<int>> bytes, {
    String? etag,
  }) => _save(
    groupId,
    file,
    etag: etag,
    write: (part) async {
      var size = 0;
      final sink = part.openWrite();
      try {
        await sink.addStream(
          bytes.map((chunk) {
            size += chunk.length;
            return chunk;
          }),
        );
        await sink.flush();
      } on Object {
        try {
          await sink.close();
        } on Object {
          // 保留导致流失败的原始错误。
        }
        rethrow;
      }
      await sink.close();
      return size;
    },
  );

  Future<String> _save(
    String groupId,
    UfsFileEntry file, {
    required String? etag,
    required Future<int> Function(File part) write,
  }) async {
    final rel = groupRelativePath(file.path, groupId);
    if (!_validGroupId(groupId) ||
        rel == null ||
        file.id.isEmpty ||
        file.isDirectory ||
        file.isDeleted) {
      throw ArgumentError('无效的交付物下载路径');
    }
    return _serialize(() async {
      final entries = await _load(groupId);
      if (_unrecoverableIndexes.contains(groupId)) {
        throw const FileSystemException('下载索引损坏，拒绝覆盖现有记录');
      }
      final root = await _downloadsDirectory();
      final target = _child(root, 'deliverables/$groupId/$rel');
      await target.parent.create(recursive: true);
      final part = File('${target.path}.part');
      late final int size;
      try {
        size = await write(part);
        await part.rename(target.path);
      } on Object {
        try {
          if (await part.exists()) await part.delete();
        } on Object {
          // 保留原始下载错误；下次写入仍会覆盖残留的 .part。
        }
        rethrow;
      }
      // 同路径换了 UFS id 时，旧身份不能再读到新文件的内容。
      final savedFile = _copyEntry(file, size: size, etag: etag ?? file.etag);
      final updated = Map<String, UfsFileEntry>.of(entries)
        ..removeWhere(
          (_, entry) => groupRelativePath(entry.path, groupId) == rel,
        )
        ..[file.id] = savedFile;
      await _writeIndex(root, groupId, updated);
      _entries[groupId] = updated;
      _unrecoverableIndexes.remove(groupId);
      return target.path;
    });
  }

  /// 扫描当前账号下载目录中的实际文件，避免索引损坏或中断写入导致占用漏算。
  Future<DownloadedFileInventory> inventory() async {
    await _writes;
    final root = await _downloadsDirectory();
    final deliverables = Directory(_child(root, 'deliverables').path);
    if (await FileSystemEntity.type(deliverables.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return DownloadedFileInventory(const []);
    }

    final records = <DownloadedFileRecord>[];
    await for (final groupEntity in deliverables.list(followLinks: false)) {
      if (groupEntity is! Directory) continue;
      final groupId = groupEntity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (!_validGroupId(groupId)) continue;

      final indexedByPath = <String, UfsFileEntry>{};
      final entries = await _load(groupId);
      for (final entry in entries.values) {
        final rel = groupRelativePath(entry.path, groupId);
        if (rel != null) indexedByPath[rel] = entry;
      }

      Future<void> visit(Directory directory, String prefix) async {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is Link) continue;
          final rel = prefix.isEmpty
              ? entity.path.substring(groupEntity.path.length + 1)
              : '$prefix/${entity.path.substring(directory.path.length + 1)}';
          final normalizedRel = rel.replaceAll(Platform.pathSeparator, '/');
          if (entity is Directory) {
            await visit(entity, normalizedRel);
          } else if (entity is File) {
            final entry = indexedByPath[normalizedRel];
            records.add(
              DownloadedFileRecord(
                groupId: groupId,
                relativePath: normalizedRel,
                fileName: switch (entry) {
                  final indexed? when indexed.name.isNotEmpty => indexed.name,
                  _ => normalizedRel.split('/').last,
                },
                sizeBytes: await entity.length(),
                isIndexed: entry != null,
              ),
            );
          }
        }
      }

      await visit(groupEntity, '');
    }

    records.sort((a, b) {
      final byGroup = a.groupId.compareTo(b.groupId);
      return byGroup != 0 ? byGroup : a.relativePath.compareTo(b.relativePath);
    });
    return DownloadedFileInventory(records);
  }

  /// 删除用户选中的下载副本；只处理账号目录内的普通文件，不跟随符号链接。
  Future<DownloadedFileCleanupResult> removeFiles(
    Iterable<DownloadedFileKey> keys,
  ) {
    final requested = keys.toSet();
    if (requested.isEmpty) {
      return Future.value(
        const DownloadedFileCleanupResult(deletedFiles: 0, deletedBytes: 0),
      );
    }

    return _serialize(() async {
      final root = await _downloadsDirectory();
      var deletedFiles = 0;
      var deletedBytes = 0;
      final failures = <String, String>{};
      final groups = requested.map((key) => key.groupId).toSet();

      for (final groupId in groups) {
        if (!_validGroupId(groupId)) {
          failures[groupId] = '无效的对话目录';
          continue;
        }
        final entries = await _load(groupId);
        final updated = Map<String, UfsFileEntry>.of(entries);
        var indexChanged = false;
        final groupKeys = requested.where((key) => key.groupId == groupId);

        for (final key in groupKeys) {
          final label = '$groupId/${key.relativePath}';
          if (!_validRelativePath(key.relativePath)) {
            failures[label] = '无效的文件路径';
            continue;
          }
          final target = await _safeFile(root, groupId, key.relativePath);
          if (target == null) {
            final previousLength = updated.length;
            updated.removeWhere(
              (_, entry) =>
                  groupRelativePath(entry.path, groupId) == key.relativePath,
            );
            indexChanged = updated.length != previousLength || indexChanged;
            continue;
          }

          try {
            final size = await target.length();
            await target.delete();
            deletedFiles++;
            deletedBytes += size;
            final previousLength = updated.length;
            updated.removeWhere(
              (_, entry) =>
                  groupRelativePath(entry.path, groupId) == key.relativePath,
            );
            indexChanged = updated.length != previousLength || indexChanged;
          } on Object catch (e) {
            failures[label] = '删除失败：$e';
          }
        }

        _entries[groupId] = updated;
        if (indexChanged && !_unrecoverableIndexes.contains(groupId)) {
          try {
            await _writeIndex(root, groupId, updated);
          } on Object catch (e) {
            failures['$groupId/<索引>'] = '文件已删除，但索引更新失败：$e';
          }
        }
      }

      return DownloadedFileCleanupResult(
        deletedFiles: deletedFiles,
        deletedBytes: deletedBytes,
        failures: failures,
      );
    });
  }

  bool _validRelativePath(String relativePath) =>
      relativePath.isNotEmpty &&
      relativePath.split('/').every(isValidPathSegment);

  Future<File?> _safeFile(
    Directory root,
    String groupId,
    String relativePath,
  ) async {
    final segments = relativePath.split('/');
    var directory = Directory(_child(root, 'deliverables/$groupId').path);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    for (final segment in segments.take(segments.length - 1)) {
      directory = Directory(_child(directory, segment).path);
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
    }
    final target = File(_child(directory, segments.last).path);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    return target;
  }

  /// 只读当前账号索引并核对远端版本；旧版无账号归属的缓存不自动复用。
  Future<String?> localPath(String groupId, UfsFileEntry file) async {
    if (file.isDeleted || file.id.isEmpty) return null;
    final rel = groupRelativePath(file.path, groupId);
    if (rel == null || !_validGroupId(groupId)) return null;
    try {
      final entries = await _load(groupId);
      final entry = entries[file.id];
      if (entry == null || !_matchesVersion(entry, file)) return null;
      final root = await _downloadsDirectory();
      final savedRel = groupRelativePath(entry.path, groupId);
      if (savedRel == null) return null;
      final target = _child(root, 'deliverables/$groupId/$savedRel');
      if (await target.exists()) return target.path;
    } on Object catch (e) {
      SpbLog.debug('本地下载副本不可用', {'error': '$e'});
    }
    return null;
  }

  Future<List<int>?> read(
    String groupId,
    UfsFileEntry file, {
    int? maxBytes,
  }) async {
    final path = await localPath(groupId, file);
    if (path == null) return null;
    try {
      final local = File(path);
      if (maxBytes != null && await local.length() > maxBytes) return null;
      return await local.readAsBytes();
    } on FileSystemException catch (e) {
      SpbLog.debug('读取本地下载副本失败', {'error': '$e'});
      return null;
    }
  }

  /// 远端缺席不代表删除；同 id 或同路径由远端记录覆盖（包括软删除）。
  Future<List<UfsFileEntry>> merge(
    String groupId,
    List<UfsFileEntry> remote,
  ) async {
    final entries = await _load(groupId);
    final ids = remote.map((e) => e.id).toSet();
    final paths = remote.map((e) => groupRelativePath(e.path, groupId)).toSet();
    final local = <UfsFileEntry>[];
    for (final file in entries.values) {
      if (!ids.contains(file.id) &&
          !paths.contains(groupRelativePath(file.path, groupId)) &&
          await localPath(groupId, file) != null) {
        local.add(file);
      }
    }
    return [...remote, ...local];
  }

  bool _matchesVersion(UfsFileEntry saved, UfsFileEntry current) {
    return downloadedFileMatchesVersion(saved, current);
  }

  UfsFileEntry _copyEntry(
    UfsFileEntry file, {
    required int size,
    required String? etag,
  }) => UfsFileEntry(
    id: file.id,
    path: file.path,
    name: file.name,
    parentId: file.parentId,
    mimeType: file.mimeType,
    isDirectory: file.isDirectory,
    etag: etag,
    updatedAt: file.updatedAt,
    updatedAtRaw: file.updatedAtRaw ?? file.updatedAt?.toIso8601String(),
    createdAt: file.createdAt,
    deletedAt: file.deletedAt,
    ownerType: file.ownerType,
    ownerId: file.ownerId,
    metadata: file.metadata,
    raw: file.raw,
    size: size,
  );
}
