/// 内存账本：把「可再生态」（缓存 / 时间线 / 清单 / 缩略图）的占用按持有方
/// 登记成具名读数，供诊断报告与高水位日志回答「内存花在哪」。
///
/// ## 它补的是 [MemoryProbe] 回答不了的问题
///
/// `MemoryProbe`（`spb_platform`）给的是**进程级**数字：RSS / OS 高水位 /
/// imageCache。它回答「占了多少」，不回答「花在谁身上」——而用户报「占 800MB」
/// 时，光有 RSS 曲线只能猜（引擎基线？图片？时间线？交付物清单？）。
/// 本账本让每个持有方自报一行读数，于是同一份报告里能直接看出大头。
///
/// ## 为什么是进程级寄存器而不是依赖注入
///
/// 持有方分布在 `spb_domain`（时间线缓冲）与 `spb_features`（页面级缓存），
/// 两端 `main()` 与 `providers.dart` 都不想为「观测」多穿一层参数（
/// `ConversationPage` 已有 46 个具名参数，见 `tools/check_wiring_parity.sh`）。
/// 与 [SpbLog] 同一取向：进程级只读登记处，**生产者登记、消费者读取**，
/// 不改变任何业务签名。
///
/// ## 为什么必须成对注销
///
/// 读数闭包捕获的是持有方（如对话页 `State`）。只登记不注销 = 用一个全局
/// `Map` 把整页 State 钉在内存里——**观测本身成了泄漏源**。故每一个
/// [register] 都必须在持有方 `dispose` 时 [unregister]（两端页面测试会断言
/// 「页面销毁后账本里没有它」）。
///
/// ## 为什么读数允许抛错
///
/// 读数实现由各持有方提供，可能是「遍历 2000 条 item 求和」这类代码。任一
/// 读数抛错都不该让整份诊断报告失败（那是唯一的取证入口）。故 [snapshot]
/// 逐项兜住并留一条 `warn`：**读数挂了本身就是需要查的事**，只是不能连累
/// 其它项。
library;

import 'logger.dart';

/// 一个持有方的瞬时占用读数。
///
/// [bytes] 是**估算**（如时间线按 UTF-16 字符数 × 2），用于横向比较「谁是大头」，
/// 不承诺与 DevTools 的字节数逐位一致。文档与报告里都按这个口径读。
class MemoryGauge {
  const MemoryGauge({required this.count, required this.bytes});

  /// 零读数（未持有任何条目）。
  static const MemoryGauge zero = MemoryGauge(count: 0, bytes: 0);

  /// 条目数（缓存项 / 事件数 / 清单行数）。
  final int count;

  /// 估算占用字节数；0 表示该持有方无法估算（只报条目数）。
  final int bytes;
}

/// 聚合后的账本条目（同名登记项**求和**，告警阈值取最大）。
class MemoryLedgerEntry {
  const MemoryLedgerEntry({
    required this.name,
    required this.label,
    required this.count,
    required this.bytes,
    this.warnCount,
    this.warnBytes,
  });

  /// 稳定标识（如 `conversation.thumbnails`），日志字段用。
  final String name;

  /// 报告里展示的中文名。
  final String label;

  final int count;
  final int bytes;

  /// 超过该条目数即视为「高水位」（null = 不检查）。
  final int? warnCount;

  /// 超过该字节数即视为「高水位」（null = 不检查）。
  final int? warnBytes;

  /// 是否越过任一高水位线。
  bool get overWarn {
    final limitCount = warnCount;
    final limitBytes = warnBytes;
    return (limitCount != null && count > limitCount) ||
        (limitBytes != null && bytes > limitBytes);
  }

  /// 诊断报告里的一行：`对话页缩略图: 214 项 / 6.1MB`。
  String get reportLine => '$label: $count 项 / ${formatMemoryBytes(bytes)}';

  /// 高水位日志里的紧凑形式：`对话页缩略图=214/6.1MB`。
  String get warnToken => '$label=$count/${formatMemoryBytes(bytes)}';
}

