import 'dart:convert' show utf8;
import 'dart:io';

import 'logger.dart';

/// 把日志**追加写**到本地文件的 sink。
///
/// ## 为什么需要它（补的是「进程死了就没证据」这个洞）
///
/// 此前唯一的生产 sink 是 [ConsoleLogSink]（见 AGENTS.md §6.20）：
///
/// - 从桌面启动器 / 双击拉起的进程，stdout **无处可去**，日志直接丢失；
/// - 「导出诊断日志」要用户进设置页手动导出，**进程已退出时用不上**；
/// - [SpbLog] 的环形缓冲只在内存，进程一死全丢。
///
/// 于是「按 Alt+Space 后窗口卡住 / 应用像是退出了」这类报障只能靠用户口述。
///
/// ## 为什么每条同步写、不持有 `IOSink`
///
/// 这是本类最重要的取舍：
///
/// 1. **异步 `IOSink` 有缓冲**，而这里的进程可能被**硬杀**（崩溃 / 被窗口
///    管理器结束）。缓冲里没刷出去的那几行，恰恰是崩溃前最后发生的事——
///    也就是唯一有用的那几行。故用 `writeAsBytesSync`，一次 syscall 写完。
/// 2. **不持句柄** → 轮转时不需要重开流，也不会在「rename 之后旧 fd 仍指向
///    已改名的文件」这种经典坑里丢掉整段日志。
/// 3. 不做 `fsync`（`flush: false`，见 [write]）：进程死亡时数据已在 **OS 页
///    缓存**里，跨进程死亡是安全的；`fsync` 只对「断电」有意义，而桌面端日志
///    不值得为此付每次写盘的延迟。
///
/// ## 为什么必须脱敏
///
/// 文件日志会被用户直接贴进 issue（比诊断报告更原始）。日志侧本就不该记
/// 凭证（见 `spb_api` 的 `session_credential.dart`），但那是**约定**不是机制，
/// 故写盘前过一遍 [redactSecrets]（与「导出诊断日志」同一道防线）。
///
/// ## 为什么失败后静默停用、且不写 [SpbLog]
///
/// 本类**在 `SpbLog` 的调用链上**：`write` 里调 `SpbLog.warn` 会再次进入
/// `SpbLog._log` → 再次调本 `write` → 无限递归。故失败只：停用、记
/// [lastError]（供诊断与测试读取）、`print` 一行提示（与控制台 sink 同一
/// 出口）。停用而不是重试：磁盘满 / 只读时逐条重试只会刷屏。
class FileLogSink implements LogSink {
  FileLogSink({
    required this.path,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxFiles = 3,
    this.redact = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _size = _prepare();
  }

  /// 当前日志文件路径（`app.log`）。
  final String path;

  /// 单文件上限（字节）。<= 0 表示不轮转。
  ///
  /// 默认 2 MB：桌面端是常驻进程（关窗只隐藏到托盘），一周能产生几十万条
  /// 日志（与 AGENTS.md §6.20 里「环形缓冲为什么必须封顶」同一理由）。
  final int maxBytes;

  /// 历史文件份数（`app.log.1` … `app.log.maxFiles`）。
  ///
  /// 0 表示轮转时直接丢弃当前文件（不保留历史）。
  final int maxFiles;

  /// 写盘前是否过 [redactSecrets]（默认开；测试里可关以断言原文）。
  final bool redact;

  final DateTime Function() _clock;

  /// 当前文件已写入字节数（内存计数，避免每条都 stat）。
  int _size = 0;

  bool _disabled = false;
  Object? _lastError;

  /// 已写入的条数（测试与诊断用）。
  int get writes => _writes;
  int _writes = 0;

  /// 是否已因写失败而停用。
  bool get isDisabled => _disabled;

  /// 最近一次写失败的原因（未失败为 null）。
  Object? get lastError => _lastError;

  /// 当前文件的预估字节数。
  int get size => _size;

  /// 建目录 + 读现有文件长度。返回初始 [size]；失败时停用并返回 0。
  int _prepare() {
    try {
      final dir = File(path).parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (e) {
      _disabled = true;
      _lastError = e;
      return 0;
    }
  }

  @override
  void write(
    LogLevel level,
    String message, [
    Map<String, Object?> fields = const {},
  ]) {
    if (_disabled) return;

    // 复用 [LogRecord.format]：文件日志与诊断报告的**行格式完全一致**，
    // 用户贴日志 / 导出报告时不必换算。
    final line = LogRecord(
      timestamp: _clock(),
      level: level,
      message: message,
      fields: fields,
    ).format();

    try {
      final bytes = utf8.encode('${redact ? redactSecrets(line) : line}\n');
      if (maxBytes > 0 && _size > 0 && _size + bytes.length > maxBytes) {
        _rotate();
      }
      File(path).writeAsBytesSync(bytes, mode: FileMode.append);
      _size += bytes.length;
      _writes++;
    } catch (e) {
      _disabled = true;
      _lastError = e;
      // 不能走 SpbLog（递归，见类文档）；与 ConsoleLogSink 同一出口。
      // ignore: avoid_print
      print('[WARN] 文件日志写入失败，已停用: $path ($e)');
    }
  }

  /// 轮转：`app.log` → `app.log.1` → … → `app.log.maxFiles`（最旧的丢弃）。
  void _rotate() {
    if (maxFiles <= 0) {
      // 不留历史：直接清空当前文件（下一次 append 从 0 开始）。
      File(path).writeAsBytesSync(const []);
      _size = 0;
      return;
    }
    // 先删最旧的一份，再逐个后移：Linux 上 rename 会覆盖目标，但 Windows
    // 上目标存在时 `renameSync` 抛异常——统一「先删后移」就不必按平台分叉。
    final oldest = File('$path.$maxFiles');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = maxFiles - 1; i >= 1; i--) {
      final src = File('$path.$i');
      if (!src.existsSync()) continue;
      src.renameSync('$path.${i + 1}');
    }
    final current = File(path);
    if (current.existsSync()) current.renameSync('$path.1');
    _size = 0;
  }
}

/// 把日志同时投递给多个 sink（桌面端 = 控制台 + 文件）。
///
/// 一个 sink 抛异常**不得**影响其它 sink，也不得冒泡到业务调用方：日志是
/// 旁路，不能因为写文件失败就让业务流程失败。
class MultiLogSink implements LogSink {
  const MultiLogSink(this.sinks);

