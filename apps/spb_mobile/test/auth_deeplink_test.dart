import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_mobile/auth_deeplink.dart';

/// 假的深链来源：直接喂 URI，不走平台通道。
class _FakeDeepLinkSource implements DeepLinkSource {
  _FakeDeepLinkSource({this.initial});

  Uri? initial;
  final controller = StreamController<Uri>.broadcast();
  int initialUriCalls = 0;

  @override
  Future<Uri?> initialUri() async {
    initialUriCalls++;
    return initial;
  }

  @override
  Stream<Uri> uriStream() => controller.stream;
}

/// 记录回调处理情况。
class _Recorder {
  final handled = <String>[];
  final errors = <String>[];
  String? returnError;

  Future<String?> onCode(String code, PkcePair pkce) async {
    handled.add(code);
    // 顺便断言 verifier 被真的传下来了（否则换 token 必然失败）。
    assert(pkce.verifier.isNotEmpty);
    return returnError;
  }

  void onError(String message) => errors.add(message);
}

/// 构造一个已写入请求的内存 store（`put` 是异步的，无法再用级联 `..put`）。
Future<InMemoryPendingAuthStore> _newStore({
  PendingAuthRequest? pending,
}) async {
  final store = InMemoryPendingAuthStore();
  if (pending != null) await store.put(pending);
  return store;
}

PendingAuthRequest _pending({String state = 'st_1'}) => PendingAuthRequest(
  state: state,
  pkce: PkcePair(verifier: 'v' * 43, challenge: 'ch'),
);

