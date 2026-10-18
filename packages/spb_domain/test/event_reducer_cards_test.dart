import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// [EventReducer] 的归约正确性测试。
///
/// 归约是对话 UI 的正确性核心，且是纯函数——所有状态显式传入，故可无头单测。
void main() {
  /// 造一个事件。默认 transient=false（落库事件），便于用 `globalSeq` 排序。
  ChatEvent ev(
    String type, {
    String id = '',
    String turnId = 'turn_1',
    Map<String, dynamic>? payload,
    bool transient = false,
    int seq = 1,
    int globalSeq = 1,
    String groupId = 'grp_1',
    String? agentId,
  }) => ChatEvent(
    eventId: id.isEmpty ? '${type}_$globalSeq' : id,
    userId: 'usr_1',
    groupId: groupId,
    turnId: turnId,
    eventType: type,
    seq: seq,
    globalSeq: transient ? null : globalSeq,
    source: 'test',
    createdAt: DateTime.utc(2024, 3, 5, 8, 9, globalSeq.clamp(0, 59)),
    payload: payload,
    transient: transient,
    agentId: agentId,
  );

  /// EventReducer 归约：卡片与旁路通道（不进时间线的通道）
  ///
  /// ⚠️ 本文件由 `event_reducer_test.dart` 按 **group 边界**拆出（issue #48）——
  /// 纯移动，**未改动任何断言**。`ev(...)` 辅助函数在每份文件里各带一份
  /// （同 `chat_stream_controller_stale_test.dart` 的既有先例：Dart 的测试
  /// 辅助无法跨文件共享，除非进 `lib/`——那会让测试代码进生产产物）。

  group('归属反馈卡状态', () {
    /// routing_feedback_request 事件（payload 照 Go feedbackRequestPayload）。
    ChatEvent request({
      String id = 'req_1',
      String turnId = 'turn_1',
      String evaluatedTurnId = 'turn_1',
      String token = 'tok_1',
      List<Map<String, dynamic>>? options,
      String question = '这条消息我归到了「团队周报」，准确吗？',
      int globalSeq = 1,
    }) => ev(
      EventTypes.routingFeedbackRequest,
      id: id,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: {
        'question': question,
        'options':
            options ??
            [
              {'label': '准确', 'reply': '反馈#正确'},
              {'label': '不准确', 'reply': '反馈#错误'},
            ],
        'token': token,
        'evaluated_turn_id': evaluatedTurnId,
        'chosen_group_id': 'grp_1',
      },
    );

    test('产出 FeedbackRequestItem（token/question/options 到位）', () {
      final r = EventReducer.reduce([request()]);

      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<FeedbackRequestItem>());
      final fb = item as FeedbackRequestItem;
      expect(fb.token, 'tok_1', reason: 'token 是回执锚点，缺它无法提交');
      expect(fb.question, contains('准确吗'));
      expect(fb.options, ['准确', '不准确']);
      expect(fb.evaluatedTurnId, 'turn_1');
      expect(fb.resolved, isFalse);
      expect(fb.canResolve, isTrue);
    });

    test('同 turn 重复请求只保留一条（对齐服务端 partial unique index）', () {
      // 客户端会看到重放：SSE cursor 回放与 timeline 回填存在交叠窗口。
      // 不幂等则同一次登录出现两张同问题卡片。
      final r = EventReducer.reduce([
        request(id: 'req_1', globalSeq: 1),
        request(id: 'req_2', globalSeq: 2),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items, hasLength(1), reason: '同一 turn 只应有一张反馈卡');
      expect(items.single.id, 'req_1');
    });

    test('不同 turn 的请求各自成卡', () {
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        request(
          id: 'req_2',
          turnId: 'turn_2',
          evaluatedTurnId: 'turn_2',
          globalSeq: 2,
        ),
      ]);

      expect(r.items.whereType<FeedbackRequestItem>(), hasLength(2));
    });

    test('重放先到无 token 载荷时，后到的完整载荷补上 token', () {
      // 降级路径：历史回填可能先给出无 token 的载荷。补全而非新增，
      // 且 createdAt/身份沿用原卡（排序不应因重放漂移）。
      final r = EventReducer.reduce([
        request(id: 'req_1', token: '', globalSeq: 1),
        request(id: 'req_2', token: 'tok_real', globalSeq: 2),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items, hasLength(1));
      expect(items.single.token, 'tok_real', reason: '补全后必须可提交回执');
      expect(items.single.id, 'req_1', reason: '身份沿用原卡');
    });

    test('token 缺失时不可 resolve（UI 据此禁用按钮）', () {
      final r = EventReducer.reduce([request(token: '')]);

      expect((r.items.single as FeedbackRequestItem).canResolve, isFalse);
    });

    test('routing_feedback 到达后标记已解决（按被评价的 turn 匹配）', () {
      // routing_feedback 的 payload 里**没有** token/事件 id，唯一可靠匹配键
      // 是 turnId（事件附在被评价的 turn 上）。
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_1',
          globalSeq: 2,
          payload: {'correct': true},
        ),
      ]);

      final fb = r.items.whereType<FeedbackRequestItem>().single;
      expect(fb.resolved, isTrue);
      expect(fb.canResolve, isFalse, reason: '已答的卡不得重复提交');
      expect(fb.token, 'tok_1', reason: '标记已解决不得丢失 token');
    });

    test('routing_feedback 不误标其他 turn 的卡', () {
      final r = EventReducer.reduce([
        request(id: 'req_1', turnId: 'turn_1', evaluatedTurnId: 'turn_1'),
        request(
          id: 'req_2',
          turnId: 'turn_2',
          evaluatedTurnId: 'turn_2',
          globalSeq: 2,
        ),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_2',
          globalSeq: 3,
          payload: {'correct': false},
        ),
      ]);

      final items = r.items.whereType<FeedbackRequestItem>().toList();
      expect(items[0].resolved, isFalse, reason: 'turn_1 的卡未被作答');
      expect(items[1].resolved, isTrue);
    });

    test('evaluated_turn_id 与事件 turnId 不同时，按 evaluated_turn_id 匹配', () {
      // 请求事件挂在完成它的 turn 上，而标注写回被评价的 turn。语义不同，
      // 归约以 payload 的 evaluated_turn_id 为准。
      final r = EventReducer.reduce([
        request(
          id: 'req_1',
          turnId: 'turn_current',
          evaluatedTurnId: 'turn_evaluated',
        ),
        ev(
          EventTypes.routingFeedback,
          id: 'fb_1',
          turnId: 'turn_evaluated',
          globalSeq: 2,
        ),
      ]);

      expect(r.items.whereType<FeedbackRequestItem>().single.resolved, isTrue);
    });
  });

  group('agent.file.* → AgentFileItem', () {
    Map<String, dynamic> filePayload({
      String rel = 'QWEN.md',
      String? fileId = 'ufs_001',
      String mime = 'text/markdown; charset=utf-8',
      int size = 3585,
    }) => {
      'relative_path': rel,
      'metadata': {'relative_path': rel},
      'mime_type': mime,
      'size_bytes': size,
      if (fileId != null) 'ufs_file_id': fileId,
    };

    test('created 产出文件卡，字段映射正确', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'created');
      expect(item.ufsFileId, 'ufs_001');
      expect(item.sizeBytes, 3585);
      expect(item.mimeType, 'text/markdown; charset=utf-8');
      expect(item.fileName, 'QWEN.md');
      expect(item.relativePath, 'QWEN.md');
      expect(item.isDeleted, isFalse);
    });

    test('created → modified 合并为同一卡且 action 升级', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
        ev(
          EventTypes.agentFileModified,
          payload: filePayload(size: 4000),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'modified');
      expect(item.sizeBytes, 4000);
      expect(item.modifiedAt, isNotNull);
      expect(item.deletedAt, isNull);
    });

    test('created → modified → deleted 合并为一张置灰卡，保留创建时的 fileId', () {
      final r = EventReducer.reduce([
        ev(EventTypes.agentFileCreated, payload: filePayload(), globalSeq: 1),
        ev(
          EventTypes.agentFileModified,
          payload: filePayload(size: 4000),
          globalSeq: 2,
        ),
        ev(
          EventTypes.agentFileDeleted,
          payload: {
            // 删除事件实测无 ufs_file_id / size_bytes / metadata。
            'relative_path': 'QWEN.md',
            'mime_type': 'application/octet-stream',
            'deleted_from_ufs': true,
          },
          globalSeq: 3,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.action, 'deleted');
      expect(item.isDeleted, isTrue);
      // 创建时的 fileId 不应被删除事件冲掉。
      expect(item.ufsFileId, 'ufs_001');
      expect(item.deletedAt, isNotNull);
    });

    test('created 无 fileId 被跳过（对齐 webapp）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(fileId: null),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, isEmpty);
    });

    test('deleted 无 fileId 仍然出卡（服务端删除事件不带 fileId）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileDeleted,
          payload: {
            'relative_path': 'gone.md',
            'mime_type': 'application/octet-stream',
          },
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.isDeleted, isTrue);
      expect(item.ufsFileId, isNull);
    });

    test('reports/tts/ 下但无合法 turn 目录（如直接放文件）回落为普通文件卡', () {
      // `reports/tts/abc.mp3` 没有 {turn_id}/ 子目录，turn 段含 '.' 非法，
      // parseTTSAudioPath 返回 null → ttsKind=null，渲染为普通文件卡（不丢弃）。
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(rel: 'reports/tts/abc.mp3', mime: 'audio/mpeg'),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, isNull);
      expect(item.fileName, 'abc.mp3');
    });

    test('合法 TTS 路径设置 ttsKind（message_ → reply）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(
            rel: 'reports/tts/c7ad0b62/message_6.mp3',
            mime: 'audio/mpeg',
            size: 53079,
          ),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, TtsStreamKind.reply);
      expect(item.sizeBytes, 53079);
    });

    test('合法 TTS 路径设置 ttsKind（narration_ → narration）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload(
            rel: 'reports/tts/turn-1/narration_turn-1_2.mp3',
            mime: 'audio/mpeg',
          ),
          globalSeq: 1,
        ),
      ]);

      final item = r.items.single as AgentFileItem;
      expect(item.ttsKind, TtsStreamKind.narration);
    });

    test('nice_name 优先作为展示名（预留字段，生产实测从未出现）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.agentFileCreated,
          payload: filePayload()..['nice_name'] = '我的配置笔记',
          globalSeq: 1,
        ),
      ]);

      final item = r.items.single as AgentFileItem;
      expect(item.displayName, '我的配置笔记');
      expect(item.fileName, 'QWEN.md');
    });
  });

  group('turn_activity → activities 通道（不进时间线）', () {
    /// 造一个 turn_activity 事件（Transient，不落库）。
    ChatEvent activity({
      String turnId = 'turn_1',
      int? elapsedMs = 45000,
      String? lastEventType = 'tool_call',
      int? sinceLastEventMs = 3200,
      int globalSeq = 1,
    }) => ev(
      EventTypes.turnActivity,
      turnId: turnId,
      transient: true,
      globalSeq: globalSeq,
      payload: {
        if (elapsedMs != null) 'elapsed_ms': elapsedMs,
        if (lastEventType != null) 'last_event_type': lastEventType,
        if (sinceLastEventMs != null) 'since_last_event_ms': sinceLastEventMs,
      },
    );

    test('产出 activities，但不产生任何 items', () {
      final r = EventReducer.reduce([activity()]);

      expect(r.items, isEmpty, reason: '进度提示不是对话正文');
      expect(r.activities, hasLength(1));
      final a = r.activities['turn_1']!;
      expect(a.turnId, 'turn_1');
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, 'tool_call');
      expect(a.sinceLastEventMs, 3200);
    });

    test('同一 turn 两条只保留最新（越新越准）', () {
      final r = EventReducer.reduce([
        activity(elapsedMs: 15000, lastEventType: 'thought', globalSeq: 1),
        activity(elapsedMs: 45000, lastEventType: 'tool_call', globalSeq: 2),
      ]);

      expect(r.activities, hasLength(1), reason: '同 turn 只留一条');
      expect(r.activities['turn_1']!.elapsedMs, 45000);
      expect(r.activities['turn_1']!.lastEventType, 'tool_call');
    });

    test('不同 turn 各自独立', () {
      final r = EventReducer.reduce([
        activity(turnId: 'turn_a', elapsedMs: 1000, globalSeq: 1),
        activity(turnId: 'turn_b', elapsedMs: 2000, globalSeq: 2),
      ]);

      expect(r.activities.keys, containsAll(['turn_a', 'turn_b']));
      expect(r.activities['turn_a']!.elapsedMs, 1000);
      expect(r.activities['turn_b']!.elapsedMs, 2000);
    });

    test('首帧无上一步事件时 lastEventType/sinceLastEventMs 为 null', () {
      final r = EventReducer.reduce([
        activity(lastEventType: null, sinceLastEventMs: null),
      ]);

      final a = r.activities['turn_1']!;
      expect(a.elapsedMs, 45000);
      expect(a.lastEventType, isNull);
      expect(a.sinceLastEventMs, isNull);
    });

    test('elapsed_ms 缺失时退化为 0（异常载荷不产出 null）', () {
      final r = EventReducer.reduce([activity(elapsedMs: null)]);

      expect(r.activities['turn_1']!.elapsedMs, 0);
    });

    test('turnId 为空的 turn_activity 被丢弃（无法按 turn 归并）', () {
      final r = EventReducer.reduce([activity(turnId: '')]);

      expect(r.activities, isEmpty);
    });

    test('turn_activity 不推进 SSE 游标（Transient 无有效 ID）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.message,
          id: 'evt_msg',
          payload: {'text': 'hi'},
          globalSeq: 1,
        ),
        activity(globalSeq: 2),
      ]);

      expect(r.lastEventId, 'evt_msg', reason: 'Transient 事件不得作游标');
    });

    test('activity 与同 turn 的正文共存：items 有正文、activities 有进度', () {
      final r = EventReducer.reduce([
        activity(elapsedMs: 30000, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '正在分析…'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.items.single, isA<AssistantMessageItem>());
      expect(r.activities['turn_1']!.elapsedMs, 30000);
    });
  });

  group('context_update → contextUsage 通道（不进时间线）', () {
    /// 造一个 context_update 事件。
    ///
    /// 默认 transient=false：Go 侧它走 `flushEvent`（**落库**）而非
    /// `flushEventTransient`，故会带有效 eventId/globalSeq 并推进游标。
    ChatEvent ctx(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.contextUpdate,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    test('Go telemetry 形状：产出 contextUsage，但不产生任何 items', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {
            'turns': 3,
            'truncation_count': 0,
            'compaction_count': 1,
            'context_utilization': 0.25,
            'context_tokens': 50000,
            'context_window': 200000,
          },
        }),
      ]);

      expect(r.items, isEmpty, reason: '用量是诊断读数，不是对话正文');
      final u = r.contextUsage;
      expect(u, isNotNull);
      expect(u!.used, 50000, reason: 'context_tokens → used');
      expect(u.size, 200000, reason: 'context_window → size');
      expect(u.remaining, 150000, reason: '未显式给出时由 size - used 推出');
      expect(u.cost, isNull, reason: 'Go 从不发射 cost，不得伪造');
      expect(u.hasData, isTrue);
    });

    test('Go compaction 形状：tokens_after 优先于 tokens_before', () {
      final r = EventReducer.reduce([
        ctx({
          'compaction': {
            'status': 'completed',
            'reason': 'auto',
            'tokens_before': 180000,
            'tokens_after': 42000,
            'summarized_count': 12,
            'kept_count': 3,
          },
        }),
      ]);

      expect(r.items, isEmpty);
      final u = r.contextUsage!;
      expect(u.used, 42000, reason: '压缩完成后以 tokens_after 为准');
      expect(u.size, isNull, reason: '压缩事件不带窗口大小');
    });

    test('compaction_started 只有 tokens_before 时也能取到用量', () {
      final r = EventReducer.reduce([
        ctx({
          'compaction': {'status': 'started', 'tokens_before': 190000},
        }),
      ]);

      expect(r.contextUsage!.used, 190000);
    });

    test('遗留 context 形状（webapp 解析的那份）也支持，含 cost', () {
      final r = EventReducer.reduce([
        ctx({
          'context': {
            'used': 1234,
            'size': 8000,
            'remaining': 6766,
            'cost': {'amount': 0.0123, 'currency': 'USD'},
          },
        }),
      ]);

      final u = r.contextUsage!;
      expect(u.used, 1234);
      expect(u.size, 8000);
      expect(u.remaining, 6766);
      expect(u.cost!.amount, 0.0123);
      expect(u.cost!.currency, 'USD');
    });

    test('同 turn 多条合并：telemetry 的窗口与 compaction 的用量互不覆盖', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 10000, 'context_window': 200000},
        }, globalSeq: 1),
        ctx({
          'compaction': {'status': 'completed', 'tokens_after': 3000},
        }, globalSeq: 2),
      ]);

      final u = r.contextUsage!;
      expect(u.used, 3000, reason: '新的 used 覆盖旧值');
      expect(u.size, 200000, reason: '窗口大小沿用上一条 telemetry');
      expect(u.remaining, 197000, reason: 'used 更新后 remaining 必须重算');
    });

    test('context_update 推进 SSE 游标（Go 侧落库，不是 Transient）', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 100, 'context_window': 1000},
        }, globalSeq: 7),
      ]);

      expect(
        r.lastEventId,
        'context_update_7',
        reason: 'flushEvent 落库事件带有效 ID，可作游标',
      );
    });

    test('无法解析的异常载荷不产出快照（也不清空已有值）', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 500, 'context_window': 1000},
        }, globalSeq: 1),
        // 只带 compaction 状态、无任何 token 字段：fromEventPayload 返回 null。
        ctx({
          'compaction': {'status': 'started'},
        }, globalSeq: 2),
      ]);

      expect(r.contextUsage!.used, 500, reason: '异常载荷不得清空已知用量');
      expect(r.contextUsage!.size, 1000);
    });

    test('用量与同 turn 的正文共存：items 有正文、contextUsage 有读数', () {
      final r = EventReducer.reduce([
        ctx({
          'telemetry': {'context_tokens': 2000, 'context_window': 8000},
        }, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '好了'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.contextUsage!.used, 2000);
    });

    test('无 context_update 时 contextUsage 为 null', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': 'hi'}),
      ]);

      expect(r.contextUsage, isNull, reason: '无数据应隐藏而非显示 0');
    });
  });

  group('queue_state / retry_scheduled → executionStatus 通道（不进时间线）', () {
    /// 造一个 queue_state 事件。
    ///
    /// ⚠️ 默认 transient=false：Go 侧五个发射点**全部未设 Transient**
    /// （`enqueue.go` 走 persistEventAtomic、`turn_worker.go` / `gate_impls.go`
    /// 走 w.emit 的落库分支），故它们是落库事件、会推进游标。
    ChatEvent qs(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.queueState,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    ChatEvent retry(
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      EventTypes.retryScheduled,
      turnId: turnId,
      globalSeq: globalSeq,
      payload: payload,
    );

    test('queue_state(queued) 产出 executionStatus，但不产生任何 items', () {
      final r = EventReducer.reduce([
        qs({
          'state': 'queued',
          'reason': 'session_busy',
          'queue_total': 7,
          'queue_user': 2,
        }),
      ]);

      expect(r.items, isEmpty, reason: '等待提示不是对话正文');
      final s = r.executionStatus;
      expect(s, isNotNull);
      expect(s!.turnId, 'turn_1');
      expect(s.kind, ExecutionStatusKind.queued);
      expect(s.reason, 'session_busy');
      expect(s.queueTotal, 7);
      expect(s.queueUser, 2);
    });

    test(
      'retry_scheduled 产出 executionStatus（attempt / max_retries / delay_ms）',
      () {
        final r = EventReducer.reduce([
          retry({
            'attempt': 2,
            'max_retries': 3,
            'delay_ms': 5000,
            'reason': 'stderr 原文不应被当文案',
          }),
        ]);

        expect(r.items, isEmpty);
        final s = r.executionStatus!;
        expect(s.kind, ExecutionStatusKind.retryScheduled);
        expect(s.attempt, 2);
        expect(s.maxRetries, 3);
        expect(s.delayMs, 5000);
      },
    );

    test('start 清除同一 turn 的等待状态（起跑即等待结束）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        ev(EventTypes.start, payload: {'status': 'running'}, globalSeq: 2),
      ]);

      expect(r.executionStatus, isNull, reason: '已起跑，不该再显示「排队中」');
    });

    test('message 正文到达后清除等待状态', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        ev(
          EventTypes.message,
          payload: {'text': '回复来了'},
          transient: true,
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(1));
      expect(r.executionStatus, isNull, reason: '已有正文，等待显然结束');
    });

    test('done / error 终态也清除等待状态', () {
      final done = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.done, payload: {'status': 'completed'}, globalSeq: 2),
      ]);
      expect(done.executionStatus, isNull);

      final failed = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.error, payload: {'message': 'boom'}, globalSeq: 2),
      ]);
      expect(failed.executionStatus, isNull);
    });

    test('清除只作用于同一 turn（别的 turn 的正文不抹掉本 turn 的等待）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, turnId: 'turn_1', globalSeq: 1),
        ev(
          EventTypes.message,
          turnId: 'turn_2',
          payload: {'text': '另一个 turn'},
          globalSeq: 2,
        ),
      ]);

      expect(r.executionStatus, isNotNull, reason: 'turn_2 的正文与 turn_1 是否在等无关');
      expect(r.executionStatus!.turnId, 'turn_1');
    });

    test('queue_state(state=cancelled) 是终态而非等待，且会清除已有等待', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        qs({'state': 'cancelled', 'reason': 'cancelled'}, globalSeq: 2),
      ]);

      expect(
        r.executionStatus,
        isNull,
        reason: 'cancelled 是等待结束（EmitCanceled），不是新的等待',
      );
    });

    test('同 turn 多条等待只留最后一条（越新越准）', () {
      final r = EventReducer.reduce([
        qs({
          'state': 'queued',
          'reason': 'global_concurrency_limit',
        }, globalSeq: 1),
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 2),
      ]);

      expect(r.executionStatus!.reason, 'session_busy');
    });

    test('retry_scheduled 覆盖先前的 queue_state（后到的等待原因胜出）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued', 'reason': 'session_busy'}, globalSeq: 1),
        retry({'attempt': 2}, globalSeq: 2),
      ]);

      expect(r.executionStatus!.kind, ExecutionStatusKind.retryScheduled);
      expect(r.executionStatus!.attempt, 2);
    });

    test('state 缺失或非 queued 的 queue_state 不产出状态', () {
      expect(EventReducer.reduce([qs(const {})]).executionStatus, isNull);
      expect(
        EventReducer.reduce([
          qs({'state': 'running'}),
        ]).executionStatus,
        isNull,
      );
    });

    test('turnId 为空的等待事件被丢弃（无法定位 turn）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, turnId: ''),
      ]);

      expect(r.executionStatus, isNull);
    });

    test('两类事件均推进 SSE 游标（Go 侧落库，非 Transient）', () {
      final r = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 5),
        retry({'attempt': 1}, globalSeq: 6),
      ]);

      expect(
        r.lastEventId,
        'retry_scheduled_6',
        reason: '落库事件带有效 ID，应作游标（与 turn_activity 相反）',
      );
    });

    test('等待与同 turn 正文共存：等待在 message 前有效、之后被清', () {
      final before = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
      ]);
      expect(before.executionStatus, isNotNull);

      final after = EventReducer.reduce([
        qs({'state': 'queued'}, globalSeq: 1),
        ev(EventTypes.message, payload: {'text': '好了'}, globalSeq: 2),
      ]);
      expect(after.items, hasLength(1));
      expect(after.executionStatus, isNull);
    });
  });

  group('tts_* → ttsStatus 通道（不进时间线）', () {
    /// 造一个 TTS 生命周期事件。
    ///
    /// ⚠️ `tts_started` 默认 transient=true（Go `main.go:715` 只对它设 Transient）；
    /// 两个终态事件是**落库**的，故用 transient=false。
    ChatEvent tts(
      String type,
      Map<String, dynamic> payload, {
      String turnId = 'turn_1',
      int globalSeq = 1,
    }) => ev(
      type,
      turnId: turnId,
      globalSeq: globalSeq,
      transient: type == EventTypes.ttsStarted,
      payload: payload,
    );

    test('tts_started 产出 ttsStatus(started)，但不产生任何 items', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'message', 'seq': 1}),
      ]);

      expect(r.items, isEmpty, reason: '播报状态不是对话正文');
      final s = r.ttsStatus;
      expect(s.turnId, 'turn_1');
      expect(s.phase, TtsPhase.started);
      expect(s.mode, 'message');
      expect(s.hasStatus, isTrue);
      expect(s.isTerminal, isFalse);
    });

    test('stream 模式的 tts_started 带 reason=first_delta', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream', 'reason': 'first_delta'}),
      ]);

      expect(r.ttsStatus.mode, 'stream');
      expect(r.ttsStatus.reason, 'first_delta');
    });

    test('tts_completed 产出 ttsStatus(completed) 并记下段数', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
        tts(EventTypes.ttsCompleted, {
          'parts': 3,
          'bytes': 1024,
          'duration_ms': 2500,
        }, globalSeq: 2),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.completed);
      expect(s.parts, 3);
      expect(s.isTerminal, isTrue);
    });

    test('tts_failed 产出 ttsStatus(failed) 并保留服务端文案与诊断字段', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsFailed, {
          'reason': 'synthesize_failed',
          'seq': 1,
          'message': '语音生成失败，本次文本回复不受影响。',
        }),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.failed);
      expect(s.message, '语音生成失败，本次文本回复不受影响。');
      expect(s.reason, 'synthesize_failed');
      expect(s.isTerminal, isTrue);
    });

    test('stream 终态失败：completed_parts 作为 parts，并带 failed_part/lost_chars', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsFailed, {
          'parts': 5,
          'bytes': 900,
          'duration_ms': 1000,
          'reason': 'provider_error',
          'failed_part': 3,
          'completed_parts': 2,
          'lost_chars': 42,
          'message': '语音生成未完全成功，已生成的部分仍可播放。',
        }),
      ]);

      final s = r.ttsStatus;
      expect(s.phase, TtsPhase.failed);
      expect(s.parts, 2, reason: '失败时 parts 取 completed_parts（已完成数）');
      expect(s.failedPart, 3);
      expect(s.lostChars, 42);
    });

    test('started → completed 按顺序覆盖（回放也得到终态）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.completed,
        reason: '终态落库且顺序在后，回放历史不应停在「合成中」',
      );
    });

    test('started → failed 按顺序覆盖', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'message'}, globalSeq: 1),
        tts(EventTypes.ttsFailed, {'message': '失败了'}, globalSeq: 2),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.failed);
    });

    test('新 turn 的 user_message 清除上一轮播报状态（不粘在新一轮上）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 1),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_2',
          payload: {'input': '下一个问题'},
          globalSeq: 2,
        ),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle, reason: '上一轮的「语音已生成」不该粘在新一轮上');
      expect(r.ttsStatus.hasStatus, isFalse);
      expect(r.items, hasLength(1), reason: 'user_message 仍正常进时间线');
    });

    test('同 turn 重放的 user_message 不清掉本 turn 的播报状态', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          turnId: 'turn_1',
          payload: {'input': '问题'},
          globalSeq: 1,
        ),
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
        ev(
          EventTypes.userMessage,
          turnId: 'turn_1',
          payload: {'input': '问题'},
          globalSeq: 3,
        ),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.completed,
        reason: '同 turn 的重复 user_message 不应误清本 turn 状态',
      );
    });

    test('turnId 为空的 tts 事件被丢弃（无法按 turn 归并）', () {
      final r = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, turnId: ''),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle);
    });

    test('非 TTS 事件的通用键不被误读为播报字段', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.error,
          payload: {'message': '这不是语音失败', 'reason': 'boom'},
          globalSeq: 1,
        ),
      ]);

      expect(
        r.ttsStatus.phase,
        TtsPhase.idle,
        reason: 'error 事件的 message 不是播报文案',
      );
    });

    test('tts_started 不推进游标，终态事件推进游标', () {
      final started = EventReducer.reduce([
        tts(EventTypes.ttsStarted, {'mode': 'stream'}, globalSeq: 1),
      ]);
      expect(started.lastEventId, isEmpty, reason: 'Transient 无有效 ID');

      final completed = EventReducer.reduce([
        tts(EventTypes.ttsCompleted, {'parts': 1}, globalSeq: 2),
      ]);
      expect(
        completed.lastEventId,
        'tts_completed_2',
        reason: '终态落库，应推进游标（与 started 相反）',
      );
    });

    test('无 tts 事件时 ttsStatus 为 idle（非 null）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.message, payload: {'text': 'hi'}),
      ]);

      expect(r.ttsStatus.phase, TtsPhase.idle);
      expect(r.ttsStatus.hasStatus, isFalse, reason: 'UI 据此不渲染状态条');
    });

    test('四态齐备：idle 是显式态而非 null', () {
      // 需求列出 idle/started/completed/failed 四态。idle 不是「null 的别名」，
      // 而是可穷举的一个分支（UI 的 switch 能无 default 地覆盖它）。
      const idle = TtsStatus.idle();
      expect(idle.phase, TtsPhase.idle);
      expect(idle.turnId, isEmpty);
      expect(idle.hasStatus, isFalse);
      expect(idle.isTerminal, isFalse);
      expect(idle.at, isNull, reason: '空闲不是事件，没有时间戳');

      expect(TtsPhase.values, hasLength(4));
      expect(TtsPhase.values.map((p) => p.wire).toList(), [
        'idle',
        'started',
        'completed',
        'failed',
      ]);
    });

    test('默认归约结果就是 idle（调用方无需判空）', () {
      final r = EventReducer.reduce(const []);

      expect(r.ttsStatus.phase, TtsPhase.idle);
    });
  });
}
