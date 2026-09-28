/// 数据契约：DTO / 聊天事件 / 枚举。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。
/// 事件类型常量与 Go 侧 `internal/chatbus/broker.go` 一一对应，**改动必须两边同步**。
library;

export 'src/chat_event.dart';
export 'src/chat_group.dart';
export 'src/chat_turn.dart';
export 'src/event_types.dart';
export 'src/pagination.dart';