  final List<LogSink> sinks;

  @override
  void write(
    LogLevel level,
    String message, [
    Map<String, Object?> fields = const {},
  ]) {
    for (final sink in sinks) {
      try {
        sink.write(level, message, fields);
      } catch (_) {
        // 故意不用 SpbLog 记录：本函数就在 SpbLog 的调用链上，会无限递归。
        // 单个 sink 的失败由其自身负责暴露（见 [FileLogSink.lastError]）。
      }
    }
  }
}

/// 会话启动标记（每次启动写一条）。
///
/// 与 [logSessionCleanExitMessage] 成对使用：下次启动时若在日志末尾找不到
/// 正常退出标记，就说明上次是崩溃 / 被结束进程 / 掉电——这是「Dart 侧没有
/// 任何崩溃上报」（AGENTS.md §6.20 第 2 层有意不做）时**最低成本**的补偿。
const String logSessionStartMessage = '会话启动';

/// 会话正常退出标记（`quit()` 的收尾里写入）。
const String logSessionCleanExitMessage = '会话结束（正常退出）';

/// 本次启动之前，上一次会话是否**正常退出**。
///
/// 从日志末尾**往前**扫，看先遇到哪个边界标记：
///
/// | 先遇到 | 返回 | 含义 |
/// |---|---|---|
/// | [logSessionCleanExitMessage] | `true` | 上次走到了 `quit()` 的收尾 |
/// | [logSessionStartMessage] | `false` | 新会话开了头，但上一个没留退出标记 |
/// | 都没有 | `null` | 首次运行 / 刚轮转 / 标记之前的老日志 |
///
/// ## ⚠️ 为什么不能「只看最后一条日志是不是退出标记」
///
/// 那会**级联误报**：一次崩溃之后，下次启动会写「会话启动」+ 一条「上次未
/// 正常退出」的告警；此后即使每次都干净退出，只要退出标记之后还有**任何**
/// 一条日志（`quit()` 之后的 `dispose()` 就会写），下一次启动又会判成崩溃
/// ——告警从此**永远**出现，于是它不再携带任何信息。
///
/// 从后往前找边界标记就没这个问题：退出标记**之后**的日志（属同一次收尾）
/// 不影响判断，而「新会话开始」这一事实会正确地终结上一段的判定。
///
/// ## 为什么只读末尾 [tailBytes] 字节
///
/// 日志可能已有数 MB，启动路径上读全文纯属浪费。扫到窗口开头仍没命中就返回
/// `null`（宁可说「不知道」，也不误报崩溃）。进程刚崩时最后一行可能被截断，
/// 那种情况会落到 `false`——方向是对的。
bool? previousSessionExitedCleanly(String path, {int tailBytes = 8 * 1024}) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final length = file.lengthSync();
    if (length == 0) return null;

