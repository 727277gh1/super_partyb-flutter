library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

import 'package:spb_mobile/providers.dart';

/// 生物识别门禁在认证状态机里的接线（issue #94）。
///
/// ## 这个测试防的是什么
///
/// 「门禁接上了」有四种**静默**失败方式，全都不会报错、全都能骗过人工点一遍：
///
/// 1. 冷启动有凭证却没上锁（忘了判偏好 / 判了却直接 `restore()`）；
/// 2. 解锁成功但状态没推进（于是锁屏页永远停着）；
/// 3. 切后台再回来没重新上锁（只挡冷启动等于没挡）；
/// 4. 开关关着却仍然上锁（用户明确关掉了功能，还是被拦）。
///
/// 这里用假 gate + 内存 token store 逐一钉住；真平台通道一行不碰。
/// 记录调用、可编排结果的假门禁（不碰真平台通道）。
class FakeBiometricGate implements BiometricGate {
  FakeBiometricGate({
    this.availabilityResult = BiometricAvailability.available,
    this.outcomes = const [BiometricAuthOutcome.success],
  });

  BiometricAvailability availabilityResult;
  List<BiometricAuthOutcome> outcomes;
  int availabilityCalls = 0;
  int authCalls = 0;

  @override
  Future<BiometricAvailability> availability() async {
    availabilityCalls++;
    return availabilityResult;
  }

  @override
  Future<BiometricAuthOutcome> authenticate({
    required String reason,
    bool allowDeviceCredential = true,
  }) async {
    final outcome = outcomes[authCalls.clamp(0, outcomes.length - 1)];
    authCalls++;
    return outcome;
  }
}

/// 一份「刚登录」的凭证（未过期，`restore()` 不会触发网络刷新）。
StoredTokens freshSessionTokens() => StoredTokens(
  accessToken: 'at_test',
  expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
);

