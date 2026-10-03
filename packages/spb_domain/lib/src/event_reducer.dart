import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'gate_decision.dart';
import 'spec_ui.dart';
import 'tts_audio_path.dart';
import 'turn_activity.dart';

/// 把服务端事件流归约成可渲染的对话项列表。
///
/// ## 核心不变式
///
/// **同一 turn 全部 `message` 事件拼接即完整回复**（Go API 约定，`final_message`
/// 已废弃）。因此归约的关键是正确区分「增量」与「权威帧」：
///
/// | 事件形态 | `transient` | 处理方式 |
/// |---|---|---|
/// | 流式增量 | `true` | **追加**到当前段落 |
/// | 权威帧 | `false` | **替换**当前段落（段级完整文本） |
///
/// 权威帧存在的意义：增量可能在断线期间丢失，权威帧是服务端落库的完整快照，
/// 收到后应覆盖累积结果，避免残缺。
///
/// 第二条不变式：**同一 turn 只渲染一个用户气泡**。`user_message` 由客户端乐观
/// 回显与服务端广播各产生一次（同一 turnId），归约时按 turnId 原位合并。
///
/// ## 为什么是纯函数
///
/// 归约逻辑是对话 UI 的正确性核心，必须能脱离 Flutter 单测。所有状态显式传入，
/// 无隐藏可变状态（对比「在 State 里直接 mutate」的做法）。
class EventReducer {
  const EventReducer();

