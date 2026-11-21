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

  group('当前阶段与优先级', () {
    test('没有运行轮次时不显示状态', () {
      expect(
        deriveTurnStatus(
          isStreaming: false,
          isStale: true,
          executionStatus: exec(ExecutionStatusKind.queued),
        ),
        isNull,
      );
      expect(deriveTurnStatus(isStreaming: true), isNull);
    });

    test('超时压过排队和工具，不再转圈', () {
      final status = deriveTurnStatus(
        isStreaming: true,
        isStale: true,
        phase: TurnStatusKind.runningWithTools,
        executionStatus: exec(ExecutionStatusKind.queued),
      )!;
      expect(status.kind, TurnStatusKind.stalled);
      expect(status.spinner, isFalse);
      expect(status.detail, isNull);
    });

    test('排队和重试压过已有正文', () {
      for (final kind in ExecutionStatusKind.values) {
        final status = deriveTurnStatus(
          isStreaming: true,
          phase: TurnStatusKind.replying,
          executionStatus: exec(kind),
        )!;
        expect(
          status.kind,
          kind == ExecutionStatusKind.queued
              ? TurnStatusKind.queued
              : TurnStatusKind.retrying,
        );
      }
    });

    test('已调用的工具只作摘要，不证明还在执行', () {
      final status = deriveTurnStatus(
        isStreaming: true,
        toolCount: 12,
        lastToolName: 'bash',
        phase: TurnStatusKind.replying,
        activity: activity(),
      )!;
      expect(status.text, '正在回复');
      expect(status.spinner, isFalse);
      expect(status.detail, '已运行 2 秒 · 已调用 12 个工具 · 最近：bash');
    });

    test('只有工具历史时回到通用执行态', () {
      final status = deriveTurnStatus(isStreaming: true, toolCount: 3)!;
      expect(status.kind, TurnStatusKind.running);
      expect(status.text, '执行中');
    });

    test('准备阶段、空工具名与未知活动不编造内容', () {
      expect(
        deriveTurnStatus(isStreaming: true, isPreparing: true)!.text,
        '正在准备响应',
      );
      final status = deriveTurnStatus(
        isStreaming: true,
        phase: TurnStatusKind.runningWithTools,
        activeToolName: ' ',
        activity: activity(elapsedMs: -1, lastEventType: 'executor_started'),
      )!;
      expect(status.text, '正在执行工具');
      expect(status.detail, '最近：executor_started');
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

    test('已完成工具不冒充运行中的轮次', () {
      expect(streamingTurnIdOf([tool('t1'), tool('t2')]), isNull);
    });

    test('空 turnId 的流式项 → null（不拿空串当 turnId）', () {
      expect(streamingTurnIdOf([text('m1', turnId: '')]), isNull);
    });
  });

  group('从时间线派生阶段', () {
    TurnStatusSummary? status(
      List<ConversationItem> items, {
      Set<String> stale = const {},
      ExecutionStatus? execution,
    }) => deriveTurnStatusFor(
      items: items,
      turnId: streamingTurnIdOf(items),
      staleTurnIds: stale,
      executionStatus: execution,
    );

    test('思考 → 工具 → 正文，旧思考和已完成工具不覆盖新正文', () {
      final thought = ThoughtItem(
        id: 'thought',
        createdAt: DateTime.utc(2026),
        turnId: 'turn_1',
        text: '分析',
        isStreaming: true,
      );
      expect(status([thought])!.kind, TurnStatusKind.thinking);
      expect(
        status([thought, tool('t1', output: null)])!.text,
        '正在执行工具 · Read',
      );
      expect(status([thought, tool('t1')])!.text, '执行中');
      expect(status([thought, tool('t1'), text('m1')])!.text, '正在回复');
    });

    test('权威正文落地后不退回旧思考，等待终态时显示执行中', () {
      final thought = ThoughtItem(
        id: 'thought',
        createdAt: DateTime.utc(2026),
        turnId: 'turn_1',
        text: '分析',
        isStreaming: true,
      );
      expect(status([thought, text('m1', isStreaming: false)])!.text, '执行中');
    });

    test('工具可先于正文独立开始，已终结的空结果工具不再等待', () {
      expect(
        status([tool('t1', output: null)])!.kind,
        TurnStatusKind.runningWithTools,
      );
      final done = ToolCallItem(
        id: 't1',
        createdAt: DateTime.utc(2026),
        turnId: 'turn_1',
        name: 'Read',
        isComplete: true,
      );
      expect(status([done]), isNull);
    });

    test('并行工具乱序完成时仍显示尚未完成的工具', () {
      final pending = ToolCallItem(
        id: 'pending',
        createdAt: DateTime.utc(2026),
        turnId: 'turn_1',
        name: 'bash',
      );
      expect(status([pending, tool('done')])!.text, '正在执行工具 · bash');
    });

    test('超时后的工具阶段不继续转圈', () {
      final summary = status([tool('t1', output: null)], stale: {'turn_1'})!;
      expect(summary.kind, TurnStatusKind.stalled);
      expect(summary.spinner, isFalse);
    });

    test('结束后收起状态，别的轮次活动不污染当前轮次', () {
      expect(status([text('m1', isStreaming: false)]), isNull);
      final summary = deriveTurnStatusFor(
        items: [text('m1')],
        turnId: 'turn_1',
        activities: {'other': activity(turnId: 'other')},
      )!;
      expect(summary.text, '正在回复');
      expect(summary.detail, isNull);
    });

    test('详情按原顺序列出当前轮次工具，不混入上一轮', () {
      final progress = scanTurnProgress([
        tool('old', turnId: 'old'),
        tool('first'),
        tool('second'),
        text('m1'),
      ], turnId: 'turn_1');
      expect(progress.tools.map((item) => item.id), ['first', 'second']);
      expect(progress.toolCount, 2);
    });
  });

  group('统一状态栏', () {
    testWidgets('按需展开详情，多个执行中工具也只有一个转圈', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TurnStatusStrip(
              summary: const TurnStatusSummary(
                kind: TurnStatusKind.runningWithTools,
                text: '正在执行工具 · Read',
                detail: '已调用 2 个工具',
              ),
              tools: [tool('a', output: null), tool('b', output: null)],
            ),
          ),
        ),
      );
      expect(find.byType(ToolCallTile), findsNothing);
      await tester.tap(find.byTooltip('查看详情'));
      await tester.pump();
      expect(find.text('已调用 2 个工具'), findsOneWidget);
      expect(find.byType(ToolCallTile), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('收起详情'));
      await tester.pump();
      expect(find.byType(ToolCallTile), findsNothing);
    });

    for (final size in [const Size(375, 812), const Size(812, 375)]) {
      for (final brightness in Brightness.values) {
        testWidgets('窄屏/横屏大字号与减少动态效果：$size $brightness', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var cancelled = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: TurnStatusStrip(
                  summary: const TurnStatusSummary(
                    kind: TurnStatusKind.stalled,
                    text: '长时间无进展 · 可能仍在后台运行',
                    spinner: false,
                    detail: '队列：总计 12345，你的 1234',
                  ),
                  showCancel: true,
                  onCancel: () => cancelled = true,
                ),
              ),
            ),
          );
          await tester.tap(find.byTooltip('查看详情'));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          final stop = find.byKey(const ValueKey('conversation-cancel-turn'));
          expect(tester.getSize(stop).shortestSide, greaterThanOrEqualTo(48));
          await tester.tap(stop);
          expect(cancelled, isTrue);
        });
      }
    }

    testWidgets('运行中尊重减少动态效果，并保留阶段文案', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: TurnStatusStrip(
                summary: TurnStatusSummary(
                  kind: TurnStatusKind.thinking,
                  text: '思考中',
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('思考中'), findsOneWidget);
    });
  });
}
