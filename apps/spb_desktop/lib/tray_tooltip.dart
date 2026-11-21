// Why 整文件忽略 prefer_initializing_formals：Dart 不允许私有**命名**参数
// （`this._capabilities` 会强制调用方写 `_capabilities:`，编译器直接拒绝），
// 故构造函数里只能用「公开参数名 + 显式赋值」，该 lint 在此是误报。
// 与 desktop_integration.dart 同一情况。
// ignore_for_file: prefer_initializing_formals

import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 托盘提示文本的构造规则（**纯函数**，便于单测）。
///
/// ## 为什么需要它
///
/// `TrayState`（`spb_platform/lib/src/tray.dart`）定义了
/// `unreadCount` / `syncEnabled` / `syncing` 与 `displayTooltip` 的拼装规则，
/// 但它**零引用**——托盘提示从未被推送过，用户看到的永远是托盘库的默认值。
///
/// 未读数由 `/me/notices` 提供，表示站内通知，不是聊天消息计数。
TrayState buildTrayState({
  required bool syncConfigured,
  required bool syncing,
  int unreadCount = 0,
}) {
  return TrayState(
    tooltip: _tooltipText(syncConfigured: syncConfigured, syncing: syncing),
    unreadCount: unreadCount,
    syncEnabled: syncConfigured,
    syncing: syncing,
  );
}

/// 提示文本：基础名 + 同步状态。
///
/// ## 为什么不把「未读」拼进来
///
/// `TrayState.displayTooltip` 已经负责把未读数拼成 `名称 (N)`。若这里再拼
/// 一次会得到 `名称 (3) (3)`。故本函数只管同步状态，未读交给 `displayTooltip`。
String _tooltipText({required bool syncConfigured, required bool syncing}) {
  if (syncing) return 'Super PartyB — 同步中…';
  if (!syncConfigured) return 'Super PartyB — 未配置同步目录';
  return 'Super PartyB';
}

/// 把同步状态推送到托盘提示。
///
/// ## 为什么是一个持有订阅的类，而不是在 `app.dart` 里直接 `ref.listen`
///
/// `ref.listen` 必须在 `build` 里调用（Riverpod 的约束，见
/// `flutter_riverpod` 的 `listen` 文档），而托盘接线发生在 `initState`
/// ——那时还没有 build 上下文。用一个类持有 `ProviderSubscription` 并在
/// [dispose] 里关掉，生命周期与 `DesktopIntegration` 一致（都由
/// `SpbDesktopApp` 持有）。
///
/// ## 为什么订阅的是「是否在同步」而不是「同步结果」
///
/// 提示文本要反映**当下**的状态（正在同步 / 空闲），而不是历史结果。同步
/// 结束后回到「空闲」才是用户预期——一个永久显示「同步中…」的托盘提示
/// 比没有提示更糟（用户会以为同步卡住了）。
class TrayTooltipController {
  TrayTooltipController({
    required DesktopCapabilities capabilities,
    required bool Function() syncConfigured,
    required bool Function() syncing,
    int Function()? unreadCount,
  }) : _capabilities = capabilities,
       _syncConfigured = syncConfigured,
       _syncing = syncing,
       _unreadCount = unreadCount;

  final DesktopCapabilities _capabilities;

  /// 读取「是否已配置同步目录」。
  ///
  /// 用回调而非快照值：目录可能在设置页被改（甚至清空），持有快照会一直
  /// 显示旧状态。
  final bool Function() _syncConfigured;

  /// 读取「是否正在同步」。
  final bool Function() _syncing;
  final int Function()? _unreadCount;

  /// 上一次推送的文本。去重，避免每次状态通知都做一次平台调用。
  String? _lastPushed;

  /// 立即按当前状态推送一次。
  ///
  /// 不 await：托盘推送失败已在能力层内部降级（记日志），启动流程不该
  /// 因托盘卡住。
  void push() {
    final text = buildTrayState(
      syncConfigured: _syncConfigured(),
      syncing: _syncing(),
      unreadCount: _unreadCount?.call() ?? 0,
    ).displayTooltip;

    if (text == _lastPushed) return;
    _lastPushed = text;
    _capabilities.setTrayTooltip(text).catchError((Object e) {
      SpbLog.warn('推送托盘提示失败', {'error': e.toString()});
    });
  }

  void dispose() {
    // 目前无订阅需要关闭（调用方负责触发 push）。保留方法是为了让生命周期
    // 对称——将来若接入真正的未读来源，订阅会挂在这里。
    _lastPushed = null;
  }
}
