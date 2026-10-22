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

  /// 悬浮输入窗的标准配置（**纯文本**，无附件）。
  ///
  /// 尺寸偏小且置顶，符合「一句话输入」的用途。
  /// 带附件的版本见 [quickCaptureWithAttachments]。
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

  /// 悬浮输入窗（**支持附件拖入**）的配置。
  ///
  /// # 为什么需要单独一个 spec 而不是把 quickCapture 改高
  ///
  /// [quickCapture] 的高度（132）是按「一行输入 + 一行提示」算出来的，
  /// 且该尺寸被 `quick_capture_page_test.dart` 断言为「输入框必须单行」。
  /// 带附件的窗口需要额外容纳：
  ///   - 附件 chip 行（至少一行，约 32px）
  ///   - 多行输入（最多 4 行，约 96px）
  /// 直接改 quickCapture 会让那条断言失效，也会让不需要附件的场景白白占屏幕。
  ///
  /// # 尺寸取值的依据
  ///
  /// 高 320：一行 chip（32）+ 四行输入（约 96）+ 状态行（20）+ 按钮行（36）
  /// + 内边距（约 40）+ 余量。留余量是因为字体/DPI 缩放会让实际高度浮动
  /// （Flutter 的逻辑像素在不同 DPI 下对应的物理高度不同）。
  /// 高 360 允许窗口被用户拖高一点；宽 720 让附件 chip 能并排放下两个。
  static const quickCaptureWithAttachments = WindowSpec(
    role: WindowRole.quickCapture,
    title: '快速输入',
    width: 720,
    height: 360,
    minWidth: 560,
    minHeight: 240,
    alwaysOnTop: true,
    skipTaskbar: true,
    // 允许用户拖高：附件多时 chip 会换行，固定高度会把输入框挤没。
    resizable: true,
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

  /// 在系统文件管理器中**定位**一个本地条目（文件或目录）。
  ///
  /// 调用方传入**绝对路径**。实现应校验它存在（不存在返回 false，避免
  /// 启动一个打开空路径的文件管理器让用户以为应用坏了），再按平台 spawn：
  ///
  /// | 平台 | 命令 | 行为 |
  /// |---|---|---|
  /// | Windows | `explorer /select,<path>` | 在资源管理器里**选中**它 |
  /// | macOS | `open -R <path>` | 在 Finder 里选中它 |
  /// | Linux | `xdg-open <父目录>` | 打开所在目录（freedesktop 无选中概念） |
  ///
  /// 返回 true 表示已成功发起；false 表示不支持、路径不存在或 spawn 失败。
  /// **不抛异常**——对齐本接口既有的静默降级哲学：上层只在 false 时提示
  /// 用户一次，不写 try/catch。
  ///
  /// ## ⚠️ 必须同时接受**文件**（这是一次真实缺陷的修法）
  ///
  /// 修复前本方法只接受目录：实现里用 `Directory(path).exists()` 校验，
  /// 而 `Directory(<文件路径>).exists()` 恒为 false（实测）。于是时间线卡片与
  /// 交付物面板的「在文件管理器中定位」**在三个平台上都**立即返回 false，
  /// 用户看到的就是「点了没反应 / 无法定位文件」。
  ///
  /// 同一处还有第二个缺陷：即使放行，Windows 分支 spawn 的是
  /// `explorer <path>`——那是**用默认程序打开**，不是定位。两者现已一并修正
  /// （定位走 `spawnSystemReveal`，打开走 `spawnSystemOpen`）。
  Future<bool> revealPath(String path);

  /// 用系统默认程序打开**文件**（非目录）。
  ///
  /// ## 为什么与 [revealPath] 分开两个方法而不是合一个
  ///
  /// 两者语义不同、目标类型不同，且各有明确的调用场景：
  /// - [revealPath]：在文件管理器里**定位**条目（用户想找文件在哪）；
  /// - [openFile]：用默认程序**打开**文件（用户想看内容）。
  ///
  /// 合成一个「按类型自动决定行为」的方法会把「我要定位还是打开」这个**意图**
  /// 从调用点抹掉——调用方本想打开一个文件，却因传入了目录路径而被定位，
  /// 或反之。分开后调用点表达的就是它的真实意图。
  ///
  /// 这也与 webapp 的两个独立命令（`open_local_file` / `reveal_local_file`）
  /// 对齐。
  ///
  /// ## 为什么校验的是「文件存在」而不是「目录存在」
  ///
  /// 同 [revealPath] 的谨慎：不存在的路径 spawn 一个系统程序只会让用户以为
  /// 应用坏了。故先校验（[File] 而非 [Directory]），再 spawn。
  ///
  /// 返回 true 表示成功发起；false 表示不支持、文件不存在或 spawn 失败。
  /// **不抛异常**（同 [revealPath]）。
  Future<bool> openFile(String path);

  /// 释放资源。
  Future<void> dispose();

  /// 把诊断报告写入用户选定的文件（issue #40）。
  ///
  /// ## 为什么返回三态枚举而不是 `bool` / `String?`
  ///
  /// 调用方（设置页）需要给**不同**的反馈：
  /// - [DiagnosticsExportOutcome.saved] → 「已导出」；
  /// - [DiagnosticsExportOutcome.cancelled] → **什么都不说**（用户自己点了
  ///   取消，再弹一条「已取消」是噪音）；
  /// - [DiagnosticsExportOutcome.failed] → 「导出失败」。
  ///
  /// 用 `bool` 会把「取消」与「失败」合并，于是取消时弹一个失败提示（用户
  /// 以为功能坏了）；用 `String?`（非空即成功）会丢掉「失败」这一态。
  ///
  /// ## 为什么日志写入失败也算「失败」而不是抛
  ///
  /// 与 [revealPath] / [openFile] 同一约定：调用方不该为此写 try/catch。
  /// 磁盘满、路径只读、用户选了不可写目录都是**预期内**的降级路径，
  /// 记日志 + 返回 [DiagnosticsExportOutcome.failed] 即可。
  ///
  /// [suggestedName] 是保存对话框的默认文件名，由调用方给（它才知道「现在
  /// 几点、哪个平台」）——本层不自己编时间戳。
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  });
}

