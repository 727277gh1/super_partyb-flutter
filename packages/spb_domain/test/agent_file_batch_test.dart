import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 同 turn 同秒文件事件批量聚合（`groupFileEventsForDisplay`）测试。
///
/// ## 这个测试防的是什么
///
/// 聚合是**纯展示形态**（不改归约结果），所以它出错时不会报错、不会崩——
/// 只是时间线看起来「不太对」：一批刚删掉的文件显示成「生成了 5 个文件」、
/// 跨 turn 的两个文件被并成一张卡、或者语音分段被吸进批量卡丢了顺序。
/// 这些都是**静默错误**，只能靠逐条锁定口径来防。
///
/// 口径真源是 webapp `apps/webapp/src/lib/workbench/agent-file-batch.ts` 的
/// `groupFileEventsForDisplay`（它自己又与小程序 `timeline/file-batches.ts`
/// 同口径）。**三端必须一致**——不一致会让同一个 turn 在 webapp 与客户端
/// 显示成不同形状，用户会以为数据不同。
const _turnA = 'turn_a';
const _turnB = 'turn_b';

/// 一个普通文件项（非 TTS）。
///
/// [second] 是「同一秒」的构造参数：同值即同秒。用固定基准日期 + 秒偏移，
/// 避免测试依赖 `DateTime.now()`。
AgentFileItem _file(
  String name, {
  required int second,
  String turnId = _turnA,
  String action = 'created',
  String? mimeType = 'text/markdown',
}) => AgentFileItem(
  id: name,
  createdAt: DateTime.utc(2026, 9, 14, 0, 0, second),
  relativePath: 'out/$name',
  fileName: name,
  displayName: name,
  action: action,
  turnId: turnId,
  ufsFileId: 'ufs_$name',
  mimeType: mimeType,
);

/// 一个 TTS 语音分段（`reports/tts/**`）。
AgentFileItem _tts(
  String name, {
  required int second,
  String turnId = _turnA,
}) => AgentFileItem(
  id: name,
  createdAt: DateTime.utc(2026, 9, 14, 0, 0, second),
  relativePath: 'reports/tts/$turnId/$name',
  fileName: name,
  displayName: name,
  action: 'created',
  turnId: turnId,
  ufsFileId: 'ufs_$name',
  mimeType: 'audio/mpeg',
  ttsKind: TtsStreamKind.reply,
);

/// 非文件项（用来验证「非文件是断点」）。
ConversationItem _text(String id, {int second = 0}) => AssistantMessageItem(
  id: id,
  createdAt: DateTime.utc(2026, 9, 14, 0, 0, second),
  text: 'x',
  turnId: _turnA,
);