  /// 归约结果。
  ///
  /// [items] 按时间正序（旧 → 新）；[lastEventId] 是最后一个**落库**事件的 ID，
  /// 供 SSE 断线重连作 cursor（Transient 事件无有效 ID，不能用作游标）。
  static ReductionResult reduce(Iterable<ChatEvent> events) {
    final items = <ConversationItem>[];
    // Gate 决策走独立通道（见 ReductionResult.gateDecisions 的说明）。
    //
    // 在同一个循环里收集，而不是事后 `collectGateDecisions(events)`：
    // [events] 是 Iterable，可能是惰性流（如 `_buffer.map(...)`）；迭代两次
    // 会重算或拿到不同结果。单趟保证两个输出基于同一批事件。
    final gateDecisions = <GateDecision>[];

    // 执行中活动快照，按 turnId 取最新（见 ReductionResult.activities）。
    //
    // 同在一个循环里收集的理由与 gateDecisions 相同（单趟、同一批事件）。
    // 它**不**进 items：进度提示不是对话正文（与 webapp 的
    // `categorizeEvent('turn_activity') === 'event'` 同语义）。
    final activities = <String, TurnActivitySnapshot>{};
    var lastEventId = '';

    // 当前正在累积的 assistant 段落 / thought 段落。
    // 用索引而非对象引用，因为 copyWith 会替换对象。
    int? currentAssistantIdx;
    int? currentThoughtIdx;

    // tool_call_id → items 中的索引，用于把 tool_result 合并回对应的 call。
    final toolIdxById = <String, int>{};

    for (final ev in events) {
      if (!ev.transient && ev.eventId.isNotEmpty) {
        lastEventId = ev.eventId;
      }

      final gate = gateDecisionFrom(ev);
      if (gate != null) gateDecisions.add(gate);

      // turn_activity：按 turnId 取最新。
      //
      // WHY 在循环顶部而非 switch 分支里：`default:` 分支的语义是「控制事件，
      // 不进对话列表也不进任何通道」；放进去就等于宣称它被丢弃。它确实不产
      // items，但产出 activities——与 adaptive_decision 同样的「顶部收集 +
      // default 不管」写法（这正是修复 2927 条事件被吞时确立的取向）。
      //
      // 同 turn 多条只保留最后一条：服务端每次心跳重算 elapsed_ms，越新越准
      // （对齐 webapp chat-timeline.ts 的 `group.activity = {...}` 覆盖写）。
      final activity = TurnActivitySnapshot.fromEvent(ev);
      if (activity != null) activities[activity.turnId] = activity;

      switch (ev.eventType) {
        case EventTypes.userMessage:
          // 用户消息（每个 turn 的首个事件，见 Go 侧 `chat/enqueue.go`）。
          //
          // 正文在 `payload['input']`，**不在** `payload['text']`——故不能直接用
          // [ChatEvent.text]（它对 user_message 恒为空串）。
          final text = _userMessageText(ev);
          if (text.isEmpty) break;

          // 去重：`enqueue.go` 把 user_message 放进 `broadcasts`，即服务端**会**
          // 通过 SSE 推它；而 [ChatStreamController.send] 已用**同一 turnId** 插过
          // 一条乐观回显。不做去重就会渲染出「本地气泡 + 服务端气泡」两个。
          final existing = _indexOfUserMessage(items, ev.turnId);
          final userItem = UserMessageItem(
            id: ev.eventId,
            createdAt: ev.createdAt,
            text: text,
            turnId: ev.turnId,
          );
          if (existing != null) {
            // 原位替换：保持它排在 assistant 流式段落之前。
            items[existing] = userItem;
          } else {
            items.add(userItem);
          }

        case EventTypes.start:
          // 新 turn 开始：闭合上一段的流式状态，避免光标一直闪。
          currentAssistantIdx = null;
          currentThoughtIdx = null;

        case EventTypes.message:
          final text = ev.text;
          if (text.isEmpty) break;

          if (ev.isIncremental) {
            // 增量帧：追加。
            final idx = currentAssistantIdx;
            if (idx != null && items[idx] is AssistantMessageItem) {
              final prev = items[idx] as AssistantMessageItem;
              items[idx] = prev.copyWith(
                text: prev.text + text,
                isStreaming: true,
              );
            } else {
              currentAssistantIdx = items.length;
              items.add(
                AssistantMessageItem(
                  id: ev.eventId,
                  createdAt: ev.createdAt,
                  text: text,
                  turnId: ev.turnId,
                  isStreaming: true,
                  agentId: ev.agentId,
                ),
              );
            }
          } else if (ev.isAuthoritativeFrame) {
            // 权威帧：替换整段。若当前无段落则新建。
            final idx = currentAssistantIdx;
            if (idx != null && items[idx] is AssistantMessageItem) {
              items[idx] = (items[idx] as AssistantMessageItem).copyWith(
                text: text,
                isStreaming: false,
              );
            } else {
              currentAssistantIdx = items.length;
              items.add(
                AssistantMessageItem(
                  id: ev.eventId,
                  createdAt: ev.createdAt,
                  text: text,
                  turnId: ev.turnId,
                  isStreaming: false,
                  agentId: ev.agentId,
                ),
              );
            }
          } else {
            // 非流式 message（如历史 timeline 里的完整消息）：独立成项。
            currentAssistantIdx = items.length;
            items.add(
              AssistantMessageItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                text: text,
                turnId: ev.turnId,
                isStreaming: false,
                agentId: ev.agentId,
              ),
            );
          }

        case EventTypes.thought:
          final text = ev.text;
          if (text.isEmpty) break;
          if (ev.isIncremental) {
            final idx = currentThoughtIdx;
            if (idx != null && items[idx] is ThoughtItem) {
              final prev = items[idx] as ThoughtItem;
              items[idx] = prev.copyWith(
                text: prev.text + text,
                isStreaming: true,
              );
            } else {
              currentThoughtIdx = items.length;
              items.add(
                ThoughtItem(
                  id: ev.eventId,
                  createdAt: ev.createdAt,
                  text: text,
                  turnId: ev.turnId,
                  isStreaming: true,
                ),
              );
            }
          } else {
            currentThoughtIdx = items.length;
            items.add(
              ThoughtItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                text: text,
                turnId: ev.turnId,
                isStreaming: false,
              ),
            );
          }

        case EventTypes.toolCall:
          // 工具调用是**段落边界**：pigo 多轮工具调用时，每个工具轮各自产生一份
          // 完整的权威 message 帧（`pigo_core.go` 的 `segmentFlushed` 在
          // `turn_start`/`turn_end` 重置），而 Go 侧明确约定
          // 「最终回复 = 同 turn 全部 message 权威帧拼接」。
          //
          // 因此这里必须闭合当前 assistant/thought 段落。否则下一轮的权威帧会
          // 走 `currentAssistantIdx` 的「替换」分支，把上一轮的文本整个覆盖掉——
          // 表现为多轮工具调用的回复只剩最后一段，中间内容静默丢失。
          currentAssistantIdx = null;
          currentThoughtIdx = null;

          final callId = ev.toolCallId ?? ev.eventId;
          toolIdxById[callId] = items.length;
          items.add(
            ToolCallItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              name: ev.toolName ?? 'unknown',
              turnId: ev.turnId,
              args: ev.toolArgs,
              isComplete: false,
            ),
          );

