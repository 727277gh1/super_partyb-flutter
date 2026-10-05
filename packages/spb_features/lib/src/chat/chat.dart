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
/// ## 设计令牌
///
/// 所有间距/圆角/动效时长一律取 `spb_design` 的 `SpbSpacing` / `SpbRadius` /
/// `SpbDuration`，**不写魔法数**。这样主题调整只需改令牌文件。
library;

export 'agent_file_card.dart';
export 'agent_switcher.dart';
export 'assistant_message_bubble.dart';
export 'confirmation_card.dart';
export 'conversation_page.dart';
export 'feedback_request_card.dart';
export 'follow_up_chips.dart';
export 'chat_sidebar.dart';
export 'group_deliverables_panel.dart';
export 'group_debug_panel.dart';
export 'group_gate_panel.dart';
export 'group_todos_panel.dart';
export 'group_tool_calls_panel.dart';
export 'group_management.dart';
export 'group_settings.dart';
export 'group_settings_panel.dart';
export 'group_list_page.dart';
export 'habit_suggestion_card.dart';
export 'habit_suggestion_editor.dart';
export 'my_turns_page.dart';
export 'message_composer.dart';
export 'pending_messages_bar.dart';
export 'pending_confirmations_page.dart';
export 'search_page.dart';
export 'spec_ui_card.dart';
export 'thought_tile.dart';
export 'tool_call_tile.dart';
export 'user_message_bubble.dart';
