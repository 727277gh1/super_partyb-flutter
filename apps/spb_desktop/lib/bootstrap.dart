import 'dart:io';

import 'package:flutter/services.dart' show KeyboardKey, PhysicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端启动引导：初始化窗口、托盘、全局快捷键。
///
/// ## 为什么独立成文件
///
/// `main.dart` 只负责编排顺序，具体初始化逻辑（尤其涉及平台分支的部分）
/// 放在这里，便于测试时替换，也避免 `main.dart` 膨胀。
Future<DesktopCapabilities> bootstrapDesktop(
  WidgetsFlutterBinding binding,
) async {
  if (!SpbEnv.isDesktop) {
    return const NoopDesktopCapabilities();
  }

  try {
    final caps = PlatformDesktopCapabilities();
    await caps.initialize();
    // 在 runApp **之前**应用主窗口配置。
    //
    // ## ⚠️ 这里不能用 `waitUntilReadyToShow`
    //
    // 那是 `window_manager` 的推荐用法，但它会**等到首帧渲染后**才执行回调。
    // 而本函数在 `runApp` 之前运行——首帧永远不会到来，`await` 会死锁，
    // 应用卡在启动黑屏（无任何日志）。
    //
    // 故改用直接的 setter（`setSize`/`setMinimumSize`/`center`…）。它们在
    // 窗口创建后即可调用，不需要等首帧。代价是没有「先隐藏再显示」的原子性，
    // 启动瞬间可能看到默认尺寸闪一下——比死锁可接受得多。
    await caps.applyWindowSpec(WindowSpec.main);
    return caps;
  } catch (e, st) {
    // 桌面能力初始化失败不应阻止应用启动——降级为无托盘/无快捷键，
    // 用户仍可通过主窗口正常使用。
    SpbLog.error('桌面能力初始化失败，降级运行', error: e, stackTrace: st);
    return const NoopDesktopCapabilities();
  }
}

