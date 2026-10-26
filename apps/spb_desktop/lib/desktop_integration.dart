// Why 整文件忽略 prefer_initializing_formals：Dart 不允许私有**命名**参数
// （`this._capabilities` 会强制调用方写 `_capabilities:`，编译器直接拒绝），
// 故构造函数里只能用「公开参数名 + 显式赋值」，该 lint 在此是误报。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:go_router/go_router.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

import 'router.dart';

/// 托盘菜单项 id。
///
/// ## 为什么集中定义
///
/// 菜单项的 id 同时出现在三处：构建菜单、注册回调、以及可能的「更新勾选状态」。
/// 散落的字符串字面量一旦拼错，表现是「点了没反应」——不会有任何报错。
class TrayActionIds {
  const TrayActionIds._();

  static const show = 'tray.show';
  static const quickCapture = 'tray.quickCapture';

  /// 立即跑一轮交付物同步。
  static const syncNow = 'tray.syncNow';

  /// 在文件管理器里打开当前同步目录。
  static const openSyncDir = 'tray.openSyncDir';

  /// 跳到同步设置页（选目录 / 范围 / 媒体开关）。
  static const syncSettings = 'tray.syncSettings';

  /// 跳到**全局设置页**（`/settings`：同步目录 / 范围 / 过滤 / 外观 /
  /// 个人偏好 / 导出诊断日志）。
  ///
  /// 与 [syncSettings] 是**两个不同目标**：后者直达 `/settings/sync`
  /// （高频的「跑一轮同步」），前者是配置入口。桌面端此前只有后者，
  /// 于是 `/settings` 在界面上不可达（见 AGENTS.md §6.11）。
  static const settings = 'tray.settings';

  static const quit = 'tray.quit';
}

/// 把桌面能力接到路由与托盘上。
///
/// ## 为什么需要这一层
///
/// `PlatformDesktopCapabilities` 位于 `apps/`，但它**不知道 go_router 的存在**
/// ——这是有意的分层：窗口能力不应依赖路由实现。它通过 [onShowWindow] 回调把
/// 「要显示哪个角色的窗口」抛给上层，由本文件接到导航上。
///
/// ## 单窗口模型下的映射
///
/// 见 `bootstrap.dart` 的类文档：`window_manager` 无法创建窗口，故
/// `settings` / `quickCapture` 是主窗口内的**路由页面**而非独立窗口。
/// 「显示设置窗」= 导航到 `/settings`。
///
/// ## 为什么不是 Provider
///
/// 本类有副作用（设置回调、推送托盘菜单），且生命周期与 `GoRouter` 绑定。
/// 用 Provider 会让「谁负责 dispose」变模糊（托盘监听器需要摘除）。
/// 由 [SpbDesktopApp] 持有并显式 [detach] 更清晰。
class DesktopIntegration {
  DesktopIntegration({
    required DesktopCapabilities capabilities,
    required GoRouter router,
    this.onSyncNow,
    this.onOpenSyncDirectory,
    this.isSyncConfigured,
  }) : _capabilities = capabilities,
       _router = router;

  final DesktopCapabilities _capabilities;
  final GoRouter _router;

  /// 托盘「立即同步交付物」的动作。null 时该项 `enabled: false`。
  final Future<void> Function()? onSyncNow;

  /// 托盘「打开同步目录」的动作（通常是 `revealPath`）。null 时该项禁用。
  final Future<void> Function()? onOpenSyncDirectory;

  /// 是否已配置同步目录。
  ///
  /// ## 为什么是回调而不是构造时的布尔快照
  ///
  /// 目录可以在设置页随时被改（或首次配置）。若构造时取一次快照，
  /// 应用启动时未配置 → 之后配好了，「打开同步目录」仍会永久禁用，
  /// 直到重启。回调在**推送菜单时**取值，与
  /// `TrayTooltipController.syncConfigured` 同一取向。
  ///
  /// ⚠️ 它只在 [_installTrayMenu] 时被调用一次。菜单推送之后目录再变，
  /// 需要重新推送菜单才能反映（本类不主动监听——那属于同步状态广播的
  /// 职责，见 `app.dart` 的托盘提示接线）。
  final bool Function()? isSyncConfigured;

