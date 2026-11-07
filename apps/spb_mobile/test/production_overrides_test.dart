import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_domain/spb_domain.dart';
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
  });

  testWidgets('真 sink 装配下，启动即请求一次通知权限', (tester) async {
    // 见桌面端同名用例：后台发起权限请求会让首条确认卡通知被静默丢弃。
    final sink = _RecordingLocalSink();
    await pumpApp(tester, notificationSink: sink);

    expect(sink.permissionCalls, 1, reason: '启动时请求一次，且只一次（幂等）');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
