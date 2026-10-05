import 'package:spb_models/spb_models.dart';

import 'spec_ui.dart';
import 'tts_audio_path.dart';

/// 对话中可渲染的一项（由事件归约而来）。
///
/// ## 为什么需要归约层
///
/// 服务端事件流是**扁平的**，且 `message`/`thought` 有「增量帧 + 权威帧」两形态。
/// UI 需要的是「一段完整回复」，而不是几百个增量片段。归约层负责：
///
/// 1. **合并增量**：`transient == true` 的 message/thought 追加到当前段落；
/// 2. **权威帧替换**：`transient == false` 的同类事件替换整段（防止增量丢失导致残缺）；
/// 3. **配对工具调用**：`tool_call` 与 `tool_result` 按 `tool_call_id` 合并成一项；
/// 4. **过滤控制事件**：heartbeat / queue_state / gate_* 不进对话列表。
///
/// 这样 UI 只需渲染 `List<ConversationItem>`，无需理解事件流细节。
sealed class ConversationItem {
  const ConversationItem({
    required this.id,
    required this.createdAt,
    this.turnId = '',
  });

  /// 稳定标识：同一逻辑项在多次归约后 id 不变，供 Flutter 列表 diff 使用。
  final String id;
  final DateTime createdAt;
  final String turnId;
}

/// 用户发出的消息。
final class UserMessageItem extends ConversationItem {
  const UserMessageItem({
    required super.id,
    required super.createdAt,
    required this.text,
    super.turnId,
  });

  final String text;
}

/// Agent 的回复段落。
///
/// [isStreaming] 为 true 表示该段仍在接收增量，UI 可显示光标/加载态。
final class AssistantMessageItem extends ConversationItem {
  const AssistantMessageItem({
    required super.id,
    required super.createdAt,
    required this.text,
    super.turnId,
    this.isStreaming = false,
    this.agentId,
  });

  final String text;
  final bool isStreaming;
  final String? agentId;

  AssistantMessageItem copyWith({String? text, bool? isStreaming}) =>
      AssistantMessageItem(
        id: id,
        createdAt: createdAt,
        text: text ?? this.text,
        turnId: turnId,
        isStreaming: isStreaming ?? this.isStreaming,
        agentId: agentId,
      );
}

/// 思考过程（可折叠展示）。
final class ThoughtItem extends ConversationItem {
  const ThoughtItem({
    required super.id,
    required super.createdAt,
    required this.text,
    super.turnId,
    this.isStreaming = false,
  });

  final String text;
  final bool isStreaming;

  ThoughtItem copyWith({String? text, bool? isStreaming}) => ThoughtItem(
    id: id,
    createdAt: createdAt,
    text: text ?? this.text,
    turnId: turnId,
    isStreaming: isStreaming ?? this.isStreaming,
  );
}

/// 工具调用（已与结果配对）。
final class ToolCallItem extends ConversationItem {
  const ToolCallItem({
    required super.id,
    required super.createdAt,
    required this.name,
    super.turnId,
    this.args,
    this.output,
    this.isComplete = false,
  });

  final String name;
  final Map<String, dynamic>? args;

  /// null 表示结果尚未返回。
  final String? output;

  final bool isComplete;

  ToolCallItem copyWith({String? output, bool? isComplete}) => ToolCallItem(
    id: id,
    createdAt: createdAt,
    name: name,
    turnId: turnId,
    args: args,
    output: output ?? this.output,
    isComplete: isComplete ?? this.isComplete,
  );
}

/// 错误项。
final class ErrorItem extends ConversationItem {
  const ErrorItem({
    required super.id,
    required super.createdAt,
    required this.message,
    super.turnId,
    this.isRecoverable = true,
  });

  final String message;
  final bool isRecoverable;
}

/// 归属判定提示（`routing_selected`）。
final class RoutingNoticeItem extends ConversationItem {
  const RoutingNoticeItem({
    required super.id,
    required super.createdAt,
    super.turnId,
    this.groupId,
    this.reason,
  });

  final String? groupId;
  final String? reason;
}

/// 待用户确认（`confirmation_required`）。
final class ConfirmationItem extends ConversationItem {
  const ConfirmationItem({
    required super.id,
    required super.createdAt,
    required this.question,
    super.turnId,
    this.options = const [],
    this.resolved = false,
    this.confirmationId = '',
    this.groupId = '',
  });

  final String question;
  final List<String> options;
  final bool resolved;

