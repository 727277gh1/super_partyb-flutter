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
  });

  final String question;
  final List<String> options;
  final bool resolved;
}

/// 后续提问建议（`follow_up_suggested`）。
final class FollowUpSuggestionItem extends ConversationItem {
  const FollowUpSuggestionItem({
    required super.id,
    required super.createdAt,
    required this.suggestions,
    super.turnId,
  });

  final List<String> suggestions;
}
