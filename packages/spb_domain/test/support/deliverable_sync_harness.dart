/// 交付物同步 的共享夹具（issue #48 从 `deliverable_sync_test.dart` 抽出）。
///
/// ⚠️ 文件私有的 `_Xxx` 移到共享库后必须去掉下划线（跨库不可见），
/// 故拆分时引用它们的调用点同步改名（纯重命名，无行为变化）。
library;

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

/// 内存下载桩：记录调用，按 fileId 返回内容/304/错误。
///
/// [notModifiedIds] 默认无条件返回 304（用于验证引擎对 304 的处理）。
/// 若打开 [conditionalOnly]，则只在本轮**确实带了** `If-None-Match` 时返回 304
/// —— 那才是真实服务端的行为，用于验证「引擎该不该带 etag」这类判据。
class StubDownloader implements FileDownloader {
  StubDownloader({
    this.notModifiedIds = const {},
    this.conditionalOnly = false,
  });

  final Set<String> notModifiedIds;

  /// true = 只在带条件头时返回 304（模拟真实服务端）。
  final bool conditionalOnly;

  final calls = <(String, String?)>[];
  final errors = <String, String>{};

  @override
  Future<SyncDownloadResult> download(
    String fileId, {
    String? ifNoneMatch,
  }) async {
    calls.add((fileId, ifNoneMatch));
    final err = errors[fileId];
    if (err != null) throw Exception(err);
    final should304 =
        notModifiedIds.contains(fileId) &&
        (!conditionalOnly || (ifNoneMatch != null && ifNoneMatch.isNotEmpty));
    if (should304) {
      return const SyncDownloadResult.notModified();
    }
    return const SyncDownloadResult.downloaded([1, 2, 3, 4, 5]);
  }
}

/// 内存落盘桩：记录写入/删除，可注入失败。
///
/// [exists] 默认按「`written` 里有没有」回答，另外可用 [preExisting] 模拟
/// 「状态里有记录但磁盘上没有 / 上有」这两种真实场景。
class StubSink implements FileSink, LocalFileReader {
  StubSink({Set<String>? preExisting})
    : preExisting = preExisting ?? const <String>{};

  final written = <String, List<int>>{};
  final deleted = <String>[];
  final failWrite = <String>{};
  final failDelete = <String>{};

  /// 额外视为「磁盘上已存在」的路径（模拟上次同步留下的文件）。
  final Set<String> preExisting;

  @override
  Future<void> write(String relPath, List<int> bytes) async {
    if (failWrite.contains(relPath)) throw Exception('磁盘满了');
    written[relPath] = bytes;
  }

  @override
  Future<void> delete(String relPath) async {
    if (failDelete.contains(relPath)) throw Exception('权限不足');
    deleted.add(relPath);
    written.remove(relPath);
  }

  @override
  Future<bool> exists(String relPath) async =>
      written.containsKey(relPath) || preExisting.contains(relPath);

  /// 读取已写入的字节（回传链路用；未写入/已删除时抛错，与真实实现
  /// `LocalFileSink.readBytes` 一致——不得返回空列表）。
  @override
  Future<List<int>> readBytes(String relPath) async {
    final bytes = written[relPath];
    if (bytes == null) {
      throw PlatformError('本地文件不存在：$relPath');
    }
    return bytes;
  }
}

/// 内存状态库（`SyncStateStore` 的最小实现，用于范围/目录变更语义）。
class MemoryStateStore implements SyncStateStore {
  final _data = <String, SyncState>{};
  int resetAllCount = 0;

  @override
  Future<SyncState> load(String key) async => _data[key] ?? SyncState.empty;

  @override
  Future<void> save(String key, SyncState state) async => _data[key] = state;

  @override
  Future<void> reset(String key) async => _data.remove(key);

  @override
  Future<void> resetAll() async {
    resetAllCount++;
    _data.clear();
  }
}

const gidFixture = 'g1';