  /// **确认卡行的 id**（`chat_confirmations.id`），用于调用 resolve 端点。
  ///
  /// ⚠️ 与 [id]（= `ChatEvent.eventId`）**不是同一个值**。Go 侧
  /// `chatgate.emitConfirmationRequired` 发事件时 `ID: NewID()`，而
  /// `confirmationID` 来自 `EnsureConfirmationCard` 插入的卡行——两者独立生成。
  /// 真正的 id 在 payload 的 `confirmation_id` 里（见
  /// `BuildConfirmationRequiredPayload`）。
  ///
  /// 用 [id] 去 resolve 会 404（`UpdateChatConfirmation` 按 id 更新，0 行受影响），
  /// 表现为「点了确认按钮没反应」。
  ///
  /// 为空串表示事件未携带该字段（异常载荷）；此时 UI 应禁用按钮，
  /// 不要退而用 [id] 去试。
  final String confirmationId;

  /// 该确认卡所属的 group（来自事件的 `group_id`）。
  ///
  /// ## 为什么必须带上它（issue #1）
  ///
  /// 真实写端点是 `POST /api/chat/groups/:group_id/confirmations/:id/resolve`
  /// ——**路径里必须有 group_id**（`ext_routes.go:39` 把 handler 挂在
  /// `/api` 组下的 `chat/groups/:group_id/confirmations`）。
  /// 只凭 `confirmation_id` 无法拼出该路径，故归约时把事件里的 group 带上。
  final String groupId;

  /// 是否可调用 resolve 端点。
  ///
  /// 两个 id 都必须齐备：缺 group_id 拼不出真实路径，缺 confirmation_id 服务端
  /// 0 行受影响。
  bool get canResolve =>
      confirmationId.isNotEmpty && groupId.isNotEmpty && !resolved;
}

/// 归属反馈请求（`routing_feedback_request`）。
///
/// 服务端在 **turn 完成后**发出，问用户「这条消息归到这个对话对吗」。
///
/// ## 为什么不在入队时问（服务端的设计理由，客户端照抄其语义）
///
/// 「归属对不对」只有在用户**看到回答之后**才能答——归属对不对，恰恰要靠
/// 回答是否接得上上下文来判断。入队时问等于让用户猜。
///
/// ## 为什么从 `options` 渲染而不解析 payload 里的 `spec`
///
/// Go 侧 `feedbackRequestPayload` 的注释明示：**Options 是语义真源**（所有
/// 渠道都靠它），Spec 只是其中一种呈现。且 spec 按钮走 `send_next_input`
/// 消息通道（会产生一条用户消息），而客户端可直接调 `resolveFeedback`
/// （一次性 CAS、不产生用户消息）——后者更优。
final class FeedbackRequestItem extends ConversationItem {
  const FeedbackRequestItem({
    required super.id,
    required super.createdAt,
    required this.token,
    super.turnId,
    this.question = '',
    this.options = const [],
    this.chosenGroupId,
    this.evaluatedTurnId,
    this.resolved = false,
  });

  /// 回执锚点（= 请求事件的 event id）。
  ///
  /// 服务端用它直查请求、校验归属、一次性消费。为空表示异常载荷，
  /// 此时 UI 必须禁用按钮——不要用 [id] 去试。
  final String token;

  final String question;

  /// 选项的展示文字（语义真源，来自 payload 的 `options[].label`）。
  final List<String> options;

  /// 当时归到的对话（供 UI 展示「归到《X》对吗」）。
  final String? chosenGroupId;

  /// 被评价的 turn（标注将附到它上面）。
  ///
  /// 与 [turnId] 语义不同：请求事件在完成它的 turn 上，而标注写回被评价的
  /// turn。归约时按它做幂等（对齐服务端的 partial unique index）。
  final String? evaluatedTurnId;

  /// 用户是否已作答（`routing_feedback` 已到达，或本地提交成功后本地标记）。
  final bool resolved;

  /// 是否可提交回执。
  ///
  /// 缺 token 时服务端直查不到请求，提交必然失败。
  bool get canResolve => token.isNotEmpty && !resolved;

  /// 复制并覆盖部分字段（标记已解决时用）。
  ///
  /// 必须带上 [token]：标记已解决**只是渲染状态**，若丢失它，后续任何需要
  /// 重新读取该项的场景都会退化成不可 resolve（服务端按 token 直查）。
  FeedbackRequestItem copyWith({bool? resolved}) => FeedbackRequestItem(
    id: id,
    createdAt: createdAt,
    turnId: turnId,
    token: token,
    question: question,
    options: options,
    chosenGroupId: chosenGroupId,
    evaluatedTurnId: evaluatedTurnId,
    resolved: resolved ?? this.resolved,
  );
}

