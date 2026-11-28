/// 应用私有下载副本的清单与清理结果。
///
/// 下载副本与用户选择的同步工作区分开管理：清理本清单只影响当前账号的
/// `DownloadedFileStore`，不触碰远端文件或同步状态。
library;

/// 下载副本在账号目录内的稳定键。
typedef DownloadedFileKey = ({String groupId, String relativePath});

/// 磁盘上实际存在的一个下载文件。
///
/// `isIndexed == false` 表示文件已落盘，但索引没有对应记录（例如进程在原子
/// 提交索引前退出）。它仍计入占用并可由用户明确清理。
class DownloadedFileRecord {
  const DownloadedFileRecord({
    required this.groupId,
    required this.relativePath,
    required this.fileName,
    required this.sizeBytes,
    required this.isIndexed,
  });

  final String groupId;
  final String relativePath;
  final String fileName;
  final int sizeBytes;
  final bool isIndexed;

  DownloadedFileKey get key => (groupId: groupId, relativePath: relativePath);
}

/// 当前账号下载目录中实际存在的文件。
class DownloadedFileInventory {
  DownloadedFileInventory(Iterable<DownloadedFileRecord> files)
    : files = List.unmodifiable(files);

  final List<DownloadedFileRecord> files;

  int get totalFiles => files.length;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);

  Set<String> get groupIds => files.map((file) => file.groupId).toSet();
}

/// 用户确认后的本机下载清理结果。
class DownloadedFileCleanupResult {
  const DownloadedFileCleanupResult({
    required this.deletedFiles,
    required this.deletedBytes,
    this.failures = const {},
  });

  final int deletedFiles;
  final int deletedBytes;

  /// 相对路径 → 失败原因。部分成功时也保留每个失败项供界面反馈。
  final Map<String, String> failures;

  bool get hasFailures => failures.isNotEmpty;
}
