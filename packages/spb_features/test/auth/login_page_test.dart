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
    Future<String?> Function(String raw)? onImportSession,
    Size? size,
  }) async {
    // 窗口尺寸：默认 800×600。改小可复现「内容过高溢出」这类布局问题
    // （手机横屏 / 错误 banner 撑开的场景）。
    if (size != null) {
      tester.view
        ..physicalSize = size * tester.view.devicePixelRatio
        ..devicePixelRatio = tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          onSignIn: onSignIn,
          state: state,
          onImportSession: onImportSession,
        ),
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
        onSignIn: () async =>
            'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
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
      // （文案在桌面端闭环提交中从「正在跳转…」改为「正在登录…」，
      // 当时测试未同步，这里对齐实现。）
      expect(find.text('正在登录…'), findsOneWidget);
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

  group('登录页：粘贴导入会话', () {
    testWidgets('未注入 onImportSession 时不展示导入入口', (tester) async {
      // 移动端有深链回调，不需要用户手工搬运凭证。
      await pumpLogin(tester, onSignIn: () async => null);

      expect(find.byKey(const ValueKey('login-import-session')), findsNothing);
    });

    testWidgets('注入后展示入口，默认收起（SSO 是主路径）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async => null,
      );

      expect(
        find.byKey(const ValueKey('login-import-session')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('login-import-field')),
        findsNothing,
        reason: '默认展开会让登录页看起来有两条对等入口，喧宾夺主',
      );
    });

    testWidgets('展开后展示输入框与确认按钮，再点收起', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async => null,
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-import-field')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('login-import-confirm')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-import-field')), findsNothing);
    });

    testWidgets('粘贴内容后点导入，回调收到原始文本一次', (tester) async {
      final received = <String>[];
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async {
          received.add(raw);
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'id_token=test-id-token',
      );
      // `enterText` 不推进帧：确认按钮的可用性不依赖输入，但 setState 后
      // 需要一次 pump 让输入框内容反映到树里。
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      expect(received, ['id_token=test-id-token']);
    });

    testWidgets('输入为空时不调回调，只提示（避免必然失败的请求）', (tester) async {
      var calls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async {
          calls++;
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      expect(calls, 0, reason: '空输入不该发请求');
      expect(find.textContaining('请先粘贴'), findsOneWidget);
    });

    testWidgets('导入失败时展示原因（与 onSignIn 同语义）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async => '认不出粘贴的内容',
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'garbage',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.text('认不出粘贴的内容'), findsOneWidget);
    });

    testWidgets('导入成功后清空输入框（凭证不该留在 widget 里）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async => null,
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'id_token=test-id-token',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('login-import-field')),
      );
      expect(
        field.controller?.text,
        isEmpty,
        reason: '成功后输入框里的凭证没有用处，而它本身就是敏感值',
      );
    });

    testWidgets('导入中禁用确认按钮（防重复提交）', (tester) async {
      final gate = Completer<String?>();
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) => gate.future,
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'id_token=test-id-token',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-import-confirm')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('正在导入…'), findsOneWidget);

      gate.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('导入抛异常时兜住并显示可读错误（不白屏）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onImportSession: (raw) async => throw StateError('keyring 不可用'),
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'id_token=test-id-token',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('导入失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('小窗口 + 展开的导入区 + 错误 banner 不溢出（回归）', (tester) async {
      // 测试窗口默认 800×600；错误 banner + 展开的导入区（多行输入框）叠加后
      // 曾把 Column 撑出 16px（RenderFlex overflow），根布局缺滚动容器。
      // 手机横屏（高度 < 500）更容易命中。这里用 600×420 直接复现当时的溢出。
      await pumpLogin(
        tester,
        size: const Size(600, 420),
        onSignIn: () async => null,
        onImportSession: (raw) async => '认不出粘贴的内容',
      );

      await tester.tap(find.byKey(const ValueKey('login-import-session')));
      await tester.pumpAndSettle();
      // 小窗口下按钮初始在视口外，先滚到可见再点（真实用户同样要滚一下）。
      await tester.ensureVisible(
        find.byKey(const ValueKey('login-import-field')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-import-field')),
        'garbage',
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('login-import-confirm')),
      );
      await tester.tap(find.byKey(const ValueKey('login-import-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '错误态不得溢出（可滚动兑底）');
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
