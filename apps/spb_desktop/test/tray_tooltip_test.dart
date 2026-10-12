import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_desktop/providers.dart';
import 'package:spb_desktop/tray_tooltip.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

/// 记录托盘提示推送的能力桩。
class _RecordingCapabilities implements DesktopCapabilities {
  final List<String> tooltips = [];

  @override
  bool get isSupported => true;

  @override
  Future<void> setTrayTooltip(String tooltip) async {
    tooltips.add(tooltip);
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> showWindow(WindowRole role) async {}
  @override
  Future<void> hideWindow(WindowRole role) async {}
  @override
  Future<bool> registerHotkey(String id, HotkeyBinding binding) async => true;
  @override
  Future<void> unregisterHotkey(String id) async {}
  @override
  Future<bool> isLaunchAtStartupEnabled() async => false;
  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}
  @override
  Future<void> setTrayMenu(List<TrayMenuItem> items) async {}
  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<bool> revealPath(String path) async => false;
  @override
  Future<bool> openFile(String path) async => false;
  @override
  Future<DiagnosticsExportOutcome> saveDiagnostics(
    String text, {
    required String suggestedName,
  }) async => DiagnosticsExportOutcome.unsupported;
  @override
  Future<void> dispose() async {}
}

void main() {
  group('buildTrayState', () {
    test('未配置同步目录时如实说明', () {
      final state = buildTrayState(syncConfigured: false, syncing: false);

      expect(state.tooltip, contains('未配置同步目录'));
      expect(state.syncEnabled, isFalse);
      expect(state.syncing, isFalse);
    });

    test('同步中优先于「未配置目录」', () {
      // 两个条件同时成立时（用户在同步过程中清空了目录），「同步中」是更
      // 当下的信息——说「未配置目录」会与正在跑的任务矛盾。
      final state = buildTrayState(syncConfigured: false, syncing: true);

      expect(state.tooltip, contains('同步中'));
      expect(state.tooltip, isNot(contains('未配置同步目录')));
    });

    test('已配置且空闲时是基础名（不附加状态）', () {
      final state = buildTrayState(syncConfigured: true, syncing: false);

      expect(state.tooltip, 'Super PartyB');
    });

    test('未读数由 displayTooltip 拼装，不重复拼接', () {
      // TrayState.displayTooltip 会把未读数拼成「名称 (N)」。buildTrayState
      // 若自己再拼一次会得到「名称 (3) (3)」。
      final state = buildTrayState(
        syncConfigured: true,
        syncing: false,
        unreadCount: 3,
      );

      expect(state.displayTooltip, 'Super PartyB (3)');
      expect('(3)'.allMatches(state.displayTooltip).length, 1);
    });
  });

  group('runSyncActionProvider 的在途状态管理', () {
    test('同步抛异常时也在途状态也会复位（finally，不是成功路径专属）', () async {
      // ## 为什么这条必须测「异常路径」
      //
      // 托盘提示显示「同步中…」的依据就是这个状态。若异常时不复位，一次失败
      // 会让托盘**永久**停在「同步中…」——比没有提示更糟，用户会以为同步卡死。
      //
      // 用「未配置同步目录」制造异常：这是最常见的失败（用户还没选目录就点
      // 同步），且不需要真打 UFS。
      final container = ProviderContainer(
        overrides: [
          // 返回空目录 → `_runSync` 抛 PlatformError。
          loadSyncSettingsProvider.overrideWithValue(
            () async => const SyncSettings(),
          ),
        ],
      );
      addTearDown(container.dispose);

      // 前置条件：初始为「不在途」。
      expect(container.read(syncInFlightProvider), isFalse);

      await expectLater(
        container.read(runSyncActionProvider)(),
        throwsA(isA<PlatformError>()),
      );

      expect(
        container.read(syncInFlightProvider),
        isFalse,
        reason: '异常路径必须复位，否则托盘永远显示「同步中…」',
      );
    });

    test('同步进行中状态为 true（供托盘显示「同步中…」）', () async {
      // 用一个可控的 loadSyncSettings 把执行卡在「读设置」之后，
      // 从而观察到中间态。
      final gate = Completer<SyncSettings>();
      final container = ProviderContainer(
        overrides: [
          loadSyncSettingsProvider.overrideWithValue(() => gate.future),
        ],
      );
      addTearDown(container.dispose);

      final future = container.read(runSyncActionProvider)();
      // 让 provider 有机会进入闭包、置位在途。
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(syncInFlightProvider),
        isTrue,
        reason: '同步在跑时必须是在途，托盘才会显示「同步中…」',
      );

      // 收尾：让 run 走到异常路径结束（空目录 → PlatformError）。
      gate.complete(const SyncSettings());
      await expectLater(future, throwsA(isA<PlatformError>()));
      expect(container.read(syncInFlightProvider), isFalse);
    });
  });

  group('TrayTooltipController', () {
    test('push 按当前状态推送到托盘', () {
      final caps = _RecordingCapabilities();
      final controller = TrayTooltipController(
        capabilities: caps,
        syncConfigured: () => true,
        syncing: () => false,
      );

      controller.push();

      expect(caps.tooltips, ['Super PartyB']);
    });

    test('状态变化后 push 会推送新文本', () {
      final caps = _RecordingCapabilities();
      var syncing = false;
      final controller = TrayTooltipController(
        capabilities: caps,
        syncConfigured: () => true,
        syncing: () => syncing,
      );

      controller.push();
      syncing = true;
      controller.push();

      expect(caps.tooltips, ['Super PartyB', contains('同步中')]);
    });

    test('文本未变化时去重，不做重复的平台调用', () {
      // 这是**控制器自己**的去重，不是 notifier 的。
      // 用同一个状态反复 push（模拟「无关的重建/通知」），托盘只该被推一次。
      final caps = _RecordingCapabilities();
      final controller = TrayTooltipController(
        capabilities: caps,
        syncConfigured: () => true,
        syncing: () => false,
      );

      controller.push();
      controller.push();
      controller.push();

      expect(caps.tooltips.length, 1);
    });

    test('回到同一文本后仍去重（与「上一次推送」比较，而非「是否推过」）', () {
      // 同步中 → 空闲 → 同步中 → 空闲：文本在两种值间往复，每次都该推
      // （状态真的变了），但连续两次空闲只推一次。
      final caps = _RecordingCapabilities();
      var syncing = false;
      final controller = TrayTooltipController(
        capabilities: caps,
        syncConfigured: () => true,
        syncing: () => syncing,
      );

      controller.push(); // 空闲
      syncing = true;
      controller.push(); // 同步中
      syncing = false;
      controller.push(); // 空闲
      controller.push(); // 空闲（重复）

      expect(caps.tooltips.length, 3);
      expect(caps.tooltips.last, 'Super PartyB');
    });

    test('每次读取实时状态，不用构造时的快照', () {
      // 目录可能在设置页被改（甚至清空）；持有快照会一直显示旧状态。
      final caps = _RecordingCapabilities();
      var configured = false;
      final controller = TrayTooltipController(
        capabilities: caps,
        syncConfigured: () => configured,
        syncing: () => false,
      );

      controller.push();
      configured = true;
      controller.push();

      expect(caps.tooltips.first, contains('未配置同步目录'));
      expect(caps.tooltips.last, 'Super PartyB');
    });
  });
}
