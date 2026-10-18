/// 上下文用量与费用快照（由 `context_update` 事件归一化而来）。
///
/// ## 它解决什么问题
///
/// 长对话会逼近模型上下文窗口，服务端在压缩（compaction）与每轮收尾时都会
/// 通过 `context_update` 播报「当前占用了多少 token / 窗口多大」。没有它，
/// 用户只能从「回复突然变短」反推上下文被压缩了。
///
/// ## ⚠️ 契约漂移：webapp 解析的形状与 Go 实际发射的形状**不是同一个**
///
/// 服务端（Go）从 `internal/chatexec/pigo_core.go` 发射的 payload **只有两种**：
///
/// | 形态 | payload | 何时 |
/// |---|---|---|
/// | 遥测 | `{telemetry: {turns, truncation_count, compaction_count, context_utilization, context_tokens, context_window, tool_durations_ms}}` | 每轮 pigo 运行收尾 |
/// | 压缩 | `{compaction: {status, reason, tokens_before, tokens_after?, summarized_count?, kept_count?, error?}}` | 上下文压缩开始/完成 |
///
/// 而 `apps/webapp` 的 `use-workbench-state.ts` 解析的是
/// `payload.context.{used, size, remaining, cost:{amount, currency}}` —— 那是
/// **遗留 Python** 编排器的形状（见 `apps/orchestrator/.../data_helpers.py`）。
/// Go 侧全仓 `grep '"used"'` 零命中，故 webapp 的 `contextUsage` 对 Go 后端
/// **恒为 null**（死代码）。
///
/// 本模型因此**两种形状都解析**：Go 的 `telemetry` / `compaction` 是当前唯一
/// 活着的来源，`context` 留给向前兼容与 webapp 对齐。**不要**只抄 webapp 的
/// 解析——那会复刻一个永不亮起的 UI。
///
/// ## 费用：Go 从不发射
///
/// Go 侧没有 `cost` / `currency` 的任何产出点（全仓 grep 零命中）。故 [cost]
/// 在 Go 后端上**恒为 null**——UI 必须容忍它缺失，**不得**用 0 或默认币种伪造。
class ContextUsage {
  const ContextUsage({this.used, this.size, this.remaining, this.cost});

  /// 已占用 token 数（Go：`telemetry.context_tokens`，或压缩的
  /// `tokens_after` / `tokens_before`）。
  ///
  /// 为 null 表示本条事件没带这个信息（**不是** 0）——调用方应保留上一次的
  /// 已知值（见 [mergedWith]），不要用 0 覆盖。
  final int? used;

  /// 上下文窗口总 token 数（Go：`telemetry.context_window`）。
  ///
  /// 为 null 表示未知（例如只有压缩事件时）。
  final int? size;

  /// 剩余可用 token 数。
  ///
  /// 优先取 payload 显式给的 `remaining`（遗留 `context` 形状）；缺失时在
  /// [used] 与 [size] 都已知的前提下由 `size - used` 推出（Go 形状）。
  final int? remaining;

  /// 费用（Go 后端恒为 null，见类文档）。
  final ContextCost? cost;

  /// 是否至少有一个可展示的字段（全空时 UI 不应渲染）。
  bool get hasData => used != null || size != null || remaining != null;

  /// 上下文占用率（0.0–1.0）；[used] / [size] 任一缺失或窗口非正时为 null。
  ///
  /// 由 [used] / [size] 现算，而非直接用 Go 的 `context_utilization`——两者
  /// 在异常载荷下可能不一致，现算保证「显示的分子分母」与「占用率」自洽。
  double? get utilization {
    final u = used;
    final s = size;
    if (u == null || s == null || s <= 0) return null;
    return u / s;
  }

  /// 用更新的一条快照覆盖本快照，**逐字段合并**。
  ///
  /// ## 为什么是合并而不是整体替换
  ///
  /// 同一个 turn 内 `telemetry` 与 `compaction` 会交替到达，各自只带部分字段：
  /// 压缩事件只有 token 数、没有窗口大小。整体替换会让「压缩完成后窗口大小
  /// 丢失」，UI 从「12K / 200K」退化成「12K / ?」。合并保留各自的已知信息。
  ///
  /// 语义是「[newer] 的非空字段胜出，空字段沿用旧值」——[newer] 里显式为 null
  /// 的字段**不代表**服务端说「该值不存在」，只代表这条事件没带它。
  ContextUsage mergedWith(ContextUsage newer) {
    final mergedUsed = newer.used ?? used;
    final mergedSize = newer.size ?? size;
    // remaining 的优先级：newer 显式值 > 旧显式值 > 由合并后的 used/size 推导。
    //
    // ⚠️ 不能沿用旧 remaining 了事：used/size 更新后旧的 remaining 就过期了
    // （例如 used 从 1000 涨到 5000，旧的 remaining 仍按 1000 算）。
    final int? mergedRemaining;
    if (newer.remaining != null) {
      mergedRemaining = newer.remaining;
    } else if (newer.used != null && mergedSize != null) {
      // 本次带新的 used：remaining 必须跟着重算，旧值作废。
      mergedRemaining = mergedSize - newer.used!;
    } else if (newer.size != null && mergedUsed != null) {
      mergedRemaining = newer.size! - mergedUsed;
    } else {
      mergedRemaining = remaining;
    }
    return ContextUsage(
      used: mergedUsed,
      size: mergedSize,
      remaining: mergedRemaining,
      cost: newer.cost ?? cost,
    );
  }

