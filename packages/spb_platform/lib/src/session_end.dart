import 'package:flutter/services.dart';

import 'package:spb_core/spb_core.dart';

/// 宿主生命周期通道名（**原生 → Dart**）。
///
/// ⚠️ 必须与原生侧逐字一致：`apps/spb_desktop/windows/runner/flutter_window.cpp`
/// 的 `kHostLifecycleChannelName`。写错不会报错，只会表现为 Dart 侧永远收不到
/// 「会话即将结束」——即安装包升级时客户端照旧不退、安装程序停在「正在关闭
/// 应用」这一步（见 [installSessionEndHandler] 的说明）。
const kHostLifecycleChannelName = 'com.atjog.spb/host_lifecycle';

/// 原生侧「会话即将结束」的动作名。
const _sessionEndingMethod = 'sessionEnding';

/// 安装「会话即将结束」处理器。
///
/// [onSessionEnd] 要做的是**一次正常退出**：摘监听器、注销全局快捷键、销毁
/// 托盘图标、结束进程（真实实现见 `apps/spb_desktop/lib/desktop_integration.dart`
/// 的 `quitApplication`，它最终调到 `PlatformDesktopQuit.quit`）。
///
/// ## 它解决的是什么
///
/// Windows 的安装包（Inno Setup）升级时用 Restart Manager 关掉正在运行的
/// 客户端：`WM_QUERYENDSESSION`（lParam = `ENDSESSION_CLOSEAPP`）→
/// `WM_ENDSESSION` → 对仍未退出的 GUI 应用用 `WM_CLOSE` 兜底。而桌面端的既有
/// 行为是「关窗 = 隐藏到托盘」（`setHideOnClose` 打开 `preventClose`），
/// 于是 `WM_CLOSE` 被拦下、进程不退，安装程序停在「正在关闭应用」，用户看到
/// 的就是「装不下去了」。
///
/// 原生侧因此把 `WM_ENDSESSION` 转成这条通道调用，Dart 侧照常走 `quit()`。
/// 只做 Dart 侧「监听关闭事件」是不够的：那条事件在窗口已经隐藏、消息循环
/// 还在跑的时候照样发得出来，原生侧没有「这是安装程序要你退出」的信息。
///
/// ## 平台现状
///
/// 只有 Windows 原生侧会调用它（Linux/macOS 的安装形态是解压替换，没有
/// Restart Manager 这一步）。在其他平台注册处理器是**无操作**：没有任何人
/// 调用这条通道，不会抛异常，也不影响启动。
///
/// ## 为什么是全局函数而不是能力接口
///
/// 与 `readClipboardFiles` 同一取向：这是一次纯粹的**通道接线**，没有需要
/// 实现方记住的状态，也不需要上层做 try/catch——`onSessionEnd` 自己负责
/// 记日志（`quitApplication` 就是那样做的）。
///
/// ## 为什么要允许重复安装
///
/// `MethodCallHandler` 是「整个通道一个」的全局槽位，重复安装等于**替换**。
/// 应用启动只会装一次；`detach` 时摘掉（[uninstallSessionEndHandler]），
/// 再 `attach` 就再装上——测试里会这么做，故不能假设「只装一次」。
void installSessionEndHandler(Future<void> Function() onSessionEnd) {
  const channel = MethodChannel(kHostLifecycleChannelName);
  channel.setMethodCallHandler((call) async {
    if (call.method != _sessionEndingMethod) {
      // 未知动作不抛：通道另一侧是原生代码，抛错只会变成静默丢弃的
      // PlatformException，而日志是唯一能查的东西。
      SpbLog.warn('收到未知的宿主生命周期动作，忽略', {'method': call.method});
      return null;
    }
    await onSessionEnd();
    return null;
  });
}

/// 摘除处理器。
///
/// 只有 `detach`（应用退出/测试复位）需要，正常运行时不需要手动调用。
void uninstallSessionEndHandler() {
  const MethodChannel(kHostLifecycleChannelName).setMethodCallHandler(null);
}
