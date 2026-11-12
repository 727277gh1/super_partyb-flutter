/// 同步链路的**在途字节**计数与账本登记。
///
/// ## 它回答什么
///
/// 2026-11 真机报障的诊断报告里，高水位日志是这一行：
///
/// ```
/// WARN 内存高水位 rss_mb=498.5 peak_mb=565.3 since_start_mb=431.6
///      image_cache_mb=0.3 breakdown=
/// ```
///
/// `image_cache_mb` 只有 0.3MB、`breakdown` 为空——说明这 400+MB 既不是图片，
/// 也不是任何**登记过**的持有方（时间线/缩略图/气泡缓存/交付物清单，它们只在
/// 会话页与交付面板登记）。而当轮真正的大头是「同步链路把整份文件读进内存」
/// （下载返回的字节 + 哈希时的又一次拷贝），那条路径**没有任何读数**，于是
/// 证据链断在这里。
///
/// 本文件补的就是这一条读数：谁在内存里持有同步文件字节，账本里就有一行。
///
/// ## 为什么是进程级计数器而不是把持有方传进账本
///
/// 持有方是**一段正在执行的控制流**（`SyncEngine` 的下载分支、
/// `DeliverableUploadUseCase` 的单个文件上传），不是页面级的 `State`。让它们
/// 各自 `register`/`unregister` 会把「记账」散到多处、且异常路径容易漏注销；
/// 用一对 `hold`/`release`（配合 `finally`）就够了——读数是「此刻在途多少」，
/// 而不是「谁登记了」。
///
/// ## 为什么允许计数为负时归零
///
/// `release` 与 `hold` 不共享同一个对象，异常/重入时理论上可能不配对。归零
/// 是**保守**的一侧：读数偏小比报一个负数（会让读者以为账本坏了）好。
library;

import 'package:spb_core/spb_core.dart';

/// 进程级「同步在途字节」计数器。
///
/// 语义：**当前**驻留在内存里的同步文件字节数（不是累计量）。`count` 是在途
/// 文件数（一个文件算一项，与 [MemoryGauge.count] 对齐）。
abstract final class SyncInFlightBytes {
  static int _bytes = 0;
  static int _files = 0;

  /// 当前在途字节数。
  static int get bytes => _bytes;

  /// 当前在途文件数。
  static int get files => _files;

  /// 登记一份常驻内存的文件字节。
  ///
  /// 调用方必须在 `finally` 里配 [release]——否则读数会一直虚高，那会让下一次
  /// 报障的分解行误导人（比没有读数更糟）。
  static void hold(int byteCount) {
    if (byteCount <= 0) return;
    _bytes += byteCount;
    _files += 1;
  }

  /// 释放在途字节（与 [hold] 成对）。
  static void release(int byteCount) {
    if (byteCount <= 0) return;
    _bytes -= byteCount;
    if (_bytes < 0) _bytes = 0;
    _files -= 1;
    if (_files < 0) _files = 0;
  }

  /// 清空（**测试专用**：进程级计数器会跨用例累积）。
  static void reset() {
    _bytes = 0;
    _files = 0;
  }
}

/// 账本里这条读数的名字（报告/日志里出现，稳定不改）。
const String syncInFlightGaugeName = 'sync.inflight';

/// 把在途字节登记进 [MemoryLedger]，返回注销令牌。
///
/// ## 为什么由装配层调用一次
///
/// 它没有「持有方」可以挂（见文件头），故登记动作属于**进程级装配**：两端
/// `main()` 在 `installMemoryProbe()` 之后各调一次，令牌与进程同寿命、不注销
/// （`MemoryLedger` 是进程级寄存器，页面级登记才需要成对注销）。
///
/// ## 阈值
///
/// [warnBytes] 默认 128MB：超过它意味着「有一份很大的文件正在内存里」，那正是
/// 需要在高水位日志里被看见的时刻。注意上传/下载路径同时可能持有**两份**（整
/// 份字节 + 哈希拷贝），故 128MB 的读数对应约 64MB 的文件。
int registerSyncInFlightGauge({int warnBytes = 128 * 1024 * 1024}) {
  return MemoryLedger.register(
    name: syncInFlightGaugeName,
    label: '同步在途字节',
    read: () => MemoryGauge(
      count: SyncInFlightBytes.files,
      bytes: SyncInFlightBytes.bytes,
    ),
    warnBytes: warnBytes,
  );
}
