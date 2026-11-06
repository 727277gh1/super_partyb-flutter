/// `local_auth` 支撑的生物识别门禁（issue #94）。
///
/// ## 为什么实现在 App 而不是 `spb_platform`
///
/// 与 `wechat_open_sdk.dart` 同一条理由：`spb_platform` 只放**契约**，插件依赖
/// 声明在本 App，桌面端构建就不会把移动端插件拖进依赖树（见
/// `packages/spb_platform/pubspec.yaml` 里 `window_manager` 那段教训）。
///
/// ## 这一层做的唯一一件事：把平台异常归一成 [BiometricAuthOutcome]
///
/// `local_auth` 3.x 的行为是「成功返回 true，失败抛 [LocalAuthException]」，
/// 且异常码有 14 种、跨平台还不完全一致。上层（锁屏页 / `AuthStateNotifier`）
/// 只需要知道「能不能重试、要不要强制重登」，所以映射集中在这里，只有一处
/// 需要跟着插件升级改。
library;

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// `local_auth` 的实现。
class LocalAuthBiometricGate implements BiometricGate {
  LocalAuthBiometricGate([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<BiometricAvailability> availability() async {
    try {
      // isDeviceSupported：有生物识别**或**有设备凭据（PIN/图案/密码）都算 true。
      // 这正是我们要的口径——issue #94 允许降级到设备密码。
      if (await _auth.isDeviceSupported()) {
        return BiometricAvailability.available;
      }
      // 硬件在但没录生物识别、也没设设备凭据。
      return await _auth.canCheckBiometrics
          ? BiometricAvailability.noCredentials
          : BiometricAvailability.noHardware;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
          BiometricAvailability.noHardware,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled =>
          BiometricAvailability.noCredentials,
        // 其余（deviceError / unknownError / uiUnavailable …）在能力探测阶段
        // 一律按「不可用」处理：探测失败时不该把一个假的「可用」摆给用户，
        // 那会导致「开关能打开，但每次解锁都失败」这种更差的体验。
        _ => BiometricAvailability.unsupported,
      };
    } on MissingPluginException {
      // 桌面 / 未注册插件的环境（例如测试里误用了真实实现）。
      return BiometricAvailability.unsupported;
    } on PlatformException catch (e) {
      SpbLog.warn('探测生物识别能力失败', {'code': e.code});
      return BiometricAvailability.unsupported;
    }
  }

  @override
  Future<BiometricAuthOutcome> authenticate({
    required String reason,
    bool allowDeviceCredential = true,
  }) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // biometricOnly 与「允许设备凭据」是反的：true 表示**只**认生物识别。
        biometricOnly: !allowDeviceCredential,
        // 切后台时系统会取消验证；开启后插件会在回前台时自动重试一次。
        // 移动端解锁时切后台的典型场景是「来了个电话」，重试比直接失败好。
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricAuthOutcome.success : BiometricAuthOutcome.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        // 用户取消 / 系统取消（来电、切后台、超时）：都不是「验证失败」，
        // 不该计入失败次数，也不该弹错误——用户改主意了而已。
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.userRequestedFallback =>
          BiometricAuthOutcome.canceled,

        // 平台锁定：连续失败过多，或系统要求先用别的方式解锁设备。此时再弹
        // 生物识别框没有意义（系统会直接拒绝），必须走完整登录。
        LocalAuthExceptionCode.biometricLockout ||
        LocalAuthExceptionCode.temporaryLockout =>
          BiometricAuthOutcome.lockedOut,

        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
          BiometricAuthOutcome.unavailable,

        // authInProgress（上一轮还没结束）/ uiUnavailable / deviceError /
        // unknownError：都按「这次没成，可以再试」处理。刻意不映射成
        // lockedOut——那会触发强制重新登录，代价太大，而这些多半是瞬时故障。
        _ => BiometricAuthOutcome.failed,
      };
    } on MissingPluginException {
      return BiometricAuthOutcome.unavailable;
    } on PlatformException catch (e) {
      SpbLog.warn('生物识别验证异常', {'code': e.code});
      return BiometricAuthOutcome.failed;
    }
  }
}
