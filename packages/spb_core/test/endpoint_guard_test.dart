import 'dart:async';

import 'package:spb_core/spb_core.dart';
import 'package:test/test.dart';

/// `EndpointGuard` 的契约测试（issue #50 运行中降级/升级）。
///
/// ## 这个测试防的是什么
///
/// 升降级是**不对称迟滞**，三类「静默退化」都只在真实网络变化时才现形，
/// 本机永远复现不到：
///
///   1. **降级不生效**：计数阈值判错 / 只在升级态才计数判错 → 用户切到无
///      IPv6 的网络后永远连不上（issue #50 的主症状）。
///   2. **降级误触发**：把 4xx/5xx 也计入 → 服务端一次 500 就把用户从
///      源站踢回 CDN，且永不恢复优化路径。
///   3. **只降不升**：冷却后的重探没安排 / 安排了一次失败就放弃 → 用户切回
///      有 IPv6 的网络也回不到源站（issue #50 明确否定的方案）。
///
/// 全部用注入的 `probe` + 注入的 `now`，不碰真实网络、不真等 5 分钟。
void main() {
  final compiledApi = Uri.parse(SpbEnv.apiBaseUrl);
  final compiledUfs = Uri.parse(SpbEnv.ufsBaseUrl);
  final compiledHost = compiledApi.host;

  /// 把端点置为「已升级」态（模拟启动时探测成功）。
  Future<void> setUpgraded() async {
    await SpbEndpoints.resolveAndUpdate(
      preferred: <String, String>{compiledHost: 'v6.example.com'},
      probe: (_, _, _) async => true,
      timeout: const Duration(milliseconds: 5),
    );
    expect(
      SpbEndpoints.current.probeOutcome,
      EndpointProbeOutcome.upgraded,
      reason: '前置条件：本组用例都从升级态开始',
    );
  }

  setUp(() {
    SpbEndpoints.resetForTest();
  });

  tearDown(() {
    EndpointGuard.instance.dispose();
    SpbEndpoints.resetForTest();
  });

  group('降级（快路径）', () {
    test('连续 3 次连接失败 → 退回编译期地址，结论为 downgraded', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.upgraded,
        reason: '未达阈值不得提前降级',
      );

      guard.recordFailure(EndpointFailureKind.connectivity);
      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.downgraded,
      );
      expect(SpbEndpoints.current.apiBaseUrl, SpbEnv.apiBaseUrl);
      expect(SpbEndpoints.current.ufsBaseUrl, SpbEnv.ufsBaseUrl);
      expect(guard.consecutiveFailures, 0, reason: '降级后计数清零');
    });

    test('成功响应清零计数（跨「好/坏」两段网络不累积）', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordSuccess();
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);

      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.upgraded,
        reason: '清零后重新计数，两次失败不得触发降级',
      );
    });

    test('服务端错误（4xx/5xx）不计入判据', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;

      for (var i = 0; i < 10; i++) {
        guard.recordFailure(EndpointFailureKind.server);
      }
      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.upgraded,
        reason: '源站能返回错误码说明网络是通的，不该降级',
      );
      expect(guard.consecutiveFailures, 0);
    });

    test('用户取消不计入判据', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      for (var i = 0; i < 10; i++) {
        guard.recordFailure(EndpointFailureKind.cancelled);
      }
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.upgraded);
    });

    test('已处于编译期地址时失败不计数（无处可降）', () {
      final guard = EndpointGuard.instance;
      // 前置：skipped 态（未配置别名表）。
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.skipped);

      for (var i = 0; i < 10; i++) {
        guard.recordFailure(EndpointFailureKind.connectivity);
      }
      expect(guard.consecutiveFailures, 0);
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.skipped);
    });

    test('降级会广播基地址变化（装配层据此重建 Dio）', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;

      final events = <SpbEndpoints>[];
      final sub = SpbEndpoints.changes.listen(events.add);
      addTearDown(sub.cancel);

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1), reason: '一次降级只发一条事件');
      expect(events.single.apiBaseUrl, SpbEnv.apiBaseUrl);
    });

    test('重复降级是幂等的（不重复广播）', () async {
      await setUpgraded();
      final events = <SpbEndpoints>[];
      final sub = SpbEndpoints.changes.listen(events.add);
      addTearDown(sub.cancel);

      SpbEndpoints.downgrade();
      SpbEndpoints.downgrade();
      SpbEndpoints.downgrade();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
    });

    test('kept → downgraded 不广播（基地址没变）', () async {
      // 先落到 kept（探测失败）。
      await SpbEndpoints.resolveAndUpdate(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => false,
        timeout: const Duration(milliseconds: 5),
      );
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.kept);

      final events = <SpbEndpoints>[];
      final sub = SpbEndpoints.changes.listen(events.add);
      addTearDown(sub.cancel);

      SpbEndpoints.downgrade();
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty, reason: '结论变了但基地址相同，重建 Dio 没有意义');
    });
  });

  group('升级（慢路径 + 冷却）', () {
    test('冷却期未到时 tryUpgrade 不探测，而是等够再试', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      var probeCalls = 0;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      guard.probe = (_, _, _) async {
        probeCalls++;
        return true;
      };

      // 降级 → 计数达到阈值，安排冷却计时器。
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.downgraded,
      );

      // 立刻手动重探：冷却期未到 → 不得发起探测。
      await guard.tryUpgrade();
      expect(probeCalls, 0, reason: '冷却期内重探会造成探测风暴');
      expect(guard.hasPendingUpgrade, isTrue);
    });

    test('冷却期后重探成功 → 回到 preferred，结论 upgraded', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      guard.probe = (_, _, _) async => true;
      guard.preferredOverride = <String, String>{
        compiledHost: 'v6.example.com',
      };
      guard.upgradeCooldown = const Duration(minutes: 5);

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);

      // 把时钟推过冷却期，再手动触发（等价于计时器到期）。
      clock = clock.add(const Duration(minutes: 6));
      await guard.tryUpgrade();

      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(SpbEndpoints.current.chosenHost, 'v6.example.com');
    });

    test('冷却期后重探失败 → 重新安排下一轮，不放弃', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      guard.probe = (_, _, _) async => false;
      guard.upgradeCooldown = const Duration(minutes: 5);

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);

      clock = clock.add(const Duration(minutes: 6));
      await guard.tryUpgrade();

      expect(
        SpbEndpoints.current.probeOutcome,
        EndpointProbeOutcome.downgraded,
        reason: '重探失败应留在降级态',
      );
      expect(
        guard.hasPendingUpgrade,
        isTrue,
        reason: '一次「撞上切换中间态」的重探不该让恢复永久失效',
      );
    });

    test('非降级/保持态时 tryUpgrade 是空操作', () async {
      final guard = EndpointGuard.instance;
      var probeCalls = 0;
      guard.probe = (_, _, _) async {
        probeCalls++;
        return true;
      };
      await guard.tryUpgrade();
      expect(probeCalls, 0);
    });

    test('启动即 kept（无 IPv6）后：成功响应触发重探并升级', () async {
      // 典型场景：开机时没 IPv6 → 启动探测失败（kept）；后来连上 WiFi 有了
      // IPv6 → 下一个请求成功就应重探并升回源站。
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      await SpbEndpoints.resolveAndUpdate(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => false,
        timeout: const Duration(milliseconds: 5),
      );
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.kept);

      final guard = EndpointGuard.instance;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      guard.probe = (_, _, _) async => true;
      guard.preferredOverride = <String, String>{
        compiledHost: 'v6.example.com',
      };

      guard.recordSuccess();
      await Future<void>.delayed(Duration.zero);

      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.upgraded);
      expect(SpbEndpoints.current.chosenHost, 'v6.example.com');
    });

    test('kept 态下连续成功不重复探测（探测风暴防护）', () async {
      final compiledHost = Uri.parse(SpbEnv.apiBaseUrl).host;
      await SpbEndpoints.resolveAndUpdate(
        preferred: <String, String>{compiledHost: 'v6.example.com'},
        probe: (_, _, _) async => false,
        timeout: const Duration(milliseconds: 5),
      );
      final guard = EndpointGuard.instance;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      var probeCalls = 0;
      guard.probe = (_, _, _) async {
        probeCalls++;
        return false;
      };
      guard.preferredOverride = <String, String>{
        compiledHost: 'v6.example.com',
      };

      // 10 次成功响应，时钟不动。
      for (var i = 0; i < 10; i++) {
        guard.recordSuccess();
        await Future<void>.delayed(Duration.zero);
      }

      expect(probeCalls, 1, reason: '冷却期内的重复成功不得每次都探一次（每次 1.5s 超时）');
    });

    test('skipped 态下成功不触发探测（未配别名表）', () async {
      final guard = EndpointGuard.instance;
      var probeCalls = 0;
      guard.probe = (_, _, _) async {
        probeCalls++;
        return true;
      };
      guard.recordSuccess();
      await Future<void>.delayed(Duration.zero);
      expect(probeCalls, 0);
    });

    test('升级态下成功不触发探测（已是目标状态）', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      var probeCalls = 0;
      guard.probe = (_, _, _) async {
        probeCalls++;
        return true;
      };
      guard.recordSuccess();
      await Future<void>.delayed(Duration.zero);
      expect(probeCalls, 0);
    });

    test('升级也广播（装配层据此切回源站）', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      var clock = DateTime(2026, 1, 1, 12);
      guard.now = () => clock;
      guard.probe = (_, _, _) async => true;
      guard.upgradeCooldown = const Duration(minutes: 5);

      final events = <SpbEndpoints>[];
      final sub = SpbEndpoints.changes.listen(events.add);
      addTearDown(sub.cancel);

      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));

      guard.preferredOverride = <String, String>{
        compiledHost: 'v6.example.com',
      };
      clock = clock.add(const Duration(minutes: 6));
      await guard.tryUpgrade();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events.last.chosenHost, 'v6.example.com');
    });
  });

  group('重置与清理', () {
    test('resetForTest 清空计数、计时器与注入项', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      guard.failureThreshold = 1;
      guard.recordFailure(EndpointFailureKind.connectivity);
      expect(guard.hasPendingUpgrade, isTrue);

      SpbEndpoints.resetForTest();

      expect(guard.hasPendingUpgrade, isFalse);
      expect(guard.consecutiveFailures, 0);
      expect(guard.failureThreshold, 3);
      expect(SpbEndpoints.current.probeOutcome, EndpointProbeOutcome.skipped);
    });

    test('dispose 取消挂起计时器', () async {
      await setUpgraded();
      final guard = EndpointGuard.instance;
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      guard.recordFailure(EndpointFailureKind.connectivity);
      expect(guard.hasPendingUpgrade, isTrue);

      guard.dispose();
      expect(guard.hasPendingUpgrade, isFalse);
    });
  });

  group('SpbEndpoints.downgrade 自身', () {
    test('非升级态时降级是空操作（返回 current 同一内容）', () {
      final before = SpbEndpoints.current;
      final after = SpbEndpoints.downgrade();
      expect(after.probeOutcome, before.probeOutcome);
      expect(after.apiBaseUrl, before.apiBaseUrl);
    });

    test('降级保留 ufs 与 api 都回到编译期值', () async {
      await setUpgraded();
      expect(SpbEndpoints.current.ufsBaseUrl, contains('v6.example.com'));
      SpbEndpoints.downgrade();
      expect(SpbEndpoints.current.apiBaseUrl, compiledApi.toString());
      expect(SpbEndpoints.current.ufsBaseUrl, compiledUfs.toString());
    });

    test('isDowngraded 只对 downgraded 为真', () async {
      expect(SpbEndpoints.isDowngraded, isFalse);
      await setUpgraded();
      expect(SpbEndpoints.isDowngraded, isFalse);
      SpbEndpoints.downgrade();
      expect(SpbEndpoints.isDowngraded, isTrue);
    });
  });
}
