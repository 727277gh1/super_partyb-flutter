import 'dart:async';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `collectWorkspaceSyncReviews` 的聚合测试。
///
/// ## 这个测试防的是什么
///
/// 聚合层是「全部对话」范围下唯一把 N 个 per-group 响应拼成一份列表的地方，
/// 四类错误都会**静默**发生：
///
/// | 错误 | 后果 |
/// |---|---|
/// | 结果按完成顺序拼接 | 同一条待确认项在两次轮询间上下跳（用户点错按钮） |
/// | 单个 group 失败就整体失败 | 一个已归档的对话让所有待确认项消失 |
/// | 不限并发 | 「全部对话」范围下每 15 秒打几十个请求 |
/// | `enabled` 取 any-of 时写反 | 服务端没跑 groupsync 时仍展示空区块，或反之整块不显示 |
void main() {
  WorkspaceSyncReview review(String id, {String revision = 'rev1'}) =>
      WorkspaceSyncReview(
        id: id,
        groupId: 'g',
        path: '$id.pdf',
        revision: revision,
      );

  WorkspaceSyncReviewsPage page(List<String> ids, {bool enabled = true}) =>
      WorkspaceSyncReviewsPage(
        enabled: enabled,
        items: [for (final id in ids) review(id)],
      );

  test('多个 group 的待确认项按传入顺序聚合，并带上标题', () async {
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [
        WorkspaceSyncReviewGroup(id: 'g1', title: '月度报表'),
        WorkspaceSyncReviewGroup(id: 'g2', title: '故障排查'),
      ],
      fetch: (gid) async => page(['$gid-a', '$gid-b']),
    );

    expect(snapshot.enabled, isTrue);
    expect(snapshot.failedGroups, 0);
    expect(snapshot.entries.map((e) => e.groupId), ['g1', 'g1', 'g2', 'g2']);
    expect(snapshot.entries.map((e) => e.groupTitle), [
      '月度报表',
      '月度报表',
      '故障排查',
      '故障排查',
    ]);
    expect(snapshot.entries.map((e) => e.review.id), [
      'g1-a',
      'g1-b',
      'g2-a',
      'g2-b',
    ]);
  });

  test('后完成的请求不影响顺序（按下标回填，不按完成顺序拼接）', () async {
    final completers = <String, Completer<WorkspaceSyncReviewsPage>>{};
    final snapshotFuture = collectWorkspaceSyncReviews(
      groups: const [
        WorkspaceSyncReviewGroup(id: 'g1', title: 'A'),
        WorkspaceSyncReviewGroup(id: 'g2', title: 'B'),
      ],
      fetch: (gid) => (completers[gid] = Completer()).future,
    );

    expect(completers.keys, ['g1', 'g2'], reason: '两路并发都应已发起');
    // 故意让**后面的**先完成。
    completers['g2']!.complete(page(['b1']));
    await Future<void>.delayed(Duration.zero);
    completers['g1']!.complete(page(['a1']));
    final snapshot = await snapshotFuture;

    expect(snapshot.entries.map((e) => e.review.id), ['a1', 'b1']);
  });

  test('单个 group 失败不拖垮其余项（计入 failedGroups）', () async {
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [
        WorkspaceSyncReviewGroup(id: 'g1', title: 'A'),
        WorkspaceSyncReviewGroup(id: 'g2', title: 'B'),
      ],
      fetch: (gid) async {
        if (gid == 'g2') throw StateError('404 已归档');
        return page(['a1']);
      },
    );

    expect(snapshot.failedGroups, 1);
    expect(snapshot.entries.map((e) => e.review.id), ['a1']);
    expect(snapshot.enabled, isTrue, reason: '成功的 group 说明功能已启用');
  });

  test('全部 group 都 disabled 时 enabled=false 且无条目', () async {
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [WorkspaceSyncReviewGroup(id: 'g1')],
      fetch: (gid) async => page(const [], enabled: false),
    );

    expect(snapshot.enabled, isFalse);
    expect(snapshot.isEmpty, isTrue);
  });

  test('并发数被限制（全部对话范围下不打几十个请求）', () async {
    var inFlight = 0;
    var peak = 0;
    var started = 0;
    final releases = <Completer<void>>[];

    final snapshotFuture = collectWorkspaceSyncReviews(
      groups: [
        for (var i = 0; i < 12; i++) WorkspaceSyncReviewGroup(id: 'g$i'),
      ],
      concurrency: 3,
      fetch: (gid) async {
        inFlight++;
        started++;
        if (inFlight > peak) peak = inFlight;
        final gate = Completer<void>();
        releases.add(gate);
        await gate.future;
        inFlight--;
        return page(['$gid-x']);
      },
    );

    // 让首批 worker 都进入 fetch。
    await Future<void>.delayed(Duration.zero);
    expect(peak, 3, reason: '同时只有 concurrency 路在途');
    expect(started, 3, reason: '其余请求要等前一批完成');

    // 逐个放行；并发峰值全程不得越界（否则「全部对话」范围会打出一波突发）。
    var released = 0;
    while (released < releases.length) {
      releases[released].complete();
      released++;
      await Future<void>.delayed(Duration.zero);
      expect(peak, lessThanOrEqualTo(3));
    }

    final snapshot = await snapshotFuture;
    expect(snapshot.entries, hasLength(12));
    expect(snapshot.entries.map((e) => e.review.id).first, 'g0-x');
  });

  test('空 group 列表不发起任何请求', () async {
    var calls = 0;
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [],
      fetch: (gid) async {
        calls++;
        return page(['x']);
      },
    );

    expect(calls, 0);
    expect(snapshot.enabled, isFalse);
    expect(snapshot.entries, isEmpty);
  });

  test('空 id 的 group 计为失败，且不拼出非法路径', () async {
    var calls = 0;
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [
        WorkspaceSyncReviewGroup(id: ''),
        WorkspaceSyncReviewGroup(id: 'g1', title: 'A'),
      ],
      fetch: (gid) async {
        calls++;
        return page(['a1']);
      },
    );

    expect(calls, 1);
    expect(snapshot.failedGroups, 1);
    expect(snapshot.entries.map((e) => e.review.id), ['a1']);
  });

  test('queriedGroupIds 记下真的查过的 group（空 id 不计）', () async {
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [
        WorkspaceSyncReviewGroup(id: 'g1'),
        WorkspaceSyncReviewGroup(id: '  '),
        WorkspaceSyncReviewGroup(id: 'g2'),
      ],
      fetch: (gid) async => page(const []),
    );

    expect(snapshot.queriedGroupIds, {
      'g1',
      'g2',
    }, reason: 'todo.changed 靠它判断「这次通知是否可能改变本快照」');
    expect(
      snapshot.queriedGroupIds,
      isNot(contains('')),
      reason: '空 id 没查过（计为失败），不得混进查询集',
    );
  });

  test('空 group 列表时 queriedGroupIds 为空集', () async {
    final snapshot = await collectWorkspaceSyncReviews(
      groups: const [],
      fetch: (gid) async => page(['x']),
    );

    expect(snapshot.queriedGroupIds, isEmpty);
  });
}
