/// 「确认卡到达时该不该发 OS 通知」的判定。
///
/// ## 为什么这条规则在 domain 而不是 UI
///
/// 它不是渲染细节，而是一条**产品规则**（防骚扰）：
///
/// 1. 只对**新到达且未解决**的确认卡发（不是每次 items 变化都发）；
/// 2. 每个 id 只发一次（SSE 重连会回放，不判重会连弹几十条）；
/// 3. 窗口在前台时不发（用户正看着对话，弹窗是噪音）；
/// 4. 权限只请求一次（否则 Android 上会反复弹框）。
///
/// 散在 UI 里会随页面重建而失效：`_seen` 集合放在 `State` 里，切 group 重建
/// 页面就把判重丢了 → 同一张卡弹两次。故抽成独立对象，由装配层持有在**跨页面
/// 重建**的生命周期上（与 apps 既有的 `_seenConfirmationIds` 同寿命）。
///
/// ## 为什么不用「结构类型」绕开依赖
///
/// Dart 是**名义类型**：`item is SomeInterface` 要求类型真的实现了该接口，
/// 只有同名成员**不够**。故判定必须放在能 import `ConfirmationItem` 的包里，
/// 而那就是 `spb_domain`。
library;

import 'package:spb_core/spb_core.dart';

import 'conversation_item.dart';
import 'notifications.dart';

/// 通知文案与负载的构造参数。
///
/// 抽出来是为了让「文案」与「判定」分开测试，且允许装配层覆盖（如将来做 i18n，
/// 见 issue #23）。
class ConfirmationNotificationText {
  const ConfirmationNotificationText({
    this.title = '需要你确认',
    this.fallbackBody = '有一项操作等待确认',
  });

  final String title;

  /// 确认卡问题为空时的兜底正文。
  ///
  /// ## 为什么需要兜底
  ///
  /// 确认卡的 `question` 来自服务端 payload。异常载荷（缺字段）会让正文为空，
  /// 而一条**没有正文**的系统通知在 Linux 上根本不显示（libnotify 需要 body
  /// 或 summary 至少有一个非空），在 Android 上显示为空白行。故必须有兜底。
  final String fallbackBody;
}

/// 确认卡 → 通知负载的路由前缀。
///
/// 点击通知要跳到**该对话**（不只是「打开应用」）。用 `/chat/{groupId}`——
/// 与 apps 的路由约定一致。
String confirmationNotificationPayload(String groupId) => '/chat/$groupId';

/// 「确认卡到达时该不该发通知」的判定器（有状态）。
///
/// 见库级文档的三条规则。本类**不做 IO**（除通过 [NotificationSink] 发送）：
/// 判定是纯逻辑，可在无平台通道的环境里完整单测。
class ConfirmationNotifier {
  ConfirmationNotifier({
    required NotificationSink sink,
    required bool Function() isWindowFocused,
    this.text = const ConfirmationNotificationText(),
  }) : _sink = sink,
       _isWindowFocused = isWindowFocused;

  final NotificationSink _sink;

  /// 窗口是否在前台（聚焦）。
  ///
  /// 做成回调而不是构造时的布尔快照：聚焦状态**随时变化**，快照会让
  /// 「启动时未聚焦」永远为真（此后每条通知都发）。
  final bool Function() _isWindowFocused;

  final ConfirmationNotificationText text;

  /// 已处理过的确认卡 id。
  ///
  /// 含「已发通知的」与「前台看到过的」「已解决的」——见类文档的规则 3。
  final Set<String> _notifiedIds = {};

  /// 已处理的确认卡 id 数（供测试与诊断）。
  int get notifiedCount => _notifiedIds.length;

  /// 是否已处理过该 id。
  bool hasSeen(String confirmationId) => _notifiedIds.contains(confirmationId);

  /// 权限是否已确认。null = 尚未请求。
  bool? _permissionGranted;

