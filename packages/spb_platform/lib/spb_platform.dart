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

export 'src/desktop_capabilities.dart';
export 'src/tray.dart';
export 'src/window_manager.dart';
