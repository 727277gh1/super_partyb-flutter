import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// `dispatch_stage`（首 token 之前的分发进度）的**契约测试**。
///
/// ## 为什么这组断言值得单独一个文件
///
/// 这条事件有三个别处没有的性质，每一个都只能靠测试钉住：
///
/// 1. **payload 有两种形态**（`phase=start` / `phase=end`，root 收尾还多四个键）。
///    访问器在缺失时**必须给 null 而不是猜**——猜错会把「未开始的段」当成
///    「已结束」，UI 上是「进度条提前收起」这种难复现的怪状。
/// 2. **它没有 turn、没有 group**（分发发生在建 turn、定 group 之前），归因只能
///    靠 `request_id`。若访问器把别的事件的同名字段读出来，归因就会串。
/// 3. **`name` / `status` / `reason` / `request_id` 都是极通用的键名**，所以每个
///    访问器都做了 `eventType` 门禁；门禁失效的后果是「任何带同名键的事件都被
///    误读成分发进度」——下面有一组专门守这条。
///
/// 帧形状真源：`super_partyb` 的 `cmd/server/main.go` 的 `StageFunc` /
/// `SummaryFunc` 闭包（super_partyb#181）。
void main() {
  /// 构造一条 `dispatch_stage` 事件（键名照抄 Go side 的 snake_case payload）。
  ///
  /// `payload` 里刻意用「只在传了参数才放键」的写法：缺键路径（例如
  /// `phase=start` 没有 `end_ms`）才是访问器的主要风险面。
  ChatEvent dispatchEvent({
    String eventId = 'evt_1',
    String eventType = EventTypes.dispatchStage,
    String? requestId,
    String? name,
    String? phase,
    int? startMs,
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
    'eventId': eventId,
    'eventType': eventType,
    'userId': 'usr_1',
    // 分发帧**没有** turn / group：这两项恒为空串是契约的一部分，不是缺数据。
    'groupId': '',
    'turnId': '',
    'seq': 0,
    'source': 'system',
    'createdAt': (createdAt ?? DateTime.utc(2026, 11, 16, 12))
        .toIso8601String(),
    'transient': true,
    'payload': <String, dynamic>{
      if (requestId != null) 'request_id': requestId,
      if (name != null) 'name': name,
      if (phase != null) 'phase': phase,
      if (startMs != null) 'start_ms': startMs,
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

  group('事件类型登记', () {
    test('dispatch_stage 已登记为已知类型（否则每帧都落一条「未知事件」日志）', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'enqueue',
        phase: 'start',
      );
      expect(ev.isKnown, isTrue);
    });

    test('不进时间线、也不是流式增量', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'enqueue',
        phase: 'start',
      );
      expect(ev.isTimelineVisible, isFalse);
      expect(ev.isIncremental, isFalse);
      expect(ev.isAuthoritativeFrame, isFalse);
      expect(
        EventTypes.timelineVisible,
        isNot(contains(EventTypes.dispatchStage)),
      );
      expect(
        EventTypes.streamIncremental,
        isNot(contains(EventTypes.dispatchStage)),
      );
    });
  });

  group('段开始帧（phase=start）', () {
    test('归因键 / 段名 / 开始偏移 / 预算都能读出来', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'classify.llm',
        phase: 'start',
        startMs: 120,
        budgetMs: 20000,
      );

      expect(ev.dispatchRequestId, 'rid_1');
      expect(ev.dispatchStageName, 'classify.llm');
      expect(ev.dispatchPhase, 'start');
      expect(ev.dispatchStartMs, 120);
      expect(ev.dispatchBudgetMs, 20000);
    });

    test('结束键与终态键在开始帧上必须是 null（不是 0 / 不是空串）', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'classify.llm',
        phase: 'start',
        startMs: 120,
      );

      expect(ev.dispatchEndMs, isNull);
      expect(ev.dispatchStatus, isNull);
      expect(ev.dispatchReason, isNull);
      expect(ev.dispatchElapsedMs, isNull);
      expect(ev.dispatchUnattributedMs, isNull);
    });
  });

  group('段结束帧（phase=end）', () {
    test('结束偏移 / 终态 / 原因都能读出来', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'classify.gate',
        phase: 'end',
        startMs: 100,
        endMs: 101,
        status: 'skip',
        reason: 'budget_low',
      );

      expect(ev.dispatchPhase, 'end');
      expect(ev.dispatchEndMs, 101);
      expect(ev.dispatchStatus, 'skip');
      expect(ev.dispatchReason, 'budget_low');
    });

    test('ok 段没有 reason 键时返回 null（不能把 null 当 ok）', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'enqueue',
        phase: 'end',
        startMs: 0,
        endMs: 8,
        status: 'ok',
      );

      expect(ev.dispatchStatus, 'ok');
      expect(ev.dispatchReason, isNull);
    });

    test('未知 status 原样返回（fail-open，不做归一）', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'enqueue',
        phase: 'end',
        status: 'something_new',
      );
      expect(ev.dispatchStatus, 'something_new');
    });
  });

  group('root 收尾帧（name=dispatch）', () {
    test('汇总四键可读', () {
      final ev = dispatchEvent(
        requestId: 'rid_1',
        name: 'dispatch',
        phase: 'end',
        startMs: 0,
        endMs: 3711,
        status: 'ok',
        elapsedMs: 3711,
        unattributedMs: 3147,
        critical: 'router.query_encode',
        dropped: 0,
      );

      expect(ev.dispatchStageName, 'dispatch');
      expect(ev.dispatchElapsedMs, 3711);
      expect(ev.dispatchUnattributedMs, 3147);
      expect(ev.dispatchCriticalStage, 'router.query_encode');
      expect(ev.dispatchDropped, 0);
    });
  });

  group('eventType 门禁（防同名键误读）', () {
    /// 一个「带齐了分发四键」的非分发事件：`tool_result` 的 `status`、
    /// `tool_call` 的 `name` 都是分发 payload 的键名。
    final intruder = ChatEvent.fromJson({
      'eventId': 'evt_other',
      'eventType': EventTypes.toolResult,
      'userId': 'usr_1',
      'groupId': 'grp_1',
      'turnId': 'turn_1',
      'seq': 1,
      'globalSeq': 9,
      'source': 'pigo',
      'createdAt': '2026-11-16T12:00:00.000Z',
      'payload': <String, dynamic>{
        'request_id': 'rid_lookalike',
        'name': 'bash',
        'phase': 'end',
        'start_ms': 10,
        'end_ms': 20,
        'budget_ms': 30,
        'status': 'ok',
        'reason': 'cache_hit',
        'elapsed_ms': 40,
        'unattributed_ms': 50,
        'critical': 'x',
        'dropped': 60,
      },
    });

    test('非 dispatch_stage 事件的同名字段一律读成 null', () {
      expect(intruder.dispatchRequestId, isNull);
      expect(intruder.dispatchStageName, isNull);
      expect(intruder.dispatchPhase, isNull);
      expect(intruder.dispatchStartMs, isNull);
      expect(intruder.dispatchEndMs, isNull);
      expect(intruder.dispatchBudgetMs, isNull);
      expect(intruder.dispatchStatus, isNull);
      expect(intruder.dispatchReason, isNull);
      expect(intruder.dispatchElapsedMs, isNull);
      expect(intruder.dispatchUnattributedMs, isNull);
      expect(intruder.dispatchCriticalStage, isNull);
      expect(intruder.dispatchDropped, isNull);
    });

    test('dispatch_stage 的空 payload 也全给 null（不抛）', () {
      final ev = ChatEvent.fromJson({
        'eventId': 'evt_empty',
        'eventType': EventTypes.dispatchStage,
        'createdAt': '2026-11-16T12:00:00.000Z',
        'payload': <String, dynamic>{},
      });

      expect(ev.dispatchRequestId, isNull);
      expect(ev.dispatchStageName, isNull);
      expect(ev.dispatchPhase, isNull);
      expect(ev.dispatchStartMs, isNull);
    });
  });
}
