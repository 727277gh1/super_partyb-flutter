/// 显示环境的**远端会话**探测：RDP 会话下动画与过渡的降级依据 + 诊断读数。
///
/// ## 它解决什么
///
/// issue #110：Windows 远程桌面（RDP）里切换界面明显卡顿。两个成因都落在
/// 「每帧要画的像素」上，而它们**都不是**本地会话的问题：
///
/// 1. RDP 会话没有硬件 D3D 加速，ANGLE 只能落 `D3D_DRIVER_TYPE_WARP`
///    （软件光栅化），单帧 raster 从 ~3ms 变 20–40ms（§6.74 的判读表）；
/// 2. 整窗重绘在这条路径上**全额**付费——因此常驻动画（spinner、光标、
///    呼吸/脉冲）与全窗过渡都要在远端会话里降级。
///
/// 判据只能来自宿主：Flutter 侧**没有**「当前是不是远端会话」的信号
/// （`MediaQuery` 只带系统的「减少动效」开关，RDP 不会替用户打开它）。
/// 故由原生侧回答 `GetSystemMetrics(SM_REMOTESESSION)`，本模块负责搬运与缓存。
///
/// ## 为什么是「进程级静态缓存」而不是每次现问
///
/// 平台通道是异步的，而消费方有两类：
///
/// - **诊断报告**（`diagnosticsEnvironment()`）：同步拼 Map，不能 await；
/// - **UI 动效策略**（`apps/spb_desktop` 的 `remoteSessionProvider`）：首帧就要
///   定下来，否则第一帧会用「本地会话」的策略渲染，随后再切一次——那本身
///   就是一次整窗重绘。
///
/// 故启动时探测**一次**、结果存进静态字段，之后全同步读。
///
/// ## 为什么只在启动时探测（不跟随会话切换）
///
/// 「本地启动后被 RDP 连上」这条路径本模块覆盖不了，且**故意不覆盖**：
///
/// - 会话切换要原生侧注册 `WTSRegisterSessionNotification` 才有事件；
/// - 而会话切换那一刻引擎正在重建交换链（见白屏那一类问题），此时再触发一次
///   「全部动画时长归零」的全局重建只会放大问题；
/// - 影响面也小：远端会话通常是整场都远端的。
///
/// 换言之：本模块的结论是「这个进程**从**远端会话启动」，不是「此刻是不是
/// 远端」。诊断报告里记的也是这个口径（键名 `remote_session`）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spb_core/spb_core.dart';

/// 显示环境通道名。
///
/// ⚠️ 必须与原生侧逐字一致：`apps/spb_desktop/windows/runner/flutter_window.cpp`
/// 的 `kDisplayEnvChannelName`。写错不会报错，只会表现为 Dart 侧拿到
/// `MissingPluginException` → 读数「未知」→ 远端会话降级整条不生效（而
/// 应用照旧可用，因此**没有任何报障信号**）。
const kDisplayEnvChannelName = 'com.atjog.spb/display_env';

/// 原生方法名：返回当前进程所在的 Windows 会话是否为远端（RDP）会话。
const _remoteSessionMethod = 'remoteSession';

/// 显示环境探测结果（进程级，启动时写入）。
///
/// 见库文档：这是「进程从远端会话启动」的结论，不是「此刻是否远端」。
abstract final class SpbDisplayEnv {
  /// 是否远端桌面会话。
  ///
  /// 三态：`true` / `false` / `null`（未探测或本平台没有实现）。
  /// **null 不等于 false**——它表示「我们不知道」，故：
  ///
  /// - 诊断报告里写 `(未知)` 而不是 `false`（后者会让人以为「本地会话」已确认）；
  /// - 动效策略按 `false` 处理（保守：不乱关用户的动画）。
  static bool? get remoteSession => _remoteSession;

  static bool? _remoteSession;

  /// 探测一次并缓存。
  ///
  /// 返回探测值（`null` = 本平台没有实现 / 通道不可用）。**不抛异常**：
  /// 这是旁路观测，任何失败都只能降级为「未知」。
  ///
  /// 只有 Windows 原生侧实现了这条通道（见 `flutter_window.cpp`）；其余平台
  /// 拿到 `MissingPluginException` → `null`。这一点在移动端是**预期内**的，
  /// 故不写 `warn`（那里没有 RDP，写 warn 只会制造噪声）。
  static Future<bool?> detectRemoteSession() async {
    try {
      final value = await const MethodChannel(kDisplayEnvChannelName)
          .invokeMethod<bool>(_remoteSessionMethod);
      _remoteSession = value;
      // 这条日志是报障时唯一的「当时是远端会话」证据（诊断报告里的同名键
      // 读的是同一个值，两者互为交叉验证）。
      SpbLog.info('显示环境探测', {'remote_session': value ?? '(未知)'});
      return value;
    } on MissingPluginException {
      // 非 Windows 平台：本平台没有这条通道，属预期内。
      _remoteSession = null;
      return null;
    } on Object catch (e) {
      // 通道存在但调用失败（原生侧未注册 handler、messenger 已销毁等）：
      // 保留可能已有的旧值，并留一条可查的日志。
      SpbLog.warn('显示环境探测失败（远端会话按未知处理）', {'error': '$e'});
      return _remoteSession;
    }
  }

  /// 仅供测试：直接设置结论（`null` = 复位成「未知」）。
  ///
  /// `flutter test` 里没有平台通道，用例不需要真的走一遍探测。
  @visibleForTesting
  static void debugSetRemoteSession(bool? value) => _remoteSession = value;
}
