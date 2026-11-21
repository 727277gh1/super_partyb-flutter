import 'package:spb_domain/spb_domain.dart';
import 'package:test/test.dart';

/// 时间线「数据面」快照的值对象（`TimelineDiagnostics` / `TimelineProbe`）。
///
/// ## 这个测试防的是什么
///
/// 这份快照是**报障时唯一的数字证据**：用户只能说「回复少了一大块」，而它要
/// 回答「少的那段到底进没进归约结果」。故两件事必须钉住：
///
/// 1. 字段口径（`assistant_chars` 只算助手正文、逐轮按字符数降序）；
/// 2. 报告小节**只输出数字与 id**——它会被贴进公开 issue，正文一个字都不能进。
void main() {
  TimelineDiagnostics sample({
    List<TurnTextStat>? turns,
    int? oldest,
    int replaceDropped = 0,
    int? replaceBefore,
    int? replaceAfter,
  }) => TimelineDiagnostics(
    groupId: 'grp_1',
    bufferedEvents: 2000,
    maxBufferEvents: 2000,
    itemCount: 42,
    assistantChars: 9000,
    turns:
        turns ??
        const [
          TurnTextStat(
            turnId: 'turn_long',
            chars: 8000,
            items: 2,
            isStreaming: false,
          ),
          TurnTextStat(
            turnId: 'turn_short',
            chars: 1000,
            items: 1,
            isStreaming: true,
          ),
        ],
    oldestLoadedGlobalSeq: oldest,
    newestBufferedGlobalSeq: 12345,
    trimCount: 3,
    lastTrimDropped: 137,
    lastTrimKept: 1900,
    lastTrimPerTurn: true,
    fromCache: false,
    replayGapRepairs: 1,
    sseCursorPresent: true,
    lastReplaceDropped: replaceDropped,
    lastReplaceOldestBefore: replaceBefore,
    lastReplaceOldestAfter: replaceAfter,
  );

  group('toLogFields：日志字段口径', () {
    test('关键词名齐全且是 snake_case（与 Go 的 slog 约定一致）', () {
      final fields = sample().toLogFields();

      // 这些键是报告契约：报障时人工比对客户端/服务端日志靠它。
      expect(
        fields.keys,
        containsAll([
          'group_id',
          'buffered_events',
          'max_buffer_events',
          'items',
          'assistant_chars',
          'turn_count',
          'oldest_loaded_global_seq',
          'newest_buffered_global_seq',
          'trim_count',
          'last_trim_dropped',
          'last_trim_kept',
          'last_trim_per_turn',
          'from_cache',
          'replay_gap_repairs',
          'sse_cursor_present',
          // §6.85：整段替换的丢弃量（「中途丢块、滚动才回来」的唯一数字证据）
          'last_replace_dropped_older',
          'last_replace_oldest_before',
          'last_replace_oldest_after',
        ]),
      );
      expect(fields['buffered_events'], 2000);
      expect(fields['assistant_chars'], 9000);
      expect(fields['turn_count'], 2);
      // 最长的那轮单独给出来：一眼看出「那条长回复还在不在」。
      expect(fields['longest_turn_chars'], 8000);
      expect(fields['longest_turn_id'], 'turn_long');
    });

    test('没有正文轮次时不出 longest_* 键（而不是给 0）', () {
      // 0 会被读成「最长的那轮是 0 字符」，与「根本没有正文」是两件事。
      final fields = sample(turns: const []).toLogFields();

      expect(fields.containsKey('longest_turn_chars'), isFalse);
      expect(fields.containsKey('longest_turn_id'), isFalse);
      expect(fields['turn_count'], 0);
    });

    test('globalSeq 区间为 null 时原样保留 null（不写成 0）', () {
      // 0 是一个合法的 globalSeq 值（虽然服务端不用），写成 0 会让报告看起来
      // 像「本地覆盖到 0 号事件」。
      final fields = sample(oldest: null).toLogFields();

      expect(fields['oldest_loaded_global_seq'], isNull);
      expect(fields['newest_buffered_global_seq'], 12345);
    });
  });

  group('toReportLines：报告小节', () {
    test('含缓冲/对话项/覆盖区间/裁剪/修复/逐轮明细', () {
      final lines = sample().toReportLines().join('\n');

      expect(lines, contains('缓冲事件: 2000 / 2000'));
      expect(lines, contains('对话项: 42'));
      expect(lines, contains('9000 字符'));
      expect(lines, contains('globalSeq ? .. 12345'));
      expect(lines, contains('裁剪: 共 3 次'));
      expect(lines, contains('回放缺口修复: 1 次'));
      expect(lines, contains('turn_long: 8000 字符 / 2 段'));
      expect(lines, contains('turn_short: 1000 字符 / 1 段（流式中）'));
    });

    test('逐轮明细按上限截断，并如实说明还有多少未列出', () {
      final many = [
        for (var i = 0; i < 12; i++)
          TurnTextStat(
            turnId: 't$i',
            chars: 100 - i,
            items: 1,
            isStreaming: false,
          ),
      ];

      final lines = sample(turns: many).toReportLines(turnLimit: 3);

      expect(lines.where((l) => l.startsWith('  - ')).length, 3);
      expect(lines.join('\n'), contains('… 另有 9 轮未列出'));
      expect(lines.join('\n'), contains('最多 3 轮'));
    });

    test('没有正文轮次时写「（空）」而不是留一个空小节', () {
      final lines = sample(turns: const []).toReportLines();

      expect(lines, contains('逐轮正文: （空）'));
    });

    test('全局模式（groupId 为 null）写明「全局模式」而不是空串', () {
      const d = TimelineDiagnostics(
        groupId: null,
        bufferedEvents: 0,
        maxBufferEvents: 2000,
        itemCount: 0,
        assistantChars: 0,
        turns: [],
        oldestLoadedGlobalSeq: null,
        newestBufferedGlobalSeq: null,
        trimCount: 0,
        lastTrimDropped: 0,
        lastTrimKept: 0,
        lastTrimPerTurn: true,
        fromCache: false,
        replayGapRepairs: 0,
        sseCursorPresent: false,
      );

      expect(d.toReportLines().join('\n'), contains('group_id: (全局模式)'));
    });

    group('整段替换那条读数（§6.85）', () {
      /// ## 这个 group 防的是什么
      ///
      /// 「对话中途丢块、滚动才回来」的成因之一，是缺口修复把缓冲整段换成
      /// 最新一页、顺带扔掉已翻页的更早历史。而它的报告行有三种情形，**写混
      /// 了就会被误读成「没发生」**：
      ///
      /// | 情形 | 正确措辞 | 误写的后果 |
      /// |---|---|---|
      /// | 没触发过缺口修复 | 无（未触发缺口修复） | — |
      /// | 触发过但没丢东西 | 最近一次未丢弃已加载历史 | 写成「无」会让人以为探测没跑 |
      /// | 丢了 | 丢 N 条 + 翻页下界 A → B | 不写区间就不知道「滚到顶能不能拉回来」 |
      test('没触发过缺口修复 → 说明未触发（不是笼统的「无」）', () {
        final lines = const TimelineDiagnostics(
          groupId: 'grp_1',
          bufferedEvents: 200,
          maxBufferEvents: 2000,
          itemCount: 10,
          assistantChars: 100,
          turns: [],
          oldestLoadedGlobalSeq: 900,
          newestBufferedGlobalSeq: 1000,
          trimCount: 0,
          lastTrimDropped: 0,
          lastTrimKept: 0,
          lastTrimPerTurn: true,
          fromCache: false,
          replayGapRepairs: 0,
          sseCursorPresent: false,
        ).toReportLines().join('\n');

        expect(lines, contains('整段替换: 无（未触发缺口修复）'));
      });

      test('触发过但没丢已加载历史 → 明确写「未丢弃」（不能写「无」）', () {
        final lines = sample().toReportLines().join('\n');

        expect(lines, contains('整段替换: 最近一次未丢弃已加载历史'));
      });

      test('丢弃已加载历史 → 写清条数与翻页下界的变化（滚动可拉回）', () {
        final lines = sample(
          replaceDropped: 21,
          replaceBefore: 100,
          replaceAfter: 900,
        ).toReportLines().join('\n');

        expect(
          lines,
          contains('整段替换: 最近一次丢弃已加载历史 21 条（翻页下界 100 → 900，须重新向上翻页才能取回）'),
        );
      });

      test('下界缺失时不伪造数字（用 ? 占位）', () {
        // 首次加载就触发替换、或服务端事件没有 globalSeq 时，下界可能是 null。
        // 写成 0 会让报告看起来像「覆盖到 0 号事件」。
        final lines = sample(
          replaceDropped: 5,
          replaceBefore: null,
          replaceAfter: null,
        ).toReportLines().join('\n');

        expect(lines, contains('翻页下界 ? → ?'));
      });
    });
  });

  group('TimelineProbe：进程内最近一份快照', () {
    tearDown(TimelineProbe.reset);

    test('未采集时为 null，record 之后可读，reset 后回到 null', () {
      TimelineProbe.reset();
      expect(TimelineProbe.latest, isNull);

      TimelineProbe.record(sample());
      expect(TimelineProbe.latest?.assistantChars, 9000);

      TimelineProbe.reset();
      expect(TimelineProbe.latest, isNull);
    });

    test('后写覆盖先写（只保留最近一份，不累积）', () {
      TimelineProbe.record(sample());
      TimelineProbe.record(sample(turns: const []));

      expect(TimelineProbe.latest?.turns, isEmpty);
    });
  });
}
