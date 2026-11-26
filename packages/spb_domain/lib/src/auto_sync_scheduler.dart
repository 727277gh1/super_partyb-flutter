/// 自动同步调度器（**纯逻辑**，只做排程，不碰磁盘也不碰网络）。
///
/// ## 为什么需要它
///
/// 交付物同步此前只有手动入口（托盘「立即同步交付物」/ 同步页按钮）。
/// 用户得记得点，本地目录才会跟得上远端。本类把「什么时候该同步」抽成
/// 一个可无头单测的状态机，真正的「同步」由注入的 [run] 完成。
///
/// ## 为什么放 `spb_domain` 而不是 app 装配层
///
/// 排程规则里有几条**正确性**判据（幂等、在途不重叠、暂停后必须能重新
/// 武装、失败要续排而不是静默死掉）。放在纯 Dart 包才能用 `fake_async`
/// 逐条断言，而不是只能靠真机等 15 分钟。
///
/// ## 三条设计取舍
///
/// 1. **自续排的一次性 `Timer`，而不是 `Timer.periodic`**：`periodic` 在
///    回调里做异步工作时，会让两轮重叠（上一轮还没跑完就排下一轮）。虽然
///    [run] 侧有在途守卫，但重叠会让「本轮跳过」变成常态且难以观测。
/// 2. **`apply` 以配置相等作幂等键**：装配层可能有多个信号源（登录态、
///    配置变化）都触发 reconcile，若每次都重排计时器，用户每次切前台都会
///    把周期重置、实际同步间隔被无限拉长。
/// 3. **`pause` 清空已应用配置**：否则重新登录时 `apply(同一个配置)` 会因
///    幂等判定直接返回，**永远排不上计时器**（这条写反过一次，有专门用例钉住）。
library;

import 'dart:async';

import 'package:spb_core/spb_core.dart';

import 'sync_auto_config.dart';

/// 一轮自动同步的执行体（通常是 `runSyncActionProvider` 的薄包装）。
typedef AutoSyncRun = Future<void> Function();

/// 自动同步调度器。
///
/// 生命周期：`dispose` 之后不可再用。其余方法都可反复调用。
class AutoSyncScheduler {
  /// [run] 应在内部自己处理失败（本类只记日志，不向上抛）。
  /// 它必须是**可重入安全**的：本类保证不会并发调用，但调用方手动触发的
  /// 同步可能与本类的轮次重叠。
  AutoSyncScheduler({required AutoSyncRun run}) : _run = run;

  final AutoSyncRun _run;

  Timer? _timer;
  AutoSyncConfig? _applied;
  bool _launched = false;
  bool _running = false;
  bool _disposed = false;

  /// 是否已排上周期计时器。
  bool get isScheduled => _timer != null;

  /// 是否处于「已启用自动同步」状态（[pause] 与 [dispose] 之后为 false）。
  bool get isApplied => _applied != null;

  /// 本轮是否正在执行。
  bool get isRunning => _running;

  /// 应用一份配置。
  ///
  /// ## 语义
  ///
  /// - 与上次**相同**的配置 → 什么都不做（不重排计时器，不重跑启动同步）；
  /// - 配置未启用（[AutoSyncConfig.isEnabled] 为 false）→ 等价于 [pause]；
  /// - 首次启用且 [AutoSyncConfig.onLaunch] 为 true → **立即**跑一轮；
  /// - [AutoSyncConfig.intervalMinutes] 大于 0 → 排一个一次性计时器，
  ///   每轮结束后续排。
  Future<void> apply(AutoSyncConfig config) async {
    if (_disposed) return;
    // 幂等键：装配层的多个信号源会反复喂同一份配置（登录态变化、
    // FutureProvider 首次完成）。若不去重，周期会被无限重置。
    if (_applied == config) return;

    if (!config.isEnabled) {
      pause();
      return;
    }

    _applied = config;
    // 先排周期，再跑启动轮：启动轮可能耗时很长（首轮是全量），
    // 顺序反过来会让「周期同步」被启动同步的耗时推迟到不可预期。
    _armTimer();
    if (config.onLaunch && !_launched) {
      _launched = true;
      await _tick();
    }
  }

  /// 暂停：取消计时器，并**清空**已应用配置。
  ///
  /// ## 为什么必须清空
  ///
  /// 若只取消计时器而保留 `_applied`，重新登录时装配层会再喂一份**相同**的
  /// 配置，`apply` 的幂等判定会让它直接返回——于是自动同步在第二次登录后
  /// 永久失效。清空 `_applied` 与 `_launched` 后，重新登录会重新武装，
  /// 并按 `onLaunch` 再跑一轮（登录即「新会话」，语义上就是「启动」）。
  void pause() {
    _applied = null;
    _launched = false;
    _cancelTimer();
  }

  /// 释放资源。调用后本实例不再响应任何方法。
  void dispose() {
    _disposed = true;
    _applied = null;
    _cancelTimer();
  }

  void _armTimer() {
    _cancelTimer();
    final minutes = _applied?.intervalMinutes ?? 0;
    if (minutes <= 0) return;
    _timer = Timer(Duration(minutes: minutes), _tick);
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 跑一轮，然后**在结束后**续排下一轮。
  ///
  /// ## 为什么在结束后才续排（而不是在触发时就排）
  ///
  /// 一次性 `Timer` 的语义就是「本轮结束 → 距下一轮 [intervalMinutes]」。
  /// 若在触发时立刻排，长轮次（首轮全量）会与下一轮重叠，退化成
  /// 「背靠背两次同步」。
  Future<void> _tick() async {
    // 必须 `_cancelTimer()` 而不是 `_timer = null`。
    //
    // ## 为什么（这条被测试抓到过）
    //
    // `apply` 里「先排周期，再跑启动轮」——启动轮进 `_tick` 时，那个计时器
    // **是活的**。只把字段置 null 会丢掉引用但留下僵尸 Timer，它到期后
    // 再触发一次 `_tick`，于是「一轮」变成两轮并发。
    //
    // 当 `_tick` 本身是计时器回调时，取消一个已触发的计时器是空操作。
    _cancelTimer();
    if (_disposed || _applied == null) return;

    if (_running) {
      // 理论上不会发生（本类串行化自己的轮次）。真发生说明有第二个触发源
      // ——跳过本轮并**照常续排**，绝不让排程链断在这里。
      SpbLog.debug('自动同步跳过本轮：上一轮仍在进行');
    } else {
      _running = true;
      try {
        await _run();
      } on Object catch (e, st) {
        // 必须留痕（issue #45）：自动同步没有用户界面，一次失败若被吞掉，
        // 用户只会看到「目录没更新」而完全没有线索。
        SpbLog.error('自动同步轮次失败', error: e, stackTrace: st);
      } finally {
        _running = false;
      }
    }

    if (_disposed || _applied == null) return;
    _armTimer();
  }
}
