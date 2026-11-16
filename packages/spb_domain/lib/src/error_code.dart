/// 服务端 `error` 事件的 `code` 闭集，以及客户端表现位。
///
/// ## 真源与边界
///
/// 服务端真源是 super_partyb 的 `chatbus.ErrorCodes()` 与它导出的
/// `apps/go-api/docs/error-codes.json`（`{code, default_message, retryable}`）。
/// 本文件是**客户端镜像**：闭集取值与 `retryable` 必须与该 JSON 逐条相等，
/// 由 `test/error_code_test.dart` 读 vendored 的
/// `test/fixtures/error_codes.json` 对拍（CI 不联网）。
///
/// 客户端**不抄 `default_message`**：正文文案一律用服务端下发的 `message`
/// （它空时才由服务端自己回落兜底句）。这里只放「这个 code 该怎么表现」——
/// 图标与是否可重发——那是 UI 决策，服务端没有、也不该有。
///
/// ## 为什么 `code` 是 String 的镜像而不是 Dart enum
///
/// 服务端会**先**发新 code、客户端**后**升级（移动端无法强制升级）。若客户端
/// 用 exhaustive `enum`，新值直接落到 `values.first` 或抛异常，用户会看到错误
/// 的分类与错的表现。故 [traits] 接受 `String?`，未知值一律 fail-open 到
/// [ErrorCodeTraits.failOpen]（≈ 今天的行为），详见其文档。
///
/// ## 为什么没有 `needsRestore`
///
/// webapp 侧有一份历史实现按 `error_type == "session_expired"` 先 restore 会话
/// 再重发；Go 侧没有这个形态（幽灵 session 在执行**之前**就被
/// `chatexec.verifyContinuationSession` 清空自愈，超窗由 `OverflowRetryExecutor`
/// 自动「清 session + 重试一次」），服务端也刻意**没有**把这个值放进闭集
/// （见 super_partyb#182 的复核结论）。本仓库的「重发」就是再发一条消息，
/// 不存在需要先 restore 的前置动作，故不留空位。
library;

/// 错误图标 token。
///
/// 纯 Dart 包不得 import `package:flutter/*`（分层守卫 + `dart test` 无引擎），
/// 故这里只给**语义 token**，`IconData` 由 `spb_features` 侧映射
/// （`_errorIcon`）。
enum ErrorCodeIcon {
  /// 内存 / 资源上限。
  memory,

  /// 上游限流（可重试）。
  rateLimited,

  /// 上游一般错误 / 内部错误。
  server,

  /// 时间类（未活动 / 硬超时）。
  timeout,

  /// 执行中断（挂死清理）。
  interrupted,

  /// 未知 code 的兜底。
  generic,
}

/// 一个 `code` 的客户端表现位。
final class ErrorCodeTraits {
  const ErrorCodeTraits({
    required this.retryable,
    required this.icon,
    this.label,
  });

  /// 是否值得给「重发」入口。
  ///
  /// 与服务端 `chatbus.Retryable(code)` **逐条对齐**（它是该语义位的真源）：
  /// 限流 / 上游错误 / 两档超时 / 挂死 → true；OOM 与 `internal_error` → false。
  /// OOM 之所以不可重试：同样的输入 + 同样的内存上限必然再崩一次，重发只会
  /// 让用户多等一轮、并再吃一次沙箱杀进程的开销。
  final bool retryable;

  /// 图标语义 token。
  final ErrorCodeIcon icon;

  /// 短分类徽标（如「内存不足」），用于红卡标题。
  ///
  /// **不是正文文案**：正文永远是服务端 `message`。这里只回答「这是哪一类失败」，
  /// 让用户在一屏里扫出差异（OOM vs 限流 vs 超时），而不用读完一整句话。
  ///
  /// `null` = 未知 `code`（[ErrorCodeTraits.failOpen]）：不猜分类，UI 因此不渲染
  /// 徽标——猜错类别比不给类别更误导。
  final String? label;

