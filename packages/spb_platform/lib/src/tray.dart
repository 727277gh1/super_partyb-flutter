/// 托盘相关的补充类型。
///
/// 菜单项与回调类型定义在 [desktop_capabilities.dart]，本文件放
/// 「托盘状态」等需要被上层共享的可变数据模型。
library;

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