  bool _attached = false;

  /// 是否已成功接线（能收到窗口/托盘事件）。
  ///
  /// 测试用：验证「Noop 能力下不会接线」这类行为。
  bool get isAttached => _attached;

  /// 接入回调与托盘菜单。幂等（重复调用只生效一次）。
  ///
  /// ## 为什么是 `attach` 而不是构造函数里做
  ///
  /// 构造函数里做副作用会让「创建对象」和「产生副作用」绑死——测试无法
  /// 只创建对象而不动全局状态。显式 `attach` 让调用点清楚知道「这里开始
  /// 接管平台事件」。
  void attach() {
    if (_attached) return;

    final caps = _capabilities;
    // ## 为什么按**接口**判能力而不是按具体类
    //
    // 真实实现（`PlatformDesktopCapabilities`）与测试桩都能实现这两个接口，
    // 故测试可以验证接线逻辑本身（导航映射、托盘菜单内容），而不必启动真实的
    // window_manager。按具体类判（`caps is PlatformDesktopCapabilities`）会让
    // 这段逻辑只能在真机上验证。
    if (caps is! WindowDisplayTarget || caps is! TrayActionTarget) {
      SpbLog.debug('桌面能力不支持接线，跳过路由/托盘', {'type': caps.runtimeType.toString()});
      return;
    }

    // ## 为什么要分开提升成局部变量
    //
    // Dart 的类型提升无法穿透 `is! A || is! B`——`caps` 在条件成立后被提升为
    // `A & B`（交集类型），但**在方法体内不可用**（语言限制，见
    // dart-lang/language#2136）。用两个局部变量分别接住，后续调用才有静态类型。
    final display = caps as WindowDisplayTarget;
    final tray = caps as TrayActionTarget;

    _attached = true;
    display.onShowWindow = _navigateToRole;
    display.onHideWindow = _onHideWindow;

    _installTrayMenu(tray, caps);
  }

  /// 把「显示某角色的窗口」映射成路由导航。
  ///
  /// ## 悬浮窗为什么不能只导航
  ///
  /// `alwaysOnTop` 是**窗口级**属性，只改路由拿不到置顶效果——用户打完字抬头
  /// 一看，窗口被别的程序遮住了。故显示悬浮窗要额外把窗口切成悬浮形态
  /// （见 [OverlayWindowController]）。设置窗没有这个需求（它就是普通页面）。
  Future<void> _navigateToRole(WindowRole role) async {
    final target = switch (role) {
      WindowRole.main => SpbRoutes.home,
      WindowRole.settings => SpbRoutes.settings,
      WindowRole.quickCapture => SpbRoutes.overlay,
    };

    // 已在目标路由时跳过：`go` 到同一路径会重建页面，清掉用户正在编辑的
    // 表单草稿（悬浮窗里正打了一半的字会消失）。
    if (_router.state.uri.path == target) {
      SpbLog.debug('已在目标路由，跳过导航', {'path': target});
      return;
    }

    // 切换前先处理窗口形态：进入悬浮模式要在**导航前**完成，否则会先看到
    // 全尺寸的主窗口闪一下再缩成悬浮窗。
    if (role == WindowRole.quickCapture) {
      await _enterOverlayWindow();
    } else {
      // 从悬浮窗切到其他页面：还原窗口（否则设置页会挤在 720×360 里）。
      // 未处于悬浮模式时是空操作。
      await _exitOverlayWindow();
    }

    SpbLog.debug('桌面能力触发导航', {'role': role.name, 'path': target});
    _router.go(target);
  }