void main() {
  group('OidcCallbackUri', () {
    test('redirectUri 是 partyb://oidc/callback', () {
      expect(OidcCallbackUri.redirectUri, 'partyb://oidc/callback');
    });

    test('matches 只认 scheme + host + path 三者全对', () {
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://oidc/callback?code=x')),
        isTrue,
      );
      // 容忍结尾斜杠（部分平台转发时会补）。
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://oidc/callback/?code=x')),
        isTrue,
      );
      // 只 scheme 对、host 错 → 不是本应用的回调。
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://share/callback')),
        isFalse,
      );
      // 只 scheme 对、path 错。
      expect(OidcCallbackUri.matches(Uri.parse('partyb://oidc/evil')), isFalse);
      // scheme 错。
      expect(
        OidcCallbackUri.matches(Uri.parse('https://oidc/callback')),
        isFalse,
      );
      // 前缀相似但不是同一 path（防御 `callback-evil` 这类绕过）。
      expect(
        OidcCallbackUri.matches(Uri.parse('partyb://oidc/callback-evil')),
        isFalse,
      );
    });

    test('parse 对非本应用回调抛 AuthError', () {
      expect(
        () => OidcCallbackUri.parse(
          Uri.parse('partyb://share/x?code=c'),
          expectedState: 'st_1',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('parse 校验 state 不匹配', () {
      expect(
        () => OidcCallbackUri.parse(
          Uri.parse('partyb://oidc/callback?code=c&state=WRONG'),
          expectedState: 'st_1',
        ),
        throwsA(isA<AuthError>()),
      );
    });

    test('parse 接受合法回调并取出 code', () {
      final r = OidcCallbackUri.parse(
        Uri.parse('partyb://oidc/callback?code=c_1&state=st_1'),
        expectedState: 'st_1',
      );
      expect(r.code, 'c_1');
    });

    test('parse 把 error 回调映射为可读 AuthError', () {
      expect(
        () => OidcCallbackUri.parse(
          Uri.parse(
            'partyb://oidc/callback?error=access_denied&'
            'error_description=user+cancelled&state=st_1',
          ),
          expectedState: 'st_1',
        ),
        throwsA(
          isA<AuthError>().having(
            (e) => e.message,
            'message',
            allOf(contains('access_denied'), contains('user cancelled')),
          ),
        ),
      );
    });
  });

  group('PendingAuthRequestStore', () {
    test('consume 是一次性的（防重放同一个回调链接）', () async {
      final store = InMemoryPendingAuthStore();
      await store.put(_pending());

      expect(await store.consume(), isNotNull);
      expect(await store.consume(), isNull, reason: '同一个 state 不得被消费两次');
    });
  });

  group('AuthDeepLinkReceiver', () {
    test('冷启动链接会被处理（进程未运行时不会有 stream 事件）', () async {
      final source = _FakeDeepLinkSource(
        initial: Uri.parse('partyb://oidc/callback?code=cold&state=st_1'),
      );
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      await Future<void>.delayed(Duration.zero);

      expect(source.initialUriCalls, 1);
      expect(rec.handled, ['cold']);
      await receiver.dispose();
    });

    test('运行中的链接也会被处理', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_2&state=st_1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, ['c_2']);
      await receiver.dispose();
    });

    test('非本应用的深链被静默忽略（不报错、不换 token）', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      // 同 scheme 但不同 host —— 只看 scheme 的实现会把它当成回调。
      source.controller.add(Uri.parse('partyb://share/x?code=evil'));
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, isEmpty, reason: '不得把别的深链当成授权码');
      expect(rec.errors, isEmpty, reason: '用户点了别的链接不该弹错误');
      await receiver.dispose();
    });

    test('state 不匹配时不换 token，并通过 onError 上报', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending(state: 'st_1'));
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_evil&state=st_OTHER'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, isEmpty, reason: 'CSRF 校验失败不得发起换 token');
      expect(rec.errors, hasLength(1));
      await receiver.dispose();
    });

    test('没有进行中的登录时收到回调 → 拒绝（无法校验 state）', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: InMemoryPendingAuthStore().consume,
        onError: rec.onError,
      );

      await receiver.start();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_1&state=st_1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, isEmpty);
      expect(rec.errors, hasLength(1));
      expect(rec.errors.single, contains('没有进行中的登录'));
      await receiver.dispose();
    });

    test('onCode 返回错误文案时通过 onError 上报', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder()..returnError = 'invalid_grant';
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_1&state=st_1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, ['c_1']);
      expect(rec.errors, ['invalid_grant']);
      await receiver.dispose();
    });

    test('onCode 抛异常时被兜住（不冒泡到 stream 监听器）', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: (code, pkce) async => throw StateError('boom'),
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_1&state=st_1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.errors, hasLength(1));
      expect(rec.errors.single, contains('boom'));
      await receiver.dispose();
    });

    test('start 幂等：重复调用不会重复订阅', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      await receiver.start();

      expect(source.initialUriCalls, 1, reason: '第二次 start 不应再取初始链接');
      await receiver.dispose();
    });

    test('dispose 后不再处理链接', () async {
      final source = _FakeDeepLinkSource();
      final rec = _Recorder();
      final store = await _newStore(pending: _pending());
      final receiver = AuthDeepLinkReceiver(
        source: source,
        onCode: rec.onCode,
        pendingState: store.consume,
        onError: rec.onError,
      );

      await receiver.start();
      await receiver.dispose();
      source.controller.add(
        Uri.parse('partyb://oidc/callback?code=c_after&state=st_1'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(rec.handled, isEmpty);
      await source.controller.close();
    });
  });

  group('mobileSignIn', () {
    OidcConfig config() => const OidcConfig(
      issuer: 'https://app.example.com/idp',
      clientId: 'client_mobile',
      redirectUri: 'partyb://oidc/callback',
    );

    test('生成授权 URL：带 PKCE、state 与自定义 scheme 回调', () async {
      final store = InMemoryPendingAuthStore();
      Uri? opened;

      final error = await mobileSignIn(
        config: config(),
        store: store,
        launch: (url) async {
          opened = url;
          return true;
        },
        stateGenerator: () => 'st_fixed',
        pkceGenerator: () =>
            const PkcePair(verifier: 'verifier_value', challenge: 'ch_fixed'),
      );

      expect(error, isNull);
      final q = opened!.queryParameters;
      expect(q['client_id'], 'client_mobile');
      expect(q['redirect_uri'], 'partyb://oidc/callback');
      expect(q['state'], 'st_fixed');
      expect(q['code_challenge'], 'ch_fixed');
      expect(q['code_challenge_method'], 'S256');
      expect(q['response_type'], 'code');
      // verifier 绝不能出现在授权 URL 里（泄露即等于没有 PKCE）。
      expect(opened!.toString(), isNot(contains('verifier_value')));
    });

    test('把 state + verifier 一起存起来供回调使用', () async {
      final store = InMemoryPendingAuthStore();

      await mobileSignIn(
        config: config(),
        store: store,
        launch: (url) async => true,
        stateGenerator: () => 'st_fixed',
        pkceGenerator: () => const PkcePair(verifier: 'v_abc', challenge: 'ch'),
      );

      final pending = await store.consume();
      expect(pending, isNotNull);
      expect(pending!.state, 'st_fixed');
      expect(pending.pkce.verifier, 'v_abc');
    });

    test('client_id 未配置时不打开浏览器并返回可读错误', () async {
      final store = InMemoryPendingAuthStore();
      var launched = false;

      final error = await mobileSignIn(
        config: const OidcConfig(
          issuer: 'https://x/idp',
          clientId: '',
          redirectUri: 'partyb://oidc/callback',
        ),
        store: store,
        launch: (url) async {
          launched = true;
          return true;
        },
      );

      expect(launched, isFalse);
      expect(error, contains('client_id'));
    });

    test('打不开浏览器时清掉待验证请求（避免下次回调误判）', () async {
      final store = InMemoryPendingAuthStore();

      final error = await mobileSignIn(
        config: config(),
        store: store,
        launch: (url) async => false,
        stateGenerator: () => 'st_fixed',
        pkceGenerator: () => const PkcePair(verifier: 'v_abc', challenge: 'ch'),
      );

      expect(error, isNotNull);
      expect(await store.consume(), isNull, reason: '失败后不得留下待验证请求');
    });

    test('launch 抛异常时也清掉待验证请求', () async {
      final store = InMemoryPendingAuthStore();

      final error = await mobileSignIn(
        config: config(),
        store: store,
        launch: (url) async => throw StateError('no browser'),
        stateGenerator: () => 'st_fixed',
        pkceGenerator: () => const PkcePair(verifier: 'v_abc', challenge: 'ch'),
      );

      expect(error, contains('无法打开浏览器'));
      expect(await store.consume(), isNull);
    });
  });
}
