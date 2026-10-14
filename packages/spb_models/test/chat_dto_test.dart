import 'package:spb_models/spb_models.dart';
import 'package:test/test.dart';

/// 聊天类 DTO 的 `fromJson` 契约测试。
///
/// ## 为什么这批模型此前零覆盖
///
/// `ChatTurn` / `ChatTurnSummary` / `ChatConfirmation` / `ChatInboxMessage` /
/// `ChatSearchHit` 都是**端点投影**（服务端各自的 `xxxToDict` / `xxxToListItem`
/// 手写键名），字段名与形状**互不相同**且都是 snake_case。它们此前没有测试，
/// 只被页面间接用到——而页面用的是「能跑就行」的路径，字段读错时**不报错**
/// （缺失键走安全默认值），于是漂移只在界面上表现为「某列一直是空的」。
///
/// 本文件按「真实服务端响应样本」驱动，每个类钉住三件事：
///
/// 1. **键名**：服务端键名拼错时解析出空值（而不是永远匹配不上的魔法字符串）；
/// 2. **缺字段/类型漂移**：不抛异常，回落安全默认值；
/// 3. **语义 getter**：状态判定（`isTerminal` / `isPending` / `isWithdrawable` …）
///    必须与状态机一致——`AGENTS.md §5.3` 记录过「英式 `cancelled` vs 美式
///    `canceled`」这类会静默判错的坑。
void main() {
  group('ChatTurn（turnToDict）', () {
    /// `turnToDict` 的真实形状（`internal/server/chat.go`）。
    Map<String, dynamic> turnJson({
      String? status,
      Object? fanout = 1,
      Object? requestId = 'req_1',
      Object? metadata,
      Object? channel = 'webapp',
      String? startedAt = '2024-03-05T08:00:01Z',
      String? endedAt = '2024-03-05T08:00:09Z',
    }) => {
      'id': 'turn_1',
      'group_id': 'grp_1',
      'user_id': 'usr_1',
      if (requestId != null) 'request_id': requestId,
      'input_text': '帮我看看',
      'status': status ?? 'running',
      'fanout_count': fanout,
      'completed_count': 0,
      'error_count': 0,
      if (metadata != null) 'metadata': metadata,
      if (channel != null) 'channel': channel,
      'created_at': '2024-03-05T08:00:00Z',
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
    };

    test('字段名是 snake_case，全部照抄服务端', () {
      final t = ChatTurn.fromJson(turnJson());

      expect(t.id, 'turn_1');
      expect(t.groupId, 'grp_1');
      expect(t.userId, 'usr_1');
      expect(t.requestId, 'req_1');
      expect(t.inputText, '帮我看看');
      expect(t.fanoutCount, 1);
      expect(t.channel, 'webapp');
      // 时间必须解析（`created_at` 解析失败会回落 `now()`，故断言它不等于 now）。
      expect(t.createdAt, DateTime.parse('2024-03-05T08:00:00Z').toLocal());
      expect(t.startedAt, DateTime.parse('2024-03-05T08:00:01Z').toLocal());
      expect(t.endedAt, DateTime.parse('2024-03-05T08:00:09Z').toLocal());
    });

    test('状态机判定：六态各自只命中一个', () {
      for (final entry in {
        'queued': 'isQueued',
        'running': 'isRunning',
        'pending': 'isPending',
        'completed': 'isCompleted',
        'failed': 'isFailed',
        'canceled': 'isCanceled',
      }.entries) {
        final t = ChatTurn.fromJson(turnJson(status: entry.key));
        final flags = {
          'isQueued': t.isQueued,
          'isRunning': t.isRunning,
          'isPending': t.isPending,
          'isCompleted': t.isCompleted,
          'isFailed': t.isFailed,
          'isCanceled': t.isCanceled,
        };
        expect(
          flags[entry.value],
          isTrue,
          reason: 'status=${entry.key} 应命中 ${entry.value}',
        );
        expect(flags.entries.where((e) => e.value).map((e) => e.key), [
          entry.value,
        ], reason: 'status=${entry.key} 不应命中其它态');
      }
    });

    test('isTerminal 只认 completed/failed/canceled', () {
      // pending（等确认）与 queued/running 都不是终态——它们还会产生事件。
      expect(
        ChatTurn.fromJson(turnJson(status: 'completed')).isTerminal,
        isTrue,
      );
      expect(ChatTurn.fromJson(turnJson(status: 'failed')).isTerminal, isTrue);
      expect(
        ChatTurn.fromJson(turnJson(status: 'canceled')).isTerminal,
        isTrue,
      );
      for (final s in ['queued', 'running', 'pending']) {
        expect(
          ChatTurn.fromJson(turnJson(status: s)).isTerminal,
          isFalse,
          reason: '$s 不是终态',
        );
      }
    });

    test('duration：已终结用 ended-started；进行中用 now-started', () {
      final done = ChatTurn.fromJson(turnJson());
      expect(done.duration, const Duration(seconds: 8));

      // 进行中（ended_at 缺失）：以当前时间计算，故只断言下界。
      final running = ChatTurn.fromJson(
        turnJson(
          status: 'running',
          startedAt: '2024-03-05T08:00:00Z',
          endedAt: null,
        ),
      );
      expect(running.duration, isNotNull);
      expect(running.duration!.inDays, greaterThan(0));
    });

    test('duration：started_at 缺失时为 null（不谎报 0）', () {
      final t = ChatTurn.fromJson(turnJson(startedAt: null));
      expect(t.duration, isNull);
    });

    test('计数是 num/字符串也归一成 int（gin 的 float64 形态）', () {
      final t = ChatTurn.fromJson(
        turnJson(fanout: 2.0)
          ..['completed_count'] = '3'
          ..['error_count'] = null,
      );
      expect(t.fanoutCount, 2);
      expect(t.completedCount, 3);
      expect(t.errorCount, 0);
    });

    test('缺字段回落安全默认值（不抛）', () {
      final t = ChatTurn.fromJson(const {});
      expect(t.id, '');
      expect(t.status, 'queued');
      expect(t.fanoutCount, 0);
      expect(t.requestId, isNull);
      expect(t.metadata, isNull);
      expect(t.channel, isNull);
      expect(t.startedAt, isNull);
      // created_at 缺失时回落到 now()（服务端不会缺，但解析要稳）。
      expect(t.createdAt, isA<DateTime>());
    });

    test('metadata 是对象时保留（非对象归一成 null）', () {
      final t = ChatTurn.fromJson(
        turnJson(
          metadata: {
            'targets': [
              {'agent_id': 'a1'},
            ],
          },
        ),
      );
      expect(t.metadata?['targets'], isA<List<dynamic>>());

      final bad = ChatTurn.fromJson(turnJson(metadata: 'not-a-map'));
      expect(bad.metadata, isNull);
    });
  });

  group('ChatTurnSummary（turnToListItem）', () {
    /// `turnToListItem` 的真实形状（`internal/server/user_turns.go`）。
    ///
    /// ⚠️ 与 `ChatTurn` 字段名**不同**：主键是 `turn_id`、文本是
    /// `input_preview`、还有 `derived_source` / `has_error` / `message_count`。
    Map<String, dynamic> summaryJson({
      String? derivedSource = 'chat',
      Object? rawSource = 'direct',
      Object? groupTitle = '某个对话',
      bool hasError = false,
      Object? messageCount = 2,
    }) => {
      'turn_id': 'turn_1',
      'group_id': 'grp_1',
      if (groupTitle != null) 'group_title': groupTitle,
      'input_preview': '帮我看看',
      'status': 'completed',
      'derived_source': derivedSource,
      if (rawSource != null) 'source': rawSource,
      'created_at': '2024-03-05T08:00:00Z',
      'started_at': '2024-03-05T08:00:01Z',
      'ended_at': '2024-03-05T08:00:09Z',
      'has_error': hasError,
      'message_count': messageCount,
    };

    test('键名是 turn_id / input_preview（不是 id / input_text）', () {
      // 若有人拿 ChatTurn.fromJson 解析这里，会得到全空对象且不报错。
      final s = ChatTurnSummary.fromJson(summaryJson());
      expect(s.turnId, 'turn_1');
      expect(s.groupId, 'grp_1');
      expect(s.groupTitle, '某个对话');
      expect(s.inputPreview, '帮我看看');
      expect(s.rawSource, 'direct');
      expect(s.messageCount, 2);
    });

    test('derived_source → TurnSource 五类映射', () {
      for (final entry in {
        'chat': TurnSource.chat,
        'mq': TurnSource.mq,
        'schedule': TurnSource.schedule,
        'habit': TurnSource.habit,
        'tool_agent': TurnSource.toolAgent,
      }.entries) {
        expect(
          ChatTurnSummary.fromJson(summaryJson(derivedSource: entry.key))
              .source,
          entry.value,
        );
      }
    });

    test('未知 / 缺失 derived_source 落到 unknown（向前兼容，不抛）', () {
      expect(
        ChatTurnSummary.fromJson(summaryJson(derivedSource: 'brand_new'))
            .source,
        TurnSource.unknown,
      );
      expect(
        ChatTurnSummary.fromJson(summaryJson(derivedSource: null)).source,
        TurnSource.unknown,
      );
    });

    test('isRunning 含 queued；isFailed 含 has_error', () {
      expect(
        ChatTurnSummary.fromJson(summaryJson()..['status'] = 'running')
            .isRunning,
        isTrue,
      );
      expect(
        ChatTurnSummary.fromJson(summaryJson()..['status'] = 'queued')
            .isRunning,
        isTrue,
      );
      expect(
        ChatTurnSummary.fromJson(summaryJson()..['status'] = 'completed')
            .isRunning,
        isFalse,
      );
      // 状态是 completed 但 error_count>0 时也判失败（服务端置 has_error）。
      expect(
        ChatTurnSummary.fromJson(summaryJson(hasError: true)).isFailed,
        isTrue,
      );
      expect(
        ChatTurnSummary.fromJson(summaryJson()..['status'] = 'failed').isFailed,
        isTrue,
      );
    });

    test('group_title 缺失时为 null（对话已删）', () {
      final s = ChatTurnSummary.fromJson(summaryJson(groupTitle: null));
      expect(s.groupTitle, isNull);
    });

    test('message_count 是字符串也归一；缺字段回 0', () {
      expect(
        ChatTurnSummary.fromJson(summaryJson(messageCount: '5')).messageCount,
        5,
      );
      final s = ChatTurnSummary.fromJson(
        summaryJson()..remove('message_count'),
      );
      expect(s.messageCount, 0);
    });
  });

  group('TurnSource：wire 与枚举名不是同名映射', () {
    test('fromServer ↔ wire 严格互逆（toolAgent ↔ tool_agent）', () {
      for (final s in const ['chat', 'mq', 'schedule', 'habit', 'tool_agent']) {
        final src = TurnSource.fromServer(s);
        expect(src.wire, s, reason: '$s 往返必须一致');
      }
    });

    test('unknown 的 wire 是空串（不是可筛选项，调用方据此跳过参数）', () {
      // 写成 `source.name` 会发出 `toolAgent`，服务端 switch 落不到分支 →
      // 过滤器静默失效。unknown 发空串是「不要筛」的信号。
      expect(TurnSource.unknown.wire, '');
    });

    test('label 是中文展示名，unknown 回「其它」', () {
      expect(TurnSource.chat.label, '对话');
      expect(TurnSource.toolAgent.label, '工具');
      expect(TurnSource.unknown.label, '其它');
    });
  });

  group('ChatConfirmation（scanConfirmationToListItem）', () {
    Map<String, dynamic> confJson({
      Object? decision,
      Object? confidence = 0.9,
      String? status,
      Object? agentId = 'agt_1',
    }) => {
      'id': 'cfm_1',
      'turn_id': 'turn_1',
      'group_id': 'grp_1',
      'user_id': 'usr_1',
      if (agentId != null) 'agent_id': agentId,
      'kind': 'continue_suggestion',
      'recommendation_action': 'continue',
      if (confidence != null) 'confidence': confidence,
      if (decision != null) 'decision': decision,
      'status': status ?? 'pending',
      'created_at': '2024-03-05T08:00:00Z',
    };

    test('基本字段与 decision 快照解析', () {
      final c = ChatConfirmation.fromJson(
        confJson(decision: {'reason': '要继续吗？', 'confidence': 0.9}),
      );
      expect(c.id, 'cfm_1');
      expect(c.turnId, 'turn_1');
      expect(c.groupId, 'grp_1');
      expect(c.kind, 'continue_suggestion');
      expect(c.recommendationAction, 'continue');
      expect(c.confidence, 0.9);
      expect(c.isPending, isTrue);
    });

    test('reason：优先 decision.reason，缺失/空白/非字符串回兜底', () {
      expect(
        ChatConfirmation.fromJson(confJson(decision: {'reason': '要继续吗？'}))
            .reason,
        '要继续吗？',
      );
      // 空白字符串也算「没有」——否则界面会显示一片空白。
      expect(
        ChatConfirmation.fromJson(confJson(decision: {'reason': '   '})).reason,
        '需要确认',
      );
      expect(
        ChatConfirmation.fromJson(confJson(decision: {'reason': 42})).reason,
        '需要确认',
      );
      expect(ChatConfirmation.fromJson(confJson()).reason, '需要确认');
    });

    test('confidence 只接受 num（字符串/缺失 → null）', () {
      expect(
        ChatConfirmation.fromJson(confJson(confidence: '0.9')).confidence,
        isNull,
      );
      expect(
        ChatConfirmation.fromJson(confJson(confidence: null)).confidence,
        isNull,
      );
    });

    test('非 pending 状态不判 pending（resolved/expired/cancelled）', () {
      for (final s in ['resolved', 'expired', 'cancelled']) {
        expect(
          ChatConfirmation.fromJson(confJson(status: s)).isPending,
          isFalse,
        );
      }
    });

    test('缺字段回安全默认值（status 缺省 pending，created_at 回 now）', () {
      final c = ChatConfirmation.fromJson(const {});
      expect(c.id, '');
      expect(c.status, 'pending');
      expect(c.agentId, isNull);
      expect(c.decision, isNull);
      expect(c.createdAt, isA<DateTime>());
    });
  });

  group('ChatInboxMessage（inboxToDict）', () {
    /// ⚠️ 键名是 `input`（不是 ChatTurn 的 `input_text`）。
    Map<String, dynamic> inboxJson({
      String? status,
      Object? groupId = 'grp_1',
      Object? turnId,
      Object? processedAt,
      Object? payload,
      Object? result,
    }) => {
      'id': 'msg_1',
      'user_id': 'usr_1',
      'input': '再来一条',
      'status': status ?? 'pending',
      'agent_type': 'pigo',
      'created_at': '2024-03-05T08:00:00Z',
      'updated_at': '2024-03-05T08:00:05Z',
      if (groupId != null) 'group_id': groupId,
      if (turnId != null) 'turn_id': turnId,
      if (processedAt != null) 'processed_at': processedAt,
      if (payload != null) 'payload': payload,
      if (result != null) 'result': result,
    };

    test('键名是 input（不是 input_text）', () {
      final m = ChatInboxMessage.fromJson(inboxJson());
      expect(m.input, '再来一条');
      expect(m.agentType, 'pigo');
      expect(m.groupId, 'grp_1');
    });

    test('四态判定 + isProcessed 与 isWithdrawable', () {
      final pending = ChatInboxMessage.fromJson(inboxJson());
      expect(pending.isPending, isTrue);
      expect(pending.isProcessed, isFalse);
      expect(pending.isWithdrawable, isTrue);

      final committed = ChatInboxMessage.fromJson(
        inboxJson(status: 'committed', turnId: 'turn_1'),
      );
      expect(committed.isCommitted, isTrue);
      expect(committed.isProcessed, isTrue);
      // 只有 pending 可撤回（服务端 WHERE status='pending'）——否则必然 404。
      expect(committed.isWithdrawable, isFalse);
      expect(committed.turnId, 'turn_1');

      expect(
        ChatInboxMessage.fromJson(inboxJson(status: 'superseded')).isSuperseded,
        isTrue,
      );
      expect(
        ChatInboxMessage.fromJson(inboxJson(status: 'withdrawn')).isWithdrawn,
        isTrue,
      );
    });

    test('空串归一成 null（服务端 iso 对零值时间产空串）', () {
      // 不归一会得到 `''` 这种「假有值」，让 `groupId == null` 的判定失效。
      final m = ChatInboxMessage.fromJson(
        inboxJson(groupId: '', processedAt: ''),
      );
      expect(m.groupId, isNull);
      expect(m.processedAt, isNull);
    });

    test('payload / result 对象保留；created_at 缺失回 now', () {
      final m = ChatInboxMessage.fromJson(
        inboxJson(
          payload: {'source': 'bridge', 'channel': 'wechat_ilink'},
          result: {'status': 'committed', 'strategy': 'merge', 'turn_id': 't1'},
          processedAt: '2024-03-05T08:00:06Z',
        ),
      );
      expect(m.payload?['channel'], 'wechat_ilink');
      expect(m.result?['strategy'], 'merge');
      expect(m.processedAt, DateTime.parse('2024-03-05T08:00:06Z').toLocal());

      final empty = ChatInboxMessage.fromJson(const {});
      expect(empty.status, 'pending');
      expect(empty.createdAt, isA<DateTime>());
      expect(empty.updatedAt, isA<DateTime>());
    });
  });

  group('ChatSearchHit（search 端点返回的是 turn 摘要）', () {
    Map<String, dynamic> hitJson({
      Object? groupTitle = '某个对话',
      Object? agentId = 'agt_1',
      Object? createdAt = '2024-03-05T08:00:00Z',
    }) => {
      'turn_id': 'turn_1',
      'group_id': 'grp_1',
      if (groupTitle != null) 'group_title': groupTitle,
      'input_text': '帮我看看',
      if (createdAt != null) 'created_at': createdAt,
      if (agentId != null) 'agent_id': agentId,
    };

    test('字段名 snake_case（turn_id / input_text）', () {
      final h = ChatSearchHit.fromJson(hitJson());
      expect(h.turnId, 'turn_1');
      expect(h.groupId, 'grp_1');
      expect(h.groupTitle, '某个对话');
      expect(h.inputText, '帮我看看');
      expect(h.agentId, 'agt_1');
      expect(h.createdAt, DateTime.parse('2024-03-05T08:00:00Z').toLocal());
    });

    test('group_title 为空 → displayTitle 兜底（归档/超上限时服务端写零值）', () {
      expect(
        ChatSearchHit.fromJson(hitJson(groupTitle: '')).displayTitle,
        '（未命名对话）',
      );
      expect(ChatSearchHit.fromJson(hitJson()).displayTitle, '某个对话');
    });

    test('agent_id 空串 → null（服务端无 targets 时返回 nil）', () {
      expect(ChatSearchHit.fromJson(hitJson(agentId: '')).agentId, isNull);
      expect(ChatSearchHit.fromJson(hitJson(agentId: null)).agentId, isNull);
    });

    test('created_at 解析失败/缺失 → null（**不回退 now()**）', () {
      // 回退 now() 会让「没有时间」的条目看起来像刚刚创建。
      expect(
        ChatSearchHit.fromJson(hitJson(createdAt: null)).createdAt,
        isNull,
      );
      expect(ChatSearchHit.fromJson(hitJson(createdAt: '')).createdAt, isNull);
      expect(
        ChatSearchHit.fromJson(hitJson(createdAt: 'not-a-date')).createdAt,
        isNull,
      );
    });

    test('raw 保留原始响应（未建模字段不丢）', () {
      final h = ChatSearchHit.fromJson(hitJson()..['extra_field'] = 1);
      expect(h.raw['extra_field'], 1);
    });
  });

  /// `toString()` 覆盖（issue #38 补）。
  ///
  /// ## 为什么值得单测
  ///
  /// 这些不是「为了凑覆盖率」的填充：`toString` 是**日志与调试输出**的唯一来源，
  /// 而它们插值的是可空字段与集合长度——`$groupTitle`（可空）、
  /// `input.length`（input 为 null 时会抛）、`${items.length}/$total` 等。
  /// 一条 `toString` 抛异常会把「本来只想打一行日志」变成二次故障，且发生位置
  /// 往往是错误处理路径（最不该再抛的地方）。
  group('toString 诊断输出（不得抛）', () {
    test('ChatSearchHit', () {
      final hit = ChatSearchHit.fromJson(const {
        'turn_id': 't1',
        'group_id': 'g1',
        'group_title': '标题',
      });
      expect(hit.toString(), contains('turn=t1'));
      expect(hit.toString(), contains('group=g1'));

      // group_title 缺失（null）时也不能抛。
      final noTitle = ChatSearchHit.fromJson(const {
        'turn_id': 't1',
        'group_id': 'g1',
      });
      expect(() => noTitle.toString(), returnsNormally);
    });

    test('ChatInboxMessage', () {
      final m = ChatInboxMessage.fromJson(const {
        'id': 'm1',
        'status': 'pending',
        'group_id': 'g1',
        'input': 'hello',
      });
      expect(m.toString(), contains('m1'));
      expect(m.toString(), contains('5 chars'));

      // input 缺失 → 空串，length 为 0（不抛）。
      final empty = ChatInboxMessage.fromJson(const {'id': 'm2'});
      expect(() => empty.toString(), returnsNormally);
    });

    test('UfsFileEntry / UfsFilePage', () {
      final e = UfsFileEntry.fromJson(const {
        'id': 'f1',
        'path': 'a/b.md',
        'size': 12,
        'etag': 'e1',
      });
      expect(e.toString(), contains('f1'));
      expect(e.toString(), contains('a/b.md'));

      // isDeleted 为真时额外带 DELETED 标记（诊断用）。
      final deleted = UfsFileEntry.fromJson(const {
        'id': 'f1',
        'path': 'a/b.md',
        'size': 12,
        'deleted_at': '2026-03-01T00:00:00Z',
      });
      expect(deleted.toString(), contains('DELETED'));

      expect(
        const UfsFilePage(items: [], total: 7).toString(),
        contains('0/7'),
      );
    });

    test('Agent / GroupSession / GroupAgentSwitchResult', () {
      expect(
        Agent.fromJson(const {'id': 'a1', 'name': '小助手'}).toString(),
        contains('a1'),
      );
      expect(
        GroupSession.fromJson(const {'id': 's1', 'agent_id': 'a1'}).toString(),
        contains('s1'),
      );
      expect(
        GroupAgentSwitchResult.fromJson(const {
          'group_id': 'g1',
          'new_agent_id': 'a2',
        }).toString(),
        contains('g1'),
      );
    });

    test('Miniapp* 一族', () {
      final progress = MiniappProgress.fromJson(const {
        'completed': 3,
        'total': 5,
      });
      expect(progress.toString(), contains('3/5'));

      final work = MiniappWork.fromJson(const {
        'id': 'w1',
        'title': 'x',
        'status': 'running',
        'progress': {'completed': 1, 'total': 2},
      });
      expect(work.toString(), contains('w1'));

      final step = MiniappStep.fromJson(const {'id': 'st1', 'status': 'done'});
      expect(step.toString(), contains('st1'));

      final artifact = MiniappArtifact.fromJson(const {
        'id': 'ar1',
        'name': 'report.md',
        'type': 'file',
      });
      expect(artifact.toString(), contains('ar1'));

      final confirmation = MiniappConfirmation.fromJson(const {
        'id': 'c1',
        'type': 'confirm',
        'status': 'pending',
      });
      expect(confirmation.toString(), contains('c1'));

      final detail = MiniappWorkDetail.fromJson(const {
        'id': 'w1',
        'status': 'running',
      });
      expect(detail.toString(), contains('w1'));

      final eventItem = MiniappEventItem.fromJson(const {
        'id': 'ev1',
        'type': 'message',
      });
      expect(eventItem.toString(), contains('ev1'));

      final workEvent = MiniappWorkEvent.fromJson(const {
        'id': 'we1',
        'event_type': 'message',
      });
      expect(workEvent.toString(), contains('we1'));

      final dispatch = MiniappDispatchResult.fromJson(const {
        'turn_id': 't1',
        'status': 'queued',
      });
      expect(dispatch.toString(), contains('t1'));

      final sub = MiniappNotificationSubscription.fromJson(const {
        'template_key': 'k1',
        'remaining_quota': 3,
      });
      expect(sub.toString(), contains('k1'));
    });

    test('PreferenceChannelOption / UserPreferences', () {
      expect(
        const PreferenceChannelOption(
          value: 'dingtalk',
          label: '钉钉',
        ).toString(),
        contains('dingtalk'),
      );
      final prefs = UserPreferences.fromJson(const {
        'reply_language': 'zh',
        'customized': true,
      });
      expect(() => prefs.toString(), returnsNormally);
    });
  });
}
