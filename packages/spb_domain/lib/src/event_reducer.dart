import 'package:spb_models/spb_models.dart';

import 'conversation_item.dart';

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

      switch (ev.eventType) {
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
            ),
          );

        case EventTypes.confirmationResolved:
          // 把对应的 confirmation 标记为已解决（按 turnId 匹配最近一条）。
          for (var i = items.length - 1; i >= 0; i--) {
            final it = items[i];
            if (it is ConfirmationItem && !it.resolved) {
              items[i] = ConfirmationItem(
                id: it.id,
                createdAt: it.createdAt,
                turnId: it.turnId,
                question: it.question,
                options: it.options,
                resolved: true,
              );
              break;
            }
          }

        case EventTypes.followUpSuggested:
          final suggestions = ev.followUpSuggestions;
          if (suggestions.isNotEmpty) {
            items.add(
              FollowUpSuggestionItem(
                id: ev.eventId,
                createdAt: ev.createdAt,
                turnId: ev.turnId,
                suggestions: suggestions,
              ),
            );
          }

        default:
          // heartbeat / queue_state / gate_* / tts_* / goal_* 等控制事件
          // 不进入对话列表。它们由专门的状态层消费（如连接指示器、TTS 播放器）。
          break;
      }
    }

    return ReductionResult(items: items, lastEventId: lastEventId);
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
}

/// 归约输出。
class ReductionResult {
  const ReductionResult({required this.items, required this.lastEventId});

  final List<ConversationItem> items;

  /// 最后一个落库事件的 ID，用作 SSE 重连 cursor。
  final String lastEventId;
}