  /// 取悬浮窗形态控制器（不支持时为 null）。
  ///
  /// ## 为什么不缓存成字段
  ///
  /// 本类可能被长期持有（应用生命周期），而能力实现在测试里会被替换。
  /// 每次从 `_capabilities` 取，保证与当前实现一致。
  OverlayWindowController? get _overlay {
    final caps = _capabilities;
    // 显式 cast：Dart 的类型提升对**独立接口**不生效（`OverlayWindowController`
    // 不是 `DesktopCapabilities` 的子类型，即使实现类同时 implements 两者）。
    return caps is OverlayWindowController
        ? caps as OverlayWindowController
        : null;
  }

  Future<void> _enterOverlayWindow() async {
    final overlay = _overlay;
    if (overlay == null) {
      // 平台不支持窗口形态切换（移动端/测试桩）：退化为「只是导航」。
      SpbLog.debug('平台不支持悬浮窗形态切换，仅导航');
      return;
    }
    // 幂等判断交给实现方（它有唯一真相，见 isOverlayModeActive 的文档）。
    if (overlay.isOverlayModeActive) return;

    final ok = await overlay.enterOverlayMode(
      WindowSpec.quickCaptureWithAttachments,
    );
    if (!ok) SpbLog.warn('悬浮窗形态切换失败，窗口可能未置顶');
  }

  Future<void> _exitOverlayWindow() async {
    final overlay = _overlay;
    if (overlay == null || !overlay.isOverlayModeActive) return;
    await overlay.exitOverlayMode();
  }

  /// 退出悬浮模式（供悬浮窗页面在提交/取消时调用）。
  ///
  /// ## 为什么页面要显式调它
  ///
  /// `Esc` 清空后关窗、提交成功后关窗——这两条路径都**不经过**
  /// `showWindow`，故不会被 [_navigateToRole] 自动还原。若不显式调用，
  /// 窗口会一直保持 720×360 置顶，用户回到主界面后窗口再也放不大。
  Future<void> leaveOverlay() => _exitOverlayWindow();

  /// 隐藏某角色的「窗口」。
  ///
  /// 单窗口下，隐藏覆盖式页面（设置/悬浮窗）= 回到主界面。
  /// 主窗口本身不隐藏——那会让应用看起来退出了。
  Future<void> _onHideWindow(WindowRole role) async {
    if (role == WindowRole.main) return;
    // ## 为什么必须还原窗口
    //
    // 隐藏悬浮窗若只导航回主界面，窗口会**保持** 720×360 置顶——用户看到的
    // 是主界面挤在一个小置顶窗里，且再也放不大（除非重启）。
    // 这条路径与 `leaveOverlay` 是两回事，别漏。
    await _exitOverlayWindow();
    if (_router.state.uri.path == SpbRoutes.home) return;
    _router.go(SpbRoutes.home);
  }

