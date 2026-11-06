import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
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
    Future<String?> Function(
      void Function(MiniProgramShortCode code)? onShortCode,
    )?
    onWeChatSignIn,
    Future<String?> Function(String email, void Function() onSent)?
    onEmailSignIn,
    Future<String?> Function(String code)? onHandoffSignIn,
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
          onWeChatSignIn: onWeChatSignIn,
          onEmailSignIn: onEmailSignIn,
          onHandoffSignIn: onHandoffSignIn,
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

    testWidgets('SSO 说明提到浏览器页的「用邮件登录」（否则用户不知道还有这条路）', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);
      expect(find.textContaining('用邮件登录'), findsOneWidget);
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

  group('登录页：微信一键登录的短码回退', () {
    testWidgets('编排层回调短码 → 展示分组码与倒计时，流程结束后收掉', (tester) async {
      // 注意：短码展示期间有个 1s 的倒计时 Timer，`pumpAndSettle` 会一直等它，
      // 所以这里用显式 pump 推进时间。
      final gate = Completer<String?>();
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([onShortCode]) {
          onShortCode?.call(
            const MiniProgramShortCode(
              scene: 'A3F9K2',
              displayCode: 'A3F-9K2',
              expiresInSeconds: 300,
            ),
          );
          return gate.future;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pump();

      expect(find.byKey(const ValueKey('login-short-code')), findsOneWidget);
      expect(
        find.text('A3F-9K2'),
        findsOneWidget,
        reason: '必须展示分组形态（服务端 displayCode），不是裸 scene',
      );
      expect(find.text('05:00 内有效'), findsOneWidget);
      // 说明文案要跟着切换：这时候「将打开微信」已经不成立了
      expect(find.textContaining('输入登录码'), findsOneWidget);
      // 小程序名必须出现在文案里：App 唤不起小程序，用户得自己去微信里找它，
      // 只说「打开小程序」等于把「哪个、在哪」留给用户猜。
      expect(find.textContaining('成蹊'), findsWidgets);

      // 倒计时会走：3 秒后应为 04:57
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('04:57 内有效'), findsOneWidget);

      // 流程结束后（成功/失败一样）短码必须消失：留着只会让人继续抄旧码
      gate.complete(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-short-code')), findsNothing);
    });

    testWidgets('短码归零后显示已过期（而不是负数）', (tester) async {
      final gate = Completer<String?>();
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([onShortCode]) {
          onShortCode?.call(
            const MiniProgramShortCode(
              scene: 'A3F9K2',
              displayCode: 'A3F-9K2',
              expiresInSeconds: 2,
            ),
          );
          return gate.future;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('已过期，请重新发起'), findsOneWidget);
      gate.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('走正常唤起路径时完全不出现短码卡', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([_]) async => null,
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('login-short-code')), findsNothing);
    });
  });

  group('登录页：微信一键登录', () {
    testWidgets('未注入回调时不展示按钮（桌面端没有这条路径）', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);
      expect(find.byKey(const ValueKey('login-wechat-button')), findsNothing);
    });

    testWidgets('注入后展示按钮，点击调用一次回调', (tester) async {
      var calls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([_]) async {
          calls++;
          return null;
        },
      );

      expect(find.byKey(const ValueKey('login-wechat-button')), findsOneWidget);
      expect(find.text('微信一键登录'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('失败原因展示在错误条', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([_]) async => '无法唤起微信，请确认已安装微信后重试',
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('无法唤起微信'), findsOneWidget);
    });

    testWidgets('等待微信确认期间：按钮文案变化且两个入口都禁用', (tester) async {
      // 用 Completer 把回调挂住，模拟「已唤起小程序、正在轮询」的中间态。
      final gate = Completer<String?>();
      var ssoCalls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async {
          ssoCalls++;
          return null;
        },
        onWeChatSignIn: ([_]) => gate.future,
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pump();

      expect(find.text('请在微信中确认…'), findsOneWidget);
      // 两个入口互斥：并发发起会产生两套 state/PKCE，回调只能匹配一个。
      final wechat = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-wechat-button')),
      );
      final sso = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-sso-button')),
      );
      expect(wechat.onPressed, isNull, reason: '进行中应禁用，避免重复发起');
      expect(sso.onPressed, isNull, reason: '另一条登录路径也必须禁用');

      gate.complete(null);
      await tester.pumpAndSettle();
      expect(ssoCalls, 0);
      expect(find.text('微信一键登录'), findsOneWidget);
    });

    testWidgets('回调抛异常时兜住并展示（不白屏）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([_]) async =>
            throw StateError('platform channel missing'),
      );

      await tester.tap(find.byKey(const ValueKey('login-wechat-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('login-error')), findsOneWidget);
      expect(find.textContaining('微信登录失败'), findsOneWidget);
    });
  });

  group('登录页：邮箱 magic link', () {
    testWidgets('未注入回调时不展示邮箱入口', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);
      expect(find.byKey(const ValueKey('login-email-field')), findsNothing);
      expect(find.byKey(const ValueKey('login-email-button')), findsNothing);
    });

    testWidgets('注入后展示输入框与按钮（始终可见，不像粘贴那样收起）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) async => null,
      );
      expect(find.byKey(const ValueKey('login-email-field')), findsOneWidget);
      expect(find.text('用邮件登录'), findsOneWidget);
      expect(find.textContaining('一次性登录链接'), findsOneWidget);
    });

    testWidgets('空输入不调回调，只提示（避免必然失败的请求）', (tester) async {
      var calls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) async {
          calls++;
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pump();

      expect(calls, 0);
      expect(find.text('请先输入邮箱地址'), findsOneWidget);
    });

    testWidgets('输入邮箱后点按钮，回调收到裁掉空白的邮箱一次', (tester) async {
      final received = <String>[];
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) async {
          received.add(email);
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-email-field')),
        '  user@example.com  ',
      );
      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pumpAndSettle();

      expect(received, ['user@example.com']);
    });

    testWidgets('邮件受理后按钮文案切到「已发送」（用户知道该去查收）', (tester) async {
      final completer = Completer<String?>();
      void Function()? sentSignal;
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) {
          sentSignal = onSent;
          return completer.future;
        },
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-email-field')),
        'user@example.com',
      );
      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pump();
      expect(find.text('正在发送…'), findsOneWidget);

      // 模拟编排层在邮件受理成功后调 onSent。
      sentSignal!();
      await tester.pump();
      expect(find.text('已发送，请在邮件中确认…'), findsOneWidget);
      // 防枚举：文案不能说「邮件已发送」。
      expect(find.textContaining('如果该邮箱已注册'), findsOneWidget);

      completer.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('用邮件登录'), findsOneWidget);
    });

    testWidgets('等待期间三个入口全部禁用（避免并发发起两套登录）', (tester) async {
      final completer = Completer<String?>();
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onWeChatSignIn: ([_]) async => null,
        onEmailSignIn: (email, onSent) => completer.future,
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-email-field')),
        'user@example.com',
      );
      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pump();

      final sso = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-sso-button')),
      );
      final wechat = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-wechat-button')),
      );
      final email = tester.widget<FilledButton>(
        find.byKey(const ValueKey('login-email-button')),
      );
      expect(sso.onPressed, isNull);
      expect(wechat.onPressed, isNull);
      expect(email.onPressed, isNull);

      completer.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('失败原因展示在错误条（与 onSignIn 同语义）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) async => '登录链接已过期，请重新发起',
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-email-field')),
        'user@example.com',
      );
      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pumpAndSettle();

      expect(find.text('登录链接已过期，请重新发起'), findsOneWidget);
    });

    testWidgets('回调抛异常时兜住并展示（不白屏）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onEmailSignIn: (email, onSent) async => throw StateError('boom'),
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-email-field')),
        'user@example.com',
      );
      await tester.tap(find.byKey(const ValueKey('login-email-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('邮箱登录失败'), findsOneWidget);
    });
  });

  group('登录页：反向登录码（手机小程序出码）', () {
    testWidgets('不传回调时不渲染该区域（移动端/未配置时不占位）', (tester) async {
      await pumpLogin(tester, onSignIn: () async => null);
      expect(find.byKey(const ValueKey('login-handoff-field')), findsNothing);
      expect(find.byKey(const ValueKey('login-handoff-button')), findsNothing);
    });

    testWidgets('渲染输入框与按钮，并把用户输入的码交给回调', (tester) async {
      final received = <String>[];
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onHandoffSignIn: (code) async {
          received.add(code);
          return null;
        },
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-handoff-field')),
        'AB2C-3D4E',
      );
      await tester.tap(find.byKey(const ValueKey('login-handoff-button')));
      await tester.pump();

      // 原样交给编排层：归一化在 `miniProgramHandoffSignIn` 里统一做，
      // 页面再归一化一次会让「本地丢字符」与「服务端丢字符」出现两套规则。
      expect(received, ['AB2C-3D4E']);
    });

    testWidgets('空输入不发请求，直接提示', (tester) async {
      var calls = 0;
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onHandoffSignIn: (_) async {
          calls++;
          return null;
        },
      );

      await tester.tap(find.byKey(const ValueKey('login-handoff-button')));
      await tester.pump();

      expect(calls, 0);
      expect(find.text('请先输入登录码'), findsOneWidget);
    });

    testWidgets('失败原因展示给用户（码错了要能改，不是白按一次）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onHandoffSignIn: (_) async => '登录码无效或已被使用，请核对后重新输入',
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-handoff-field')),
        'AB2C3D4E',
      );
      await tester.tap(find.byKey(const ValueKey('login-handoff-button')));
      await tester.pump();

      expect(find.text('登录码无效或已被使用，请核对后重新输入'), findsOneWidget);
    });

    testWidgets('成功后清空输入框（码就是凭据，不该留在控件里）', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onHandoffSignIn: (_) async => null,
      );

      final field = find.byKey(const ValueKey('login-handoff-field'));
      await tester.enterText(field, 'AB2C3D4E');
      await tester.tap(find.byKey(const ValueKey('login-handoff-button')));
      await tester.pump();

      expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    });

    testWidgets('页面写明「2 分钟 / 一次性 / 别发给别人」', (tester) async {
      await pumpLogin(
        tester,
        onSignIn: () async => null,
        onHandoffSignIn: (_) async => null,
      );
      // 码是持有即授权的凭据：不写清楚，用户会截图发微信求助，拿到截图的人
      // 就能登录他的账号。
      expect(find.text('登录码 2 分钟内有效、只能用一次。请勿把码发给任何人。'), findsOneWidget);
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
