import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spb_features/spb_features.dart';
import 'package:spb_platform/spb_platform.dart';

/// 锁屏页（[SessionLockPage]）的五条分支（issue #94）。
///
/// ## 这个测试防的是什么
///
/// 门禁类功能最糟的失败方向不是「挡不住」，而是**把用户永久关在门外**：
///
/// - 把「用户取消」渲染成红色错误并清掉会话 → 用户划掉一次验证框就被登出；
/// - 平台锁定 / 设备不可用时还保留一个注定失败的「解锁」按钮 → 用户以为
///   应用坏了，看不到「重新登录」这个唯一出路；
/// - 「改用登录」回调没接上 → 用户只能反复戳指纹。
///
/// 这些都只在**状态切换**上体现，故这里逐条钉住渲染结果，配合假 gate
/// （不触碰真平台通道）。
void main() {
  /// 记录调用次数的假解锁动作。
  ({List<int> calls, Future<BiometricAuthOutcome> Function() fn}) fakeUnlock(
    List<BiometricAuthOutcome> outcomes,
  ) {
    var i = 0;
    final calls = <int>[];
    return (
      calls: calls,
      fn: () async {
        calls.add(i);
        final outcome = outcomes[i.clamp(0, outcomes.length - 1)];
        i++;
        return outcome;
      },
    );
  }

  Future<void> pumpLock(
    WidgetTester tester, {
    required Future<BiometricAuthOutcome> Function() onUnlock,
    Future<void> Function()? onUseSignIn,
    bool autoPrompt = false,
    bool allowDeviceCredential = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionLockPage(
          onUnlock: onUnlock,
          onUseSignIn: onUseSignIn ?? () async {},
          autoPrompt: autoPrompt,
          allowDeviceCredential: allowDeviceCredential,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('进页面不自动弹框时显示「解锁」按钮，点了才调用', (tester) async {
    final unlock = fakeUnlock([BiometricAuthOutcome.success]);
    await pumpLock(tester, onUnlock: unlock.fn);

    expect(unlock.calls, isEmpty, reason: 'autoPrompt=false 时不应主动验证');
    expect(find.byKey(const ValueKey('session-lock-unlock')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-lock-unlock')));
    await tester.pumpAndSettle();
    expect(unlock.calls, hasLength(1));
  });

  testWidgets('autoPrompt 时进页面即弹一次', (tester) async {
    final unlock = fakeUnlock([BiometricAuthOutcome.success]);
    await pumpLock(tester, onUnlock: unlock.fn, autoPrompt: true);

    expect(unlock.calls, hasLength(1));
  });

  testWidgets('取消：不显示红色错误，且解锁按钮仍可用', (tester) async {
    final unlock = fakeUnlock([BiometricAuthOutcome.canceled]);
    await pumpLock(tester, onUnlock: unlock.fn, autoPrompt: true);

    final hint = tester.widget<Text>(
      find.byKey(const ValueKey('session-lock-hint')),
    );
    expect(hint.data, '需要验证身份后才能继续');
    expect(
      hint.style?.color,
      isNot(
        Theme.of(tester.element(find.byType(SessionLockPage)))
            .colorScheme
            .error,
      ),
      reason: '取消是用户的选择，不该用错误色指责他',
    );
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('session-lock-unlock')),
    );
    expect(button.onPressed, isNotNull, reason: '取消后必须能再试一次');
  });

  testWidgets('验证失败：允许重试，再次点击会再调一次', (tester) async {
    final unlock = fakeUnlock([
      BiometricAuthOutcome.failed,
      BiometricAuthOutcome.success,
    ]);
    await pumpLock(tester, onUnlock: unlock.fn, autoPrompt: true);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('session-lock-hint'))).data,
      '验证未通过，可以再试一次',
    );
    await tester.tap(find.byKey(const ValueKey('session-lock-unlock')));
    await tester.pumpAndSettle();
    expect(unlock.calls, hasLength(2));
  });

  testWidgets('平台锁定：隐藏「解锁」，主按钮变成「重新登录」', (tester) async {
    final unlock = fakeUnlock([BiometricAuthOutcome.lockedOut]);
    var signInCalls = 0;
    await pumpLock(
      tester,
      onUnlock: unlock.fn,
      onUseSignIn: () async => signInCalls++,
      autoPrompt: true,
    );

    expect(
      find.byKey(const ValueKey('session-lock-unlock')),
      findsNothing,
      reason: '已被系统锁定，再弹验证框只会失败',
    );
    final primary = find.byKey(const ValueKey('session-lock-signin-primary'));
    expect(primary, findsOneWidget);

    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(signInCalls, 1, reason: '「重新登录」必须接到注入的回调');
  });

  testWidgets('设备不可用：同样只剩「重新登录」，且说明原因', (tester) async {
    final unlock = fakeUnlock([BiometricAuthOutcome.unavailable]);
    await pumpLock(tester, onUnlock: unlock.fn, autoPrompt: true);

    expect(find.byKey(const ValueKey('session-lock-unlock')), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('session-lock-hint'))).data,
      '当前设备无法完成本机验证，请重新登录',
    );
  });

  testWidgets('「改用登录」在可重试时也提供（不把用户困住）', (tester) async {
    var signInCalls = 0;
    await pumpLock(
      tester,
      onUnlock: () async => BiometricAuthOutcome.success,
      onUseSignIn: () async => signInCalls++,
    );

    await tester.tap(find.byKey(const ValueKey('session-lock-signin')));
    await tester.pumpAndSettle();
    expect(signInCalls, 1);
  });

  testWidgets('允许设备密码降级时，副标题写明可以用密码', (tester) async {
    await pumpLock(
      tester,
      onUnlock: () async => BiometricAuthOutcome.success,
      allowDeviceCredential: true,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('session-lock-subtitle')))
          .data,
      contains('设备密码'),
    );

    await pumpLock(
      tester,
      onUnlock: () async => BiometricAuthOutcome.success,
      allowDeviceCredential: false,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('session-lock-subtitle')))
          .data,
      isNot(contains('设备密码')),
    );
  });

  testWidgets('onUnlock 抛异常时不炸页面，仍能重试', (tester) async {
    var calls = 0;
    await pumpLock(
      tester,
      onUnlock: () async {
        calls++;
        if (calls == 1) throw StateError('平台通道炸了');
        return BiometricAuthOutcome.success;
      },
      autoPrompt: true,
    );

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('session-lock-hint'))).data,
      '验证未通过，可以再试一次',
    );
    expect(find.byKey(const ValueKey('session-lock-unlock')), findsOneWidget);
  });
}