  /// 安装托盘菜单。
  ///
  /// [tray] 是接线点（推送菜单、注册回调），[caps] 用于窗口显示与退出
  /// ——它们是不同的接口，故分开传。
  ///
  /// ## 顺序要求
  ///
  /// 必须先 `setTrayMenu` 再 `registerTrayAction`：前者会清空回调表
  /// （菜单整体替换，旧 id 失效），见 `registerTrayAction` 的文档。
  void _installTrayMenu(TrayActionTarget tray, DesktopCapabilities caps) {
    // 同步相关三项的可用性。
    //
    // ## 为什么用 `enabled: false` 而不是「不渲染」或「点了没反应」
    //
    // 不渲染会让菜单项随配置变化而出现/消失，用户找不到它去哪了；而「点了
    // 没反应」是最差的一种——用户会反复点、以为应用卡死。置灰是唯一能同时
    // 表达「这里有这个功能」与「现在还不能用」的形态。
    final syncReady = isSyncConfigured?.call() ?? false;

    final items = [
      const TrayMenuItem(id: TrayActionIds.show, label: '显示主窗口'),
      const TrayMenuItem(
        id: TrayActionIds.quickCapture,
        label: '快速输入（Alt+Space）',
      ),
      TrayMenuItem.separator(),
      // 同步三项：这是原 Tauri 薄壳的托盘能力（迁移时漏掉的部分）。
      // 独立成组是因为它们作用于「交付物同步」这个子系统，与上面的窗口
      // 动作不同类；退出单独一组（避免误点）。
      TrayMenuItem(
        id: TrayActionIds.syncNow,
        label: '立即同步交付物',
        enabled: onSyncNow != null,
      ),
      TrayMenuItem(
        id: TrayActionIds.openSyncDir,
        label: '打开同步目录',
        // 未配置目录时禁用：此时 `revealPath` 拿到的是空串，打开文件管理器
        // 会落到用户主目录——看起来像「功能坏了」，而不是「还没配」。
        enabled: onOpenSyncDirectory != null && syncReady,
      ),
      // 「同步设置…」始终可用：它正是**配置入口**，禁用会让未配置的用户
      // 无法完成配置（死锁）。
      const TrayMenuItem(id: TrayActionIds.syncSettings, label: '同步设置…'),
      // 全局设置（`/settings`）：与上面那项是**不同目标**，不是重复。
      // 上面只到 `/settings/sync`（跑一轮同步 + 目录），而同步目录 / 范围 /
      // 过滤 / 外观 / 个人偏好 / 导出诊断日志都在 `/settings` 首页。
      //
      // 同样**始终可用**：理由同上（它是配置入口）。
      const TrayMenuItem(id: TrayActionIds.settings, label: '设置…'),
      TrayMenuItem.separator(),
      const TrayMenuItem(id: TrayActionIds.quit, label: '退出'),
    ];

    // 不 await：托盘推送失败已在能力层内部降级（记日志），
    // 启动流程不应因托盘卡住。
    unawaited(tray.setTrayMenu(items));

    tray.registerTrayAction(TrayActionIds.show, () {
      caps.showWindow(WindowRole.main);
    });
    tray.registerTrayAction(TrayActionIds.quickCapture, () {
      caps.showWindow(WindowRole.quickCapture);
    });
    tray.registerTrayAction(TrayActionIds.syncNow, () {
      // 未注入时菜单项已置灰，正常点不到；这里再判一次是防御——托盘实现
      // 对 `enabled` 的处理不完全一致（某些 Linux 托盘忽略该字段）。
      final action = onSyncNow;
      if (action == null) {
        SpbLog.warn('托盘「立即同步」未注入回调，忽略本次点击');
        return;
      }
      // 不 await：同步可能跑很久，托盘回调必须立刻返回（否则托盘线程被占）。
      // 失败已在动作内部处理（`runSyncActionProvider` 自己记日志）。
      unawaited(action());
    });
    tray.registerTrayAction(TrayActionIds.openSyncDir, () {
      final action = onOpenSyncDirectory;
      if (action == null) {
        SpbLog.warn('托盘「打开同步目录」未注入回调，忽略本次点击');
        return;
      }
      unawaited(action());
    });
    tray.registerTrayAction(TrayActionIds.syncSettings, () {
      // ## 为什么不走 `showWindow(WindowRole.settings)`
      //
      // `WindowRole` 只有 main / settings / quickCapture，没有 sync 这个角色
      // （同步设置是 `/settings/sync` 这个**子页面**，不是独立窗口）。用
      // `showWindow(settings)` 只会落到设置页的首个 tab，用户还得自己再点
      // 一次「同步」——托盘项的标签承诺的是直达。
      unawaited(_openSyncSettings());
    });
    tray.registerTrayAction(TrayActionIds.settings, () {
      // 全局设置页（`/settings`）。
      //
      // ## 为什么直接 `_router.go` 而不是 `caps.showWindow(WindowRole.settings)`
      //
      // `showWindow` 的语义是「显示窗口」——真实实现会先 `windowManager.show()`
      // + `focus()`，**并确保窗口已从托盘隐藏态回来**。但托盘菜单本身就是
      // 在应用可见时点的（窗口被隐藏到托盘时用户看不到菜单），而这里要的只是
      // 一次导航。
      //
      // 更关键的是**本类已持有 router**，且 `WindowRole.settings` 的映射也在本类
      // 里（`_navigateToRole`）——绕一圈回到自己的能力层只会让「从悬浮窗切到
      // 设置要还原窗口」这条逻辑依赖桩实现是否转发 `onShowWindow`（测试桩不转发，
      // 于是断言路由的用例会莫名其妙地红）。
      //
      // 还原窗口仍必须做：不还原的话设置页会挤在 720×360 的置顶窗里。
      unawaited(_openSettings());
    });
    tray.registerTrayAction(TrayActionIds.quit, () {
      // 退出需要先摘监听器、注销快捷键、销毁托盘图标，见
      // `PlatformDesktopQuit.quit` 的文档。
      // ## 为什么用显式 cast 而不是 `is` 提升
      //
      // Dart 的类型提升要求目标类型是**当前类型的子类型**。
      // `PlatformDesktopQuit` 与 `DesktopCapabilities` 是两个独立接口
      // （真实实现同时 implements 两者），故 `caps is PlatformDesktopQuit`
      // 不会把 `caps` 提升成可调用 `.quit()` 的类型。
      final quittable = caps is PlatformDesktopQuit
          ? caps as PlatformDesktopQuit
          : null;
      if (quittable == null) {
        SpbLog.warn('当前能力实现不支持 quit，托盘退出项无效');
        return;
      }
      unawaited(quittable.quit());
    });

    // ## 为什么「关窗即隐藏」要以托盘可用为前提
    //
    // 该行为的目的是让应用留在托盘继续跑同步。若托盘没起来（Linux 无
    // appindicator、Flatpak 沙箱等），关窗后用户**没有任何办法唤回应用**
    // ——进程还在，窗口没了。故托盘不可用时保持「关窗即退出」。
    tray.setHideOnClose(tray.trayAvailable);
  }

