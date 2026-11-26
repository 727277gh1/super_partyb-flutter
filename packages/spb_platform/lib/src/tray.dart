/// 托盘相关的补充类型。
///
/// 菜单项与回调类型定义在 [desktop_capabilities.dart]，本文件放
/// 「托盘状态」等需要被上层共享的可变数据模型，以及托盘的平台差异判据。
library;

import 'system_open.dart';

/// 托盘右键弹出上下文菜单时，是否必须先「把窗口置前」。
///
/// ## 为什么 Windows 必须经典 Win32 托盘 bug）
///
/// Win32 的 `TrackPopupMenu` 要求**调用窗口处于前台**，否则菜单弹出后：
/// 点外面收不回去、菜单表现为一个卡死的列表，整个应用看起来像死机
/// （Raymond Chen 的经典条目；MSDN 在 TrackPopupMenu 的 Remarks 里
/// 专门写了这条）。修法是弹菜单前调一次 `SetForegroundWindow`。
///
/// `tray_manager` 把这一步暴露为 `popUpContextMenu(bringAppToFront:)`
/// ——该参数**只在 Windows 实现**（README 明写），默认 false。不传就是
/// 把这个 bug 原样放进产品（2026-11 Windows 用户报障「快速输入菜单打开
/// 后是一个卡住的列表」）。
///
/// Linux 不需要也不能弹：appindicator 由桌面环境自行展示菜单，插件的
/// Linux 端根本没实现 `popUpContextMenu`（调了抛 MissingPluginException），
/// 且 `onTrayIconRightMouseDown` 在 Linux 上不会触发。macOS 有实现但系统
/// 会自行处理前台，保持 false 与既有行为一致。
///
/// ## 为什么是纯函数
///
/// 本机无 Windows（无法真机验证菜单行为），这条判据是「Windows 分支是否
/// 真的对」的唯一自动化保障——与 `spawnSystemOpen` 的三平台分派同一取向：
/// 平台决策必须是可无头单测的纯函数，不能散在实现里靠 `Platform.isXxx`。
bool trayMenuNeedsBringToFront(HostPlatform platform) =>
    platform == HostPlatform.windows;

/// 托盘当前展示状态。
///
/// 与 [DesktopCapabilities.setTrayMenu] 配合：状态变化 → 重建菜单 → 推送。
class TrayState {
  const TrayState({
    this.tooltip = 'Super PartyB',
    this.unreadCount = 0,
    this.syncEnabled = false,
    this.syncing = false,
  });

  final String tooltip;

  /// 未读消息数。> 0 时工具提示显示角标。
  final int unreadCount;

  /// 交付物同步开关（托盘菜单里的复选框项）。
  final bool syncEnabled;

  /// 同步进行中（菜单项显示为禁用 + 「同步中…」）。
  final bool syncing;

  TrayState copyWith({
    String? tooltip,
    int? unreadCount,
    bool? syncEnabled,
    bool? syncing,
  }) => TrayState(
    tooltip: tooltip ?? this.tooltip,
    unreadCount: unreadCount ?? this.unreadCount,
    syncEnabled: syncEnabled ?? this.syncEnabled,
    syncing: syncing ?? this.syncing,
  );

  /// 工具提示文本：有未读时带上角标。
  String get displayTooltip =>
      unreadCount > 0 ? '$tooltip ($unreadCount)' : tooltip;
}
