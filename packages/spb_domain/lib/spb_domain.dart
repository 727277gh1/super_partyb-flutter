/// 领域逻辑：用例、状态机、仓储接口。
///
/// **纯 Dart 包**：禁止 import `package:flutter/*`。
/// 依赖方向：`spb_domain` → `spb_api` / `spb_models` / `spb_core`。
/// 反向依赖（api 依赖 domain）是禁止的。
library;

// 导出的领域类型（barrel 文件，便于检索与确认公共 API 面）：
//   ChatStreamController          —— SSE 连接 + 事件缓冲 + 归约后的对话项流
//   EventReducer                  —— 事件流 → List<ConversationItem> 归约器
//   ConversationItem              —— 可渲染项 sealed 家族（User/Assistant/Tool/…）
//   QuickCaptureUseCase           —— 无归属入口提交用例（走 ChatApi.quickCapture）
//   QuickCaptureOutcome           —— 提交结果 sealed 家族（Queued/FeedbackRecorded/Unknown）
export 'src/chat_stream_controller.dart';
export 'src/conversation_item.dart';
export 'src/event_reducer.dart';
export 'src/quick_capture_usecase.dart';
