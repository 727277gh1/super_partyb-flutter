/// 平台能力抽象：多窗口、托盘、全局快捷键、文件选择、通知。
///
/// 移动端与桌面端的差异**全部收敛在本包**：上层（`spb_features` / apps）
/// 只调用本包的能力接口，不直接 import 平台插件。
///
/// WHY 必须隔离：`window_manager` / `tray_manager` / `hotkey_manager` 都是
/// 桌面专属插件，在 Android/iOS 上编译期虽能通过（有 no-op 实现），
/// 但调用会抛异常。用接口隔离后，移动端可以注入 [NoopDesktopCapabilities]，
/// 而不是靠 `if (Platform.isAndroid)` 散落各处。
library;

///   DesktopCapabilities        —— 平台能力接口（窗口/托盘/快捷键/目录选择）
///   NoopDesktopCapabilities     —— 移动端/不支持平台的空实现
///   LocalFileSink               —— 原子写入 + 路径穿越防御的落盘实现（同时实现 LocalFileReader）
///   LocalNotificationSink       —— flutter_local_notifications 支撑的通知发送（契约在 spb_domain）
///   DiagnosticsExporter         —— 诊断报告「另存为」（issue #40）
///   diagnosticsEnvironment / exportDiagnosticsReport
///                               —— 诊断报告的环境信息采集与一步到位导出
///   DragDropCapability          —— 文件拖入抽象（桌面实现 / 移动端空实现）
///   DroppedFile                 —— 拖入文件的归一形态（惰性读字节）
///   scanLocalGroups / scanLocalStats —— 本地同步目录扫描（只认 group_id 形状）
///   executePrunePlan            —— 按计划清理本地目录（删除前重新校验）
///   HostPlatform / ProcessRunner / spawnSystemOpen / spawnSystemReveal
///                               —— 系统「打开 / 定位」命令的三平台分派（可注入以便测试）
///   installGlobalErrorHandlers   —— 全局错误兜底（FlutterError / PlatformDispatcher
///                                  / Zone 三道防线 → SpbLog 环形缓冲，issue #45）
export 'src/desktop_capabilities.dart';
export 'src/diagnostics_export.dart';
export 'src/directory_picker.dart';
export 'src/drag_drop.dart';
export 'src/file_sink.dart';
export 'src/global_error_handler.dart';
export 'src/local_notification_sink.dart';
export 'src/local_prune.dart';
export 'src/overlay_files.dart';
export 'src/system_open.dart';
export 'src/tray.dart';
export 'src/window_manager.dart';