/// 记录**在途重叠**的下载桩（验证并发是真的发生了）。
///
/// ## 为什么不能只看「调用了 N 次」
///
/// 串行实现同样会调用 N 次——次数无法区分串行与并发。真正要断言的是
/// **同时有多个在途**（`maxInFlight > 1`）。故每个 `download` 在返回前等待
/// 一个外部释放的 gate，调用方按需放行。
class ConcurrencyProbeDownloader implements FileDownloader {
  ConcurrencyProbeDownloader();

  int inFlight = 0;
  int maxInFlight = 0;

  /// 进入 `download` 的顺序（用于断言「是否按计划顺序发起」）。
  final started = <String>[];

  /// 完成顺序（用于断言合并顺序**不**取决于它）。
  final finished = <String>[];

  /// 每个 fileId 的延迟毫秒数（制造「先发起后完成」的乱序）。
  final delays = <String, int>{};

  /// 每个 fileId 实际收到的 `If-None-Match`（验证条件请求判据）。
  final conditionalEtags = <String, String?>{};

  final errors = <String, String>{};

  @override
  Future<SyncDownloadResult> download(
    String fileId, {
    String? ifNoneMatch,
  }) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    started.add(fileId);
    conditionalEtags[fileId] = ifNoneMatch;
    try {
      // ## 为什么**总是**至少让出一次事件循环
      //
      // 没有 await 的 async 函数体会同步跑完（含 `finally` 里的 `inFlight--`），
      // 于是每个下载在下一个 worker 启动前就已经结束——`maxInFlight` 恒为 1，
      // 测试就退化成「只看调用次数」（串行也满足）。真实下载必然有 I/O 挂起，
      // 这里用 `Duration.zero` 复现那个挂起点。
      await Future<void>.delayed(Duration(milliseconds: delays[fileId] ?? 0));
      final err = errors[fileId];
      if (err != null) throw Exception(err);
      finished.add(fileId);
      return const SyncDownloadResult.downloaded([1, 2, 3, 4, 5]);
    } finally {
      inFlight--;
    }
  }
}

/// 记录写入顺序的落盘桩（并发测试用；不模拟磁盘存在性）。
class OrderedSink implements FileSink {
  final writtenOrder = <String>[];
  final deletedOrder = <String>[];
  final failWrite = <String>{};

  /// 删除的延迟毫秒数（用于制造「删除比下载慢」的完成顺序）。
  final deleteDelays = <String, int>{};

  @override
  Future<void> write(String relPath, List<int> bytes) async {
    if (failWrite.contains(relPath)) throw Exception('磁盘满了');
    writtenOrder.add(relPath);
  }

  @override
  Future<void> delete(String relPath) async {
    final ms = deleteDelays[relPath];
    if (ms != null) await Future<void>.delayed(Duration(milliseconds: ms));
    deletedOrder.add(relPath);
  }

  @override
  Future<bool> exists(String relPath) async => false;
}

/// 构造远端条目。
///
/// `path` 默认带**尾斜杠**——这是 UFS 实测行为（`buildMaterializedPath`
/// 无条件拼 `name + '/'`），不带的话测试会掩盖真实场景。
UfsFileEntry remoteFixture(
  String rel, {
  String? id,
  int size = 10,
  String? mime = 'text/markdown',
  String? etag = 'W/"1"',
  String updatedAt = '2026-01-01T00:00:00Z',
  bool deleted = false,
  bool directory = false,
}) => UfsFileEntry.fromJson({
  'id': id ?? 'id-$rel',
  'path': '/workspace/groups/$gidFixture/$rel/',
  'name': rel.split('/').last,
  'size': size,
  'mime_type': mime,
  'is_directory': directory,
  if (etag != null) 'etag': etag,
  'updated_at': updatedAt,
  if (deleted) 'deleted_at': '2026-02-01T00:00:00Z',
});

SyncState stateWith(Map<String, SyncedFile> files, {String? cursor}) =>
    SyncState(cursor: cursor, files: files);

const permissiveFixture = SyncFilterConfig(maxFileSize: 0, includeMedia: true);