  /// 请求一次权限（幂等：已请求过就不重复请求）。
  ///
  /// ## 为什么幂等很重要
  ///
  /// 每次 `items` 变化都请求一次权限，会在 Android 上反复弹框（用户点了「拒绝」
  /// 之后还弹，直到系统永久拒绝）。幂等保证「应用生命周期内最多请求一次」。
  Future<bool> ensurePermission() async {
    final cached = _permissionGranted;
    if (cached != null) return cached;
    final granted = await _sink.requestPermission();
    _permissionGranted = granted;
    if (!granted) {
      SpbLog.debug('通知权限未授予，后续不再尝试');
    }
    return granted;
  }

  /// 接线点击回调。
  ///
  /// ## 为什么导航回调在 [attach] 而不是构造函数
  ///
  /// 本对象由 Riverpod 的 `Provider` 创建，而**路由实例在 app 层**
  /// （`GoRouter` 由 `SpbDesktopApp`/`SpbMobileApp` 的 `initState` 建）。
  /// provider 拿不到路由，若把回调塞进构造函数，就得反过来让 provider 依赖
  /// 路由——那会把「路由」拖进依赖图（并在测试里被迫构造 GoRouter）。
  ///
  /// 故：构造只依赖 [NotificationSink] 与焦点判定，导航由 app 层在
  /// `initState` 里接上。`onNavigate` 为 null 时不接线（测试 / 未装配路由）。
  ///
  /// 幂等：重复调用只保留最后一次接线。
  void attach({void Function(String payload)? onNavigate}) {
    if (onNavigate == null) return;
    _sink.onSelect = (payload) {
      if (payload == null || payload.isEmpty) return;
      onNavigate(payload);
    };
  }

  /// 处理一批归约后的对话项，对**新到达且未解决**的确认卡发通知。
  ///
  /// 返回本次实际发出的通知（供测试断言，也便于调用方记日志）。
  Future<List<LocalNotification>> handleItems(
    Iterable<ConversationItem> items,
  ) async {
    final fresh = <ConfirmationItem>[];
    for (final item in items) {
      if (item is! ConfirmationItem) continue;
      final id = item.confirmationId;
      // 空 id 的卡无法判重（也不可 resolve）：不发。
      // 不入 `_notifiedIds`（没有可记的键），故它每轮都会被跳过——正确。
      if (id.isEmpty) continue;
      if (item.resolved) {
        // 已解决的卡：记入但不发（历史回填会把旧卡推来）。
        _notifiedIds.add(id);
        continue;
      }
      if (_notifiedIds.add(id)) fresh.add(item);
    }

    if (fresh.isEmpty) return const [];

    // 规则 3：窗口在前台 → 不打扰。**但仍已记入** `_notifiedIds`（上面的 add
    // 已生效）：用户已经看到这张卡，之后切到后台不该为它补弹一条。
    if (_isWindowFocused()) return const [];

    // 规则 4：权限只请求一次。
    if (!await ensurePermission()) return const [];

    final sent = <LocalNotification>[];
    for (final card in fresh) {
      final notification = LocalNotification(
        id: card.confirmationId,
        title: text.title,
        body: card.question.isEmpty ? text.fallbackBody : card.question,
        // payload 用 groupId：点击后要跳到**该对话**，而不只是打开应用。
        // 空 groupId 时不带 payload（导航层退化为「打开主窗口」）。
        payload: card.groupId.isEmpty
            ? null
            : confirmationNotificationPayload(card.groupId),
      );
      await _sink.show(notification);
      sent.add(notification);
    }
    return sent;
  }

  /// 清空判重集合与权限缓存（切用户 / 退出登录时调用）。
  ///
  /// ## 为什么必须清
  ///
  /// 换用户后新卡的 id 与旧的不会冲突（服务端 id 全局唯一），故不清也不会误判。
  /// 但两点必须清：
  ///
  /// - `_permissionGranted`：新会话下权限可能变了（用户去系统设置里改过），
  ///   沿用旧缓存会让「上次被拒」永久静默；
  /// - `_notifiedIds`：无界增长（长会话累积），且它描述的是「本会话见过什么」。
  void reset() {
    _notifiedIds.clear();
    _permissionGranted = null;
  }
}