/// 诊断报告的导出结果。
///
/// 见 [DesktopCapabilities.saveDiagnostics] 的说明：三态而非布尔，因为
/// 「用户取消」与「写入失败」对用户意味着完全不同的两件事。
enum DiagnosticsExportOutcome {
  /// 已写入用户选定的文件。
  saved,

  /// 用户取消了保存对话框（或平台返回了空路径）。**不是错误**。
  cancelled,

  /// 打开对话框或写入文件时出错。
  failed,

  /// 当前平台没有这个能力（[NoopDesktopCapabilities]）。
  ///
  /// 与 [failed] 分开：装配层可以据此**不展示**入口（而不是展示一个点了
  /// 必失败的按钮）。
  unsupported,
}

/// 「窗口显示/隐藏」的可接线能力。
///
/// ## 为什么单独一个接口，而不是加进 [DesktopCapabilities]
///
/// [DesktopCapabilities] 的语义是「**能力**」（能做什么），本接口的语义是
/// 「**接线点**」（把事件抛给谁）。两者生命周期不同：
///
/// - 能力实现分桌面（真实）与移动端（[NoopDesktopCapabilities]）；
/// - 接线点只有**能真正接收事件**的实现才需要，Noop 与测试桩都不需要。
///
/// 若把回调塞进 [DesktopCapabilities]，所有实现（含 3 个测试桩）都被迫实现
/// 一对它们毫无意义的字段，且「测试桩忘记赋值 → 回调为 null → 静默不导航」
/// 这类问题只会在运行时暴露。
///
/// ## 为什么用「设置字段」而不是「注册监听器」
///
/// 只有**一个**消费者（`DesktopIntegration`），不需要多播。字段语义更简单：
/// 后设置的覆盖先前的，`null` 表示不接线（应用退出时）。
abstract interface class WindowDisplayTarget {
  /// 显示某角色窗口的请求。实现方应**同步**触发（调用方不等待结果）。
  ///
  /// 设为 null 表示摘除接线。
  set onShowWindow(void Function(WindowRole role)? callback);

  /// 隐藏某角色窗口的请求。
  set onHideWindow(void Function(WindowRole role)? callback);
}

/// 「窗口聚焦状态变化」的可接线能力。
///
/// ## 为什么单独一个接口，而不是加进 [DesktopCapabilities]
///
/// 与 [WindowDisplayTarget] 同一理由：这是**接线点**（把事件抛给谁），不是
/// 「平台有没有这个能力」。Noop 实现与测试桩都不需要它。
///
/// ## 为什么是「推送」而不是「查询」
///
/// 消费方（`ConfirmationNotifier` 的前台判定，见 issue #21）需要**同步**答案，
/// 而 `windowManager.isFocused()` 是异步的平台通道调用——每次判定都 await
/// 一次往返既慢，又会在 `flutter test` 里因没有平台通道而挂住。故由实现方在
/// 焦点事件到达时推送，消费方只存最后已知值。
abstract interface class WindowFocusTarget {
  /// 窗口获得焦点。设为 null 表示摘除接线。
  set onFocus(void Function()? callback);

  /// 窗口失去焦点。设为 null 表示摘除接线。
  set onBlur(void Function()? callback);
}

/// 托盘菜单的可接线能力。
///
/// 与 [WindowDisplayTarget] 同一理由：托盘菜单项是**纯数据**
/// （[TrayMenuItem] 不含闭包），回调需要在推送菜单后单独注册。这个「注册」
/// 动作是接线点，不是能力，故单独成接口。
///
/// 见 `DesktopIntegration` 的说明：必须先 [setTrayMenu] 再 [registerTrayAction]。
abstract interface class TrayActionTarget {
  /// 推送托盘菜单（纯数据）。
  Future<void> setTrayMenu(List<TrayMenuItem> items);