void main() {
  group('阈值边界（FILE_BATCH_MIN_COUNT = 5）', () {
    // 表驱动：段长 → 期望行形状。
    for (final (count, expectBatch) in [(4, false), (5, true), (6, true)]) {
      test('同秒 $count 个 → ${expectBatch ? "批量卡" : "逐条"}', () {
        final items = [
          for (var i = 0; i < count; i++) _file('f$i.md', second: 0),
        ];

        final rows = groupFileEventsForDisplay(items);

        expect(rows, hasLength(expectBatch ? 1 : count));
        if (expectBatch) {
          final row = rows.single as AgentFileBatchRow;
          expect(row.count, count);
          expect(row.verb, '生成');
        } else {
          expect(rows.every((r) => r is SingleItemRow), isTrue);
        }
      });
    }

    test('阈值常量本身是 5（三端口径一致，改动必须是有意的）', () {
      expect(FILE_BATCH_MIN_COUNT, 5);
    });
  });

  group('连续性：只聚合相邻同秒段', () {
    test('同秒 5 个 → 一张批量卡', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('f$i.md', second: 10),
      ]);
      expect(rows, hasLength(1));
      expect((rows.single as AgentFileBatchRow).count, 5);
    });

    test('同秒 3 + 同秒 3（跨秒）→ 两段都逐条（不合并成 6）', () {
      // 每段都不达阈值，故各自逐条。若实现错误地「跨秒合并」，
      // 就会得到 1 张 6 个的批量卡——正是 webapp 明确不要的行为。
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 3; i++) _file('a$i.md', second: 10),
        for (var i = 0; i < 3; i++) _file('b$i.md', second: 11),
      ]);
      expect(rows, hasLength(6));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });

    test('同秒 5 + 同秒 5（跨秒）→ 两张批量卡', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('a$i.md', second: 10),
        for (var i = 0; i < 5; i++) _file('b$i.md', second: 11),
      ]);
      expect(rows, hasLength(2));
      expect(rows.every((r) => r is AgentFileBatchRow), isTrue);
    });

    test('同秒但被跨秒段隔开（5 + 1 + 5 同秒）→ 不回溯合并', () {
      // 中间夹一个不同秒的文件：两段同秒的 5 个**不相邻**，各自成批。
      // 若实现按「秒值分组」（map 分组）而非「相邻段」，就会并成一张 10 个的卡。
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('a$i.md', second: 10),
        _file('mid.md', second: 11),
        for (var i = 0; i < 5; i++) _file('b$i.md', second: 10),
      ]);
      expect(rows, hasLength(3));
      expect((rows[0] as AgentFileBatchRow).count, 5);
      expect(rows[1], isA<SingleItemRow>());
      expect((rows[2] as AgentFileBatchRow).count, 5);
    });

    test('不同秒的相邻文件不聚合（即使总数超阈值）', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 6; i++) _file('f$i.md', second: i),
      ]);
      expect(rows, hasLength(6));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });
  });

  group('跨 turn 必须断段', () {
    test('同秒 3+3 分属两个 turn → 不聚合（turnId 是段键的一部分）', () {
      // 客户端时间线是扁平的（webapp 的已按 turn 分组，天然看不到这种相邻）。
      // 不显式把 turnId 纳入段键，这 6 个同秒文件就会连成一段 → 误聚合。
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 3; i++) _file('a$i.md', second: 10, turnId: _turnA),
        for (var i = 0; i < 3; i++) _file('b$i.md', second: 10, turnId: _turnB),
      ]);
      expect(rows, hasLength(6));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });

    test('turn A 同秒 5 个 → 批量；紧邻的 turn B 同秒 5 个 → 另一批', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('a$i.md', second: 10, turnId: _turnA),
        for (var i = 0; i < 5; i++) _file('b$i.md', second: 10, turnId: _turnB),
      ]);
      expect(rows, hasLength(2));
      expect((rows[0] as AgentFileBatchRow).count, 5);
      expect((rows[1] as AgentFileBatchRow).count, 5);
      // 两批的成员分属不同 turn（没有混进对方）。
      expect(
        (rows[0] as AgentFileBatchRow).files.every((f) => f.turnId == _turnA),
        isTrue,
      );
      expect(
        (rows[1] as AgentFileBatchRow).files.every((f) => f.turnId == _turnB),
        isTrue,
      );
    });
  });

  group('动词按批内最新态选取（含删除）', () {
    test('全 created → 生成', () {
      expect(
        agentFileBatchVerb([
          for (var i = 0; i < 5; i++) _file('f$i.md', second: 0),
        ]),
        '生成',
      );
    });

    test('含 modified（无 deleted）→ 更新', () {
      expect(
        agentFileBatchVerb([
          _file('a.md', second: 0),
          _file('b.md', second: 0, action: 'modified'),
        ]),
        '更新',
      );
    });

    test('含 deleted → 删除（否则删除批会误显示为「生成了 N 个」）', () {
      expect(
        agentFileBatchVerb([
          _file('a.md', second: 0),
          _file('b.md', second: 0, action: 'modified'),
          _file('c.md', second: 0, action: 'deleted'),
        ]),
        '删除',
      );
    });

    test('批量卡的动词取删除批（端到端）', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 4; i++) _file('f$i.md', second: 0),
        _file('gone.md', second: 0, action: 'deleted'),
      ]);
      expect(rows, hasLength(1));
      expect((rows.single as AgentFileBatchRow).verb, '删除');
    });

    test('未知 action 视为 created（不编造动词）', () {
      expect(
        agentFileBatchVerb([_file('a.md', second: 0, action: 'weird')]),
        '生成',
      );
    });
  });

  group('TTS 语音分段永不参与聚合', () {
    test('同秒 5 个 TTS → 逐条（不聚合）', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _tts('speech_${_turnA}_$i.mp3', second: 0),
      ]);
      expect(rows, hasLength(5));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });

    test('TTS 是断点：两侧的文件段各自判定，不被 TTS 串起来', () {
      // 3 个文件 + 1 个 TTS + 3 个文件（全同秒）。
      // 若 TTS 只是「被跳过」，这 6 个文件会连成一段 → 误聚合。
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 3; i++) _file('a$i.md', second: 0),
        _tts('speech_${_turnA}_1.mp3', second: 0),
        for (var i = 0; i < 3; i++) _file('b$i.md', second: 0),
      ]);
      expect(rows, hasLength(7)); // 3 + 1 + 3，全部逐条
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });

    test('TTS 数量不计入批量卡的 count', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('f$i.md', second: 0),
        _tts('speech_${_turnA}_1.mp3', second: 0),
      ]);
      expect(rows, hasLength(2));
      expect((rows[0] as AgentFileBatchRow).count, 5);
      expect(rows[1], isA<SingleItemRow>());
    });
  });

  group('非文件项是断点且原样输出', () {
    test('文本夹在文件中间 → 不合并（否则藏起中间的步骤）', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 3; i++) _file('a$i.md', second: 0),
        _text('msg_1'),
        for (var i = 0; i < 3; i++) _file('b$i.md', second: 0),
      ]);
      expect(rows, hasLength(7));
      expect((rows[3] as SingleItemRow).item.id, 'msg_1');
    });

    test('非文件项原样透传（顺序不变）', () {
      final rows = groupFileEventsForDisplay([
        _text('m1', second: 1),
        _text('m2', second: 2),
      ]);
      expect(rows.map((r) => (r as SingleItemRow).item.id), ['m1', 'm2']);
    });
  });

  group('秒键与边界情况', () {
    test('agentFileSecondOf 截断到秒（忽略毫秒）', () {
      expect(
        agentFileSecondOf(DateTime.utc(2026, 9, 14, 1, 2, 3, 456, 789)),
        '2026-09-14T01:02:03',
      );
    });

    test('同秒不同毫秒仍算同秒', () {
      // 服务端 RFC3339 带毫秒，同一秒内的毫秒差异不应切开批次。
      final a = AgentFileItem(
        id: 'a.md',
        createdAt: DateTime.utc(2026, 9, 14, 0, 0, 3, 100),
        relativePath: 'out/a.md',
        fileName: 'a.md',
        displayName: 'a.md',
        action: 'created',
        turnId: _turnA,
      );
      final b = AgentFileItem(
        id: 'b.md',
        createdAt: DateTime.utc(2026, 9, 14, 0, 0, 3, 900),
        relativePath: 'out/b.md',
        fileName: 'b.md',
        displayName: 'b.md',
        action: 'created',
        turnId: _turnA,
      );
      final rows = groupFileEventsForDisplay([
        a,
        b,
        for (var i = 0; i < 3; i++) _file('f$i.md', second: 3),
      ]);
      expect(rows, hasLength(1));
      expect((rows.single as AgentFileBatchRow).count, 5);
    });

    test('空列表 → 空结果', () {
      expect(groupFileEventsForDisplay([]), isEmpty);
    });

    test('全是非文件项 → 全部逐条（不产出批量卡）', () {
      final rows = groupFileEventsForDisplay([_text('m1'), _text('m2')]);
      expect(rows, hasLength(2));
      expect(rows.every((r) => r is SingleItemRow), isTrue);
    });
  });

  group('不改归约结果', () {
    test('批量卡成员与输入是同一批对象（未复制/未改写）', () {
      final files = [for (var i = 0; i < 5; i++) _file('f$i.md', second: 0)];
      final rows = groupFileEventsForDisplay(files);
      final batch = rows.single as AgentFileBatchRow;
      // 顺序保持输入顺序（展开后按此顺序渲染，TTS 分段顺序不丢）。
      expect(batch.files.map((f) => f.id), files.map((f) => f.id));
      expect(identical(batch.files[0], files[0]), isTrue);
    });

    test('成员列表不可变（防止渲染层就地排序改到归约数据）', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('f$i.md', second: 0),
      ]);
      final batch = rows.single as AgentFileBatchRow;
      expect(
        () => batch.files.add(_file('x.md', second: 0)),
        throwsUnsupportedError,
      );
    });
  });

  group('定位 id（locateIdsOf / locateIdsOfAll）', () {
    /// ## 这个 group 防的是什么
    ///
    /// `ConversationPage` 用它做两件事：注册定位键、**回收**已不在时间线上的
    /// 键（issue #39）。两处必须是同一份口径——若回收用的集合比注册用的
    /// 少算了一个 id，那个仍在渲染的行的 `GlobalKey` 会被删掉，`KeyedSubtree`
    /// 随之卸载重挂（丢失滚动位置，且搜索定位失效）。
    ///
    /// 最容易漏的是**批量卡的非首成员**：批内 5 个文件共用同一个定位点
    /// （它们渲染在同一张卡里），故 5 个 id 都必须算进「活着的行」。
    test('单条行 → 只含该条 id', () {
      final item = _text('m1');
      expect(locateIdsOf(SingleItemRow(item)), ['m1']);
    });

    test('批量卡 → 含批内全部成员 id（不只首成员）', () {
      final files = [for (var i = 0; i < 5; i++) _file('f$i.md', second: 0)];
      final row = groupFileEventsForDisplay(files).single;
      expect(row, isA<AgentFileBatchRow>());
      expect(locateIdsOf(row), ['f0.md', 'f1.md', 'f2.md', 'f3.md', 'f4.md']);
    });

    test('locateIdsOfAll 展平多行，含批内全部成员', () {
      final rows = groupFileEventsForDisplay([
        _text('m1'),
        for (var i = 0; i < 5; i++) _file('f$i.md', second: 0),
        _text('m2', second: 1),
      ]);
      expect(locateIdsOfAll(rows), {
        'm1',
        'f0.md',
        'f1.md',
        'f2.md',
        'f3.md',
        'f4.md',
        'm2',
      });
    });

    test('空时间线 → 空集合（页面据此回收全部旧键）', () {
      expect(locateIdsOfAll([]), isEmpty);
    });

    test('返回的集合不含重复 id', () {
      final rows = groupFileEventsForDisplay([
        for (var i = 0; i < 5; i++) _file('f$i.md', second: 0),
      ]);
      final ids = locateIdsOfAll(rows);
      expect(ids, hasLength(5));
    });
  });
}
