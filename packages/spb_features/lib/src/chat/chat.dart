/// 聊天功能模块：对话界面与输入组件。
///
/// ## 分层职责
///
/// 本目录只做**渲染与交互**：消费 `spb_domain` 的归约结果（`ConversationItem`），
/// 调 `spb_domain` 的控制器/用例发送。**不含**归约逻辑、不含 HTTP 调用
/// （除 [GroupListPage] 直接调 `ChatApi.listGroups`——那是纯列表拉取，
/// 没有领域规则可放）。
///
/// ## 设计令牌
///
/// 所有间距/圆角/动效时长一律取 `spb_design` 的 `SpbSpacing` / `SpbRadius` /
/// `SpbDuration`，**不写魔法数**。这样主题调整只需改令牌文件。
library;

export 'assistant_message_bubble.dart';
export 'confirmation_card.dart';
export 'conversation_page.dart';
export 'follow_up_chips.dart';
export 'group_list_page.dart';
export 'message_composer.dart';
export 'thought_tile.dart';
export 'tool_call_tile.dart';
export 'user_message_bubble.dart';
