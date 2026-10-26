import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_data/spb_data.dart';
import 'package:spb_domain/spb_domain.dart';

import 'package:spb_mobile/providers.dart';

/// 移动端对 `sync.auto` 的**读写兼容**。
///
/// ## 为什么移动端要读写一个自己不消费的字段
///
/// 移动端不装配自动同步排程器（后台定时器在 Android/iOS 上不可靠），设置页
/// 也不渲染该区块。但同一份 `SyncSettings` 会在两端之间流转：用户在桌面端
/// 开过「每 30 分钟」，然后打开移动端设置页改了「同步图片」并保存——若这里
/// 不写回 `sync.auto`，桌面端的配置就被**静默清掉**了，而用户完全不知道。
///
/// 即：移动端「不实现」不等于「可以破坏」。
void main() {
  ProviderContainer makeContainer(AppDatabase db) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        // 移动端目录由系统分配（走 path_provider 平台通道，测试里没有）。
        syncLocalRootProvider.overrideWith((ref) async => '/tmp/deliverables'),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('保存设置时原样写回 sync.auto（不丢桌面端配置）', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = makeContainer(db);

    const auto = AutoSyncConfig(onLaunch: true, intervalMinutes: 30);
    await container.read(saveSyncSettingsProvider)(
      const SyncSettings(auto: auto),
    );

    final prefs = PreferencesStore(db);
    expect(AutoSyncConfig.decode(await prefs.getString('sync.auto')), auto);
  });

  test('读取设置时带回 sync.auto', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = makeContainer(db);

    const auto = AutoSyncConfig(intervalMinutes: 60);
    await PreferencesStore(db).setString('sync.auto', auto.encode());

    final loaded = await container.read(loadSyncSettingsProvider)();
    expect(loaded.auto, auto);
  });

  test('从未配置过 → 读到全关（自动同步默认关闭）', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = makeContainer(db);

    final loaded = await container.read(loadSyncSettingsProvider)();
    expect(loaded.auto, AutoSyncConfig.disabled);
  });

  test('保存其他字段时不会改动已有的 sync.auto', () async {
    // 真实场景：桌面端开了周期同步 → 用户到移动端只改「同步图片」。
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = makeContainer(db);

    const auto = AutoSyncConfig(onLaunch: true, intervalMinutes: 180);
    await PreferencesStore(db).setString('sync.auto', auto.encode());

    final loaded = await container.read(loadSyncSettingsProvider)();
    await container.read(saveSyncSettingsProvider)(
      loaded.copyWith(filter: const SyncFilterConfig(includeMedia: true)),
    );

    final again = await container.read(loadSyncSettingsProvider)();
    expect(again.auto, auto, reason: '只改过滤配置不该动自动同步');
    expect(again.filter.includeMedia, isTrue);
  });
}
