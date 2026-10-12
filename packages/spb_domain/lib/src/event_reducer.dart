import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';
import 'execution_status.dart';
import 'gate_decision.dart';
import 'spec_ui.dart';
import 'tts_status.dart';
import 'turn_activity.dart';

/// 最后一个 turn 的运行状态（webapp `deriveStreamLifecycle` 的客户端等价物）。
///
/// ## 为什么需要它（而不是只有 [EventReducer.inFlightTurnIds]）
///
/// [EventReducer.inFlightTurnIds] 的判据是**流式标记**（`isStreaming` / 未配对的
/// `tool_call`），而流式标记只由**增量帧**（Transient）产生。重开对话时回填的
/// 全是落库的权威帧 → 流式标记恒为空 → 一个仍在服务端运行的 turn 被当成静止。
///
/// 故需要一条与「有没有流式标记」无关的结构推断：**最后一个 turn 有没有终态
/// 事件**（`done` / `error`）。见 [EventReducer.lastTurnRunState]。
///
/// 四种状态与 webapp 的 `StreamLifecycle` 对齐：`idle`（无 turn）/ `preparing`
/// （只有用户消息，agent 还没动）/ `streaming`（已有 agent 侧产物）/
/// `terminal`（收到过终态事件）。**只有前两者之外的两种需要看门狗**。
enum LastTurnRunState {
  /// 时间线里没有任何可归属的 turn。
  idle,

  /// 最后一个 turn 只有用户消息（已提交，agent 尚未产出）。
  preparing,

  /// 最后一个 turn 已有 agent 侧产物（可能仍在跑）。
  streaming,

