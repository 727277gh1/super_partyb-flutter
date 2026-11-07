import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_desktop/providers.dart';
import 'package:spb_domain/spb_domain.dart';
import 'package:spb_platform/spb_platform.dart';

import 'support/desktop_harness.dart';

/// 真的 [LocalNotificationSink]（所以能通过 `is LocalNotificationSink` 分支），
/// 但把权限请求记下来——`flutter test` 里没有平台通道，基类实现只会返回 false。
class _RecordingLocalSink extends LocalNotificationSink {
  int permissionCalls = 0;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return true;
  }
}

/// 生产装配（`main.dart` 的 override 清单）的回归测试。
///
/// ## 为什么需要这个文件
///
/// 通知 sink 曾**从未**被覆盖过：`main.dart` 只挂了桌面能力与拖拽能力，
/// `notificationSinkProvider` 一直是默认的 `NoopNotificationSink`。后果是整条
/// 通知链路静默失效——`requestPermission()` 恒 false，`handleItems` 恒返回空，
/// 而 `if (sink is LocalNotificationSink)` 里的初始化与点击导航接线也全都不执行，
/// **没有任何报错**。
///
/// 单测全绿是因为两处测试各自绕开了这条线：页面用例自己注入
/// `RecordingNotificationSink`（见 `desktop_harness.dart`），
/// `check_wiring_parity.sh` 只比对共享组件的具名参数、不看 provider override。
/// 这正是 AGENTS.md §6.17 那类「接线断裂，页面测试抓不到」的失效。
///
/// 故这里断言的是**生产实际会拿到的那套 override**，而不是某个页面。
void main() {
  ProviderContainer buildProductionContainer() {
    final container = ProviderContainer(
      overrides: buildProductionOverrides(
        capabilities: const NoopDesktopCapabilities(),
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  group('生产 override 清单', () {
    test('通知 sink 是真实实现（不是 Noop）', () {
      final container = buildProductionContainer();
      final sink = container.read(notificationSinkProvider);
      expect(
        sink,
        isA<LocalNotificationSink>(),
        reason: '生产必须用真实 sink；用 Noop 等于通知功能整条不存在',
      );
    });

    test('判定器与 sink 读的是同一个 provider', () {
      final container = buildProductionContainer();
      // `confirmationNotifierProvider` 内部 `ref.watch(notificationSinkProvider)`：
      // 若 override 没生效，它拿到的就是 Noop（无法从外部直接观测），
      // 故这里钉住「判定器可构造」+「sink 已是真实实现」。
      expect(container.read(confirmationNotifierProvider), isNotNull);
      final sink = container.read(notificationSinkProvider);
      expect(sink, isA<LocalNotificationSink>());
    });

    test('拖拽能力也在同一份清单里（防止只挂一半）', () {
      final container = buildProductionContainer();
      final dragDrop = container.read(dragDropCapabilityProvider);
      expect(dragDrop, isA<DesktopDragDropCapability>());
    });

    test('不挂 override 时就是 Noop——这就是「漏挂」的实际后果', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sink = container.read(notificationSinkProvider);
      expect(sink, isA<NoopNotificationSink>());
    });
  });

  testWidgets('真 sink 装配下，启动即请求一次通知权限', (tester) async {
    // 权限必须在**启动时**（用户看得见应用）请求：判定流程是「拿不到权限就
    // 不发」，而 Android 13+ 在后台发起的请求要等用户回到应用才弹框——
    // 于是首条后台确认卡通知会在权限框出现前就被丢弃，且不会重发。
    final sink = _RecordingLocalSink();
    await pumpApp(tester, notificationSink: sink);

    expect(sink.permissionCalls, 1, reason: '启动时请求一次，且只一次（幂等）');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
