import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import '../support/conversation_page_harness.dart';

/// 分发进度条（`dispatch_progress.dart`，issue #114 阶段 2）。
///
/// ## 这个文件防的是什么
///
/// 进度条的三个失败形态都不会抛异常，只会「看起来正常但没信息」：
///
/// | 写错 | 后果 |
/// |---|---|
/// | 没有 500ms 门槛 | 每次发送都闪一条（p90 只有 27ms）——把真长尾也变成噪声 |
/// | 不计时 / 不计「已等待」 | 条出现后一动不动，用户分不清「在干活」与「卡住」 |
/// | 未知段名显示空串 | 服务端新增段时条变成一条空白，且没有任何测试会红 |
///
/// 判据本身（门槛、文案兜底）在 `spb_domain` 的 `dispatch_stage_test.dart` 里
/// 逐条钉住；这里验**组件行为**（计时、渲染、位置）。
void main() {
  DispatchStageProgress progress({
    DateTime? startedAt,
    String? current,
    int completed = 0,
    bool rootFinished = false,
  }) {
    final start =
        startedAt ?? DateTime.now().subtract(const Duration(seconds: 5));
    return DispatchStageProgress(
      requestId: 'rid_x',
      startedAt: start,
      updatedAt: start,
      completed: [
        for (var i = 0; i < completed; i++)
          DispatchStageSpan(
            name: 'stage$i',
            startMs: i,
            endMs: i + 1,
            status: DispatchStageStatus.ok,
          ),
      ],
      currentStage: current,
      rootStarted: true,
      rootFinished: rootFinished,
    );
  }

  Widget host(Widget child) => MaterialApp(
    theme: SpbTheme.light(),
    home: Scaffold(
      body: Column(mainAxisSize: MainAxisSize.min, children: [child]),
    ),
  );

  group('门槛（500ms）', () {
    testWidgets('未过门槛时不占位（渲染成空白）', (tester) async {
      final t0 = DateTime.utc(2026, 1, 1);
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(startedAt: t0, current: 'classify.llm'),
            clock: () => t0,
          ),
        ),
      );

      expect(find.byType(DispatchProgressBar), findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-dispatch-progress')),
        findsNothing,
        reason: '条本身不该出现在树上（否则会占位）',
      );
    });

    testWidgets('到门槛时自动出现（不依赖外部重建）', (tester) async {
      // 计时器在门槛时刻触发一次重建：条的出现由组件自己负责，页面只需把
      // 进度推进来。若依赖父层重建，短命的分发会永远不出现（父层可能整段
      // 时间没有其他 setState）。
      final t0 = DateTime.utc(2026, 1, 1);
      var now = t0;
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(startedAt: t0, current: 'classify.llm'),
            clock: () => now,
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('conversation-dispatch-progress')),
        findsNothing,
      );

      now = t0.add(const Duration(milliseconds: dispatchProgressMinVisibleMs));
      await tester.pump(
        const Duration(milliseconds: dispatchProgressMinVisibleMs),
      );

      expect(
        find.byKey(const ValueKey('conversation-dispatch-progress')),
        findsOneWidget,
      );
    });

    testWidgets('已过门槛的进度立刻可见（切对话/晚挂载的形态）', (tester) async {
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(
              startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
              current: 'router.auto_agent',
            ),
          ),
        ),
      );

      expect(
        find.text('正在匹配 Agent'),
        findsOneWidget,
        reason: 'router.auto_agent 是生产长尾 3.1s 的那一段（super_partyb#181）',
      );
    });
  });

  group('文案与读数', () {
    testWidgets('只有 root start 时显示「正在分发」而不是空串', (tester) async {
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(
              startedAt: DateTime.now().subtract(const Duration(seconds: 2)),
            ),
          ),
        ),
      );

      expect(find.text('正在分发'), findsOneWidget);
    });

    testWidgets('未知段名兜底「正在处理」（服务端新增段不能让条变空白）', (tester) async {
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(
              startedAt: DateTime.now().subtract(const Duration(seconds: 2)),
              current: 'brand_new_stage',
            ),
          ),
        ),
      );

      expect(find.text('正在处理'), findsOneWidget);
    });

    testWidgets('显示「已等待 N 秒」，并在每秒推进（这段没有正文可看）', (tester) async {
      final t0 = DateTime.utc(2026, 1, 1);
      var now = t0.add(const Duration(seconds: 3));
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(startedAt: t0, current: 'classify.prepare'),
            clock: () => now,
          ),
        ),
      );
      expect(find.text('3 秒'), findsOneWidget);

      now = t0.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('5 秒'), findsOneWidget, reason: '每秒刷一次，否则数字不动');
    });

    testWidgets('已完成的段数作为第二个「它在动」的证据', (tester) async {
      final t0 = DateTime.utc(2026, 1, 1);
      var now = t0.add(const Duration(seconds: 4));
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(startedAt: t0, current: 'enqueue', completed: 3),
            clock: () => now,
          ),
        ),
      );

      expect(find.text('4 秒 · 已过 3 步'), findsOneWidget);
      expect(find.text('正在入队'), findsOneWidget);
    });

    testWidgets('进度为 null 时不占位', (tester) async {
      await tester.pumpWidget(host(const DispatchProgressBar(progress: null)));

      expect(
        find.byKey(const ValueKey('conversation-dispatch-progress')),
        findsNothing,
      );
    });

    testWidgets('root 已收尾时即使传进来也不显示（防御性）', (tester) async {
      // 控制器在 root 收尾时会直接推 null（见 controller 用例），这里再挡一道：
      // 万一消费方自己保留了旧快照，也不该让条停在「已收尾」的状态上。
      await tester.pumpWidget(
        host(
          DispatchProgressBar(
            progress: progress(
              startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
              current: 'enqueue',
              rootFinished: true,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('conversation-dispatch-progress')),
        findsNothing,
      );
    });
  });

  group('对话页接线（位置与订阅）', () {
    setUpHarness();
    tearDownHarness();

    testWidgets('未注入时不渲染（服务端开关关着的一端零行为变化）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(tester, wireDispatchProgress: false);

      expect(find.byType(DispatchProgressBar), findsNothing);
    });

    testWidgets('有进度时出条，且条在输入框之上（更早的等待离输入框更远）', (tester) async {
      mockTimeline();
      await startController(tester);
      await pumpPage(
        tester,
        dispatchProgressSnapshotOverride: progress(
          startedAt: DateTime.now().subtract(const Duration(seconds: 4)),
          current: 'classify.llm',
        ),
      );

      expect(find.byType(DispatchProgressBar), findsOneWidget);
      expect(find.text('正在判断消息归属'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(DispatchProgressBar)).dy,
        lessThan(tester.getTopLeft(find.byType(MessageComposer)).dy),
        reason: '分发进度属于「还没开始」，必须排在输入框之上',
      );
    });

    testWidgets('流推送到达时实时更新（不等父层重建）', (tester) async {
      mockTimeline();
      await startController(tester);
      final stream = StreamController<DispatchStageProgress?>.broadcast();
      await pumpPage(tester, dispatchProgressStreamOverride: stream.stream);

      expect(find.byType(DispatchProgressBar), findsNothing);

      await tester.runAsync(() async {
        stream.add(
          progress(
            startedAt: DateTime.now().subtract(const Duration(seconds: 4)),
            current: 'enqueue',
          ),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(find.text('正在入队'), findsOneWidget);

      await tester.runAsync(() async {
        stream.add(null);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      // null 之后页面直接把组件从树上摘掉（`if (_dispatchProgress != null)`），
      // 不是留一个渲染空白的占位。
      expect(find.byType(DispatchProgressBar), findsNothing);
    });
  });
}
