import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_ui/spb_ui.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';

import 'agent_file_batch_card.dart';
import 'agent_file_card.dart';
import 'agent_file_preview.dart';
import 'assistant_message_bubble.dart';
import 'confirmation_card.dart';
import 'conversation_search_sheet.dart';
import 'feedback_request_card.dart';
import 'flush_strategy_dialog.dart';
import 'follow_up_chips.dart';
import 'habit_auto_run_card.dart';
import 'habit_suggestion_card.dart';
import 'message_composer.dart';
import 'outbox_bar.dart';
import 'spec_ui_card.dart';
import 'pending_messages_bar.dart';
import 'row_locate_registry.dart';
import 'thought_tile.dart';
import 'tool_call_tile.dart';
import 'user_message_bubble.dart';

/// 溢出菜单的一项（窄屏时收纳 AppBar 的低频入口）。
///
/// 见 [ConversationPage.overflowItems] 与 issue #31。
class ConversationOverflowItem {
  const ConversationOverflowItem({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 菜单项的测试键。
  ///
  /// **不要**复用宽屏那个 `IconButton` 的 key：同一个 key 指向两种交互会让
  /// 断言的含义随窗口宽度漂移（宽屏找到按钮、窄屏找到菜单项）。
  final Key key;

  final IconData icon;

  final String label;

  /// 点击动作。null = 该项禁用（如 `_group` 未就绪）。
  ///
  /// ## 为什么是禁用而不是不传这一项
  ///
  /// 与 AppBar 图标同一取舍（见 [ConversationPage.actions] 的注释）：入口
  /// 消失会让用户以为「本端不支持这个功能」，而置灰只说明「现在还用不了」。
  final VoidCallback? onTap;
}

/// 对话页：时间线 + 输入框。
///
/// ## 数据来源
///
/// [controller] 的 `items` 流（归约后的 `List<ConversationItem>`）。页面**不做**
/// 任何归约/合并——那是 `spb_domain` 的职责，页面只负责渲染。
///
/// ## 自动滚到底
///
/// 新项到达时若用户**已在底部附近**则自动滚到底；若用户正在向上翻看历史
/// 则**不打扰**（否则滚动位置会被强制拽走，无法回看）。判定阈值见
/// [_autoScrollThreshold]。
///
/// 这是桌面 IM 的标准行为：无条件自动滚动会让「用户正在读历史时来一条新消息」
/// 变成一场与滚动的拔河。
class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.controller,
    this.title,
    this.onResolveConfirmation,
    this.onResolveFeedback,
    this.onAcceptHabit,
    this.onEditAndAcceptHabit,
    this.onDismissHabit,
    this.onSnoozeHabit,
    this.onSpecAction,
    this.onSelectAgent,
    this.onSend,
    this.onRetryTurn,
    this.enableSearch = false,
    this.overflowItems,
    this.onFlush,
    this.onFlushWithStrategy,
    this.onCancelTurn,
    this.onLoadOlder,
    this.onReconnect,
    this.onDownloadAgentFile,
    this.onLoadThumbnailAgentFile,
    this.onOpenAgentFile,
    this.onRevealAgentFile,
    this.onPreviewAgentFile,
    this.onOpenLink,
    this.historyKey,
    this.loadPending,
    this.undoPending,
    this.pendingReloadKey,
    this.activities,
    this.activitiesSnapshot,
    this.contextUsage,
    this.contextUsageSnapshot,
    this.executionStatus,
    this.executionStatusSnapshot,
    this.ttsStatus,
    this.ttsStatusSnapshot,
    this.staleTurnIds,
    this.staleTurnIdsSnapshot,
    this.outboxEntries,
    this.outboxSnapshot,
    this.onCancelOutbox,
    this.onRetryOutbox,
    this.onRemoveOutbox,
    this.actions,
    this.emptyHint = '还没有对话，输入消息开始吧',
  });

  final ChatStreamController controller;

  /// AppBar 右侧追加的操作（不覆盖连接指示等内置项）。
  ///
  /// ## 为什么提供这个插槽而不要求调用方自建 Scaffold
  ///
  /// 桌面端要在 AppBar 放「交付物侧边栏开关」，但它不属于对话页的固有部件
  /// （移动端没有侧边栏）。提供一个**只在尾部追加**的插槽，移动端不传即可，
  /// 无需各平台自建一整套 Scaffold。
  final List<Widget>? actions;

  /// AppBar 标题。null 时不显示 AppBar。
  final String? title;

  /// 确认卡选项回调。参数为（group id, 卡行 id, 选项文案）。
  ///
  /// ## 为什么必须带 groupId（issue #1）
  ///
  /// 真实写端点是 `POST /api/chat/groups/:group_id/confirmations/:id/resolve`
  /// ——路径里必须有 group_id。只传 confirmationId 无法拼出该路径，
  /// 调用方只能报 404（且是静默的）。
  ///
  /// 为 null 时确认卡按钮禁用。
  final void Function(String groupId, String confirmationId, String option)?
  onResolveConfirmation;

  /// 归属反馈卡回调。参数为（回执 token, 是否准确）。
  ///
  /// 与 [onResolveConfirmation] 同理注入：真实写端点是
  /// `POST /chat/feedback/:token/resolve`，页面只收集意图，请求与错误翻译
  /// 归调用方（也使 widget test 无需 HTTP mock）。
  ///
  /// 为 null 时反馈卡按钮禁用。
  final void Function(String token, bool correct)? onResolveFeedback;

  /// 习惯建议卡：接受（`action=accept`）。
  ///
  /// 服务端会据此建出 active pattern（`misc_extra.go` 的
  /// `createPatternFromSuggestion`），所以这是**有副作用的写操作**，
  /// app 层应给出成功/失败反馈。
  ///
  /// 为 null 时接受按钮不显示。
  final void Function(HabitSuggestionItem suggestion)? onAcceptHabit;

  /// 习惯建议卡：忽略（`action=dismiss`，服务端写 24h 冷却窗口）。
  final void Function(HabitSuggestionItem suggestion)? onDismissHabit;

  /// 习惯建议卡：就地编辑后接受（`action=edit_and_accept` + `pattern_patch`）。
  ///
  /// 与 [onAcceptHabit] 同属「建出 active pattern」的写操作，区别只是服务端
  /// 会先把 patch 合并进候选值（`applyPatternPatch`，出现即覆盖、未出现即保留）。
  ///
  /// patch 的字段集由服务端下发的 `editable_fields` 决定（见
  /// `HabitSuggestionEditor`），本页不做任何筛选。
  ///
  /// 为 null 时编辑入口不显示。
  final void Function(
    HabitSuggestionItem suggestion,
    Map<String, dynamic> patch,
  )?
  onEditAndAcceptHabit;

  /// 习惯建议卡：稍后提醒（`action=snooze` + 选中的时长）。
  ///
  /// 时长→`snooze_until` 的换算在 [HabitSnoozeOption.untilIso]（UTC），
  /// 不由本页做：那是契约计算，归 `spb_models`，否则两个端会算出不同时区。
  final void Function(HabitSuggestionItem suggestion, HabitSnoozeOption option)?
  onSnoozeHabit;

  /// spec 卡片上的动作回调（建议卡 `copy_text`、归属反馈卡 `send_next_input`）。
  ///
  /// 页面只上抛动作，由 app 层决定怎么处理（copy_text → 回填输入框、
  /// send_next_input → 直接发送），保持「页面不持有 ChatApi」的分层约定。
  final void Function(SpecUiAction action)? onSpecAction;

  /// 把选中 Agent 切到指定 id（建议卡标注了 agent_id 时）。
  ///
  /// 与 [onSpecAction] 分开：切 agent 是**本地 UI 状态**，不是网络动作，
  /// app 层只需 setState 即可，走同一回调会把两件事耦合。
  final void Function(String agentId)? onSelectAgent;

  /// 自定义发送逻辑。为 null 时用 `controller.send(input: text)`。
  ///
  /// 之所以可覆盖：悬浮窗等入口走 `QuickCaptureUseCase`（无归属），
  /// 而本页是「已知 group」的常规发送。
  final Future<void> Function(String text)? onSend;

  /// 重发一个**已失败**的 turn（用原输入重新投递一轮）。
  ///
  /// ## 为什么需要它
  ///
  /// `error` 事件是回合终态（服务端不会再产出任何内容），用户唯一的出路是
  /// 把那段输入再发一次。没有这个入口，用户只能手动重打一遍——而重打的输入
  /// 会变成一个**新 turn**，与失败那轮并列显示，历史里留下两条几乎一样的用户
  /// 消息（webapp 的 `handleRetryTurn` 正是为此存在）。
  ///
  /// ## 为什么不复用 `onSend`
  ///
  /// `onSend` 的语义是「发一条**新**消息」：它走 `/users/:uid/chat/messages`
  /// 的完整前置链（分类 → 路由 → 归属判定），并生成新的 `request_id`。
  /// 重发要的是「锁定原 group + 原 agent，不再跑路由」，并**换一个新
  /// `request_id`**（否则命中幂等去重，返回那个已失败的 turn，等于什么都没做）。
  /// 这两点在装配层用 [ChatStreamController.send] 的 `groupId`/`agentId`/
  /// `routingMode` 参数表达，页面不该知道。
  ///
  /// 参数是失败 turn 的输入文本与当时选中的 agent。
  ///
  /// 为 null 时错误条不展示「重发」按钮。
  final Future<void> Function(String text, String? agentId)? onRetryTurn;

  /// 「立即发送」：把服务端缓冲区里已 pending 的消息立即合并提交。
  ///
  /// null = 不显示该入口（如移动端或未接线时）。
  ///
  /// 与 [onSend] 的区别见 `MessageComposer` 的类文档：前者发**新的一条**，
  /// 本回调推**已经排队的那批**。
  ///
  /// 返回 [FlushResult] 而非 `void`：服务端可能回 `confirmation_required`
  /// （HTTP 200 但**什么都没提交**），需要选策略后重试。
  final FlushPending? onFlush;

  /// 按用户选定的冲突策略重新提交（[onFlush] 返回待确认时才会用到）。
  final FlushWithStrategy? onFlushWithStrategy;

  /// 下载 agent 文件产物的回调。null 时下载按钮禁用。
  ///
  /// 页面不直接依赖 `spb_api`：真实下载（`UfsApi.download` + 落盘）由 app 层注入。
  final Future<void> Function(AgentFileItem file)? onDownloadAgentFile;

  /// 加载 agent 文件缩略图（仅图片类有意义）。返回字节则内联渲染，null/失败退化为图标。
  ///
  /// 与 [onDownloadAgentFile] 同取向：页面不依赖 `spb_api`，真实请求
  /// （`UfsApi.thumbnail`）由 app 层注入。
  ///
  /// **未注入时卡片完全不发请求**（`AgentFileCard._maybeLoadThumbnail` 在
  /// loader 为 null 时直接返回），故只读时间线用法不受影响。
  final Future<List<int>?> Function(AgentFileItem file)?
  onLoadThumbnailAgentFile;

  /// 用系统默认程序打开 agent 文件（的本地副本）。
  ///
  /// 与 [onDownloadAgentFile] 同取向：页面不碰平台 IO，真实动作
  /// （解析本地路径 → 必要时先下载 → `caps.openFile`）由 app 层注入。
  ///
  /// **为 null 时卡片不渲染该菜单项**（而非渲染一个点了没反应的项）。
  /// 移动端就是这样：它注入 `NoopDesktopCapabilities`，`openFile` 恒 false，
  /// 接上只会让用户点「打开」得到「无法打开文件」。
  final OpenAgentFile? onOpenAgentFile;

  /// 在系统文件管理器中定位 agent 文件。null 时不渲染该菜单项（同
  /// [onOpenAgentFile]）。
  final RevealAgentFile? onRevealAgentFile;

  /// 文件预览能力（文本 / 图片 / 外部跳转）。
  ///
  /// 与 [onDownloadAgentFile] 同取向：页面不依赖 `spb_api`，真实取数
  /// （`UfsApi.download`）与 URL 拼接由 app 层注入。
  ///
  /// **为 null 时卡片不渲染预览按钮**——只读时间线用法完全不受影响。
  final AgentFilePreviewCallbacks? onPreviewAgentFile;

  /// 打开 Markdown 回复里的链接。null 时链接不响应点击（仅保留样式）。
  ///
  /// 与 [onDownloadAgentFile] 同理：打开 URL 属平台 IO（桌面端走 `xdg-open` /
  /// `open` / `explorer`，移动端走 `url_launcher`），页面只收集意图，由 app
  /// 层注入。
  final void Function(String url, String title)? onOpenLink;

  /// 停止正在生成的轮次（入参是 [ConversationItem.turnId]）。
  ///
  /// ## 为什么用注入而不是直接调 `ChatApi.cancelTurn`
  ///
  /// 与 [onResolveConfirmation] 同理：本页只收集意图（用户点了停止），请求与
  /// 错误翻译归调用方。页面不持有 `ChatApi`，故 widget test 里无需 HTTP mock
  /// 就能验证「什么条件下可点、点了传什么 turnId」。
  ///
  /// 为 null 时**不展示**停止按钮（保持「只读时间线」用法）。
  final Future<void> Function(String turnId)? onCancelTurn;

  /// 向上翻页：加载更早的历史。
  ///
  /// 返回 `false` 表示「已到最早一条」，本页据此**停止**继续触发——否则每次滚动
  /// 到顶部都会发一个注定为空的请求（服务端游标 `global_seq < 0` 恒无结果）。
  ///
  /// 为 null 时不展示「加载更早」入口（保持「只读时间线」用法）。
  final Future<bool> Function()? onLoadOlder;

  /// 手动重连 SSE。
  ///
  /// ## 为什么需要它
  ///
  /// `SseClient` 自带指数退避重连，但退避到 `maxRetries` 后会把状态置为
  /// [SseState.failed] **永久停手**；而 `reconnecting` 期间遇到长退避时，用户
  /// 也可能不想等。两种情况下用户都需要一个「现在就再试一次」的入口。
  ///
  /// ## 为什么用注入而不是直接调 `controller.reconnect()`
  ///
  /// 与 [onCancelTurn] 同理：页面只收集意图，请求归调用方。页面已在用
  /// `controller` 读 items/连接状态，但重连是**动作**而非数据，注入后 widget
  /// test 里不需要真 SseClient 就能验证「什么状态下可点、点了几次」。
  ///
  /// 为 null 时指示器不可点（保持纯展示）。
  final VoidCallback? onReconnect;

  /// 当前对话的身份（两端都传 `groupId`）。
  ///
  /// ## 为什么必须显式传，而不能自己看出来
  ///
  /// 翻页终止标记（「已到最早一条」）的**有效范围是「一个对话」**，换了对话必须
  /// 重置。但本页无法自行察觉切换：SSE 是 user 级订阅，切 group 走的是
  /// `ChatStreamController.switchGroup`——**控制器实例不变**，`_ChatPage` 也未带
  /// `key`，故 State 被复用，`didUpdateWidget` 里 `oldWidget.controller ==
  /// widget.controller`。
  ///
  /// 不重置的后果：在 A 对话翻到头后切到 B，`_reachedOldest` 仍是 true，B 的
  /// 历史永远翻不出来（且毫无报错）。
  ///
  /// 不复用 [pendingReloadKey]：那个参数只在待处理栏接线时才存在，而翻页与它
  /// 无关——两者的值碰巧都是 groupId，但耦合会让「只接线待处理栏」的用法
  /// 静默带走翻页的正确性。
  final String? historyKey;

  /// 加载当前 group 的待处理收件箱消息。
  ///
  /// ## 为什么是「加载 + 撤销」两个回调，而不是收一个 `ChatApi`
  ///
  /// 撤销需要 **userId**（`POST /users/:uid/chat/messages/:id/undo`），而页面
  /// 不该知道 userId 从哪来（那要走 `/api/auth/me`，两端时机不同）。注入后
  /// 本页在 widget test 里可以完整验证（含 409 分支），不需要 HTTP mock。
  ///
  /// 为 null 时不展示待处理栏（保持「只读时间线」用法）。
  final LoadPendingMessages? loadPending;

  /// 撤销一条待处理消息（参数是 `ChatInboxMessage.id`，不是 turn id）。
  final UndoPendingMessage? undoPending;

  /// 变化时重新加载待处理消息（传 groupId）。
  ///
  /// 见 [PendingMessagesBar.reloadKey]：切换 group 时 State 会被复用，
  /// 不靠这个键就会一直显示上一个 group 的待处理消息。
  final String? pendingReloadKey;

  /// 执行中活动快照流（`turn_activity`，Transient）。
  ///
  /// ## 它解决什么问题
  ///
  /// 执行器在「已起跑但还没吐出任何正文」的空窗期是静默的（读代码、跑 bash、
  /// 等模型首 token），此时时间线不动，用户分不清「在干活」与「卡死了」。
  /// 本流携带「已运行多久 + 上一步是什么」，用于展示进度。
  ///
  /// ## 为什么是 Map 而不是单条快照
  ///
  /// SSE 是 user 级订阅，一条流里可能同时存在多个 turn 的活动。单条快照只能
  /// 表达「最近一次事件属于哪个 turn」，若那个 turn 不是当前流式的 turn，
  /// 页面就无法拿到自己需要的那条。Map 按 turnId 索引，直查即得。
  ///
  /// 为 null 时不展示活动指示（与 [activitiesSnapshot] 一同省略）。
  final Stream<Map<String, TurnActivitySnapshot>>? activities;

  /// 首帧活动快照（供首屏渲染，避免等下一次推送）。
  ///
  /// 与 [activities] 的关系同 `controller.snapshot` 与 `controller.items`：
  /// 快照是同步初值，流是后续增量。两者都要传，否则「事件在订阅前已到达」
  /// 会让指示器到下一次心跳（约 15s）才出现。
  final Map<String, TurnActivitySnapshot>? activitiesSnapshot;

  /// 上下文用量流（`context_update` 归约输出）。
  ///
  /// ## 为什么渲染在顶部而不在时间线里
  ///
  /// 用量是**持续变化的一行状态数字**（每次压缩、每轮 pigo 收尾都会刷），
  /// 不是对话正文。进时间线会不断插入/更新条目把对话冲散，而回看历史时
  /// 旧值毫无意义。webapp 同样把它放在状态侧边栏（`WorkbenchStatusSidebar`）
  /// 而非消息流。
  ///
  /// ## 与 [activities] 同取向
  ///
  /// 都是「调用方注入才订阅」的旁路状态：未注入时本页是纯只读时间线。
  /// 为 null 时不展示用量区。
  final Stream<ContextUsage?>? contextUsage;

  /// 首帧用量快照（同步初值）。
  ///
  /// 读 `controller.contextUsageSnapshot` 是同步 getter，建立不了依赖，故首帧
  /// 值必须由调用方显式传入（同 [activitiesSnapshot]）。
  final ContextUsage? contextUsageSnapshot;

  /// 执行等待/重试状态流（`queue_state` / `retry_scheduled` 归约输出）。
  ///
  /// ## 它回答什么
  ///
  /// 「我发了消息，为什么还没回复」——是**在排队等名额**，还是**在重试**。
  /// 两者在时间线上都没有任何内容，没有它就只能干等。
  ///
  /// ## 与 [activities] 的关系：同一槽位，本流优先
  ///
  /// [activities] 是「已在跑但没正文」，本流是「还没开始跑」。两者不会同时
  /// 有意义，故共用时间线底部那一条状态位，且本流胜出（对齐 webapp 的
  /// `turn.activity && !turn.queueReason` 判定）。
  ///
  /// 为 null 时不展示。未注入时本页不展示等待提示（同 [activities]）。
  final Stream<ExecutionStatus?>? executionStatus;

  /// 首帧等待状态（同步初值，同 [contextUsageSnapshot]）。
  final ExecutionStatus? executionStatusSnapshot;

  /// 语音播报状态流（`tts_started` / `tts_completed` / `tts_failed` 归约输出）。
  ///
  /// ## 只做状态展示，不引入播放
  ///
  /// 客户端既有决策是「TTS 仅下载不播放」（AGENTS.md §11：无音频播放插件）。
  /// 本参数只驱动一条状态文字，**不**持有可播放句柄、**不**触发播放；
  /// 音频文件仍走交付物同步链路。
  ///
  /// ## 为什么贴顶而不进时间线
  ///
  /// 语音是文本回复的衍生物，不是独立的一条回复。它又是「最近一次播报」的
  /// 单值状态（终态事件在 turn 结束后才到达，那时已无流式项可关联），故与
  /// [contextUsage] 同属**常驻读数区**，不进时间线。
  ///
  /// 为 null 时不展示。未注入时本页不展示播报状态。
  final Stream<TtsStatus?>? ttsStatus;

  /// 首帧播报状态（同步初值，同 [contextUsageSnapshot]）。
  ///
  /// 非空：无播报事件时为 [TtsPhase.idle]，UI 用 [TtsStatus.hasStatus] 判断。
  final TtsStatus? ttsStatusSnapshot;

  /// 「长时间无进展」的 turn 集合流（见 `ChatStreamController.staleTurnIds`）。
  ///
  /// ## 为什么由 app 层注入而不是页面自己计时
  ///
  /// 判据是「距最后一次事件」——而 `turn_activity` 是「执行器仍在跑」的直接
  /// 证据却**不进 [controller.items]**（走 activities 通道）。页面只看得见
  /// items，据此计时会把「只有工具心跳、尚无正文」的长 turn 误判成卡死。
  ///
  /// ## 语义是提示，不是终态
  ///
  /// 收到某个 turnId 时，本页**只**做两件事：停掉它的流式光标、让位提示条。
  /// **不**禁用取消——turn 可能真在跑，而取消是用户此时唯一的出路。
  ///
  /// 未注入时不展示超时提示——保持本页在未接线时仍是纯只读时间线
  /// （同 [onCancelTurn] / [activities] 的取向）。
  final Stream<Set<String>>? staleTurnIds;

  /// 超时集合的同步初值（同 [contextUsageSnapshot]）。
  final Set<String>? staleTurnIdsSnapshot;

  /// 离线队列的「待发送」条（issue #26 切片 C / issue #30）。
  ///
  /// null = 不展示（未接线时；页面单测不必造队列）。
  ///
  /// ## 为什么是「一个流 + 一个快照 + 三个回调」，而不是直接注入 `OutboxQueue`
  ///
  /// 与 `loadPending` / `undoPending` 同一取向：本包只做渲染与交互，网络/存储
  /// 实现由 app 注入。且本包只依赖契约类型 `OutboxEntry`，不需要知道队列的
  /// 重试/持久化实现。
  ///
  /// ## 为什么快照与流都要（同 `activities` 的取向）
  ///
  /// 页面可能在队列已有条目**之后**才挂载（从列表页点进来）。只看流会错过
  /// 那一次推送，首帧显示为空。
  final Stream<List<OutboxEntry>>? outboxEntries;

  /// 队列快照（供首帧渲染）。
  final List<OutboxEntry>? outboxSnapshot;

  /// 取消一条待发送消息（返回 false = 被拒绝，条目正在投递中）。
  final Future<bool> Function(String id)? onCancelOutbox;

  /// 手动重试一条（针对彻底失败的条目）。
  final Future<bool> Function(String id)? onRetryOutbox;

  /// 丢弃一条（删除，不再投递）。
  final Future<void> Function(String id)? onRemoveOutbox;

  /// 是否在 AppBar 展示「在本对话中搜索」入口。
  ///
  /// ## 为什么由本页自己实现（而不是交给 app 层）
  ///
  /// 搜索命中后要**滚回时间线的某一条**，那需要本页的 `ScrollController` 与
  /// 归约后的 `_items`。两者都是页面私有 State，app 层拿不到。故本参数是
  /// **开关**，不是实现注入。
  ///
  /// ## 为什么默认 false
  ///
  /// 移动端 AppBar 此前已无余量（见 issue #31：≤412dp 溢出），若默认开启会
  /// 把「未接线的调用方」也一起撑破。故默认关闭，由各端在确认空间足够后
  /// 显式打开（桌面端有宽屏空间；移动端先修 AppBar 再开）。
  final bool enableSearch;

  /// 窄屏溢出菜单的条目。null = 不渲染溢出菜单（宽屏或未接线）。
  ///
  /// ## 为什么由调用方提供条目、页面负责渲染
  ///
  /// 三个低频入口（对话设置 / 任务清单 / 目标历史）的**动作**属于各端
  /// （它们各自持有弹层与 State），而「在本对话中搜索」的**动作**属于本页
  /// （需要页面的 `ScrollController` 与 `_items`）。
  ///
  /// 故页面把两者合成一个菜单：调用方给条目，页面把自己的搜索项**追加在
  /// 末尾**并渲染整个菜单。若让调用方渲染菜单，搜索项就得由调用方触发——
  /// 而它拿不到页面私有 State。
  ///
  /// 见 issue #31（窄屏 AppBar 溢出）。
  final List<ConversationOverflowItem>? overflowItems;

  final String emptyHint;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final _scrollController = ScrollController();

  /// 时间线上每个展示行的 `GlobalKey`，供搜索命中后滚动定位。
  ///
  /// 注册 + 回收的规则见 [RowLocateRegistry]（issue #39：此前只 `putIfAbsent`
  /// 从不回收，跨 group 切换持续累积）。
  final _rowKeys = RowLocateRegistry();

  /// 已提交 resolve 的卡行 id（本地去重，避免重复点击发出两次请求）。
  ///
  /// 服务端有 CAS（`pending` → `resolved` 首次写入才生效），重复请求不会造成
  /// 数据错误，但会让 UI 出现两次 loading。本地记录更简单直接。
  final _resolving = <String>{};

  /// 已提交 resolveFeedback 的回执 token（防重复点击，与 [_resolving] 同理）。
  ///
  /// 服务端 CAS 保证重复请求无数据错误，但会让 UI 出现两次 loading。
  final _resolvingFeedback = <String>{};

  /// 已提交过操作的**建议 id**（防重复点击，与上面两个同理）。
  ///
  /// 用 suggestionId 而非事件 id：resolved 事件到达后卡片会换成结果行，
  /// 这中间的窗口靠本集合关掉，否则用户可以连点两下「让它自动做」
  /// ——服务端会建出两条 pattern。
  final _resolvingHabit = <String>{};

  /// 追加到输入框的草稿通道（spec 卡 copy_text 动作的「回填输入框」路径）。
  ///
  /// 页面持有它并传给 [MessageComposer.draft]：spec 卡在**时间线里**，而输入框
  /// 在页面底部，两者是兄弟节点，没有更近的共同祖先可放状态。
  final _draft = ValueNotifier<String>('');

  /// 正在提交「停止生成」请求。
  ///
  /// ## 为什么需要它（而不是只看 isStreaming）
  ///
  /// 停止是一次往返请求，而服务端的 `done` 事件要等**下一轮**才会到达。这中间
  /// 的窗口里流式标记仍是 true，按钮会保持可点；用户再点一次会得到
  /// `409 turn not cancellable (not queued/running)`——一个从用户视角看毫无道理
  /// 的错误（他刚点了停止，界面却说不能停止）。用本地标记把窗口关掉。
  ///
  /// 不需要「请求失败就恢复」的特殊逻辑：finally 里无条件复位，若 `done` 已先
  /// 到达，复位后按钮依然禁用（因为流式项已被 `_sealStreaming` 闭合）。
  bool _cancelling = false;

  /// 正在重发的 turn id（null = 没有）。
  ///
  /// 与 [_cancelling] 同一取向：重发是写操作，按钮在请求往返期间必须禁用，
  /// 否则连点两次会产生两个新 turn。
  String? _retryingTurnId;

  /// 是否已到最早一条历史（[ConversationPage.onLoadOlder] 返回过 false）。
  ///
  /// 一旦为 true 就不再触发，避免在顶部反复发空请求。
  bool _reachedOldest = false;

  /// 正在加载更早的历史（防止滚动过程中并发发多次请求）。
  bool _loadingOlder = false;

  /// 顶部触发阈值（像素）。
  ///
  /// 不用 0：`ListView` 的滚动位置在快速滑动时可能一瞬间就到 0，留一点余量
  /// 可以提前取下一页，让「滑到顶」与「内容已就位」重合而不是先看到空白。
  static const double _loadOlderThreshold = 120;

  /// 「算作在底部」的阈值（像素）。
  ///
  /// 不用 0：列表内容高度与视口高度在滚动过程中有细微抖动（图片解码、
  /// 字体加载），严格等于 maxScrollExtent 会导致自动滚动时断时续。
  static const double _autoScrollThreshold = 80;

  StreamSubscription<List<ConversationItem>>? _itemsSub;
  List<ConversationItem> _items = const [];

  /// 时间线是否来自本地缓存（issue #29 切片 B）。
  ///
  /// 与 [_items] 同取向：存在 State 里 + 订阅推送时 setState。初值取控制器
  /// 快照——页面可能在控制器已回落到缓存**之后**才挂载（如从列表页进入），
  /// 只看流会错过那一次推送。
  bool _timelineFromCache = false;
  StreamSubscription<bool>? _fromCacheSub;

  /// 离线队列快照（issue #30）。
  List<OutboxEntry> _outbox = const [];
  StreamSubscription<List<OutboxEntry>>? _outboxSub;

  /// `turn_activity` 订阅与最近一次快照（按 turnId 索引）。
  ///
  /// 与 [_items] 同取向：存在 State 里 + 订阅推送时 setState。若在 build 里
  /// 读 `controller.activitiesSnapshot`，那是同步 getter，建立不了依赖，
  /// 事件到达时**不会**触发重建（指示器永远不出现）。
  StreamSubscription<Map<String, TurnActivitySnapshot>>? _activitiesSub;
  Map<String, TurnActivitySnapshot> _activities = const {};

  /// `context_update` 订阅与最近一次用量快照。
  ///
  /// 与 [_activities] 同取向：存在 State 里 + 订阅推送时 setState。若在 build
  /// 里读 `controller.contextUsageSnapshot`（同步 getter），事件到达时**不会**
  /// 触发重建，用量区永远停在首帧值。
  StreamSubscription<ContextUsage?>? _contextUsageSub;
  ContextUsage? _contextUsage;

  /// `queue_state` / `retry_scheduled` 订阅与最近一次等待状态。
  ///
  /// 与 [_contextUsage] 同取向：存 State + 订阅推送时 setState。
  StreamSubscription<ExecutionStatus?>? _executionStatusSub;
  ExecutionStatus? _executionStatus;

  /// `tts_*` 订阅与最近一次播报状态。
  ///
  /// 与 [_executionStatus] 同取向：存 State + 订阅推送时 setState。
  StreamSubscription<TtsStatus?>? _ttsStatusSub;

  /// 最近一次播报状态；null 仅表示「尚未收到任何快照」，与 idle 区分开
  /// （idle 是收到快照但无播报，null 是还没订阅到）。
  TtsStatus? _ttsStatus;

  /// `staleTurnIds` 订阅与最近一次超时集合。
  ///
  /// 与 [_activities] / [_contextUsage] 同取向：存在 State 里 + 订阅推送时
  /// setState（在 build 里读一个同步 getter 建立不了依赖）。
  StreamSubscription<Set<String>>? _staleTurnIdsSub;
  Set<String> _staleTurnIds = const {};

  /// 是否跟随底部。
  ///
  /// ## 为什么用状态标志而不是每次重新测量位置
  ///
  /// 直觉做法是在新项到达时测「当前位置是否在底部」。但**流式回复会在几十毫秒内
  /// 连续到达多个事件**，而自动滚动是 150ms 动画——上一次动画还在路上时，
  /// 新内容已把 maxScrollExtent 撞大，此时测量必然得到「不在底部」，
  /// 于是自动跟随**永久停掉**（用户没做任何操作，消息却不再跟随）。
  ///
  /// 用标志位：只在**滚动事件**里更新它（用户上滑 → false，回到接近底部 → true）。
  /// 新增内容本身不触发滚动事件，故不会误判。
  bool _following = true;

  @override
  void initState() {
    super.initState();
    _items = widget.controller.snapshot;
    _itemsSub = widget.controller.items.listen(_onItems);
    _scrollController.addListener(_onScroll);
    _subscribeActivities();
    _subscribeContextUsage();
    _subscribeExecutionStatus();
    _subscribeTtsStatus();
    _subscribeStaleTurnIds();
    _subscribeTimelineCache();
    _subscribeOutbox();
  }

  /// 订阅离线队列（仅在调用方注入 [ConversationPage.outboxEntries] 时）。
  ///
  /// 与 `activities` 同取向的「注入才订阅」：未接线时页面是纯只读时间线。
  void _subscribeOutbox() {
    final stream = widget.outboxEntries;
    if (stream == null) return;
    _outbox = widget.outboxSnapshot ?? const [];
    _outboxSub = stream.listen((rows) {
      if (!mounted) return;
      setState(() => _outbox = rows);
    });
  }

  /// 订阅「时间线来自缓存」信号（切片 B / issue #29）。
  ///
  /// ## 为什么总是订阅（不像 activities 那样「注入才订阅」）
  ///
  /// 缓存是**控制器自带**的能力（构造时注入 `timelineCache`），不像
  /// `activities` 那样需要调用方额外接线。故这里无需一个「是否注入」的开关：
  /// 未注入缓存的控制器永远不会推 true，订阅是空转但不产生噪声。
  ///
  /// ## 初值必须取快照
  ///
  /// 从列表页进入对话时，`switchGroup`/`start` 的回落可能在**页面挂载之前**
  /// 就完成了。只看流会错过那一次推送，提示条永远不出现。
  void _subscribeTimelineCache() {
    _timelineFromCache = widget.controller.timelineFromCacheSnapshot;
    _fromCacheSub = widget.controller.timelineFromCache.listen((v) {
      if (!mounted) return;
      setState(() => _timelineFromCache = v);
    });
  }

  /// 订阅活动流（仅在调用方传了 [ConversationPage.activities] 时）。
  ///
  /// 用「注入才订阅」而非「总是订阅 controller」：保持本页在未注入时是
  /// **纯只读时间线**（同 [ConversationPage.onCancelTurn] 等注入参数的取向），
  /// 且不白订阅一条无人消费的流。
  void _subscribeActivities() {
    final stream = widget.activities;
    if (stream == null) return;
    _activitiesSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _activities = snapshot);
    });
    _activities = widget.activitiesSnapshot ?? const {};
  }

  /// 订阅用量流（仅在调用方传了 [ConversationPage.contextUsage] 时）。
  ///
  /// 与 [_subscribeActivities] 同一取向：未注入时本页不展示用量区，也不白订阅。
  void _subscribeContextUsage() {
    final stream = widget.contextUsage;
    if (stream == null) return;
    _contextUsageSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _contextUsage = snapshot);
    });
    _contextUsage = widget.contextUsageSnapshot;
  }

  /// 订阅等待/重试状态流（仅在调用方传了 [ConversationPage.executionStatus] 时）。
  void _subscribeExecutionStatus() {
    final stream = widget.executionStatus;
    if (stream == null) return;
    _executionStatusSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _executionStatus = snapshot);
    });
    _executionStatus = widget.executionStatusSnapshot;
  }

  /// 订阅播报状态流（仅在调用方传了 [ConversationPage.ttsStatus] 时）。
  void _subscribeTtsStatus() {
    final stream = widget.ttsStatus;
    if (stream == null) return;
    _ttsStatusSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _ttsStatus = snapshot);
    });
    _ttsStatus = widget.ttsStatusSnapshot;
  }

  /// 订阅超时集合流（仅在调用方传了 [ConversationPage.staleTurnIds] 时）。
  ///
  /// 与 [_subscribeActivities] 同一取向：未注入时本页不展示超时提示，也不
  /// 白订阅一条无人消费的流。
  void _subscribeStaleTurnIds() {
    final stream = widget.staleTurnIds;
    if (stream == null) return;
    _staleTurnIdsSub = stream.listen((snapshot) {
      if (!mounted) return;
      setState(() => _staleTurnIds = snapshot);
    });
    _staleTurnIds = widget.staleTurnIdsSnapshot ?? const {};
  }

  @override
  void didUpdateWidget(ConversationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _itemsSub?.cancel();
      _items = widget.controller.snapshot;
      _itemsSub = widget.controller.items.listen(_onItems);
    }
    // 活动流换了来源（或从未注入变为注入）：重订阅。
    if (oldWidget.activities != widget.activities) {
      unawaited(_activitiesSub?.cancel());
      _activitiesSub = null;
      _activities = const {};
      _subscribeActivities();
    }
    // 用量流同理。
    if (oldWidget.contextUsage != widget.contextUsage) {
      unawaited(_contextUsageSub?.cancel());
      _contextUsageSub = null;
      _contextUsage = null;
      _subscribeContextUsage();
    }
    // 等待/重试流同理。
    if (oldWidget.executionStatus != widget.executionStatus) {
      unawaited(_executionStatusSub?.cancel());
      _executionStatusSub = null;
      _executionStatus = null;
      _subscribeExecutionStatus();
    }
    // 播报状态流同理。
    if (oldWidget.ttsStatus != widget.ttsStatus) {
      unawaited(_ttsStatusSub?.cancel());
      _ttsStatusSub = null;
      _ttsStatus = null;
      _subscribeTtsStatus();
    }
    // 超时集合流同理。
    if (oldWidget.staleTurnIds != widget.staleTurnIds) {
      unawaited(_staleTurnIdsSub?.cancel());
      _staleTurnIdsSub = null;
      _staleTurnIds = const {};
      _subscribeStaleTurnIds();
    }
    // 队列接线换了：重订 + 重取快照。
    //
    // ⚠️ 快照要**每次**重取（不能只在流变化时）：`outboxSnapshot` 来自
    // Provider 的 `ref.watch(...).snapshot`，而 Provider 只在依赖变化时重建
    // ——单靠它拿不到最新队列，必须配合流；反过来，流的值在两次推送之间也可能
    // 落后于快照（页面刚重建）。两者都刷新才能保证不显示过期状态。
    if (oldWidget.outboxEntries != widget.outboxEntries) {
      unawaited(_outboxSub?.cancel());
      _outboxSub = null;
      _subscribeOutbox();
    } else if (widget.outboxEntries != null) {
      final snap = widget.outboxSnapshot;
      if (snap != null && !identical(snap, _outbox)) {
        _outbox = snap;
      }
    }
    // 换了控制器（或换对话）：重订缓存信号并重取快照。
    //
    // 控制器携带 `timelineCache`，换 group 后 `_fromCache` 已在
    // `switchGroup` 里复位——本页需要跟上那个新值。
    if (oldWidget.controller != widget.controller) {
      unawaited(_fromCacheSub?.cancel());
      _fromCacheSub = null;
      _timelineFromCache = widget.controller.timelineFromCacheSnapshot;
      _subscribeTimelineCache();
    }
    // 换了对话就要重新给翻页一次机会：`_reachedOldest` 是上一个 group 的结论，
    // 沿用会让新对话永远翻不到历史（见 [historyKey] 的说明）。
    if (oldWidget.historyKey != widget.historyKey ||
        oldWidget.controller != widget.controller) {
      _reachedOldest = false;
    }
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _activitiesSub?.cancel();
    _contextUsageSub?.cancel();
    _executionStatusSub?.cancel();
    _ttsStatusSub?.cancel();
    _staleTurnIdsSub?.cancel();
    _fromCacheSub?.cancel();
    _outboxSub?.cancel();
    _scrollController.dispose();
    _draft.dispose();
    super.dispose();
  }

  void _onItems(List<ConversationItem> items) {
    setState(() => _items = items);

    if (_following) {
      // 等一帧：新项尚未布局完成，此时 maxScrollExtent 还是旧值。
      WidgetsBinding.instance.addPostFrameCallback((_) => _followBottom());
    }
  }

  /// 根据滚动位置更新 [_following]。
  ///
  /// 程序触发的滚动也会走到这里，但它向底部移动，结果是 `_following`
  /// 保持 true——正是期望的。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;

    // 顶部触发加载更早历史。
    //
    // WHY 挂在滚动监听而不是另起 Timer / ScrollNotification：本页已有唯一的滚动
    // 监听（[_onScroll]），翻页与自动跟随共享同一个「位置已变」信号，不需要第二
    // 套时序。
    //
    // ⚠️ 必须放在下面「内容不足一屏」的 early return **之前**：那种情况下
    // `pixels == 0` 也正是「在顶部」，若在 early return 之后判断就会被跳过。
    // （实践中影响极小：首屏 `_backfill` 一次拉 200 条，短到填不满屏幕的对话
    // 基本意味着已全部加载。但把判断放在正确的位置不需要额外代价。）
    if (position.pixels <= _loadOlderThreshold) {
      unawaited(_maybeLoadOlder());
    }

    // 内容不足一屏时 maxScrollExtent == 0，视为在底部。
    if (position.maxScrollExtent <= 0) {
      _following = true;
      return;
    }
    _following =
        position.pixels >= position.maxScrollExtent - _autoScrollThreshold;

    // 跟随中仍未到底 → 继续追。
    //
    // ⚠️ 这一步不可省：`ListView.builder` 的 `maxScrollExtent` 是**惰性估算**的
    // ——它只根据已构建的可见项推算。新增内容后，估算值会在后续若干帧里逐步
    // 修正（实测：同一次推送后先报 321，几帧后才是真实的 1041）。
    // 若只在新增项时滚一次，滚动会停在中间（实测停 321/1041，约 1/3 处）。
    // 这里借「滚动会触发通知」这一点自我修正，直到真正到底。
    if (_following) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followBottom());
    }
  }

  /// 到达顶部附近时加载更早的一页（带并发与终止保护）。
  ///
  /// 只在 [_onScroll] 里调用，而那里已确认 `_scrollController.hasClients`；
  /// 空列表时渲染的是 [EmptyState] 而非 `ListView`，控制器没有 client，
  /// 滚动通知根本不会产生。故这里不需要再判 `_items.isEmpty`。
  ///
  /// ## 已知边界：前插后不补偿滚动位置
  ///
  /// 向 `ListView` 头部插入内容会把当前可见内容整体下推（Flutter 保持
  /// `pixels` 不变），故翻页瞬间可视位置会跳到「新插入的那一页」。
  ///
  /// 正确的做法是记录插入前后的 `maxScrollExtent` 差值再补偿 `pixels`，但那需要
  /// 与自动跟随（[_following]）协调——两者同时生效时会把用户从顶部拽到底部。
  /// 本机无 DISPLAY、无法真机验证交互，靠猜写这段补偿只会得到一个「测试全绿但
  /// 手感不对」的实现，故先不做，待有桌面环境时按实测手感补上。
  Future<void> _maybeLoadOlder() async {
    final handler = widget.onLoadOlder;
    // 两重护栏：未注入 / 已到最早 / 正在加载。
    if (handler == null || _reachedOldest || _loadingOlder) return;

    _loadingOlder = true;
    try {
      final hasMore = await handler();
      if (!mounted) return;
      // 返回 false = 已到最早，从此不再触发。
      if (!hasMore) setState(() => _reachedOldest = true);
    } on SpbError catch (e) {
      // 失败不标记 `_reachedOldest`：下次滚到顶可以重试。
      if (mounted) _showMessage('加载更早历史失败：${e.message}');
    } finally {
      _loadingOlder = false;
    }
  }

  /// 滚到底（仅在 [_following] 时由调用方触发）。
  void _followBottom() {
    if (!mounted || !_following || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = position.maxScrollExtent;
    // 已在底部就不动（避免无谓的滚动通知与重绘）。
    if ((position.pixels - target).abs() < 1) return;

    // 流式回复会在几十毫秒内连续到达多个事件，而滚动动画是 150ms。
    // 若每次都用 animateTo，新动画会**取消**上一个并从当前位置重来，
    // 永远追不上不断变大的 maxScrollExtent。故：
    //   - 距离较小时（单条新消息）用动画，视觉平滑；
    //   - 距离较大时（流式突发 / 惰性估算刚修正）直接 jump，保证一定到底。
    if (target - position.pixels > position.viewportDimension) {
      _scrollController.jumpTo(target);
      return;
    }
    _scrollController.animateTo(
      target,
      // 用令牌而非硬编码时长（见 docs/flutter-component-research.md §3.1）。
      duration: SpbDuration.fast,
      curve: Curves.easeOut,
    );
  }

  Future<void> _handleSubmit(String text) async {
    // ## 为什么两个分支共用同一个错误处置
    //
    // `onSend` 是**生产路径**（两个 app 都注入了它，为了带上 agentId，见
    // desktop/mobile router 的说明），而默认的 `controller.send` 才是
    // 「未接线」时的兑底。两者都可能抛 [MessageQueuedError]（离线入队）
    // ——若只包住其中一个，生产路径上的入队异常会变成**未捕获异常**：
    // 用户看不到任何提示，消息虽然排上了队却无从得知。
    try {
      final custom = widget.onSend;
      if (custom != null) {
        await custom(text);
      } else {
        await widget.controller.send(input: text);
      }
    } on MessageQueuedError catch (e) {
      // 已入离线队列（issue #30）：**不是**失败——用户打好的字没丢。
      //
      // ## 为什么不与下面的分支合并
      //
      // 两者都继承 SpbError，但用户的正确反应完全相反：这条要「等着，别重打」
      // （重打会发两条），下面那条要「改一下再试」。合并成一句「发送失败」会让
      // 用户以为消息丢了、然后重打一遍。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('网络不可用，已加入待发送：${e.message}')));
    } on SpbError catch (e) {
      // 发送失败：提示但不回滚输入（用户可能想重试同一段文字，
      // 清空反而让他重打一遍）。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：${e.message}')));
    }
  }

  /// 重发一个失败的 turn（用原输入重新投递一轮）。
  ///
  /// ## 为什么直接发送而不是回填输入框
  ///
  /// 对齐 webapp 的 `handleRetryTurn`（`ChatMessageList.tsx:290`）：它同样
  /// 直接重新投递。按钮文案是「重发」而不是「重新编辑」，语义就是「再跑一遍」。
  /// 用户想改文案时可以直接在输入框里重打（那是发**新**消息，语义也不同）。
  ///
  /// 与 [FollowUpChips] 的 `onAppend` 不同：建议卡是「追问的起点」（服务端动作
  /// 就是 `copy_text`），而这里是「把刚失败的那次重做」。
  ///
  /// 防重复点击靠 [_retryingTurnId]：重发是写操作，连点两次会产生两个 turn。
  Future<void> _handleRetryTurn(ErrorItem error) async {
    final handler = widget.onRetryTurn;
    final turnId = error.turnId;
    if (handler == null || turnId.isEmpty || _retryingTurnId != null) return;

    // 找该 turn 的原用户输入与当时选中的 agent。
    //
    // 不能用「全局最后一条 UserMessageItem」：用户在失败后又发了几条时，那个
    // 找到的是别人的输入。`turnId` 是可靠的关联键（error 与 user_message 同 turn）。
    UserMessageItem? source;
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      if (item is UserMessageItem && item.turnId == turnId) {
        source = item;
        break;
      }
    }
    final text = source?.text ?? '';
    // 找不到原输入（历史只回填到 error 之后）时不发请求：拿别的文本去发会把
    // 「重发」变成「乱发一条」。按钮会因此在那种情况下无反应——比发错好。
    if (text.isEmpty) return;

    setState(() => _retryingTurnId = turnId);
    try {
      await handler(text, source?.agentId);
    } on SpbError catch (e) {
      // 重发本身又失败了（例如仍是同一个终态错误）：提示但**不**改归约结果
      // ——新一轮的 error 事件会由服务端发出，页面会多出一条错误条。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('重发失败：${e.message}')));
    } finally {
      if (mounted) setState(() => _retryingTurnId = null);
    }
  }

  /// 打开「在本对话中搜索」底部弹层。
  ///
  /// ## 为什么用弹层而不是新路由
  ///
  /// 与 AGENTS.md §6.10 的两端载体约定一致，但这里还有一个更硬的理由：
  /// 搜索命中后要**滚回本页时间线的某一条**，而那需要本页的
  /// `ScrollController` 与 `_rowKeys`。新路由会得到另一个页面实例
  /// （State 不共享），滚不动原页面。
  ///
  /// ## 为什么把「是否还有更早历史」传下去
  ///
  /// 搜索只覆盖**已加载**的 items。若 `_reachedOldest` 为 false，面板必须
  /// 告知用户「没搜到」不等于「不存在」（见 `ConversationSearchSheet`）。
  ///
  /// ## 为什么在 `await` 之后才滚动（而不是在 `onOpenHit` 里直接滚）
  ///
  /// 弹层占据下半屏，未关闭时 `ensureVisible` 会把目标滚到**被弹层遮住的
  /// 位置**（它只保证「在滚动视口内」，不知道上层还有弹层）。而
  /// `showModalBottomSheet` 返回的 Future 正是在弹层**完全退场后**完成，
  /// 故这里 await 它、再滚动，不需要任何「等动画的固定延时」。
  Future<void> _openSearch() async {
    ConversationSearchHit? picked;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // 高度按屏幕比例给：键盘弹出时 `viewInsets` 会把内容顶上去，
      // 固定高度会让结果区被挤没。
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: ConversationSearchSheet(
          // 每次查询时现读，故弹层打开期间到达的新消息也能被搜到。
          readItems: () => _items,
          upperHistoryUnloaded: !_reachedOldest,
          onOpenHit: (hit) {
            picked = hit;
            Navigator.of(sheetContext).maybePop();
          },
        ),
      ),
    );
    if (!mounted || picked == null) return;
    await _scrollToItem(picked!.itemId);
  }

  /// 把时间线滚到指定 `item.id` 的那一行。
  Future<void> _scrollToItem(String itemId) async {
    final targetContext = _rowKeys[itemId]?.currentContext;
    if (targetContext == null) {
      // 目标行未被构建（在视口外且 `ListView.builder` 尚未创建它）。
      //
      // 不静默失败：用户点了命中项却什么都没发生，会以为搜索坏了。给出
      // 可执行的下一步（继续往上翻）比沉默好。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该条在更早的位置，请向上滚动后重试')));
      return;
    }

    await Scrollable.ensureVisible(
      targetContext,
      // 用 `center` 而不是 `alignment: 0`：命中项周围的内容（同一轮的
      // 上下文）比「目标贴顶」更有用，且贴顶时若上方有未加载历史会立即触发
      // 翻页，把用户从目标处推走。
      alignment: 0.5,
      duration: SpbDuration.normal,
      curve: Curves.easeOut,
    );
  }

  /// 把「被拒绝」翻译成用户可读的提示。
  ///
  /// 返回原结果，便于调用方继续用（当前无人用，但保持可组合）。
  Future<bool> _withRejectionNotice(Future<bool> action, String notice) async {
    final ok = await action;
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(notice)));
    }
    return ok;
  }

  /// 当前仍在生成的项；null 表示没有进行中的生成。
  ///
  /// ## 为什么取「最后一个」而不是「任意一个」
  ///
  /// `items` 按时间升序，而 `done` 会闭合**全部**流式段落（`_sealStreaming`），
  /// 故同一时刻最多只有一个 turn 处于流式态。取最后一个与取任意一个等价，
  /// 但「最后一个」在将来若出现多段并存时，仍指向最新（也就是用户最想停的）那个。
  ///
  /// ## 为什么 [ThoughtItem] 也算
  ///
  /// 只认 [AssistantMessageItem] 会漏掉「agent 正在思考、还没吐第一个字」这段
  /// ——而那恰恰是最需要能停的时候（实测长 turn 的思考段可达数十秒）。两者都由
  /// 归约层在同一套 `isStreaming` 语义下维护：增量帧置 true，`done`/权威帧置 false。
  ConversationItem? get _streamingItem {
    for (var i = _items.length - 1; i >= 0; i--) {
      final item = _items[i];
      final streaming = switch (item) {
        AssistantMessageItem(:final isStreaming) => isStreaming,
        ThoughtItem(:final isStreaming) => isStreaming,
        _ => false,
      };
      if (streaming) return item;
    }
    return null;
  }

  /// 当前处于超时兜底态的进行中项；null 表示没有。
  ///
  /// 「长时间无进展」与「流式」是两个不同的概念：stale 只说明客户端没再收到
  /// 进展，turn 可能仍在后台跑。故它**不**改变 [ConversationItem]（不改文本、
  /// 不改 `isComplete`），只让 UI 停掉光标并给出提示。
  ConversationItem? get _staleTurnItem {
    final streaming = _streamingItem;
    if (streaming == null) return null;
    return _staleTurnIds.contains(streaming.turnId) ? streaming : null;
  }

  /// 停止当前轮次。
  Future<void> _handleCancelTurn() async {
    final handler = widget.onCancelTurn;
    // `turnId` 为空则不发请求：服务端路由是 `/chat/turns/:turn_id/cancel`，
    // 空 id 会打到 `/chat/turns//cancel`（语义不明的 404，见 issue #2 同源陷阱）。
    final turnId = _streamingItem?.turnId ?? '';
    if (handler == null || turnId.isEmpty || _cancelling) return;

    setState(() => _cancelling = true);
    try {
      await handler(turnId);
    } on SpbError catch (e) {
      // 失败只提示、不崩。**不**清空流式标记：turn 可能仍在跑，
      // 用户应当还能再试一次（而不是看着界面假装已停）。
      if (mounted) _showMessage('停止失败：${e.message}');
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _handleResolve(
    String groupId,
    String confirmationId,
    String option,
  ) async {
    final callback = widget.onResolveConfirmation;
    if (callback == null || _resolving.contains(confirmationId)) return;

    setState(() => _resolving.add(confirmationId));
    try {
      callback(groupId, confirmationId, option);
    } finally {
      if (mounted) setState(() => _resolving.remove(confirmationId));
    }
  }

  /// 建议卡点按：把建议文本回填到输入框（copy_text 的 onAppend 路径）。
  ///
  /// 走 [_draft] 而非直接发送：MessageComposer 在页面底部，时间线里的卡片
  /// 无法直接访问它的 controller。
  void _handleSuggestionAppend(String text) {
    if (text.isEmpty) return;
    _draft.value = text;
  }

  /// spec 卡片上的动作上抛给 app 层。
  void _handleSpecAction(SpecUiAction action) {
    widget.onSpecAction?.call(action);
  }

  /// 提交归属反馈（防重复点击；与 [_handleResolve] 同构）。
  ///
  /// 解锁时机也一致：成功与失败都解锁——服务端 CAS 保证重复请求无数据错误，
  /// 失败时允许重试（不弹错误打断阅读）。
  Future<void> _handleResolveFeedback(String token, bool correct) async {
    final callback = widget.onResolveFeedback;
    if (callback == null || _resolvingFeedback.contains(token)) return;

    setState(() => _resolvingFeedback.add(token));
    try {
      callback(token, correct);
    } finally {
      if (mounted) setState(() => _resolvingFeedback.remove(token));
    }
  }

  /// 提交习惯建议操作（接受 / 忽略 / 稍后），三个共用一个在途标记。
  ///
  /// ## 为什么三者共用一个集合
  ///
  /// 它们作用于**同一张卡**，且在途期间卡上三个按钮都应禁用（用户在等结果，
  /// 不该再点另一个）。分三个集合反而要维护三份「另一个是否在途」的查询。
  ///
  /// 在途标记按 suggestionId 记录，且**在回调返回后立即清除**（不等 resolved
  /// 事件到达）：若服务端广播延迟，一直禁用会让用户以为卡坏了；而服务端的 CAS
  /// 已经能挡住真正的重复提交。
  Future<void> _handleHabitAction(
    HabitSuggestionItem suggestion,
    void Function(HabitSuggestionItem suggestion) callback,
  ) async {
    if (!suggestion.canResolve ||
        _resolvingHabit.contains(suggestion.suggestionId)) {
      return;
    }

    setState(() => _resolvingHabit.add(suggestion.suggestionId));
    try {
      callback(suggestion);
    } finally {
      if (mounted) {
        setState(() => _resolvingHabit.remove(suggestion.suggestionId));
      }
    }
  }

  /// 是否可以点「停止生成」。
  ///
  /// 两个条件：有流式项，且该项带着非空 [ConversationItem.turnId]。
  /// 后者不可省：`turnId` 为空说明事件未携带该字段（历史数据或异常载荷），
  /// 此时发不出正确的取消请求（见 [_handleCancelTurn]）。
  /// 提交中（[_cancelling]）同样禁用，避免连点。
  bool get _canCancelTurn {
    if (_cancelling) return false;
    final item = _streamingItem;
    return item != null && item.turnId.isNotEmpty;
  }

  /// 当前应展示的执行中活动快照；null 表示不该展示。
  ///
  /// ## 显示条件（逐条对齐 webapp `ChatMessageList.tsx:471`）
  ///
  /// | webapp 条件 | 本页等价物 |
  /// |---|---|
  /// | `turn.activity` 存在 | [_activities] 里有该 turnId 的快照 |
  /// | `isStreaming` | 该 turn 是 [_streamingItem] 的 turn |
  /// | `!hasAgentContent` | 该 turn 还没有非空正文的 [AssistantMessageItem] |
  /// | `!turn.status`（无终态） | 有流式项即意味着 `done` 尚未到达（`_sealStreaming` 会闭合全部流式段） |
  /// | `!turn.queueReason` | 客户端**未跟踪**排队原因（无对应领域字段），恒真 |
  ///
  /// ## 为什么四个条件都要
  ///
  /// 只判「有活动」会在两种情况下产生误导：
  /// 1. **已有正文**：正文在往下滚，再插一句「已运行 3 分」只是噪声；
  /// 2. **已收尾**：`done` 之后活动快照可能仍在 State 里（它是 Transient，
  ///    只能靠下一个事件或切对话清掉），不判终态会在完成的对话下挂一条
  ///    「执行中」，比不显示更糟。
  ///
  /// 反过来，这两个条件都不能用来「省掉 `isStreaming`」：`isStreaming` 才是
  /// 「turn 在跑」的直接证据，而「无正文」也可能是「早就跑完且本来就没回复」。
  TurnActivitySnapshot? get _visibleActivity {
    final streaming = _streamingItem;
    if (streaming == null || streaming.turnId.isEmpty) return null;

    // 已判超时 → 让位给 [_StaleTurnNotice]。
    //
    // 活动快照是 Transient（不落库），断线后可能停在 State 里；继续显示
    // 「执行中 · 已运行 12 分」会与「长时间无进展」自相矛盾。
    if (_staleTurnIds.contains(streaming.turnId)) return null;

    final activity = _activities[streaming.turnId];
    if (activity == null) return null;

    // 已有正文 → 让位给真实内容。
    for (final item in _items) {
      if (item is AssistantMessageItem &&
          item.turnId == streaming.turnId &&
          item.text.isNotEmpty) {
        return null;
      }
    }
    return activity;
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;

    return Scaffold(
      appBar: title == null
          ? null
          : AppBar(
              title: Text(title, overflow: TextOverflow.ellipsis),
              // 连接状态指示：SSE 断线时用户需要知道「不是没回复，是断了」。
              actions: [
                // 停止生成：仅在确有正在生成的轮次时可点。
                //
                // 选**禁用**而非隐藏：AppBar 宽度恒定，不会因状态切换而抖动；
                // 且用户能看到「这里有一个停止按钮，只是现在没什么可停」。
                if (widget.onCancelTurn != null) ...[
                  IconButton(
                    key: const ValueKey('conversation-cancel-turn'),
                    icon: const Icon(Icons.stop_circle_outlined),
                    tooltip: '停止生成',
                    onPressed: _canCancelTurn ? _handleCancelTurn : null,
                  ),
                  const SizedBox(width: SpbSpacing.xs),
                ],
                // 调用方追加的操作（如桌面端的交付物侧边栏开关），
                // 放在连接指示**之前**：连接状态是全局性的，固定在最右侧。
                ...?widget.actions,
                // 对话内搜索：搜的是**已加载的时间线**（含 agent 回复），
                // 与全局搜索页（只搜用户输入、跨对话）互补。
                //
                // 放在 widget.actions **之后**：它是页面固有能力，而 actions
                // 是各端追加的。
                if (widget.enableSearch)
                  IconButton(
                    key: const ValueKey('conversation-search-open'),
                    icon: const Icon(Icons.search),
                    tooltip: '在本对话中搜索',
                    onPressed: _openSearch,
                  ),
                // 窄屏溢出菜单（issue #31）：收纳调用方交来的低频入口，并把
                // 「在本对话中搜索」追加在末尾。
                //
                // 搜索项**总是**追加：窄屏不摆 `conversation-search-open`
                // 图标（没地方），但功能不能因此消失。两项的 `key` 不同
                // （`conversation-search-open` vs `menu-conversation-search`），
                // 故测试能分别断言两种布局下的路径。
                if (widget.overflowItems != null)
                  _OverflowMenu(
                    items: widget.overflowItems!,
                    onSearch: _openSearch,
                  ),
                StreamBuilder<SseState>(
                  stream: widget.controller.connectionState,
                  initialData: widget.controller.currentState,
                  builder: (context, snapshot) => _ConnectionIndicator(
                    state: snapshot.data,
                    onReconnect: widget.onReconnect,
                  ),
                ),
                const SizedBox(width: SpbSpacing.sm),
              ],
            ),
      body: Column(
        children: [
          // 离线数据提示（issue #29 切片 B）：贴最顶。
          //
          // 与下面几条状态条的语义不同：那几条说的是「这一轮/这个 turn」的状态，
          // 而本提示说的是「你看到的整份历史都来自本地缓存」——它修饰的是
          // **整个时间线**，故贴顶且独立成条（与切片 A 的
          // `GroupListPage._CacheNotice` 同一取向）。
          if (_timelineFromCache) const _OfflineTimelineNotice(),
          // 上下文用量：贴在时间线**上方**（顶部诊断区），不进时间线。
          //
          // 与下面两条状态条的位置差异是有意的：用量是「资源占用」的常驻读数，
          // 与输入/待处理无关，故贴顶；而活动指示描述「正在跑的那个 turn」，
          // 语义上贴时间线底部。
          if (_contextUsage != null && _contextUsage!.hasData)
            _ContextUsageBar(usage: _contextUsage!),
          // 语音播报状态：同样贴顶（常驻读数区）。
          //
          // 与下面「等待/活动」槽位分开是有意的：那两个回答「为什么还没回复」，
          // 而播报是**回复已生成之后**的异步衍生状态，与等待无关；挤进同一槽位
          // 会让「在等重试」与「语音失败」互相遮挡。
          if (_ttsStatus != null && _ttsStatus!.hasStatus)
            _TtsStatusBar(status: _ttsStatus!),
          Expanded(
            child: _items.isEmpty
                ? EmptyState(message: widget.emptyHint)
                : _buildTimeline(),
          ), // 待处理消息栏紧贴输入框上方：它描述的是「我刚发出去、还没被处理
          // 的那条」，语义上与输入区相邻而非与时间线相邻。
          // 执行中活动指示放在**时间线与待处理栏之间**：它描述的是「正在跑的
          // 那个 turn 的进度」，语义上属于时间线；而待处理栏的语义属于输入区，
          // 两者各贴各自的一端（见各自文档）。
          // 执行等待/重试提示（queue_state / retry_scheduled）：与活动指示
          // **共用同一槽位**，且优先于它。
          //
          // 判定依据：两者语义互斥——本提示是「还没开始跑（等名额/等重试）」，
          // 活动指示是「已在跑但没正文」。若同时存在（例如旧的排队事件尚未被
          // 起跑事件清掉，而心跳已先到），显示「在等」比显示「在跑」更保守也
          // 更准（对齐 webapp `turn.activity && !turn.queueReason`）。
          if (_staleTurnItem != null)
            const _StaleTurnNotice()
          else if (_executionStatus != null)
            _ExecutionStatusBar(status: _executionStatus!)
          else if (_visibleActivity != null)
            _TurnActivityIndicator(activity: _visibleActivity!),
          // 离线队列（issue #30）：紧贴待处理栏**上方**。
          //
          // ## 为什么两条并存而不是合并
          //
          // 它们回答两个不同的问题：本栏是「我这边还没发出去」（客户端队列），
          // 待处理栏是「服务端还在攒批」（`chat_inbox_messages`）。断网时先入
          // 客户端队列；联网投递成功后服务端才开始攒批——两者**可以同时非空**。
          // 合并会让「消息到底在哪一端」变得不可知。
          //
          // ## 为什么在待处理栏之上
          //
          // 本栏的条目**更早**（还没到服务端），故离输入框更远——视觉上
          // 「越靠外 = 越早期」与时间顺序一致。
          if (widget.outboxEntries != null)
            OutboxBar(
              entries: _outbox,
              // 取消 / 重试被拒绝时给出反馈（见 `_rejectNotice`）。
              //
              // ## 为什么要在页面包装一层，而不是把回调直接透传
              //
              // 回调返回 false 表示**拒绝**（条目正在投递中 / 存储删除失败）。
              // 组件层不做乐观移除，但若什么都不说，用户点了「取消」看到列表
              // 没变，会以为按钮坏了——于是再点几次。必须说明原因。
              onCancel: widget.onCancelOutbox == null
                  ? null
                  : (id) => _withRejectionNotice(
                      widget.onCancelOutbox!(id),
                      '这条消息正在发送中，稍候再取消',
                    ),
              onRetry: widget.onRetryOutbox,
              onRemove: widget.onRemoveOutbox,
            ),
          if (widget.loadPending != null && widget.undoPending != null)
            PendingMessagesBar(
              load: widget.loadPending!,
              undo: widget.undoPending!,
              // 本栏也提供发送入口：它展示的正是「将要被提交的那几条」，
              // 多条 pending 时的策略选择需要这个上下文。
              flush: widget.onFlush,
              flushWithStrategy: widget.onFlushWithStrategy,
              reloadKey: widget.pendingReloadKey ?? '',
            ),
          MessageComposer(
            onSubmit: _handleSubmit,
            onFlush: widget.onFlush,
            onFlushWithStrategy: widget.onFlushWithStrategy,
            draft: _draft,
          ),
        ],
      ),
    );
  }

  /// 时间线展示行（聚合后的结果）。
  ///
  /// ## 为什么在渲染前算一次，而不是在 `itemBuilder` 里
  ///
  /// 聚合是**全量**的（分组需要看到整段才能判断「连续同秒」），且 `ListView`
  /// 会多次调用 `itemBuilder`（滚动/重建）。在 builder 里算会把 O(n) 的分组
  /// 变成 O(n·可见项) 次重复计算，且每次得到新对象会让 `ValueKey` 失效。
  ///
  /// 放在 `_buildTimeline` 里（每次 build 算一次）而不缓存进 State：分组是
  /// 纯函数且很快（一次线性扫描），而缓存需要在 `_onItems` 里同步维护——
  /// 多一处可忘的地方。
  List<TimelineDisplayRow> _displayRows() => groupFileEventsForDisplay(_items);

  /// 丢弃已不在时间线上的行所对应的 `GlobalKey`（issue #39）。
  ///
  /// 规则与理由见 [RowLocateRegistry.recycle]。在 [_buildTimeline] 里调用
  /// （而不是 `_onItems`）：`rows` 已经算好了，零额外开销，且「当前行集合」
  /// 就是渲染的事实来源。
  void _recycleRowKeys(List<TimelineDisplayRow> rows) =>
      _rowKeys.recycle(locateIdsOfAll(rows));

  Widget _buildTimeline() {
    final rows = _displayRows();
    _recycleRowKeys(rows);

    return ScrollConfiguration(
      // 桌面端：Flutter 默认的 dragDevices **不含鼠标**，不加这个
      // 鼠标拖拽无法滚动时间线（滚轮不受影响）。
      // 见 docs/flutter-component-research.md §3.1。
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: ListView.builder(
        controller: _scrollController,
        padding: SpbSpacing.pagePadding,
        // itemCount +1 给底部留白，避免最后一项紧贴输入框。
        itemCount: rows.length + 1,
        itemBuilder: (context, index) {
          if (index == rows.length) {
            return const SizedBox(height: SpbSpacing.xxl);
          }
          final row = rows[index];
          // 搜索定位用的 GlobalKey。
          //
          // ## 为什么用 `KeyedSubtree` 包一层，而不是把 GlobalKey 当行 key
          //
          // 下面那个 `ValueKey` 的作用是「同一逻辑项跨重建复用 Element」；
          // 换成 `GlobalKey` 会让框架按「全局唯一」语义搬移 Element，
          // 流式更新时的复用行为会变。两者目的不同，故各占一层。
          //
          // ## 批量卡为什么给每个成员都注册同一个 key
          //
          // 搜索命中拿到的 `itemId` 是**具体某条**的 id（可能是批里的第 3 个
          // 文件），而行 key 是 `batch:<首成员 id>`。若只注册首成员，搜到批内
          // 其他文件时 `_rowKeys` 里找不到，会退化成「请向上滚动」的提示——
          // 而那条明明就在屏幕上。同一批共用一个定位点是对的：它们本来就渲染
          // 在同一张卡里。
          final locateKeys = locateIdsOf(row);
          final locateKey = _rowKeys.keyFor(locateKeys);

          return KeyedSubtree(
            key: locateKey,
            child: Padding(
              // 稳定 Key：单条用归约层的 item.id；批量卡用首成员 id（归约层保证
              // 同一逻辑项 id 不变，故批的 key 也稳定）。Flutter 据此复用 Element，
              // 避免流式更新时整列重建。
              key: ValueKey(switch (row) {
                SingleItemRow(:final item) => item.id,
                AgentFileBatchRow(:final files) => 'batch:${files.first.id}',
              }),
              padding: const EdgeInsets.only(bottom: SpbSpacing.md),
              child: switch (row) {
                SingleItemRow(:final item) => _buildItem(item),
                AgentFileBatchRow() => AgentFileBatchCard(
                  batch: row,
                  onDownload: widget.onDownloadAgentFile,
                  onLoadThumbnail: widget.onLoadThumbnailAgentFile,
                  onOpen: widget.onOpenAgentFile,
                  onReveal: widget.onRevealAgentFile,
                  onPreview: widget.onPreviewAgentFile,
                ),
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildItem(ConversationItem item) => switch (item) {
    UserMessageItem(:final text) => UserMessageBubble(text: text),
    // `isStreaming` 与超时集合求交：判超时后停掉光标。
    //
    // ⚠️ 只影响光标，**不改归约结果**——若 turn 其实仍在跑、增量帧随后到达，
    // 段落会自然恢复流式态（不会出现重复气泡，因为归约输入未变）。
    AssistantMessageItem(:final text, :final isStreaming) =>
      AssistantMessageBubble(
        text: text,
        isStreaming: isStreaming && !_staleTurnIds.contains(item.turnId),
        onLinkTap: widget.onOpenLink,
      ),
    ThoughtItem(:final text, :final isStreaming) => ThoughtTile(
      text: text,
      isStreaming: isStreaming && !_staleTurnIds.contains(item.turnId),
    ),
    ToolCallItem(:final name, :final args, :final output, :final isComplete) =>
      ToolCallTile(
        name: name,
        args: args,
        output: output,
        isComplete: isComplete,
      ),
    ConfirmationItem() => ConfirmationCard(
      question: item.question,
      options: item.options,
      resolved: item.resolved,
      busy: _resolving.contains(item.confirmationId),
      // 用卡行 id 而非 item.id（事件 id）——见 ConfirmationItem.confirmationId。
      // 未携带 confirmation_id 的异常事件禁用按钮，不退化用事件 id 去试。
      onResolve: item.canResolve
          ? (option) =>
                _handleResolve(item.groupId, item.confirmationId, option)
          : null,
    ),
    FollowUpSuggestionItem() => FollowUpChips(
      suggestions: item.suggestions,
      // 带 agent 标注的语义：点建议时先切 Agent（若标注了）再追加到输入框。
      //
      // 为什么从「点了直接发送」改为「回填输入框」：服务端给建议卡的动作就是
      // copy_text（「点击复制问题，可修改后再发送」），webapp 同样走
      // onAppend——建议是**追问的起点**，用户常要改几个字再发。直接发出去
      // 会把「我要改一下」变成「发错了再重来」。
      //
      // onSpecAction / onSelectAgent 都未注入时（旧调用方）退化为点击即发送。
      richSuggestions: [
        for (var i = 0; i < item.suggestions.length; i++)
          FollowUpSuggestion(
            text: item.suggestions[i],
            agentId: item.agentIdAt(i),
          ),
      ],
      onAppend: (widget.onSpecAction != null || widget.onSelectAgent != null)
          ? _handleSuggestionAppend
          : null,
      onSelectAgent: widget.onSelectAgent,
      onTap: _handleSubmit,
    ),
    GoalProgressItem() => SpecUiCard(
      doc: item.spec,
      // 进度卡里的按钮（goal_gate 的 spec 无动作，这里主要是向前兼容）。
      onAction: _handleSpecAction,
    ),
    RoutingNoticeItem(:final reason) => _RoutingNotice(reason: reason),
    GoalGateStoppedItem() => _GoalGateStoppedNotice(item: item),
    ScheduleCreatedItem() => _ScheduleCreatedNotice(item: item),
    DiagnosticNoticeItem() => _DiagnosticNotice(item: item),
    ErrorItem(:final message, :final isRecoverable) => ErrorBanner(
      // 重发是「用原输入再跑一轮」，按钮文案用「重发」而不是「重试」——
      // 后者容易被读成「重试这个请求」（不产生新 turn），而实际会产生新 turn。
      message: message,
      onRetry:
          (widget.onRetryTurn != null &&
              isRecoverable &&
              item.turnId.isNotEmpty)
          ? () => _handleRetryTurn(item)
          : null,
      retryLabel: _retryingTurnId == item.turnId ? '重发中…' : '重发',
    ),
    FeedbackRequestItem() => FeedbackRequestCard(
      question: item.question,
      options: item.options,
      resolved: item.resolved,
      busy: _resolvingFeedback.contains(item.token),
      // 三个条件都要满足才给可点按钮：
      //   - app 层注入了回执通道（未注入时点了没反应，不如直接禁用）；
      //   - token 非空（服务端按 token 直查请求，一次性 CAS，缺它必然失败）；
      //   - 尚未作答。
      onResolve: (widget.onResolveFeedback != null && item.canResolve)
          ? (correct) => _handleResolveFeedback(item.token, correct)
          : null,
    ),
    HabitSuggestionItem() => HabitSuggestionCard(
      suggestion: item,
      busy: _resolvingHabit.contains(item.suggestionId),
      // 三个回调都需 app 层注入：本页不持有 HabitApi（分层约定，
      // 且 widget test 因此不需要 HTTP mock）。
      //
      // 注意卡片上的回调签名是 `VoidCallback`（无参）——卡自己知道是哪条建议，
      // 页面用闭包把 item 带进去，而不是把 item 再传一遍。
      onAccept: widget.onAcceptHabit == null
          ? null
          : () => _handleHabitAction(item, widget.onAcceptHabit!),
      // 编辑回调带 patch：页面用闭包把 item 与 patch 一起交给 app 层，
      // 卡片只需知道「用户改了什么」（见 HabitSuggestionCard._openEditor）。
      onEditAndAccept: widget.onEditAndAcceptHabit == null
          ? null
          : (patch) => _handleHabitAction(
              item,
              (x) => widget.onEditAndAcceptHabit!(x, patch),
            ),
      onDismiss: widget.onDismissHabit == null
          ? null
          : () => _handleHabitAction(item, widget.onDismissHabit!),
      onSnooze: widget.onSnoozeHabit == null
          ? null
          : (option) => _handleHabitAction(
              item,
              (x) => widget.onSnoozeHabit!(x, option),
            ),
    ),
    AgentFileItem() => AgentFileCard(
      file: item,
      onDownload: widget.onDownloadAgentFile,
      // 缩略图回调是**按 file 绑定**的：卡片侧 `onLoadThumbnail` 无参，
      // 故在此把 item 闭包进去。
      //
      // `ufsFileId` 为空时传 null：卡片自己只判 `isImage` / `isDeleted`，
      // 不判「有没有可拉的 id」。不在此拦住就会发出
      // `GET /api/files//thumbnails/256`（一个 404），对每张无 id 的卡白跑一趟。
      //
      // ⚠️ 该闭包每次 build 都是新实例，`AgentFileCard.didUpdateWidget` 据此
      // 重置缩略图缓存——这是必要的：同一张卡被更新到另一个文件时必须重拉。
      onLoadThumbnail:
          widget.onLoadThumbnailAgentFile == null ||
              (item.ufsFileId ?? '').isEmpty
          ? null
          : () => widget.onLoadThumbnailAgentFile!(item),
      // 直接透传（不包闭包）：卡片侧这两个回调本来就收 file 入参。
      // 未注入时传 null，卡片据此不渲染对应菜单项。
      onOpen: widget.onOpenAgentFile,
      onReveal: widget.onRevealAgentFile,
      onPreview: widget.onPreviewAgentFile,
    ),
    HabitAutoRunItem() => HabitAutoRunCard(item: item),
  };
}

/// 语音播报状态条：展示播报进行到哪一步 / 为什么失败。
///
/// ## 只做状态展示（不播放）
///
/// 客户端既有决策是「TTS 仅下载不播放」（AGENTS.md §11：无音频播放插件）。
/// 本组件**只**渲染一行状态文字，不提供播放控件，也不持有音频句柄；
/// 音频文件本身仍走交付物同步（见 `tts_audio_path.dart`）。
///
/// ## 三态文案
///
/// | 阶段 | 文案 | 来源 |
/// |---|---|---|
/// | idle | （不展示） | —— 由调用方 [TtsStatus.hasStatus] 拦住 |
/// | started | 正在生成语音… | 逐字对齐 webapp `ChatMessageList` |
/// | completed | 语音已生成 | 本轮额外展示（见下） |
/// | failed | 服务端 `message`，兜底「语音生成失败。」 | webapp 同 |
///
/// ## ⚠️ 与 webapp 的**有意偏离**：completed 也展示
///
/// webapp 的注释写明「完成不额外提示」（`ttsStatus === "starting"` 与
/// `"failed"` 两个分支，无 completed 分支）。本任务验收明确要求「三种状态
/// 各自渲染」，且完成态确实承载信息（分段数），故这里显式展示。
/// 若将来要求逐字对齐 webapp，删掉 completed 分支即可。
class _TtsStatusBar extends StatelessWidget {
  const _TtsStatusBar({required this.status});

  final TtsStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final failed = status.phase == TtsPhase.failed;
    final parts = status.parts;

    return Material(
      key: const ValueKey('conversation-tts-status'),
      // 失败用 errorContainer 与其它状态条区分：它是**需要用户知道**的负面
      // 结果（服务端文案也强调「本次文本回复不受影响」，即"别担心，但要知道"）；
      // 进行中/完成用中性的 surfaceContainerHighest（同上下文用量条）。
      color: failed ? scheme.errorContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            if (status.phase == TtsPhase.started)
              SizedBox(
                width: SpbSpacing.lg,
                height: SpbSpacing.lg,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Icon(
                failed ? Icons.warning_amber_outlined : Icons.graphic_eq,
                size: SpbSpacing.lg,
                color: failed
                    ? scheme.onErrorContainer
                    : scheme.onSurfaceVariant,
              ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                _text(status),
                key: const ValueKey('conversation-tts-status-text'),
                style: textTheme.bodySmall?.copyWith(
                  color: failed
                      ? scheme.onErrorContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            // 已完成段数：只在有值时显示（started 阶段无从得知）。
            if (parts != null && parts > 0 && status.phase != TtsPhase.failed)
              Text(
                '$parts 段',
                key: const ValueKey('conversation-tts-status-parts'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 状态文案。
  ///
  /// 失败优先用服务端给的 `message`（已是可直接展示的中文，且区分「全失败」与
  /// 「部分成功」两种情形），缺失时兜底——与 webapp 的
  /// `turn.ttsErrorMessage || "语音生成失败。"` 同口径。
  static String _text(TtsStatus s) {
    switch (s.phase) {
      case TtsPhase.idle:
        // 调用方用 hasStatus 拦住 idle，不应走到这里；给出空串而非抛异常，
        // 避免上游漏判时把整页崩掉。
        return '';
      case TtsPhase.started:
        return '正在生成语音…';
      case TtsPhase.completed:
        return '语音已生成';
      case TtsPhase.failed:
        final msg = s.message;
        return (msg != null && msg.isNotEmpty) ? msg : '语音生成失败。';
    }
  }
}

/// 上下文用量条：展示「已用 / 窗口」与（若服务端提供）费用。
///
/// ## 为什么贴在时间线顶部
///
/// 它是**资源占用读数**（每次压缩 / 每轮收尾刷新），与「当前在聊什么」无关，
/// 故贴顶常驻；而 `_TurnActivityIndicator` 描述的是「正在跑的那个 turn」，
/// 语义上属于时间线底部。两者位置不同是**有意**的，不要为了对称把它们并排。
///
/// ## 对齐 webapp
///
/// `apps/webapp/messages/zh.json`：
/// - `costAndUsage` = `成本与用量`
/// - `tokenUsed` = `已使用`
/// - `tokenCostLabel` = `费用`
///
/// 取值口径与 `WorkbenchStatusSidebar` 一致：只在 `used` 与 `size` 都已知时
/// 显示 token 行；费用只在 `amount > 0` 时显示。
class _ContextUsageBar extends StatelessWidget {
  const _ContextUsageBar({required this.usage});

  final ContextUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final used = usage.used;
    final size = usage.size;
    final cost = usage.cost;

    return Material(
      key: const ValueKey('conversation-context-usage'),
      // 与连接/活动条区分：用量是中性读数而非「临时状态」，用 surfaceContainer
      // 而非 secondaryContainer，视觉上不与「正在执行」混淆。
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.data_usage,
              size: SpbSpacing.lg,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                // 只在两端都已知时拼「X / Y」：只有 used 时拼出「12K / null」
                // 比只显示「12K」更糟（用户会以为窗口未知是缺陷）。
                (used != null && size != null)
                    ? '上下文：${formatTokenCount(used)} / ${formatTokenCount(size)}'
                    : '上下文：${formatTokenCount(used ?? size ?? 0)}',
                key: const ValueKey('conversation-context-usage-tokens'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            // 费用：Go 后端从不发射（见 ContextUsage 类文档），故实际运行时
            // 这一段不渲染。不用 0 伪造——「未提供」与「花了 0 元」是两回事。
            if (cost != null && cost.amount > 0)
              Text(
                '费用：\$${cost.amount.toStringAsFixed(4)} ${cost.currency}',
                key: const ValueKey('conversation-context-usage-cost'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// token 数文案（与 webapp `formatTokenCount` 逐字对齐）。
///
/// webapp 口径：≥ 1000 时用 K，整数不带小数（`12K`）、非整数一位小数（`12.5K`）；
/// < 1000 时直接输出数字。
///
/// 负数按 0 处理：服务端异常载荷不应产出「已用 -1」这种读数。
@visibleForTesting
String formatTokenCount(int n) {
  if (n <= 0) return '0';
  if (n >= 1000) {
    final k = n / 1000;
    return k % 1 == 0 ? '${k.toInt()}K' : '${k.toStringAsFixed(1)}K';
  }
  return '$n';
}

/// 执行等待/重试提示条：展示「尚未回复的原因」。
///
/// ## 为什么需要它
///
/// 「发了消息但迟迟没回复」有两种原因，而时间线上**都没有任何内容**：
/// 排队等执行名额，或上一轮失败正在安排重试。没有本组件，两者与「卡死」
/// 在 UI 上完全无法区分。
///
/// ## 文案逐字对齐 webapp
///
/// `apps/webapp/messages/zh.json` 与 `ChatMessageList.tsx` 的判定链：
///
/// | 条件 | 文案 |
/// |---|---|
/// | `retry_scheduled` | 正在安排第 {attempt} 次重试 |
/// | `reason == session_busy` | 正在等待当前会话完成 |
/// | `reason == user_concurrency_limit` | 正在等待用户并发额度 |
/// | `reason == global_concurrency_limit` | 正在等待执行资源 |
/// | 其余 | 正在等待执行 |
///
/// 另附 `队列：总计 {total}，你的 {user}`（webapp `queuePosition`）。
///
/// ## 视觉与 [_TurnActivityIndicator] 共用一套
///
/// 两者是同一槽位的互斥状态，故用同一颜色/圆角/旋转图标，只换文案与 Key
/// ——用户看到的是「同一条提示位」在切换内容，而不是两套不相干的横幅。
class _ExecutionStatusBar extends StatelessWidget {
  const _ExecutionStatusBar({required this.status});

  final ExecutionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final total = status.queueTotal;
    final user = status.queueUser;

    return Material(
      key: const ValueKey('conversation-execution-status'),
      // 与活动指示同用 secondaryContainer（同一槽位的互斥状态，见类文档）。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                _text(status),
                key: const ValueKey('conversation-execution-status-text'),
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            // 队列规模只在两端都已知时显示：只给一个数字会让人以为它是
            // 「总计」或「你的」中的某一个，反而歧义。
            if (total != null && user != null)
              Text(
                '队列：总计 $total，你的 $user',
                key: const ValueKey('conversation-execution-status-queue'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 横幅文案（判定链与 webapp `ChatMessageList.tsx` 一致）。
  ///
  /// ⚠️ 重试分支**不看** `reason`：Go 的 `retry_scheduled.reason` 是执行器
  /// stderr 原文（可能很长、含路径与噪声），拿它当文案会把横幅变成一堆日志。
  /// webapp 同样只用 `attempt`。
  static String _text(ExecutionStatus s) {
    if (s.kind == ExecutionStatusKind.retryScheduled) {
      // attempt 缺失时退化为 1（与 webapp 的 `|| "1"` 一致）：
      // 宁可说「第 1 次」也不要拼出「第 null 次」。
      return '正在安排第 ${s.attempt ?? 1} 次重试';
    }
    return switch (s.reason) {
      'session_busy' => '正在等待当前会话完成',
      'user_concurrency_limit' => '正在等待用户并发额度',
      'global_concurrency_limit' => '正在等待执行资源',
      _ => '正在等待执行',
    };
  }
}

/// 执行中活动指示：在「已起跑但还没有正文」的空窗期展示「已运行 X · 最近：Y」。
///
/// ## 为什么需要它
///
/// 长 turn 的静默期可达数十秒（读代码 / 跑 bash / 等模型首 token）。此时时间线
/// 一动不动，用户唯一的判断依据是「它是不是死了」。本组件把服务端 `turn_activity`
/// 里的「已运行多久 + 上一步是什么」呈现出来，让等待有可见的进展。
///
/// 离线时间线提示条（issue #26 切片 B / issue #29）。
///
/// ## 为什么需要它
///
/// 回填失败时用缓存渲染，若不给任何提示，用户看到的是**一份陈旧且不再更新
/// 的历史**——他会以为「对方没再说话」，而不是「我掉线了」。
///
/// ## 为什么没有「重试」按钮（与 `GroupListPage._CacheNotice` 不同）
///
/// 列表页那条可以「重试」是因为重试的代价小（一次列表请求）。对话页的重试
/// 要重拉整段 timeline 并**重建缓冲**，而重连本身已有入口（AppBar 的连接
/// 指示器 `onReconnect`）——再加一个按钮会让两个入口做同一件事，且用户很难
/// 分辨它们。故这里只陈述事实。
///
/// ## 为什么没有时间戳（同样与列表页那条不同）
///
/// 列表缓存的 `fetchedAt` 是**整表写入**的单一时刻，问「多旧」有意义。
/// timeline 缓存是**增量 upsert**（分页逐段追加），整 group 没有单一写入
/// 时刻；拿最大/最小 `cachedAt` 都不代表「这份历史有多旧」。与其编一个
/// 看起来精确实则误导的时间，不如只说「可能不是最新」。
class _OfflineTimelineNotice extends StatelessWidget {
  const _OfflineTimelineNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const ValueKey('conversation-offline-timeline'),
      // 与 `GroupListPage._CacheNotice` 同色：提示而非警告（数据是**有效**的，
      // 只是旧）——与错误色区分开。
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                // 不写「已中断」也不写「正在重试」：与 `_StaleTurnNotice` 同一
                // 原则——客户端不跟踪重试，没有证据就不编造。
                '离线数据 · 当前显示的是本地缓存的历史',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 超时兜底提示条：长时间未收到进展。
///
/// ## 它解决什么问题
///
/// 流式标记只有 `done` / `start` 两条清除路径。一旦 `done` 丢失（turn worker
/// 崩溃、长断线、回放窗口被打穿），UI 会**永久**停在流式态：光标不停闪、活动
/// 指示器常驻、取消按钮永久可点（点下去得到 409）。
///
/// ## 为什么必须显式提示（而不是像 webapp 那样静默回 idle）
///
/// webapp 把 lifecycle 悄悄回 `idle` 即可——它没有常驻的取消按钮。本客户端有，
/// 且 stale 时**故意保持可点**（turn 可能真在跑，而取消是用户唯一的出路）。
/// 若同时把光标停掉又不解释，用户会看到「界面静止 + 一个可以点的停止按钮」，
/// 无从判断到底是哪种状态。
///
/// ## 文案不编造
///
/// 只说「可能仍在后台运行，或已中断」——这是客户端**唯一能确证**的事：
/// - 不写「已中断」：没有终态事件就没有证据（后端可能仍在跑）；
/// - 不写「正在重试」：客户端不跟踪重试（`retry_scheduled` 走另一条通道）。
class _StaleTurnNotice extends StatelessWidget {
  const _StaleTurnNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('conversation-stale-turn'),
      // 与活动指示 / 等待提示同用 secondaryContainer：三者都是「临时状态条」，
      // 视觉上应属同一族而非各造一套。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.hourglass_disabled_outlined,
              size: SpbSpacing.lg,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                '长时间未收到新进展 · 任务可能仍在后台运行，或已中断',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ## 文案对齐 webapp
///
/// `apps/webapp/messages/zh.json`：
/// - `turnActivity` = `执行中 · 已运行 {elapsed}`
/// - `turnActivityJustStarted` = `刚开始`
/// - `turnActivityLast` = `最近：{action}`
///
/// 两者用同一套措辞，便于用户跨端对照。
class _TurnActivityIndicator extends StatelessWidget {
  const _TurnActivityIndicator({required this.activity});

  final TurnActivitySnapshot activity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final last = activity.lastEventType;

    return Material(
      key: const ValueKey('conversation-turn-activity'),
      // 与待处理栏同用 secondaryContainer：两者都是「临时状态条」，
      // 视觉上应属同一族而非各造一套。
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SpbSpacing.md,
          vertical: SpbSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: SpbSpacing.lg,
              height: SpbSpacing.lg,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: Text(
                '执行中 · 已运行 ${formatTurnElapsed(activity.elapsedMs)}',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            // 无上一步时不渲染该段：服务端首帧（刚起跑）不带 last_event_type，
            // 拼出「最近：null」比不显示更糟。
            if (last != null && last.isNotEmpty)
              Text(
                '最近：$last',
                key: const ValueKey('conversation-turn-activity-last'),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 已运行时长文案（毫秒 → 中文）。
///
/// ## 为什么在客户端算，而不是直接用服务端字符串
///
/// 服务端只给 `elapsed_ms`（数字），文案是渲染层职责。
///
/// ## 单位选择：≥ 1 分钟才拆成「X 分 Y 秒」
///
/// webapp 用 `date-fns` 的 `formatDuration({seconds}, {zero: false})`，实测输出
/// 是「3 秒」「90 秒」「7325 秒」——即**只取最大单位且不拆**（因为传进去的
/// duration 只有 `seconds` 字段）。本函数采用同一口径，但把 ≥ 60s 拆成
/// 「X 分 Y 秒」：
///
/// - `formatDuration` 在这种输入下给出的是「7325 秒」，人脑得自己除 60；
/// - 空窗期动辄几分钟，这是用户唯一的时间参照，「2 分 2 秒」比「122 秒」好读。
///
/// 这是**有意偏离**（改善可读性，不是修正错误）。若将来要求逐字对齐，改成
/// 「只取最大单位」即可，判定逻辑已在下方分开。
///
/// 负数与缺失一律按 0 处理（服务端异常载荷不产出「已运行 -1 秒」）。
@visibleForTesting
String formatTurnElapsed(int elapsedMs) {
  final totalSeconds = elapsedMs <= 0 ? 0 : (elapsedMs / 1000).round();
  if (totalSeconds < 60) return '$totalSeconds 秒';

  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (seconds == 0) return '$minutes 分钟';
  return '$minutes 分 $seconds 秒';
}

/// 连接状态指示（AppBar 右侧）。
///
/// 非已连接态时变为可点的「重连」入口；已连接态是纯展示。
/// AppBar 上的溢出菜单（窄屏收纳低频入口）。
///
/// ## 为什么用 `PopupMenuButton` 而不是 `MenuAnchor`
///
/// `PopupMenuButton` 自带定位、键盘导航与关闭语义，且 `itemBuilder` 在每次
/// 打开时重建——后者正好让「`_group` 刚加载完」这类状态在下次打开菜单时生效。
/// `MenuAnchor` 需要自己管 `MenuController` 与关闭时机，收益为零。
///
/// ## 菜单项的禁用而不是隐藏
///
/// [ConversationOverflowItem.onTap] 为 null 的项渲染成**禁用**（`enabled: false`），
/// 与 AppBar 图标同一取舍：入口消失会让用户以为「本端不支持」，置灰只说明
/// 「现在还用不了」。
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.items, required this.onSearch});

  final List<ConversationOverflowItem> items;

  /// 「在本对话中搜索」的动作（由页面提供，见 [ConversationPage.overflowItems]）。
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      key: const ValueKey('conversation-overflow-menu'),
      tooltip: '更多',
      // 回调用 `value` 而不是 `onSelected` + 枚举：条目本身就是「做什么」，
      // 再引入一个枚举只会多一层需要同步维护的映射。禁用项不进入
      // `onSelected`（`PopupMenuItem.enabled: false` 不可点）。
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        for (final item in items)
          PopupMenuItem<VoidCallback>(
            key: item.key,
            value: item.onTap,
            enabled: item.onTap != null,
            child: _OverflowMenuRow(icon: item.icon, label: item.label),
          ),
        // 搜索始终可用（它不依赖 `_group`）：搜的是已加载的时间线。
        const PopupMenuDivider(),
        PopupMenuItem<VoidCallback>(
          key: const ValueKey('menu-conversation-search'),
          value: onSearch,
          child: const _OverflowMenuRow(icon: Icons.search, label: '在本对话中搜索'),
        ),
      ],
    );
  }
}

/// 溢出菜单的一行（图标 + 文案）。
class _OverflowMenuRow extends StatelessWidget {
  const _OverflowMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: SpbSpacing.lg),
      const SizedBox(width: SpbSpacing.md),
      Text(label),
    ],
  );
}

class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.state, this.onReconnect});

  final SseState? state;

  /// 手动重连回调。为 null（或已连接）时不可点。
  final VoidCallback? onReconnect;

  /// 是否渲染点击手势。
  ///
  /// ## 为什么已连接态必须**不渲染**手势，而不是渲染一个 `onTap: null`
  ///
  /// 指示器就在 AppBar 右侧、紧邻常用区域。已连接时它每秒都会重绘（心跳虽不进
  /// 业务流，但状态流会在重连时变动），一个仍然存在的 `InkWell` 会：
  /// 1. 在水波纹与 `Semantics` 上把图标宣告成「可点」，而它其实什么都不做；
  /// 2. 在触屏上把「误碰一下」变成一次无意义的重连（重连会 teardown 当前流，
  ///    正在传输的帧会被丢掉）。
  ///
  /// 故这里按状态换 widget 树，而不是给同一个树换个空回调。
  bool get _clickable => onReconnect != null && state != SseState.connected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String tooltip) = switch (state) {
      SseState.connected => (Icons.cloud_done_outlined, scheme.tertiary, '已连接'),
      SseState.connecting => (Icons.cloud_queue, scheme.primary, '连接中'),
      SseState.reconnecting => (Icons.cloud_off_outlined, scheme.error, '重连中…'),
      SseState.failed => (Icons.cloud_off, scheme.error, '连接失败'),
      SseState.idle || null => (Icons.cloud_outlined, scheme.outline, '未连接'),
    };

    // 内边距在两个分支下**相同**：否则可点/不可点切换时图标会左右移动
    // （与停止按钮选「禁用而非隐藏」同一个理由：AppBar 宽度必须恒定）。
    final iconWidget = Padding(
      padding: const EdgeInsets.all(SpbSpacing.sm),
      child: Icon(icon, size: SpbSpacing.lg, color: color),
    );

    return Tooltip(
      key: const ValueKey('conversation-connection-indicator'),
      message: _clickable ? '$tooltip（点击重连）' : tooltip,
      child: _clickable
          ? InkWell(
              onTap: onReconnect,
              customBorder: const CircleBorder(),
              child: iconWidget,
            )
          : iconWidget,
    );
  }
}

/// 归属判定提示。
class _RoutingNotice extends StatelessWidget {
  const _RoutingNotice({this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.center,
      child: Text(
        reason == null || reason!.isEmpty ? '已自动判定归属' : '归属：$reason',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 错误项。
/// 目标自动推进停止提示（`goal_gate_stopped`）。
///
/// ## 为什么用窄条而不是错误卡
///
/// 「自动推进停止」不是错误：`goal_completed` 是**成功终态**。用
/// `ErrorBanner` 的红底会让「目标已实现」看起来像失败。故与
/// [_RoutingNotice] 同一形式（居中窄条 + 弱化色），只在有轮次信息时补一行副文案。
///
/// ## 文案来自领域层，不在这里 switch reason
///
/// 映射规则（reason → 中文）属于领域知识，且需与 miniapp 逐条一致，故放在
/// [GoalGateStoppedItem.message]（可无头单测）。本组件只负责排版。
class _GoalGateStoppedNotice extends StatelessWidget {
  const _GoalGateStoppedNotice({required this.item});

  final GoalGateStoppedItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final turns = item.turnCountLabel;

    return Align(
      alignment: Alignment.center,
      child: Column(
        key: const ValueKey('goal-gate-stopped-notice'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.message,
            textAlign: TextAlign.center,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (turns != null)
            Text(
              turns,
              textAlign: TextAlign.center,
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}

/// 自动续跑排程提示（`schedule_created`）。
///
/// ## 为什么与 [_GoalGateStoppedNotice] 同形式但分开一个组件
///
/// 两者语义相反（即将继续 vs 已停止），且**可能交替出现**（一轮排程 → 下轮
/// 熔断停止）。用同一组件会让「停止」与「继续」看起来一模一样，而那正是用户
/// 最需要分清的两个结论。故文案与图标都不同，排版形式保持一致（都是居中窄条）。
///
/// ## 为什么用 timer 图标而不是 info
///
/// 「过多久会接着跑」是**时间**语义，timer 能直接传达「等待中」。
/// 用 info 会与 [_DiagnosticNotice] 的图标撞车。
///
/// ## 文案来自领域层
///
/// 秒数与轮次的拼接规则属领域知识（且需处理字段缺失的退化），故放在
/// [ScheduleCreatedItem.userText]（可无头单测）。本组件只负责排版。
class _ScheduleCreatedNotice extends StatelessWidget {
  const _ScheduleCreatedNotice({required this.item});

  final ScheduleCreatedItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: Alignment.center,
      child: Row(
        key: const ValueKey('schedule-created-notice'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.timer_outlined,
            size: SpbSpacing.lg,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: SpbSpacing.xs),
          Text(
            item.userText,
            textAlign: TextAlign.center,
            style: textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 诊断提示（`pigo_session_missing`）。
///
/// ## 为什么单独一个组件而不是复用 [_RoutingNotice]
///
/// 两者的可见度不同：归属判定是每次路由都可能出现的常规信息，而「会话绑定
/// 失效」是**罕见且重要**的降级事件（用户会直接感知为上下文丢失）。用同一
/// 弱化样式会让这条关键线索在长对话里被忽略。故用带图标的浅色窄条，但**不用**
/// 错误红底——服务端已经处理了（新建会话继续），用户需要的是解释而非告警。
class _DiagnosticNotice extends StatelessWidget {
  const _DiagnosticNotice({required this.item});

  final DiagnosticNoticeItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('diagnostic-notice'),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: SpbSpacing.lg,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.sm),
            Expanded(
              child: SelectableText(
                item.content,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
