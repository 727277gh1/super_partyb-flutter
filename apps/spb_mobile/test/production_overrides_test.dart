import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
import 'package:spb_mobile/background_notifications.dart';
import 'package:spb_mobile/providers.dart';
import 'package:spb_platform/spb_platform.dart';

import 'support/mobile_harness.dart';

/// 真的 [LocalNotificationSink]（能通过 `is LocalNotificationSink` 分支），
/// 但把权限请求记下来——`flutter test` 里没有平台通道，基类实现只会返回 false。
class _RecordingLocalSink extends LocalNotificationSink {
  int permissionCalls = 0;

  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return true;
  }
}

/// 生产装配（`main.dart` 的 override 清单）的回归测试——与桌面端
/// `production_overrides_test.dart` 同构，理由见该文件头。
///
/// 移动端此前更糟：`main.dart` 用的是裸 `ProviderContainer()`，**一个 override
/// 都没有**，故通知功能在 Android/iOS 上从未真正启用过。
void main() {
  ProviderContainer buildProductionContainer() {
    final container = ProviderContainer(overrides: buildProductionOverrides());
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
      expect(container.read(confirmationNotifierProvider), isNotNull);
      final sink = container.read(notificationSinkProvider);
      expect(sink, isA<LocalNotificationSink>());
    });

    test('不挂 override 时就是 Noop——这就是「漏挂」的实际后果', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final sink = container.read(notificationSinkProvider);
      expect(sink, isA<NoopNotificationSink>());
    });

    // 「通知自检」入口（issue #90）随 sink 真假而显隐：真 sink 才给函数，
    // Noop 给 null（页面据此不渲染入口）。这条同时守住两件事——漏挂 override
    // 时入口不会凭空出现，而装配正确时它必须存在（否则用户永远点不到自检）。
    test('通知自检入口只随真 sink 出现', () {
      final container = buildProductionContainer();
      expect(
        container.read(notificationSelfTestProvider),
        isNotNull,
        reason: '生产装配是真的 sink，自检入口必须可点',
      );

      final plain = ProviderContainer();
      addTearDown(plain.dispose);
      expect(
        plain.read(notificationSelfTestProvider),
        isNull,
        reason: 'Noop sink 下必须隐藏入口，而不是让用户点一个永远失败的自检',
      );
    });

    // 后台检查的排程器（§6.111）：装配层必须注入真实现，但**是否支持**由
    // 平台决定（只有 Android）。测试跑在 Linux 上，所以这里断言的是
    // 「装的是 WorkManager 实现」+「非 Android 不声称支持」——两条一起守，
    // 漏挂 override 时第一条会红，把平台门禁写成恒 true 时第二条会红。
    test('后台检查排程器：生产装配真实现，非 Android 不声称支持', () {
      final container = buildProductionContainer();
      final scheduler = container.read(notificationPollingSchedulerProvider);
      expect(scheduler, isA<WorkmanagerNotificationScheduler>());
      expect(
        scheduler.supported,
        isFalse,
        reason: '只有 Android 有可靠的后台排程；其他平台不得注册定时任务',
      );
      // 没有排程就没有后台检查读数可读 → 设置页不展示那一行。
      expect(container.read(backgroundCheckReportProvider), isNull);
    });
  });

  testWidgets('真 sink 装配下，启动即请求一次通知权限', (tester) async {
    // 见桌面端同名用例：后台发起权限请求会让首条确认卡通知被静默丢弃。
    final sink = _RecordingLocalSink();
    await pumpApp(tester, notificationSink: sink);

    expect(sink.permissionCalls, 1, reason: '启动时请求一次，且只一次（幂等）');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
