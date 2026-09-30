/// 数据契约：DTO / 聊天事件 / 枚举。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。
/// 事件类型常量与 Go 侧 `internal/chatbus/broker.go` 一一对应，**改动必须两边同步**。
library;

// 导出的契约类型（barrel 文件，便于检索与确认公共 API 面）：
//   ChatEvent / EventTypes          —— 聊天事件与事件类型常量
//   ChatGroup / ActiveSession       —— 对话分组与 agent 绑定会话
//   ChatInboxMessage                —— 收件箱消息（pending 接口的真实返回）
//   ChatTurn                        —— 对话轮次
//   ListResponse / CursorPage / StreamCursor —— 分页与 SSE 续接游标
//   ChatSearchHit                —— 搜索命中项（turn 摘要，**不是** ChatEvent）
//   UfsFileEntry / UfsFilePage   —— UFS 文件条目与分页响应（交付物同步用）
//   Miniapp*                     —— 小程序工作台 BFF 契约（work/artifact/confirmation/通知）
export 'src/chat_confirmation.dart';
export 'src/chat_event.dart';
export 'src/chat_group.dart';
// `show` 显式声明公共类型名，避免该模块未来新增内部辅助类时被动泄漏到公共 API。
export 'src/chat_inbox_message.dart' show ChatInboxMessage;
export 'src/chat_search_hit.dart';
export 'src/chat_turn.dart';
export 'src/chat_turn_summary.dart';
export 'src/event_types.dart';
export 'src/miniapp.dart';
export 'src/pagination.dart';
export 'src/ufs_file_entry.dart';
