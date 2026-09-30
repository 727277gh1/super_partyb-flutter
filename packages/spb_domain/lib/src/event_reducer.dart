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
              ),
            );
          }

        case EventTypes.agentFileCreated:
        case EventTypes.agentFileModified:
        case EventTypes.agentFileDeleted:
          _mergeAgentFile(items, ev);

        default:
          // heartbeat / queue_state / gate_* / tts_* / goal_* 等控制事件
          // 不进入对话列表。它们由专门的状态层消费（如连接指示器、TTS 播放器）。
          break;
      }
    }

    return ReductionResult(items: items, lastEventId: lastEventId);
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
  const ReductionResult({required this.items, required this.lastEventId});

  final List<ConversationItem> items;

  /// 最后一个落库事件的 ID，用作 SSE 重连 cursor。
  final String lastEventId;
}