/// 等到启动判定结束（`unknown` → 其他）。
Future<void> settleAuth(ProviderContainer container) async {
  for (var i = 0; i < 200; i++) {
    if (container.read(authStateProvider).status != AuthStatus.unknown) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('启动判定超时：状态一直停在 unknown');
}

void main() {
  /// 建容器并等到启动判定结束（`unknown` → 其他）。
  Future<ProviderContainer> start({
    required FakeBiometricGate gate,
    StoredTokens? stored,
    bool lockEnabled = true,
    BiometricLockPolicy policy = const BiometricLockPolicy(),
  }) async {
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore(stored)),
        biometricGateProvider.overrideWithValue(gate),
        biometricLockEnabledProvider.overrideWith((ref) async => lockEnabled),
        biometricLockPolicyProvider.overrideWithValue(policy),
      ],
    );
    addTearDown(container.dispose);
    // 触发 build（内部 `_bootstrap` 是异步的）。
    container.read(authStateProvider);
    await settleAuth(container);
    return container;
  }

  test('有凭证 + 开关打开 → 冷启动即锁定，且**不**提前换 token', () async {
    final gate = FakeBiometricGate();
    final store = InMemoryTokenStore(freshSessionTokens());
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        biometricGateProvider.overrideWithValue(gate),
        biometricLockEnabledProvider.overrideWith((ref) async => true),
      ],
    );
    addTearDown(container.dispose);
    container.read(authStateProvider);
    await settleAuth(container);

    expect(container.read(authStateProvider).isLocked, isTrue);
    expect(gate.authCalls, 0, reason: '锁定阶段不该自动发起一次验证');
    expect(gate.availabilityCalls, greaterThan(0));
  });

  test('解锁成功 → 已登录', () async {
    final gate = FakeBiometricGate(outcomes: [BiometricAuthOutcome.success]);
    final container = await start(gate: gate, stored: freshSessionTokens());

    final outcome = await container.read(authControllerProvider).unlock();

    expect(outcome, BiometricAuthOutcome.success);
    expect(container.read(authStateProvider).isAuthenticated, isTrue);
  });

  test('解锁失败 / 取消 → 仍停在锁定，且**不**清凭证', () async {
    for (final outcome in [
      BiometricAuthOutcome.failed,
      BiometricAuthOutcome.canceled,
    ]) {
      final gate = FakeBiometricGate(outcomes: [outcome]);
      final store = InMemoryTokenStore(freshSessionTokens());
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          biometricGateProvider.overrideWithValue(gate),
          biometricLockEnabledProvider.overrideWith((ref) async => true),
        ],
      );
      addTearDown(container.dispose);
      container.read(authStateProvider);
      await settleAuth(container);

      expect(
        await container.read(authControllerProvider).unlock(),
        outcome,
        reason: '结果必须原样返回，锁屏页据此决定文案',
      );
      expect(container.read(authStateProvider).isLocked, isTrue);
      expect(store.clearCount, 0, reason: '失败一次就清凭证，会在传感器临时不可用时销毁刚登录的会话');
    }
  });

  test('平台锁定 → 仍停在锁定（由页面给出「重新登录」出口）', () async {
    final gate = FakeBiometricGate(outcomes: [BiometricAuthOutcome.lockedOut]);
    final container = await start(gate: gate, stored: freshSessionTokens());

    expect(
      await container.read(authControllerProvider).unlock(),
      BiometricAuthOutcome.lockedOut,
    );
    expect(container.read(authStateProvider).isLocked, isTrue);
  });

  test('「改用登录」（signOut）→ 未登录且凭证被清', () async {
    final gate = FakeBiometricGate();
    final store = InMemoryTokenStore(freshSessionTokens());
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        biometricGateProvider.overrideWithValue(gate),
        biometricLockEnabledProvider.overrideWith((ref) async => true),
      ],
    );
    addTearDown(container.dispose);
    container.read(authStateProvider);
    await settleAuth(container);
    expect(container.read(authStateProvider).isLocked, isTrue);

    await container.read(authControllerProvider).signOut();

    expect(container.read(authStateProvider).isUnauthenticated, isTrue);
    expect(store.clearCount, 1);
  });

  test('开关关闭 → 有凭证直接进入已登录（不上锁）', () async {
    final gate = FakeBiometricGate();
    final container = await start(
      gate: gate,
      stored: freshSessionTokens(),
      lockEnabled: false,
    );

    expect(container.read(authStateProvider).isAuthenticated, isTrue);
    expect(gate.availabilityCalls, 0, reason: '关着开关连设备能力都不必探测');
  });

  test('开关开着但设备不可用 → 放行到已登录（不能把人锁在外面）', () async {
    final gate = FakeBiometricGate(
      availabilityResult: BiometricAvailability.noCredentials,
    );
    final container = await start(gate: gate, stored: freshSessionTokens());

    expect(
      container.read(authStateProvider).isAuthenticated,
      isTrue,
      reason: '指纹被删掉 / 换设备后若仍上锁，用户就永久进不去了',
    );
  });

  test('没有凭证 → 未登录（不上锁、不弹验证）', () async {
    final gate = FakeBiometricGate();
    final container = await start(gate: gate);

    expect(container.read(authStateProvider).isUnauthenticated, isTrue);
    expect(gate.authCalls, 0);
  });

  group('回到前台重新上锁', () {
    test('宽限期内回来 → 保持已登录', () async {
      final container = await start(
        gate: FakeBiometricGate(),
        stored: freshSessionTokens(),
        lockEnabled: false,
      );
      expect(container.read(authStateProvider).isAuthenticated, isTrue);

      // 打开开关（模拟用户在设置页开启，写入方会同步推到 notifier）。
      container.read(authStateProvider.notifier).setLockEnabled(true);
      container.read(windowFocusedProvider.notifier).set(false);
      container.read(windowFocusedProvider.notifier).set(true);

      expect(
        container.read(authStateProvider).isAuthenticated,
        isTrue,
        reason: '默认 30 秒宽限期：切出去立刻回来不该被要求验证',
      );
    });

    test('超过宽限期回来 → 重新上锁', () async {
      final container = await start(
        gate: FakeBiometricGate(),
        stored: freshSessionTokens(),
        lockEnabled: false,
        policy: const BiometricLockPolicy(gracePeriod: Duration.zero),
      );
      expect(container.read(authStateProvider).isAuthenticated, isTrue);
      container.read(authStateProvider.notifier).setLockEnabled(true);

      container.read(windowFocusedProvider.notifier).set(false);
      // 让时间真的走过去一点（宽限期为 0 时判据是 `backgrounded > 0`）。
      await Future<void>.delayed(const Duration(milliseconds: 2));
      container.read(windowFocusedProvider.notifier).set(true);

      expect(container.read(authStateProvider).isLocked, isTrue);
    });

    test('未登录时回前台不上锁（不打断登录流程）', () async {
      final container = await start(
        gate: FakeBiometricGate(),
        lockEnabled: true,
        policy: const BiometricLockPolicy(gracePeriod: Duration.zero),
      );
      expect(container.read(authStateProvider).isUnauthenticated, isTrue);

      container.read(windowFocusedProvider.notifier).set(false);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      container.read(windowFocusedProvider.notifier).set(true);

      expect(container.read(authStateProvider).isUnauthenticated, isTrue);
    });
  });

  test('启动判定与登录回调并发时，不把已登录改回未登录', () async {
    // 真机场景：冷启动带着 `partyb://oidc/callback` 深链，回调先落盘并置为
    // 已登录，而启动判定读到的是「落盘之前」的空快照。此时若无条件写
    // 未登录，用户刚登录就被踢回登录页。
    final store = InMemoryTokenStore();
    final gate = FakeBiometricGate();
    final container = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        biometricGateProvider.overrideWithValue(gate),
        biometricLockEnabledProvider.overrideWith((ref) async => true),
      ],
    );
    addTearDown(container.dispose);

    // 先让回调完成（落盘 + 置为已登录），再触发启动判定所依赖的 provider。
    await store.write(freshSessionTokens());
    container.read(authStateProvider.notifier).signedIn();
    container.read(authStateProvider);
    await settleAuth(container);

    expect(container.read(authStateProvider).isAuthenticated, isTrue);
  });
}
