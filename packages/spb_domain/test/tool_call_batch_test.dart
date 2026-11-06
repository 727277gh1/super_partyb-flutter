import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 时间线连续工具调用的展示层折叠（`groupToolCallsForDisplay`）测试。
///
/// ## 这个测试防的是什么
///
/// 折叠是**纯展示形态**（`ConversationItem` 一条不动），所以它出错时不会抛
/// 异常、不会让任何既有用例失败——只是时间线上少了一截或多了个空壳。
/// 具体是这几类**静默错误**：
///
/// 1. 把正文夹在中间的两个工具调用合成一张卡（用户读到的顺序变成
///    「工具卡 → 正文」，而真实顺序是「工具 → 正文 → 工具」）；
/// 2. 跨 turn 合并（两件事说成一件，与文件批同一类错误）；
/// 3. `turnId` 为空也折叠（归属未知时相邻两条可能来自不同 turn）；
/// 4. 折叠行**丢了成员 id**（搜索能搜到却定位不到，只能退化成
///    「请向上滚动」——这正是 `locateIdsOf` 那条断言的作用）。
///
/// 口径真源是 `agent_file_batch.dart` 的 `ToolCallBatchRow` 文档（以及
/// `tool_call_batch.dart` 的口径表）。
const _turnA = 'turn_a';
const _turnB = 'turn_b';

/// 一个工具调用项。[output] 为 null 表示**还在跑**。
ToolCallItem _tool(
  String id, {
  String turnId = _turnA,
  String name = 'Read',
  String? output = 'ok',
}) => ToolCallItem(
  id: id,
  createdAt: DateTime.utc(2026, 9, 14, 0, 0, 0),
  name: name,
  turnId: turnId,
  output: output,
  isComplete: output != null,
);

/// 正文（既不是文件也不是工具 → 断点）。
AssistantMessageItem _text(String id, {String turnId = _turnA}) =>
    AssistantMessageItem(
      id: id,
      createdAt: DateTime.utc(2026, 9, 14, 0, 0, 0),
      text: 'x',
      turnId: turnId,
    );