        case EventTypes.toolResult:
          final callId = ev.toolCallId;
          final idx = callId == null ? null : toolIdxById[callId];
          final output = ev.toolOutput ?? ev.text;
          if (idx != null && idx < items.length && items[idx] is ToolCallItem) {
            items[idx] = (items[idx] as ToolCallItem).copyWith(
              output: output,
              isComplete: true,
            );
          } else {
            // 结果先于调用到达（或缺失 call）——独立成项，不丢弃信息。
            items.add(
              ToolCallItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                name: ev.toolName ?? 'unknown',
                turnId: ev.turnId,
                output: output,
                isComplete: true,
              ),
            );
          }

        case EventTypes.error:
          items.add(
            ErrorItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              message: ev.errorMessage ?? '未知错误',
              turnId: ev.turnId,
            ),
          );

        case EventTypes.done:
          // 终态：闭合所有流式段落。
          currentAssistantIdx = null;
          currentThoughtIdx = null;
          _sealStreaming(items);

        case EventTypes.routingSelected:
          // 只在与用户可见归属相关时展示；`auto` 且无 group 变化的场景由 UI 过滤。
          items.add(
            RoutingNoticeItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              groupId: ev.routingGroupId,
              reason: ev.routingReason,
            ),
          );

        case EventTypes.confirmationRequired:
          items.add(
            ConfirmationItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              question: ev.text.isNotEmpty
                  ? ev.text
                  : (ev.payload?['question']?.toString() ?? '需要确认'),
              options: _stringList(ev.payload?['options']),
              // ⚠️ 卡行 id，**不是** ev.eventId。两者由服务端独立生成：
              // `emitConfirmationRequired` 给事件 `ID: NewID()`，而卡行 id 来自
              // `EnsureConfirmationCard` 并作为 `confirmation_id` 放进 payload。
              // 用 ev.eventId 调 resolve 会 404（0 行受影响，无报错）。
              confirmationId: ev.payload?['confirmation_id']?.toString() ?? '',
              // group_id 必须带上：真实 resolve 路径是
              // /api/chat/groups/:group_id/confirmations/:id/resolve（issue #1）。
              // SSE 是 user 级订阅，事件自带的 groupId 就是该卡所属对话。
              groupId: ev.groupId,
            ),
          );

        case EventTypes.confirmationResolved:
        case EventTypes.confirmationExpired:
          // 两者都意味着「这张确认卡不再可交互」，UI 处理相同（置灰/隐藏按钮），
          // 故共用同一段标记逻辑：
          //   - confirmation_resolved：用户已作答；
          //   - confirmation_expired：超时作废（`turn_worker.go` 的
          //     `writeConfirmationExpired`，由 TTL 回收触发）。
          _markConfirmationResolved(items, ev.turnId);

        case EventTypes.followUpSuggested:
          final suggestions = ev.followUpSuggestions;
          if (suggestions.isNotEmpty) {
            items.add(
              FollowUpSuggestionItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                turnId: ev.turnId,
                suggestions: suggestions,
                // 按下标对位：agent_id 是 omitempty，历史建议缺失为 null
                // （不切 agent，保持原行为）。长度不一致时 agentIdAt 越界
                // 返回 null，不会错位到别的建议上。
                agentIds: ev.followUpAgentIds,
              ),
            );
          }

        case EventTypes.goalGateDecision:
          // 目标进度卡：只渲染 spec_schema 能解析出来的情形——解析失败（形状
          // 漂移/损坏）时**不产出该项**，时间线其余部分照常。
          // 与 webapp 同语义：每 turn 取最后一条（多轮续跑只展示最新进度），
          // 故同 turn 已有时替换。
          final doc = parseSpecUi(ev.specSchema);
          if (doc != null) {
            _upsertGoalProgress(
              items,
              GoalProgressItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                turnId: ev.turnId,
                spec: doc,
              ),
            );
          }

        case EventTypes.routingFeedbackRequest:
          // 归属反馈请求：turn **完成后**问用户「这条消息归到这个对话对吗」。
          // 语义真源在 payload 的 question/options[]（spec 是服务端另一路呈现，
          // 客户端忽略是设计内路径，见 FeedbackRequestItem 的类文档）。
          //
          // token 缺失时仍然入表（服务端不变量是「产出事件 ⇒ 必有 token」，
          // 缺失属异常载荷），但 canResolve=false，UI 会禁用按钮。
          _upsertFeedbackRequest(
            items,
            FeedbackRequestItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              token: ev.feedbackToken,
              question: ev.feedbackQuestion,
              options: ev.feedbackOptions,
              chosenGroupId: ev.feedbackChosenGroupId,
              evaluatedTurnId: ev.feedbackEvaluatedTurnId ?? ev.turnId,
            ),
          );

        case EventTypes.routingFeedback:
          // 用户已作答（服务端 CAS 消费成功后写的标注事件）。把被评价 turn 上的
          // 请求标记为已解决。payload 里**没有** token/事件 id，唯一的可靠匹配键
          // 是 turnId（事件附在被评价的 turn 上，与请求的 evaluated_turn_id 相同；
          // 见 Go classify_feedback_resolve.go 的 appendTurnEvent(target.TurnID…)）。
          _markFeedbackResolved(items, ev.turnId);

        case EventTypes.agentFileCreated:
        case EventTypes.agentFileModified:
        case EventTypes.agentFileDeleted:
          _mergeAgentFile(items, ev);

        case EventTypes.habitSuggestionCreated:
          // 习惯候选建议：服务端检测到周期性行为后发的事件，是用户看到建议卡
          // 的**唯一**入口（webapp / 小程序均渲染）。
          //
          // 之前该事件落到 `default:` 分支被静默丢弃——同 `agent.file.*` 曾被
          // 吐掉 2927 条的缺陷类别。显式分支是本次修复的核心。
          //
          // payload 不完整（无 suggestion_id）时**不产出该项**：没有身份键
          // 就无法与后续 resolved 合并，也无法提交 accept/dismiss。
          final suggestion = HabitSuggestion.fromEventPayload(
            ev.payload ?? const {},
            groupId: ev.groupId,
            userId: ev.userId,
            createdAt: ev.createdAt,
          );
          if (suggestion != null) {
            _upsertHabitSuggestion(
              items,
              HabitSuggestionItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                turnId: ev.turnId,
                suggestionId: suggestion.id,
                topicKey: suggestion.topicKey,
                triggerType: suggestion.triggerType,
                triggerConfig: suggestion.triggerConfig,
                preferredAgentId: suggestion.preferredAgentId,
                targetAcceptanceLevel: suggestion.targetAcceptanceLevel,
                confidence: suggestion.confidence,
                reasons: suggestion.reasons,
                evidence: suggestion.evidence,
                editableFields: suggestion.editableFields,
              ),
            );
          }

        case EventTypes.habitSuggestionResolved:
          // 就地更新已存在的建议卡（同一 suggestion_id）。
          //
          // 找不到对应的 created 时**不新建卡**：resolved 不带 rule_draft，
          // 凭它建出来的卡会缺 topic_key / 触发配置（渲染成一张空白卡）。
          // 正常情形下 created 总在 resolved 之前（同一 turn，按 seq 排序），
          // 找不到说明调用方只归约了部分事件窗口（如 SSE cursor 从中间接入）。
          _applyHabitSuggestionResolved(items, ev);

        default:
          // heartbeat / queue_state / gate_evaluated / gate_completed /
          // gate_error / tts_* / goal_gate_stopped / schedule_created 等控制事件
          // 不进入对话列表，也不进 gate 决策通道。
          //
          // ⚠️ `adaptive_decision` / `goal_gate_decision` **不在**本分支的
          // 「丢弃」之列：它们已在循环顶部经 `gateDecisionFrom(ev)` 收进 gate
          // 决策通道（见 ReductionResult.gateDecisions）。这正是修复前的缺口——
          // 常量已在 EventTypes 声明，但归约器把这两类连同上面的噪声事件一起
          // 静默丢弃了。
          //
          // ⚠️ 该分支也**不**包含 `agent.file.*`（已在上方 case 处理）。
          // 在 agent 文件卡接入前，本分支曾吞掉 2927 条 agent 产物事件——
          // 原注释声称「如连接指示器、TTS 播放器」会消费，但客户端
          // **从来没有** TTS 播放器（`grep tts|audioPlayer` 零命中），
          // 误导性的「托底」比没有注释更糟（会让排障者以为有处理而放过泄漏）。
          break;
      }
    }

    return ReductionResult(
      items: items,
      lastEventId: lastEventId,
      gateDecisions: gateDecisions,
      activities: activities,
    );
  }

  /// 插入或替换目标进度卡（同 turn 幂等，与 webapp「每 turn 取最后一条」一致）。
  ///
  /// 多轮续跑会产生多条 goal_gate_decision（每轮一条），不替换的话时间线
  /// 会堆一堆过期进度。以事件 id 为身份键：replace 后 [GoalProgressItem.id]
  /// 保持**最新那条的 id**（列表 diff 以它为准）。
  static void _upsertGoalProgress(
    List<ConversationItem> items,
    GoalProgressItem incoming,
  ) {
    if (incoming.turnId.isNotEmpty) {
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (it is GoalProgressItem && it.turnId == incoming.turnId) {
          items[i] = incoming;
          return;
        }
      }
    }
    items.add(incoming);
  }

  /// 插入或更新习惯建议卡（按 suggestionId 幂等）。
  ///
  /// ## 为什么不用 turnId 作幂等键
  ///
  /// 同一 turn 上可能有多条不同的建议（不同 suggestion_id），也可能一条
  /// created + 一条 resolved。按 turnId 合并会把不同建议错并成一张。
  ///
  /// ## 重放时保留先到者的 createdAt
  ///
  /// SSE cursor 回放与 timeline 回填交叠时同一事件会到达两次。若每次都把
  /// createdAt 换成新值，列表排序会因重放而漂移（用户看到卡片位置跳动）。
  /// 故更新时保留原卡的 createdAt 与 id。
  static void _upsertHabitSuggestion(
    List<ConversationItem> items,
    HabitSuggestionItem incoming,
  ) {
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it is HabitSuggestionItem &&
          it.suggestionId == incoming.suggestionId) {
        items[i] = incoming.copyWith(
          // 保留已处理状态：resolved 先于 created 到达的反常序下，
          // 不能因为来了一个「未处理」的 created 就把已处理重置。
          userFeedback: it.userFeedback,
          resolvedPatternId: it.resolvedPatternId,
          snoozeUntil: it.snoozeUntil,
        );
        return;
      }
    }
    items.add(incoming);
  }

  /// 把 `habit_suggestion_resolved` 应用到已存在的建议卡上。
  ///
  /// 无匹配卡时**什么都不做**（不新建）——resolved 不带 `rule_draft`，
  /// 新建出来的卡会缺 topic_key 与触发配置。见调用点的说明。
  static void _applyHabitSuggestionResolved(
    List<ConversationItem> items,
    ChatEvent ev,
  ) {
    final suggestionId = ev.habitSuggestionId;
    if (suggestionId == null) return;
    // `action` 是请求动作（accept/dismiss/snooze/edit_and_accept），
    // `user_feedback` 是写库值（accepted/dismissed/snoozed）。
    // 优先读 user_feedback；缺失时从 action 推（兼容旧载荷）。
    final feedback =
        HabitUserFeedback.from(ev.habitUserFeedback) ??
        HabitUserFeedback.from(
          HabitSuggestionAction.from(ev.habitResolvedAction)?.feedback,
        );
    if (feedback == null) return;
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it is HabitSuggestionItem && it.suggestionId == suggestionId) {
        items[i] = it.copyWith(
          userFeedback: feedback,
          resolvedPatternId: ev.habitResolvedPatternId,
          snoozeUntil: ev.habitSnoozeUntil,
        );
        return;
      }
    }
  }

  /// 插入或替换归属反馈请求（同 turn 幂等）。
  ///
  /// ## 为什么按 evaluatedTurnId 幂等
  ///
  /// 服务端用 partial unique index（迁移 0025）保证同一 turn 只有一条反馈
  /// 请求；但客户端会看到**重放**（SSE cursor 回放 + timeline 回填的交叠窗口）。
  /// 不幂等的话，同一次登录会出现两张同问题卡片。
  ///
  /// 同 turn 已有请求时**保留原卡、不新增**（服务端也只存一条）；若新事件的
  /// 字段更完整（如历史回填先到的是无 token 的降级载荷），就地更新原卡——
  /// createdAt 取原卡的（排序不应因重放漂移）。
  static void _upsertFeedbackRequest(
    List<ConversationItem> items,
    FeedbackRequestItem incoming,
  ) {
    // evaluatedTurnId 语义优先（它与请求事件的 turnId 可以不同）；
    // 请求事件必挂在一个 turn 上，故回退后非空。
    final turnKey = incoming.evaluatedTurnId ?? incoming.turnId;
    if (turnKey.isNotEmpty) {
      for (var i = 0; i < items.length; i++) {
        final it = items[i];
        if (it is! FeedbackRequestItem) continue;
        final existingKey = it.evaluatedTurnId ?? it.turnId;
        if (existingKey == turnKey) {
          // 同 turn 已有：保留原卡身份，仅当新载荷更完整时补字段。
          if (it.token.isEmpty && incoming.token.isNotEmpty) {
            items[i] = FeedbackRequestItem(
              id: it.id,
              createdAt: it.createdAt,
              turnId: it.turnId,
              token: incoming.token,
              question: incoming.question.isNotEmpty
                  ? incoming.question
                  : it.question,
              options: incoming.options.isNotEmpty
                  ? incoming.options
                  : it.options,
              chosenGroupId: it.chosenGroupId ?? incoming.chosenGroupId,
              evaluatedTurnId: it.evaluatedTurnId,
              resolved: it.resolved,
            );
          }
          return;
        }
      }
    }
    items.add(incoming);
  }

  /// 把 [turnId] 上的归属反馈请求标记为已答。
  ///
  /// 与 [_markConfirmationResolved] 同构：从后往前找第一条同 turn 且未解决的
  /// 请求。[turnId] 为空时退化为「最近一条未解决」（历史数据或异常事件下
  /// 宁可多标一张，也不静默丢掉状态变更）。
  static void _markFeedbackResolved(
    List<ConversationItem> items,
    String turnId,
  ) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is! FeedbackRequestItem || it.resolved) continue;
      // 匹配键是被评价的 turn（与请求事件的 evaluated_turn_id 一致），
      // 其次退而用请求事件自身的 turnId（两者通常相同）。
      final matches =
          turnId.isNotEmpty &&
          (it.evaluatedTurnId == turnId || it.turnId == turnId);
      if (!matches) continue;
      items[i] = it.copyWith(resolved: true);
      return;
    }
  }

  /// 把 [turnId] 上最近一条未解决的确认卡标记为已解决。
  ///
  /// ## 为什么必须按 turnId 匹配
  ///
  /// 原实现（内联在 `confirmationResolved` 分支里）只找「最近一条未解决」，
  /// 并不校验 turn 归属，而注释却写着「按 turnId 匹配」——两者不一致。
  ///
  /// 这个缺口在 `confirmationExpired` 接入后**会真的出错**：该事件由 turn worker
  /// 按 turn 发出（`writeConfirmationExpired(ctx, turn)`），当多个 turn 同时挂着
  /// 确认卡时，A 的过期事件会把 B 的卡片误标为已解决。故此处补上归属校验。
  ///
  /// [turnId] 为空时（历史数据或异常事件）退化为「最近一条未解决」，
  /// 宁可多标一张也不静默丢掉状态变更。
  static void _markConfirmationResolved(
    List<ConversationItem> items,
    String turnId,
  ) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is! ConfirmationItem || it.resolved) continue;
      if (turnId.isNotEmpty && it.turnId != turnId) continue;
      items[i] = ConfirmationItem(
        id: it.id,
        createdAt: it.createdAt,
        turnId: it.turnId,
        question: it.question,
        options: it.options,
        resolved: true,
        // 必须带上卡行 id 与 groupId：标记已解决只是渲染状态，而 resolve 调用
        // 两者都需要（路径含 group_id，见 issue #1）。
        // 若此处丢失，同一 turn 上「先解决的卡」会退化为不可 resolve 的项
        // （例如重绘后 UI 需要重新读取该卡）。
        confirmationId: it.confirmationId,
        groupId: it.groupId,
      );
      return;
    }
  }

  /// `user_message` 的正文：优先 `payload['input']`，回退 [ChatEvent.text]。
  ///
  /// 只接受 String 与数字的字符串形式（`input` 恒为字符串，但防御异常载荷）。
  static String _userMessageText(ChatEvent ev) {
    final raw = ev.payload?['input'];
    if (raw is String) return raw;
    if (raw != null) return raw.toString();
    return ev.text;
  }

  /// 找同一 turn 上已有的用户消息项（用于乐观回显与服务端事件的去重）。
  ///
  /// 倒序扫描：取最近一条，与其余「按 turn 闭合」的逻辑保持一致的取向。
  static int? _indexOfUserMessage(List<ConversationItem> items, String turnId) {
    if (turnId.isEmpty) return null;
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is UserMessageItem && it.turnId == turnId) return i;
    }
    return null;
  }

  /// 把仍在 streaming 的段落标记为完成（收到 done 或流中断时调用）。
  static void _sealStreaming(List<ConversationItem> items) {
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it is AssistantMessageItem && it.isStreaming) {
        items[i] = it.copyWith(isStreaming: false);
      } else if (it is ThoughtItem && it.isStreaming) {
        items[i] = it.copyWith(isStreaming: false);
      } else if (it is ToolCallItem && !it.isComplete) {
        // 未收到结果的工具调用标记为完成（带提示），避免 UI 永远转圈。
        items[i] = it.copyWith(isComplete: true, output: '(无输出)');
      }
    }
  }

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
  }

  /// TTS 语音产物路径前缀（复用 `deliverable_sync.ttsRelPrefix` 的同一约定）。
  //
  // 这类文件渲染为**语音条目**（而非普通文件卡）：回复正文（reply）展开显示，
  // 思考填充语（narration）默认折叠——全部展开会淹没对话。
  // 详见 [parseTTSAudioPath] 与 [AgentFileItem.ttsKind]。
  static const _ttsProductPrefix = 'reports/tts/';

  /// 阶段优先级（action 取最新态）：deleted > modified > created。
  static const _fileStageRank = {'created': 0, 'modified': 1, 'deleted': 2};

  /// 合并 `agent.file.*` 事件为 [AgentFileItem]。
  //
  // 关键规则（对齐 webapp `chat-timeline.ts` 的 `byFile` + `fileIdentitySeen`
  // 双集合与 `mergeFileEventLifecycle`）：
  //
  // 1. **身份键 = 归一化 relative_path**。删除事件历史上不带 `ufs_file_id`
  //    （生产 11/11 条均缺），且同路径删除重建会换 id——用 id 收敛会把同一
  //    文件拆成多张卡。
  // 2. **created/modified 无 fileId 则跳过**（对齐 webapp：`if (!isDeleted &&
  //    !fileId) continue`）。删除事件例外，因为它本就没有 fileId。
  // 3. **位置锚点 = 首次出现**（items 中首次插入的位置）。后续事件原地更新
  //    同一张卡，不跳动位置。
  // 4. **action 取阶段更高者**（deleted > modified > created），避免乱序到达
  //    时 action 退回 created。
  // 5. **展示属性取最新非空**：fileId / mimeType / sizeBytes 被后续事件的非空
  //    值覆盖，但不被空值冲掉（删除事件无 fileId，不能把创建时的 id 冲掉）。
  // 6. **lifecycle 累积时间点**：created 锁定首次 createdAt，modified/deleted
  //    记各自时间。
  // 7. **TTS 产物**：渲染为语音条目（设置 [AgentFileItem.ttsKind]），
  //    而非跳过。前缀匹配仅识别 `reports/tts/` 下的音频；parseTTSAudioPath
  //    解析不出（如 turn_id 含非法字符）的回落为普通文件卡（ttsKind=null）。
  static void _mergeAgentFile(List<ConversationItem> items, ChatEvent ev) {
    final action = ev.agentFileAction;
    if (action == null) return; // 未来新增的 agent.file.* 子类型：暂不处理

    final relPath = ev.relativePath;
    final identity = _normalizeRelPath(relPath);
    if (identity.isEmpty) return;

    // TTS 产物判定（前缀锚定开头）。解析不出 kind 则标记为语音条目；
    // 解析不出（异常路径）回落为普通文件卡，不丢弃。
    final TtsStreamKind? ttsKind = relPath.startsWith(_ttsProductPrefix)
        ? parseTTSAudioPath(relPath)?.kind
        : null;

    // 删除事件无 fileId 是正常的；created/modified 无 fileId 则是异常载荷，跳过。
    final isDeleted = action == 'deleted';
    if (!isDeleted && (ev.ufsFileId == null || ev.ufsFileId!.isEmpty)) return;

    final fileName = _basename(identity);
    final displayName = ev.displayName.isEmpty ? fileName : ev.displayName;

    final existingIdx = _indexOfAgentFile(items, identity);
    if (existingIdx == null) {
      // 首次出现：插入新卡。
      items.add(
        AgentFileItem(
          id: identity,
          createdAt: ev.createdAt,
          turnId: ev.turnId,
          relativePath: relPath,
          fileName: fileName,
          displayName: displayName,
          action: action,
          ufsFileId: ev.ufsFileId,
          mimeType: ev.mimeType,
          sizeBytes: ev.sizeBytes,
          ttsKind: ttsKind,
          modifiedAt: action == 'modified' ? ev.createdAt : null,
          deletedAt: action == 'deleted' ? ev.createdAt : null,
        ),
      );
      return;
    }

    // 原地合并：保持首次出现的位置锚点与 createdAt，更新最新态。
    final prev = items[existingIdx] as AgentFileItem;
    final prevRank = _fileStageRank[prev.action] ?? 0;
    final nextRank = _fileStageRank[action] ?? 0;
    final mergedAction = nextRank >= prevRank ? action : prev.action;

    items[existingIdx] = AgentFileItem(
      id: prev.id,
      createdAt: prev.createdAt,
      turnId: prev.turnId,
      relativePath: relPath.isEmpty ? prev.relativePath : relPath,
      fileName: fileName.isEmpty ? prev.fileName : fileName,
      displayName: displayName.isEmpty ? prev.displayName : displayName,
      action: mergedAction,
      // 取最新非空（删除事件无 fileId，不冲掉创建时的 id）。
      ufsFileId: (ev.ufsFileId != null && ev.ufsFileId!.isNotEmpty)
          ? ev.ufsFileId
          : prev.ufsFileId,
      mimeType: ev.mimeType ?? prev.mimeType,
      sizeBytes: ev.sizeBytes ?? prev.sizeBytes,
      ttsKind: ttsKind ?? prev.ttsKind,
      modifiedAt: action == 'modified' ? ev.createdAt : prev.modifiedAt,
      deletedAt: action == 'deleted' ? ev.createdAt : prev.deletedAt,
    );
  }

  /// 取路径 basename（`a/b.md` → `b.md`）。与 `ChatEvent.displayName` 不同，
  /// 这里**不读 nice_name**：[AgentFileItem.fileName] 始终是真实文件名，
  /// 给预览类型判定 / UFS 跳转用；展示名另走 [AgentFileItem.displayName]。
  static String _basename(String identity) {
    if (identity.isEmpty) return '';
    final i = identity.lastIndexOf('/');
    return i >= 0 ? identity.substring(i + 1) : identity;
  }

  /// 取最近一张。
  static int? _indexOfAgentFile(List<ConversationItem> items, String identity) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is AgentFileItem && it.id == identity) return i;
    }
    return null;
  }

  /// 归一化相对路径（对齐 webapp `normalizeRelPath`）。
  static String _normalizeRelPath(String path) {
    return path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceFirst(RegExp(r'/+$'), '');
  }
}

