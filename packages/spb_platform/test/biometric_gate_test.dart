import 'package:flutter_test/flutter_test.dart';

import 'package:spb_platform/spb_platform.dart';

/// [shouldLockOnResume] 的契约测试（issue #94）。
///
/// ## 这个测试防的是什么
///
/// 「回到前台要不要重新上锁」是本功能里唯一有**边界**的判断，而它藏在启动
/// 逻辑里时只能靠 widget 测试间接观察（差一秒这类场景几乎无法断言）。抽成纯
/// 函数后逐条钉住，实现里改成 `>=` 或漏掉「已登录」这个条件都会立刻转红。
///
/// 三道条件各自漏掉的后果：
///
/// - 漏 `enabled`：用户明确关掉了开关，却还是每次被要求验证；
/// - 漏 `authenticated`：正在走 OIDC 回调（状态 `unknown`）时弹一道验证框，
///   把登录流程打断——用户看到的是「刚登录完又被锁住」；
/// - 漏宽限期：切出去看一眼通知回来就被要求验指纹。
void main() {
  const grace = Duration(seconds: 30);

  test('开着门禁 + 已登录 + 超过宽限期 → 上锁', () {
    expect(
      shouldLockOnResume(
        enabled: true,
        authenticated: true,
        backgrounded: const Duration(seconds: 31),
        gracePeriod: grace,
      ),
      isTrue,
    );
  });

  test('门禁关着 → 永不上锁', () {
    expect(
      shouldLockOnResume(
        enabled: false,
        authenticated: true,
        backgrounded: const Duration(hours: 8),
        gracePeriod: grace,
      ),
      isFalse,
    );
  });

  test('未登录 → 不上锁（没有内容可挡，还会打断 OIDC 回调）', () {
    expect(
      shouldLockOnResume(
        enabled: true,
        authenticated: false,
        backgrounded: const Duration(hours: 8),
        gracePeriod: grace,
      ),
      isFalse,
    );
  });

  test('宽限期内 → 不上锁（看一眼通知就回来）', () {
    expect(
      shouldLockOnResume(
        enabled: true,
        authenticated: true,
        backgrounded: const Duration(seconds: 29),
        gracePeriod: grace,
      ),
      isFalse,
    );
  });

  test('恰好等于宽限期 → 不上锁（边界取 > 而非 >=，避免抖动）', () {
    expect(
      shouldLockOnResume(
        enabled: true,
        authenticated: true,
        backgrounded: grace,
        gracePeriod: grace,
      ),
      isFalse,
    );
  });

  test('宽限期为零时只要真的离开过就上锁', () {
    expect(
      shouldLockOnResume(
        enabled: true,
        authenticated: true,
        backgrounded: const Duration(microseconds: 1),
        gracePeriod: Duration.zero,
      ),
      isTrue,
    );
  });

  group('UnsupportedBiometricGate', () {
    test('可用性恒为 unsupported', () async {
      expect(
        await const UnsupportedBiometricGate().availability(),
        BiometricAvailability.unsupported,
      );
    });

    test('验证恒不通过（空实现绝不能「假装成功」）', () async {
      // 这是安全相关的断言：桌面端 / 测试默认注入这个实现。若它返回
      // success，任何漏挂 override 的场景都会静默跳过门禁。
      expect(
        await const UnsupportedBiometricGate().authenticate(reason: '解锁'),
        BiometricAuthOutcome.unavailable,
      );
    });
  });

  group('BiometricLockPolicy', () {
    test('默认 30 秒宽限期 + 允许设备密码降级', () {
      const policy = BiometricLockPolicy();
      expect(policy.gracePeriod, const Duration(seconds: 30));
      expect(policy.allowDeviceCredential, isTrue);
    });

    test('默认不开启（这是需要用户同意的功能）', () {
      expect(BiometricLockPolicy.enabledByDefault, isFalse);
    });

    test('偏好键是稳定的字面量（改了会静默丢掉用户的开关）', () {
      // 键名一旦改动，老用户的设置就读不到 → 门禁悄悄变回「关」。
      expect(BiometricLockPolicy.preferenceKey, 'biometric_lock_enabled');
    });
  });
}
