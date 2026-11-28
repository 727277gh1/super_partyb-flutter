part of 'habit.dart';

/// 触发类型（`trigger_type`）。
///
/// 真源：`workers/habit/trigger_type.go`。
enum HabitTriggerType {
  /// 按时间（hour/minute/times/weekday）。
  timeBased('time_based', '定时'),

  /// 持续盯梢（cadence/stop，指数退避）。
  watch('watch', '盯梢'),

  /// 事件驱动（当前无内置产出者，保留枚举值）。
  eventBased('event_based', '事件'),

  unknown('', '未知');

  const HabitTriggerType(this.wire, this.label);

  final String wire;
  final String label;

  static HabitTriggerType from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 接受级别（`acceptance_level`）。
enum HabitAcceptanceLevel {
  /// 自动执行，不询问。
  autoRun('auto_run', '自动执行'),

  /// 需要确认后执行。
  confirmRequired('confirm_required', '需确认'),

  /// 只建议，不执行。
  suggestOnly('suggest_only', '仅建议'),

  unknown('', '未知');

  const HabitAcceptanceLevel(this.wire, this.label);

  final String wire;
  final String label;

  static HabitAcceptanceLevel from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 规则状态（`status`）。
///
/// 只有 [active] 会被调度器拾取（`due_rule.go`）。
enum HabitPatternStatus {
  active('active', '生效中'),
  paused('paused', '已暂停'),
  suggested('suggested', '待确认'),
  archived('archived', '已归档'),
  unknown('', '未知');

  const HabitPatternStatus(this.wire, this.label);

  final String wire;
  final String label;

  static HabitPatternStatus from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 规则来源（`source_type`）。
enum HabitSourceType {
  manual('manual', '手动创建'),
  learned('learned', '自动学习'),
  memory('memory', '记忆抽取'),
  suggestion('suggestion', '建议采纳'),
  unknown('', '未知');

  const HabitSourceType(this.wire, this.label);

  final String wire;
  final String label;

  static HabitSourceType from(String? raw) {
    for (final v in values) {
      if (v.wire.isNotEmpty && v.wire == raw) return v;
    }
    return unknown;
  }
}

/// 时间型触发配置（`trigger_config_json` 中 time_based 的部分）。
///
/// ## 关键陷阱：写入侧存复数，读取侧只认单数
///
/// `NormalizeTriggerConfig`（`workers/habit/trigger_config.go`）在**写入时**
/// 把 `weekdays`（复数）归一成 `weekday`（单数），并让顶层 `hour`/`minute`
/// 镜像 `times[0]`。但历史数据（或未经归一化的路径）仍可能只有复数键，
/// 故这里两个键都读，且顶层 hour/minute 与 times[0] 也互为兜底。
///
/// [times] 为空时，[firstHour]/[firstMinute] 回退到顶层 `hour`/`minute`
/// （那些顶层值是 `NormalizeTriggerConfig` 写的影子字段）。
class HabitTimeTriggerConfig {
  const HabitTimeTriggerConfig({
    this.times = const [],
    this.weekdays = const [],
    this.hour,
    this.minute,
    this.mode,
  });

  /// 触发时刻列表（`times[]`，每项 `{hour, minute}`）。
  final List<HabitTimeOfDay> times;

  /// 星期（1=周一 … 7=周日）。空表示每天。
  final List<int> weekdays;

  /// 顶层影子 hour（`times` 为空时的兜底）。
  final int? hour;

  /// 顶层影子 minute。
  final int? minute;

  /// 触发模式（如 `weekly`），可选。
  final String? mode;

  bool get isEmpty => times.isEmpty && weekdays.isEmpty && hour == null;

  /// 首个触发时刻：优先 `times[0]`，回退顶层 hour/minute。
  int? get firstHour => times.isNotEmpty ? times.first.hour : hour;

  int? get firstMinute => times.isNotEmpty ? times.first.minute : minute;

  /// 人类可读摘要，如「每周一、三 09:00」或「每天 09:00」。
  String get summary {
    final h = firstHour;
    if (h == null) return '未配置触发时间';
    final m = firstMinute ?? 0;
    final clock =
        '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
    if (weekdays.isEmpty) return '每天 $clock';
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    final days = weekdays
        .where((d) => d >= 1 && d <= 7)
        .map((d) => names[d - 1])
        .join('、');
    return days.isEmpty ? '每天 $clock' : '每周$days $clock';
  }

