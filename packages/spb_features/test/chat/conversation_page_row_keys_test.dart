import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_models/spb_models.dart';

import '../support/conversation_page_harness.dart';

/// 时间线「行定位键」在**页面层**的回归测试。
///
/// ## 这个文件防的是什么（一次真实事故）
///
/// 用户报障：**「对话内容一滚动就会丢失，然后继续滚动又出现」**。
///
/// 根因不在渲染层，而在 `RowLocateRegistry.keyFor`：它把批量卡的**每个成员**
/// 都写成同一个 `GlobalKey` 实例。于是当「同一段文件被拆成多行」时，多行拿到
/// 同一个键 → Flutter 抛 `Multiple widgets used the same GlobalKey` →
/// **后出现的那几行渲染为空白**（滚走再滚回来又重建出来——与用户描述逐字吻合）。
///
/// 拆分是真实会发生的：`ChatStreamController` 的缓冲区上限 2000 条
/// （[ChatStreamController.maxBufferEvents]），从**头部**丢最旧事件，边界可能
/// 落在批量卡中间——7 个同秒文件剩 4 个，不足 `FILE_BATCH_MIN_COUNT`（5），
/// 于是退回 4 个 `SingleItemRow`。
///
/// ## 为什么必须在这里测（`row_locate_registry_test.dart` 不够）
///
/// 纯逻辑测试能钉住「拆散后各行拿到不同的键」，但钉不住**页面真的这样用它**：
/// 页面若把 `keyFor` 的结果复制一份再分发，纯逻辑测试仍全绿。这与 AGENTS.md
/// §6.21 / §6.26 / §6.33 / §6.36 同一类「绿不代表对」。
///
/// ## 为什么现在仍能构造出「批量卡被拆散」（2026-10 更新）
///
/// `ChatStreamController._trimBuffer` 已改为**按轮裁剪**（整轮丢弃，见
/// `_turnBoundaryAtOrAfter`）：边界落在两轮之间，故「切进批量卡中间」不再
/// 可能发生——它会把整张批量卡（同一轮）一次丢完。
///
/// 但拆散**仍能发生**，走的是另一条路径：缓冲区里**只有一个 turn** 时没有边界
/// 可切，`_trimBuffer` 退回逐条丢头部（并记 warn）。本用例因此把填充事件的
/// turnId 也改成 `turn_batch`，让整个缓冲区成为「一轮超长对话」，于是裁剪落回
/// 逐条路径，批量卡被切散——**这与「首屏回填了一轮超长对话」的真实场景一致**
/// （那种情况下也会发生）。
///
/// ## 为什么断言「4 张卡都渲染」而不是「没有异常」
///
/// `Multiple widgets used the same GlobalKey` 由
/// `BuildOwner._debugVerifyGlobalKeyReservation` 在 **debug** 下校验；release
/// 构建里那条校验根本不跑——用户看到的就只有空白。故断言落在**可见结果**上。
void main() {
  setUpHarness();
  tearDownHarness();
  // §6.85 的两个 release 侧观测点都是**进程级**的（计数器 / 日志环形缓冲），
  // 会跨用例累积。断言「没抱错」之前必须先清。
  setUp(() {
    PerfProbe.reset();
    SpbLog.clearRecentLogs();
  });

  testWidgets('多轮真实空 ID 增量完成后，上翻不会抢占其他回复的 GlobalKey', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    final expectedTexts = <String>[];
    final initialIds = <String>[];
    for (var turn = 0; turn < 3; turn++) {
      final turnId = 'turn-$turn';
      final text = List.generate(
        20,
        (i) => '第 $turn 轮第 $i 段：完整的长回复正文。' * 5,
      ).join('\n\n');
      expectedTexts.add(text);
      await pushEvent(
        tester,
        'start',
        sseEvent('start', id: 'start-$turn', turnId: turnId, seq: turn * 3 + 1),
      );
      // 生产的 transient 帧 ID 为空、两个序号均为 0；同段增量会先在缓冲中合并。
      for (final delta in [
        text.substring(0, text.length ~/ 2),
        text.substring(text.length ~/ 2),
      ]) {
        await pushEvent(
          tester,
          'message',
          sseEvent(
            'message',
            id: '',
            turnId: turnId,
            seq: 0,
            transient: true,
            payload: {'content': delta},
          ),
        );
        final id = controller.snapshot
            .whereType<AssistantMessageItem>()
            .last
            .id;
        if (initialIds.length == turn) {
          initialIds.add(id);
        } else {
          expect(id, initialIds[turn], reason: '合并增量后仍使用首帧身份');
        }
      }
      await pushEvent(
        tester,
        'message',
        sseEvent(
          'message',
          id: 'final-$turn',
          turnId: turnId,
          seq: turn * 3 + 2,
          payload: {'content': text},
        ),
      );
      await pushEvent(
        tester,
        'done',
        sseEvent('done', id: 'done-$turn', turnId: turnId, seq: turn * 3 + 3),
      );
      await tester.pumpAndSettle();
    }
    final replies = controller.snapshot
        .whereType<AssistantMessageItem>()
        .toList();
    expect(replies.map((item) => item.text), expectedTexts);
    expect(replies.map((item) => item.id), initialIds);
    expect(initialIds, everyElement(isNotEmpty));
    expect(initialIds.toSet(), hasLength(3));
    expect(PerfProbe.rowKeyOwnerCollisions, 0);
    expect(
      SpbLog.recentLogs.where((entry) => entry.message.contains('行主键重复')),
      isEmpty,
    );

    final list = find.byType(CustomScrollView).first;
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    final seen = <String>{};
    for (var step = 0; step < 100; step++) {
      await tester.drag(list, const Offset(0, 280));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final element in find.byType(AssistantMessageBubble).evaluate()) {
        final bubble = element.widget as AssistantMessageBubble;
        final box = element.renderObject! as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.overlaps(tester.getRect(list))) seen.add(bubble.text);
      }
      if (position.pixels == 0) break;
    }
    expect(seen, unorderedEquals(expectedTexts), reason: '必须从末尾向上实际经过每一条回复');
  });

  testWidgets('批量卡被缓冲区裁剪拆散后，每一行都渲染出来（不撞 GlobalKey）', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    mockTimeline();
    await startController(tester);
    await pumpPage(tester);

    // ── 事件编排（数字是刻意算过的，改动前先读下面说明）──────────────
    //
    // 目标：让 `_trimBuffer` 的边界**恰好切在批量卡中间**。
    //
    //   7 个同秒同 turn 的文件 → 一张 7 成员的批量卡
    //   + 1996 条 `executor_started` 填充 → 缓冲 2003 条 → 裁剪 3 条
    //     = 前 3 个文件被丢 → 剩 4 个，不足阈值 5 → 退回 4 个 `SingleItemRow`
    //
    // ⚠️ 填充事件必须与批量卡**同一个 turnId**（`turn_batch`）。按轮裁剪后
    // 有边界时不会切进任何一轮；只有当整个缓冲区属于同一轮、无边界可切时才
    // 退回逐条丢头部——那正是本用例要覆盖的降级路径。若给填充事件各不相同的
    // turnId，边界会落在批量卡之后，整张卡被一次丢完（实测：`AgentFileCard`
    // 数量为 0，本用例的前提断言先红）。
    //
    // 填充事件用 `executor_started` 而不是消息：它是**诊断事件**
    // （`EventTypes.diagnostic`），进缓冲区但既不产生对话项、也不产出
    // executionStatus（那会让页面显示带转圈的「排队中」条，`pumpAndSettle`
    // 永远等不到静止）。故裁剪逻辑与真实场景一致，而渲染树只有 4 行——
    // 本用例从 ~21s 降到毫秒级。别换成 user_message：那会让时间线真的有
    // 2000 行，`pumpAndSettle` 要十几秒。
    const batchSize = 7;
    const batchCut = 3; // 裁剪吃掉前 3 个文件
    // 总条数必须是 2003（= 上限 2000 + 3），差一条就不是「切进批里第 3 个」。
    const filler = 1996;

    var seq = 0;
    final batchEvents = <(String, Map<String, dynamic>)>[
      for (var f = 0; f < batchSize; f++)
        (
          EventTypes.agentFileCreated,
          {
            ...sseEvent(
              'agent.file.created',
              id: 'f$f',
              turnId: 'turn_batch',
              seq: ++seq,
            ),
            'payload': {
              'relative_path': 'out/batch_$f.md',
              'ufs_file_id': 'ufs_batch_$f',
            },
          },
        ),
    ];
    final fillerEvents = <(String, Map<String, dynamic>)>[
      for (var i = 0; i < filler; i++)
        (
          EventTypes.executorStarted,
          sseEvent(
            'executor_started',
            id: 'x$i',
            // 与批量卡同 turn（见文件头「为什么现在仍能构造出批量卡被拆散」）。
            turnId: 'turn_batch',
            seq: ++seq,
          ),
        ),
    ];

    // 归约被合并到一个零延迟 `Timer`（issue #44），且该 Timer 落在**真实**
    // 时区（见 `pushEvent` 的文档），故必须在 `runAsync` 里推 + 多等几个真实
    // 轮次。
    Future<void> pushAll(List<(String, Map<String, dynamic>)> batch) =>
        tester.runAsync(() async {
          for (final e in batch) {
            sse.push(e.$1, e.$2);
          }
          for (var i = 0; i < 8; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        });

    // ── 关键：**分两阶段推，中间必须真正渲染一次** ────────────────────
    //
    // 缺陷只在「页面已经为批量卡建好键、随后该卡被拆散」时才会触发。若把
    // 2003 条一次推完再 pump，页面第一次构建时看到的**已经**是 4 个落单行
    // （`keyFor` 从头到尾只收到单元素 ids），撞键根本不会发生——本用例会在
    // 修复前的代码上变绿（实测踩过）。
    await pushAll(batchEvents);
    await tester.pumpAndSettle();
    expect(
      groupFileEventsForDisplay(controller.snapshot)
          .whereType<AgentFileBatchRow>(),
      hasLength(1),
      reason: '阶段 1 必须先渲染出一张 7 成员的批量卡',
    );

    await pushAll(fillerEvents);
    await tester.pumpAndSettle();

    // ── 前置断言：确认裁剪真的把批量卡拆散了 ──────────────────────────
    //
    // 不确认这一点，用例会在「根本没拆散」的状态下变绿——那正是修复前纯逻辑
    // 测试抓不到本缺陷的原因（它自己构造拆分状态）。
    expect(
      controller.bufferedEventCount,
      ChatStreamController.maxBufferEvents,
      reason: '缓冲区应已触顶并裁剪',
    );
    final rows = groupFileEventsForDisplay(controller.snapshot);
    expect(
      rows
          .whereType<SingleItemRow>()
          .map((r) => r.item)
          .whereType<AgentFileItem>()
          .map((f) => f.id),
      [for (var f = batchCut; f < batchSize; f++) 'out/batch_$f.md'],
      reason: '裁剪边界应恰好切进批量卡，剩下的文件退回逐条渲染',
    );
    expect(
      rows.whereType<AgentFileBatchRow>(),
      isEmpty,
      reason: '不足阈值（$FILE_BATCH_MIN_COUNT）后不应再有批量卡',
    );

    // ── 断言：滚到顶部，每一行都必须真的渲染出来 ──────────────────────
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();

    // 修复前：只有首个文件那一行渲染出来，其余 3 行是空白。
    expect(
      tester.takeException(),
      isNull,
      reason: '不应有 Multiple widgets used the same GlobalKey',
    );
    expect(
      find.byType(AgentFileCard),
      findsNWidgets(batchSize - batchCut),
      reason: '4 个落单文件必须各自渲染出一张卡（修复前只有 1 张）',
    );
    for (var f = batchCut; f < batchSize; f++) {
      expect(
        find.textContaining('batch_$f.md'),
        findsOneWidget,
        reason: 'out/batch_$f.md 的行必须是可见内容，不能是空白',
      );
    }

    // ── §6.85 的 release 侧自检：本场景**不应**报「行主键重复」 ─────
    //
    // 批卡被拆成 4 行后，它们的主键是各自的文件 id（f3..f6），互不相同。
    // 若这个自检误报，用户报障时就会把「撞键」当成病因，反向误导。
    expect(PerfProbe.rowKeyOwnerCollisions, 0, reason: '每行主键独立（拆散后不再共享键实例）');
    expect(
      SpbLog.recentLogs.where((r) => r.message.contains('行主键重复')),
      isEmpty,
      reason: '正常行集合不得触发主键重复 warn',
    );
  });
}
