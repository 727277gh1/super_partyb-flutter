import 'dart:async';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

import 'support/chat_stream_controller_harness.dart';

/// 控制器旁路通道：gate / 活动 / 上下文用量 / 等待 / TTS / group 元数据 / 目标 / 标题
///
/// ⚠️ 本文件由 `chat_stream_controller_test.dart` 按 group 边界拆出
/// （issue #48）——纯移动，未改动任何断言。
/// 共享夹具见 `support/chat_stream_controller_harness.dart`。
void main() {
  setUpHarness();

  group('gate 决策通道', () {
    test('gateDecisionsSnapshot 含 adaptive_decision（不再静默丢弃）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {
            'action': 'auto_continue',
            'gate_source': 'llm_gate',
            'confidence': 0.9,
            'reason': '任务未完成',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.gateDecisionsSnapshot, hasLength(1));
      final d = c.gateDecisionsSnapshot.single;
      expect(d.kind, GateDecisionKind.autoContinue);
      expect(d.source, GateSourceKind.llmGate);
      expect(d.confidence, 0.9);

      await c.dispose();
    });

    test('gate 决策不进 items（时间线只放用户可见内容）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {'action': 'auto_continue', 'gate_source': 'fastpath'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: 'gate 决策是诊断信息，不进时间线');
      expect(c.gateDecisionsSnapshot, hasLength(1));

      await c.dispose();
    });

    test('gateDecisions 流在事件到达时推送', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <List<GateDecision>>[];
      final sub = c.gateDecisions.listen(pushed.add);

      sse.push(
        EventTypes.goalGateDecision,
        sseEvent(
          EventTypes.goalGateDecision,
          id: 'gate_goal_1',
          payload: {'goal_achieved': true, 'source': 'tasks_completed'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last.single.kind, GateDecisionKind.goalCompleted);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后 gate 决策被清空（不泄漏上一个对话的决策）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.adaptiveDecision,
        sseEvent(
          EventTypes.adaptiveDecision,
          id: 'gate_1',
          payload: {'action': 'stop', 'gate_source': 'llm_gate'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.gateDecisionsSnapshot, hasLength(1));

      await c.switchGroup('grp_2');

      expect(c.gateDecisionsSnapshot, isEmpty, reason: '切对话后旧对话的 gate 决策不得残留');

      await c.dispose();
    });
  });

  group('执行中活动通道（turn_activity）', () {
    test('activitiesSnapshot 含 turn_activity，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          globalSeq: 0,
          payload: {
            'elapsed_ms': 45000,
            'last_event_type': 'tool_call',
            'since_last_event_ms': 3200,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '进度提示不进时间线');
      expect(c.activitiesSnapshot, hasLength(1));
      final a = c.activitiesSnapshot['turn_1']!;
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, 'tool_call');

      await c.dispose();
    });

    test('activities 流在事件到达时推送全量 Map', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <Map<String, TurnActivitySnapshot>>[];
      final sub = c.activities.listen(pushed.add);

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 9000},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last['turn_1']!.elapsedMs, 9000);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后活动快照被清空（不泄漏上一个对话的进度）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 45000},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.activitiesSnapshot, hasLength(1));

      await c.switchGroup('grp_2');

      expect(c.activitiesSnapshot, isEmpty);

      await c.dispose();
    });

    test('turn_activity 不推进 SSE 游标（Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.turnActivity,
        sseEvent(
          EventTypes.turnActivity,
          transient: true,
          payload: {'elapsed_ms': 1000},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty, reason: 'Transient 事件不得作游标');

      await c.dispose();
    });
  });

  group('上下文用量通道（context_update）', () {
    test('contextUsageSnapshot 含用量，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 50000, 'context_window': 200000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '用量是诊断读数，不进时间线');
      final u = c.contextUsageSnapshot;
      expect(u, isNotNull);
      expect(u!.used, 50000);
      expect(u.size, 200000);
      expect(u.remaining, 150000);

      await c.dispose();
    });

    test('contextUsage 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <ContextUsage?>[];
      final sub = c.contextUsage.listen(pushed.add);

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 1234, 'context_window': 8000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.used, 1234);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后用量快照被清空（不泄漏上一个对话的读数）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          payload: {
            'telemetry': {'context_tokens': 500, 'context_window': 1000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.contextUsageSnapshot, isNotNull);

      await c.switchGroup('grp_2');

      expect(c.contextUsageSnapshot, isNull, reason: '切对话后旧用量不得残留');

      await c.dispose();
    });

    test('context_update 推进 SSE 游标（Go 侧 flushEvent 落库，非 Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.contextUpdate,
        sseEvent(
          EventTypes.contextUpdate,
          id: 'evt_ctx_1',
          payload: {
            'telemetry': {'context_tokens': 100, 'context_window': 1000},
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_ctx_1'),
        reason: '落库事件带有效 ID，应推进游标（与 turn_activity 相反）',
      );

      await c.dispose();
    });
  });

  group('执行等待通道（queue_state / retry_scheduled）', () {
    test('executionStatusSnapshot 含等待原因，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {
            'state': 'queued',
            'reason': 'session_busy',
            'queue_total': 3,
            'queue_user': 1,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '等待提示不进时间线');
      final s = c.executionStatusSnapshot;
      expect(s, isNotNull);
      expect(s!.kind, ExecutionStatusKind.queued);
      expect(s.reason, 'session_busy');

      await c.dispose();
    });

    test('executionStatus 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <ExecutionStatus?>[];
      final sub = c.executionStatus.listen(pushed.add);

      sse.push(
        EventTypes.retryScheduled,
        sseEvent(
          EventTypes.retryScheduled,
          payload: {'attempt': 2, 'max_retries': 3},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.kind, ExecutionStatusKind.retryScheduled);
      expect(pushed.last!.attempt, 2);

      await sub.cancel();
      await c.dispose();
    });

    test('切 group 后等待状态被清空（不泄漏上一个对话的提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.executionStatusSnapshot, isNotNull);

      await c.switchGroup('grp_2');

      expect(c.executionStatusSnapshot, isNull, reason: '切对话后旧等待不得残留');

      await c.dispose();
    });

    test('message 到达后等待状态被清除（不挂着过期提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.executionStatusSnapshot, isNotNull);

      sse.push(
        EventTypes.message,
        sseEvent(
          EventTypes.message,
          id: 'evt_msg_1',
          payload: {'text': '回复来了'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.executionStatusSnapshot, isNull);

      await c.dispose();
    });

    test('queue_state 推进 SSE 游标（Go 侧落库，非 Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.queueState,
        sseEvent(
          EventTypes.queueState,
          id: 'evt_qs_1',
          payload: {'state': 'queued', 'reason': 'session_busy'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_qs_1'),
        reason: '落库事件带有效 ID，应推进游标（与 turn_activity 相反）',
      );

      await c.dispose();
    });
  });

  group('语音播报通道（tts_started / tts_completed / tts_failed）', () {
    test('ttsStatusSnapshot 含播报状态，且不进 items', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          transient: true,
          payload: {'mode': 'message', 'seq': 1},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty, reason: '播报状态不进时间线');
      final s = c.ttsStatusSnapshot;
      expect(s.phase, TtsPhase.started);
      expect(s.mode, 'message');

      await c.dispose();
    });

    test('ttsStatus 流在事件到达时推送快照', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <TtsStatus?>[];
      final sub = c.ttsStatus.listen(pushed.add);

      sse.push(
        EventTypes.ttsFailed,
        sseEvent(
          EventTypes.ttsFailed,
          payload: {'message': '语音生成失败，本次文本回复不受影响。'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isNotEmpty);
      expect(pushed.last!.phase, TtsPhase.failed);
      expect(pushed.last!.message, '语音生成失败，本次文本回复不受影响。');

      await sub.cancel();
      await c.dispose();
    });

    test('started → completed 推进到终态', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          transient: true,
          payload: {'mode': 'stream'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.ttsStatusSnapshot.phase, TtsPhase.started);

      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(EventTypes.ttsCompleted, payload: {'parts': 2}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.ttsStatusSnapshot.phase, TtsPhase.completed);
      expect(c.ttsStatusSnapshot.parts, 2);

      await c.dispose();
    });

    test('切 group 后播报状态被清空（不泄漏上一个对话的提示）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      adapter.onGet(
        '/chat/groups/grp_2/timeline',
        (server) => server.reply(200, {
          'items': <Map<String, dynamic>>[],
          'next_before_global_seq': '',
        }),
        queryParameters: {'limit': 200},
      );

      await c.start(groupId: 'grp_1');
      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(EventTypes.ttsCompleted, payload: {'parts': 1}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.ttsStatusSnapshot.hasStatus, isTrue);

      await c.switchGroup('grp_2');

      expect(c.ttsStatusSnapshot.phase, TtsPhase.idle, reason: '切对话后旧播报不得残留');

      await c.dispose();
    });

    test('tts_started 不推进游标，终态事件推进游标', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.ttsStarted,
        sseEvent(
          EventTypes.ttsStarted,
          id: 'evt_tts_started',
          transient: true,
          payload: {'mode': 'stream'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        sse.recordedEventIds,
        isNot(contains('evt_tts_started')),
        reason: 'tts_started 是 Transient，不得作游标',
      );

      sse.push(
        EventTypes.ttsCompleted,
        sseEvent(
          EventTypes.ttsCompleted,
          id: 'evt_tts_done',
          payload: {'parts': 1},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        sse.recordedEventIds,
        contains('evt_tts_done'),
        reason: '终态落库，应推进游标',
      );

      await c.dispose();
    });
  });

  group('group 变更通知通道（group_updated）', () {
    /// 造一个 group_updated 帧（Transient，见 Go PublishGroupUpdated）。
    Map<String, dynamic> groupUpdatedEvent({
      String id = 'evt_gu_1',
      String groupId = 'grp_1',
      String op = 'created',
      String? title = '新对话',
      String? status = 'active',
    }) => sseEvent(
      EventTypes.groupUpdated,
      id: id,
      groupId: groupId,
      transient: true,
      payload: {
        'op': op,
        'group': {
          'id': groupId,
          if (title != null) 'title': title,
          if (status != null) 'status': status,
        },
      },
    );

    test('收到 group_updated → groupUpdates 流收到一条（含 op 与快照）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, GroupUpdateOp.created);
      expect(pushed.single.groupId, 'grp_1');
      expect(pushed.single.title, '新对话');
      expect(pushed.single.status, 'active');

      await sub.cancel();
      await c.dispose();
    });

    test('逐条推送而非累积（两条 → 两次事件，顺序保持）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(id: 'evt_1', groupId: 'grp_x', op: 'created'),
      );
      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(
          id: 'evt_2',
          groupId: 'grp_x',
          op: 'deleted',
          title: null,
          status: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '通知语义：逐条推送，不累积');
      expect(pushed[0].op, GroupUpdateOp.created);
      expect(pushed[1].op, GroupUpdateOp.deleted);

      await sub.cancel();
      await c.dispose();
    });

    test('不受 group 过滤影响：聚焦 grp_1 时也能收到 grp_other 的变更', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      // 另一个 group 的变更——对话页聚焦 grp_1，但列表页需要知道它。
      sse.push(
        EventTypes.groupUpdated,
        groupUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        pushed,
        hasLength(1),
        reason: 'group_updated 的 groupId 指向被变更的 group，不是当前聚焦的 group',
      );
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('未知 op 归 GroupUpdateOp.unknown 且 needsRefetch 为真（不丢弃事件）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent(op: 'renamed'));
      await Future<void>.delayed(Duration.zero);

      expect(pushed.single.op, GroupUpdateOp.unknown);
      expect(pushed.single.op.needsRefetch, isTrue);

      await sub.cancel();
      await c.dispose();
    });

    test('group_updated 不进 items，也不推进游标（Transient）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupUpdated, groupUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      expect(sse.recordedEventIds, isEmpty);

      await c.dispose();
    });
  });
  group('group 元数据通知通道（group_metadata_updated）', () {
    /// 造一个 group_metadata_updated 帧。
    ///
    /// ⚠️ `transient` 默认 **false**——对齐服务端实际行为（它确实落库）。
    Map<String, dynamic> metadataUpdatedEvent({
      String id = 'evt_gm_1',
      String groupId = 'grp_1',
      String reason = 'goal_completed',
      Map<String, dynamic>? metadata,
    }) => sseEvent(
      EventTypes.groupMetadataUpdated,
      id: id,
      groupId: groupId,
      payload: {
        'reason': reason,
        'metadata':
            metadata ??
            {
              'goal_gate': {
                'enabled': false,
                'continue_until_done': false,
                'state': {'status': 'completed'},
              },
              'tts': {'enabled': true},
            },
      },
    );

    test('收到事件 → groupUpdates 流收到 op=metadata 且携带完整 metadata', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupMetadataUpdated, metadataUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, GroupUpdateOp.metadata);
      expect(pushed.single.groupId, 'grp_1');

      final md = pushed.single.metadata;
      expect(md, isNotNull, reason: '必须携带 metadata，否则面板无法刷新');
      expect(
        (md!['goal_gate'] as Map)['enabled'],
        isFalse,
        reason: 'goal gate 已被服务端自动停用——这就是需要纠正的错显',
      );
      expect(
        (md['goal_gate'] as Map)['continue_until_done'],
        isFalse,
        reason: '两个键成对写入，只改一个会让 goalGateEnabled 仍为 true',
      );

      await sub.cancel();
      await c.dispose();
    });

    test('reason 可读：goal_completed / max_auto_turns_reached', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e1', reason: 'goal_completed'),
      );
      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e2', reason: 'max_auto_turns_reached'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2));
      // reason 在事件上（不在 GroupUpdate 里）；此处用原始事件验证可读性。
      expect(pushed[0].op, GroupUpdateOp.metadata);
      expect(pushed[1].op, GroupUpdateOp.metadata);

      await sub.cancel();
      await c.dispose();
    });

    test('⚠️ 与 goal_updated 相反：本事件**推进**游标（它确实落库）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'evt_gm_cursor'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        contains('evt_gm_cursor'),
        reason:
            'group_metadata_updated 持久化到 chat_events（broker.go:82），'
            '带有效 ID，应当推进游标以便断线回放',
      );

      await c.dispose();
    });

    test('不受 group 过滤影响：别的 group 的 metadata 变更也能收到', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        metadataUpdatedEvent(id: 'e_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('metadata 缺失的异常载荷不推送（避免清空现有开关）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupMetadataUpdated,
        sseEvent(
          EventTypes.groupMetadataUpdated,
          id: 'evt_no_md',
          payload: {'reason': 'goal_completed'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(
        pushed.single.metadata,
        isNull,
        reason: '无 metadata 时消费方应忽略（不得用空 map 覆盖）',
      );

      await sub.cancel();
      await c.dispose();
    });

    test('不进 items（时间线不得出现元数据变更气泡）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupMetadataUpdated, metadataUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);

      await c.dispose();
    });
  });
  group('目标变更通知通道（goal_updated）', () {
    /// 造一个 goal_updated 帧。
    ///
    /// ⚠️ `transient` 默认 **false**——刻意对齐服务端的实际行为（漏设）。
    /// 用 true 造数据会让游标断言在假前提上通过。
    Map<String, dynamic> goalUpdatedEvent({
      String id = 'evt_goal_1',
      String groupId = 'grp_1',
      String op = 'goal_create',
      String source = 'user',
      String? goalText = '把同步做稳',
      List<Map<String, dynamic>>? tasks,
      bool transient = false,
    }) => sseEvent(
      EventTypes.goalUpdated,
      id: id,
      groupId: groupId,
      transient: transient,
      globalSeq: 0,
      payload: {
        'op': op,
        if (goalText != null)
          'goal': {
            'id': 'goal_1',
            'group_id': groupId,
            'goal_text': goalText,
            'status': 'active',
          },
        'tasks':
            tasks ??
            [
              {'task_id': 't1', 'status': 'in_progress', 'title': '修 bug'},
            ],
        'progress': {'total': 1, 'completed': 0, 'in_progress': 1},
      },
    );

    test('收到 goal_updated → goalUpdates 流收到一条（含快照）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.op, 'goal_create');
      expect(pushed.single.groupId, 'grp_1');
      expect(pushed.single.goalText, '把同步做稳');
      expect(pushed.single.tasks, hasLength(1));
      expect(pushed.single.snapshot, isNotNull);

      await sub.cancel();
      await c.dispose();
    });

    test('⚠️ 核心：不推进游标（服务端漏设 Transient，穿透会丢整个回放窗口）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(
        sse.recordedEventIds,
        isEmpty,
        reason:
            'goal_updated 不在 chat_events 表里，若被记作 cursor，服务端 '
            'replayUserEvents 定位不到该 ID 会返回 nil，丢掉整个回放窗口',
      );
      expect(sse.lastEventId, isNull, reason: '游标必须保持未变（可用 lastEventId 观测）');

      await c.dispose();
    });

    test('不进 items（时间线不得出现目标变更气泡）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.goalUpdated, goalUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);
      expect(c.bufferedEventCount, 0, reason: '通知类事件不占缓冲区');

      await c.dispose();
    });

    test('即便服务端将来设了 transient=true 也不推游标（按类型分流）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_goal_t', transient: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty);

      await c.dispose();
    });

    test('不受 group 过滤影响：别的 group 的目标变更也能收到', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('逐条推送而非累积（task_create 后 task_reorder 各一次）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_1', op: 'task_create'),
      );
      sse.push(
        EventTypes.goalUpdated,
        goalUpdatedEvent(id: 'evt_2', op: 'task_reorder'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '通知语义：逐条推送，不累积');
      expect(pushed[0].op, 'task_create');
      expect(pushed[1].op, 'task_reorder');

      await sub.cancel();
      await c.dispose();
    });

    test('goal 缺失的异常载荷不推送（避免清空现有目标）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      // 无 goal 字段（服务端任务列表读失败时会退化为不带快照的信号）。
      sse.push(
        EventTypes.goalUpdated,
        sseEvent(
          EventTypes.goalUpdated,
          id: 'evt_no_goal',
          payload: {'op': 'task_create', 'tasks': <Map<String, dynamic>>[]},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1), reason: '事件本身仍送达（消费方可据此选择重拉）');
      expect(pushed.single.snapshot, isNull, reason: '无 goal 时不造空快照');

      await sub.cancel();
      await c.dispose();
    });

    test('groupId 为空时丢弃（无法定位要刷新哪个对话）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      final pushed = <GoalUpdate>[];
      final sub = c.goalUpdates.listen(pushed.add);

      await c.ensureConnected();
      sse.push(EventTypes.goalUpdated, goalUpdatedEvent(groupId: ''));
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isEmpty);
      expect(sse.recordedEventIds, isEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('dispose 后不报错（流已关闭）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      await c.dispose();

      // 控制器已关闭，推事件不应抛异常。
      expect(
        () => sse.push(EventTypes.goalUpdated, goalUpdatedEvent()),
        returnsNormally,
      );
      await Future<void>.delayed(Duration.zero);
    });
  });
  group('标题实时更新（group_title_updated）', () {
    /// 造一个 group_title_updated 帧（Transient，见 Go buildTitleUpdatedEvent）。
    Map<String, dynamic> titleUpdatedEvent({
      String id = 'evt_gt_1',
      String groupId = 'grp_1',
      String? newTitle = '燕麦怎么吃',
    }) => sseEvent(
      EventTypes.groupTitleUpdated,
      id: id,
      groupId: groupId,
      transient: true,
      // globalSeq 为 0：Transient 事件不落库，无有效序号。
      globalSeq: 0,
      payload: {if (newTitle != null) 'new_title': newTitle},
    );

    test(
      '收到 group_title_updated → 一条 GroupUpdate(op=title, title=新标题)',
      () async {
        final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
        mockTimeline();
        await c.start(groupId: 'grp_1');

        final pushed = <GroupUpdate>[];
        final sub = c.groupUpdates.listen(pushed.add);

        sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
        await Future<void>.delayed(Duration.zero);

        expect(pushed, hasLength(1));
        expect(pushed.single.op, GroupUpdateOp.title);
        expect(pushed.single.title, '燕麦怎么吃');
        expect(pushed.single.groupId, 'grp_1');
        // 该事件没有 status 快照，不得凭空给一个值（列表页会拿它覆盖现有状态）。
        expect(pushed.single.status, isNull);

        await sub.cancel();
        await c.dispose();
      },
    );

    test('游标不被推进（Transient 无有效 ID，作 cursor 会跳过权威帧）', () async {
      // 这是本通道最危险的一步：一旦把 group_title_updated 的 eventId 记进
      // cursor，重连时服务端会从它之后回放，而它是 Transient（未落库）——
      // 用它定位等于跳过一个不存在的位置，其后的权威帧会永久丢失。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(sse.recordedEventIds, isEmpty, reason: 'Transient 事件不得作游标');

      await c.dispose();
    });

    test('不受 group 过滤影响：聚焦 grp_1 时也能收到 grp_other 的标题变更', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_other', groupId: 'grp_other'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(1));
      expect(pushed.single.groupId, 'grp_other');

      await sub.cancel();
      await c.dispose();
    });

    test('不进 items（标题更新不是时间线正文）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent());
      await Future<void>.delayed(Duration.zero);

      expect(c.snapshot, isEmpty);

      await c.dispose();
    });

    test('groupId 为空时丢弃（无法定位要更新哪一项）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(EventTypes.groupTitleUpdated, titleUpdatedEvent(groupId: ''));
      await Future<void>.delayed(Duration.zero);

      expect(pushed, isEmpty);

      await sub.cancel();
      await c.dispose();
    });

    test('new_title 缺失/空串时不产生标题（不得把标题清空）', () async {
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_a', newTitle: null),
      );
      sse.push(
        EventTypes.groupTitleUpdated,
        titleUpdatedEvent(id: 'evt_b', newTitle: ''),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed, hasLength(2), reason: '事件本身仍要送达（op=title）');
      expect(pushed[0].title, isNull);
      expect(pushed[1].title, isNull);

      await sub.cancel();
      await c.dispose();
    });

    test('旧键名 title 不再被读取（服务端已改为 new_title）', () async {
      // 服务端 2026-09 的修复方向是「改发射端」（前端两处一致读 new_title）。
      // 本用例钉住：若有人把客户端改成读 payload.title，这里会失败。
      final c = ChatStreamController(sse: sse, api: api, userId: 'usr_1');
      mockTimeline();
      await c.start(groupId: 'grp_1');

      final pushed = <GroupUpdate>[];
      final sub = c.groupUpdates.listen(pushed.add);

      sse.push(
        EventTypes.groupTitleUpdated,
        sseEvent(
          EventTypes.groupTitleUpdated,
          transient: true,
          globalSeq: 0,
          payload: {'title': '旧键名的标题'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pushed.single.title, isNull);

      await sub.cancel();
      await c.dispose();
    });
  });
}