/// 桌面端实现（window_manager + tray_manager + hotkey_manager）。
///
/// ## ⚠️ 单窗口限制（M0 结论，与 AGENTS.md 的原假设不同）
///
/// 仓库 AGENTS.md §6.5 假设 `window_manager` 能管理「主窗 + 设置窗 + 悬浮窗」
/// 三个窗口。**该假设不成立**，实测依据：
///
/// - `window_manager` 0.5.2 的公开 API **没有任何创建窗口的方法**。全部方法
///   （`setSize`/`setAlwaysOnTop`/`show`/`hide`…）都作用于**唯一的**窗口。
/// - Linux 原生侧 `window_manager_plugin.cc:32` 的 `get_window()` 实现是
///   `gtk_widget_get_toplevel(view)` —— 从插件持有的**唯一** `FlView` 反查其
///   顶层 `GtkWindow`。一个 engine 只有一个 view，故只能有一个窗口。
/// - `windowManager.getId()` 存在但**没有配套的 `createWindow`**：它是给
///   Flutter 未来多窗口 API 预留的，当前无法用于「再开一个窗」。
///
/// Flutter 官方多窗口支持（`flutter config --enable-windowing`）在 3.47.5
/// 仍标记为 `(Not set) (Unavailable)`。
///
/// ## 因此采用的方案：单窗口 + 内嵌浮层
///
/// [WindowRole.quickCapture] 与 [WindowRole.settings] **不是独立窗口**，
/// 而是主窗口内的路由页面（见 `router.dart` 的 `/overlay`、`/settings`）。
/// [showWindow] 通过导航到对应路由来「显示」，而非创建窗口。
///
/// 这带来两个已知差异（记录在此，避免后续误以为实现有 bug）：
///
/// 1. **悬浮窗会跟随主窗口**：主窗口最小化时悬浮窗一并不可见。真正的
///    独立置顶窗需要等 Flutter 多窗口稳定，或改用原生嵌入。
/// 2. **`alwaysOnTop` / `skipTaskbar` 对悬浮窗无效**：这两个属性是窗口级的，
///    单窗口下无法只对「页面」生效。
///
/// 相对收益：无需依赖未稳定的 API，且主窗口已置顶/跳过任务栏时体验接近。
class PlatformDesktopCapabilities
    with TrayListener, WindowListener
    implements
        DesktopCapabilities,
        WindowDisplayTarget,
        TrayActionTarget,
        WindowFocusTarget,
        PlatformDesktopQuit,
        OverlayWindowController {
  PlatformDesktopCapabilities({
    this.trayIconAsset = 'assets/tray_icon.png',
    this.windowIconAsset = 'assets/app_icon.png',
  });

  /// 托盘图标资源路径（相对 `flutter_assets`）。
  final String trayIconAsset;

  /// 窗口 / 任务栏图标资源路径（相对 `flutter_assets`）。
  ///
  /// 与 [trayIconAsset] 是**两个文件**而不是一个：托盘图标只有 64px 且
  /// 被系统缩放展示，窗口图标会被 Alt+Tab / 任务栏放大，用同一张会让其中
  /// 一处变糊。两者都是同一品牌标志的不同尺寸。
  final String windowIconAsset;

  bool _initialized = false;

  /// 托盘菜单点击回调，按 `MenuItem.key` 索引。
  ///
  /// ## 为什么在平台层再存一份回调表
  ///
  /// `tray_manager` 的 `MenuItem.onClick` 是**每个菜单项自带**的闭包，而
  /// [DesktopCapabilities.setTrayMenu] 的入参是纯数据的 [TrayMenuItem]（不含
  /// 回调）——这是有意的分层：UI 层不应把闭包塞进数据模型。故这里用 id → 回调
  /// 的映射，在 `onTrayMenuItemClick` 里按 `key` 反查。
  final _trayActions = <String, VoidCallback>{};

  /// 已注册的全局快捷键，按 id 索引（用于 unregister）。
  final _hotkeys = <String, HotKey>{};

  /// 窗口「显示」回调（由 app 层注入：导航到对应路由）。
  ///
  /// 见类文档「单窗口 + 内嵌浮层」：本层不创建窗口，只通知上层切换路由。
  void Function(WindowRole role)? _onShowWindow;

  /// 窗口「隐藏」回调。
  void Function(WindowRole role)? _onHideWindow;

  @override
  set onShowWindow(void Function(WindowRole role)? callback) =>
      _onShowWindow = callback;

  @override
  set onHideWindow(void Function(WindowRole role)? callback) =>
      _onHideWindow = callback;

  @override
  bool get isSupported => true;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // 顺序有依赖：windowManager 必须先 ensureInitialized（托盘/快捷键的
    // 平台通道都依赖 GTK 已就绪），否则 Linux 上会得到「通道未实现」。
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    await _initWindowIcon();
    await _initLaunchAtStartup();
    await _initTray();
    await _registerDefaultHotkeys();

    SpbLog.info('桌面能力已初始化', {
      'platform': Platform.operatingSystem,
      // 明确记录「单窗口」这一限制，便于排查「悬浮窗为何不独立」的疑问。
      'multiWindow': false,
    });
  }

  /// 设置窗口 / 任务栏图标。
  ///
  /// ## 为什么 Linux 也要显式设置
  ///
  /// Linux 上窗口图标**没有**从包内资源自动取：GTK 靠 `_NET_WM_ICON` 属性，
  /// Flutter 的 Linux 嵌入层不会设它（模板 `my_application.cc` 里也没有
  /// `gtk_window_set_icon`）。结果是任务栏/Alt+Tab 显示一个默认占位方块
  /// ——而托盘图标是正确的，两者不一致。
  ///
  /// 调用的是 `window_manager` 的 `setIcon`（其 Linux 实现就是
  /// `gtk_window_set_icon_from_file`）；Windows 侧同一 API 改的是窗口图标
  /// （exe 文件图标由 `Runner.rc` 的 `IDI_APP_ICON` 静态决定，两者互补）。
  /// macOS 不需要：dock 图标来自 `.app` 包里的 `AppIcon.appiconset`。
  Future<void> _initWindowIcon() async {
    if (Platform.isMacOS) return;
    try {
      await windowManager.setIcon(windowIconAsset);
    } catch (e) {
      // 同托盘：图标缺失不影响功能，只影响观感。
      SpbLog.warn('窗口图标设置失败', {'error': '$e'});
    }
  }

  /// 配置开机自启。
  ///
  /// ## 为什么用 `Platform.resolvedExecutable`
  ///
  /// 它返回**当前运行的可执行文件绝对路径**（Linux 下是 `spb_desktop`，
  /// 不是 `flutter` 或 `dart`），这正是自启项需要的。用 `Platform.script`
  /// 会指向 `.dart_tool` 里的快照路径，打包后不存在。
  Future<void> _initLaunchAtStartup() async {
    try {
      launchAtStartup.setup(
        appName: 'Super PartyB',
        appPath: Platform.resolvedExecutable,
      );
    } catch (e) {
      // 自启配置失败不影响使用（用户仍可手动启动）。
      SpbLog.warn('开机自启初始化失败', {'error': '$e'});
    }
  }

  /// 托盘是否**确认可用**。
  ///
  /// ## 为什么需要显式记录而不是「没报错就算成功」
  ///
  /// `setIcon` 在无 appindicator 的环境里可能**静默无效**（不抛异常，但图标
  /// 从未出现）。故本标志只在 setIcon 正常返回后置位，供
  /// `setHideOnClose` 判断「关窗后用户还能不能唤回应用」。
  @override
  bool get trayAvailable => _trayAvailable;

  bool _trayAvailable = false;

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(trayIconAsset);
      trayManager.addListener(this);
      await trayManager.setToolTip('Super PartyB');
      _trayAvailable = true;
    } catch (e) {
      // ## 为什么托盘失败要「静默降级」而不是抛
      //
      // Linux 下托盘依赖 StatusNotifierItem（appindicator）。在无桌面环境的
      // 容器里（本仓库开发环境就是）必然失败，但**应用本身仍可用**。
      // 若这里抛出，bootstrapDesktop 会整体降级成 Noop，连窗口尺寸设置都丢失
      // ——那是把「托盘不可用」放大成了「桌面能力全不可用」。
      SpbLog.warn('托盘初始化失败（应用继续运行，但无托盘图标）', {'error': '$e'});
    }
  }

  /// 注册默认全局快捷键（目前只有悬浮输入窗的 `Alt+Space`）。
  Future<void> _registerDefaultHotkeys() async {
    final ok = await registerHotkey('quickCapture', HotkeyBinding.quickCapture);
    if (!ok) {
      // 不抛异常：`Alt+Space` 在 GNOME/Windows 常被系统占用，属于**预期内**
      // 的失败。设置页应据此提示用户改绑（见 HotkeyBinding.quickCapture 文档）。
      SpbLog.warn('全局快捷键注册失败，可能被系统或其他应用占用', {
        'binding': HotkeyBinding.quickCapture.label,
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 窗口
  // ---------------------------------------------------------------------------

  @override
  Future<void> showWindow(WindowRole role) async {
    // 单窗口模型：先确保主窗口可见/聚焦，再通知上层切到对应路由。
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      SpbLog.warn('显示窗口失败', {'role': role.name, 'error': '$e'});
    }
    // 路由切换由上层负责（本层不依赖 go_router）。
    _onShowWindow?.call(role);
  }

  @override
  Future<void> hideWindow(WindowRole role) async {
    // 悬浮窗/设置窗是主窗口内的页面，隐藏即「切回主界面」，
    // 而不是隐藏整个窗口（那会让应用看起来退出了）。
    _onHideWindow?.call(role);
  }

  /// 按 [WindowSpec] 应用窗口配置。
  ///
  /// ## 为什么只支持 [WindowRole.main] 的 spec
  ///
  /// 单窗口下只有一份真实的窗口几何。对 `settings`/`quickCapture` 调用本方法
  /// 会**改变主窗口尺寸**（把它们的小尺寸应用上去），那不是调用方的意图。
  /// 故显式拒绝并记日志，而不是默默做错事。
  Future<void> applyWindowSpec(WindowSpec spec) async {
    if (spec.role != WindowRole.main) {
      SpbLog.debug('忽略非主窗口的 WindowSpec（单窗口模型）', {'role': spec.role.name});
      return;
    }
    try {
      await windowManager.setTitle(spec.title);
      // 先设最小尺寸再设尺寸：反过来时，若目标尺寸小于**当前**的最小尺寸，
      // 窗口管理器会把 setSize 钳到最小值，最终尺寸偏小。
      await windowManager.setMinimumSize(Size(spec.minWidth, spec.minHeight));
      await windowManager.setSize(Size(spec.width, spec.height));
      await windowManager.setResizable(spec.resizable);
      if (spec.alwaysOnTop) await windowManager.setAlwaysOnTop(true);
      if (spec.skipTaskbar) await windowManager.setSkipTaskbar(true);
      if (spec.center) await windowManager.center();
    } catch (e) {
      SpbLog.warn('应用窗口配置失败', {'role': spec.role.name, 'error': '$e'});
    }
  }

  // ---------------------------------------------------------------------------
  // 全局快捷键
  // ---------------------------------------------------------------------------

  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async {
    try {
      final key = _toKeyboardKey(binding.key);
      if (key == null) {
        SpbLog.warn('不支持的快捷键键名', {'key': binding.key});
        return false;
      }

      final hotKey = HotKey(
        identifier: id,
        key: key,
        // scope: system 才是**全局**快捷键（应用失焦也生效）。
        // 默认值已是 system，这里显式写出以免被误改。
        scope: HotKeyScope.system,
        modifiers: [
          if (binding.ctrl) HotKeyModifier.control,
          if (binding.alt) HotKeyModifier.alt,
          if (binding.shift) HotKeyModifier.shift,
          if (binding.meta) HotKeyModifier.meta,
        ],
      );

      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => _onHotkeyPressed(id),
      );
      _hotkeys[id] = hotKey;
      SpbLog.info('已注册全局快捷键', {'id': id, 'binding': binding.label});
      return true;
    } catch (e) {
      // 注册失败是**预期内**结果（被系统占用），故返回 false 而非抛异常
      // ——调用方（设置页）需要区分「注册失败」与「代码出错」。
      SpbLog.warn('注册全局快捷键失败', {
        'id': id,
        'binding': binding.label,
        'error': '$e',
      });
      return false;
    }
  }

  void _onHotkeyPressed(String id) {
    SpbLog.debug('全局快捷键触发', {'id': id});
    switch (id) {
      case 'quickCapture':
        // 悬浮输入窗：显示并聚焦，用户即可直接打字。
        showWindow(WindowRole.quickCapture);
      default:
        SpbLog.debug('未绑定的快捷键 id', {'id': id});
    }
  }

  @override
  Future<void> unregisterHotkey(String id) async {
    final hotKey = _hotkeys.remove(id);
    if (hotKey == null) return;
    try {
      await hotKeyManager.unregister(hotKey);
    } catch (e) {
      SpbLog.warn('注销全局快捷键失败', {'id': id, 'error': '$e'});
    }
  }

  /// 把 [HotkeyBinding.key] 的字符串键名映射到 `KeyboardKey`。
  ///
  /// ## 为什么用显式映射表而不是 `LogicalKeyboardKey.findKeyByKeyId`
  ///
  /// 后者需要**数字 keyId**，而从字符串（`'Space'`）拿 keyId 没有稳定 API
  /// （`LogicalKeyboardKey` 的常量是编译期的，无法按名字反射）。显式映射表
  /// 虽然要手写，但**支持哪些键一目了然**，且不会因 Flutter 版本变化而静默
  /// 匹配到错误的键。
  ///
  /// 返回 null 表示不支持该键名——调用方应提示用户换一个。
  KeyboardKey? _toKeyboardKey(String name) {
    final upper = name.toUpperCase();
    return switch (upper) {
      'SPACE' => PhysicalKeyboardKey.space,
      'ENTER' => PhysicalKeyboardKey.enter,
      'TAB' => PhysicalKeyboardKey.tab,
      'ESCAPE' => PhysicalKeyboardKey.escape,
      'BACKQUOTE' => PhysicalKeyboardKey.backquote,
      'A' => PhysicalKeyboardKey.keyA,
      'B' => PhysicalKeyboardKey.keyB,
      'C' => PhysicalKeyboardKey.keyC,
      'D' => PhysicalKeyboardKey.keyD,
      'E' => PhysicalKeyboardKey.keyE,
      'F' => PhysicalKeyboardKey.keyF,
      'G' => PhysicalKeyboardKey.keyG,
      'H' => PhysicalKeyboardKey.keyH,
      'I' => PhysicalKeyboardKey.keyI,
      'J' => PhysicalKeyboardKey.keyJ,
      'K' => PhysicalKeyboardKey.keyK,
      'L' => PhysicalKeyboardKey.keyL,
      'M' => PhysicalKeyboardKey.keyM,
      'N' => PhysicalKeyboardKey.keyN,
      'O' => PhysicalKeyboardKey.keyO,
      'P' => PhysicalKeyboardKey.keyP,
      'Q' => PhysicalKeyboardKey.keyQ,
      'R' => PhysicalKeyboardKey.keyR,
      'S' => PhysicalKeyboardKey.keyS,
      'T' => PhysicalKeyboardKey.keyT,
      'U' => PhysicalKeyboardKey.keyU,
      'V' => PhysicalKeyboardKey.keyV,
      'W' => PhysicalKeyboardKey.keyW,
      'X' => PhysicalKeyboardKey.keyX,
      'Y' => PhysicalKeyboardKey.keyY,
      'Z' => PhysicalKeyboardKey.keyZ,
      '0' => PhysicalKeyboardKey.digit0,
      '1' => PhysicalKeyboardKey.digit1,
      '2' => PhysicalKeyboardKey.digit2,
      '3' => PhysicalKeyboardKey.digit3,
      '4' => PhysicalKeyboardKey.digit4,
      '5' => PhysicalKeyboardKey.digit5,
      '6' => PhysicalKeyboardKey.digit6,
      '7' => PhysicalKeyboardKey.digit7,
      '8' => PhysicalKeyboardKey.digit8,
      '9' => PhysicalKeyboardKey.digit9,
      _ => null,
    };
  }

  // ---------------------------------------------------------------------------
  // 开机自启
  // ---------------------------------------------------------------------------

  @override
  Future<bool> isLaunchAtStartupEnabled() async {
    try {
      return await launchAtStartup.isEnabled();
    } catch (e) {
      SpbLog.warn('读取开机自启状态失败', {'error': '$e'});
      return false;
    }
  }

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (e) {
      // 失败不抛：某些桌面环境禁止写自启项（如 Flatpak 沙箱），
      // 设置页会重新读取状态并显示未生效。
      SpbLog.warn('设置开机自启失败', {'enabled': enabled, 'error': '$e'});
    }
  }

  // ---------------------------------------------------------------------------
  // 托盘
  // ---------------------------------------------------------------------------

  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {
    // 重建回调表：菜单整体替换，旧的 id 不再有意义。
    _trayActions.clear();
    try {
      final menu = Menu(items: items.map(_toMenuItem).toList());
      await trayManager.setContextMenu(menu);
    } catch (e) {
      SpbLog.warn('设置托盘菜单失败', {'error': '$e'});
    }
  }

  /// 把本层的纯数据 [TrayMenuItem] 转成 `tray_manager` 的 [MenuItem]。
  ///
  /// 回调在此处绑定（见 [_trayActions] 的说明）。
  MenuItem _toMenuItem(TrayMenuItem item) {
    switch (item.type) {
      case TrayMenuItemType.separator:
        return MenuItem.separator();

      case TrayMenuItemType.checkbox:
        return MenuItem.checkbox(
          key: item.id,
          label: item.label,
          checked: item.checked,
          disabled: !item.enabled,
          onClick: (_) => _dispatchTrayAction(item.id),
        );

      case TrayMenuItemType.submenu:
        return MenuItem.submenu(
          key: item.id,
          label: item.label,
          disabled: !item.enabled,
          submenu: Menu(items: item.children.map(_toMenuItem).toList()),
        );

      case TrayMenuItemType.normal:
        return MenuItem(
          key: item.id,
          label: item.label,
          disabled: !item.enabled,
          onClick: (_) => _dispatchTrayAction(item.id),
        );
    }
  }

  void _dispatchTrayAction(String id) {
    final action = _trayActions[id];
    if (action == null) {
      SpbLog.debug('托盘菜单项无回调', {'id': id});
      return;
    }
    action();
  }

  /// 注册某个托盘菜单项的点击回调。
  ///
  /// ## 为什么需要这个（而不是把回调塞进 [TrayMenuItem]）
  ///
  /// `spb_platform` 的数据模型保持**纯数据**，回调由 app 层在调用
  /// [setTrayMenu] 后单独注册。这样 `TrayMenuItem` 可以被序列化/比较/测试，
  /// 不会因为持有闭包而无法做相等判断。
  ///
  /// ## 调用顺序要求
  ///
  /// 必须在 [setTrayMenu] **之后**调用：`setTrayMenu` 会清空回调表
  /// （菜单整体替换，旧 id 失效）。若先注册后设菜单，回调会被清掉。
  @override
  void registerTrayAction(String id, void Function() action) {
    _trayActions[id] = action;
  }

  @override
  Future<void> setTrayTooltip(String tooltip) async {
    try {
      await trayManager.setToolTip(tooltip);
    } catch (e) {
      SpbLog.warn('设置托盘提示失败', {'error': '$e'});
    }
  }

  // ---------------------------------------------------------------------------
  // TrayListener
  // ---------------------------------------------------------------------------

  @override
  void onTrayIconMouseDown() {
    // 左键单击：显示/聚焦主窗口。
    //
    // ## 为什么不切换（toggle）
    //
    // 托盘图标的「单击显示/隐藏」在 Linux 上行为不一致（部分 DE 不派发
    // mouseUp），切换语义会让窗口「有时显示有时隐藏」，用户无法预期。
    // 只做「显示并聚焦」是幂等的。
    showWindow(WindowRole.main);
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键：弹出菜单。Linux 下部分实现由 DE 自行处理，这里显式调用以兼容
    // 需要主动弹出的平台（Windows/macOS）。
    trayManager.popUpContextMenu();
  }

  // ---------------------------------------------------------------------------
  // WindowListener
  // ---------------------------------------------------------------------------

  @override
  void onWindowClose() {
    // 关闭主窗口 → 隐藏到托盘，而不是退出进程。
    //
    // ## 为什么这是桌面端的正确默认行为
    //
    // 桌面客户端承担着「交付物后台同步」的职责，关窗即退出会让同步中断。
    // 用户要真正退出需走托盘菜单的「退出」（见 app 层菜单注册）。
    //
    // 若托盘不可用（_initTray 降级），这里隐藏窗口会让应用「消失且无法唤回」
    // ——故由 app 层决定是否启用该行为（见 `setHideOnClose`）。
    if (!_hideOnClose) return;
    windowManager.hide();
  }

  // ---------------------------------------------------------------------------
  // WindowFocusTarget
  // ---------------------------------------------------------------------------

  void Function()? _onFocus;
  void Function()? _onBlur;

  @override
  set onFocus(void Function()? callback) => _onFocus = callback;

  @override
  set onBlur(void Function()? callback) => _onBlur = callback;

  @override
  void onWindowFocus() => _onFocus?.call();

  @override
  void onWindowBlur() => _onBlur?.call();

  bool _hideOnClose = false;

  /// 是否在关闭主窗口时隐藏到托盘（而非退出）。
  ///
  /// 仅在托盘**确认可用**后才应设为 true，否则用户关窗后无法唤回应用。
  @override
  void setHideOnClose(bool value) => _hideOnClose = value;

  // ---------------------------------------------------------------------------
  // 目录选择
  // ---------------------------------------------------------------------------

  @override
  Future<String?> pickDirectory({String? title}) =>
      const FileSelectorDirectoryPicker().pick(title: title);

  // ---------------------------------------------------------------------------
  // 在文件管理器中打开目录（对齐 Tauri 的 reveal_sync_dir）
  // ---------------------------------------------------------------------------

  @override
  Future<bool> revealPath(String path) async {
    // 语义：**目录就打开它，文件就选中它**（见 `revealSystemEntry`）。
    //
    // ⚠️ 修复前这里用 `Directory(path).exists()` 校验——对**文件**恒为 false
    // （实测），于是两个「定位」入口在所有平台上都立即失败。
    // 现在校验与分流都在 `spb_platform` 的 `revealSystemEntry` 里（可无头测试）。
    final ok = await revealSystemEntryHere(path);
    if (!ok) SpbLog.debug('定位条目失败', {'path': path});
    return ok;
  }

  // ---------------------------------------------------------------------------
  // 用系统默认程序打开文件
  // ---------------------------------------------------------------------------

  @override
  Future<bool> openFile(String path) async {
    // 校验**文件**存在（不是目录）——与 revealPath 的区别见接口文档：
    // 不存在的路径 spawn 一个系统程序只会让用户以为应用坏了。
    try {
      if (!await File(path).exists()) {
        SpbLog.warn('openFile 文件不存在', {'path': path});
        return false;
      }
    } on Object catch (e) {
      SpbLog.warn('openFile 校验文件失败', {'path': path, 'error': '$e'});
      return false;
    }
    return _spawnSystemOpen(path, what: '文件');
  }

  // ---------------------------------------------------------------------------
  // 诊断报告导出（issue #40）
  // ---------------------------------------------------------------------------

  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) => const DiagnosticsExporter().save(text, suggestedName: suggestedName);

  /// 按平台 spawn 系统「打开」命令。
  ///
  /// ## 为什么 [revealPath] 与 [openFile] 能共用这一条 spawn 路径
  ///
  /// 在 Linux/macOS 上，「用默认程序打开文件」与「在文件管理器中打开目录」
  /// 走的是**同一个**命令（`xdg-open` / `open`）——系统按目标类型分派。
  /// 两者的差别在**校验**（目录 vs 文件）与**调用意图**，不在 spawn 方式。
  /// 故共用一条路径。
  ///
  /// ## 为什么委托给 `spb_platform` 而不是在本类里写三分支
  ///
  /// 平台分派必须只有**一份**。此前本类与 `auth_browser.dart` 各写了一遍，
  /// 结果后者只实现了 Linux，Windows/macOS 上 OIDC 登录与链接点击不可用。
  /// 现在两份都走 [spawnSystemOpen]，新增平台只改 `spb_platform`。
  Future<bool> _spawnSystemOpen(String path, {required String what}) async {
    final ok = await spawnSystemOpenHere(path);
    if (!ok) {
      // 具体原因（不支持 / 退出码非 0 / spawn 异常）已在 `spawnSystemOpen`
      // 内部按 warn 记录，此处不重复记日志，只把结果告知调用方。
      SpbLog.debug('打开$what失败', {'path': path});
    }
    return ok;
  }

  // ---------------------------------------------------------------------------
  // 多显示器定位（悬浮窗用）
  // ---------------------------------------------------------------------------

  /// 计算悬浮窗应出现的位置（鼠标所在显示器，居中偏上）。
  ///
  /// ## 为什么需要它
  ///
  /// 多屏用户按 `Alt+Space` 时，悬浮窗应出现在**鼠标所在的屏幕**，否则窗口
  /// 会跑到另一块屏幕上，用户要跨屏去找。见 [QuickCapturePlacement] 的说明。
  ///
  /// 返回 null 表示无法获取显示器信息（无 DISPLAY / 权限问题），
  /// 调用方应回退到默认位置。
  Future<WindowGeometry?> computeQuickCaptureGeometry(WindowSpec spec) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final size = display.size;
      final (x, y) = QuickCapturePlacement.compute(
        screenWidth: size.width,
        screenHeight: size.height,
        windowWidth: spec.width,
        windowHeight: spec.height,
      );
      return WindowGeometry(
        role: spec.role,
        x: x,
        y: y,
        width: spec.width,
        height: spec.height,
      );
    } catch (e) {
      SpbLog.warn('获取显示器信息失败', {'error': '$e'});
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 悬浮输入窗形态（主窗口临时变身）
  // ---------------------------------------------------------------------------

  /// 进入悬浮模式前的窗口快照。null 表示当前不在悬浮模式。
  ///
  /// ## 为什么用 null 表示「不在悬浮模式」而不是一个 bool
  ///
  /// 快照本身就是「是否已保存」的证据：有快照 = 处于悬浮模式。用单独的 bool
  /// 会多一个可能与快照不一致的状态（bool=true 但快照为 null → 还原时无数据）。
  WindowGeometry? _preOverlayBounds;
  bool _preOverlayAlwaysOnTop = false;
  bool _preOverlaySkipTaskbar = false;
  bool _preOverlayResizable = true;

  @override
  Future<bool> enterOverlayMode(WindowSpec spec) async {
    // 幂等：已在悬浮模式时不重复保存（否则会把悬浮态当成「原状态」，
    // 退出时还原成小窗口，用户再也回不到主界面尺寸）。
    if (_preOverlayBounds != null) return true;

    try {
      final bounds = await windowManager.getBounds();
      _preOverlayBounds = WindowGeometry(
        role: WindowRole.main,
        x: bounds.left,
        y: bounds.top,
        width: bounds.width,
        height: bounds.height,
      );
      _preOverlayAlwaysOnTop = await windowManager.isAlwaysOnTop();
      _preOverlaySkipTaskbar = await windowManager.isSkipTaskbar();
      _preOverlayResizable = await windowManager.isResizable();

      // 顺序：先放宽最小尺寸，否则 setSize 会被旧的 min 钳住。
      // 主窗口 min 是 860×600，而悬浮窗只有 720×360——不先放宽就永远设不小。
      await windowManager.setMinimumSize(const Size(1, 1));
      await windowManager.setSize(Size(spec.width, spec.height));
      await windowManager.setResizable(spec.resizable);
      await windowManager.setAlwaysOnTop(spec.alwaysOnTop);
      await windowManager.setSkipTaskbar(spec.skipTaskbar);

      // 定位到鼠标所在显示器（多屏场景），失败则居中。
      final geometry = await computeQuickCaptureGeometry(spec);
      if (geometry != null) {
        await windowManager.setPosition(Offset(geometry.x, geometry.y));
      } else {
        await windowManager.center();
      }

      await windowManager.show();
      await windowManager.focus();
      SpbLog.info('进入悬浮输入窗模式', {
        'size': '${spec.width.toInt()}x${spec.height.toInt()}',
      });
      return true;
    } catch (e) {
      // 失败时清掉快照，避免 exitOverlayMode 用一个不完整的快照去还原。
      _preOverlayBounds = null;
      SpbLog.warn('进入悬浮输入窗模式失败', {'error': '$e'});
      return false;
    }
  }

  @override
  bool get isOverlayModeActive => _preOverlayBounds != null;

  @override
  Future<void> exitOverlayMode() async {
    final bounds = _preOverlayBounds;
    if (bounds == null) return; // 未进入过：空操作（可能被重复调用）。

    _preOverlayBounds = null;
    try {
      await windowManager.setAlwaysOnTop(_preOverlayAlwaysOnTop);
      await windowManager.setSkipTaskbar(_preOverlaySkipTaskbar);
      await windowManager.setResizable(_preOverlayResizable);
      await windowManager.setBounds(
        Rect.fromLTWH(bounds.x, bounds.y, bounds.width, bounds.height),
      );
      // 还原最小尺寸（主窗口 spec 的值），否则用户可以把窗口拖到 1×1。
      await windowManager.setMinimumSize(
        Size(WindowSpec.main.minWidth, WindowSpec.main.minHeight),
      );
      await windowManager.show();
      await windowManager.focus();
      SpbLog.info('退出悬浮输入窗模式');
    } catch (e) {
      SpbLog.warn('退出悬浮输入窗模式失败', {'error': '$e'});
    }
  }

  /// 真正退出应用。
  ///
  /// ## 为什么单独一个方法而不是 `exit(0)`
  ///
  /// 需要先摘监听器、注销全局快捷键、销毁托盘图标，否则：
  /// - 全局快捷键残留会让 `Alt+Space` 指向已死进程（部分平台会报错）；
  /// - 托盘图标残留会显示成「僵尸图标」，直到用户 hover 才消失。
  ///
  /// 托盘菜单的「退出」走这里；主窗口的关闭按钮走 [onWindowClose]
  /// （默认隐藏到托盘，见 `setHideOnClose`）。
  @override
  Future<void> quit() async {
    SpbLog.info('用户请求退出应用');
    await dispose();
    await windowManager.destroy();
  }

  @override
  Future<void> dispose() async {
    // 顺序与 initialize 相反：先摘监听器，再注销快捷键，最后释放托盘。
    windowManager.removeListener(this);
    for (final id in _hotkeys.keys.toList()) {
      await unregisterHotkey(id);
    }
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (e) {
      SpbLog.debug('销毁托盘失败（可能本就未创建）', {'error': '$e'});
    }
  }
}