/// 后续提问建议（`follow_up_suggested`）。
final class FollowUpSuggestionItem extends ConversationItem {
  const FollowUpSuggestionItem({
    required super.id,
    required super.createdAt,
    required this.suggestions,
    this.agentIds = const [],
    super.turnId,
  });

  final List<String> suggestions;

  /// 每条建议适用的 agent（与 [suggestions] **按下标一一对应**，缺失为 null）。
  ///
  /// Go 侧注释：本条建议更适合由哪个 agent 回答（已由服务端校验为 active）。
  /// 点击建议时除追加文本外还应把选中 Agent 切过去——对齐 webapp
  /// FollowUpSuggestCard（先切人再追加，与「选人再提问」的直觉一致）。
  /// 历史建议（功能上线前落库）无此字段，按下标对位 null。
  final List<String?> agentIds;

  /// 下标 [i] 的建议适用的 agent；越界或未标注返回 null。
  String? agentIdAt(int i) =>
      i >= 0 && i < agentIds.length ? agentIds[i] : null;
}

/// 目标进度卡（`goal_gate_decision` 的 spec_schema 渲染产物）。
///
/// 服务端把任务表判定结果编译成 JsonUiSchema（card + progress + metric，
/// `chatgate/goal_gate_spec.go` buildTaskSpec）。归约时保留**原始 spec**、
/// 不在归约层展开字段——进度卡的消费场景是「时间线里看到当轮进度」，
/// 展开字段就得同步维护两份真源；渲染层从 spec 读，与服务端产出一致。
///
/// 这是 webapp 的对应行为：goal_gate_decision 带 spec_schema 时每 turn 取
/// 最后一条（多轮续跑只展示最新进度），渲染进时间线。
final class GoalProgressItem extends ConversationItem {
  const GoalProgressItem({
    required super.id,
    required super.createdAt,
    required this.spec,
    super.turnId,
  });

  /// 解析后的 spec 文档；服务端产出损坏（解析返回 null 的情形）时为 null，
  /// UI 据此跳过渲染。
  final SpecUiDocument? spec;
}

/// 习惯候选建议卡（`habit_suggestion_created` / `habit_suggestion_resolved`）。
///
/// ## 为什么归约层要处理它（而非静默丢弃）
///
/// 该事件由 `workers/habit/timeline_events.go` 的 `TimelineEmitter` 落库并广播，
/// 会随普通时间线一起到达（客户端拉 timeline 时不带 `event_type` 过滤，服务端
/// `chat.go` 在无过滤时返回全部）。它**不是**控制事件——它是用户在对话里看到
/// 「检测到一个习惯，要不要采纳」的**唯一**入口，webapp 与小程序都渲染它。
/// 若不显式处理，它会落到归约器的 `default:` 分支被静默丢弃，用户永远看不到
/// 建议（与 `agent.file.*` 曾被吞掉 2927 条是同一类缺陷）。
///
/// ## 为什么按 suggestionId 幂等，而不是 turnId
///
/// `habit_suggestion_resolved` 附在**与 created 同一个 turn** 上（服务端 resolve
/// 时重新取该 group 最近一条 turn，见 `TimelineEmitter.Emit`），所以同一 turn
/// 上会先有一条 created、后有一条 resolved。按 turnId 合并会把两张卡（不同
/// 建议）错并成一张；按 [suggestionId] 合并才能「created 建卡、resolved 就地
/// 更新同一张卡」。
///
/// 另一重必要性：SSE cursor 回放与 timeline 回填存在交叠窗口，同一事件会被
/// 归约两次，不幂等会看到重复卡片。
final class HabitSuggestionItem extends ConversationItem {
  const HabitSuggestionItem({
    required super.id,
    required super.createdAt,
    required this.suggestionId,
    super.turnId,
    this.topicKey = '',
    this.triggerType = HabitTriggerType.timeBased,
    this.triggerConfig,
    this.preferredAgentId,
    this.targetAcceptanceLevel,
    this.confidence,
    this.reasons = const [],
    this.evidence = const {},
    this.editableFields = const [],
    this.userFeedback,
    this.resolvedPatternId,
    this.snoozeUntil,
  });

