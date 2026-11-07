import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_features/spb_features.dart';

import 'package:spb_desktop/providers.dart';

import 'support/desktop_harness.dart';

/// `reconcileAutoSyncProvider` 的**武装判据**。
///
/// ## 为什么单独测这一个闭包
///
/// 它是「什么时候该排程」的唯一判定点，而三条判据都会**静默**出错：
///
/// 1. 认证未就绪就武装 → 每轮 401，日志噪音且白跑；
/// 2. 没目录也武装 → 每轮抛「请先选择同步目录」，同样纯噪音；
/// 3. 登出后不 `pause` → 计时器继续跑，每轮都在无凭证状态下失败。
///
/// widget 测试只覆盖「保存后喂了新配置」（见 `router_settings_test.dart`），
/// 这三条判据在那里都不触发（测试默认就是已登录 + 有目录）。
void main() {
  /// 建一个最小容器：只 override 调度器与设置读取，认证走真实实现。
  ({ProviderContainer container, NoopAutoSyncScheduler scheduler}) make({
    required SyncSettings settings,
    TokenStore? tokenStore,
  }) {
    final scheduler = NoopAutoSyncScheduler();
    final container = ProviderContainer(
      overrides: [
        autoSyncSchedulerProvider.overrideWithValue(scheduler),
        loadSyncSettingsProvider.overrideWithValue(() async => settings),
        // 真实 `SecureTokenStore` 会走平台通道（测试里没有）。
        tokenStoreProvider.overrideWithValue(
          tokenStore ?? InMemoryTokenStore(freshTokens()),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, scheduler: scheduler);
  }

  /// 等到认证状态不再是 unknown（`restore()` 是异步的）。
  Future<void> awaitAuthSettled(ProviderContainer c) async {
    for (var i = 0; i < 100; i++) {
      if (c.read(authStateProvider).status != AuthStatus.unknown) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('认证状态在 100 次事件循环内没有落定');
  }

  test('已登录 + 有目录 → 按配置武装', () async {
    final m = make(
      settings: const SyncSettings(
        localRoot: '/home/u/out',
        auto: AutoSyncConfig(onLaunch: true, intervalMinutes: 30),
      ),
    );
    await awaitAuthSettled(m.container);
    expect(m.container.read(authStateProvider).isAuthenticated, isTrue);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.applied, [
      const AutoSyncConfig(onLaunch: true, intervalMinutes: 30),
    ]);
  });

  test('未登录 → pause，且不读设置、不武装', () async {
    final m = make(
      settings: const SyncSettings(
        localRoot: '/home/u/out',
        auto: AutoSyncConfig(onLaunch: true),
      ),
      // 空存储 → `restore()` 判为未登录。
      tokenStore: InMemoryTokenStore(null),
    );
    await awaitAuthSettled(m.container);
    expect(m.container.read(authStateProvider).isUnauthenticated, isTrue);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.applied, isEmpty);
    expect(m.scheduler.pauseCalls, 1);
  });

  test('没有同步目录 → pause（而不是排一个每轮必失败的计时器）', () async {
    final m = make(
      settings: const SyncSettings(
        // localRoot 为 null。
        auto: AutoSyncConfig(onLaunch: true, intervalMinutes: 15),
      ),
    );
    await awaitAuthSettled(m.container);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.applied, isEmpty);
    expect(m.scheduler.pauseCalls, 1);
  });

  test('「勾选若干对话」仍可同步 → 正常武装', () async {
    // 这条钉住「别把选中模式误判成不可同步」：`canSync` 只排除**单 group**
    // 模式（`!allGroups && groupIds.isEmpty`），而「勾选若干」是常见配置。
    final m = make(
      settings: const SyncSettings(
        localRoot: '/home/u/out',
        scope: SyncScopeConfig(allGroups: false, groupIds: ['g1']),
        auto: AutoSyncConfig(onLaunch: true),
      ),
    );
    await awaitAuthSettled(m.container);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.applied, [const AutoSyncConfig(onLaunch: true)]);
    expect(m.scheduler.pauseCalls, 0);
  });

  test('单 group 模式（canSync 为 false）→ pause', () async {
    // 单 group 没有 groupId，`toScope()` 会抛「缺少 group_id」——排一个每轮
    // 必抛的计时器毫无意义。
    final m = make(
      settings: const SyncSettings(
        localRoot: '/home/u/out',
        scope: SyncScopeConfig(allGroups: false),
        auto: AutoSyncConfig(onLaunch: true),
      ),
    );
    await awaitAuthSettled(m.container);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.applied, isEmpty);
    expect(m.scheduler.pauseCalls, 1);
  });

  test('配置是全关 → 等价于 pause（不排任何计时器）', () async {
    final m = make(settings: const SyncSettings(localRoot: '/home/u/out'));
    await awaitAuthSettled(m.container);

    await m.container.read(reconcileAutoSyncProvider)();

    expect(m.scheduler.pauseCalls, 1);
    expect(m.scheduler.isApplied, isFalse);
  });

  test('反复 reconcile 同一份配置 → 幂等（不重复武装）', () async {
    // 这是装配层的真实形态：启动一次 + 登录态变化一次 + 每次保存设置一次。
    final m = make(
      settings: const SyncSettings(
        localRoot: '/home/u/out',
        auto: AutoSyncConfig(intervalMinutes: 60),
      ),
    );
    await awaitAuthSettled(m.container);

    final reconcile = m.container.read(reconcileAutoSyncProvider);
    await reconcile();
    await reconcile();
    await reconcile();

    // 桩只记录调用，去重由真身 `apply` 负责（见
    // `packages/spb_domain/test/auto_sync_scheduler_test.dart` 的幂等组）。
    // 这里断言的是「装配层确实每次都喂了同一份配置」——若它开始喂不同的值
    // （比如每次读出一个新建对象却不等价），真身的幂等就会失效。
    expect(m.scheduler.applied, hasLength(3));
    expect(m.scheduler.applied.toSet(), {
      const AutoSyncConfig(intervalMinutes: 60),
    });
  });
}
