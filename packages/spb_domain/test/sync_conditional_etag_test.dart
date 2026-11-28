import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

void main() {
  test('远端 ETag 更新后必须下载新正文，不能用新 ETag 声称本地已缓存', () async {
    final sink = StubSink()..written['a.md'] = [1, 2, 3];
    final downloader = _VersionedDownloader();
    final engine = SyncEngine(downloader: downloader, sink: sink);
    final state = stateWith({
      'a.md': SyncedFile(
        etag: 'etag-old',
        size: 3,
        contentHash: contentHashOf([1, 2, 3]),
      ),
    });
    final result = await engine.run(
      remote: [remoteFixture('a.md', etag: 'etag-new', size: 3)],
      state: state,
      scope: const SyncGroupScope(gidFixture),
      filter: permissiveFixture,
    );
    expect(sink.written['a.md'], [4, 5, 6]);
    expect(result.report.downloaded, 1);
    expect(result.report.notModified, 0);
    expect(result.state.files['a.md']?.etag, 'etag-new');
    expect(downloader.conditions, ['etag-old']);
  });
}

class _VersionedDownloader implements FileDownloader {
  final conditions = <String?>[];

  @override
  Future<SyncDownloadResult> download(
    String fileId, {
    String? ifNoneMatch,
  }) async {
    conditions.add(ifNoneMatch);
    // 真实 UFS 仅比较条件头和当前远端版本，不知道客户端磁盘里保存的正文。
    if (ifNoneMatch == 'etag-new') {
      return const SyncDownloadResult.notModified();
    }
    return const SyncDownloadResult.downloaded([4, 5, 6]);
  }
}
