/// 聊天事件类型常量。
///
/// ⚠️ **真源是 Go 侧 `apps/go-api/internal/chatbus/broker.go` 的 `Event*` 常量**。
/// 本文件是它的镜像，新增/改名事件必须两边同步，否则客户端会静默丢弃未知事件。
///
/// WHY 用 `String` 常量而非 Dart `enum`：服务端可能新增事件类型，而旧客户端
/// 不认识它。用 enum 时解析未知值要么抛异常、要么需要 fallback 分支；用字符串
/// 则天然容忍未知类型（走 [ChatEvent.isKnown] 判定后按通用方式渲染）。
/// 这是**向前兼容**的刻意选择——移动端发布后无法强制用户升级。
class EventTypes {
  // 私有构造：本类是**纯常量命名空间**（全部成员是 `static const String`），
  // 只用于防止实例化，任何地方都不会调用。`// coverage:ignore-line` 是因为
  // 它**结构上不可达**（库外不可见、库内无调用），不是「漏测」。
  const EventTypes._(); // coverage:ignore-line

  // ---- 基础执行流 ----
  static const start = 'start';
  static const message = 'message';
  static const thought = 'thought';
  static const plan = 'plan'; // 保留给未来真实 plan 事件，勿用于心跳
  static const heartbeat = 'heartbeat'; // Transient，不落库不渲染

  /// 执行中的活动快照（`internal/chat/turn_worker.go` 的
  /// `upgradeHeartbeatToActivity`：把 executor 心跳升级而来）。
  ///
  /// **Transient**：与 [heartbeat] 同族（不落库、不回放），payload 是
  /// `{elapsed_ms, last_event_type?, since_last_event_ms?, content?}`。
  /// 用途是在「执行中但还没有正文」的空窗期展示「已运行多久 + 上一步是什么」，
  /// 避免用户误判为卡死。**不进 [timelineVisible]**：它是进度提示，不是时间线正文。
  static const turnActivity = 'turn_activity';

  static const toolCall = 'tool_call';
  static const toolResult = 'tool_result';
  static const error = 'error';
  static const done = 'done';
  static const contextUpdate = 'context_update';

  /// 用户发出的消息（落库事件，每个 turn 的首个事件）。
  ///
  /// ⚠️ **不在 `chatbus/broker.go` 的 `Event*` 常量里**——它由
  /// `internal/chat/enqueue.go` 以字面量 `"user_message"` 落库（单事务内写
  /// `chat_turns` + `user_message` + 附加事件 + `queue_state`）。
  /// 这印证了「`broker.go` 不是完整事件集」：**新增事件时必须同时核对落库点**，
  /// 只看 `broker.go` 会漏掉本类型，而它是时间线里渲染用户气泡的唯一依据。
  static const userMessage = 'user_message';

  /// 确认超时失效（`internal/chat/turn_worker.go` 的 `writeConfirmationExpired`）。
  ///
  /// 与 [confirmationResolved] 成对：前者是「已作废」，后者是「已作答」。
  /// 两者都需把 UI 上的确认卡置为不可交互，否则用户会对着一张早已失效的卡点下去。
  static const confirmationExpired = 'confirmation_expired';

  // ---- Turn 生命周期与 gate 诊断 ----
  static const executorStarted = 'executor_started';
  static const executorCompleted = 'executor_completed';
  static const gateEvaluated = 'gate_evaluated';
  static const gateCompleted = 'gate_completed';
  static const gateError = 'gate_error';

  // ---- 前置链路由 / 确认 ----
  static const routingSelected = 'routing_selected';
  static const confirmationRequired = 'confirmation_required';
  static const confirmationResolved = 'confirmation_resolved';
  static const adaptiveDecision = 'adaptive_decision';
  static const ttsStarted = 'tts_started';
  static const ttsCompleted = 'tts_completed';
  static const ttsFailed = 'tts_failed';
  static const retryScheduled = 'retry_scheduled';
  static const followUpSuggested = 'follow_up_suggested';
  static const queueState = 'queue_state';

  /// 用户对「这条消息归属哪个对话」的人工反馈（正确/错误）。
  static const routingFeedback = 'routing_feedback';

  /// 向用户**征询**归属是否正确（提问，非标注）。与 [routingFeedback] 一问一答。
  static const routingFeedbackRequest = 'routing_feedback_request';

  // ---- Goal Gate ----
  static const goalGateDecision = 'goal_gate_decision';
  static const goalGateStopped = 'goal_gate_stopped';
  static const scheduleCreated = 'schedule_created';
  static const groupMetadataUpdated = 'group_metadata_updated';

