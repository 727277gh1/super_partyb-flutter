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

  /// EventReducer 归约：习惯 / 目标 / 诊断通知
  ///
  /// ⚠️ 本文件由 `event_reducer_test.dart` 按 **group 边界**拆出（issue #48）——
  /// 纯移动，**未改动任何断言**。`ev(...)` 辅助函数在每份文件里各带一份
  /// （同 `chat_stream_controller_stale_test.dart` 的既有先例：Dart 的测试
  /// 辅助无法跨文件共享，除非进 `lib/`——那会让测试代码进生产产物）。

  /// 习惯建议事件（`habit_suggestion_created` / `habit_suggestion_resolved`）。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 这两个事件不在 `chatbus/broker.go` 里（由 `habit.TimelineEmitter` 用字面量
  /// 直接广播），若只对着 broker.go 做镜像就会漏掉它们，于是事件落到归约器的
  /// `default:` 分支被**静默丢弃**——用户永远看不到建议卡，且没有任何报错
  /// （与 `agent.file.*` 曾被吞 2927 条是同一类缺陷）。
  group('habit 建议 → HabitSuggestionItem', () {
    /// `BuildSuggestionCreatedPayload` 的真实形状。
    Map<String, dynamic> createdPayload({String id = 'run-sugg-1'}) => {
      'suggestion_id': id,
      'habit_pattern_id': null,
      'status': 'pending',
      'trigger_type': 'time_based',
      'recommendation': {
        'action': 'accept_rule',
        'confidence': 0.72,
        'reasons': ['每周一你都会让我写周报'],
      },
      'rule_draft': {
        'topic_key': 'weekly-report',
        'trigger_type': 'time_based',
        'trigger_config': {
          'hour': 9,
          'weekday': [1],
        },
        'preferred_agent_id': 'agt-1',
        'delivery_group_id': 'grp-1',
        'target_acceptance_level': 'suggest_only',
      },
      'evidence': {'occurrences': 3},
      'editable_fields': ['topic_key', 'trigger_config'],
    };

    test('created 产出建议卡（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
      ]);

      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<HabitSuggestionItem>());
      final s = item as HabitSuggestionItem;
      expect(s.suggestionId, 'run-sugg-1');
      expect(s.topicKey, 'weekly-report');
      expect(s.triggerType, HabitTriggerType.timeBased);
      expect(s.triggerConfig!.time!.firstHour, 9);
      expect(s.preferredAgentId, 'agt-1');
      expect(s.targetAcceptanceLevel, HabitAcceptanceLevel.suggestOnly);
      expect(s.confidence, 0.72);
      expect(s.reasons, hasLength(1));
      expect(s.canResolve, isTrue, reason: '未反馈时应可操作');
      expect(s.isAccepted, isFalse);
    });

    test('缺 suggestion_id 的载荷不产出项（无身份键不可操作）', () {
      final payload = createdPayload()..remove('suggestion_id');
      final r = EventReducer.reduce([
        ev(EventTypes.habitSuggestionCreated, payload: payload),
      ]);
      expect(r.items, isEmpty);
    });

    test('resolved 就地更新同一张卡（按 suggestionId 而非 turnId）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionResolved,
          // 同一 turn：服务端 resolve 时重新取该 group 最近一条 turn。
          payload: {
            'suggestion_id': 'run-sugg-1',
            'status': 'resolved',
            'action': 'accept',
            'user_feedback': 'accepted',
            'resolved_pattern_id': 'hp-new',
            'snooze_until': null,
            'topic_key': 'weekly-report',
          },
          globalSeq: 2,
        ),
      ]);

      // 关键：仍然只有一张卡（不是 created 一张 + resolved 一张）。
      expect(r.items, hasLength(1));
      final s = r.items.single as HabitSuggestionItem;
      expect(s.userFeedback, HabitUserFeedback.accepted);
      expect(s.resolvedPatternId, 'hp-new');
      expect(s.canResolve, isFalse, reason: '已处理应禁用按钮');
      expect(s.isAccepted, isTrue);
      // 草稿信息不应因 resolved 而丢失。
      expect(s.topicKey, 'weekly-report');
      expect(s.triggerConfig!.time!.firstHour, 9);
    });

    test('resolved 无对应 created 时不新建空白卡', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionResolved,
          payload: {
            'suggestion_id': 'run-orphan',
            'action': 'dismiss',
            'user_feedback': 'dismissed',
          },
        ),
      ]);
      // resolved 不带 rule_draft，凭它建卡会得到一张没有 topic_key 的空白卡。
      expect(r.items, isEmpty);
    });

    test('snooze 记下 snooze_until', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionResolved,
          payload: {
            'suggestion_id': 'run-sugg-1',
            'action': 'snooze',
            'user_feedback': 'snoozed',
            'snooze_until': '2026-10-05T00:00:00Z',
          },
          globalSeq: 2,
        ),
      ]);

      final s = r.items.single as HabitSuggestionItem;
      expect(s.userFeedback, HabitUserFeedback.snoozed);
      expect(s.snoozeUntil, isNotNull);
      expect(s.snoozeUntil!.toUtc().day, 5);
    });

    test('重放同一事件不产生重复卡（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.habitSuggestionCreated,
        payload: createdPayload(),
        globalSeq: 1,
      );
      final r = EventReducer.reduce([e, e]);
      expect(r.items, hasLength(1));
    });

    test('同一 turn 上两条不同建议各自成卡（不能按 turnId 合并）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(id: 'run-a'),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitSuggestionCreated,
          payload: createdPayload(id: 'run-b'),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      final ids = r.items.cast<HabitSuggestionItem>().map(
        (s) => s.suggestionId,
      );
      expect(ids, containsAll(['run-a', 'run-b']));
    });

    test('watch 候选按 watch 形状渲染（不显示凌晨 0 点）', () {
      final payload = createdPayload();
      payload['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_type'] = 'watch';
      (payload['rule_draft'] as Map)['trigger_config'] = {
        'cadence': {'initial_seconds': 3600},
      };

      final r = EventReducer.reduce([
        ev(EventTypes.habitSuggestionCreated, payload: payload),
      ]);

      final s = r.items.single as HabitSuggestionItem;
      expect(s.triggerType, HabitTriggerType.watch);
      expect(s.triggerConfig!.time, isNull);
      expect(s.triggerConfig!.summary, isNot(contains('00:00')));
    });
  });

  /// 习惯自动执行完成（`habit_auto_run_completed`）——习惯回环的 Reward 环。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 同 [habitSuggestionCreated]：该事件**不在** `chatbus/broker.go` 的常量表里，
  /// 只对着 broker.go 做镜像必然漏掉，于是落到归约器的 `default:` 分支被静默
  /// 丢弃——用户永远看不到「服务端帮你跑了一轮习惯」的回执。
  ///
  /// ## ⚠️ 契约来源说明
  ///
  /// Go 侧当前**不产出**本事件（`workers/habit/turn_terminal.go:35` 明说不做），
  /// 载荷形状取自 Python 的 `build_habit_auto_run_completed_payload` 与 webapp 的
  /// 解析器。这里钉住的是「事件一旦补齐，客户端能正确渲染」——即验收要求的
  /// 「事件产出对话项」。
  group('habit 自动执行 → HabitAutoRunItem', () {
    /// `build_habit_auto_run_completed_payload` 的真实形状。
    Map<String, dynamic> autoRunPayload({
      String topicKey = 'daily_review',
      String runId = 'run-1',
    }) => {
      'habit_pattern_id': 'hp-1',
      'habit_run_id': runId,
      'turn_id': 'turn_1',
      'delivery_group_id': 'grp_1',
      'topic_key': topicKey,
      'summary': 'daily review 习惯提醒已成功送达，完成本轮强化。',
    };

    test('产出习惯强化项（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.habitAutoRunCompleted, payload: autoRunPayload()),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      expect(r.items, hasLength(1));
      final item = r.items.single;
      expect(item, isA<HabitAutoRunItem>());
      final h = item as HabitAutoRunItem;
      expect(h.topicKey, 'daily_review');
      expect(h.topicLabel, 'daily review', reason: '下划线应换成空格');
      expect(h.runId, 'run-1');
      expect(h.patternId, 'hp-1');
      expect(h.turnId, 'turn_1');
    });

    test('缺 topic_key 仍产出项（身份键不是它，渲染为未命名）', () {
      final payload = autoRunPayload()..remove('topic_key');
      final r = EventReducer.reduce([
        ev(EventTypes.habitAutoRunCompleted, payload: payload),
      ]);

      // 与建议卡不同：建议卡缺 suggestion_id 必须丢弃（无身份键不可操作），
      // 本项是纯通知，没有可操作性，不应因缺展示字段而消失。
      expect(r.items, hasLength(1));
      expect((r.items.single as HabitAutoRunItem).topicLabel, '未命名习惯');
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(EventTypes.habitAutoRunCompleted, payload: autoRunPayload());
      final r = EventReducer.reduce([e, e]);
      expect(r.items, hasLength(1));
    });

    test('同一 turn 上两次不同执行各自成项（不能按 turnId 合并）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.habitAutoRunCompleted,
          id: 'evt-a',
          payload: autoRunPayload(topicKey: 'daily_review', runId: 'run-a'),
          globalSeq: 1,
        ),
        ev(
          EventTypes.habitAutoRunCompleted,
          id: 'evt-b',
          payload: autoRunPayload(topicKey: 'weekly_report', runId: 'run-b'),
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      final labels = r.items.cast<HabitAutoRunItem>().map((h) => h.topicLabel);
      expect(labels, containsAll(['daily review', 'weekly report']));
    });
  });

  /// 自动续跑排程（`schedule_created`）——Goal Gate「即将继续」的唯一可见信号。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 与 `goal_gate_stopped` 同型：`EventTypes.timelineVisible` 收录了它，而
  /// 归约器曾把它落在 `default:` 静默丢弃。后果是用户看到界面静止，无法区分
  /// 「在等一会儿接着跑」与「已经停了」——而这两个结论正是由
  /// `schedule_created` 与 `goal_gate_stopped` 分别表达的。
  ///
  /// ⚠️ 服务端**不发**绝对时间（`scheduled_at` / `next_run_at` / `run_at` 都
  /// 没有），只发相对秒数 `delay_seconds`。故断言必须落在秒数上，不能去断言
  /// 某个时间戳字段。
  group('schedule_created → ScheduleCreatedItem', () {
    test('产出排程项并带上秒数与轮次（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.scheduleCreated,
          payload: {
            'schedule_id': 'sched_1',
            'reason': 'done',
            'status': 'pending',
            'delay_seconds': 30,
            'source': 'goal_gate',
            'auto_turn_count': 2,
            'max_auto_turns': 5,
          },
        ),
      ]);

      final item = r.items.single as ScheduleCreatedItem;
      expect(item.delaySeconds, 30);
      expect(item.reason, 'done');
      expect(item.autoTurnCount, 2);
      expect(item.maxAutoTurns, 5);
      expect(item.userText, '将在 30 秒后自动继续（第 2/5 轮）');
    });

    test('缺 delay_seconds 时仍产出，且**不编造秒数**', () {
      // 异常载荷（字段缺失）不该让整条事件消失——但也不能兜底成「30 秒」：
      // 一个编造的时间会让用户真的去等它，而实际触发时刻无人知道。
      final r = EventReducer.reduce([
        ev(EventTypes.scheduleCreated, payload: {'reason': 'done'}),
      ]);

      final item = r.items.single as ScheduleCreatedItem;
      expect(item.delaySeconds, isNull);
      expect(item.userText, '已排入下一轮自动继续');
      expect(item.userText, isNot(contains('秒')));
    });

    test('缺轮次计数时只报秒数（不显示残缺的「第 /轮」）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.scheduleCreated, payload: {'delay_seconds': 45}),
      ]);

      expect((r.items.single as ScheduleCreatedItem).userText, '将在 45 秒后自动继续');
    });

    test('只有上限没有已推进数时退化为「上限 N 轮」', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.scheduleCreated,
          payload: {'delay_seconds': 10, 'max_auto_turns': 5},
        ),
      ]);

      expect(
        (r.items.single as ScheduleCreatedItem).userText,
        '将在 10 秒后自动继续（上限 5 轮）',
      );
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.scheduleCreated,
        id: 'evt_sched_1',
        payload: {'delay_seconds': 30},
      );
      // 本项不按身份键 upsert（与 GoalGateStoppedItem 同取向：排程通知是
      // 一次性事件，没有天然身份键），但控制器层的 seen 去重会滤掉同一
      // eventId——故这里只断言「单条输入产出单项」。
      //
      // 不在归约器层做 eventId 去重是有意的：`reduce` 是纯函数，同一个事件
      // 对象被传两次时按 id 去重需要维护跨调用状态，而真正会重复输入的路径
      //（SSE 回放 + timeline 回填交叠）已在控制器用 seen 集合滤掉。
      final r = EventReducer.reduce([e]);
      expect(r.items, hasLength(1));
    });
  });

  /// 目标自动推进停止（`goal_gate_stopped`）——Goal Gate 终止的唯一可见信号。
  ///
  /// ## 这个测试防的是什么
  ///
  /// `EventTypes.timelineVisible` **早已**收录 `goalGateStopped`，但归约器没有
  /// 对应 case，事件落到 `default:` 被静默丢弃——即「集合说它可见、实现却把它
  /// 丢了」。用户看到 agent 不再自动续跑却没有任何解释。
  ///
  /// 文案映射必须与 miniapp `goalGateStoppedContent()` 逐条一致，否则同一个
  /// 停止原因在手机与桌面上显示不同结论。
  group('goal_gate_stopped → GoalGateStoppedItem', () {
    test('产出停止项（不再被 default 分支丢弃）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.goalGateStopped,
          payload: {'reason': 'goal_completed', 'auto_turn_count': 3},
        ),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      final item = r.items.single;
      expect(item, isA<GoalGateStoppedItem>());
      final s = item as GoalGateStoppedItem;
      expect(s.reason, 'goal_completed');
      expect(s.message, '目标已实现，自动推进已停用');
      expect(s.turnCountLabel, '已自动推进 3 轮');
    });

    test('五种 reason 的文案与 miniapp 逐条一致', () {
      // 取值来源：Go chatgate/goal_gate.go 的三处 emit（:416 停止态、:435 目标
      // 达成、:549 熔断）与 miniapp normalize.ts:146 的映射表。
      const expected = {
        'goal_completed': '目标已实现，自动推进已停用',
        'max_auto_turns_reached': '已达自动推进轮次上限，发送新消息后可继续',
        'no_tasks': '目标尚无任务列表，请先拆解任务后再启用自动推进',
        'task_blocked': '存在受阻任务，自动推进已暂停，需人工介入',
        'task_error_stopped': '存在出错停止的任务，自动推进已暂停，需人工介入',
      };
      for (final entry in expected.entries) {
        final r = EventReducer.reduce([
          ev(EventTypes.goalGateStopped, payload: {'reason': entry.key}),
        ]);
        expect(
          (r.items.single as GoalGateStoppedItem).message,
          entry.value,
          reason: 'reason=${entry.key} 的文案漂移了',
        );
      }
    });

    test('未知 reason 走兜底但保留结论（不静默消失）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.goalGateStopped, payload: {'reason': 'brand_new_reason'}),
      ]);

      expect(r.items, hasLength(1));
      expect(
        (r.items.single as GoalGateStoppedItem).message,
        '自动推进已停止',
        reason: '服务端新增原因时不能什么都不显示',
      );
    });

    test('payload 完全缺失时仍产出项（兜底文案）', () {
      final r = EventReducer.reduce([ev(EventTypes.goalGateStopped)]);

      expect(r.items, hasLength(1));
      final s = r.items.single as GoalGateStoppedItem;
      expect(s.reason, '');
      expect(s.message, '自动推进已停止');
      expect(s.turnCountLabel, isNull, reason: '无计数时不渲染轮次行');
    });

    test('轮次文案覆盖「只有计数」「只有上限」「两者都有」', () {
      String? label(Map<String, dynamic> payload) =>
          (EventReducer.reduce([
                    ev(EventTypes.goalGateStopped, payload: payload),
                  ]).items.single
                  as GoalGateStoppedItem)
              .turnCountLabel;

      expect(label({'auto_turn_count': 2}), '已自动推进 2 轮');
      expect(label({'max_auto_turns': 10}), '上限 10 轮');
      expect(
        label({'auto_turn_count': 2, 'max_auto_turns': 10}),
        '已自动推进 2/10 轮',
      );
      expect(label({}), isNull);
    });

    test('detail 与 sessionId 类字段：空白串归 null（不渲染空白行）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.goalGateStopped,
          payload: {'reason': 'task_blocked', 'detail': '   '},
        ),
      ]);
      expect((r.items.single as GoalGateStoppedItem).detail, isNull);
    });

    test('重放同一事件不产生重复项（SSE 回放 + 回填交叠窗口）', () {
      final e = ev(
        EventTypes.goalGateStopped,
        id: 'evt_stop_1',
        payload: {'reason': 'goal_completed'},
      );
      // 本项不按身份键 upsert（与 HabitAutoRunItem 同取向：终态通知），
      // 但控制器层的 seen 去重会滤掉同一 eventId，故归约器只保证「有产出」。
      final r = EventReducer.reduce([e]);
      expect(r.items, hasLength(1));
    });
  });

  /// 会话绑定失效（`pigo_session_missing`）——诊断事件，但解释了用户可感知的
  /// 「上下文莫名丢失」。
  ///
  /// ## 这个测试防的是什么
  ///
  /// 该常量只在 `EventTypes` 声明（`pigoSessionMissing`），全仓零消费——事件
  /// 落到 `default:` 被静默丢弃。它虽标 `Diagnostic: true`（默认不广播、只落库），
  /// 但**会在拉 timeline 历史时到达**，那时它是唯一能解释「这段对话为什么断了
  /// 上下文」的线索。
  group('pigo_session_missing → DiagnosticNoticeItem', () {
    test('产出诊断项并原样透传服务端说明', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.pigoSessionMissing,
          payload: {
            'content': '检测到失效的会话绑定（历史会话文件未落盘），本次将新建会话继续',
            'session_id': 'sess-ghost-1',
            'expected_path': '/home/u/.pigo/sessions/sess-ghost-1.jsonl',
          },
        ),
      ]);

      expect(r.items, isNotEmpty, reason: '事件必须产出可见反馈');
      final item = r.items.single;
      expect(item, isA<DiagnosticNoticeItem>());
      final d = item as DiagnosticNoticeItem;
      expect(d.content, contains('失效的会话绑定'));
      expect(d.sessionId, 'sess-ghost-1');
    });

    test('content 缺失时用兜底文案仍产出（结论不丢）', () {
      final r = EventReducer.reduce([
        ev(EventTypes.pigoSessionMissing, payload: {'session_id': 's1'}),
      ]);

      expect(r.items, hasLength(1));
      final d = r.items.single as DiagnosticNoticeItem;
      expect(d.content, '检测到失效的会话绑定，本次将新建会话继续');
      expect(d.sessionId, 's1');
    });

    test('payload 完全缺失时不编造 session_id', () {
      final r = EventReducer.reduce([ev(EventTypes.pigoSessionMissing)]);

      expect(r.items, hasLength(1));
      final d = r.items.single as DiagnosticNoticeItem;
      expect(d.sessionId, isNull);
      expect(d.content, isNotEmpty);
    });

    test('诊断事件不污染时间线顺序（与用户消息共存且各成一项）', () {
      final r = EventReducer.reduce([
        ev(
          EventTypes.userMessage,
          id: 'evt_u',
          payload: {'input': '继续'},
          globalSeq: 1,
        ),
        ev(
          EventTypes.pigoSessionMissing,
          id: 'evt_d',
          payload: {'content': '会话已重建'},
          globalSeq: 2,
        ),
      ]);

      expect(r.items, hasLength(2));
      expect(r.items[0], isA<UserMessageItem>());
      expect(r.items[1], isA<DiagnosticNoticeItem>());
    });
  });
}
