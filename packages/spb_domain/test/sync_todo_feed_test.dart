import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `SyncTodoFeed`：本对话待确认同步项的取数 + 失效驱动。
///
/// ## 这个测试防的是什么
///
/// | 错误 | 后果 |
/// |---|---|
/// | 事件风暴逐条重拉 | 一次扫描拦下 N 个目录 → N 次 HTTP（真源是 GET，刷多次无意义） |
/// | 别的 group 的通知也重拉 | 用户在 A 对话里，B 对话的文件变更让 A 反复取数 |
/// | 失败清空列表 | 一次网关抖动让「待办」凭空消失，用户以为文件已被处理 |
/// | dispose 后仍写流 | `StateError: Cannot add event after closing`（页面退出即崩） |
void main() {
  WorkspaceSyncReview review(String id, {String revision = 'rev1'}) =>
      WorkspaceSyncReview(id: id, path: '$id/', revision: revision);

  WorkspaceSyncReviewsPage page(List<String> ids, {bool enabled = true}) =>
      WorkspaceSyncReviewsPage(
        enabled: enabled,
        items: [for (final id in ids) review(id)],
      );

  test('start 立即拉一次并推送 enabled + items', () async {
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async => page(['r1']),
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    final states = <SyncTodoFeedState>[];
    final sub = feed.changes.listen(states.add);
    await feed.start();
    await Future<void>.delayed(Duration.zero);

    expect(states.first.loading, isTrue, reason: '首帧先给「加载中」');
    expect(states.last.enabled, isTrue);
    expect(states.last.items.map((r) => r.id), ['r1']);
    expect(states.last.error, isNull);

    await sub.cancel();
  });

  test('todo.changed（本 group）触发重拉，别的 group 不触发', () async {
    var calls = 0;
    final changes = StreamController<TodoChange>.broadcast();
    addTearDown(changes.close);
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        return page(['r$calls']);
      },
      todoChanges: changes.stream,
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();
    expect(calls, 1);

    changes.add(
      const TodoChange(groupId: 'grp_other', op: TodoChangeOp.created),
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: '别的对话的文件变了与本对话无关');

    changes.add(const TodoChange(groupId: 'grp_1', op: TodoChangeOp.created));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });

  test('groupId 缺失的通知保守重拉（不确定范围）', () async {
    var calls = 0;
    final changes = StreamController<TodoChange>.broadcast();
    addTearDown(changes.close);
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        return page(['r1']);
      },
      todoChanges: changes.stream,
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();
    changes.add(const TodoChange(groupId: '', op: TodoChangeOp.created));
    await Future<void>.delayed(Duration.zero);

    expect(calls, 2);
  });

  test('事件风暴单飞：在途期间的多条通知只算一次', () async {
    var calls = 0;
    final changes = StreamController<TodoChange>.broadcast();
    addTearDown(changes.close);
    final gate = Completer<void>();
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        // 第一次之后的拉取被 gate 卡住，模拟慢网。
        if (calls > 1) await gate.future;
        return page(['r1']);
      },
      todoChanges: changes.stream,
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();
    for (var i = 0; i < 5; i++) {
      changes.add(const TodoChange(groupId: 'grp_1', op: TodoChangeOp.created));
    }
    await Future<void>.delayed(Duration.zero);

    expect(calls, 2, reason: '5 条事件合并成 1 次在途拉取');

    gate.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('轮询按 pollInterval 重复拉取，dispose 后停止', () async {
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        return page(['r1']);
      },
      // 真实短间隔（20ms）而不是 fakeAsync：这里验证的是「定时器真的在跑」，
      // 用假时钟还要额外处理 fetch 的 microtask 与 tearDown 的交互。
      pollInterval: const Duration(milliseconds: 20),
    );

    await feed.start();
    expect(calls, 1);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, greaterThanOrEqualTo(3), reason: '20ms 一次，100ms 内至少再拉 3 次');

    await feed.dispose();
    final before = calls;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, before, reason: 'dispose 之后必须停轮询');
  });

  test('失败保留上次列表，只记错误（不清空）', () async {
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        if (calls == 1) return page(['r1']);
        throw const NetworkError('网关抖动');
      },
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();
    expect(feed.state.items, hasLength(1));

    await feed.refresh();

    expect(feed.state.items, hasLength(1), reason: '抖动不该让待办凭空消失');
    expect(feed.state.error, '网关抖动');
  });

  test('成功一次即清空错误', () async {
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        if (calls == 1) throw const NetworkError('网关抖动');
        return page(['r1']);
      },
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();
    expect(feed.state.error, isNotNull);

    await feed.refresh();
    expect(feed.state.error, isNull);
    expect(feed.state.items, hasLength(1));
  });

  test('enabled=false 与「空列表」是两种状态', () async {
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async => page(const [], enabled: false),
      pollInterval: Duration.zero,
    );
    addTearDown(feed.dispose);

    await feed.start();

    expect(feed.state.enabled, isFalse);
    expect(feed.state.items, isEmpty);
  });

  test('dispose 后到达的响应不再写流（不抛）', () async {
    final gate = Completer<WorkspaceSyncReviewsPage>();
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () => gate.future,
      pollInterval: Duration.zero,
    );

    final started = feed.start();
    await feed.dispose();
    gate.complete(page(['r1']));

    // 不抛 StateError 即通过；状态也不该被更新。
    await started;
    expect(feed.state.items, isEmpty);
  });

  test('enabled=false 时降频轮询（不是停）：配好了仍能自动恢复', () async {
    // ## 本用例防的是什么
    //
    // `enabled: false` 是**服务端当次配置**（worker 没跑），不是「本对话没有待办」。
    // 若因此停掉轮询，「运维打开 groupsync」这件事就永远发现不了（用户得关掉
    // 重开对话页）；若仍按 15 秒打，等于给每个打开的对话页挂一条永久无效请求。
    // 故正确行为是降频，并在恢复 enabled 后自己回到快节奏。
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        // 头两轮未启用，之后启用（模拟运维开关）。
        return page(['r1'], enabled: calls > 2);
      },
      pollInterval: const Duration(milliseconds: 20),
      idlePollInterval: const Duration(milliseconds: 60),
    );
    addTearDown(feed.dispose);

    await feed.start();
    expect(feed.state.enabled, isFalse);

    // 100ms 内只该有降频的那一次（20ms 快节奏会打 4~5 次）。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, 2, reason: 'enabled=false 时必须按 idlePollInterval 降频');

    // 再等 200ms：降频又跑两轮 → enabled 变 true → 回到 20ms 快节奏。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(feed.state.enabled, isTrue);
    expect(
      calls,
      greaterThanOrEqualTo(5),
      reason: 'enabled 恢复后必须回到 pollInterval，而不是一直卡在降频',
    );
  });

  test('enabled=true 时按 pollInterval 轮询（不降频）', () async {
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        return page(['r1']);
      },
      pollInterval: const Duration(milliseconds: 20),
      idlePollInterval: const Duration(milliseconds: 500),
    );
    addTearDown(feed.dispose);

    await feed.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, greaterThanOrEqualTo(3), reason: 'enabled=true 走 20ms 快节奏');
  });

  test('start 幂等：重复调用不会叠加定时器', () async {
    var calls = 0;
    final feed = SyncTodoFeed(
      groupId: 'grp_1',
      fetch: () async {
        calls++;
        return page(['r1']);
      },
      pollInterval: const Duration(milliseconds: 50),
      idlePollInterval: const Duration(seconds: 60),
    );
    addTearDown(feed.dispose);

    await feed.start();
    await feed.start();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(calls, 1, reason: '第二次 start 不该再拉一次');
  });
}
