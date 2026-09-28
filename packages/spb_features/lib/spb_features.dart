/// 功能模块：chat / works / settings / sync
///
/// ## 公共 API 出口
///
/// 本文件是本包唯一允许被外部 import 的入口，`lib/src/` 下的实现细节不对外暴露。
/// **漏 export 会让 app 无法 import**（编译器报「未找到该名称」）。
///
/// 当前导出：
///   chat          —— 对话列表 / 时间线 / 输入框 / 各类 item 组件
///   quickCapture  —— 悬浮输入窗（无归属入口，不接受 group_id）
library;

export 'src/chat/chat.dart';
export 'src/quick_capture/quick_capture.dart';