  /// 最后一个 turn 收到过终态事件（`done` / `error`）。
  terminal,
}

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

    // 上下文用量快照（`context_update`）。
    //
    // 单个值而非 Map：用量是**对话级**状态（当前上下文窗口被占了多少），
    // 不是 per-turn 的——同一 turn 内 telemetry 与 compaction 会交替到达，
    // 各自只带部分字段，故用 `mergedWith` 逐字段累积（见 ContextUsage 类文档）。
    //
    // 它**不**进 items：用量是诊断/状态信息，不是对话正文（对齐 webapp 把
    // 它渲染在右侧状态侧边栏而非时间线）。
    ContextUsage? contextUsage;

    // 执行等待/重试状态（`queue_state` / `retry_scheduled`）。
    //
    // 单个值而非 Map：它是「当前这个 group 里哪个 turn 在等」的一行提示，
    // 同一时刻只需要展示一条（最新的等待者胜出）。
    //
    // ## 为什么清除要按 turn 作用域 + 按事件顺序
    //
    // 这两类事件在 Go 侧**是落库的**（非 Transient，见 ExecutionStatus 类文档），
    // 故回放一段「排队 → 起跑 → 回复」的历史时也会经过这里。清除必须按
    // globalSeq 升序自然生效（本循环就是升序），回放才能得到与实时一致的终态
    // ——否则历史回放会永远挂着一条「排队中」。
    //
    // 作用域限同 turn：别的 turn 的正文不该抹掉本 turn 的排队提示。
    ExecutionStatus? executionStatus;

    // 语音播报状态（`tts_started` / `tts_completed` / `tts_failed`）。
    //
    // 非空且默认为 [TtsPhase.idle]：调用方无需到处判空，UI 用 [TtsStatus.hasStatus]
    // 决定是否渲染。
    //
    // ## 为什么不能按「当前流式的 turn」查表
    //
    // 终态（completed/failed）在 turn 结束后才到达，那时已经没有流式项了
    // （`_streamingItem` 为 null）。若按 turnId 查表，恰恰在最需要展示
    // 「合成完成 / 失败原因」时查不到。故取「最近一条」而非「当前 turn 的」。
    //
    // ## 跨 turn 失效
    //
    // 新 turn 的 `user_message` 到达时置回 idle（见下方），避免「上一轮的已完成」
    // 横幅粘在新一轮上。
    var ttsStatus = const TtsStatus.idle();
    var lastEventId = '';

    // 当前正在累积的 assistant 段落 / thought 段落。
    // 用索引而非对象引用，因为 copyWith 会替换对象。
    int? currentAssistantIdx;
    int? currentThoughtIdx;

    // tool_call_id → items 中的索引，用于把 tool_result 合并回对应的 call。
    final toolIdxById = <String, int>{};

    // 收到过终态事件（`done` / `error`）的 turn 集合。
    //
    // ## 为什么必须在归约时收集（不能事后从 items 反推）
    //
    // `done` **不产出任何 item**：它只把流式段落标记为完成（见 [_sealStreaming]）。
    // 因此「一个已完成的 turn」与「一个回填出来、仍在跑的 turn」在归约结果里
    // **完全一致**（都是 `[UserMessageItem, AssistantMessageItem(isStreaming:false)]`）。
    // 想区分二者，只能在遍历事件时顺手记下终态——这正是本集合的用途。
    //
    // ## 为什么是派生数据而不是新增 item
    //
    // 与 [ReductionResult.activities] / [ReductionResult.executionStatus] 同取向：
    // 终态是**控制信息**而非对话正文，塞一个 item 进去会在时间线上多渲染一条
    // 用户没发过的内容。故只作为 [ReductionResult] 的附加字段派生出来，
    // `reduce` 的签名（只收事件）保持不变。
    final terminalTurnIds = <String>{};

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

      // context_update：累积成对话级用量快照。
      //
      // WHY 在循环顶部而非 switch 分支里：与 turn_activity 同因——`default:`
      // 分支的语义是「控制事件，不进对话列表也不进任何通道」；放进去就等于
      // 宣称它被丢弃。它确实不产 items，但产出 contextUsage。
      //
      // ⚠️ 该事件在 Go 侧走 `flushEvent`（落库）而非 `flushEventTransient`，
      // 故**会**带有效 eventId/globalSeq、**会**推进 SSE 游标——这里无需像
      // goal_updated 那样做 Transient 豁免。上面的游标推进已按 `!transient`
      // 把关，两条路径一致。
      if (ev.eventType == EventTypes.contextUpdate) {
        final parsed = ContextUsage.fromEventPayload(ev.payload ?? const {});
        if (parsed != null) {
          // 同 turn 内多条按到达顺序合并；跨 turn 同样合并（窗口大小不变，
          // 最新一轮的用量覆盖旧值）。
          contextUsage = contextUsage?.mergedWith(parsed) ?? parsed;
        }
      }

      // queue_state / retry_scheduled：维护「尚未回复的原因」。
      //
      // WHY 在循环顶部而非 switch 分支里：与 turn_activity / context_update 同因
      // ——`default:` 分支的语义是「控制事件，不进对话列表也不进任何通道」，
      // 放进去就等于宣称它被丢弃。它确实不产 items，但产出 executionStatus。
      //
      // ⚠️ 清除必须**先于**设置判定，且限同 turn：`queue_state` 的
      // `state=cancelled` 既是「清除信号」又属该事件类型，两者互斥
      // （fromEvent 只在 state=queued 时非 null）。
      final status = ExecutionStatus.fromEvent(ev);
      if (status != null) {
        // 新的等待者胜出（可能是另一个 turn 在排队）。
        executionStatus = status;
      } else if (executionStatus != null &&
          executionStatus.turnId == ev.turnId &&
          ExecutionStatus.clearsOn(ev)) {
        executionStatus = null;
      }

      // tts_started / tts_completed / tts_failed：维护播报状态。
      //
      // WHY 在循环顶部而非 switch 分支里：与 turn_activity / executionStatus 同因
      // ——`default:` 分支的语义是「不进对话列表也不进任何通道」，放进去就等于
      // 宣称它被丢弃。它确实不产 items，但产出 ttsStatus。
      //
      // ⚠️ 覆盖按到达顺序（本循环即 globalSeq 升序）即可，无需额外时序处理：
      // `tts_started` 是 Transient（不落库），两个终态**落库**，故回放一段
      // 「started → completed」会自然得到终态。
      final tts = TtsStatus.fromEvent(ev);
      if (tts != null) {
        ttsStatus = tts;
      } else if (ttsStatus.hasStatus &&
          ev.eventType == EventTypes.userMessage &&
          ev.turnId != ttsStatus.turnId) {
        // 新 turn 开始：上一轮的播报状态已过期，不要粘在新一轮上。
        // （只对新 turn 生效：同 turn 重放的 user_message 不应清掉本 turn 状态。）
        ttsStatus = const TtsStatus.idle();
      }

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
            // 服务端 `user_message` 事件不带 agent_id（那是客户端回显独有的键）。
            // 原位替换时**保留**本地已知的那个，否则「重发」会在权威帧到达后
            // 丢掉 agent 选择——用户看到的输入框还选着某 agent，重发却换了人。
            agentId:
                _nonEmptyString(ev.payload?['agent_id']) ??
                (existing != null && items[existing] is UserMessageItem
                    ? (items[existing] as UserMessageItem).agentId
                    : null),
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
          // error 与 done 同属终态：服务端在超时/执行异常时会先发 error 再发 done，
          // 两者都意味着「本轮不会再产出」。对齐 webapp `terminalLifecycleFromEvent`。
          if (ev.turnId.isNotEmpty) terminalTurnIds.add(ev.turnId);
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
          //
          // 同时登记到 terminalTurnIds——`done` 本身不产 item，若不在这里记录，
          // 归约结果就无法区分「已完成的 turn」与「回填出来仍在跑的 turn」
          // （见 terminalTurnIds 的说明）。
          if (ev.turnId.isNotEmpty) terminalTurnIds.add(ev.turnId);
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

        case EventTypes.habitAutoRunCompleted:
          // 习惯自动执行完成：习惯回环的 Reward 环，给用户「服务端真的帮你
          // 跑了一轮」的可见反馈。
          //
          // 之前该事件落到 `default:` 分支被静默丢弃——与
          // `habit_suggestion_created` 同因（不在 `chatbus/broker.go` 的
          // 常量表里，只对着 broker.go 做镜像必然漏掉）。
          //
          // ⚠️ Go 侧当前**不产出**本事件（见 [EventTypes.habitAutoRunCompleted]
          // 的说明）：本分支是按已冻结契约实现的前向兼容，一旦补齐即刻生效。
          //
          // 无 topic_key 也**照常产出**（与建议卡不同）：本项不靠它作身份键，
          // 空 topic 只会渲染成「未命名习惯」，比整条事件消失好得多。
          _upsertHabitAutoRun(
            items,
            HabitAutoRunItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              topicKey: ev.habitAutoRunTopicKey ?? '',
              runId: ev.habitAutoRunRunId,
              patternId: ev.habitAutoRunPatternId,
              serverSummary: ev.habitAutoRunSummary,
            ),
          );

        case EventTypes.goalGateStopped:
          // Goal Gate 终止（目标达成 / 达到自动轮次上限 / 任务受阻或出错）。
          //
          // 之前该事件落到 `default:` 分支被静默丢弃，尽管
          // `EventTypes.timelineVisible` 早已收录它（见 event_types.dart 的集合）
          // ——即「集合说它可见、实现却把它丢了」。后果是用户看到 agent 不再
          // 自动续跑却没有任何解释。
          //
          // payload 无通用 `content` 字段，文案由 [GoalGateStoppedItem.message]
          // 按 reason 映射（与 miniapp `goalGateStoppedContent()` 逐条一致）。
          // reason 缺失（异常载荷）时仍**照常产出**：兜底文案「自动推进已停止」
          // 仍传达结论，比整条事件消失好得多（与 [HabitAutoRunItem] 同取向）。
          items.add(
            GoalGateStoppedItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              reason: ev.payload?['reason']?.toString() ?? '',
              detail: _nonEmptyString(ev.payload?['detail']),
              autoTurnCount: _intOrNull(ev.payload?['auto_turn_count']),
              maxAutoTurns: _intOrNull(ev.payload?['max_auto_turns']),
            ),
          );

        case EventTypes.scheduleCreated:
          // 自动续跑已排程（Goal Gate 即将继续）。
          //
          // 与上面的 `goal_gate_stopped` 是**一对**：本项说「即将继续」，后者说
          // 「已停止」。此前它落在 `default:` 分支被静默丢弃，用户看到界面静止
          // 时无法区分「在等一会儿接着跑」与「已经停了」。
          //
          // delay_seconds 缺失（异常载荷）时仍**照常产出**：文案退化为
          // 「已排入下一轮自动继续」而不编造秒数（见 [ScheduleCreatedItem.userText]），
          // 比整条事件消失好得多（与 [HabitAutoRunItem] 同取向）。
          items.add(
            ScheduleCreatedItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              delaySeconds: ev.scheduleDelaySeconds,
              reason: ev.payload?['reason']?.toString() ?? '',
              autoTurnCount: _intOrNull(ev.payload?['auto_turn_count']),
              maxAutoTurns: _intOrNull(ev.payload?['max_auto_turns']),
            ),
          );

        case EventTypes.pigoSessionMissing:
          // 会话绑定失效（幽灵 session_id）：服务端已清空绑定、本轮新建会话。
          //
          // 这是**诊断事件**（Go 侧 `Diagnostic: true`），默认只落库不广播，
          // 故主要在拉 timeline 历史时到达——但它的价值恰恰在历史里：用户
          // 回头看会发现「这里开始 agent 不记得上下文了」，本条是唯一解释。
          //
          // content 为空时仍产出：正文缺失说明载荷异常，但「会话绑定失效」
          // 这个结论本身仍值得展示（用兜底文案，不编造 session_id）。
          items.add(
            DiagnosticNoticeItem(
              id: ev.eventId,
              createdAt: ev.createdAt,
              turnId: ev.turnId,
              content:
                  _nonEmptyString(ev.payload?['content']) ??
                  '检测到失效的会话绑定，本次将新建会话继续',
              sessionId: _nonEmptyString(ev.payload?['session_id']),
            ),
          );

        default:
          // heartbeat / gate_evaluated / gate_completed / gate_error / tts_* 等
          // 控制事件不进入对话列表，也不进 gate 决策通道。
          //
          // ⚠️ `adaptive_decision` / `goal_gate_decision` **不在**本分支的
          // 「丢弃」之列：它们已在循环顶部经 `gateDecisionFrom(ev)` 收进 gate
          // 决策通道（见 ReductionResult.gateDecisions）。这正是修复前的缺口——
          // 常量已在 EventTypes 声明，但归约器把这两类连同上面的噪声事件一起
          // 静默丢弃了。
          //
          // ⚠️ `goal_gate_stopped` / `pigo_session_missing` / `schedule_created`
          // **都不再**在本分支的「丢弃」之列（此前它们确实落在这里）：前两者
          // 是 Goal Gate 终止与上下文丢失的唯一可见信号，后者是「即将继续」
          // 的唯一信号。三者都在上方有显式 case——`EventTypes.timelineVisible`
          // 早已收录它们，而实现漏了分支，这正是「集合与实现单侧漂移」的形态
          // （由 `event_types_consistency_test.dart` 守卫）。
          //
          // ⚠️ 该分支也**不**包含 `agent.file.*`（已在上方 case 处理）。
          // 在 agent 文件卡接入前，本分支曾吞掉 2927 条 agent 产物事件——
          // 原注释声称「如连接指示器、TTS 播放器」会消费，但客户端
          // **从来没有** TTS 播放器（`grep tts|audioPlayer` 零命中），
          // 误导性的「托底」比没有注释更糟（会让排障者以为有处理而放过泄漏）。
          //
          // ⚠️ `group_title_updated` 落在这里是**有意**的，不是遗漏：它是
          // Transient 的「你手上的标题过期了」通知，真源在 `chat_groups.title`，
          // 时间线里不该出现「已改名」气泡。它由 `GroupUpdate.fromEvent`
          // 归一后走 `groupUpdates` 通道驱动列表刷新
          // （见 `ChatStreamController._onFrame` 的例外推送）。
          break;
      }
    }

    return ReductionResult(
      items: items,
      lastEventId: lastEventId,
      gateDecisions: gateDecisions,
      activities: activities,
      contextUsage: contextUsage,
      executionStatus: executionStatus,
      ttsStatus: ttsStatus,
      terminalTurnIds: terminalTurnIds,
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

  /// 插入习惯自动执行完成项（按事件 id 幂等）。
  ///
  /// ## 为什么用事件 id 而不是 runId
  ///
  /// 同一事件会在「SSE cursor 回放」与「timeline 回填」的交叠窗口到达两次；
  /// 两者带的是**同一个 eventId**，故按 id 去重即可。用 `runId` 会在载荷缺它
  /// （旧载荷/降级载荷）时失去幂等性，而事件 id 是 ChatEvent 必有的。
  ///
  /// 与 [_upsertHabitSuggestion] 不同：本项是**终态通知**（无后续事件改写它），
  /// 故不保留旧字段，重复到达时以先到者为准（不重建、不刷 createdAt——
  /// 列表排序不应因重放而漂移）。
  static void _upsertHabitAutoRun(
    List<ConversationItem> items,
    HabitAutoRunItem incoming,
  ) {
    for (final it in items) {
      if (it is HabitAutoRunItem && it.id == incoming.id) return;
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

  /// 仍在进行中的 turn id 集合。
  ///
  /// ## 它解决什么问题
  ///
  /// 「超时兜底」（距最后一条事件过久仍未收到 `done` 时停掉流式光标）需要知道
  /// **哪些 turn 还在跑**。归约结果本身不携带这个答案：`done` 丢失后流式标记
  /// 永远为 true，而 UI 无从区分「刚起跑」与「卡死十分钟」。
  ///
  /// ## 为什么算「未完成的工具调用」也算进行中
  ///
  /// 长工具（构建 / 大范围检索 / 下载）期间既没有正文也没有思考，只有一条
  /// `tool_call`。只看 [AssistantMessageItem.isStreaming] 会漏掉这一段——而它
  /// 恰恰是最容易长时间静默、最需要兜底的情形。
  ///
  /// ## 为什么是纯查询而不是给 [reduce] 加参数
  ///
  /// 「强制封段」会制造两个真实缺陷：
  ///
  /// 1. **重复气泡**：该段 `isStreaming` 变 false 后，若 turn 其实仍在跑、增量帧
  ///    恢复到达，归约器的段落索引是从头重建的，会新建一个
  ///    [AssistantMessageItem]——同一个 turn 渲染出两个气泡。
  /// 2. **编造**：[`_sealStreaming`] 会把未配对的工具调用写成
  ///    `isComplete: true, output: '(无输出)'`，而 turn 可能还在后台跑。
  ///
  /// 故归约结果保持不变，只把「谁在跑」这个事实**派生**出来，由消费方决定
  /// 怎么呈现（webapp 的 `deriveStreamLifecycle` 同一取向）。
  ///
  /// ## 回填出来的历史 turn 不在其中（已知边界）
  ///
  /// 流式增量是 Transient（不落库），timeline 回填拿到的 `message` 全是权威帧
  /// （`isStreaming == false`）。故「重开对话时服务端仍在跑」本函数返回空。
  /// 这个形态由 [lastTurnRunState] 覆盖（判据不同：结构推断而非流式标记）。
  static Set<String> inFlightTurnIds(Iterable<ConversationItem> items) {
    final ids = <String>{};
    for (final it in items) {
      // turnId 为空无法关联到任何 turn（历史数据或异常载荷）。
      if (it.turnId.isEmpty) continue;
      final inFlight = switch (it) {
        AssistantMessageItem(:final isStreaming) => isStreaming,
        ThoughtItem(:final isStreaming) => isStreaming,
        ToolCallItem(:final isComplete) => !isComplete,
        _ => false,
      };
      if (inFlight) ids.add(it.turnId);
    }
    return ids;
  }

  /// 最后一个 turn 的运行状态（**结构推断**，与流式标记无关）。
  ///
  /// ## 它解决什么问题（issue #9 / AGENTS.md §5.8 的「B1b」）
  ///
  /// [inFlightTurnIds] 判的是**流式标记**，而流式标记只由增量帧产生。重开一个
  /// 对话时，回填的事件全是落库的权威帧 → 标记恒为空 → 一个仍在服务端运行的
  /// turn 被渲染成静止。本函数按 webapp `deriveStreamLifecycle` 的判据换成
  /// **结构推断**，从而覆盖该场景。
  ///
  /// ## 判据（逐条对齐 webapp）
  ///
  /// 1. 取时间线里**最后一个非空 turnId**（跳过 `router` 伪 turn）；
  /// 2. 该 turn 命中 [ReductionResult.terminalTurnIds] → [LastTurnRunState.terminal]；
  /// 3. 该 turn 有 agent 侧项 → [LastTurnRunState.streaming]；
  /// 4. 只有用户项 → [LastTurnRunState.preparing]；
  /// 5. 无任何可归属项 → [LastTurnRunState.idle]。
  ///
  /// ## 为什么「有 agent 侧项」就够，不需要看流式标记
  ///
  /// agent 侧项（正文 / 思考 / 工具调用 / 错误 / 文件产物）意味着服务端**至少
  /// 开始产出了**。若没有终态，它就可能仍在跑。这比「有没有流式标记」更可靠：
  /// 后者依赖 Transient 增量帧是否恰好在本连接上到达过。
  ///
  /// ## 为什么要把 [ReductionResult.terminalTurnIds] 作为入参
  ///
  /// 终态（`done` / `error`）**不产出 item**，故无法从 [items] 反推。必须由
  /// 归约器在遍历事件时记录（见该字段的说明）。不传它时视为「没有任何 turn
  /// 收到过终态」——那会把所有历史 turn 都判成可能在跑，**不要**在生产路径上
  /// 省略该参数。
  ///
  /// ## 为什么是「最后一个 turn」而不是「所有 turn」
  ///
  /// 同一 group 的 turn 是排队串行执行的（Go `chat/queue_state` 语义），不会
  /// 有两个 turn 同时跑。取最后一个即可回答「现在是不是还在跑」，且避免了
  /// 「很久以前那个没收到的 done」把当前对话永远判成运行中。
  static LastTurnRunState lastTurnRunState(
    Iterable<ConversationItem> items, {
    Set<String> terminalTurnIds = const {},
  }) {
    // 1) 最后一个非空 turnId。
    //
    // `router` 是服务端用于归属判定的伪 turn，不代表一次执行。
    final list = items.toList();
    var lastTurnId = '';
    for (final it in list.reversed) {
      if (it.turnId.isEmpty) continue;
      if (it.turnId == 'router') continue;
      lastTurnId = it.turnId;
      break;
    }
    if (lastTurnId.isEmpty) return LastTurnRunState.idle;

    var hasAgentSide = false;
    var hasUserSide = false;
    for (final it in list) {
      if (it.turnId != lastTurnId) continue;
      switch (it) {
        case AssistantMessageItem():
        case ThoughtItem():
        case ToolCallItem():
        case ErrorItem():
        case AgentFileItem():
        case GoalProgressItem():
        case HabitAutoRunItem():
          hasAgentSide = true;
        case UserMessageItem():
          hasUserSide = true;
        case _:
          break;
      }
    }

    // 2) 终态优先：有终态事件即「本轮不会再产出」。
    if (terminalTurnIds.contains(lastTurnId)) {
      return LastTurnRunState.terminal;
    }
    // 3) 已有 agent 产物且无终态 → 可能仍在跑（这正是重开对话的场景）。
    if (hasAgentSide) return LastTurnRunState.streaming;
    // 4) 只有用户消息 → 已提交，agent 尚未动。
    if (hasUserSide) return LastTurnRunState.preparing;
    return LastTurnRunState.idle;
  }

  /// 最后一个 turn 是否**可能仍在服务端运行**（重开对话场景的看门狗判据）。
  ///
  /// 等价于「[lastTurnRunState] 为 [LastTurnRunState.streaming] 或
  /// [LastTurnRunState.preparing]」。
  ///
  /// ## 为什么 `preparing` 也算
  ///
  /// `preparing` 是「用户消息已落库、agent 还没产出任何东西」——这正是
  /// 排队/起跑的空窗期，**最需要**兜底（服务端可能已崩且永远不会发 `done`）。
  /// 对齐 webapp：`deriveStreamLifecycle` 的 `preparing` 同样不是终态。
  ///
  /// ## 语义是提示，不是终态
  ///
  /// 返回 true **不**意味着 turn 一定在跑，只意味着「没有证据说明它停了」。
  /// 消费方（看门狗）据此武装计时器，**不得**据此写库或禁用取消
  /// （与 [inFlightTurnIds] 同一取向，见 AGENTS.md §5.8 的三条不变式）。
  static bool lastTurnMayBeRunning(
    Iterable<ConversationItem> items, {
    Set<String> terminalTurnIds = const {},
  }) {
    final state = lastTurnRunState(items, terminalTurnIds: terminalTurnIds);
    return state == LastTurnRunState.streaming ||
        state == LastTurnRunState.preparing;
  }

  /// 最后一个可能仍在跑的 turn 的 id；无则空串。
  ///
  /// 看门狗需要它来武装**那一个**计时器（与 [inFlightTurnIds] 返回集合不同：
  /// 这里只关心最后一个 turn，因为同 group 的 turn 串行执行）。
  static String lastRunningTurnId(
    Iterable<ConversationItem> items, {
    Set<String> terminalTurnIds = const {},
  }) {
    final state = lastTurnRunState(items, terminalTurnIds: terminalTurnIds);
    if (state != LastTurnRunState.streaming &&
        state != LastTurnRunState.preparing) {
      return '';
    }
    for (final it in items.toList().reversed) {
      if (it.turnId.isEmpty || it.turnId == 'router') continue;
      return it.turnId;
    }
    return '';
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

  /// 取非空字符串，空串/空白串/非字符串均归 null。
  ///
  /// 服务端用 `omitempty` 与空串两种方式表达「没有」，故不能只判 null——
  /// 把空串当「有值」会让 UI 渲染出空白行（如 `detail: ""`）。
  static String? _nonEmptyString(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  /// 取整数，非 num / 非有限值归 null。
  ///
  /// JSON 解码可能给出 `double`（如 `3.0`），故不能直接 `as int?`。
  static int? _intOrNull(Object? v) => v is num ? v.toInt() : null;

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
    // 构造交给 [AgentFileItem.fromEvent]（**唯一**工厂）：详情面板逐事件渲染、
    // 不走归约，若两边各拼一份，规则会各自漂移。这里只负责「合并进列表」。
    final fresh = AgentFileItem.fromEvent(ev);
    if (fresh == null) return; // 异常载荷 / 未来新增子类型：暂不处理

    final existingIdx = _indexOfAgentFile(items, fresh.id);
    if (existingIdx == null) {
      // 首次出现：插入新卡。
      items.add(fresh);
      return;
    }

    // 原地合并：保持首次出现的位置锚点与 createdAt，更新最新态。
    final prev = items[existingIdx] as AgentFileItem;
    final prevRank = _fileStageRank[prev.action] ?? 0;
    final nextRank = _fileStageRank[fresh.action] ?? 0;
    final mergedAction = nextRank >= prevRank ? fresh.action : prev.action;

    items[existingIdx] = AgentFileItem(
      id: prev.id,
      createdAt: prev.createdAt,
      turnId: prev.turnId,
      relativePath: fresh.relativePath.isEmpty
          ? prev.relativePath
          : fresh.relativePath,
      fileName: fresh.fileName.isEmpty ? prev.fileName : fresh.fileName,
      displayName: fresh.displayName.isEmpty
          ? prev.displayName
          : fresh.displayName,
      action: mergedAction,
      // 取最新非空（删除事件无 fileId，不冲掉创建时的 id）。
      ufsFileId: (fresh.ufsFileId != null && fresh.ufsFileId!.isNotEmpty)
          ? fresh.ufsFileId
          : prev.ufsFileId,
      mimeType: fresh.mimeType ?? prev.mimeType,
      sizeBytes: fresh.sizeBytes ?? prev.sizeBytes,
      ttsKind: fresh.ttsKind ?? prev.ttsKind,
      modifiedAt: fresh.modifiedAt ?? prev.modifiedAt,
      deletedAt: fresh.deletedAt ?? prev.deletedAt,
    );
  }

  /// 取最近一张。
  static int? _indexOfAgentFile(List<ConversationItem> items, String identity) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is AgentFileItem && it.id == identity) return i;
    }
    return null;
  }
}