  /// 注册某个菜单项的点击回调。
  ///
  /// **必须在 [setTrayMenu] 之后调用**：前者会清空回调表（菜单整体替换，
  /// 旧 id 失效）。
  ///
  /// ## 为什么是 `void Function()` 而不是 `VoidCallback`
  ///
  /// 本文件只依赖 `spb_core`，没有 import `package:flutter`。用原生函数类型
  /// 可以避免为一个类型别名（`VoidCallback` 就是 `void Function()`）给这个
  /// 契约文件引入 Flutter 依赖——让「能力接口」保持与 UI 框架无关。
  void registerTrayAction(String id, void Function() action);

  /// 托盘是否**确认可用**（图标已成功创建）。
  ///
  /// 用于决定「关闭主窗口是隐藏到托盘还是退出」——见 `DesktopIntegration`。
  bool get trayAvailable;

  /// 是否在关闭主窗口时隐藏到托盘。
  void setHideOnClose(bool value);
}

/// 「真正退出应用」的能力。
///
/// ## 为什么不放进 [DesktopCapabilities]
///
/// [DesktopCapabilities.dispose] 的语义是「释放资源」（应用已在退出流程中），
/// 而 `quit` 是「**发起**退出」（摘监听器 → 注销快捷键 → 销毁托盘 → 结束进程）。
/// 两者前置条件不同：`dispose` 可以在任何时候调用，`quit` 只能由用户动作触发。
///
/// ## 为什么需要它
///
/// 桌面端的默认行为是「关窗 = 隐藏到托盘」（保留后台同步）。因此必须有另一条
/// **明确的**退出路径，否则用户无法真正结束应用——只能杀进程。托盘菜单的
/// 「退出」项就是这条路。
///
/// 没有托盘时（Linux 无 appindicator 等）不启用「关窗即隐藏」，
/// 此时关闭主窗口即退出，本能力不被调用。
abstract interface class PlatformDesktopQuit {
  /// 摘除监听器、注销快捷键、销毁托盘图标，然后结束进程。
  Future<void> quit();
}

/// 悬浮输入窗的「窗口形态」切换能力。
///
/// ## 为什么需要它（而不是「再开一个窗口」）
///
/// `window_manager` 做不到多窗口（见 `bootstrap.dart` 的类文档），但悬浮窗的
/// **置顶**是核心需求——否则用户按 `Alt+Space` 打完字，窗口被其他程序遮住。
///
/// 故采用「主窗口临时变身」：进入悬浮模式时把当前窗口改成小尺寸 + 置顶 +
/// 隐藏任务栏，退出时还原。这样在单窗口约束下仍能拿到真正的 `alwaysOnTop`
/// （那是**窗口级**属性，只对「页面」设置是无效的）。
///
/// ## 为什么单独成接口
///
/// 与 [WindowDisplayTarget] 同一理由：这是**接线/控制点**，不是「平台有没有
/// 这个能力」。Noop 实现与测试桩不需要它。
abstract interface class OverlayWindowController {
  /// 进入悬浮输入窗形态。
  ///
  /// 实现方应**先保存当前几何与窗口标志**，供 [exitOverlayMode] 还原。
  /// 重复调用应幂等（第二次不重复保存，否则会把悬浮态本身当成「原状态」）。
  ///
  /// 返回是否成功进入（平台不支持或无窗口时返回 false）。
  Future<bool> enterOverlayMode(WindowSpec spec);

  /// 退出悬浮输入窗形态，还原进入前的几何与窗口标志。
  ///
  /// 未进入过时调用应为空操作（不抛异常）——`Esc` 与「提交成功」两条路径都会
  /// 调它，可能重复触发。
  Future<void> exitOverlayMode();

  /// 当前是否处于悬浮输入窗形态。
  ///
  /// ## 为什么必须有这个 getter
  ///
  /// 调用方（`DesktopIntegration`）需要知道「现在要不要还原窗口」。若它在自己
  /// 那边存一个 `bool _overlayActive`，就有**两份状态**：悬浮窗页面自己调
  /// `exitOverlayMode()` 还原后，调用方那份仍是 true，于是下次按 `Alt+Space`
  /// 会以为「已在悬浮模式」而跳过进入——窗口不再置顶，且无任何报错。
  ///
  /// 让实现方持有唯一真相，调用方每次问它。
  bool get isOverlayModeActive;
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
  Future<bool> revealPath(String path) async {
    SpbLog.debug('revealPath 在当前平台不可用', {'path': path});
    return false;
  }

  @override
  Future<bool> openFile(String path) async {
    SpbLog.debug('openFile 在当前平台不可用', {'path': path});
    return false;
  }

  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async {
    SpbLog.debug('saveDiagnostics 在当前平台不可用', {'name': suggestedName});
    return DiagnosticsExportOutcome.unsupported;
  }

  @override
  Future<void> dispose() async {}
}