    final start = length > tailBytes ? length - tailBytes : 0;
    final raf = file.openSync();
    try {
      raf.setPositionSync(start);
      final bytes = raf.readSync(length - start);
      // allowMalformed：截断多字节字符（中文）时不要让这里抛异常。
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      for (final line in lines.reversed) {
        // 先判退出标记：干净收尾时它是最后出现的边界标记。
        if (line.contains(logSessionCleanExitMessage)) return true;
        // 只看到「会话启动」而没有退出标记 ⇒ 那次会话没走完收尾。
        if (line.contains(logSessionStartMessage)) return false;
      }
      return null; // 窗口内没有任何边界标记
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    // 读不到就当「不知道」（null），不要因此让启动失败或误报崩溃。
    return null;
  }
}

/// 默认日志文件路径（应用数据目录下 `logs/app.log`）。
///
/// ## 为什么放在应用数据目录、且与 `sync.db` 同一根
///
/// 报障时要能一句话告诉用户「把 `~/.local/share/super_partyb/logs/app.log`
/// 发给我」。多一个根目录（如 XDG 规范的 `$XDG_STATE_HOME`）会让「日志在哪」
/// 变成需要解释的问题——这里刻意与既有的 `sync.db` 同根。
///
/// 各平台：
/// - Linux / macOS：`${XDG_DATA_HOME:-$HOME/.local/share}/super_partyb/logs/app.log`
/// - Windows：`%APPDATA%/super_partyb/logs/app.log`（退回
///   `%USERPROFILE%/AppData/Roaming`）
/// - 三者都拿不到（无 HOME）：返回 null（调用方只用控制台 sink）
///
/// `SPB_LOG_DIR` 可整体覆盖目录（便携部署 / 测试用）。
///
/// [environment] / [isWindows] 可注入，便于在无对应平台的环境里单测。
String? defaultLogFilePath({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  final win = isWindows ?? Platform.isWindows;

  final override = env['SPB_LOG_DIR']?.trim();
  if (override != null && override.isNotEmpty) return '$override/app.log';

  final String? base;
  if (win) {
    final appData = env['APPDATA']?.trim();
    final profile = env['USERPROFILE']?.trim();
    base = (appData != null && appData.isNotEmpty)
        ? appData
        : ((profile != null && profile.isNotEmpty)
              ? '$profile/AppData/Roaming'
              : null);
  } else {
    final xdg = env['XDG_DATA_HOME']?.trim();
    final home = env['HOME']?.trim();
    base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : ((home != null && home.isNotEmpty) ? '$home/.local/share' : null);
  }
  if (base == null) return null;
  return '$base/super_partyb/logs/app.log';
}