/// 登记进账本的单个读数（内部结构）。
class _Registration {
  const _Registration({
    required this.name,
    required this.label,
    required this.read,
    this.warnCount,
    this.warnBytes,
  });

  final String name;
  final String label;
  final MemoryGauge Function() read;
  final int? warnCount;
  final int? warnBytes;
}

/// 进程级内存账本。
abstract final class MemoryLedger {
  MemoryLedger._();

  static final Map<int, _Registration> _entries = <int, _Registration>{};
  static int _nextToken = 1;

  /// 登记一个读数，返回**注销令牌**（持有方 `dispose` 时交回 [unregister]）。
  ///
  /// 同 [name] 允许多个登记（例如两端测试同时挂着两个对话页）：[snapshot]
  /// 按 name 求和，故无需保证唯一。
  static int register({
    required String name,
    required String label,
    required MemoryGauge Function() read,
    int? warnCount,
    int? warnBytes,
  }) {
    final token = _nextToken++;
    _entries[token] = _Registration(
      name: name,
      label: label,
      read: read,
      warnCount: warnCount,
      warnBytes: warnBytes,
    );
    return token;
  }

  /// 注销。令牌不存在时静默返回（重复注销是幂等操作，不该抛）。
  static void unregister(int token) => _entries.remove(token);

  /// 当前登记项数量（测试用：断言「页面销毁后已注销」）。
  static int get registrationCount => _entries.length;

  /// 聚合快照：按 name 求和，按字节降序（报告里大头在前）。
  static List<MemoryLedgerEntry> snapshot() {
    final byName = <String, MemoryLedgerEntry>{};
    for (final reg in _entries.values) {
      final MemoryGauge gauge;
      try {
        gauge = reg.read();
      } on Object catch (e) {
        // 见文件头「为什么读数允许抛错」：留痕但不连累整份报告。
        SpbLog.warn('内存账本读数失败', {'name': reg.name, 'error': '$e'});
        continue;
      }

      final prev = byName[reg.name];
      if (prev == null) {
        byName[reg.name] = MemoryLedgerEntry(
          name: reg.name,
          label: reg.label,
          count: gauge.count,
          bytes: gauge.bytes,
          warnCount: reg.warnCount,
          warnBytes: reg.warnBytes,
        );
        continue;
      }

      byName[reg.name] = MemoryLedgerEntry(
        name: reg.name,
        label: prev.label,
        count: prev.count + gauge.count,
        bytes: prev.bytes + gauge.bytes,
        // 阈值取最大而不是求和：两个页面各挂一份缓存，告警线不该翻倍。
        warnCount: _maxNullable(prev.warnCount, reg.warnCount),
        warnBytes: _maxNullable(prev.warnBytes, reg.warnBytes),
      );
    }

    final list = byName.values.toList(growable: false);
    // 字节相同（或都为 0）时按 name 排，保证报告稳定可 diff。
    list.sort((a, b) {
      final byBytes = b.bytes.compareTo(a.bytes);
      return byBytes != 0 ? byBytes : a.name.compareTo(b.name);
    });
    return list;
  }

  /// 诊断报告「## 内存采样」小节里的分解行（为空表示还没人登记）。
  static List<String> reportLines() =>
      snapshot().map((e) => e.reportLine).toList(growable: false);

  /// 越过高水位的条目（[MemoryWatchdog] 用）。
  static List<MemoryLedgerEntry> overWarnEntries() =>
      snapshot().where((e) => e.overWarn).toList(growable: false);

  /// 清空全部登记。
  ///
  /// **测试专用**（本包无 `meta` 依赖，故不加注解）：账本是进程级单例，
  /// 用例之间会累积；生产代码不调用它（那会让报告与高水位日志永远为空）。
  static void reset() {
    _entries.clear();
    _nextToken = 1;
  }

  static int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }
}

/// 字节数的可读形式（KB/MB 保留一位小数，<1KB 直接给 B）。
String formatMemoryBytes(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}
