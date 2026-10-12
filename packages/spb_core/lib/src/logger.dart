/// 极简结构化日志。
///
/// WHY 不引第三方日志包：目前只需要「分级 + 可插拔 sink」，引包会带进
/// 一层不必要的依赖与 API 面。等到需要文件轮转 / 上报时再替换。
///
/// 与 Go API 的 slog 字段约定对齐（`level` / `message` / `service` / `request_id`），
/// 便于把客户端日志与服务端日志在 logs-collector 里串联。
///
/// ## 内存环形缓冲（issue #40）
///
/// [SpbLog] 除转发给 sink 外，还**始终**在内存里保留最近
/// [SpbLog.recentLogCapacity] 条日志，供「导出诊断日志」使用。
/// 见 [buildDiagnosticsReport] / [redactSecrets]。
library;

enum LogLevel {
  debug(10, 'DEBUG'),
  info(20, 'INFO'),
  warn(30, 'WARN'),
  error(40, 'ERROR');

  const LogLevel(this.severity, this.label);

  final int severity;
  final String label;
}

/// 日志接收器。实现方可写入文件、控制台或上报服务。
abstract interface class LogSink {
  void write(LogLevel level, String message, Map<String, Object?> fields);
}

/// 控制台 sink（默认）。
class ConsoleLogSink implements LogSink {
  const ConsoleLogSink();

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {
    final buf = StringBuffer()
      ..write('[')
      ..write(level.label)
      ..write('] ')
      ..write(message);
    if (fields.isNotEmpty) {
      buf.write(' ');
      buf.write(fields.entries.map((e) => '${e.key}=${e.value}').join(' '));
    }
    // ignore: avoid_print
    print(buf.toString());
  }
}

/// 丢弃所有日志（测试用）。
class NullLogSink implements LogSink {
  const NullLogSink();

  @override
  void write(LogLevel level, String message, Map<String, Object?> fields) {}
}

/// 一条**已记录**的日志（含时间戳）。
///
/// ## 为什么单独一个类型，而不是存 `(level, message, fields)` 三元组
///
/// 诊断报告需要**时间戳**（「什么时候开始出问题的」是报障的第一问），而
/// [LogSink.write] 的签名里没有它——时间戳由 [SpbLog] 在记录时补上。
/// 存裸元组的话，调用方就得记住「第几个位置是时间」。
class LogRecord {
  const LogRecord({
    required this.timestamp,
    required this.level,
    required this.message,
    required this.fields,
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;
  final Map<String, Object?> fields;

  /// 单行文本形态（诊断报告用）。
  ///
  /// ## 为什么强制单行
  ///
  /// 诊断文本会被用户贴进 issue / 聊天窗口。若堆栈里的换行原样输出，一条
  /// 日志会变成几十行，读者会把堆栈的第 2 行误当成「又一条日志」。故字段值
  /// 里的换行统一转义成字面量 `\n`，保证「一条日志 = 一行」。
  String format() {
    final buf = StringBuffer()
      ..write(timestamp.toIso8601String())
      ..write(' ')
      ..write(level.label.padRight(5))
      ..write(' ')
      ..write(_escapeNewlines(message));
    for (final entry in fields.entries) {
      buf
        ..write(' ')
        ..write(entry.key)
        ..write('=')
        ..write(_formatFieldValue(entry.value));
    }
    return buf.toString();
  }

  @override
  String toString() => format();
}

/// 把字段值渲染成单个词元。含空格时加引号，便于人读时区分边界。
String _formatFieldValue(Object? value) {
  if (value == null) return 'null';
  final text = _escapeNewlines(value.toString());
  return text.contains(' ') ? '"$text"' : text;
}

/// 换行转义（含 Windows 的 `\r\n` 与裸 `\r`）。
String _escapeNewlines(String text) => text
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\n');

/// 全局日志入口。
///
/// 有意设计为可变单例：日志需要能在任意层级（含无 DI 的纯函数）取到。
/// 生命周期在 `main()` 里初始化一次，测试中替换为 [NullLogSink]。
class SpbLog {
  SpbLog._();

  static LogSink _sink = const ConsoleLogSink();
  static LogLevel _minLevel = LogLevel.info;

  /// 内存里保留的日志条数上限。
  ///
  /// ## 为什么是「环形」而不是「全留」
  ///
  /// 桌面端是常驻进程（关窗只隐藏到托盘），跑一周能产生几十万条日志。诊断只
  /// 需要「最近发生了什么」，全留会让内存随运行时长线性增长——而这是用户
  /// **看不见**的泄漏。500 条按每条约 100 字节算不到 100 KB，可忽略。
  static const int recentLogCapacity = 500;

  /// 环形缓冲本体。用 `List` + 手动裁剪而非 `Queue`：条数上限 500，
  /// `removeRange(0, 1)` 的搬移成本可忽略，换来的是「可按下标读」的简单语义。
  static final List<LogRecord> _recent = <LogRecord>[];

  /// 最近记录的日志（最旧在前，最新在后）。返回**只读视图**。
  ///
  /// 只读是刻意的：调用方若能在报告生成前删改条目，「导出」出来的就不是
  /// 真实发生过的事。
  static List<LogRecord> get recentLogs =>
      List<LogRecord>.unmodifiable(_recent);

  /// 清空环形缓冲。
  ///
  /// **测试专用**（本包无 `meta` 依赖，故不加注解）：全局单例的缓冲会在
  /// 用例之间累积，断言「缓冲里有什么」之前必须先清。生产代码不应调用它
  /// ——那会让「导出诊断日志」导出空报告。
  static void clearRecentLogs() => _recent.clear();

  /// 替换 sink。返回旧 sink，便于测试后恢复。
  static LogSink configure({required LogSink sink, LogLevel? minLevel}) {
    final old = _sink;
    _sink = sink;
    if (minLevel != null) _minLevel = minLevel;
    return old;
  }

  static void debug(String message, [Map<String, Object?> fields = const {}]) =>
      _log(LogLevel.debug, message, fields);

  static void info(String message, [Map<String, Object?> fields = const {}]) =>
      _log(LogLevel.info, message, fields);

  static void warn(String message, [Map<String, Object?> fields = const {}]) =>
      _log(LogLevel.warn, message, fields);

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> fields = const {},
  }) {
    final enriched = <String, Object?>{
      ...fields,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stack': stackTrace.toString(),
    };
    _log(LogLevel.error, message, enriched);
  }