void main() {
  group('阈值边界（TOOL_CALL_BATCH_MIN_COUNT = 5）', () {
    for (final (count, expectBatch) in [(4, false), (5, true), (6, true)]) {
      test('连续 $count 个 → ${expectBatch ? "折叠卡" : "逐条"}', () {
        final rows = groupToolCallsForDisplay([
          for (var i = 0; i < count; i++) SingleItemRow(_tool('t$i')),
        ]);

        expect(rows, hasLength(expectBatch ? 1 : count));
        if (expectBatch) {
          expect(rows.single, isA<ToolCallBatchRow>());
          expect((rows.single as ToolCallBatchRow).count, count);
        } else {
          // 不足阈值时必须**原样吐出原行对象**（不是重建的等价行）：
          // 页面按 `ValueKey(item.id)` 复用 Element，重建行不会出错，但
          // 会让「逐条路径」多一次无意义的对象分配，也让 identity 断言失效。
          expect(rows.every((r) => r is SingleItemRow), isTrue);
        }
      });
    }

    test('恰好 5 个是下限（4 个逐条、5 个成卡，边界不漂移）', () {
      expect(TOOL_CALL_BATCH_MIN_COUNT, 5);
      final four = groupToolCallsForDisplay([
        for (var i = 0; i < 4; i++) SingleItemRow(_tool('t$i')),
      ]);
      final five = groupToolCallsForDisplay([
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('t$i')),
      ]);
      expect(four.whereType<ToolCallBatchRow>(), isEmpty);
      expect(five.whereType<ToolCallBatchRow>(), hasLength(1));
    });
  });

  group('断点：任何非工具调用行都切断当前批', () {
    test('正文夹在中间 → 两段各自判阈值（都不足 → 逐条）', () {
      final rows = groupToolCallsForDisplay([
        SingleItemRow(_tool('a')),
        SingleItemRow(_tool('b')),
        SingleItemRow(_text('m')),
        SingleItemRow(_tool('c')),
        SingleItemRow(_tool('d')),
      ]);

      expect(rows.whereType<ToolCallBatchRow>(), isEmpty);
      expect(rows, hasLength(5));
    });

    test('正文夹在中间 → 两段各自 5 个都成卡（顺序不被打乱）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('a$i')),
        SingleItemRow(_text('m')),
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('b$i')),
      ]);

      expect(rows, hasLength(3));
      expect(rows[0], isA<ToolCallBatchRow>());
      expect((rows[0] as ToolCallBatchRow).calls.first.id, 'a0');
      expect(rows[1], isA<SingleItemRow>());
      expect(rows[2], isA<ToolCallBatchRow>());
      expect((rows[2] as ToolCallBatchRow).calls.first.id, 'b0');
    });

    test('跨 turn 不得合并（即使连着且都够 5 个）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('a$i')),
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('b$i', turnId: _turnB)),
      ]);

      expect(rows, hasLength(2));
      final first = rows[0] as ToolCallBatchRow;
      final second = rows[1] as ToolCallBatchRow;
      expect(first.calls.every((c) => c.turnId == _turnA), isTrue);
      expect(second.calls.every((c) => c.turnId == _turnB), isTrue);
    });

    test('turnId 为空 → 整段逐条（归属未知时宁可不折叠）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 8; i++) SingleItemRow(_tool('t$i', turnId: '')),
      ]);

      expect(rows.whereType<ToolCallBatchRow>(), isEmpty);
      expect(rows, hasLength(8));
    });

    test('文件批量卡是断点（工具批不得吸进文件卡，也不得跨过它合并）', () {
      // 先跑文件聚合：同 turn 同秒的 5 个文件会成一张 AgentFileBatchRow。
      final items = <ConversationItem>[
        for (var i = 0; i < 5; i++) _tool('t$i'),
        for (var i = 0; i < 5; i++)
          AgentFileItem(
            id: 'f$i',
            createdAt: DateTime.utc(2026, 9, 14, 0, 0, 0),
            relativePath: 'out/f$i.md',
            fileName: 'f$i.md',
            displayName: 'f$i.md',
            action: 'created',
            turnId: _turnA,
            ufsFileId: 'ufs_f$i',
            mimeType: 'text/markdown',
          ),
        for (var i = 0; i < 5; i++) _tool('u$i'),
      ];

      final rows = groupTimelineForDisplay(items);

      // 顺序 [工具批][文件批][工具批]：文件卡把两段工具调用彻底隔开，
      // 而不是把 10 条并成一段。
      expect(rows, hasLength(3));
      expect(rows[0], isA<ToolCallBatchRow>());
      expect((rows[0] as ToolCallBatchRow).calls.map((c) => c.id).toList(), [
        't0',
        't1',
        't2',
        't3',
        't4',
      ]);
      expect(rows[1], isA<AgentFileBatchRow>());
      expect((rows[1] as AgentFileBatchRow).count, 5);
      expect(rows[2], isA<ToolCallBatchRow>());
      expect((rows[2] as ToolCallBatchRow).calls.map((c) => c.id).toList(), [
        'u0',
        'u1',
        'u2',
        'u3',
        'u4',
      ]);
    });
  });

  group('不丢内容（折叠 ≠ 删除）', () {
    test('成员顺序与逐条一致，且覆盖全部工具调用', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 12; i++) SingleItemRow(_tool('t$i', name: 'T$i')),
      ]);

      final batch = rows.single as ToolCallBatchRow;
      expect(batch.calls.map((c) => c.id), [
        for (var i = 0; i < 12; i++) 't$i',
      ]);
      expect(batch.calls.map((c) => c.name), [
        for (var i = 0; i < 12; i++) 'T$i',
      ]);
    });

    test('locateIdsOf 返回全部成员 id（否则搜索定位会退化）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 6; i++) SingleItemRow(_tool('t$i')),
      ]);

      expect(locateIdsOf(rows.single), ['t0', 't1', 't2', 't3', 't4', 't5']);
      // 与 `locateIdsOfAll` 同口径（页面用它同时做注册与回收）。
      expect(locateIdsOfAll(rows), ['t0', 't1', 't2', 't3', 't4', 't5']);
    });

    test('未完成的工具调用也算成员（看门狗用它判「turn 仍在跑」）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 4; i++) SingleItemRow(_tool('t$i')),
        SingleItemRow(_tool('t4', output: null)),
        SingleItemRow(_tool('t5', output: null)),
      ]);

      final batch = rows.single as ToolCallBatchRow;
      expect(batch.count, 6);
      expect(batch.hasRunning, isTrue);
      expect(batch.completedCount, 4);
    });
  });

  group('hasRunning / completedCount', () {
    test('全部完成 → hasRunning 为 false', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('t$i')),
      ]);
      final batch = rows.single as ToolCallBatchRow;
      expect(batch.hasRunning, isFalse);
      expect(batch.completedCount, 5);
      expect(batch.last.id, 't4');
    });

    test('最后一个还在跑 → last 就是它（卡片副标题用「最近」）', () {
      final rows = groupToolCallsForDisplay([
        for (var i = 0; i < 5; i++) SingleItemRow(_tool('t$i')),
        SingleItemRow(_tool('t5', name: 'Bash', output: null)),
      ]);
      final batch = rows.single as ToolCallBatchRow;
      expect(batch.last.name, 'Bash');
      expect(batch.hasRunning, isTrue);
      expect(batch.completedCount, 5);
    });
  });

  group('空输入与退化输入', () {
    test('空列表 → 空输出（不产生空批）', () {
      expect(groupToolCallsForDisplay(const []), isEmpty);
      expect(groupTimelineForDisplay(const []), isEmpty);
    });

    test('只有正文 → 原样（不误判成批）', () {
      final rows = groupToolCallsForDisplay([
        SingleItemRow(_text('m1')),
        SingleItemRow(_text('m2')),
      ]);
      expect(rows, hasLength(2));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });
  });
}