  /// 从 `context_update` 的 payload 解析。
  ///
  /// 返回 null 表示本 payload 没有任何可识别的用量字段（异常载荷，调用方应
  /// 保留上一次快照而非清空）。
  ///
  /// ## 支持的三种形状
  ///
  /// 1. Go `telemetry`：`{context_tokens, context_window, context_utilization}`
  /// 2. Go `compaction`：`{tokens_before, tokens_after}`
  /// 3. 遗留 `context`（webapp 解析的那份）：`{used, size, remaining, cost}`
  ///
  /// 另容忍扁平写法（`context_tokens_used` / `token_used` / `used` 等），
  /// 与 webapp debug 页的 `tokenUsage` 提取口径一致。
  static ContextUsage? fromEventPayload(Map<String, dynamic> payload) {
    // 逐层下钻：优先取嵌套的 telemetry / compaction / context。
    final telemetry = _map(payload, 'telemetry');
    final compaction = _map(payload, 'compaction');
    final legacy = _map(payload, 'context');

    int? used;
    int? size;
    int? remaining;
    ContextCost? cost;

    // ---------- 1. Go telemetry ----------
    if (telemetry != null) {
      used = _int(telemetry, const ['context_tokens', 'contextTokens']);
      size = _int(telemetry, const ['context_window', 'contextWindow']);
    }

    // ---------- 2. Go compaction ----------
    if (compaction != null) {
      // 完成时 tokens_after 是压缩后的新用量；started 时只有 tokens_before
      // （那是「即将被压缩」的当前用量，同样是有效观测值）。
      used ??= _int(compaction, const ['tokens_after', 'tokensAfter']);
      used ??= _int(compaction, const ['tokens_before', 'tokensBefore']);
    }

    // ---------- 3. 遗留 context 形状 ----------
    if (legacy != null) {
      used ??= _int(legacy, const ['used']);
      size ??= _int(legacy, const ['size']);
      remaining ??= _int(legacy, const ['remaining']);
      final costRaw = _map(legacy, 'cost');
      if (costRaw != null) {
        cost = ContextCost.fromMap(costRaw);
      }
    }

    // ---------- 4. 扁平兜底（webapp debug 页口径）----------
    used ??= _int(payload, const ['context_tokens_used', 'token_used', 'used']);
    size ??= _int(payload, const ['context_tokens_size', 'token_size', 'size']);
    remaining ??= _int(payload, const ['remaining']);
    if (cost == null) {
      // 扁平形态下 cost 可能是数字，currency 是同级字符串。
      final amount = _double(payload['cost']);
      if (amount != null) {
        cost = ContextCost(
          amount: amount,
          currency: _string(payload['currency']) ?? 'USD',
        );
      }
    }

    // ---------- 推导：remaining / size ----------
    if (remaining == null && used != null && size != null) {
      remaining = size - used;
    }
    // size 缺失但给了占用率：size = used / utilization（telemetry 的一种降级）。
    if (size == null && used != null) {
      final util =
          _double(telemetry?['context_utilization']) ??
          _double(telemetry?['contextUtilization']);
      if (util != null && util > 0) {
        size = (used / util).round();
        remaining ??= size - used;
      }
    }

    if (used == null && size == null && remaining == null && cost == null) {
      return null;
    }
    return ContextUsage(
      used: used,
      size: size,
      remaining: remaining,
      cost: cost,
    );
  }

  // ---------- 内部辅助 ----------

  /// 取嵌套 Map；非 Map（含 null）返回 null。
  static Map<String, dynamic>? _map(Map<String, dynamic> src, String key) {
    final v = src[key];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
    return null;
  }

  /// 按候选键顺序取第一个可解析为 int 的值。
  ///
  /// 用**候选列表**而非固定键名：Go 与遗留形状的键名不同，且 snake/camel 两种
  /// 序列化点都可能出现（见 `ChatEvent.fromJson` 的双形态说明）。
  static int? _int(Map<String, dynamic> src, List<String> keys) {
    for (final k in keys) {
      final v = src[k];
      if (v is int) return v;
      if (v is num) return v.round();
      if (v is String) {
        final parsed = int.tryParse(v) ?? double.tryParse(v)?.round();
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static double? _double(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static String? _string(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    return null;
  }

  @override
  String toString() =>
      'ContextUsage(used=$used, size=$size, remaining=$remaining'
      '${cost != null ? ', cost=$cost' : ''})';
}

/// 费用（`context_update` 的 `cost`）。
///
/// ⚠️ Go 后端**从不发射**它（全仓无 `cost` / `currency` 产出点），故实际运行时
/// 恒为 null。保留该类型是为与 webapp 的 `ContextUsage.cost` 对齐，以及将来
/// 服务端补上费用播报时无需改客户端契约。
class ContextCost {
  const ContextCost({required this.amount, this.currency = 'USD'});

  /// 金额。
  final double amount;

  /// 币种（ISO 4217，如 `USD`）。缺省 `USD` 与 webapp 的兜底一致。
  final String currency;

  /// 从 `{amount, currency}` 解析；`amount` 无法解析为数字时返回 null。
  static ContextCost? fromMap(Map<String, dynamic> src) {
    final amount = ContextUsage._double(src['amount']);
    if (amount == null) return null;
    return ContextCost(
      amount: amount,
      currency: ContextUsage._string(src['currency']) ?? 'USD',
    );
  }

  @override
  String toString() => 'ContextCost($amount $currency)';
}
