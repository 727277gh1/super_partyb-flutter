/// 悬浮输入窗（quick capture）功能模块。
///
/// 「无归属入口」：用户打一句话，由服务端分类链决定它属于哪个对话
/// （与 MQ inbound 同语义）。页面**不接受** group_id 参数——见
/// [QuickCapturePage] 与 `QuickCaptureSubmit` 的说明。
library;

export 'overlay_quick_capture_page.dart';
export 'quick_capture_page.dart';
