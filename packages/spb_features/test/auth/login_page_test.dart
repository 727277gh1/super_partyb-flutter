import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_features/spb_features.dart';

/// 登录页测试。
///
/// ## 这个测试防的是什么
///
/// 登录页是**唯一**能让用户进入应用的入口，它的失败模式都是「静默」的：
/// - 按钮点了没反应（回调没接上）→ 用户以为应用坏了；
/// - 失败原因不展示 → 用户反复点击（如「client_id 未配置」这种必须让用户
///   看到的配置错误）；
/// - 重复点击发起多次授权 → 产生多个 state，回调只能匹配一个。
///
/// 故这里逐条断言「回调被调用几次」「错误是否显示」「加载态是否禁用按钮」。
void main() {
  /// 把登录页放进最小可用的 MaterialApp。
  Future<void> pumpLogin(
    WidgetTester tester, {
    required Future<String?> Function() onSignIn,
    AuthState state = const AuthState(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(onSignIn: onSignIn, state: state),
      ),
    );
    await tester.pump();
  }

  group('登录页渲染', () {
    testWidgets('展示 SSO 登录按钮与说明文案', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);

      expect(find.text('使用 SSO 登录'), findsOneWidget);
      expect(find.byKey(const ValueKey('login-sso-button')), findsOneWidget);
      expect(find.text('登录 Super PartyB'), findsOneWidget);
      expect(find.textContaining('统一身份认证中心'), findsOneWidget);
    });

    testWidgets('默认不显示错误条', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);
      expect(find.byKey(const ValueKey('login-error')), findsNothing);
    });

    testWidgets('展示外部传入的错误（AuthState.message）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        state: AuthState.failed('会话已过期，请重新登录'),
      );

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.text('会话已过期，请重新登录'), findsOneWidget);
    });
  });

  group('登录页发起授权', () {
    testWidgets('点击按钮调用 onSignIn 一次', (tester) async {
      var calls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async {
          calls++;
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('onSignIn 返回 null（成功发起）时不显示错误', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsNothing);
    });

    testWidgets('onSignIn 返回错误串时显示该错误', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => 'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('client_id 未配置'), findsOneWidget);
    });

    testWidgets('onSignIn 抛异常时兜住并显示可读错误（不白屏）', (tester) async {
      // 平台通道异常（如浏览器无法启动）不应让登录页崩掉——那样用户连
      // 「重试」都点不到。
      await pumpLogin(
        tester,
        onSignIn: () async => throw StateError('无法启动浏览器'),
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('无法发起登录'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '异常必须被兜住');
    });

    testWidgets('加载中按钮禁用且重复点击不重复发起授权', (tester) async {
      // 重复发起会生成多个 state，回调只能匹配其中一个，其余成为悬挂会话。
      var calls = 0;
      final gate = Completer<String?>();
      await pumpLogin(
        tester,
        onSignIn: () {
          calls++;
          return gate.future;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pump();

      // 加载态：文案变化 + 按钮禁用。
      expect(find.text('正在跳转…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-sso-button')),
      );
      expect(button.onPressed, isNull, reason: '加载中必须禁用');

      // 再次点击应被忽略。
      await tester.tap(
        find.byKey(const ValueKey('login-sso-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(calls, 1, reason: '重复点击不得重复发起授权');

      gate.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('使用 SSO 登录'), findsOneWidget);
    });

    testWidgets('新的点击清除上一次的本地错误', (tester) async {
      var attempt = 0;
      await pumpLogin(
        tester,
        onSignIn: () async {
          attempt++;
          return attempt == 1 ? '第一次失败' : null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();
      expect(find.text('第一次失败'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('login-sso-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('login-error')),
        findsNothing,
        reason: '重试成功后不得残留上次的错误',
      );
    });
  });

  group('AuthState', () {
    test('默认是 unknown（读取凭证是异步的，不能当成未登录）', () {
      // 若把「还没读到」当成「未登录」，启动瞬间会闪一下登录页；
      // 当成「已登录」则会先显示主界面再被踢走。
      expect(const AuthState().status, AuthStatus.unknown);
      expect(const AuthState().isAuthenticated, isFalse);
      expect(const AuthState().isUnauthenticated, isFalse);
    });

    test('三个状态的谓词互斥', () {
      expect(AuthState.authenticated.isAuthenticated, isTrue);
      expect(AuthState.authenticated.isUnauthenticated, isFalse);

      expect(AuthState.unauthenticated.isAuthenticated, isFalse);
      expect(AuthState.unauthenticated.isUnauthenticated, isTrue);

      expect(AuthState.unknown.isAuthenticated, isFalse);
      expect(AuthState.unknown.isUnauthenticated, isFalse);
    });

    test('failed 带错误消息且是未认证', () {
      final s = AuthState.failed('boom');
      expect(s.status, AuthStatus.unauthenticated);
      expect(s.message, 'boom');
    });

    test('copyWith 可清除消息（不是「无法清空」）', () {
      final s = AuthState.failed('boom');
      expect(s.copyWith(status: AuthStatus.authenticated).message, 'boom');
      expect(s.copyWith(clearMessage: true).message, isNull);
    });

    test('toString 含状态与消息', () {
      expect(AuthState.failed('boom').toString(), contains('unauthenticated'));
      expect(AuthState.failed('boom').toString(), contains('boom'));
    });
  });
}
