/// 移动端后台检查（`WorkManager`）的**可观测读数**。
///
/// ## 为什么要有它
///
/// 后台检查是「尽力而为」的（§6.111）：Doze、待机分桶、用户划掉应用、厂商省电
/// 策略、没给通知权限——每一种都能让它**静默不跑**。此前只记「上次**成功**的
/// 时刻」，于是「没收到通知」只答得出「跑过 / 没跑过」两态，区分不了
/// 「在前台所以不发」「没权限所以排程被撤」「请求失败在退避」。
///
/// 更要紧的是：它跑在**另一个 engine** 里，`SpbLog` 的环形缓冲不共享——
/// 前台「导出诊断日志」看不到后台的任何一行。故每轮结局落进 `notifications.db`
/// （`NotificationStateStore`），设置页与诊断读同一份事实。
///
/// ## 边界
///
/// 只记**元信息**：结局、时刻、计数、错误摘要。不记通知正文、不记 token、
/// 不记 group 标题——它是给用户念给我们听的，不是数据通道。
library;

/// 一次后台检查的结局。
///
/// 三态而非布尔：`skipped`（有意不发）与 `failed`（没做成）在排查上方向相反，
/// 混成一个「没弹」会让用户和我们同时猜错。
enum BackgroundCheckOutcome { ok, skipped, failed }

/// [BackgroundCheckOutcome.skipped] 的原因。
enum BackgroundCheckSkip {
  /// 应用在前台：通知交给应用内提示，后台刻意不发（§6.111「不该弹的时候不能弹」）。
  foreground,

  /// 没有通知权限：排程本身已被撤（`reconcile(enabled: false)`），这里只是确认。
  noPermission,

  /// 没有凭证：登出态下旧任务仍可能被系统唤醒。
  loggedOut,

  /// 请求期间换账号 / 登出：旧响应已丢弃。
  sessionChanged,

  /// 被系统中断（`onTaskStopped`）或超出本次 deadline。
  interrupted,
}

/// [BackgroundCheckOutcome.failed] 的成因分类。
enum BackgroundCheckFailure {
  /// 认证失败（`AuthError`）：刷新失败或凭证作废，通常需要用户重新登录。
  auth,

  /// 请求失败：网络、超时、5xx。下一轮退避重试即可。
  request,
}

/// 一次后台检查的结果（每轮**都**写，成功也写）。
///
/// 与「上次成功时刻」分开存：失败/跳过不能把那个时刻擦掉（一个旧的时刻配上
/// 「刚跑过」的暗示比没有更误导），但也必须留下本轮发生了什么。
class BackgroundCheckResult {
  const BackgroundCheckResult({
    required this.outcome,
    required this.at,
    this.skip,
    this.failure,
    this.unread,
    this.fetched,
    this.shown,
    this.error,
  });

  final BackgroundCheckOutcome outcome;

  /// 本轮结束时刻（UTC 存、展示时转本地）。
  final DateTime at;

  /// 仅 [BackgroundCheckOutcome.skipped] 有值。
  final BackgroundCheckSkip? skip;

  /// 仅 [BackgroundCheckOutcome.failed] 有值。
  final BackgroundCheckFailure? failure;

  /// 服务端报告的未读数（成功时才有）。
  final int? unread;

  /// 本轮拉取的 notice 条数（成功时才有）。
  final int? fetched;

  /// 本轮实际弹出的通知条数（成功时才有）。
  final int? shown;

  /// 失败摘要（已截断，见 [describeBackgroundCheckResult]）。成功/跳过恒为 null。
  final String? error;
}

/// 设置页要的两件事：上次**成功**的时刻，以及**最近一次**（任意结局）。
///
/// 拆成两个字段而不是「最近一次成功」一个字段：用户问的是「为什么这次没收到」，
/// 那要看最近一次，而不是上一次成功（后者可能是一小时前，也可能压根没有）。
class BackgroundCheckReport {
  const BackgroundCheckReport({this.lastSuccessAt, this.last});

  /// 上一次**成功**的时刻（null = 从未成功过）。
  final DateTime? lastSuccessAt;

  /// 最近一次尝试的结局（null = 升级前的老库，没有这条记录）。
  final BackgroundCheckResult? last;

  static const empty = BackgroundCheckReport();
}

/// 把一次结局说成一句**只陈述事实**的中文（设置页副标题、诊断导出共用）。
///
/// 刻意不写「保证送达」之类承诺：后台检查在 Doze / 待机分桶 / 用户划掉应用时
/// 会被推迟甚至取消，写死承诺只会在没收到时误导排查方向。
///
/// [maxErrorChars] 只约束错误摘要：它是给用户念的，太长反而没人念。
String describeBackgroundCheckResult(
  BackgroundCheckResult result, {
  int maxErrorChars = 60,
}) {
  switch (result.outcome) {
    case BackgroundCheckOutcome.ok:
      final fetched = result.fetched;
      final shown = result.shown;
      if (fetched == null || shown == null) return '成功';
      return '成功（抓取 $fetched 条，弹出 $shown 条）';
    case BackgroundCheckOutcome.skipped:
      return switch (result.skip) {
        BackgroundCheckSkip.foreground => '在前台，已交给应用内提示',
        BackgroundCheckSkip.noPermission => '没有通知权限，后台检查已停用',
        BackgroundCheckSkip.loggedOut => '未登录，后台检查暂停',
        BackgroundCheckSkip.sessionChanged => '请求期间换了账号，结果已丢弃',
        BackgroundCheckSkip.interrupted => '被系统中断（超时或被停）',
        null => '跳过',
      };
    case BackgroundCheckOutcome.failed:
      final head = switch (result.failure) {
        BackgroundCheckFailure.auth => '认证失败（可能需要重新登录）',
        BackgroundCheckFailure.request => '请求失败',
        null => '失败',
      };
      final detail = _truncate(result.error, maxErrorChars);
      return detail == null ? head : '$head：$detail';
  }
}

String? _truncate(String? text, int max) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  // 单行化：错误串常带换行，进副标题会把行高撑开。
  final single = trimmed.replaceAll(RegExp(r'\s+'), ' ');
  return single.length <= max ? single : '${single.substring(0, max)}…';
}
