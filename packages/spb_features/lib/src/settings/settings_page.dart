import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_design/spb_design.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_models/spb_models.dart';
import 'package:spb_platform/spb_platform.dart';
import 'package:spb_ui/spb_ui.dart';

import 'notification_subscriptions_card.dart';
import 'user_preferences_card.dart';

/// 弹出目录选择器。返回 null = 用户取消。
typedef PickSettingsDirectory = Future<String?> Function();

/// 导出诊断报告（issue #40）。
///
/// ## 为什么返回三态枚举而不是 `bool`
///
/// 见 `spb_platform` 的 `DiagnosticsExportOutcome`：页面需要对「已导出」与
/// 「用户取消」给**不同**的反馈（后者不弹任何提示），而「失败」要弹错误。
/// 用 `bool` 会把取消当失败，用户点一下取消就看到「导出失败」。
typedef ExportDiagnostics = Future<DiagnosticsExportOutcome> Function();

/// 读取主题模式偏好。
typedef LoadThemeMode = Future<ThemeMode> Function();

/// 保存主题模式偏好。
///
/// ## 为什么这个不是「整份提交」的 draft 的一部分
///
/// 主题是**即时反馈**项：用户点了「深色」就该立刻变深色。若并进 draft，
/// 用户得再点一次「保存」才生效——而那时他已经在看着浅色界面确认「没生效」。
/// 故本项独立注入、选中即保存（与通知订阅额度同一取舍）。
typedef SaveThemeMode = Future<void> Function(ThemeMode mode);

/// 读取已保存的同步设置。
typedef LoadSyncSettings = Future<SyncSettings> Function();

/// 保存同步设置（**一次性提交全部字段**）。
///
/// ## 为什么是「整份提交」而不是「逐字段 setter」
///
/// 「换目录必须重置同步状态」要求目录写入与状态清空**在同一事务**里完成。
/// 若暴露成 `setLocalRoot` / `setScope` / `setIncludeMedia` 三个 setter，调用方
/// 就得自己保证「先改目录再清状态」，而漏掉一步就会出现「目录已改、状态没清」
/// → 「换目录后同步显示成功，但新目录是空的」。
///
/// 收成一个入口后，事务边界由实现方（app 装配层）决定，页面无从破坏它。
typedef SaveSyncSettings = Future<void> Function(SyncSettings settings);

/// 读取可勾选的对话列表（同步范围用）。
typedef LoadSyncGroups = Future<List<ChatGroup>> Function();

/// 扫描本地同步目录（清理与统计用）。
typedef ScanLocalGroups = Future<List<LocalGroupStats>> Function();

/// 执行清理计划。
typedef ExecutePrune = Future<PruneOutcome> Function(PrunePlan plan);

/// 「桌面集成」区块的展示信息（纯数据）。
///
/// ## 为什么是值对象而不是平台能力接口
///
/// 设置页只需要两件事：是否展示该区块、快捷键文案是什么。若为此注入整个
/// `DesktopIntegrationInfo`，页面就与平台能力包（窗口 / 托盘 / 快捷键插件）
/// 绑在一起——移动端为了这一个布尔也不得不构造一个空能力对象，而页面
/// 本身其实对「怎么拿到这些值」毫无兴趣。
///
/// 换成值对象后，**判定留在装配层**（那里才真的持有能力实现），页面只渲染。
class DesktopIntegrationInfo {
  const DesktopIntegrationInfo({required this.visible, this.hotkeyLabel = ''});

  /// 是否展示「桌面集成」区块（移动端为 false）。
  final bool visible;

  /// 悬浮输入窗快捷键的人类可读文案。
  ///
  /// 由装配层传入绑定的 `label`——**不在页面里硬编码** `Alt+Space`，
  /// 改绑定时只需改一处。
  final String hotkeyLabel;

  /// 不展示（移动端 / 无桌面能力）。
  static const hidden = DesktopIntegrationInfo(visible: false);
}

/// 「全部删除」在清理策略对话框里的哨兵值。
///
/// 用哨兵而非第二个布尔变量：三个选项因此共用同一个 `RadioGroup<int>`，
/// 选中状态只有一处真源，不会出现「天数与全部同时选中」的矛盾态。
const int _pruneAllSentinel = -1;