  // ---- Agent 文件产物（agent.file.*）----
  //
  // ⚠️ **这些事件不在 `chatbus/broker.go` 的 `Event*` 常量里**——它们由
  // `workers/groupsync`、`workers/agentfilerender`、`tts/service.go` 各自
  // emit。印证了顶部「broker.go 不是完整事件集」的告警：新增事件时必须
  // 全仓 grep `agent.file.` 而非只看 broker.go。
  //
  // 生产实测（2927 条）：created 1821 / modified 1001 / deleted 105。
  // 删除事件**不带 `ufs_file_id` / `size_bytes`**（生产库 11/11 条均缺），
  // 故身份判定必须用 `relative_path`，不能用 fileId（见 reducer 的收敛逻辑）。

  /// 前缀，用于前缀匹配而非穷举枚举（服务端可能新增 `agent.file.renamed`）。
  static const agentFilePrefix = 'agent.file.';
  static const agentFileCreated = 'agent.file.created';
  static const agentFileModified = 'agent.file.modified';
  static const agentFileDeleted = 'agent.file.deleted';

  /// goal / task 变更通知（不落库，仅广播）。
  static const goalUpdated = 'goal_updated';

  /// group 自身的生命周期变更通知（创建/删除/归档/恢复/改名/元数据）。
  ///
  /// **Transient**：真源在 `chat_groups` 表，事件只提示「你手上的 group 列表
  /// 过期了」。payload = `{op, group: {id, title, status, ...}}`，op 值域见
  /// `internal/chat/group_events.go` 的 `GroupEventOp`（created / deleted /
  /// archived / active / title / metadata）。发布口只有 `PublishGroupUpdated`。
  ///
  /// 与 [groupTitleUpdated] 的关系：后者是 Title Gate 在 turn 收尾时发的**已落库**
  /// 事件（有 turn），本事件覆盖 title 之外的 group 生命周期变更，两者共存。
  /// **不进 [timelineVisible]**：它驱动对话列表刷新，不是时间线正文。
  static const groupUpdated = 'group_updated';

  /// 分组标题被自动生成/改写（`internal/chatgate/title_gate.go`）。
  ///
  /// **Transient**：真源在 `chat_groups.title`，事件只提示「你手上的标题过期了」。
  /// 客户端收到后应重新拉 group 详情，而非把 payload 里的标题当权威值渲染。
  static const groupTitleUpdated = 'group_title_updated';

  /// pigo session 文件缺失（`internal/chatexec/pigo_session_file.go`）。
  ///
  /// 属诊断事件：说明某个 agent 绑定的 session 已丢失，服务端会自愈重建。
  /// 默认不渲染给用户，仅供排查。
  static const pigoSessionMissing = 'pigo_session_missing';

  // ---- 习惯（habit）----
  //
  // 真源：`internal/workers/habit/timeline_events.go` 的 `EventHabitSuggestion*`
  // 常量（该文件注释明示「前端 habit-timeline.mts 与 projector.extractFeedback
  // 均按这两个字面量识别，改动即破坏契约」）。
  //
  // ⚠️ 本仓库的 `spb_models/test/event_types_test.dart` 与 Go 侧的
  // `chatbus/broker.go` **都不含**这两个常量——`broker.go` 只登记经它广播的
  // 类型，而 habit 事件由 `habit.TimelineEmitter` 用字面量直接 `Publish`。
  // 这正是「只对 broker.go 做镜像会漏事件」的实例（同 [userMessage] 的境遇）。

  /// 检测器产出新的习惯候选建议。
  ///
  /// 落库事件（非 Transient），payload 见 `BuildSuggestionCreatedPayload`：
  /// `{suggestion_id, habit_pattern_id(候选为 null), status, trigger_type,
  /// recommendation{action,confidence,reasons}, rule_draft{topic_key,
  /// trigger_type,trigger_config,preferred_agent_id,delivery_group_id,
  /// target_acceptance_level}, evidence, editable_fields}`。
  static const habitSuggestionCreated = 'habit_suggestion_created';

  /// 用户已处理（accept / dismiss / snooze / edit_and_accept）某条建议。
  ///
  /// payload 见 `BuildSuggestionResolvedPayload`：`{suggestion_id, status,
  /// action, user_feedback, resolved_pattern_id, snooze_until, topic_key}`。
  ///
  /// ⚠️ 该事件附在**与 created 同一个 turn** 上（服务端 resolve 时重新取该
  /// group 最近一条 turn），故客户端按 `suggestion_id` 匹配（见
  /// `HabitSuggestionItem`），不能按 turnId。
  static const habitSuggestionResolved = 'habit_suggestion_resolved';

  /// 习惯规则被重新校准。
  ///
  /// ⚠️ **Go 侧当前没有任何产出点**（`workers/habit/projector.go` 注释确认
  /// Python 时代的事件未随迁移补上），webapp 的消费列表里却仍列着它，
  /// `habit_insights.go` 的 `countRecalibrationEvents` 也在查它（故
  /// `recalibration.total_count` 恒为 0）。声明常量只为让 `isKnown` 不误判，
  /// **不要**据此在 UI 上做「重校准次数」的确定性展示。
  static const habitPatternRecalibrated = 'habit_pattern_recalibrated';