  /// 跳到同步设置页。
  ///
  /// ## 为什么必须先 `leaveOverlay()`
  ///
  /// 从悬浮窗（720×360 置顶）直接导航，设置页会挤在那个小窗里，且窗口仍是
  /// 置顶——用户既看不全也放不大。这与 [_navigateToRole] 里「非 quickCapture
  /// 角色先还原窗口」是同一件事，只是这条路径不经过那个方法（因为它的入参是
  /// `WindowRole`，而这里没有对应的角色）。
  Future<void> _openSyncSettings() async {
    await _exitOverlayWindow();

    // 已在同步设置页时不重复导航：`go` 到同一路径会重建页面，清掉用户正在
    // 编辑的表单草稿（与 [_navigateToRole] 的守卫同一理由）。
    if (_router.state.uri.path == SpbRoutes.sync) {
      SpbLog.debug('已在同步设置页，跳过导航');
      return;
    }

    SpbLog.debug('托盘触发导航', {'path': SpbRoutes.sync});
    _router.go(SpbRoutes.sync);
  }

  /// 托盘「设置…」：回到全局设置页（`/settings`）。
  ///
  /// 与 [_openSyncSettings] 是**两个不同目标**：后者直达 `/settings/sync`
  /// （跑一轮同步 + 目录），本方法回到 `/settings` 首页（范围 / 过滤 / 外观 /
  /// 个人偏好 / 导出诊断日志）。
  Future<void> _openSettings() async {
    await _exitOverlayWindow();

    if (_router.state.uri.path == SpbRoutes.settings) {
      SpbLog.debug('已在设置页，跳过导航');
      return;
    }

    SpbLog.debug('托盘触发导航', {'path': SpbRoutes.settings});
    _router.go(SpbRoutes.settings);
  }

  /// 摘除接线（应用退出时调用）。
  void detach() {
    if (!_attached) return;
    _attached = false;
    // 同 attach：显式 cast（提升对独立接口不生效）。
    final caps = _capabilities;
    if (caps is WindowDisplayTarget) {
      final display = caps as WindowDisplayTarget;
      display.onShowWindow = null;
      display.onHideWindow = null;
    }
  }
}
