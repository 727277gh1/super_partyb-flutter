import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

import 'support/deliverable_sync_harness.dart';

void main() {
  test('已隔离失败项不能让游标跨过另一条尚未隔离的失败项', () async {
    final downloader = StubDownloader()
      ..errors['id-old.md'] = '首次失败'
      ..errors['id-later.md'] = '连续失败';
    const state = SyncState(
      cursor: '2026-01-01T00:00:00Z',
      files: {},
      failures: {
        '$gidFixture/later.md': SyncFailureRecord(
          count: quarantineAfterFailures - 1,
          lastError: '连续失败',
          updatedAt: '2026-03-01T00:00:00Z',
        ),
      },
    );
    final result = await SyncEngine(downloader: downloader, sink: StubSink())
        .run(
          remote: [
            remoteFixture('old.md', updatedAt: '2026-02-01T00:00:00Z'),
            remoteFixture('later.md', updatedAt: '2026-03-01T00:00:00Z'),
          ],
          state: state,
          scope: const SyncWorkspaceScope(),
          filter: permissiveFixture,
        );
    expect(result.report.failed, hasLength(2));
    expect(result.report.quarantined.map((failure) => failure.relPath), [
      '$gidFixture/later.md',
    ]);
    expect(result.state.cursor, state.cursor);
  });
}