  /// 建议 id（`habit_runs.id`）。**身份键**，跨 created/resolved 两个事件不变。
  final String suggestionId;

  /// 主题 key（`rule_draft.topic_key`）。
  final String topicKey;

  final HabitTriggerType triggerType;

  /// 建议的触发配置（watch 与 time_based 形状不同，见 [HabitTriggerConfig]）。
  final HabitTriggerConfig? triggerConfig;

  final String? preferredAgentId;

  /// 采纳后应使用的接受级别。
  final HabitAcceptanceLevel? targetAcceptanceLevel;

  final double? confidence;
  final List<String> reasons;
  final Map<String, dynamic> evidence;
  final List<String> editableFields;

  /// 用户反馈（null = 仍待处理）。
  final HabitUserFeedback? userFeedback;

  /// accept 后建出的 pattern id（resolved 事件的 `resolved_pattern_id`）。
  final String? resolvedPatternId;

  /// snooze 的截止时刻（resolved 事件的 `snooze_until`）。
  final DateTime? snoozeUntil;

  /// 是否仍可操作。
  ///
  /// 与 `FeedbackRequestItem.canResolve` 同思路：服务端 resolve 用 CAS，
  /// 已处理过的建议再提交会 409。本地据此禁用按钮，避免用户点了才被拒。
  bool get canResolve => userFeedback == null;

  /// 是否可编辑（服务端 `editable_fields` 非空）。
  ///
  /// 与 `HabitSuggestion.canEdit` 同一语义，但本类是真源——卡片与编辑器都从
  /// 归约后的时间线项渲染，而不是从列表端点的 `HabitSuggestion`。
  ///
  /// 为 false 时 UI 应**隐藏**编辑入口（而不是渲染成禁用按钮）：服务端没给
  /// 可编辑字段时，对话框会是一个空白表单，提交出的 patch 是 `{}`。
  bool get canEdit => editableFields.isNotEmpty;

  /// 是否已被接受（含 edit_and_accept，两者在服务端都写 `accept_rule`）。
  bool get isAccepted => userFeedback == HabitUserFeedback.accepted;

  /// 从**列表端点**的建议（`GET /api/chat/habit-suggestions`）构造时间线项。
  ///
  /// ## 为什么需要这个转换
  ///
  /// 「建议收件箱」页拿到的是一批 `HabitSuggestion`（`spb_models`），而卡片
  /// （[HabitSuggestionCard]）渲染的是归约后的 [HabitSuggestionItem]。两者字段
  /// 高度重叠但**不是同一个类**（前者是 HTTP 契约，后者带 `turnId` 等归约状态）。
  /// 与其在页面里手抄一份字段映射，不如集中在这里——映射错一个字段就是
  /// 「卡片显示未命名 / 无理由」，且不会报错。
  ///
  /// ## 三处刻意的字段缺口
  ///
  /// - [id]：列表项没有 eventId，用 `suggestionId` 兜底（同一批内唯一，够用）。
  /// - [editableFields]：**列表端点不下发**它（`habitRunToMap` 没有该字段），
  ///   故转换后 [canEdit] 恒为 false——收件箱里不会出现「编辑并接受」按钮。
  ///   这是对的：服务端只从事件 payload 下发白名单，客户端自行填一份会让用户
  ///   编辑出服务端不接受的 patch。
  /// - [resolvedPatternId] / [snoozeUntil]：列表端点把它们埋在
  ///   `feedback_payload` 里（键 `resolved_pattern_id` / `snooze_until`），
  ///   而不是顶层——这里显式挖出来，否则已处理项会显示成「已采纳」（没有
  ///   「习惯已生效」）与「已延后」（没有具体时刻）。
  static HabitSuggestionItem fromSuggestion(HabitSuggestion s) =>
      HabitSuggestionItem(
        id: s.id,
        createdAt: s.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        suggestionId: s.id,
        topicKey: s.topicKey,
        triggerType: s.triggerType,
        triggerConfig: s.triggerConfig,
        preferredAgentId: s.preferredAgentId,
        targetAcceptanceLevel: s.targetAcceptanceLevel,
        confidence: s.confidence,
        reasons: s.reasons,
        evidence: s.evidence,
        editableFields: s.editableFields,
        userFeedback: s.userFeedback,
        resolvedPatternId: _feedbackString(
          s.feedbackPayload,
          'resolved_pattern_id',
        ),
        snoozeUntil: _feedbackTime(s.feedbackPayload, 'snooze_until'),
      );

