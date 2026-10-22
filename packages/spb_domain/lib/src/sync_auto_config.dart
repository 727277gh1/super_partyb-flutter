/// 自动同步配置（**持久化形态**）。
///
/// ## 为什么需要它
///
/// 交付物同步此前只有**手动**入口（托盘「立即同步交付物」/ 同步页按钮）。
/// 用户得记得去点，否则本地目录永远是上次同步时的样子——而「本地有一份可
/// 离线打开的交付物」正是同步这个功能的全部意义。
///
/// 本类型描述**用户表达的意图**（启动时同步一次 / 每 N 分钟同步一次），
/// 排程由 `AutoSyncScheduler` 执行。
///
/// ## 为什么默认是「全关」
///
/// 生产实测首次全量同步 5666 条 / 4.7 GB（见 `SyncScopeConfig.toScope` 的
/// 注释）。静默地替用户拉 4.7 GB 是不可接受的默认值——尤其在计费网络或
/// 小容量磁盘上。故默认 [disabled]，用户显式开启后才排程。
library;

import 'dart:convert';

import 'package:spb_core/spb_core.dart';

/// 自动同步配置。
class AutoSyncConfig {
  const AutoSyncConfig({this.onLaunch = false, this.intervalMinutes = 0});

  /// 启动后是否自动同步一次。
  ///
  /// 与 [intervalMinutes] **相互独立**：「只在启动时同步一次」是合法且常用
  /// 的组合（每天开一次应用的用户不需要周期拉取）。
  final bool onLaunch;

  /// 周期同步的间隔（分钟）。`0` = 不周期。
  final int intervalMinutes;

  /// 可选的周期档位（分钟）。
  ///
  /// ## 为什么是离散档位而不是「任意分钟数」
  ///
  /// 同步是**全量比对 + 增量下载**（每轮都会分页拉一遍清单），间隔太短
  /// 会持续占用带宽与服务端配额。给离散档位同时也让 UI 用下拉而不是输入框
  /// ——后者要处理「0」「负数」「非数字」三种非法输入。
  ///
  /// `0` 必须在列表里：它表示「不周期」，是下拉的一个合法选项。
  static const List<int> allowedIntervals = <int>[0, 15, 30, 60, 180];

  /// 全关（默认值）。
  static const AutoSyncConfig disabled = AutoSyncConfig();

  /// 是否配置了周期同步。
  bool get isPeriodic => intervalMinutes > 0;

  /// 是否**任何**自动同步被开启。
  ///
  /// 为 false 时调度器不排任何计时器（零开销），设置页也应据此提示
  /// 「完全手动」。
  bool get isEnabled => onLaunch || isPeriodic;

  AutoSyncConfig copyWith({bool? onLaunch, int? intervalMinutes}) =>
      AutoSyncConfig(
        onLaunch: onLaunch ?? this.onLaunch,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      );

  /// 序列化为持久化字符串。
  ///
  /// ## 为什么两个字段存成一个 JSON 键
  ///
  /// 与 `SyncScopeConfig.encode` 同一理由：`onLaunch` 与 `intervalMinutes`
  /// 是一个**意图**的两个维度，分开存会出现「启动了但不知道要不要周期」的
  /// 中间态（写了一半的偏好）。存一个键天然原子。
  String encode() =>
      jsonEncode({'on_launch': onLaunch, 'interval_minutes': intervalMinutes});

  /// 从持久化字符串解析；`null`/空串/损坏一律退回 [disabled]。
  ///
  /// ## 为什么损坏时退回「全关」而不是「全开」
  ///
  /// 自动同步是**有代价**的动作（带宽、磁盘、服务端配额）。一个读不出来的
  /// 配置退回「全开」会在用户毫不知情的情况下持续拉取；退回「全关」则只是
  /// 回到手动模式——用户点一次同步就发现了，代价可逆。
  ///
  /// 不抛异常：偏好是「配置」而非「数据」，一个坏值不该让设置页打不开。
  static AutoSyncConfig decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return disabled;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return disabled;
      final launch = decoded['on_launch'];
      final rawInterval = decoded['interval_minutes'];
      final interval = rawInterval is int
          ? rawInterval
          : int.tryParse('$rawInterval') ?? 0;
      return AutoSyncConfig(
        onLaunch: launch is bool ? launch : false,
        intervalMinutes: _normalizeInterval(interval),
      );
    } catch (e) {
      SpbLog.warn('自动同步偏好无法解析，回退成「完全手动」', {
        'raw_bytes': raw.length,
        'error': e.toString(),
      });
      return disabled;
    }
  }

  /// 把任意整数钳到 [allowedIntervals] 里的一个合法档位。
  ///
  /// ## 为什么是「就近钳制」而不是「非法即 0」
  ///
  /// 0 意味着**关掉周期同步**。若某天档位集合调整（例如去掉 180 分钟），
  /// 老用户存的 180 会被判成「非法」→ 静默变成「不周期」——用户会以为
  /// 自动同步坏了。就近钳制到 60 至少保持「仍在自动同步」这个用户意图。
  ///
  /// 负数与非数字同样按 0 处理（`decode` 里 `tryParse` 失败即 0）。
  static int _normalizeInterval(int raw) {
    if (allowedIntervals.contains(raw)) return raw;
    if (raw <= 0) return 0;
    var best = allowedIntervals.first;
    var bestDiff = (best - raw).abs();
    for (final candidate in allowedIntervals) {
      final diff = (candidate - raw).abs();
      // 严格小于：等距时保留**较小**的档位（更频繁但仍在列表内，
      // 比跨到 3 小时更接近用户的原始意图）。
      if (diff < bestDiff) {
        best = candidate;
        bestDiff = diff;
      }
    }
    SpbLog.warn('自动同步间隔不在可选档位内，已就近钳制', {
      'raw': raw,
      'used': best,
      'allowed': allowedIntervals,
    });
    return best;
  }

  @override
  bool operator ==(Object other) =>
      other is AutoSyncConfig &&
      other.onLaunch == onLaunch &&
      other.intervalMinutes == intervalMinutes;

  @override
  int get hashCode => Object.hash(onLaunch, intervalMinutes);

  @override
  String toString() =>
      'AutoSyncConfig(onLaunch: $onLaunch, intervalMinutes: $intervalMinutes)';
}