  static void _log(
    LogLevel level,
    String message,
    Map<String, Object?> fields,
  ) {
    // ⚠️ 阈值过滤在**记录之前**。故「导出诊断日志」只能包含通过阈值的内容
    // ——想让报告带上 debug 细节，得用 `--dart-define=SPB_VERBOSE_LOG=true`
    // 构建，而不是期待导出时能补回来。这是刻意的：报告必须与运行时实际
    // 可见的日志一致，否则「日志里没有」会被误读成「没发生」。
    if (level.severity < _minLevel.severity) return;

    _recent.add(
      LogRecord(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        // 复制一份：调用方可能复用同一个可变 Map（见 logger_test 的
        // 「不被调用方传入的 Map 污染」）。缓冲里的历史记录必须定格。
        fields: Map<String, Object?>.unmodifiable(fields),
      ),
    );
    if (_recent.length > recentLogCapacity) {
      _recent.removeRange(0, _recent.length - recentLogCapacity);
    }

    _sink.write(level, message, fields);
  }
}

// ===========================================================================
// 诊断报告（issue #40）
// ===========================================================================
//
// ## 为什么需要它
//
// 客户端此前**没有任何远程日志通道**，用户报障时除了「它不工作」没有别的
// 信息。而本机开发环境（无 DISPLAY、无 /dev/kvm）恰好无法验证最容易出
// 平台特异性问题的部分（多窗口、托盘、Alt+Space、OIDC 回跳、交付物同步，
// 见 AGENTS.md §9）——只能靠用户描述。
//
// 第一层（本次实现）不做任何上报：把环境信息与最近日志拼成一份**文本**，
// 让用户手动附给报障。无第三方服务、无网络、无隐私评审负担。
//
// 崩溃上报（第三方 crash reporter / 复用 logs-collector）与 `integration_test/`
// 是 issue #40 的第二、三层，**有意未做**。

/// 掩码疑似凭据。
///
/// ## 为什么导出时还要再掩一次（日志侧本就不该记凭证）
///
/// 日志侧的克制确实存在（见 `spb_api` 的 `session_credential.dart`：
/// 「本函数**绝不记录 token 值**」），但那是**约定**，不是机制。诊断报告会被
/// 用户贴进公开 issue / 聊天窗口，一份泄漏的凭证无法收回。故导出前做**最后
/// 一道**基于形态的掩码：
///
/// - 不依赖「谁记了什么」——将来有人不小心把 header 打进日志，这里仍然拦住；
/// - 按**形态**（`Bearer xxx`、`key=value`、JWT、已知前缀）而非关键词黑名单，
///   避免把无辜文本（如「收到 401，会话凭证可能已失效」）也一起抹掉。
///
/// ⚠️ 掩码只保留键名（如 `Authorization=***`），因为「哪个字段被掩了」本身
/// 就是诊断信息。
String redactSecrets(String text) {
  var out = text;
  // 1) `Bearer <token>`——整体抹掉，连 `Bearer` 一词一起，避免后续
  //    key-value 规则只吃掉 `Bearer` 而把 token 留在原地。
  out = out.replaceAll(_bearerRe, '***');
  // 2) JWT（三段 base64url）。`eyJ` 是 `{"` 的 base64 前缀，命中率极高。
  out = out.replaceAll(_jwtRe, '***');
  // 3) 已知前缀的长期令牌（OpenAI / GitHub / Slack / AWS / PEM 头）。
  out = out.replaceAll(_prefixedRe, '***');
  out = out.replaceAll(_pemHeaderRe, '***');
  // 4) URL 里的 `user:pass@`。
  out = out.replaceAll(_userInfoRe, '://***@');
  // 5) `key: value` / `key=value` 形态（含 JSON 的双引号包裹）。
  out = out.replaceAllMapped(
    _credentialPairRe,
    (m) => '${m[1]}${m[2]}${m[3]}***',
  );
  return out;
}