  static HabitTimeTriggerConfig fromJson(Map<String, dynamic> json) {
    final timesRaw = json['times'];
    final times = <HabitTimeOfDay>[];
    if (timesRaw is List) {
      for (final e in timesRaw) {
        if (e is Map) {
          times.add(HabitTimeOfDay.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    // 单数优先，复数兜底（写入侧已归一，但历史数据可能只有复数）。
    final wd = json['weekday'] ?? json['weekdays'];
    final weekdays = <int>[];
    if (wd is List) {
      for (final e in wd) {
        final n = e is int ? e : (e is num ? e.toInt() : int.tryParse('$e'));
        if (n != null) weekdays.add(n);
      }
    } else if (wd is int) {
      weekdays.add(wd);
    }
    final hour = habitInt(json, 'hour', 'hour');
    final minute = habitInt(json, 'minute', 'minute');
    return HabitTimeTriggerConfig(
      times: List.unmodifiable(times),
      weekdays: List.unmodifiable(weekdays),
      hour: hour,
      minute: minute,
      mode: habitStr(json, 'mode', 'mode'),
    );
  }

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{};
    if (times.isNotEmpty) {
      out['times'] = times.map((t) => t.toJson()).toList();
    }
    if (weekdays.isNotEmpty) out['weekday'] = weekdays;
    if (hour != null) out['hour'] = hour;
    if (minute != null) out['minute'] = minute;
    if (mode != null) out['mode'] = mode;
    return out;
  }
}

/// `times[]` 里的一项。
class HabitTimeOfDay {
  const HabitTimeOfDay({required this.hour, this.minute = 0});

  final int hour;
  final int minute;

  String get label =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  static HabitTimeOfDay fromJson(Map<String, dynamic> json) => HabitTimeOfDay(
    hour: habitInt(json, 'hour', 'hour') ?? 0,
    minute: habitInt(json, 'minute', 'minute') ?? 0,
  );

  Map<String, dynamic> toJson() => {'hour': hour, 'minute': minute};
}

/// 盯梢型触发配置（`trigger_config_json` 中 watch 的部分）。
///
/// 真源：`workers/habit/watch_backoff.go` 的 `parseWatchCadence` 与
/// `watch_extract.go` 的 `WatchTriggerConfig`。
///
/// 默认值（服务端在字段缺失时套用）：initial_seconds=3600、factor=2.0、
/// max_seconds=86400、max_no_change=10。
class HabitWatchTriggerConfig {
  const HabitWatchTriggerConfig({
    this.initialSeconds = defaultInitialSeconds,
    this.factor = defaultFactor,
    this.maxSeconds = defaultMaxSeconds,
    this.maxNoChange = defaultMaxNoChange,
    this.expiresAt,
  });

  /// 首触发（及清零后）的间隔秒数（默认 3600）。
  static const int defaultInitialSeconds = 3600;
  static const double defaultFactor = 2.0;
  static const int defaultMaxSeconds = 86400;
  static const int defaultMaxNoChange = 10;

  final int initialSeconds;
  final double factor;
  final int maxSeconds;

  /// 连续无变化达到该轮数则自动 paused；**<0 表示关闭该限制**。
  ///
  /// ⚠️ 显式 `0` 是合法值（第一次无变化就停），与「缺失」不同——
  /// `parseWatchCadence` 用 `*int` 区分两者。
  final int maxNoChange;

  /// 停止盯梢的时刻（RFC3339），null = 不过期。
  final String? expiresAt;

  /// 人类可读摘要，如「每 1 小时后检查，最长 1 天」。
  String get summary {
    final base = _durationLabel(initialSeconds);
    if (maxSeconds > initialSeconds) {
      return '每 $base 起，最长间隔 ${_durationLabel(maxSeconds)}';
    }
    return '每 $base 检查一次';
  }

  static String _durationLabel(int seconds) {
    if (seconds % 86400 == 0) return '${seconds ~/ 86400} 天';
    if (seconds % 3600 == 0) return '${seconds ~/ 3600} 小时';
    if (seconds % 60 == 0) return '${seconds ~/ 60} 分钟';
    return '$seconds 秒';
  }

  static HabitWatchTriggerConfig fromJson(Map<String, dynamic> json) {
    final cadence = habitMap(json, 'cadence', 'cadence');
    final stop = habitMap(json, 'stop', 'stop');
    return HabitWatchTriggerConfig(
      initialSeconds:
          habitInt(cadence, 'initial_seconds', 'initial_seconds') ??
          defaultInitialSeconds,
      factor: habitDouble(cadence, 'factor', 'factor') ?? defaultFactor,
      maxSeconds:
          habitInt(cadence, 'max_seconds', 'max_seconds') ?? defaultMaxSeconds,
      // 注意用 containsKey 语义：显式 0 必须保留，不能走 `?? default`。
      maxNoChange:
          habitInt(stop, 'max_no_change', 'max_no_change') ??
          defaultMaxNoChange,
      expiresAt: habitStr(stop, 'expires_at', 'expires_at'),
    );
  }

  Map<String, dynamic> toJson() => {
    'cadence': {
      'initial_seconds': initialSeconds,
      'factor': factor,
      'max_seconds': maxSeconds,
    },
    'stop': {
      'max_no_change': maxNoChange,
      if (expiresAt != null) 'expires_at': expiresAt,
    },
  };
}

/// 触发配置的**联合视图**：按 `trigger_type` 分派到时间型或盯梢型。
///
/// 保留 [raw] 以便编辑时原样回传未知键（服务端 `NormalizeTriggerConfig`
/// 明确保留未知键，客户端不应把它们吃掉）。
class HabitTriggerConfig {
  const HabitTriggerConfig({
    required this.triggerType,
    this.time,
    this.watch,
    this.raw = const {},
  });

  final HabitTriggerType triggerType;
  final HabitTimeTriggerConfig? time;
  final HabitWatchTriggerConfig? watch;

  /// 原始 JSON（含客户端不认识的键）。
  ///
  /// 注意它**只反映「从 JSON 解析而来」的那部分**：客户端手工构造配置
  /// （如编辑器里新建）时 [raw] 是空的，但那不是「无配置」。
  final Map<String, dynamic> raw;

  /// 是否没有任何触发条件。
  ///
  /// ⚠️ **不能写成 `raw.isEmpty`**：那对从 JSON 解析来的配置正确，但对客户端
  /// 手工构造的配置恒为 true——UI 会把用户刚配好的「每周一 9:00」显示成
  /// 「未配置触发条件」。判断依据必须是分派后的具体形状。
  bool get isEmpty {
    if (triggerType == HabitTriggerType.watch) {
      return watch == null;
    }
    final t = time;
    return t == null || t.isEmpty;
  }

  /// 一行摘要。
  String get summary {
    if (triggerType == HabitTriggerType.watch) {
      final w = watch;
      return w == null ? '未配置触发条件' : w.summary;
    }
    final t = time;
    if (t == null || t.isEmpty) return '未配置触发条件';
    return t.summary;
  }

  /// 从 `trigger_config_json` 的**字符串**解析（服务端该列是 TEXT）。
  static HabitTriggerConfig fromJsonString(
    String? jsonString, {
    String? triggerTypeRaw,
  }) {
    final map = _decodeJsonObject(jsonString);
    return fromJson(map, triggerTypeRaw: triggerTypeRaw);
  }

  static HabitTriggerConfig fromJson(
    Map<String, dynamic> json, {
    String? triggerTypeRaw,
  }) {
    // trigger_type 可能嵌在 config 内（`WatchTriggerConfig` 会写入该键），
    // 也可能在 pattern 顶层——后者优先（真源是 pattern 列）。
    final type = HabitTriggerType.from(
      triggerTypeRaw ??
          habitStr(json, 'trigger_type', 'trigger_type') ??
          habitStr(json, 'triggerType', 'triggerType'),
    );
    final isWatch = type == HabitTriggerType.watch || json['cadence'] != null;
    return HabitTriggerConfig(
      triggerType: isWatch ? HabitTriggerType.watch : type,
      time: isWatch ? null : HabitTimeTriggerConfig.fromJson(json),
      watch: isWatch ? HabitWatchTriggerConfig.fromJson(json) : null,
      raw: Map.unmodifiable(json),
    );
  }

  /// 提交给服务端的形状（服务端会再跑一次 `NormalizeTriggerConfig`）。
  Map<String, dynamic> toJson() {
    if (triggerType == HabitTriggerType.watch) {
      final w = watch ?? const HabitWatchTriggerConfig();
      return {...raw, ...w.toJson()};
    }
    final t = time ?? const HabitTimeTriggerConfig();
    return {...raw, ...t.toJson()};
  }
}

Map<String, dynamic> _decodeJsonObject(String? s) {
  if (s == null || s.trim().isEmpty) return const {};
  try {
    final v = jsonDecode(s);
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return Map<String, dynamic>.from(v);
  } on FormatException {
    // 服务端也可能存了非法 JSON（`NormalizeTriggerConfig` 会原样返回并报错）。
    // 客户端按「无配置」处理，不抛。
  }
  return const {};
}
