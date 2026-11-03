import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

/// 「当前这一轮在干什么」的统一口径（`turn_status.dart`）测试。
///
/// ## 这个文件防的是什么
///
/// 同一句状态文案有三个消费点：对话页底部细条、桌面「动态」面板、
/// 移动端「动态」弹层。它们**各自**都不难写，难的是三处说同一件事。
/// 一旦判据分叉，用户就会看到「页面说还在跑、面板说已结束」——而两边
/// 各自都有测试、都绿。
///
/// 故这里逐条钉住**判据本身**（优先级、退化、边界），三个消费点只断言
/// 「它读的是这份判据」。
void main() {
  TurnActivitySnapshot activity({
    String turnId = 'turn_1',
    int elapsedMs = 2000,
    String? lastEventType,
  }) => TurnActivitySnapshot(
    turnId: turnId,
    elapsedMs: elapsedMs,
    at: DateTime.utc(2026, 1, 1),
    lastEventType: lastEventType,
  );

  ExecutionStatus exec(
    ExecutionStatusKind kind, {
    String? reason,
    int? attempt,
  }) => ExecutionStatus(
    turnId: 'turn_1',
    kind: kind,
    reason: reason,
    attempt: attempt,
    at: DateTime.utc(2026, 1, 1),
  );

  ToolCallItem tool(
    String id, {
    String turnId = 'turn_1',
    String? output = 'ok',
  }) => ToolCallItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    name: 'Read',
    turnId: turnId,
    output: output,
    isComplete: output != null,
  );

  AssistantMessageItem text(
    String id, {
    String turnId = 'turn_1',
    String body = 'x',
    bool isStreaming = true,
  }) => AssistantMessageItem(
    id: id,
    createdAt: DateTime.utc(2026, 1, 1),
    text: body,
    turnId: turnId,
    isStreaming: isStreaming,
  );

  group('deriveTurnStatus：没有进行中的轮次时不产出状态', () {
    test('isStreaming 为 false → null（不画一条「执行中」）', () {
      expect(
        deriveTurnStatus(
          isStreaming: false,
          activity: activity(),
          toolCount: 5,
        ),
        isNull,
      );
    });

    test('isStreaming 但什么派生量都没有 → null（正文在动，再加一条是噪声）', () {
      expect(deriveTurnStatus(isStreaming: true), isNull);
    });
  });

  group('deriveTurnStatus：优先级', () {
    test('stalled 压过排队、工具、活动（它是关于前几者的结论）', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        isStale: true,
        executionStatus: exec(ExecutionStatusKind.queued),
        activity: activity(),
        toolCount: 8,
        lastToolName: 'Bash',
      )!;
      expect(s.kind, TurnStatusKind.stalled);
      expect(s.text, contains('长时间无进展'));
      // 不转圈：与「无进展」自相矛盾。
      expect(s.spinner, isFalse);
    });

    test('排队 / 重试压过「已调用 N 个工具」（它们表示还没起跑）', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        executionStatus: exec(ExecutionStatusKind.retryScheduled, attempt: 3),
        toolCount: 8,
      )!;
      expect(s.kind, TurnStatusKind.retrying);
      expect(s.text, '正在安排第 3 次重试');
      expect(s.spinner, isTrue);
    });

    test('有工具调用压过活动快照，且文案是「已调用 N 个工具」+ 最近工具名', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        activity: activity(lastEventType: 'thought'),
        toolCount: 12,
        lastToolName: 'bash',
      )!;
      expect(s.kind, TurnStatusKind.runningWithTools);
      expect(s.text, '已调用 12 个工具');
      expect(s.detail, '最近：bash');
    });

    test('只有活动快照 → 保留既有「执行中 · 已运行 X」文案', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        activity: activity(elapsedMs: 125000, lastEventType: 'tool_call'),
      )!;
      expect(s.kind, TurnStatusKind.running);
      expect(s.text, '执行中 · 已运行 2 分 5 秒');
      expect(s.detail, '最近：工具调用');
    });
  });

  group('deriveTurnStatus：退化与不编造', () {
    test('工具名为空 → 不拼出「最近：null」，退化为已运行时长', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        activity: activity(elapsedMs: 3000),
        toolCount: 3,
        lastToolName: '   ',
      )!;
      expect(s.text, '已调用 3 个工具');
      expect(s.detail, '已运行 3 秒');
    });

    test('既没有工具名也没有活动 → detail 为 null（不是空串）', () {
      final s = deriveTurnStatus(isStreaming: true, toolCount: 1)!;
      expect(s.detail, isNull);
    });

    test('elapsedMs 为 0 / 负数 → 不出「已运行 0 秒」这类无信息补充', () {
      for (final ms in [0, -1]) {
        final s = deriveTurnStatus(
          isStreaming: true,
          activity: activity(elapsedMs: ms),
          toolCount: 2,
        )!;
        expect(s.text, '已调用 2 个工具');
        expect(s.detail, isNull);
      }
    });

    test('未知的 lastEventType 原样展示（不猜语义）', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        activity: activity(lastEventType: 'executor_started'),
      )!;
      expect(s.detail, '最近：executor_started');
    });

    test('lastEventType 为空串 → 无 detail', () {
      final s = deriveTurnStatus(
        isStreaming: true,
        activity: activity(lastEventType: '  '),
      )!;
      expect(s.detail, isNull);
    });
  });

  group('executionStatusLabel', () {
    test('排队原因逐条映射（与 webapp 同一批文案）', () {
      expect(
        executionStatusLabel(
          exec(ExecutionStatusKind.queued, reason: 'session_busy'),
        ),
        '正在等待当前会话完成',
      );
      expect(
        executionStatusLabel(
          exec(ExecutionStatusKind.queued, reason: 'user_concurrency_limit'),
        ),
        '正在等待用户并发额度',
      );
      expect(
        executionStatusLabel(
          exec(ExecutionStatusKind.queued, reason: 'global_concurrency_limit'),
        ),
        '正在等待执行资源',
      );
      // 未知原因 + 无原因 → 同一个兜底（不把原始 reason 当文案）。
      expect(
        executionStatusLabel(
          exec(ExecutionStatusKind.queued, reason: 'whatever'),
        ),
        '正在等待执行',
      );
      expect(executionStatusLabel(exec(ExecutionStatusKind.queued)), '正在等待执行');
    });

    test('重试分支只看 attempt（不看 reason 原文）', () {
      expect(
        executionStatusLabel(
          exec(
            ExecutionStatusKind.retryScheduled,
            attempt: 2,
            reason: '/usr/bin/bash: exit status 1\n<长日志>',
          ),
        ),
        '正在安排第 2 次重试',
      );
      // attempt 缺失 → 退化为 1（不拼出「第 null 次」）。
      expect(
        executionStatusLabel(exec(ExecutionStatusKind.retryScheduled)),
        '正在安排第 1 次重试',
      );
    });
  });

  group('formatTurnElapsed', () {
    test('小于 1 分钟只给秒', () {
      expect(formatTurnElapsed(0), '0 秒');
      expect(formatTurnElapsed(1000), '1 秒');
      expect(formatTurnElapsed(59000), '59 秒');
    });

    test('≥ 1 分钟拆成「X 分 Y 秒」，整分钟省略秒', () {
      expect(formatTurnElapsed(60000), '1 分钟');
      expect(formatTurnElapsed(125000), '2 分 5 秒');
      expect(formatTurnElapsed(3600000), '60 分钟');
    });

    test('负数按 0（服务端异常载荷不产出「已运行 -1 秒」）', () {
      expect(formatTurnElapsed(-5), '0 秒');
    });
  });

  group('scanTurnProgress', () {
    test('turnId 为 null / 空串 → none（不扫描）', () {
      var visits = 0;
      for (final id in [null, '']) {
        final p = scanTurnProgress(
          [text('m1')],
          turnId: id,
          onVisit: () => visits++,
        );
        expect(p.isRunning, isFalse);
        expect(p.toolCount, 0);
        expect(p.hasAgentContent, isFalse);
      }
      expect(visits, 0);
    });

    test('统计本 turn 的工具条数、最近工具名、是否有正文', () {
      final p = scanTurnProgress([
        text('m1', body: '正文'),
        tool('t1'),
        tool('t2'),
        ToolCallItem(
          id: 't3',
          createdAt: DateTime.utc(2026, 1, 1),
          name: 'Bash',
          turnId: 'turn_1',
          isComplete: false,
        ),
      ], turnId: 'turn_1');

      expect(p.isRunning, isTrue);
      expect(p.toolCount, 3);
      // 最近 = 时间上最后一条（倒序扫描首个命中）。
      expect(p.lastToolName, 'Bash');
      expect(p.hasAgentContent, isTrue);
    });

    test('遇到别的 turn 立即早退（不把上一轮的工具算进来）', () {
      final p = scanTurnProgress([
        tool('old1', turnId: 'turn_0'),
        tool('old2', turnId: 'turn_0'),
        tool('t1'),
      ], turnId: 'turn_1');

      expect(p.toolCount, 1);
      expect(p.lastToolName, 'Read');
    });

    test('⭐ 不能按类型早退：工具夹在正文之后仍要被数到', () {
      // 若实现里遇到 `AssistantMessageItem` 就 break，下面这轮的后两条工具
      // 会全部漏掉（而它们正是「正文已出、仍在调工具」的常见形态）。
      final p = scanTurnProgress([
        tool('t1'),
        text('m1'),
        tool('t2'),
        tool('t3'),
      ], turnId: 'turn_1');

      expect(p.toolCount, 3);
      expect(p.lastToolName, 'Read');
    });

    test('onVisit 覆盖扫描条数（页面用它喂 PerfProbe 预算）', () {
      var visits = 0;
      scanTurnProgress(
        [tool('a'), tool('b'), tool('c'), tool('d'), tool('e')],
        turnId: 'turn_1',
        onVisit: () => visits++,
      );
      expect(visits, 5);
    });

    test('空正文不算「已有 agent 内容」', () {
      final p = scanTurnProgress([text('m1', body: '')], turnId: 'turn_1');
      expect(p.hasAgentContent, isFalse);
    });
  });

  group('streamingTurnIdOf', () {
    test('取最后一个带流式标记的项（同 group 的 turn 串行执行）', () {
      expect(
        streamingTurnIdOf([
          text('m1', turnId: 'turn_1', isStreaming: false),
          text('m2', turnId: 'turn_2'),
        ]),
        'turn_2',
      );
    });

    test('思考项也算（起跑后先出思考、正文还没来）', () {
      expect(
        streamingTurnIdOf([
          ThoughtItem(
            id: 'th',
            createdAt: DateTime.utc(2026, 1, 1),
            text: '想',
            turnId: 'turn_9',
            isStreaming: true,
          ),
        ]),
        'turn_9',
      );
    });

    test('工具项不算（它没有 isStreaming），全部完成 → null', () {
      expect(streamingTurnIdOf([tool('t1'), tool('t2')]), isNull);
    });

    test('空 turnId 的流式项 → null（不拿空串当 turnId）', () {
      expect(streamingTurnIdOf([text('m1', turnId: '')]), isNull);
    });
  });

  group('deriveTurnStatusFor（面板用：自己收整份时间线）', () {
    test('没有流式项 → null', () {
      expect(deriveTurnStatusFor(items: [tool('t1')], turnId: null), isNull);
    });

    test('有工具调用 → runningWithTools，且 detail 是最近工具', () {
      final items = [
        text('m1'),
        tool('t1'),
        ToolCallItem(
          id: 't2',
          createdAt: DateTime.utc(2026, 1, 1),
          name: 'Bash',
          turnId: 'turn_1',
          isComplete: false,
        ),
      ];
      final s = deriveTurnStatusFor(
        items: items,
        turnId: streamingTurnIdOf(items),
      )!;
      expect(s.kind, TurnStatusKind.runningWithTools);
      expect(s.text, '已调用 2 个工具');
      expect(s.detail, '最近：Bash');
    });

    test('staleTurnIds 命中 → stalled（面板与页面提示条不能互相矛盾）', () {
      final items = [text('m1')];
      final s = deriveTurnStatusFor(
        items: items,
        turnId: streamingTurnIdOf(items),
        staleTurnIds: {'turn_1'},
      )!;
      expect(s.kind, TurnStatusKind.stalled);
    });

    test('默认显示活动快照（面板是集中视图，不按正文让位）', () {
      final items = [text('m1', body: '正文')];
      final s = deriveTurnStatusFor(
        items: items,
        turnId: streamingTurnIdOf(items),
        activities: {'turn_1': activity(elapsedMs: 5000)},
      )!;
      expect(s.kind, TurnStatusKind.running);
      expect(s.text, '执行中 · 已运行 5 秒');
    });

    test('showActivityWithContent: false → 已有正文时让位（对话页细条的规则）', () {
      final items = [text('m1', body: '正文')];
      final s = deriveTurnStatusFor(
        items: items,
        turnId: streamingTurnIdOf(items),
        activities: {'turn_1': activity(elapsedMs: 5000)},
        showActivityWithContent: false,
      );
      // 正文在动、没有工具、也没有排队 → 细条什么都不画（既有取舍）。
      expect(s, isNull);
    });

    test('活动快照的 turnId 与当前 turn 不一致时不误用', () {
      final items = [text('m1')];
      final s = deriveTurnStatusFor(
        items: items,
        turnId: streamingTurnIdOf(items),
        activities: {'turn_OTHER': activity(elapsedMs: 5000)},
      );
      expect(s, isNull);
    });
  });

  group('TurnStatusStrip（细条渲染）', () {
    Future<void> pumpStrip(
      WidgetTester tester,
      TurnStatusSummary summary,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TurnStatusStrip(summary: summary)),
        ),
      );
      await tester.pump();
    }

    testWidgets('主文案 + 补充项都渲染（各带稳定 key）', (tester) async {
      await pumpStrip(
        tester,
        const TurnStatusSummary(
          kind: TurnStatusKind.runningWithTools,
          text: '已调用 12 个工具',
          detail: '最近：bash',
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-status')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-turn-status-text')),
        findsOneWidget,
      );
      expect(find.text('已调用 12 个工具'), findsOneWidget);
      expect(find.text('最近：bash'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('detail 为 null → 不渲染补充项（不是空串占位）', (tester) async {
      await pumpStrip(
        tester,
        const TurnStatusSummary(kind: TurnStatusKind.running, text: '执行中'),
      );

      expect(
        find.byKey(const ValueKey('conversation-turn-status-detail')),
        findsNothing,
      );
    });

    testWidgets('spinner 为 false → 用沙漏图标而不是转圈（stalled 档）', (tester) async {
      await pumpStrip(
        tester,
        const TurnStatusSummary(
          kind: TurnStatusKind.stalled,
          text: '长时间无进展 · 可能仍在后台运行',
          spinner: false,
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_disabled_outlined), findsOneWidget);
    });
  });
}