/// 归约输出。
class ReductionResult {
  const ReductionResult({
    required this.items,
    required this.lastEventId,
    this.gateDecisions = const [],
    this.activities = const {},
    this.contextUsage,
    this.executionStatus,
    this.ttsStatus = const TtsStatus.idle(),
    this.terminalTurnIds = const {},
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

  /// 上下文用量与费用快照（`context_update`）。
  ///
  /// ## 为什么不在 [items] 里
  ///
  /// 与 [gateDecisions] / [activities] 同因：用量是**状态**而非对话正文。
  /// 夹在消息之间会把对话冲散，而它是持续变化的一行数字（webapp 同样把它
  /// 放在右侧状态侧边栏，见 `WorkbenchStatusSidebar`）。
  ///
  /// ## 为什么是单个值而不是 Map
  ///
  /// 用量描述的是「当前这个上下文窗口」，与具体哪个 turn 无关：
  /// 同一 turn 内 telemetry 与 compaction 会交替播报，各自只带部分字段，
  /// 归约时逐字段合并成**一个**快照（见 [ContextUsage.mergedWith]）。
  ///
  /// 为 null 表示缓冲区里没有任何可识别的 `context_update`（含服务端未发射、
  /// 或事件只带无法解析的异常载荷）——UI 应**隐藏**该区域而非显示 0。
  final ContextUsage? contextUsage;

  /// 执行等待/重试状态（`queue_state` / `retry_scheduled`）。
  ///
  /// ## 为什么不在 [items] 里
  ///
  /// 与 [gateDecisions] / [activities] / [contextUsage] 同因：它是**状态提示**
  /// 而非对话正文。它回答的是「为什么还没有回复」——夹在消息之间会与真正的
  /// 回复混淆，而它本质上是「此刻在等」的瞬时判断。
  ///
  /// ## 与 [activities] 的区别（UI 用同一个槽位）
  ///
  /// [activities] 是「已在跑但没正文」，本字段是「还没开始跑（等名额/等重试）」。
  /// 两者互斥展示，本字段**优先**（对齐 webapp `turn.activity && !turn.queueReason`）。
  ///
  /// 为 null 表示当前无等待（服务端未发射、已起跑/已回复、或已终态）。
  final ExecutionStatus? executionStatus;

  /// 语音播报状态（`tts_started` / `tts_completed` / `tts_failed`）。
  ///
  /// ## 为什么不在 [items] 里
  ///
  /// 与 [gateDecisions] / [activities] / [contextUsage] / [executionStatus] 同因：
  /// 它是**状态指示**而非对话正文。语音是文本回复的衍生物，夹进时间线会让人
  /// 以为「又多了一条回复」。
  ///
  /// 取「最近一条」而非按 turnId 查表：终态事件在 turn 结束后才到达，那时已
  /// 没有流式项可关联（详见归约器内的注释）。
  ///
  /// 非空：无播报事件时为 [TtsPhase.idle]（UI 用 [TtsStatus.hasStatus] 判断）。
  final TtsStatus ttsStatus;

  /// 收到过终态事件（`done` / `error`）的 turn 集合。
  ///
  /// ## 为什么必须由归约器派生（不能从 [items] 反推）
  ///
  /// `done` 不产出任何 item——它只把流式段落标记为完成。故「已完成的 turn」与
  /// 「回填出来、仍在跑的 turn」在 [items] 里**完全一致**，无法区分。想回答
  /// 「重开对话时服务端是不是还在跑」（issue #9），只能靠这里记录的终态。
  ///
  /// ## 消费方
  ///
  /// [EventReducer.lastTurnMayBeRunning] 把它作为「该 turn 是否仍在跑」的判据，
  /// 供 `ChatStreamController` 的超时看门狗在流式标记为空时兜底。
  final Set<String> terminalTurnIds;
}
