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
///   BiometricGate / BiometricAvailability / BiometricAuthOutcome
///                               —— 生物识别门禁契约（issue #94）。**只有契约**，
///                                  `local_auth` 的桥接在 `apps/spb_mobile`；
///                                  「回前台要不要重新上锁」的纯逻辑
///                                  （`shouldLockOnResume`）也在本包。
///   WeChatMiniProgramLauncher / OpenSdkMiniProgramLauncher
///                               —— 微信 OpenSDK 唤起小程序（issue #92，服务端
///                                  scheme 对个人主体不可用时的唯一通道）
///   HostPlatform / ProcessRunner / spawnSystemOpen / spawnSystemReveal
///                               —— 系统「打开 / 定位」命令的三平台分派（可注入以便测试）
///   normalizeWindowsPath        —— explorer 只认原生分隔符：混合分隔符路径
///                                  归一化（issue #97）
///   WindowsRevealBackend / Shell32RevealBackend
///                               —— Windows「在资源管理器中选中」的原生实现
///                                  （SHOpenFolderAndSelectItems，issue #97）
///   OverlayWindowAttribute / overlayRollbackOrder
///                               —— 悬浮窗属性改写与失败回滚顺序（纯逻辑，可无头单测）
///   fitOverlayWindowHeight / kOverlayMin/MaxWindowHeight
///                               —— 悬浮窗「内容高度 → 窗口高度」的取整与夹取
///                                  （纯逻辑，可无头单测）
///   installGlobalErrorHandlers   —— 全局错误兜底（FlutterError / PlatformDispatcher
///                                  / Zone 三道防线 → SpbLog 环形缓冲，issue #45）
///   FrameTimingReporter / summarizeTimings / installFrameTimingReporter
///                               —— 帧耗时观测（按批次汇总慢帧 → SpbLog，
///                                  由 `SPB_FRAME_TIMING` 编译期开关控制）
///   configureImageCache / imageDecodeCeilingFor
///                               —— 全局 imageCache 显式上限与解码降采样
///                                  （docs/memory-audit.md G4）
///   installMemoryPressureHandler —— 系统内存压力信号 → 清 imageCache +
///                                  app 层可再生态（docs/memory-audit.md G9）
///   MemoryProbe / MemorySample / installMemoryProbe
///                               —— 进程内存采样（RSS / 峰值 / imageCache 占用
///                                  → 有界环形缓冲 → 导出诊断日志）
///   MemoryWatchdog / installMemoryWatchdog
///                               —— 内存高水位日志（低频、边沿触发，带
///                                  MemoryLedger 分解；见 memory-audit §四）
///   installSessionEndHandler / uninstallSessionEndHandler
///                               —— 宿主「会话即将结束」接线（Windows
///                                  Restart Manager 升级安装要求客户端退出，
///                                  见 §6.87）
///   SpbDisplayEnv / detectRemoteSession
///                               —— 远端桌面（RDP）会话探测：诊断读数 +
///                                  远端会话下关闭动效的依据（issue #110，§6.96）
export 'src/biometric_gate.dart';
export 'src/desktop_capabilities.dart';
export 'src/diagnostics_export.dart';
export 'src/directory_picker.dart';
export 'src/display_env.dart';
export 'src/drag_drop.dart';
export 'src/file_sink.dart';
export 'src/frame_activity.dart';
export 'src/frame_timing.dart';
export 'src/global_error_handler.dart';
export 'src/image_cache_config.dart';
export 'src/local_notification_sink.dart';
export 'src/local_prune.dart';
export 'src/memory_pressure.dart';
export 'src/memory_probe.dart';
export 'src/memory_watchdog.dart';
export 'src/overlay_files.dart';
export 'src/overlay_window_state.dart';
export 'src/session_end.dart';
export 'src/system_open.dart';
export 'src/tray.dart';
export 'src/windows_reveal.dart';
export 'src/window_manager.dart';
export 'src/wechat_launcher.dart';