  /// 未知 / 缺失 `code` 时的 fail-open 表现。
  ///
  /// 两条都刻意取「等于今天的行为」：
  ///
  /// - `retryable: true` —— 历史事件（#182 之前的库里只有 `{"content": …}`）
  ///   与未来服务端先发的新 code 都走这里。把「重发」按钮收掉是**负向**行为
  ///   变化（用户会以为功能坏了），而它多渲染一次的代价只是「按了也没用」；
  /// - `icon/label` 走通用兜底，不猜语义（猜错分类比不分类更误导：把限流说成
  ///   「内存不足」会让用户去调小任务）。
  static const failOpen = ErrorCodeTraits(
    retryable: true,
    icon: ErrorCodeIcon.generic,
  );
}

/// 服务端 `error` code 闭集（顺序 = 服务端 `docs/error-codes.json` 的条目序）。
abstract final class ErrorCodes {
  /// 执行被内核 OOM killer 打断（SIGKILL / ExitCode 137）。
  static const oomKill = 'oom_kill';

  /// 上游（模型网关）限流。
  static const upstreamRateLimited = 'upstream_rate_limited';

  /// 上游一般性失败（连接失败 / 5xx / 流中断）。
  static const upstreamError = 'upstream_error';

  /// 未活动看门狗触发（长时间无进展）。
  static const timeoutInactivity = 'timeout_inactivity';

  /// 硬超时（本轮 deadline）。
  static const timeoutHard = 'timeout_hard';

  /// 挂死清理（running 超过 TTL 被标记失败）。
  static const turnStalled = 'turn_stalled';

  /// 兜底码（服务端保证「无 code 可填时落它」）。
  static const internalError = 'internal_error';

  /// 闭集全集。
  ///
  /// 顺序固定为服务端 JSON 的顺序，但消费方**不要**依赖顺序做逻辑
  /// （对拍测试只断言集合相等 + 逐条 `retryable` 一致）。
  static const all = <String>[
    oomKill,
    upstreamRateLimited,
    upstreamError,
    timeoutInactivity,
    timeoutHard,
    turnStalled,
    internalError,
  ];

  /// 已知 `code` 的表现位表（`retryable` 对齐服务端 `chatbus.Retryable`）。
  static const _traits = <String, ErrorCodeTraits>{
    oomKill: ErrorCodeTraits(
      retryable: false,
      icon: ErrorCodeIcon.memory,
      label: '内存不足',
    ),
    upstreamRateLimited: ErrorCodeTraits(
      retryable: true,
      icon: ErrorCodeIcon.rateLimited,
      label: '上游限流',
    ),
    upstreamError: ErrorCodeTraits(
      retryable: true,
      icon: ErrorCodeIcon.server,
      label: '模型服务错误',
    ),
    timeoutInactivity: ErrorCodeTraits(
      retryable: true,
      icon: ErrorCodeIcon.timeout,
      label: '长时间无进展',
    ),
    timeoutHard: ErrorCodeTraits(
      retryable: true,
      icon: ErrorCodeIcon.timeout,
      label: '本轮超时',
    ),
    turnStalled: ErrorCodeTraits(
      retryable: true,
      icon: ErrorCodeIcon.interrupted,
      label: '执行中断',
    ),
    internalError: ErrorCodeTraits(
      retryable: false,
      icon: ErrorCodeIcon.server,
      label: '内部错误',
    ),
  };

  /// `code` 是否在闭集内（`null` / 空串 / 未知值都返回 false）。
  static bool isKnown(String? code) =>
      code != null && _traits.containsKey(code);

  /// 取表现位。未知 / 缺失 `code` 返回 [ErrorCodeTraits.failOpen]。
  static ErrorCodeTraits traits(String? code) =>
      _traits[code] ?? ErrorCodeTraits.failOpen;
}
