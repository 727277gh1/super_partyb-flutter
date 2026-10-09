/// turn 运行时参数（`GET /api/chat/turn-runtime`，只读）。
///
/// ## 它解决什么问题
///
/// 客户端需要一条「超时兜底」：距最后一条事件超过阈值仍未收到 `done` / `error`
/// 时，把流式光标停掉——否则 `done` 一旦丢失（turn worker 崩溃、长断线、
/// 回放窗口被打穿），UI 会**永久**停在流式态。
///
/// 这个阈值不能硬编码。服务端是可配置的，且生产已经调过：
/// `CHAT_TURN_REQUEST_TIMEOUT_SECONDS=600`。客户端若写 300，长 turn
/// （长思考模型 / 多轮工具调用很容易到 300~600s）会被提前判成静止，用户看到
/// 光标消失、以为已结束，实际后端还在跑。
///
/// 修法不是把 300 改成 600（下次改 env 又会漂），而是**拉取服务端生效值**。
///
/// ## 为什么只消费一个数
///
/// 「inactivity 优先、否则 request」这条解析规则收敛在服务端
/// `internal/server/chat_runtime.go` 的 `resolveClientTurnTimeout`，客户端只读
/// [clientTurnTimeoutSeconds]。规则只有一处，不会在两侧再次分叉。
///
/// ## 阈值语义是「距最后一次活动」而非「距 turn 起点」
///
/// 服务端 inactivity 看门狗的判据就是「距最后一次活动」，而活动事件
/// （`turn_activity`）与流式增量都能续期。客户端因此也必须**按事件续期**，
/// 而不是从 turn 起点计时——否则一个持续产出工具心跳的长 turn 会被误判。
class TurnRuntime {
  const TurnRuntime({
    required this.requestTimeoutSeconds,
    required this.inactivityTimeoutSeconds,
    required this.clientTurnTimeoutSeconds,
  });

  /// 单 turn 墙钟总预算（秒）。
  final int requestTimeoutSeconds;

  /// 未活动超时（秒）；`0` 表示服务端关闭了该看门狗。
  final int inactivityTimeoutSeconds;

  /// 客户端「距最后一条事件」超时兜底应使用的秒数（服务端已按 inactivity
  /// 优先解析好）。
  final int clientTurnTimeoutSeconds;

  /// 拉取失败或服务端下发不可用值时的兜底阈值。
  ///
  /// 取 5 分钟而非 0：与 Go `CHAT_TURN_REQUEST_TIMEOUT_SECONDS` 的**默认值**
  /// 一致，故在「拉不到配置」这个降级路径上仍是与后端同量级的判断。
  static const Duration fallback = Duration(minutes: 5);

  /// 阈值上限（24 小时）。
  ///
  /// 配置写错（多敲几个 0）时兜底不能变成「永不触发」——那等于没修。
  static const Duration maxTimeout = Duration(hours: 24);

  /// 服务端下发值 → 阈值；**不可用返回 null**（调用方用 [fallback]）。
  ///
  /// ## 为什么 0 / 负数必须当作「不可用」而不是「立即超时」
  ///
  /// 客户端若把 0 当阈值，会把**所有正在跑的 turn 瞬间判成静止**——比原来的
  /// 硬编码 300s 更糟。服务端 `inactivity_timeout_seconds=0` 的语义是「关闭
  /// 该看门狗」，不是「零秒超时」。
  Duration? get clientTurnTimeout {
    if (clientTurnTimeoutSeconds <= 0) return null;
    final d = Duration(seconds: clientTurnTimeoutSeconds);
    return d > maxTimeout ? maxTimeout : d;
  }

  /// 实际可用的阈值（不可用时退化为 [fallback]）。
  Duration get effectiveClientTurnTimeout => clientTurnTimeout ?? fallback;

  factory TurnRuntime.fromJson(Map<String, dynamic> json) => TurnRuntime(
    requestTimeoutSeconds: _int(json['request_timeout_seconds']),
    inactivityTimeoutSeconds: _int(json['inactivity_timeout_seconds']),
    clientTurnTimeoutSeconds: _int(json['client_turn_timeout_seconds']),
  );

  /// 取整数；非 num / 字符串数字均可解析，其余归 0。
  ///
  /// 与 `ChatTurn._int` 同一取向：JSON 解码可能给出 `double`（如 `600.0`），
  /// 异常载荷不应抛异常——本模型只服务于一条兜底阈值，坏值退化为 [fallback]
  /// 即可，不该让对话页起不来。
  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  @override
  String toString() =>
      'TurnRuntime(request=${requestTimeoutSeconds}s, '
      'inactivity=${inactivityTimeoutSeconds}s, '
      'client=${clientTurnTimeoutSeconds}s)';
}