  static String? _feedbackString(Map<String, dynamic>? payload, String key) {
    final v = payload?[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 从 `feedback_payload` 取时刻。
  ///
  /// 与 `ChatEvent.habitSnoozeUntil` 同约定转本地时区：服务端存的是 UTC 串，
  /// 不转的话 UI 会把「明天 09:00」显示成「今天 01:00」。
  static DateTime? _feedbackTime(Map<String, dynamic>? payload, String key) {
    final s = _feedbackString(payload, key);
    return s == null ? null : DateTime.tryParse(s)?.toLocal();
  }

  HabitSuggestionItem copyWith({
    HabitUserFeedback? userFeedback,
    String? resolvedPatternId,
    DateTime? snoozeUntil,
  }) => HabitSuggestionItem(
    id: id,
    createdAt: createdAt,
    turnId: turnId,
    suggestionId: suggestionId,
    topicKey: topicKey,
    triggerType: triggerType,
    triggerConfig: triggerConfig,
    preferredAgentId: preferredAgentId,
    targetAcceptanceLevel: targetAcceptanceLevel,
    confidence: confidence,
    reasons: reasons,
    evidence: evidence,
    editableFields: editableFields,
    userFeedback: userFeedback ?? this.userFeedback,
    resolvedPatternId: resolvedPatternId ?? this.resolvedPatternId,
    snoozeUntil: snoozeUntil ?? this.snoozeUntil,
  );
}

/// Agent 产出的文件（`agent.file.*`）。
///
/// ## 为什么 [id] 用归一化的相对路径，而非 eventId
///
/// 同一文件的 created → modified → deleted 是**多条事件**，但应收敛成**一张卡**。
/// 若用 eventId 作 id，每条事件各成一项，用户会看到同一文件出现 2–3 次。
/// 用归一化路径（`'/'` 归一、首尾去斜杠、`\\` 转正斜杠）作身份键，
/// 归约时原地更新同一张卡。
///
/// ## 为什么 deleted 不删卡而是置 [action]=deleted
///
/// 用户应看到「这个文件被删了」（卡片置灰、禁用下载），而不是它凭空消失——
/// 后者会让人怀疑「文件到底生成了没有」。对齐 webapp `mergeFileEventLifecycle`。
final class AgentFileItem extends ConversationItem {
  const AgentFileItem({
    required super.id,
    required super.createdAt,
    required this.relativePath,
    required this.fileName,
    required this.displayName,
    required this.action,
    super.turnId,
    this.ufsFileId,
    this.mimeType,
    this.sizeBytes,
    this.ttsKind,
    this.modifiedAt,
    this.deletedAt,
  });

  /// 归一化的相对路径（作 [id] 与唯一身份）。删除事件也靠它收敛。
  final String relativePath;

  /// 真实文件名（含扩展名）：预览类型判定 / UFS 跳转依赖它，勿用 [displayName]。
  final String fileName;

  /// 用户可见展示名：`nice_name` 优先，否则等于 [fileName]。
  final String displayName;

  /// 生命周期最新状态（created/modified/deleted）。卡片徽标据此展示，
  /// deleted 时禁用全部下载/预览入口（UFS 已软删）。
  final String action;

  /// UFS 文件 id。删除事件无此字段（null）→ 下载入口禁用。
  final String? ufsFileId;

  final String? mimeType;

  /// 删除事件无此字段（null）。
  final int? sizeBytes;

  /// 若为 TTS 语音产物则为对应流种类，否则 null（普通文件卡）。
  //
  // 由归约器用 [parseTTSAudioPath] 计算后注入。null 表示非 TTS 产物，
  // 渲染为普通文件卡；非 null 渲染为语音条目（[TtsStreamKind.narration] 默认折叠）。
  final TtsStreamKind? ttsKind;

  /// 同一文件的后续生命周期时间点（卡片副行展示「创建 → 更新 → 删除」）。
  /// 首次创建时间用基类的 [createdAt]（归约时保持首次出现的时间作错锚点）。
  final DateTime? modifiedAt;
  final DateTime? deletedAt;

  /// 是否已被删除（UFS 软删，下载入口应禁用）。
  bool get isDeleted => action == 'deleted';

  /// 是否为图片（缩略图自动内联渲染的依据）。
  bool get isImage {
    final mt = mimeType;
    if (mt == null) return false;
    return mt.toLowerCase().startsWith('image/');
  }
}
