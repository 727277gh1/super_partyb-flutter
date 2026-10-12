/// 聊天功能模块：对话界面与输入组件。
///
/// ## 分层职责
///
/// 本目录只做**渲染与交互**：消费 `spb_domain` 的归约结果（`ConversationItem`），
/// 调 `spb_domain` 的控制器/用例发送。**不含**归约逻辑。
///
/// HTTP 调用只有两处，都是**薄适配**（没有可复用的领域规则）：
/// - [GroupListPage] 直接调 `ChatApi.listGroups`（纯列表拉取）；
/// - [GroupManagementUseCase] 把 [GroupAction] 翻译成 `ChatApi` 的四个写端点。
///
/// 后者放在本包而非 `spb_domain` 的原因：它是**两个 app 共用的 UI 级适配**
/// （响应形状归一化 + 错误分类），且 `spb_features` 已经依赖 `spb_api`。
/// 真正的领域规则（如「失败项不写状态」）仍在 `spb_domain`。
///
/// ## 目标（goal）相关的三个面板
///
/// 它们是**三个不同维度**，不要合并：
///
/// - [GroupSettingsPanel] —— 目标**文本**与群级开关（新建/清除目标文本）；
/// - [GoalTasksPanel] —— **当前**目标的**任务**（增删改查 + 重排 + 重新展开）；
/// - [GoalHistoryPanel] —— **目标本身**的**版本与状态**（切回 / 标记完成 / 归档）。
///
/// 合并会破坏各自的定位：把版本切换塞进任务面板，会让「当前目标」这个上下文
/// 在两层列表间变得含糊；把任务增删塞进设置面板，会让实时刷新的任务表与表单
/// 草稿互相干扰。
///
/// ## 设计令牌
///
/// 所有间距/圆角/动效时长一律取 `spb_design` 的 `SpbSpacing` / `SpbRadius` /
/// `SpbDuration`，**不写魔法数**。这样主题调整只需改令牌文件。
library;

export 'agent_file_batch_card.dart';
export 'agent_file_card.dart';
export 'agent_file_preview.dart';
export 'agent_switcher.dart';
export 'assistant_message_bubble.dart';
export 'auto_schedules.dart';
export 'auto_schedules_panel.dart';
export 'confirmation_card.dart';
export 'conversation_page.dart';
export 'conversation_search_sheet.dart';
export 'feedback_request_card.dart';
export 'flush_strategy_dialog.dart';
export 'follow_up_chips.dart';
export 'chat_sidebar.dart';
export 'goal_history_panel.dart';
export 'goal_tasks_panel.dart';
export 'group_deliverables_panel.dart';
export 'group_debug_panel.dart';
export 'group_gate_panel.dart';
export 'group_todos_panel.dart';
export 'group_tool_calls_panel.dart';
export 'map_spec_card.dart';
export 'group_management.dart';
export 'group_settings.dart';
export 'group_settings_panel.dart';
export 'group_list_page.dart';
export 'habit_auto_run_card.dart';
export 'habit_suggestion_card.dart';
export 'habit_suggestion_editor.dart';
export 'my_turns_page.dart';
export 'outbox_bar.dart';
export 'message_composer.dart';
export 'pending_messages_bar.dart';
export 'row_locate_registry.dart';
export 'pending_confirmations_page.dart';
export 'search_page.dart';
export 'spec_ui_card.dart';
export 'thought_tile.dart';
export 'tool_call_tile.dart';
export 'turn_detail_panel.dart';
export 'user_message_bubble.dart';
