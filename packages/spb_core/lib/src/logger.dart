/// 极简结构化日志。
///
/// WHY 不引第三方日志包：目前只需要「分级 + 可插拔 sink」，引包会带进
/// 一层不必要的依赖与 API 面。等到需要文件轮转 / 上报时再替换。
///
/// 与 Go API 的 slog 字段约定对齐（`level` / `message` / `service` / `request_id`），
/// 便于把客户端日志与服务端日志在 logs-collector 里串联。
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

/// 全局日志入口。
///
/// 有意设计为可变单例：日志需要能在任意层级（含无 DI 的纯函数）取到。
/// 生命周期在 `main()` 里初始化一次，测试中替换为 [NullLogSink]。
class SpbLog {
  SpbLog._();

  static LogSink _sink = const ConsoleLogSink();
  static LogLevel _minLevel = LogLevel.info;

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
    if (level.severity < _minLevel.severity) return;
    _sink.write(level, message, fields);
  }
}
