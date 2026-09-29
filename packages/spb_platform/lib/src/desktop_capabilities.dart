import 'package:spb_core/spb_core.dart';

/// 应用窗口的逻辑角色。
///
/// 桌面端有 3 个窗口，各自生命周期与行为不同；移动端只有 [main]。
enum WindowRole {
  /// 主窗口：完整对话 UI。
  main,

  /// 设置窗口：本地同步设置、偏好。单实例。
  settings,

  /// 悬浮输入窗：`Alt+Space` 唤起，提交后隐藏。**无归属入口**。
  quickCapture,
}

/// 窗口标识与配置。
class WindowSpec {
  const WindowSpec({
    required this.role,
    required this.title,
    this.width = 1100,
    this.height = 760,
    this.minWidth = 720,
    this.minHeight = 520,
    this.center = true,
    this.alwaysOnTop = false,
    this.skipTaskbar = false,
    this.resizable = true,
    this.show = true,
  });

  final WindowRole role;
  final String title;
  final double width;
  final double height;
  final double minWidth;
  final double minHeight;
  final bool center;

  /// 悬浮窗需置顶，否则提交时会被其他窗口遮挡。
  final bool alwaysOnTop;

  /// 悬浮窗不出现在任务栏（否则 Alt+Tab 会看到一堆悬浮窗）。
  final bool skipTaskbar;

  final bool resizable;
  final bool show;

  /// 悬浮输入窗的标准配置。
  ///
  /// 尺寸偏小且置顶，符合「一句话输入」的用途。
  static const quickCapture = WindowSpec(
    role: WindowRole.quickCapture,
    title: '快速输入',
    width: 640,
    height: 132,
    minWidth: 480,
    minHeight: 132,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
  );

  /// 设置窗配置（单实例，固定尺寸）。
  static const settings = WindowSpec(
    role: WindowRole.settings,
    title: '同步设置',
    width: 760,
    height: 640,
    minWidth: 620,
    minHeight: 520,
    resizable: true,
  );

  /// 主窗口配置。
  static const main = WindowSpec(
    role: WindowRole.main,
    title: 'Super PartyB',
    width: 1180,
    height: 800,
    minWidth: 860,
    minHeight: 600,
  );
}

/// 桌面能力集合。移动端注入 [NoopDesktopCapabilities]。
///
/// 每个方法在平台不支持时应**静默降级**（记日志、返回 false/null），
/// 而不是抛异常——上层不应为「Linux 上托盘不可用」写 try/catch。
abstract interface class DesktopCapabilities {
  /// 当前平台是否支持这些能力。
  bool get isSupported;

  /// 初始化（创建托盘、注册快捷键等）。应用启动时调用一次。
  Future<void> initialize();

  /// 显示/聚焦某个角色的窗口。窗口不存在时创建。
  Future<void> showWindow(WindowRole role);

  /// 隐藏窗口（不销毁）。
  Future<void> hideWindow(WindowRole role);

  /// 注册全局快捷键。
  ///
  /// 返回是否注册成功——快捷键可能被系统或其他应用占用。
  Future<bool> registerHotkey(String id, HotkeyBinding binding);

  Future<void> unregisterHotkey(String id);

  /// 是否开机自启。
  Future<bool> isLaunchAtStartupEnabled();

  Future<void> setLaunchAtStartup(bool enabled);

  /// 设置托盘菜单项回调。
  Future<void> setTrayMenu(List<TrayMenuItem> items);

  /// 更新托盘提示文本（如显示未读数）。
  Future<void> setTrayTooltip(String tooltip);

  /// 弹出系统目录选择对话框，返回用户选择的绝对路径。
  ///
  /// 返回 null 表示**用户取消**（不是错误，调用方不应报错）；
  /// 平台不支持时同样返回 null（见 [isSupported]）。
  ///
  /// ## 为什么不抛异常
  ///
  /// 「用户点了取消」与「这个平台没有目录选择器」都是**预期内**的结果，
  /// 而异常语义是「出错了」。若取消走异常，调用方就得在 catch 里区分
  /// 「取消」与「真失败」——而 catch 块天然适合处理意外情况。
  ///
  /// ## 为什么返回路径字符串而不是 `Directory`
  ///
  /// 本包是平台能力层，而 `dart:io` 的 `Directory` 在 web 上不可用。
  /// 返回字符串让上层（含 web 构建）无需为「拿到一个目录」引入 `dart:io`。
  Future<String?> pickDirectory({String? title});

  /// 释放资源。
  Future<void> dispose();
}

/// 快捷键绑定。
class HotkeyBinding {
  const HotkeyBinding({
    required this.key,
    this.alt = false,
    this.ctrl = false,
    this.shift = false,
    this.meta = false,
  });

  /// 物理键名（如 `Space` / `K`）。用字符串而非枚举以便扩展。
  final String key;
  final bool alt;
  final bool ctrl;
  final bool shift;
  final bool meta;

  /// 悬浮输入窗的默认绑定：`Alt+Space`。
  ///
  /// ⚠️ 该组合在部分桌面环境已被占用（如 GNOME 的窗口菜单、Windows 的系统菜单）。
  /// 注册失败时应在设置页提示用户改绑。
  static const quickCapture = HotkeyBinding(key: 'Space', alt: true);

  /// 人类可读表示（设置页展示）。
  String get label {
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Meta',
      key,
    ];
    return parts.join('+');
  }
}

/// 托盘菜单项。
class TrayMenuItem {
  const TrayMenuItem({
    required this.id,
    required this.label,
    this.type = TrayMenuItemType.normal,
    this.checked = false,
    this.enabled = true,
    this.children = const [],
  });

  final String id;
  final String label;
  final TrayMenuItemType type;
  final bool checked;
  final bool enabled;
  final List<TrayMenuItem> children;

  /// 常用项工厂。
  factory TrayMenuItem.separator() => const TrayMenuItem(
    id: '__separator__',
    label: '',
    type: TrayMenuItemType.separator,
  );

  factory TrayMenuItem.checkbox({
    required String id,
    required String label,
    required bool checked,
  }) => TrayMenuItem(
    id: id,
    label: label,
    type: TrayMenuItemType.checkbox,
    checked: checked,
  );
}

enum TrayMenuItemType { normal, checkbox, separator, submenu }

/// 移动端/不支持平台的空实现。
///
/// **所有方法静默成功**：调用方无需判空，UI 只需根据 [isSupported] 决定
/// 是否展示相关设置项。
class NoopDesktopCapabilities implements DesktopCapabilities {
  const NoopDesktopCapabilities();

  @override
  bool get isSupported => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> showWindow(WindowRole role) async {
    SpbLog.debug('showWindow 在当前平台不可用', {'role': role.name});
  }

  @override
  Future<void> hideWindow(WindowRole role) async {}

  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async {
    SpbLog.debug('registerHotkey 在当前平台不可用', {'id': id});
    return false;
  }

  @override
  Future<void> unregisterHotkey(String id) async {}

  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}

  @override
  Future<void> setTrayTooltip(String tooltip) async {}

  @override
  Future<String?> pickDirectory({String? title}) async {
    SpbLog.debug('pickDirectory 在当前平台不可用', {'title': title});
    return null;
  }

  @override
  Future<void> dispose() async {}
}