/// 设置页。
///
/// ## 页面职责边界
///
/// - **只负责**渲染与表单交互：目录、范围、过滤、清理、本地统计；
/// - **不负责**持久化、网络、磁盘——全部由注入的回调完成。
///
/// 这一分工与 [LoginPage] / [SyncPage] 一致：页面因此可以在无数据库、无网络、
/// 无平台插件的 widget test 里完整验证。
///
/// ## 表单语义：改动先留在内存，保存才落盘
///
/// 用户可能连着改好几项（换目录 + 关媒体 + 调上限），期望它们**一起生效**。
/// 若每项即时落盘，用户改到一半退出就会留下混合状态（新目录 + 旧范围），
/// 而其中「目录」这一项还牵扯到状态重置事务。故本页维护一份 draft
/// （[_draft]），只有点「保存」才调 [saveSettings]。
///
/// 「选目录」按钮同样只回填 draft——用户可能选错了想换一个，那时不该已经
/// 把旧目录的状态清掉。
///
/// ## 桌面能力项的显示条件
///
/// 托盘 / 全局快捷键是桌面专属。移动端传 [DesktopIntegrationInfo.hidden]
/// （`visible == false`），此时**不展示**这些项——展示一堆点了没反应的
/// 开关比不展示更糟。快捷键文案由装配层放进 [DesktopIntegrationInfo.hotkeyLabel]，
/// 页面不硬编码 `Alt+Space`（改绑定时只需改一处）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.loadSettings,
    required this.saveSettings,
    required this.loadGroups,
    required this.scanGroups,
    required this.executePrune,
    required this.pickDirectory,
    this.desktopInfo = DesktopIntegrationInfo.hidden,
    this.onOpenSync,
    this.onSignOut,
    this.onOpenDirectory,
    this.onOpenMyTurns,
    this.loadLaunchAtStartup,
    this.setLaunchAtStartup,
    this.loadNotifications,
    this.saveNotifications,
    this.loadThemeMode,
    this.saveThemeMode,
    this.loadPreferences,
    this.savePreferences,
    this.preferenceAgentOptions = const [],
    this.preferenceFallbackDisplayName = '',
    this.onExportDiagnostics,
    this.showAutoSync = false,
    this.title = '设置',
  });

  final LoadSyncSettings loadSettings;
  final SaveSyncSettings saveSettings;
  final LoadSyncGroups loadGroups;
  final ScanLocalGroups scanGroups;
  final ExecutePrune executePrune;
  final PickSettingsDirectory pickDirectory;

  /// 在文件管理器中打开同步目录（桌面端）。null = 不展示入口（移动端无目录概念）。
  final Future<bool> Function(String path)? onOpenDirectory;

  /// 打开「我的最近轮次」。null = 不展示入口。
  ///
  /// ## 为什么放设置页而非对话列表 AppBar
  ///
  /// 对话列表 AppBar 已有 4 个图标（新建/待确认/搜索/工作台），再加会拥挤。
  /// 本项是低频的「回顾」动作，放设置页更合适。
  final VoidCallback? onOpenMyTurns;

  /// 桌面集成区块的展示信息（决定是否展示托盘/快捷键项）。
  ///
  /// 默认不展示：未显式注入时按移动端处理（与其余可选注入同一取向——
  /// 不展示比展示一个点了没反应的区块更安全）。
  final DesktopIntegrationInfo desktopInfo;

  /// 打开「交付物同步」页。
  ///
  /// 本页只做**配置**，真正跑同步的是独立的同步页（它有进度与结果展示，
  /// 而配置是低频动作、同步是高频动作，合在一页会让用户每次同步都要滚过
  /// 一堆表单）。null 表示不提供入口（该页面此时只能配置）。
  final VoidCallback? onOpenSync;

  /// 退出登录。
  ///
  /// ## 为什么必须带确认对话框
  ///
  /// 登出会清掉本地会话（`SessionManager.logout()` 删 token）。误触的代价不是
  /// 「再点一下回来」，而是**重走一遗 OIDC 登录**（开浏览器、过 SSO、等回跳），
  /// 而这个按钮又与一堆普通设置项同屏。故两段式确认。
  ///
  /// ## 为什么导航不在这里做
  ///
  /// 本页不持有路由（与 [onOpenSync] 一致）。且登出后的去向属应用级决策：
  /// 路由守卫会在 `authState` 变为未登录时自动重定向，注入方也可以显式
  /// `go(login)`——两种做法都在页面之外。
  ///
  /// 为 null 时不展示（保持「无认证」的用法，与其余可选注入一致）。
  final Future<void> Function()? onSignOut;

  /// 读取「开机自启」当前状态。
  ///
  /// 为 null 时**不展示**该项（移动端注入 null）。不用
  /// [DesktopIntegrationInfo.visible] 判断：平台能力实现上的
  /// `isLaunchAtStartupEnabled` 在移动端恒返回 false，那会让开关看起来
  /// 「已关闭」而实际点不动——展示一个骗人的开关比不展示更糟。
  final Future<bool> Function()? loadLaunchAtStartup;

  /// 设置「开机自启」。
  ///
  /// ## 为什么返回值是 void 而不是 bool
  ///
  /// 平台可能拒绝写入自启项（Flatpak 沙箱、只读的 autostart 目录）。
  /// 能力实现内部已降级为「记日志 + 不抛」，故这里无法如实回报成功与否。
  /// 页面采取的做法是：调用后**重新读取**真实状态，让开关回到平台的事实值
  /// ——比显示一个乐观的勾选更诚实。
  final Future<void> Function(bool enabled)? setLaunchAtStartup;

  /// 通知订阅额度的读取入口。为 null 时**不展示**该区块。
  ///
  /// ## 为什么与其余设置项不同，不放进 draft
  ///
  /// 额度是服务端账本（`miniapp_subscriptions` 表），没有「草稿」语义——
  /// 详见 [NotificationSubscriptionsCard] 的类文档。
  final LoadNotificationSubscriptions? loadNotifications;

  /// 通知订阅额度的保存入口。与 [loadNotifications] 成对注入。
  final SaveNotificationSubscriptions? saveNotifications;

  /// 读取主题模式。为 null 时**不展示**「外观」区块。
  final LoadThemeMode? loadThemeMode;

  /// 保存主题模式。与 [loadThemeMode] 成对注入。
  final SaveThemeMode? saveThemeMode;

  /// 用户偏好的读取入口。为 null 时**不展示**该区块。
  ///
  /// ## 为什么自管状态而不进 draft
  ///
  /// 服务端对用户偏好是**部分更新**语义，而本页的 draft 是整份提交；
  /// 并在一起会强迫调用方在一份不含这些字段的对象里表示它们。
  /// 详见 [UserPreferencesCard] 的类文档。
  final LoadUserPreferences? loadPreferences;

  /// 用户偏好的保存入口。与 [loadPreferences] 成对注入。
  final SaveUserPreferences? savePreferences;

  /// 「默认 Agent」下拉的可选项（装配层从 agent 列表映射）。
  ///
  /// 为空时下拉只有「自动」一项——不是错误，只是本端还没接 agent 列表。
  final List<PreferenceAgentOption> preferenceAgentOptions;

  /// 昵称未设置时的回落值（`users.name` → `email`），仅作输入框占位提示。
  final String preferenceFallbackDisplayName;

  /// 导出诊断报告（issue #40）。为 null 时**不展示**该入口。
  ///
  /// ## 为什么用「未注入即隐藏」而不是「按平台判定」
  ///
  /// 与 [onOpenDirectory] / [loadLaunchAtStartup] 同一约定：判定留在装配层
  /// （那里才真的持有平台能力），页面只渲染。移动端注入
  /// `NoopDesktopCapabilities`（`saveDiagnostics` 恒返回
  /// `unsupported`），所以两端 router 都可以传同一个装配函数——真到运行时
  /// 发现不支持时，装配函数返回 `unsupported`，页面据此不弹成功提示。
  ///
  /// 见 [ExportDiagnostics] 的说明。
  final ExportDiagnostics? onExportDiagnostics;

  /// 是否展示「自动同步」区块（启动时 / 周期）。
  ///
  /// ## 为什么必须由装配层显式打开，而不是「有 draft 字段就渲染」
  ///
  /// 自动同步的值虽然存在 [SyncSettings.auto] 里（随表单整份提交），但**排程
  /// 器只在桌面端装配**：移动端没有常驻进程，后台定时器在 Android/iOS 上
  /// 不可靠（系统会冻结/杀掉），排一个不会响的计时器等于骗用户。
  ///
  /// 按「不展示点了没反应的开关」的既有取向（见本类文档的「桌面能力项的
  /// 显示条件」），移动端传 `false`，该区块整段不渲染——而不是渲染成禁用
  /// 或渲染后静默不生效。
  ///
  /// 默认 `false`：未显式注入时按「本端没有排程器」处理。
  final bool showAutoSync;

  final String title;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 表单草稿（编辑中，未落盘）。
  SyncSettings? _draft;

  /// 已落盘的设置（用于判断「有未保存改动」）。
  SyncSettings? _saved;

  /// 可勾选的对话（懒加载：只有展开「勾选若干」时才拉）。
  List<ChatGroup>? _groups;
  bool _loadingGroups = false;
  String? _groupsError;

  /// 本地统计。
  LocalSyncStats? _stats;
  bool _loadingStats = false;

  bool _loading = true;
  bool _saving = false;
  bool _pruning = false;

  /// 正在登出（防重复提交）。
  bool _signingOut = false;

  /// 开机自启的当前状态。null = 尚未读到（或未接入）。
  bool? _launchAtStartup;

  /// 当前主题模式。null = 尚未读到（或未接入）。
  ///
  /// ## 为什么单独存一份而不直接读 provider
  ///
  /// 本页不依赖 Riverpod（是纯 `StatefulWidget`，全靠注入），故主题值也走
  /// 注入：读回来的值放这里供 RadioGroup 渲染，切换时调注入的保存回调。
  /// 应用层（`MaterialApp.router` 的 `themeMode`）由 provider 驱动，
  /// 本页只是它的一个编辑入口。
  ThemeMode? _themeMode;

  /// 自启开关是否在途（防重复切换 + 禁用控件）。
  bool _togglingLaunch = false;

  /// 诊断报告导出是否在途（防重复点击 + 禁用入口）。
  ///
  /// 保存对话框是**模态**的，用户点了之后界面不会立即回来；不置 busy 会让
  /// 用户以为没反应而再点一下，弹出第二个对话框。
  bool _exportingDiagnostics = false;

  String? _error;

  /// 「已保存」提示是否可见。
  bool _savedHint = false;

  /// 单文件上限输入框（MB）。用 TextEditingController 才能保留用户输入的
  /// 中间态（如清空后重新输入），而受控于 draft 会把它立刻改写掉。
  final _maxSizeController = TextEditingController();

  bool get _dirty {
    final d = _draft;
    final s = _saved;
    if (d == null || s == null) return false;
    return d != s;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _maxSizeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.loadSettings();
      if (!mounted) return;
      setState(() {
        _draft = settings;
        _saved = settings;
        _loading = false;
        _syncMaxSizeField(settings);
      });
      // 统计与对话列表是次要信息：不阻塞首屏（分别单独加载）。
      //
      // 显式 `unawaited`：这几条都是**有意**不等待的（等待会让首屏白等）。
      // 不写的话 `unawaited_futures` 会把它们与「忘了 await」混为一谈。
      unawaited(_loadStats());
      unawaited(_loadLaunchAtStartup());
      unawaited(_loadThemeMode());
      if (!settings.scope.allGroups) unawaited(_loadGroups());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取设置失败：$e';
      });
    }
  }

  void _syncMaxSizeField(SyncSettings s) {
    final mb = s.filter.maxFileSize ~/ (1024 * 1024);
    _maxSizeController.text = '$mb';
  }

  /// 读取主题模式。
  ///
  /// 与首屏设置分开放：它要走数据库（`PreferencesStore`），不该拖慢首屏。
  /// 读不到时保持 null → 区块渲染成「禁用」，而不是假装「跟随系统」
  /// ——后者会让用户以为当前就是跟随系统，而实际只是没读到。
  Future<void> _loadThemeMode() async {
    final loader = widget.loadThemeMode;
    if (loader == null) return;
    try {
      final mode = await loader();
      if (!mounted) return;
      setState(() => _themeMode = mode);
    } catch (e) {
      SpbLog.warn('读取主题模式失败', {'error': e.toString()});
    }
  }

  /// 切换主题模式：选中即保存（不走 draft，见 [SaveThemeMode] 的说明）。
  Future<void> _setThemeMode(ThemeMode mode) async {
    final saver = widget.saveThemeMode;
    if (saver == null || _themeMode == mode) return;
    final previous = _themeMode;
    // 乐观更新：主题是即时反馈项，等落盘再变会让用户觉得「点了没反应」。
    // 失败时回滚到 previous，避免界面显示的值与库里不一致。
    setState(() => _themeMode = mode);
    try {
      await saver(mode);
    } catch (e) {
      if (!mounted) return;
      setState(() => _themeMode = previous);
      SpbLog.warn('保存主题模式失败', {'error': e.toString()});
    }
  }

  /// 读取开机自启状态。
  ///
  /// 与首屏设置分开放：读它要走平台通道（可能因无 autostart 目录而慢或失败），
  /// 不该拖慢设置页的首次渲染。
  Future<void> _loadLaunchAtStartup() async {
    final loader = widget.loadLaunchAtStartup;
    if (loader == null) return;
    try {
      final enabled = await loader();
      if (!mounted) return;
      setState(() => _launchAtStartup = enabled);
    } catch (e) {
      // 读不到就不显示该项的确定值：保持 null（渲染为禁用 + 「读取中」），
      // 而不是假装「已关闭」——后者会让用户以为自启确实关着。
      SpbLog.warn('读取开机自启状态失败', {'error': e.toString()});
      if (!mounted) return;
      setState(() => _launchAtStartup = null);
    }
  }

  /// 切换开机自启。
  ///
  /// ## 为什么写完后要重新读一次
  ///
  /// 平台可能拒绝写入（Flatpak 沙箱、只读的 autostart 目录），而能力层的
  /// `setLaunchAtStartup` 内部降级为「记日志 + 不抛」，无法回报成功与否。
  /// 重读让开关回到**平台的事实值**：写失败时它会自己弹回去，用户立刻看到
  /// 「这个开关在这个环境下不生效」，而不是以为设置成功了。
  Future<void> _toggleLaunchAtStartup(bool enabled) async {
    final setter = widget.setLaunchAtStartup;
    if (setter == null || _togglingLaunch) return;

    setState(() => _togglingLaunch = true);
    try {
      await setter(enabled);
    } catch (e) {
      if (mounted) setState(() => _error = '设置开机自启失败：$e');
    }
    // 无论成功失败都重读：让 UI 反映平台事实，而不是我们的期望。
    await _loadLaunchAtStartup();
    if (!mounted) return;
    setState(() => _togglingLaunch = false);
  }

  /// 导出诊断报告（issue #40）。
  ///
  /// ## 三态反馈（不是「成功/失败」二元）
  ///
  /// - `saved`：弹「已导出」；
  /// - `cancelled`：**什么都不说**。用户自己点了取消，再弹一条提示是噪音；
  /// - `failed`：弹「导出失败」，让用户知道该重试或换目录；
  /// - `unsupported`：弹「本平台不支持」。
  ///
  /// ## 为什么不把「取消」也当成功
  ///
  /// 「已导出」是一条**事实断言**。用户取消后看到它，会以为文件已经写好了
  /// 而去磁盘里找——找不到才是真正的困惑。
  Future<void> _exportDiagnostics() async {
    final export = widget.onExportDiagnostics;
    if (export == null || _exportingDiagnostics) return;

    setState(() => _exportingDiagnostics = true);
    DiagnosticsExportOutcome outcome;
    try {
      outcome = await export();
    } on Object catch (e) {
      // 装配函数原则上不抛（能力层已静默降级），但日志/环境采集路径可能抛
      // （如平台常量读取失败）。页面在这里兜底，不让一个诊断功能把设置页
      // 搞崩。
      SpbLog.warn('导出诊断报告失败', {'error': '$e'});
      outcome = DiagnosticsExportOutcome.failed;
    }
    if (!mounted) return;
    setState(() => _exportingDiagnostics = false);

    final message = switch (outcome) {
      DiagnosticsExportOutcome.saved => '诊断报告已导出',
      DiagnosticsExportOutcome.cancelled => null,
      DiagnosticsExportOutcome.failed => '导出诊断报告失败，请重试',
      DiagnosticsExportOutcome.unsupported => '当前平台不支持导出诊断报告',
    };
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _loadGroups() async {
    if (_loadingGroups || _groups != null) return;
    setState(() {
      _loadingGroups = true;
      _groupsError = null;
    });
    try {
      final groups = await widget.loadGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loadingGroups = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingGroups = false;
        _groupsError = '读取对话列表失败：$e';
      });
    }
  }

  Future<void> _loadStats() async {
    final root = _draft?.localRoot;
    if (root == null || root.trim().isEmpty) {
      setState(() => _stats = LocalSyncStats.empty);
      return;
    }
    setState(() => _loadingStats = true);
    try {
      final groups = await widget.scanGroups();
      if (!mounted) return;
      setState(() {
        _stats = groups.isEmpty
            ? LocalSyncStats.empty
            : LocalSyncStats(
                groupCount: groups.length,
                fileCount: groups.fold(0, (s, g) => s + g.fileCount),
                totalBytes: groups.fold(0, (s, g) => s + g.totalBytes),
              );
        _loadingStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      SpbLog.warn('统计本地同步目录失败', {'error': e.toString()});
      setState(() {
        _stats = LocalSyncStats.empty;
        _loadingStats = false;
      });
    }
  }

  /// 选择目录：**只回填 draft**，不落盘、不动同步状态。
  Future<void> _pickDirectory() async {
    final draft = _draft;
    if (draft == null) return;

    String? picked;
    try {
      picked = await widget.pickDirectory();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法打开目录选择器：$e');
      return;
    }
    if (!mounted) return;
    // null = 用户取消：保持原目录不变（同 SyncPage 的语义）。
    if (picked == null) return;

    setState(() {
      _draft = draft.copyWith(localRoot: picked);
      _savedHint = false;
      // 目录变了 → 旧统计描述的是旧目录，清掉等保存后重算。
      _stats = null;
    });
  }

  void _setScopeAll(bool all) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = draft.copyWith(scope: draft.scope.copyWith(allGroups: all));
      _savedHint = false;
    });
    // 展开勾选列表时才拉对话（避免默认「全部」也白拉一页）。
    if (!all) _loadGroups();
  }

  void _toggleGroup(String groupId, bool selected) {
    final draft = _draft;
    if (draft == null) return;
    final ids = List<String>.of(draft.scope.groupIds);
    if (selected) {
      ids.add(groupId);
    } else {
      ids.remove(groupId);
    }
    setState(() {
      _draft = draft.copyWith(scope: draft.scope.copyWith(groupIds: ids));
      _savedHint = false;
    });
  }

  void _setIncludeMedia(bool value) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = draft.copyWith(
        filter: draft.filter.copyWith(includeMedia: value),
      );
      _savedHint = false;
    });
  }

  void _setMaxSizeFromField(String raw) {
    final draft = _draft;
    if (draft == null) return;
    final mb = int.tryParse(raw.trim());
    // 空/非法输入：不改 draft（保存时会由 [_commitMaxSize] 用原值兜底），
    // 也不报错——用户还在输入中。
    if (mb == null || mb < 0) return;
    setState(() {
      _draft = draft.copyWith(
        filter: draft.filter.copyWith(maxFileSize: mb * 1024 * 1024),
      );
      _savedHint = false;
    });
  }

  void _setSinceDays(int? days) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = draft.copyWith(sinceDays: days, clearSinceDays: days == null);
      _savedHint = false;
    });
  }

  void _setAutoGroupOpen(bool value) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = draft.copyWith(auto: draft.auto.copyWith(onGroupOpen: value));
      _savedHint = false;
    });
  }

  void _setAutoOnLaunch(bool value) {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = draft.copyWith(auto: draft.auto.copyWith(onLaunch: value));
      _savedHint = false;
    });
  }

  void _setAutoInterval(int? minutes) {
    final draft = _draft;
    if (draft == null || minutes == null) return;
    setState(() {
      _draft = draft.copyWith(
        auto: draft.auto.copyWith(intervalMinutes: minutes),
      );
      _savedHint = false;
    });
  }

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving) return;

    setState(() {
      _saving = true;
      _error = null;
      _savedHint = false;
    });

    try {
      await widget.saveSettings(draft);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = draft;
        _savedHint = true;
      });
      // 保存后重算统计：目录可能变了（旧统计已失效）。
      unawaited(_loadStats());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  /// 清理本地目录：选策略 → 预览计划 → 确认 → 执行。
  Future<void> _prune() async {
    final draft = _draft;
    if (draft == null || _pruning) return;
    if (!draft.hasLocalRoot) {
      setState(() => _error = '请先选择同步目录');
      return;
    }

    final policy = await _askPrunePolicy();
    if (policy == null || !mounted) return; // 用户取消

    setState(() => _error = null);

    // ## 为什么「扫描 + 预览 + 确认」期间**不**显示进度
    //
    // 这段是同步的（扫描本地目录 + 纯函数算计划），耗时在毫秒级；而确认对话框
    // 会一直等着用户点，此时转圈既没有信息量，又会让界面看起来「还在忙」。
    // 进度只应该覆盖**真正在执行删除**的那一段。
    try {
      final groups = await widget.scanGroups();
      if (!mounted) return;

      // 计划是纯函数（domain），页面直接算——它只做「哪些有资格删」的规则，
      // 不碰磁盘。
      final plan = buildPrunePlan(groups: groups, policy: policy);
      if (!mounted) return;

      if (plan.isEmpty) {
        setState(() => _error = '没有符合条件的历史数据需要清理');
        return;
      }

      // 删除前必须确认，且文案含具体数量与体积。
      final confirmed = await _confirmPrune(plan);
      if (!mounted || confirmed != true) return;

      setState(() => _pruning = true);
      final outcome = await widget.executePrune(plan);
      if (!mounted) return;
      setState(() {
        _pruning = false;
        if (outcome.hasFailures) {
          final first = outcome.failed.entries.first;
          _error =
              '清理完成：删除 ${outcome.deleted} 个，'
              '${outcome.failed.length} 个失败（${first.key}：${first.value}）';
        } else {
          _savedHint = true;
        }
      });
      unawaited(_loadStats());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pruning = false;
        _error = '清理失败：$e';
      });
    }
  }

  /// 询问清理策略。
  ///
  /// ## 为什么用一个 [RadioGroup] 而不是三个 `groupValue`
  ///
  /// `RadioListTile.groupValue` / `onChanged` 在 Flutter 3.32 起已弃用，改由
  /// 祖先 [RadioGroup] 统一持有选中值与回调。用弃用 API 会留下 analyzer 噪音，
  /// 且未来版本会移除。
  ///
  /// 「全部删除」用哨兵值 [_pruneAllSentinel] 表达，这样三个选项共用一个
  /// `RadioGroup<int>`（而不是「天数」与「全部」两个不同类型的选择）。
  Future<PrunePolicy?> _askPrunePolicy() {
    var choice = 30;
    return showDialog<PrunePolicy>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('清理本地文件'),
          content: RadioGroup<int>(
            groupValue: choice,
            onChanged: (v) => setDialogState(() => choice = v ?? 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const RadioListTile<int>(
                  key: ValueKey('settings-prune-7d'),
                  value: 7,
                  title: Text('删除超过 7 天未更新的对话目录'),
                ),
                const RadioListTile<int>(
                  key: ValueKey('settings-prune-30d'),
                  value: 30,
                  title: Text('删除超过 30 天未更新的对话目录'),
                ),
                const RadioListTile<int>(
                  key: ValueKey('settings-prune-all'),
                  value: _pruneAllSentinel,
                  title: Text('全部删除'),
                ),
                const SizedBox(height: SpbSpacing.sm),
                Text(
                  '只清理 group_id 形状的目录，你自己的文件不会被删除。'
                  '云端副本不受影响，清理后可用「立即同步」重新拉取。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('settings-prune-next'),
              onPressed: () => Navigator.of(context).pop(
                // days = 0 是**显式「全部可删」**语义（见 PruneOlderThanDays）。
                PruneOlderThanDays(
                  days: choice == _pruneAllSentinel ? 0 : choice,
                  nowUnix: nowUnix(),
                ),
              ),
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmPrune(PrunePlan plan) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认清理'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(plan.summarize()),
          const SizedBox(height: SpbSpacing.sm),
          Text(
            '此操作不可撤销（云端副本仍在）。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('settings-prune-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );

  /// 退出登录（两段式：先确认，再调注入的回调）。
  ///
  /// ## `_signingOut` 这道护栏属于「防御性」，UI 结构已基本堵住
  ///
  /// 入口 ListTile 在 `_signingOut` 为 true 时 `onTap` 直接置 null，故正常路径
  /// 下走不到这里。它仍然保留，是因为 `setState` 到重建之间有一个窗口：
  /// 多点触控下第二次 tap 可能在重建前就完成命中测试。这个窗口无法用
  /// widget test 稳定复现（实测：去掉该判断后全部用例仍绿），故这里如实
  /// 说明它**没有测试覆盖**，而不是假装有。
  Future<void> _signOut() async {
    final handler = widget.onSignOut;
    if (handler == null || _signingOut) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('将清除本机保存的登录凭证，下次需要重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('settings-sign-out-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _signingOut = true);
    try {
      await handler();
      // 成功后**不**复位 `_signingOut`：调用方会导航走本页（登出后回登录页），
      // 期间按钮不应再可点。若调用方选择留在本页（如未接路由的用法），
      // 那也说明它有自己的处理，不应该看到按钮又变回可点而重复登出。
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _signingOut = false;
        _error = '退出登录失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_dirty)
            TextButton(
              key: const ValueKey('settings-save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final draft = _draft;
    if (draft == null) {
      return Center(
        child: Padding(
          padding: SpbSpacing.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '读取设置失败'),
              const SizedBox(height: SpbSpacing.lg),
              FilledButton.tonal(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: SpbSpacing.pagePadding,
      children: [
        if (widget.onOpenSync != null) ...[
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('settings-sync-entry'),
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('立即同步交付物'),
              subtitle: const Text('查看本轮下载结果'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenSync,
            ),
          ),
          const SizedBox(height: SpbSpacing.lg),
        ],
        // 外观：与其余设置项不同，**选中即保存**（不走 draft）。见
        // [SaveThemeMode] 的说明——主题需要即时反馈。
        if (widget.loadThemeMode != null && widget.saveThemeMode != null) ...[
          const SectionTitle('外观', highlight: true),
          Card(
            key: const ValueKey('settings-appearance'),
            margin: EdgeInsets.zero,
            child: RadioGroup<ThemeMode>(
              groupValue: _themeMode,
              onChanged: (v) {
                if (v != null) _setThemeMode(v);
              },
              child: Column(
                children: [
                  for (final mode in SpbThemeMode.all)
                    RadioListTile<ThemeMode>(
                      key: ValueKey('settings-theme-${mode.name}'),
                      value: mode,
                      title: Text(SpbThemeMode.label(mode)),
                      // 未读到当前值时禁用：宁可让用户等一帧，也不显示一个
                      // 可能错的选中项。
                      enabled: _themeMode != null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: SpbSpacing.lg),
        ],

        const SectionTitle('同步目录', highlight: true),
        _DirectoryCard(
          localRoot: draft.localRoot,
          onPick: _pickDirectory,
          onOpenDirectory:
              widget.onOpenDirectory == null ||
                  draft.localRoot == null ||
                  draft.localRoot!.isEmpty
              ? null
              : () async {
                  final ok = await widget.onOpenDirectory!(draft.localRoot!);
                  if (!mounted) return;
                  if (!ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('无法打开目录，请检查路径是否存在')),
                    );
                  }
                },
        ),
        const SizedBox(height: SpbSpacing.lg),

        const SectionTitle('同步范围', highlight: true),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('settings-scope-all'),
                value: draft.scope.allGroups,
                onChanged: _setScopeAll,
                title: const Text('全部对话'),
                subtitle: const Text('同步该账号下所有对话的交付物'),
              ),
              if (!draft.scope.allGroups) _buildGroupPicker(draft),
            ],
          ),
        ),
        const SizedBox(height: SpbSpacing.lg),

        const SectionTitle('过滤与范围', highlight: true),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('settings-include-media'),
                value: draft.filter.includeMedia,
                onChanged: _setIncludeMedia,
                title: const Text('同步图片与音视频'),
                subtitle: const Text('默认关闭：生产环境中媒体占交付物体积的绝大多数'),
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text('单文件上限'),
                subtitle: const Text('超过此大小的文件跳过；0 表示不限'),
                trailing: SizedBox(
                  width: 96,
                  child: TextField(
                    key: const ValueKey('settings-max-file-size'),
                    controller: _maxSizeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.end,
                    onChanged: _setMaxSizeFromField,
                    decoration: const InputDecoration(
                      suffixText: 'MB',
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                title: const Text('拉取范围'),
                subtitle: const Text('只同步最近变动过的交付物；「不限」会拉全部历史'),
                trailing: DropdownButton<int?>(
                  key: const ValueKey('settings-since-days'),
                  value: draft.sinceDays,
                  onChanged: _setSinceDays,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('不限')),
                    DropdownMenuItem(value: 7, child: Text('近 7 天')),
                    DropdownMenuItem(value: 30, child: Text('近 30 天')),
                    DropdownMenuItem(value: 90, child: Text('近 90 天')),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SpbSpacing.lg),

        // 自动同步：仅桌面端渲染（见 [SettingsPage.showAutoSync] 的说明）。
        if (widget.showAutoSync) ...[
          const SectionTitle('自动同步', highlight: true),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                SwitchListTile(
                  key: const ValueKey('settings-auto-sync-on-group-open'),
                  value: draft.auto.onGroupOpen,
                  onChanged: _setAutoGroupOpen,
                  title: const Text('进入对话时按需同步'),
                  // 说清「按需」的含义：不是每次进都拉，而是先判定有没有新的。
                  subtitle: const Text('打开对话时先检查该对话有没有新交付物，有才拉取'),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  key: const ValueKey('settings-auto-sync-on-launch'),
                  value: draft.auto.onLaunch,
                  onChanged: _setAutoOnLaunch,
                  title: const Text('启动后自动同步一次'),
                  subtitle: const Text('打开应用并完成登录后拉取一轮'),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('周期同步'),
                  subtitle: const Text('应用运行期间每隔一段时间自动拉取一轮'),
                  trailing: DropdownButton<int>(
                    key: const ValueKey('settings-auto-sync-interval'),
                    value: draft.auto.intervalMinutes,
                    onChanged: _setAutoInterval,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('关闭')),
                      DropdownMenuItem(value: 15, child: Text('每 15 分钟')),
                      DropdownMenuItem(value: 30, child: Text('每 30 分钟')),
                      DropdownMenuItem(value: 60, child: Text('每小时')),
                      DropdownMenuItem(value: 180, child: Text('每 3 小时')),
                    ],
                  ),
                ),
                if (draft.auto.isEnabled) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            // 首次全量同步可能很大（生产实测 5666 条 / 4.7 GB）。
                            // 不说清楚会让用户以为「开了自动同步却卡住」——
                            // 那其实是正在下第一批。
                            '自动同步只从云端拉取到本地（不会上传本地改动）。'
                            '首次同步会拉取全部历史交付物，可能较慢且占用较多流量，'
                            '可用上方「拉取范围」限制。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SpbSpacing.lg),
        ],

        const SectionTitle('本地数据', highlight: true),
        _StatsCard(
          stats: _stats,
          loading: _loadingStats,
          pruning: _pruning,
          canPrune: draft.hasLocalRoot,
          onPrune: _prune,
        ),

        // 通知订阅：仅在两端都注入了读写入口时展示（成对判断，避免出现
        // 有读无写的半截区块）。
        if (widget.loadNotifications != null &&
            widget.saveNotifications != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          NotificationSubscriptionsCard(
            load: widget.loadNotifications!,
            save: widget.saveNotifications!,
          ),
        ],

        // 个人偏好：同样成对判断（有读无写的半截区块会让用户以为改不了）。
        if (widget.loadPreferences != null &&
            widget.savePreferences != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          UserPreferencesCard(
            load: widget.loadPreferences!,
            save: widget.savePreferences!,
            agentOptions: widget.preferenceAgentOptions,
            fallbackDisplayName: widget.preferenceFallbackDisplayName,
          ),
        ],

        // 桌面能力项：移动端（visible == false）整段不展示。
        if (widget.desktopInfo.visible) ...[
          const SizedBox(height: SpbSpacing.lg),
          const SectionTitle('桌面集成', highlight: true),
          Card(
            key: const ValueKey('settings-capabilities'),
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.keyboard_outlined),
                  title: const Text('悬浮输入窗快捷键'),
                  subtitle: Text(widget.desktopInfo.hotkeyLabel),
                ),
                const Divider(height: 1),
                // 托盘**已接线**（`desktop_integration.dart` 的
                // `_installTrayMenu` 推送菜单、注册显示/快速输入/退出回调），
                // 但「托盘图标是否真的出现在用户的桌面环境里」取决于
                // appindicator 支持——那只能真机验证。故文案区分这两件事：
                // 说「已接入菜单与回调」，而不是含糊的「未完成」（后者是
                // 事实错误，会让用户以为托盘根本没做）。
                const ListTile(
                  leading: Icon(Icons.notifications_none_outlined),
                  title: Text('系统托盘'),
                  subtitle: Text('已接入菜单与回调（图标是否显示取决于桌面环境）'),
                  enabled: false,
                ),
                if (widget.loadLaunchAtStartup != null) ...[
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const ValueKey('settings-launch-at-startup'),
                    // SwitchListTile 的左侧图标参数叫 secondary（不是 leading）。
                    secondary: const Icon(Icons.power_settings_new_outlined),
                    title: const Text('开机自启'),
                    subtitle: const Text('登录系统后自动在托盘启动'),
                    // 读不到状态（null）时禁用：宁可显示「未知」也不显示
                    // 一个可能是假的「已关闭」。
                    value: _launchAtStartup ?? false,
                    onChanged: (_launchAtStartup == null || _togglingLaunch)
                        ? null
                        : _toggleLaunchAtStartup,
                  ),
                ],
              ],
            ),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          _Banner(message: _error!, danger: true),
        ],
        if (_savedHint && !_dirty) ...[
          const SizedBox(height: SpbSpacing.lg),
          const _Banner(
            key: ValueKey('settings-saved'),
            message: '设置已保存',
            danger: false,
          ),
        ],

        // 危险操作区放最后：与上面的普通设置项拉开距离，避免误触。
        if (widget.onSignOut != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          const SectionTitle('账号', highlight: true),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('settings-sign-out'),
              leading: Icon(
                Icons.logout,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('退出登录'),
              subtitle: const Text('清除本机登录凭证'),
              enabled: !_signingOut,
              onTap: _signingOut ? null : _signOut,
            ),
          ),
        ],
        if (widget.onOpenMyTurns != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('settings-my-turns-entry'),
              leading: const Icon(Icons.history_outlined),
              title: const Text('我的最近轮次'),
              subtitle: const Text('跨对话回顾最近让 agent 做了什么'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenMyTurns,
            ),
          ),
        ],

        // 诊断：报障时把环境信息 + 最近日志导成一个文本文件（issue #40）。
        //
        // ## 为什么放在最后一节而不是「桌面集成」区块里
        //
        // 那个区块只在桌面端展示（`desktopInfo.visible`），而诊断入口在两端
        // 都可接（移动端会得到 `unsupported`）。混进去会让移动端因为
        // 「visible == false」而整个区块不渲染，入口跟着消失——而它本不属于
        // 「桌面集成」的语义（与托盘/快捷键无关）。
        if (widget.onExportDiagnostics != null) ...[
          const SizedBox(height: SpbSpacing.lg),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('settings-export-diagnostics'),
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('导出诊断日志'),
              subtitle: const Text('包含版本、平台与最近日志；已对疑似凭据掩码'),
              // 在途时用转圈替掉右侧箭头：保存对话框是模态的，用户看不到
              // 「已在处理」就会再点一下。
              trailing: _exportingDiagnostics
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_alt_outlined),
              enabled: !_exportingDiagnostics,
              onTap: _exportingDiagnostics ? null : _exportDiagnostics,
            ),
          ),
        ],
        const SizedBox(height: SpbSpacing.xl),
      ],
    );
  }

  Widget _buildGroupPicker(SyncSettings draft) {
    if (_loadingGroups) {
      return const Padding(
        padding: EdgeInsets.all(SpbSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_groupsError != null) {
      return ListTile(
        title: Text(_groupsError!),
        trailing: TextButton(onPressed: _loadGroups, child: const Text('重试')),
      );
    }
    final groups = _groups ?? const <ChatGroup>[];
    if (groups.isEmpty) {
      return const ListTile(title: Text('没有可选的对话'));
    }

    return Column(
      children: [
        const Divider(height: 1),
        for (final g in groups)
          CheckboxListTile(
            key: ValueKey('settings-group-${g.id}'),
            value: draft.scope.groupIds.contains(g.id),
            onChanged: (v) => _toggleGroup(g.id, v ?? false),
            title: Text(g.title, overflow: TextOverflow.ellipsis),
            subtitle: g.isArchived ? const Text('已归档') : null,
            dense: true,
          ),
      ],
    );
  }
}

/// 分节标题。

/// 同步目录卡片。
class _DirectoryCard extends StatelessWidget {
  const _DirectoryCard({
    required this.localRoot,
    required this.onPick,
    this.onOpenDirectory,
  });

  final String? localRoot;
  final VoidCallback onPick;

  /// 打开目录回调（null = 不展示「打开目录」按钮）。桌面端注入。
  final Future<void> Function()? onOpenDirectory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasRoot = localRoot != null && localRoot!.trim().isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Row(
          children: [
            Icon(
              hasRoot ? Icons.folder_outlined : Icons.folder_off_outlined,
              color: hasRoot ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: SpbSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasRoot ? localRoot! : '尚未选择（点右侧按钮选择）',
                    key: const ValueKey('settings-local-root'),
                    style: textTheme.bodyMedium?.copyWith(
                      color: hasRoot ? null : scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  const SizedBox(height: SpbSpacing.xxs),
                  Text(
                    // 「换目录会重置同步记录」必须写在用户能看到的地方：
                    // 否则他会以为同步出错了（明明同步过，怎么又要重下）。
                    '更换目录会重置同步记录（已下载的文件不会自动迁移）',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: SpbSpacing.sm),
            TextButton(
              key: const ValueKey('settings-pick-directory'),
              onPressed: onPick,
              child: const Text('选择目录'),
            ),
            if (onOpenDirectory != null)
              TextButton.icon(
                key: const ValueKey('settings-open-directory'),
                onPressed: onOpenDirectory,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开目录'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 本地统计 + 清理入口。
class _StatsCard extends StatelessWidget {
  const _StatsCard({
    required this.stats,
    required this.loading,
    required this.pruning,
    required this.canPrune,
    required this.onPrune,
  });

  final LocalSyncStats? stats;
  final bool loading;
  final bool pruning;
  final bool canPrune;
  final VoidCallback onPrune;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final s = stats;

    return Card(
      key: const ValueKey('settings-stats'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: SpbSpacing.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: SpbSpacing.sm),
                child: LinearProgressIndicator(),
              )
            else if (s == null || s.isEmpty)
              Text('本地还没有同步过数据', style: textTheme.bodyMedium)
            else
              Wrap(
                spacing: SpbSpacing.lg,
                runSpacing: SpbSpacing.sm,
                children: [
                  Text('${s.groupCount} 个对话目录', style: textTheme.bodyMedium),
                  Text('${s.fileCount} 个文件', style: textTheme.bodyMedium),
                  Text(humanBytes(s.totalBytes), style: textTheme.bodyMedium),
                ],
              ),
            const SizedBox(height: SpbSpacing.md),
            OutlinedButton.icon(
              key: const ValueKey('settings-prune'),
              onPressed: (!canPrune || pruning) ? null : onPrune,
              icon: pruning
                  ? const SizedBox(
                      width: SpbSpacing.lg,
                      height: SpbSpacing.lg,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cleaning_services_outlined),
              label: Text(pruning ? '清理中…' : '清理本地文件'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 提示条（错误 / 成功）。
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.message, required this.danger});

  final String message;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: danger ? const ValueKey('settings-error') : null,
      padding: SpbSpacing.cardPadding,
      decoration: BoxDecoration(
        color: danger ? scheme.errorContainer : scheme.tertiaryContainer,
        borderRadius: SpbRadius.cardAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            danger ? Icons.error_outline : Icons.check_circle_outline,
            color: danger
                ? scheme.onErrorContainer
                : scheme.onTertiaryContainer,
          ),
          const SizedBox(width: SpbSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: danger
                    ? scheme.onErrorContainer
                    : scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
