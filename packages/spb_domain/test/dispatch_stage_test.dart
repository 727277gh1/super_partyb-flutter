import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `dispatch_stage` 归约（[DispatchStageTracker] / [DispatchStageProgress]）的测试。
///
/// ## 这组用例守的是什么
///
/// 服务端把「一段开始」与「一段结束」拆成**两条帧**（super_partyb#181），所以
/// 「现在在做什么」不是读某一条帧就能得到的结论，而是**配对的结果**。
/// 配对有四条容易写错的边：
///
/// | 边 | 写错的后果 |
/// |---|---|
/// | 同名段可重复（编码重试） | 旧 `start` 不收尾 → 「当前段」永远停在一个不存在的段上 |
/// | `end` 可能早于 / 缺失对应的 `start` | 整条进度卡住或抛异常 |
/// | root 帧（`name=dispatch`）与子段共用同一套 start/end 逻辑 | root `start` 把当前段顶成「正在分发」，root `end` 又提前清空 |
/// | 并发段（`reminder.prepare/<n>`）`start`/`end` 顺序可不同 | 进度条来回跳 |
///
/// 这些全部在纯 Dart 里可测（无 Flutter 引擎），故本文件不需要 `flutter_test`。
void main() {
  final t0 = DateTime.utc(2026, 11, 16, 12);

  /// 构造一条 `dispatch_stage` 事件（键名照抄 Go 侧 payload）。
  ChatEvent event({
    required String name,
    required String phase,
    String requestId = 'rid_1',
    int startMs = 0,
    int? endMs,
    int? budgetMs,
    String? status,
    String? reason,
    int? elapsedMs,
    int? unattributedMs,
    String? critical,
    int? dropped,
    DateTime? createdAt,
  }) => ChatEvent.fromJson({
    'eventId': 'evt_${name}_$phase',
    'eventType': EventTypes.dispatchStage,
    'userId': 'usr_1',
    'groupId': '',
    'turnId': '',
    'seq': 0,
    'source': 'system',
    'createdAt': (createdAt ?? t0).toIso8601String(),
    'transient': true,
    'payload': <String, dynamic>{
      'request_id': requestId,
      'name': name,
      'phase': phase,
      'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      if (budgetMs != null) 'budget_ms': budgetMs,
      if (status != null) 'status': status,
      if (reason != null) 'reason': reason,
      if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      if (unattributedMs != null) 'unattributed_ms': unattributedMs,
      if (critical != null) 'critical': critical,
      if (dropped != null) 'dropped': dropped,
    },
  });

  group('DispatchStageFrame.fromEvent', () {
    test('start 帧归一（无非本阶段键）', () {
      final frame = DispatchStageFrame.fromEvent(
        event(
          name: 'classify.llm',
          phase: 'start',
          startMs: 120,
          budgetMs: 20000,
        ),
      );

      expect(frame, isNotNull);
      expect(frame!.requestId, 'rid_1');
      expect(frame.name, 'classify.llm');
      expect(frame.phase, DispatchPhase.start);
      expect(frame.startMs, 120);
      expect(frame.budgetMs, 20000);
      expect(frame.endMs, isNull);
      expect(frame.status, DispatchStageStatus.unknown);
      expect(frame.isRoot, isFalse);
    });

    test('end 帧归一（含终态与原因）', () {
      final frame = DispatchStageFrame.fromEvent(
        event(
          name: 'classify.gate',
          phase: 'end',
          startMs: 100,
          endMs: 101,
          status: 'skip',
          reason: 'budget_low',
        ),
      );

      expect(frame!.phase, DispatchPhase.end);
      expect(frame.endMs, 101);
      expect(frame.status, DispatchStageStatus.skip);
      expect(frame.reason, 'budget_low');
    });

    test('root 帧按 name 识别（不是靠 phase 或额外字段）', () {
      final frame = DispatchStageFrame.fromEvent(
        event(
          name: dispatchRootStageName,
          phase: 'end',
          elapsedMs: 3711,
          unattributedMs: 3147,
          critical: 'router.query_encode',
        ),
      );

      expect(frame!.isRoot, isTrue);
      expect(frame.elapsedMs, 3711);
      expect(frame.unattributedMs, 3147);
      expect(frame.criticalStage, 'router.query_encode');
    });

    test('四种不可用帧一律丢弃（不抛）', () {
      // 1) 非 dispatch_stage
      expect(
        DispatchStageFrame.fromEvent(
          ChatEvent.fromJson({
            'eventId': 'e1',
            'eventType': EventTypes.toolCall,
            'createdAt': t0.toIso8601String(),
            'payload': <String, dynamic>{'name': 'bash', 'phase': 'start'},
          }),
        ),
        isNull,
      );
      // 2) 缺 request_id（无法归因，挂到空键会污染别的请求）
      expect(
        DispatchStageFrame.fromEvent(
          ChatEvent.fromJson({
            'eventId': 'e2',
            'eventType': EventTypes.dispatchStage,
            'createdAt': t0.toIso8601String(),
            'payload': <String, dynamic>{'name': 'enqueue', 'phase': 'start'},
          }),
        ),
        isNull,
      );
      // 3) 缺 name（无法配对）
      expect(
        DispatchStageFrame.fromEvent(
          ChatEvent.fromJson({
            'eventId': 'e3',
            'eventType': EventTypes.dispatchStage,
            'createdAt': t0.toIso8601String(),
            'payload': <String, dynamic>{
              'request_id': 'rid_1',
              'phase': 'start',
            },
          }),
        ),
        isNull,
      );
      // 4) 未知 phase（宁可少一条进度，也不要错配 start/end）
      expect(
        DispatchStageFrame.fromEvent(event(name: 'enqueue', phase: 'tick')),
        isNull,
      );
    });
  });

  group('配对', () {
    test('start → end 合成一个 span，并清空当前段', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(
          name: 'classify.llm',
          phase: 'start',
          startMs: 120,
          budgetMs: 20000,
        ),
      );

      var progress = tracker.progressFor('rid_1');
      expect(progress, isNotNull);
      expect(progress!.currentStage, 'classify.llm');
      expect(progress.currentLabel, '正在判断消息归属');
      expect(progress.currentBudgetMs, 20000);
      expect(progress.completedCount, 0);
      expect(progress.hasProgress, isTrue);

      tracker.applyEvent(
        event(
          name: 'classify.llm',
          phase: 'end',
          startMs: 120,
          endMs: 14700,
          status: 'ok',
        ),
      );

      progress = tracker.progressFor('rid_1')!;
      expect(progress.currentStage, isNull);
      expect(progress.completedCount, 1);
      final span = progress.completed.single;
      expect(span.name, 'classify.llm');
      expect(span.startMs, 120);
      expect(span.endMs, 14700);
      expect(span.elapsedMs, 14580);
      expect(span.status, DispatchStageStatus.ok);
      expect(span.orphan, isFalse);
      // 已有完成段仍算「有进度」，UI 该继续展示（只是不再有「正在做 X」）。
      expect(progress.hasProgress, isTrue);
      expect(progress.currentLabel, isNull);
    });

    test('两个并发段：当前段取「最后开始」的那条', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: 'reminder.prepare', phase: 'start', startMs: 10),
      );
      tracker.applyEvent(
        event(
          name: 'reminder.prepare/follow_up_suggest',
          phase: 'start',
          startMs: 20,
        ),
      );

      expect(
        tracker.progressFor('rid_1')!.currentStage,
        'reminder.prepare/follow_up_suggest',
      );

      // 先 IOC 结束的是「后开始」的那条：当前段回到还在跑的那条。
      tracker.applyEvent(
        event(
          name: 'reminder.prepare/follow_up_suggest',
          phase: 'end',
          startMs: 20,
          endMs: 30,
          status: 'ok',
        ),
      );
      expect(tracker.progressFor('rid_1')!.currentStage, 'reminder.prepare');

      tracker.applyEvent(
        event(
          name: 'reminder.prepare',
          phase: 'end',
          startMs: 10,
          endMs: 40,
          status: 'ok',
        ),
      );
      expect(tracker.progressFor('rid_1')!.currentStage, isNull);
    });

    test('同名段重试：后到的 start 覆盖旧起点，只产出一个 span', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: 'embedding.encode', phase: 'start', startMs: 30),
      );
      // 重试：服务端不会再给旧起点发 end。
      tracker.applyEvent(
        event(name: 'embedding.encode', phase: 'start', startMs: 31),
      );
      tracker.applyEvent(
        event(
          name: 'embedding.encode',
          phase: 'end',
          startMs: 31,
          endMs: 79,
          status: 'ok',
        ),
      );

      final progress = tracker.progressFor('rid_1')!;
      expect(progress.currentStage, isNull);
      expect(progress.completedCount, 1);
      // 用**新**起点配对（旧起点已放弃）
      expect(progress.completed.single.startMs, 31);
    });

    test('迟到 / 丢了 start 的 end：仍记录为 orphan，但不改当前段', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: 'router.query_encode', phase: 'start', startMs: 0),
      );
      // 一个没有 start 的段结束了（例如订阅建立前它就已开始）
      tracker.applyEvent(
        event(
          name: 'classify.prepare',
          phase: 'end',
          startMs: 5,
          endMs: 40,
          status: 'ok',
        ),
      );

      final progress = tracker.progressFor('rid_1')!;
      expect(progress.currentStage, 'router.query_encode');
      expect(progress.completedCount, 1);
      expect(progress.completed.single.orphan, isTrue);
      expect(progress.completed.single.elapsedMs, 35);
    });
  });

  group('root 帧是信封，不是一步', () {
    test('root start 不把当前段顶成「正在分发」', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: dispatchRootStageName, phase: 'start', budgetMs: 20000),
      );

      final progress = tracker.progressFor('rid_1')!;
      expect(progress.currentStage, isNull);
      expect(progress.rootStarted, isTrue);
      expect(progress.rootBudgetMs, 20000);
      // 只有信封、没有子段 → 还没有可展示的进度。
      expect(progress.hasProgress, isFalse);
    });

    test('root end 只填汇总，不清空正在跑的段', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: 'router.query_encode', phase: 'start', startMs: 0),
      );
      tracker.applyEvent(
        event(
          name: dispatchRootStageName,
          phase: 'end',
          endMs: 3711,
          elapsedMs: 3711,
          unattributedMs: 3147,
          critical: 'router.query_encode',
          status: 'ok',
          dropped: 0,
        ),
      );

      final progress = tracker.progressFor('rid_1')!;
      expect(progress.rootFinished, isTrue);
      expect(progress.rootElapsedMs, 3711);
      expect(progress.rootUnattributedMs, 3147);
      expect(progress.rootCriticalStage, 'router.query_encode');
      expect(progress.rootDropped, 0);
      // 信封到得早（ssE 顺序上 root end 在 user_message 之后，但可能先于
      // 子段的 end）：当前段必须仍在。
      expect(progress.currentStage, 'router.query_encode');
      expect(progress.completedCount, 0);
    });

    test('未归因提示只在 ≥1s 时出现（3147ms → 「其中 3.1 秒未归类」）', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(name: dispatchRootStageName, phase: 'end', unattributedMs: 3147),
      );
      expect(tracker.progressFor('rid_1')!.unattributedNotice, '其中 3.1 秒未归类');

      final small = DispatchStageTracker();
      small.applyEvent(
        event(name: dispatchRootStageName, phase: 'end', unattributedMs: 999),
      );
      expect(small.progressFor('rid_1')!.unattributedNotice, isNull);

      final none = DispatchStageTracker();
      none.applyEvent(event(name: dispatchRootStageName, phase: 'end'));
      expect(none.progressFor('rid_1')!.unattributedNotice, isNull);
    });
  });

  group('生命周期', () {
    test('不同 request_id 互不干扰（归因靠 rid，不靠 group / turn）', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(requestId: 'rid_a', name: 'enqueue', phase: 'start'),
      );
      tracker.applyEvent(
        event(requestId: 'rid_b', name: 'classify.llm', phase: 'start'),
      );

      expect(tracker.progressFor('rid_a')!.currentStage, 'enqueue');
      expect(tracker.progressFor('rid_b')!.currentStage, 'classify.llm');
      expect(tracker.requestIds, containsAll(<String>['rid_a', 'rid_b']));
    });

    test('forget / clear 丢弃状态', () {
      final tracker = DispatchStageTracker();
      tracker.applyEvent(
        event(requestId: 'rid_a', name: 'enqueue', phase: 'start'),
      );
      tracker.forget('rid_a');
      expect(tracker.progressFor('rid_a'), isNull);

      tracker.applyEvent(
        event(requestId: 'rid_b', name: 'enqueue', phase: 'start'),
      );
      tracker.clear();
      expect(tracker.progressFor('rid_b'), isNull);
      expect(tracker.requestIds, isEmpty);
    });

    test('超过 maxSessions 时淘汰最久未更新的会话（root 收尾帧丢失也不会泄漏）', () {
      final tracker = DispatchStageTracker(maxSessions: 2);
      tracker.applyEvent(
        event(
          requestId: 'rid_old',
          name: 'enqueue',
          phase: 'start',
          createdAt: t0,
        ),
      );
      tracker.applyEvent(
        event(
          requestId: 'rid_mid',
          name: 'enqueue',
          phase: 'start',
          createdAt: t0.add(const Duration(seconds: 1)),
        ),
      );
      tracker.applyEvent(
        event(
          requestId: 'rid_new',
          name: 'enqueue',
          phase: 'start',
          createdAt: t0.add(const Duration(seconds: 2)),
        ),
      );

      expect(tracker.progressFor('rid_old'), isNull);
      expect(tracker.progressFor('rid_mid'), isNotNull);
      expect(tracker.progressFor('rid_new'), isNotNull);
    });
  });

  group('段名文案（闭集 + 兜底）', () {
    test('闭集内的段名有中文文案', () {
      expect(DispatchStageLabels.labelFor('classify.prepare'), '正在检索候选对话');
      expect(DispatchStageLabels.labelFor('classify.llm'), '正在判断消息归属');
      expect(DispatchStageLabels.labelFor('enqueue'), '正在入队');
      expect(DispatchStageLabels.labelFor(dispatchRootStageName), '正在分发');
    });

    test('父子路径取叶子名（比父名更贴近此刻在等的事）', () {
      expect(
        DispatchStageLabels.labelFor('router.query_encode/embedding.encode'),
        '正在向量编码',
      );
    });

    test('不可穷举的 reminder 子段按前缀归类', () {
      expect(
        DispatchStageLabels.labelFor('reminder.prepare/follow_up_suggest'),
        '正在准备提醒',
      );
      expect(
        DispatchStageLabels.labelFor('reminder.prepare/agent_recommend'),
        DispatchStageLabels.labelFor('reminder.prepare'),
      );
    });

    test('未知 / 空段名兜底（服务端新增段不能让 UI 空转）', () {
      expect(DispatchStageLabels.labelFor('brand_new_stage'), '正在处理');
      expect(DispatchStageLabels.labelFor(''), '正在处理');
      expect(DispatchStageLabels.labelFor(null), '正在处理');
      expect(DispatchStageLabels.knownStages, isNotEmpty);
    });
  });
}