/// 归约输出。
class ReductionResult {
  const ReductionResult({
    required this.items,
    required this.lastEventId,
    this.gateDecisions = const [],
    this.activities = const {},
  });

  final List<ConversationItem> items;

  /// 最后一个落库事件的 ID，用作 SSE 重连 cursor。
  final String lastEventId;

  /// Gate 决策（`adaptive_decision` / `goal_gate_decision`）单独通道。
  ///
  /// ## 为什么不在 [items] 里
  ///
  /// 时间线只放用户可见的对话内容（见 `ConversationItem` 类文档）。
  /// Gate 决策是控制流诊断信息，夹在消息之间会干扰阅读，但又是
  /// 「agent 为什么自己又跑了一轮」的关键排障依据。故走独立通道，
  /// 由侧边栏诊断面板消费（对齐 webapp `WorkbenchGatePanel`）。
  final List<GateDecision> gateDecisions;

  /// 执行中活动快照（`turn_activity`），按 turnId 索引。
  ///
  /// ## 为什么不在 [items] 里
  ///
  /// 与 [gateDecisions] 同因：时间线只放用户可见的对话内容。进度提示是
  /// **状态指示**——它每 15s 刷新一次，进时间线会不断插入/更新条目、把对话
  /// 冲得七零八落，而且历史回放时早已过期（Transient 不落库，故断线重连后
  /// 本映射为空，需等下一个心跳）。故走独立通道，由对话页在空窗期消费。
  ///
  /// ## 为什么是 Map 而不是 List
  ///
  /// 语义是「每个 turn 当前的活动状态」，同 turn 多条只保留最新（越新越准）。
  /// Map 天然表达这一点，消费方按 turnId 直查，无需自己扫描去重。
  ///
  /// 值为 null 与「不存在该键」等价（都用 `activities[turnId]` 取）。
  final Map<String, TurnActivitySnapshot> activities;
}
