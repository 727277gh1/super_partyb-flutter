import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart'
    show KeyboardKey, MissingPluginException, PhysicalKeyboardKey;
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
    // ## ⚠️ 这里不能调 `waitUntilReadyToShow(options, callback)`（带参数的形态）
    //
    // 那是 `window_manager` 的推荐用法，但它会**等到首帧渲染后**才执行回调。
    // 而本函数在 `runApp` 之前运行——首帧永远不会到来，`await` 会死锁，
    // 应用卡在启动黑屏（无任何日志）。
    //
    // 故改用直接的 setter（`setSize`/`setMinimumSize`/`center`…）。它们在
    // 窗口创建后即可调用，不需要等首帧。代价是没有「先隐藏再显示」的原子性，
    // 启动瞬间可能看到默认尺寸闪一下——比死锁可接受得多。
    //
    // （无参数的裸 `waitUntilReadyToShow()` 是安全的，见 initialize()：
    // Windows 原生只是 CoCreateInstance、Linux/macOS 是 no-op，且它在
    // 应用运行后被调，不存在「等首帧」的语义。真正危险的是带 options/
    // callback 的 Dart 侧包装——它会追加 setState 等首帧后的操作。）
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
    this.trayIconAssetWindows = 'assets/tray_icon.ico',
    this.windowIconAsset = 'assets/app_icon.png',
  });

  /// 托盘图标资源路径（相对 `flutter_assets`）。
  ///
  /// 仅 Linux/macOS 使用。Windows 走 [trayIconAssetWindows]——见那里的说明
  /// （`LoadImage` 不支持 PNG，2026-11 真实缺陷）。
  final String trayIconAsset;

  /// 托盘图标资源路径（**Windows 专用**）。
  ///
  /// ## 为什么 Windows 必须用 `.ico` 而不是 `.png`
  ///
  /// `tray_manager` 的 Windows 端 `SetIcon` 用
  /// `LoadImage(LR_LOADFROMFILE)` 从 `data/flutter_assets/` 读图标文件，
  /// 而 `LoadImage` **只认 BMP 系资源**（`.bmp` / DIB 帧的 `.ico` / `.cur`）
  /// ——给它 PNG 返回 NULL，`Shell_NotifyIcon` 挂着空 HICON，托盘上
  /// **没有任何图标**。更糟的是插件 `setIcon` **恒返回 true 不报错**，
  /// 于是 `_trayAvailable` 照样置位、「关窗即隐藏」照样生效——用户看到的
  /// 就是「图标没了但进程还活着，窗口关了就找不回应用」（2026-11 真实
  /// 报障）。
  ///
  /// `.ico` 由 `tools/gen_brand_assets.py` 与其它图标一并生成
  /// （bitmap_format='bmp'，PNG 帧的 `.ico` 同样不被 `LoadImage` 认）。
  final String trayIconAssetWindows;

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

    // ## 为什么这里要调一次裸的 waitUntilReadyToShow（无 options 无回调）
    //
    // 2026-11 Windows 实测崩溃（事件查看器：window_manager_plugin.dll +
    // c0000005，紧随「全局快捷键触发」日志）：插件 0.5.2 的 Windows 原生
    // `taskbar_`（ITaskbarList3）**只有一个初始化点**——
    // `WaitUntilReadyToShow()` 里的 `CoCreateInstance(CLSID_TaskbarList)`；
    // 而 `SetSkipTaskbar` 直接 `taskbar_->HrInit()` **不做空检查**。此前
    // 本应用从不调 waitUntilReadyToShow（见 bootstrapDesktop 的死锁警告），
    // 于是 `taskbar_` 永远是 nullptr，悬浮窗第一步 `setSkipTaskbar(true)`
    // 就是对空指针调 COM 虚方法——窗口变小后进程即死，Dart 侧 catch
    // 与 §6.57 的回滚完全不可见（原生崩溃不走 Dart 异常）。
    //
    // 这里调是安全的：①无 options 无回调，不会重设任何窗口属性；
    // ②三平台 0.5.2 原生实现都已核实——Windows = CoCreateInstance
    // （正是要的，立即返回），Linux = 直接返回 true，macOS = 空函数体。
    // 放在 initialize() 而不是 enterOverlayMode：后面**四处**
    // `setSkipTaskbar`（applyWindowSpec 的 spec.skipTaskbar 分支、悬浮窗
    // 改写步、两处回滚）全部被覆盖，不必逐处补调用。
    await windowManager.waitUntilReadyToShow();

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
    // Windows 跳过：`window_manager` 的 `setIcon` 在 Windows 上同样走
    // `LoadImage`（见 [trayIconAssetWindows] 的说明），PNG 读不出来是
    // NULL HICON——而 `WM_SETICON(NULL)` 会**移除** exe 资源图标
    // （`Runner.rc` 的 `IDI_APP_ICON`，win32_window.cpp 注册窗口类时
    // 加载）。也就是说，本机不跳过比跳过更糟：任务栏图标从「品牌图标」
    // 退回默认 Flutter 占位。
    //
    // Windows 的窗口图标已由 exe 资源静态覆盖；若将来要动态换，需先把
    // `app_icon.ico` 也打进 assets 并按平台分流（与托盘同一手法）。
    if (Platform.isWindows) return;
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
      // Windows 必须给 `.ico`（`LoadImage` 不认 PNG，见
      // [trayIconAssetWindows] 的说明）；Linux/macOS 用同一张 PNG。
      final icon = HostPlatform.current() == HostPlatform.windows
          ? trayIconAssetWindows
          : trayIconAsset;
      await trayManager.setIcon(icon);
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
      //
      // ⚠️ 已知边界：Windows 上 `tray_manager` 的 `setIcon` 恒返回 true
      // （见 [trayIconAssetWindows]），故**传错资源形态**不会被本 catch 捕获，
      // `_trayAvailable` 会误置 true。防御手段是资源本身（`.ico` 已由
      // 生成脚本落盘）而非运行时检测——运行时拿不到「图标真的显示了吗」
      // 的信号（`Shell_NotifyIcon` 的 NIM_ADD 失败在插件内部被吞）。
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
    // ⚠️ 这两行也要有日志：与 _applyOverlayStep 同一取向，原生层崩溃
    // 不走 Dart catch，若死在 show()/focus() 里，没有这行就分不清
    // 「死在导航前」还是「死在属性改写中」。
    SpbLog.info('窗口显示请求', {'role': role.name});
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
  ///
  /// ## 主窗口尺寸按屏幕工作区自适应
  ///
  /// [WindowSpec.main] 的 1180×800 是硬编码逻辑像素，在 1080p + 150% 缩放的
  /// 笔记本上逻辑工作区只有约 680 高——窗口比工作区还高，居中后 y 为负，
  /// 标题栏（拖拽区 + 最大化按钮）出屏，用户表现为「不能移动、不能全屏」。
  /// 故这里不直接用 `spec.width/height`，而是经 [MainWindowSize.compute]
  /// 按实际工作区收缩。详见该类文档的对照表。
  Future<void> applyWindowSpec(WindowSpec spec) async {
    if (spec.role != WindowRole.main) {
      SpbLog.debug('忽略非主窗口的 WindowSpec（单窗口模型）', {'role': spec.role.name});
      return;
    }
    try {
      final computed = await _mainWindowSize(spec);
      final width = computed?.$1 ?? spec.width;
      final height = computed?.$2 ?? spec.height;

      await windowManager.setTitle(spec.title);
      // 先设最小尺寸再设尺寸：反过来时，若目标尺寸小于**当前**的最小尺寸，
      // 窗口管理器会把 setSize 钳到最小值，最终尺寸偏小。
      await windowManager.setMinimumSize(Size(spec.minWidth, spec.minHeight));
      await windowManager.setSize(Size(width, height));
      await windowManager.setResizable(spec.resizable);
      if (spec.alwaysOnTop) await windowManager.setAlwaysOnTop(true);
      if (spec.skipTaskbar) await windowManager.setSkipTaskbar(true);
      if (spec.center) await windowManager.center();
      SpbLog.info('应用主窗口尺寸', {
        'size': '${width.toInt()}x${height.toInt()}',
        'spec': '${spec.width.toInt()}x${spec.height.toInt()}',
      });
    } catch (e) {
      SpbLog.warn('应用窗口配置失败', {'role': spec.role.name, 'error': '$e'});
    }
  }

  /// 按主显示器的工作区算出主窗口尺寸。
  ///
  /// 判据与降级全在 [MainWindowSize.fromDisplay]（可无头单测）；这里只负责
  /// 取 `screen_retriever` 的 `Display` 并转发。取不到显示器信息时返回 null，
  /// 由调用方退回 spec 的静态值——**不能**因此让应用起不来。
  Future<(double, double)?> _mainWindowSize(WindowSpec spec) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      return MainWindowSize.fromDisplay(
        visibleSize: display.visibleSize,
        fullSize: display.size,
        minWidth: spec.minWidth,
        minHeight: spec.minHeight,
      );
    } catch (e) {
      // 静默降级：退回规格值（与改动前行为一致），只记一条日志。
      SpbLog.debug('获取显示器工作区失败，主窗口用规格尺寸', {'error': '$e'});
      return null;
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
    // ## 为什么是 info 而不是 debug
    //
    // `SpbLog` 默认 `minLevel = info`，debug 在生产**被过滤**。
    // 「按 Alt+Space 没反应 / 窗口卡住」这类报障的第一问就是「快捷键到底
    // 有没有触发」——若这条是 debug，诊断日志与文件日志里都看不到它
    // （AGENTS.md §6.43 的同一教训）。快捷键是低频操作，info 不会刷屏。
    SpbLog.info('全局快捷键触发', {'id': id});
    switch (id) {
      case 'quickCapture':
        // 悬浮输入窗：显示并聚焦，用户即可直接打字。
        showWindow(WindowRole.quickCapture);
      default:
        SpbLog.warn('未绑定的快捷键 id', {'id': id});
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

  /// 弹出托盘右键菜单。
  ///
  /// ## 为什么 Windows 必须带 `bringAppToFront: true`
  ///
  /// Win32 的 `TrackPopupMenu` 要求调用窗口处于前台，否则菜单弹出后点外面
  /// 收不回去——用户看到的就是一个「卡住的列表」（tray_manager 的
  /// `PopUpContextMenu` 只在 `bringAppToFront` 为 true 时才调
  /// `SetForegroundWindow`）。2026-11 Windows 用户报障的原因。
  ///
  /// Linux 是空操作：`tray_manager` 的 Linux 端未实现 `popUpContextMenu`
  /// （调用会抛 `MissingPluginException`），且 appindicator 由桌面环境
  /// 自行展示菜单——这里 catch 住并记 debug，不向上抛（与 `_initTray`
  /// 同一取向：托盘异常不阻塞应用）。
  @override
  Future<void> popUpTrayContextMenu() async {
    final bringToFront = trayMenuNeedsBringToFront(HostPlatform.current());
    try {
      // `bringAppToFront` 标注了 deprecated（"only supported on Windows and
      // will be removed"）——但 Windows 上它恰恰是**必需**的（见方法文档）。
      // 若将来该参数被移除，需要自写 SetForegroundWindow（经插件 PR 或
      // 换库）；目前 tray_manager 0.5.3 仍实现它，显式忽略弃用标记。
      // ignore: deprecated_member_use
      await trayManager.popUpContextMenu(bringAppToFront: bringToFront);
    } on MissingPluginException {
      // Linux：该方法不存在，菜单由 DE 处理。这是**预期内**路径，
      // 只记 debug（SpbLog._minLevel 默认 info，不会刷生产日志）。
      SpbLog.debug('当前平台无 popUpContextMenu，菜单由桌面环境处理');
    } catch (e) {
      SpbLog.warn('弹出托盘菜单失败', {'error': '$e'});
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
    // 右键：弹出菜单。
    //
    // ## 为什么经 [popUpTrayContextMenu]（而不是这里直接 trayManager）
    //
    // 「是否需要 bringAppToFront」是平台策略，判据收在
    // `trayMenuNeedsBringToFront`（可无头单测）；本类只负责接线。见
    // `popUpTrayContextMenu` 的文档。
    unawaited(popUpTrayContextMenu());
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
    if (!_hideOnClose) {
      // 未拦截关闭（托盘不可用）：让原生侧按默认行为销毁窗口 → 进程退出。
      // 这条日志是「关窗到底退出了没有」的唯一线索（见 setHideOnClose 的
      // 说明：原生侧一旦销毁窗口，Dart 侧就再没有机会记录任何东西）。
      SpbLog.info('关闭主窗口：未启用隐藏到托盘，按默认行为退出');
      return;
    }
    // ## 为什么这条必须是 info
    //
    // 「点了关闭，应用去哪了」是关窗相关报障的第一问。`SpbLog` 默认
    // `minLevel = info`，debug 在生产被过滤（AGENTS.md §6.43 的同一教训）；
    // 关窗是低频操作，info 不会刷屏。
    SpbLog.info('关闭主窗口：隐藏到托盘（可从托盘或 Alt+Space 唤回）');
    unawaited(_hideToTray());
  }

  /// 隐藏主窗口（关窗后的实际动作）。
  ///
  /// 失败只记日志：此时窗口仍在屏幕上（用户至少不会「找不到应用」），
  /// 比反过来（以为隐藏成功、实际没有入口）好。
  Future<void> _hideToTray() async {
    try {
      await windowManager.hide();
    } catch (e) {
      SpbLog.warn('隐藏主窗口失败（应用仍在运行）', {'error': '$e'});
    }
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
  ///
  /// ## 为什么必须同时调 `setPreventClose`（2026-11 修的真实缺陷）
  ///
  /// `window_manager` 的 `close` 事件是**通知**而不是**拦截**。三平台原生侧
  /// 的顺序都是「先派发 `close` 事件，再看 `isPreventClose()` 决定要不要继续
  /// 关闭」（Windows `WM_CLOSE` 分支 `return -1`、Linux `delete_event` 回调
  /// 的返回值、macOS `windowShouldClose` 的 bool）。而事件是**异步**投递到
  /// Dart 的——等 [onWindowClose] 里的 `windowManager.hide()` 跑到时，原生侧
  /// 早已把窗口销毁了：
  ///
  /// ```
  /// 修复前：点关闭 → 原生派发 close 事件 → DefWindowProc 销毁窗口
  ///         → 消息循环退出 → 进程结束（Dart 的 hide() 永远来不及）
  /// 修复后：点关闭 → 原生派发 close 事件 → preventClose 为真 → return -1
  ///         → 窗口保留 → Dart 的 hide() 把它从屏幕上收起来
  /// ```
  ///
  /// 即「关窗即隐藏」此前**从未真正生效过**（Linux 同理，只是没人报障）；
  /// 用户看到的就是「点关闭 = 应用退出」。
  ///
  /// ## 为什么托盘不可用时要传 false
  ///
  /// 那样才允许关窗直接退出。若一律拦截，托盘又没起来（Linux 无
  /// appindicator、Flatpak 沙箱），用户点关闭会得到一个「既没退出、也没有
  /// 任何入口」的僵尸进程。
  @override
  Future<void> setHideOnClose(bool value) async {
    _hideOnClose = value;
    try {
      await windowManager.setPreventClose(value);
    } catch (e) {
      // 失败不抛：最坏结果是「关窗即退出」（= 托盘不可用时的既有行为），
      // 应用本身仍可用。
      SpbLog.warn('设置关窗拦截失败', {'hideOnClose': value, 'error': '$e'});
      return;
    }
    SpbLog.info('关窗行为已设置', {'hideOnClose': value});
  }

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

  /// 本轮**已成功执行**的改写步骤（失败时据此逆序回滚）。
  ///
  /// ## 为什么必须记下来，而不是「回滚时全部重设一遍」
  ///
  /// 全量重设会把**还没改过的**属性也写一遍（`setAlwaysOnTop(false)` 对一个
  /// 本来就没置顶的窗口是空操作，但 `setResizable(true)` 对一个用户手动设为
  /// 不可缩放的窗口就是篡改）。只回滚真正改过的，才叫「撤销」。
  final List<OverlayWindowAttribute> _overlayApplied = [];

  /// 当前正在执行的步骤（失败日志用：`failed_step`）。
  OverlayWindowAttribute? _overlayStep;

  /// 本轮悬浮模式里最后一次贴合的窗口高度（去重用；null 表示还没贴合过）。
  double? _overlayFitHeight;

  /// 「窗口外框」比「内容区」多出来的高度（逻辑像素）。
  ///
  /// ## 为什么必须实测，而不能写死「标题栏约 32px」
  ///
  /// `window_manager.setSize` 在两个平台上语义不同：Linux 走
  /// `gtk_window_resize`（client area），Windows 走 `SetWindowPos` 作用于
  /// 顶层 HWND（**含标题栏与边框**）。写死一个值在另一个平台上就会多留／
  /// 少留一条空白——正是本次要修的观感问题。
  ///
  /// 故在第一次贴合时实测：`getSize()` 与 Flutter 视图尺寸都是逻辑像素，
  /// 两者之差就是外框（`window_manager` 已按 DPR 换算过，差值可直接用）。
  double? _windowChromeHeight;

  @override
  Future<bool> enterOverlayMode(WindowSpec spec) async {
    // 幂等：已在悬浮模式时不重复保存（否则会把悬浮态当成「原状态」，
    // 退出时还原成小窗口，用户再也回不到主界面尺寸）。
    if (_preOverlayBounds != null) return true;

    _overlayApplied.clear();
    _overlayStep = null;
    _overlayFitHeight = null;
    // 外框高度**不**在这里置空：它是窗口属性（平台/主题决定），与「第几次
    // 进入悬浮模式」无关，而重测一次要额外一次平台通道往返。

    // 注：Windows 原生 taskbar_（ITaskbarList3）已在 initialize() 里经裸
    // waitUntilReadyToShow 初始化——setSkipTaskbar 对它调 HrInit() 且
    // 不做空检查，不初始化就是 c0000005 原生崩溃（详见 initialize() 内注释）。

    try {
      // ---- 阶段 1：快照（只读，失败则窗口并未被改动）----
      final bounds = await windowManager.getBounds();
      _preOverlayAlwaysOnTop = await windowManager.isAlwaysOnTop();
      _preOverlaySkipTaskbar = await windowManager.isSkipTaskbar();
      _preOverlayResizable = await windowManager.isResizable();
      // ## 为什么最小尺寸不做快照
      //
      // `window_manager` 0.5.2 **没有 `getMinimumSize()`**（只有 setter），
      // 故「调用那一刻的最小尺寸」取不到。回滚时退回
      // `WindowSpec.main.minWidth/minHeight`——那正是启动时由本类设置的唯一
      // 来源，因此实践上等价（除非将来有人加入运行期改最小尺寸的功能，那时
      // 得把值自己记在字段里）。
      // 快照完整之后才置位：`isOverlayModeActive` 的判据必须等价于
      // 「有可用的快照」（见该 getter 的文档）。
      _preOverlayBounds = WindowGeometry(
        role: WindowRole.main,
        x: bounds.left,
        y: bounds.top,
        width: bounds.width,
        height: bounds.height,
      );

      // ---- 阶段 2：改写（逐步记账，失败可逆序回滚）----
      //
      // 顺序：先放宽最小尺寸，否则 setSize 会被旧的 min 钳住。
      // 主窗口 min 是 860×600，而悬浮窗只有 720×360——不先放宽就永远设不小。
      await _applyOverlayStep(
        OverlayWindowAttribute.minimumSize,
        () => windowManager.setMinimumSize(const Size(1, 1)),
      );
      await _applyOverlayStep(
        OverlayWindowAttribute.size,
        () => windowManager.setSize(Size(spec.width, spec.height)),
      );
      await _applyOverlayStep(
        OverlayWindowAttribute.resizable,
        () => windowManager.setResizable(spec.resizable),
      );
      await _applyOverlayStep(
        OverlayWindowAttribute.alwaysOnTop,
        () => windowManager.setAlwaysOnTop(spec.alwaysOnTop),
      );
      await _applyOverlayStep(
        OverlayWindowAttribute.skipTaskbar,
        () => windowManager.setSkipTaskbar(spec.skipTaskbar),
      );

      // 定位到鼠标所在显示器（多屏场景），失败则居中。
      final geometry = await computeQuickCaptureGeometry(spec);
      await _applyOverlayStep(OverlayWindowAttribute.position, () async {
        if (geometry != null) {
          await windowManager.setPosition(Offset(geometry.x, geometry.y));
        } else {
          await windowManager.center();
        }
      });

      // show/focus 不需要还原旧值（见 OverlayWindowAttribute.visibility），
      // 但仍要记入 `_overlayApplied`，否则日志里的「已执行步骤」会漏掉它们。
      await _applyOverlayStep(OverlayWindowAttribute.visibility, () async {
        await windowManager.show();
        await windowManager.focus();
      });

      _overlayStep = null;
      SpbLog.info('进入悬浮输入窗模式', {
        'size': '${spec.width.toInt()}x${spec.height.toInt()}',
        'steps': _overlayApplied.map((a) => a.name).join(','),
      });
      return true;
    } catch (e, st) {
      // ## 为什么必须回滚（而不是只清快照）
      //
      // 只清快照会让已生效的改动**残留**：窗口已是 720×360、置顶、且从任务栏
      // 消失，而 `isOverlayModeActive == false` 又让所有 `exitOverlayMode()`
      // 变成空操作（它开头就 `if (bounds == null) return`）。用户看到的就是
      // 「一个卡住的小窗，然后应用像是退出了」——而进程还活着。
      final failedStep = _overlayStep?.name ?? 'snapshot';
      SpbLog.warn('进入悬浮输入窗模式失败，开始回滚', {
        'failed_step': failedStep,
        'applied': _overlayApplied.map((a) => a.name).join(','),
      });
      await _rollbackOverlay();
      SpbLog.error(
        '进入悬浮输入窗模式失败（已尝试回滚窗口属性）',
        error: e,
        stackTrace: st,
        fields: {
          'failed_step': failedStep,
          'size': '${spec.width.toInt()}x${spec.height.toInt()}',
        },
      );
      return false;
    }
  }

  /// 执行一步改写并记账。抛异常时该步**不会**进入 [_overlayApplied]
  /// （它没成功，不该被回滚），但 [_overlayStep] 会留下失败步名。
  ///
  /// ## 为什么每步都记 info
  ///
  /// 2026-11 Windows 实测：按 Alt+Space 后窗口变小、随后进程直接死亡，
  /// 日志终止在「全局快捷键触发」——原生层崩溃不会走 Dart 的 catch，
  /// §6.57 的回滚 + error 日志完全不可见。逐步日志把「最后一步是什么」
  /// 直接写进文件日志：下一步复现时，日志的最后一行就是原生崩溃点
  /// （与 Windows 事件查看器的故障模块交叉验证）。每步一行、每轮最多
  /// 7 行，低频操作不会刷屏——与「快捷键触发」升 info 的同一取向
  /// （§6.43：门控/触发类日志用 debug 等于没写）。
  Future<void> _applyOverlayStep(
    OverlayWindowAttribute attribute,
    Future<void> Function() op,
  ) async {
    _overlayStep = attribute;
    SpbLog.info('悬浮窗属性改写步骤', {'step': attribute.name});
    await op();
    _overlayApplied.add(attribute);
  }

  /// 按 [overlayRollbackOrder] 逆序尽力回滚。
  ///
  /// ## 为什么「尽力」而不是「失败就抛」
  ///
  /// 回滚发生在**已经出错**的路径上：抛出只会把「窗口没回滚」变成「连原异常
  /// 都丢了」。逐步 try/catch + 汇总记录，保证「能回滚的都回滚了」，且日志里
  /// 留下**具体哪一步没回滚**（用户报障时这是关键线索）。
  Future<void> _rollbackOverlay() async {
    final bounds = _preOverlayBounds;
    final plan = overlayRollbackOrder(_overlayApplied);
    final failed = <String>[];

    for (final attribute in plan) {
      try {
        switch (attribute) {
          case OverlayWindowAttribute.minimumSize:
            await windowManager.setMinimumSize(
              Size(WindowSpec.main.minWidth, WindowSpec.main.minHeight),
            );
          case OverlayWindowAttribute.size:
            // 没有快照就无法还原尺寸：此时窗口可能仍是悬浮尺寸，但至少
            // 置顶/任务栏属性会被后面的步骤还原（下面还会 show + focus）。
            if (bounds != null) {
              await windowManager.setSize(Size(bounds.width, bounds.height));
            }
          case OverlayWindowAttribute.resizable:
            await windowManager.setResizable(_preOverlayResizable);
          case OverlayWindowAttribute.alwaysOnTop:
            await windowManager.setAlwaysOnTop(_preOverlayAlwaysOnTop);
          case OverlayWindowAttribute.skipTaskbar:
            await windowManager.setSkipTaskbar(_preOverlaySkipTaskbar);
          case OverlayWindowAttribute.position:
            if (bounds != null) {
              await windowManager.setPosition(Offset(bounds.x, bounds.y));
            }
          case OverlayWindowAttribute.visibility:
            // overlayRollbackOrder 已剔除；分支保留仅为穷尽 switch。
            break;
        }
      } catch (e, st) {
        failed.add(attribute.name);
        SpbLog.error(
          '回滚悬浮窗属性失败',
          error: e,
          stackTrace: st,
          fields: {'attribute': attribute.name},
        );
      }
    }

    // 回滚后无条件显示一次：失败路径上窗口可能停在「已隐藏 / 无任务栏图标」
    // 的状态，而那是用户**唯一**能找回应用的入口。
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      SpbLog.warn('回滚后显示窗口失败', {'error': '$e'});
    }

    _overlayApplied.clear();
    _overlayStep = null;
    _preOverlayBounds = null;
    _overlayFitHeight = null;

    if (failed.isEmpty) {
      SpbLog.info('悬浮窗属性已回滚', {'steps': plan.map((a) => a.name).join(',')});
    } else {
      SpbLog.error(
        '悬浮窗属性回滚不完整',
        fields: {
          'failed': failed.join(','),
          'rolled_back': plan.length - failed.length,
        },
      );
    }
  }

  @override
  bool get isOverlayModeActive => _preOverlayBounds != null;

  @override
  Future<void> fitOverlayContentHeight(double contentHeight) async {
    // 不在悬浮模式（平台不支持形态切换、或只做了导航）：窗口属于主界面，
    // 不能按悬浮输入框的内容去改大小。
    if (_preOverlayBounds == null) return;

    try {
      final (chrome, currentSize) = await _measureWindowChrome();
      final target = fitOverlayWindowHeight(contentHeight + chrome);

      // 去重：页面每次内容尺寸变化都会上报，重复 setSize 会让窗口抖动；
      // 当前高度已经等于目标值时也不必再走一次平台通道。
      final fit = _overlayFitHeight;
      if (fit != null && (fit - target).abs() < 1) return;
      _overlayFitHeight = target;
      if ((currentSize.height - target).abs() < 1) return;

      await windowManager.setSize(Size(currentSize.width, target));
      SpbLog.debug('悬浮窗高度贴合内容', {
        'content': contentHeight.toStringAsFixed(1),
        'chrome': chrome.toStringAsFixed(1),
        'height': target.toStringAsFixed(1),
      });
    } catch (e) {
      // 贴合失败只影响观感（窗口比内容高或矮），不阻断输入与提交——
      // 这正是它能与「进入悬浮模式」分开、不进回滚事务的原因。
      SpbLog.warn('悬浮窗高度贴合失败', {'error': '$e'});
    }
  }

  /// 实测「窗口外框比内容区多出来的高度」与当前窗口尺寸（逻辑像素）。
  ///
  /// ## 为什么用「窗口高 − Flutter 视图高」而不是读平台 API
  ///
  /// `window_manager` 没有暴露「客户区 / 外框」的区分（`getSize` 在两个平台上
  /// 分别返回 client area 与外框），故用同一时刻的两个可观测量相减：
  /// `windowManager.getSize()`（平台相关）与 Flutter 视图的逻辑高度（永远是
  /// 客户区）。Linux 上两者相等，差为 0；Windows 上差就是标题栏 + 边框。
  ///
  /// 取不到合理值时退回 `(0, 当前尺寸)`：贴合结果偏矮一个标题栏高度，
  /// 下一次内容变化会自我纠正（比抛异常、或把窗口改到异常尺寸都好）。
  Future<(double chrome, Size windowSize)> _measureWindowChrome() async {
    final size = await windowManager.getSize();
    final cached = _windowChromeHeight;
    if (cached != null) return (cached, size);

    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return (0.0, size);
    final view = views.first;
    final ratio = view.devicePixelRatio;
    if (!ratio.isFinite || ratio <= 0) return (0.0, size);
    final contentHeight = view.physicalSize.height / ratio;
    if (!contentHeight.isFinite || contentHeight <= 0) return (0.0, size);

    final chrome = size.height - contentHeight;
    // 上限 200：超过它说明两个量根本不是同一个窗口（例如窗口尚未布局
    // 完成时的陈旧视图尺寸），此时按「无外框」处理且不缓存，下次重测。
    if (!chrome.isFinite || chrome < 0 || chrome > 200) return (0.0, size);

    // 0 也要缓存：Linux 上「无外框」是常态，不缓存就每次上报都多一次
    // 视图测量。
    _windowChromeHeight = chrome;
    return (chrome, size);
  }

  @override
  Future<void> exitOverlayMode() async {
    final bounds = _preOverlayBounds;
    if (bounds == null) return; // 未进入过：空操作（可能被重复调用）。

    _preOverlayBounds = null;
    _overlayApplied.clear();
    _overlayStep = null;
    _overlayFitHeight = null;
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
    } catch (e, st) {
      // 用 error 级 + 带栈：还原失败意味着窗口会**停在悬浮形态**（小窗、
      // 置顶、不在任务栏），是用户可见故障，且它发生在一次正常操作后
      // ——不该埋在一条 warn 里。
      SpbLog.error('退出悬浮输入窗模式失败', error: e, stackTrace: st);
      // 尽力把窗口显示出来：哪怕尺寸不对，用户至少能看见它。
      try {
        await windowManager.show();
      } catch (_) {
        // 不掩盖上面的根因（已在上一条 error 日志里）。
      }
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
    // 会话正常退出标记：**必须在这次会话的所有业务日志之后**。下次启动时
    // `previousSessionExitedCleanly` 从末尾往前找边界标记，故它之后若还有
    // debug 级收尾日志（如 `dispose()` 里的托盘销毁失败）不影响判定，但
    // **不得**再写 info 及以上的业务日志——那会让「退出」看起来像中途。
    // 详见 logSessionCleanExitMessage 的文档。
    SpbLog.info(logSessionCleanExitMessage);
    await dispose();
    // ## 为什么退出前必须关掉 preventClose（macOS 上不关就退不出去）
    //
    // 「关窗即隐藏」靠 `preventClose = true` 拦截关闭（见 `setHideOnClose`）。
    // 而 macOS 的 `destroy()` 实现是 `NSApp.terminate(nil)`——AppKit 在终止
    // 序列里会逐个窗口问 `windowShouldClose:`，**任何一个返回 NO 就取消终止**。
    // 不先关掉它就是「点了退出，应用毫无反应」。
    //
    // Windows（`PostQuitMessage`）与 Linux（`gtk_window_close` 前自己把
    // `_is_prevent_close` 置 false）不受影响，但统一在这里做：三个平台同一条
    // 退出路径，不留「只在某个平台上需要记得」的分叉。
    //
    // 失败不拦退出：最坏情况是 macOS 上取消一次终止，用户再点一次即可。
    try {
      await windowManager.setPreventClose(false);
    } catch (e) {
      SpbLog.warn('退出前关闭关窗拦截失败', {'error': '$e'});
    }
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