/// `Bearer <token>`。token 至少 6 个字符，避免把英文句子里的 "bearer" 误伤。
final _bearerRe = RegExp(
  r'\bBearer\s+[A-Za-z0-9\-._~+/=]{6,}',
  caseSensitive: false,
);

/// JWT：`header.payload.signature`，三段 base64url。
final _jwtRe = RegExp(
  r'\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{2,}',
);

/// 已知前缀的长期令牌。
///
/// ⚠️ 这里**不能**在模式前加 `\b`：`-` 不是词字符，而模式开头就是 `-`，
/// 于是 `\b` 要求「前面是词字符」而永远匹配不到行首的 PEM 头（实测踩过）。
/// 故 PEM 头单独一条正则（见 [_pemHeaderRe]），本正则只留字母数字开头的
/// 令牌前缀。
final _prefixedRe = RegExp(
  r'\b(?:sk-[A-Za-z0-9_-]{10,}'
  r'|ghp_[A-Za-z0-9]{20,}'
  r'|xox[bpoa]-[A-Za-z0-9-]{8,}'
  r'|AKIA[0-9A-Z]{16})',
);

/// PEM 头（`-----BEGIN RSA PRIVATE KEY-----` 等）。
///
/// 正文是多行 base64，无法用一条正则整段匹配；抹掉头足以让人看出「这里
/// 不该有私钥」。
final _pemHeaderRe = RegExp(r'-----BEGIN[A-Z ]+-----');

/// `scheme://user:pass@host` 里的 `user:pass@`。
final _userInfoRe = RegExp(r'://[^/\s:@]+:[^/\s@]+@');

/// 凭据类键名后的值。
///
/// 分组：`1` 键名、`2` 分隔符（含其后的开引号）、`3` 值的开引号。
/// 值取到「空白 / 逗号 / 引号 / 分号 / `&`」为止——既不会吞掉同一行后续的
/// 无关字段，也不会在 JSON 里越过值的右引号。
///
/// ⚠️ 键名列表里的 `\b` 让 `access_token` **不会**被 `token` 分支命中（`_`
/// 是词字符，其与 `t` 之间没有词边界），故 `access_token` / `refresh_token`
/// 等必须逐个列出，不能只写 `token`。
// ⚠️ 这里用**非 raw** 字符串：正则里同时含 `'` 与 `"`，raw 字符串的定界符
// 与内容冲突（`r'...\'...'` 会提前结束）。非 raw 形式下 `\\` → `\`、
// `\'` → `'`，逐段拼出的模式与上面的文档一致。
final _credentialPairRe = RegExp(
  '\\b(authorization'
  '|access[_-]?token'
  '|refresh[_-]?token'
  '|id[_-]?token'
  '|api[_-]?key'
  '|apikey'
  '|client[_-]?secret'
  '|password'
  '|passwd'
  '|token'
  '|secret)'
  '(\\s*["\']?\\s*[:=]\\s*)'
  '(["\']?)'
  '([^\\s,;"\'&]+)',
  caseSensitive: false,
);

/// 组装诊断报告文本（**已脱敏**）。
///
/// [environment] 由调用方（装配层）提供：本函数在 `spb_core`（纯 Dart），拿不到
/// `FlutterVersion` / `appBuildName` 这类 Flutter 侧常量。键名与顺序由调用方
/// 决定，报告按传入顺序逐行输出。
///
/// [logs] 默认取 [SpbLog.recentLogs]。显式传入主要供测试构造确定内容。
///
/// 返回的文本**必定**经过 [redactSecrets]，调用方无需（也不应）自行拼接——
/// 见该函数的说明。
String buildDiagnosticsReport({
  required Map<String, String> environment,
  List<LogRecord>? logs,
  DateTime? generatedAt,
}) {
  final entries = logs ?? SpbLog.recentLogs;
  final at = generatedAt ?? DateTime.now();

  final buf = StringBuffer()
    ..writeln('Super PartyB 诊断报告')
    ..writeln('生成时间: ${at.toIso8601String()}')
    ..writeln()
    ..writeln('## 运行环境');

  if (environment.isEmpty) {
    buf.writeln('（未提供）');
  } else {
    for (final entry in environment.entries) {
      buf.writeln('${entry.key}: ${_escapeNewlines(entry.value)}');
    }
  }

  buf
    ..writeln()
    ..writeln('## 最近日志（${entries.length} 条，上限 ${SpbLog.recentLogCapacity}）');

  if (entries.isEmpty) {
    buf.writeln('（无）');
  } else {
    for (final record in entries) {
      buf.writeln(record.format());
    }
  }

  buf
    ..writeln()
    ..writeln('## 说明')
    ..writeln('本报告由客户端「导出诊断日志」生成，已对疑似凭据做掩码。');

  return redactSecrets(buf.toString());
}