  /// 自动执行的习惯跑完一轮（习惯回环的 **Reward 环**）。
  ///
  /// ## ⚠️ Go 侧当前**不产出**该事件（契约漂移，客户端无法修正）
  ///
  /// Python 时代由 `apps/orchestrator/chat_turn_worker_internal/habit_postprocess.py`
  /// 落库并广播；Go 迁移时**有意未补**：
  ///
  /// - `workers/habit/turn_terminal.go:35` 注释写明「属于奖励信号而非状态回写…
  ///   不在本任务范围」；
  /// - `workers/habit/projector.go:363` 只在**读取端**识别它（`reward` →
  ///   `reward_count`），全仓**没有任何 `Emit` 调用**产出该类型。
  ///
  /// 本客户端仍然消费它，理由是**两侧都指向同一结论**：
  ///
  /// 1. webapp 已在渲染（`lib/habit-timeline.mts` 的「习惯强化」标签 +
  ///    `chat-timeline.ts` 的 `formatHabitAutoRunCompletedSummary`）；
  /// 2. 服务端 projector 的注释明说识别它是「以便未来补齐事件时直接生效」。
  ///
  /// 故这里按**已冻结的 payload 契约**实现（形状取自 Python 的
  /// `build_habit_auto_run_completed_payload`），事件一旦补上即刻可见，
  /// 无需再改客户端。
  static const habitAutoRunCompleted = 'habit_auto_run_completed';

  /// 本客户端已知的全部事件类型。
  ///
  /// 新增事件时同步加进来；[ChatEvent.isKnown] 依赖它区分「服务端发了新事件」
  /// 与「契约漂移导致解析失败」。
  static const Set<String> all = {
    start,
    message,
    thought,
    plan,
    heartbeat,
    turnActivity,
    toolCall,
    toolResult,
    error,
    done,
    contextUpdate,
    userMessage,
    executorStarted,
    executorCompleted,
    gateEvaluated,
    gateCompleted,
    gateError,
    routingSelected,
    confirmationRequired,
    confirmationResolved,
    adaptiveDecision,
    ttsStarted,
    ttsCompleted,
    ttsFailed,
    retryScheduled,
    followUpSuggested,
    queueState,
    routingFeedback,
    routingFeedbackRequest,
    goalGateDecision,
    goalGateStopped,
    scheduleCreated,
    groupMetadataUpdated,
    goalUpdated,
    confirmationExpired,
    groupUpdated,
    groupTitleUpdated,
    pigoSessionMissing,
    habitSuggestionCreated,
    habitSuggestionResolved,
    habitPatternRecalibrated,
    habitAutoRunCompleted,
    // agent.file.* 不列入：见 [timelineVisible] 的前缀匹配说明。
  };

  /// 渲染进对话时间线的事件类型（其余为控制/诊断事件，不直接展示）。
  //
  // ⚠️ **`agent.file.*` 走前缀匹配而非列入本集合**：服务端可能新增
  // `agent.file.renamed` 之类，穷举枚举会让新类型静默落到 default 分支被
  // 丢弃（正是本次修复前 2927 条事件被吞的根因）。`ChatEvent.isTimelineVisible`
  // 除判定本集合外，还判定 `eventType.startsWith(agentFilePrefix)`——
  // 故本集合不含任何 `agent.file.*`，避免「既在集合里又被前缀覆盖」的冗余。
  static const Set<String> timelineVisible = {
    userMessage,
    start,
    message,
    thought,
    toolCall,
    toolResult,
    error,
    done,
    routingSelected,
    confirmationRequired,
    confirmationResolved,
    followUpSuggested,
    goalGateDecision,
    goalGateStopped,
    // 自动续跑排程（`chatgate/goal_gate.go:519` 的 emitScheduleCreated）。
    //
    // 与 [goalGateStopped] 是**一对**：本项说「即将继续」，后者说「已停止」。
    // 用户看到界面静止时需要知道是「它过多久会自己接着跑」还是「它已经停了」
    // ——只渲染其中一个都会让人误判当前状态。
    //
    // 安全进时间线：该事件属 `chatbus/broker.go` 的「持久化到 chat_events」
    // 一组（`Transient` 未设，零值 false），故会落库、会被 cursor 回放。
    scheduleCreated,
    // 习惯自动执行完成。与两个 suggestion 事件同族（都是习惯回环的用户可见
    // 节点），且 webapp 的时间线同样渲染它——见 [habitAutoRunCompleted] 的
    // 说明：Go 侧暂无产出点，这里先按契约声明，补齐后即刻生效。
    habitAutoRunCompleted,
  };

  /// 流式增量事件：收到时应「追加」而非「替换」。
  ///
  /// 与权威帧的区分规则见 [ChatEvent.transient]：Transient 的 message/thought
  /// 是增量片段，非 Transient 的是完整快照。
  static const Set<String> streamIncremental = {message, thought};
}
