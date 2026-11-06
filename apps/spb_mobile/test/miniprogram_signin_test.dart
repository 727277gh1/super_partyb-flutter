import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_mobile/miniprogram_signin.dart';

/// 小程序登录编排（App 内「微信一键」）的测试。
///
/// ## 这个测试防的是什么
///
/// 这条链路有 5 个「静默失败点」，全都不报错、只表现为「点了没反应」：
/// 1. 唤起失败（没装微信）却继续轮询 → 用户干等 3 分钟；
/// 2. 轮询不设上限 → 用户切走后 Future 永远挂着，登录页卡在「正在等待确认」；
/// 3. 过期了还在轮询 → 白等；
/// 4. 兑换出的 code 没交给落盘点 → 拿不到 token，界面毫无变化；
/// 5. 失败后不清理 pending auth → 下次回调误判「有进行中的登录」。
///
/// 所以这里断言的是**分支走向与清理动作**，不是「能跑通」。
class _FakeClient extends MiniProgramLoginClient {
  _FakeClient({
    this.session,
    this.createError,
    this.states = const [MiniProgramPollState.done],
    this.exchangeCode = 'ory_ac_test',
    this.exchangeError,
  }) : super(
         issuer: Uri.parse('https://tbcc.atjog.com/idp'),
         clientId: 'client_test',
         redirectUri: 'partyb://oidc/callback',
       );

  final MiniProgramSession? session;
  final Object? createError;
  final List<MiniProgramPollState> states;
  final String exchangeCode;
  final Object? exchangeError;

  int pollCount = 0;
  int exchangeCount = 0;

  @override
  Future<MiniProgramSession> createSession({bool withScheme = true}) async {
    final err = createError;
    if (err != null) throw err;
    return session!;
  }

  @override
  Future<MiniProgramPollState> poll(String scene) async {
    final i = pollCount < states.length ? pollCount : states.length - 1;
    pollCount++;
    return states[i];
  }

  @override
  Future<String> exchange({
    required String scene,
    required PkcePair pkce,
    required String state,
  }) async {
    exchangeCount++;
    final err = exchangeError;
    if (err != null) throw err;
    return exchangeCode;
  }
}

MiniProgramSession sessionWith({String? schemeUrl, String? schemeError}) =>
    MiniProgramSession(
      scene: 'scene-1',
      qrCodeUrl: 'data:image/png;base64,AAA',
      schemeUrl: schemeUrl,
      schemeError: schemeError,
    );

void main() {
  late InMemoryPendingAuthStore store;

  setUp(() => store = InMemoryPendingAuthStore());

  Future<String?> run(
    _FakeClient client, {
    required List<Uri> launched,
    required List<({String code, PkcePair pkce})> persisted,
    bool launchOk = true,
    Duration pollTimeout = const Duration(minutes: 3),
    Future<void> Function(Duration)? sleep,
  }) {
    return miniProgramSignIn(
      client: client,
      store: store,
      launch: (uri) async {
        launched.add(uri);
        return launchOk;
      },
      onCode: (code, pkce) async {
        persisted.add((code: code, pkce: pkce));
        return null;
      },
      pollTimeout: pollTimeout,
      pollInterval: const Duration(milliseconds: 1),
      pollMaxInterval: const Duration(milliseconds: 2),
      sleep: sleep ?? (_) async {},
    );
  }

  test('全链路：唤起 → 轮询到 done → 兑换 → 交给落盘点', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      states: [MiniProgramPollState.pending, MiniProgramPollState.done],
      // 不用默认值：证明落盘的是**兑换返回的** code，而不是任何硬编码常量。
      exchangeCode: 'ory_ac_from_idp',
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(client, launched: launched, persisted: persisted);

    expect(error, isNull);
    expect(launched.single.toString(), 'weixin://dl/business/?t=xyz');
    expect(client.exchangeCount, 1, reason: '确认后必须兑换授权码');
    expect(persisted.single.code, 'ory_ac_from_idp');
    // 兑换用的 PKCE 必须与发起时一致，否则 IdP 会 invalid_grant。
    expect(persisted.single.pkce.verifier.length, greaterThanOrEqualTo(43));
  });

  group('创建会话失败', () {
    test('AuthError → 透出服务端文案，不唤起、不轮询、不留 pending', () async {
      final client = _FakeClient(
        createError: const AuthError('微信登录暂不可用，请改用其他登录方式'),
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(client, launched: launched, persisted: persisted);

      expect(error, '微信登录暂不可用，请改用其他登录方式');
      expect(launched, isEmpty, reason: '没拿到 scene 就无从唤起');
      expect(client.pollCount, 0);
      expect(client.exchangeCount, 0);
      // 不清理会留下一个永远等不到回调的 pending，下次深链回调误判
      // 「有进行中的登录」而直接走兑换。
      expect(await store.consume(), isNull);
    });

    test('非 AuthError（网络/序列化）→ 包一层可读文案，同样不留 pending', () async {
      final client = _FakeClient(createError: StateError('connection reset'));
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(client, launched: launched, persisted: persisted);

      // 直接把 StateError.toString() 抛给用户会看到「Bad state: ...」。
      expect(error, contains('无法创建微信登录会话'));
      expect(launched, isEmpty);
      expect(client.pollCount, 0);
      expect(await store.consume(), isNull);
    });
  });

  test('无法唤起微信（未安装）→ 立即报错，不进入轮询', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(
      client,
      launched: launched,
      persisted: persisted,
      launchOk: false,
    );

    expect(error, contains('微信'));
    expect(client.pollCount, 0, reason: '唤起失败就不该轮询（用户根本看不到小程序）');
    expect(client.exchangeCount, 0);
  });

  test('服务端没给 schemeUrl → 用 schemeError 提示，不发请求', () async {
    final client = _FakeClient(
      session: sessionWith(schemeError: '暂时无法直接唤起微信，请改用其他登录方式'),
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(client, launched: launched, persisted: persisted);

    expect(error, contains('无法直接唤起微信'));
    expect(launched, isEmpty);
    expect(client.pollCount, 0);
  });

  test('scene 过期 → 停止轮询并提示重试', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      states: [MiniProgramPollState.pending, MiniProgramPollState.expired],
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(client, launched: launched, persisted: persisted);

    expect(error, contains('超时'));
    expect(client.exchangeCount, 0, reason: '过期了不该再去兑换');
  });

  test('轮询超时（用户一直不确认）→ 有限时间内返回', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      states: [MiniProgramPollState.pending],
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(
      client,
      launched: launched,
      persisted: persisted,
      pollTimeout: const Duration(milliseconds: 50),
    );

    expect(error, contains('超时'));
    expect(client.exchangeCount, 0);
  });

  test('兑换失败 → 错误文案透出，不调用落盘点', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      exchangeError: const AuthError('登录会话已失效，请重新发起'),
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    final error = await run(client, launched: launched, persisted: persisted);

    expect(error, '登录会话已失效，请重新发起');
    expect(persisted, isEmpty);
  });

  test('失败后清理 pending auth（否则下次回调会误判有进行中的登录）', () async {
    final client = _FakeClient(
      session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      states: [MiniProgramPollState.expired],
    );
    final launched = <Uri>[];
    final persisted = <({String code, PkcePair pkce})>[];

    await run(client, launched: launched, persisted: persisted);

    // consume() 会把进行中的请求取走；再取一次应为空。
    expect(await store.consume(), isNull, reason: '失败路径必须清掉 pending');
  });

  group('pollMiniProgramSession', () {
    test('pending → done 时立即返回，且退避有上限', () async {
      final delays = <Duration>[];
      var calls = 0;
      final state = await pollMiniProgramSession(
        poll: () async {
          calls++;
          return calls < 6
              ? MiniProgramPollState.pending
              : MiniProgramPollState.done;
        },
        interval: const Duration(milliseconds: 10),
        maxInterval: const Duration(milliseconds: 25),
        timeout: const Duration(seconds: 5),
        sleep: (d) async => delays.add(d),
      );

      expect(state, MiniProgramPollState.done);
      expect(calls, 6);
      // 退避不得越过上限，也不得为 0（否则就是忙轮询）。
      expect(delays.every((d) => d > Duration.zero), isTrue);
      expect(
        delays.every((d) => d <= const Duration(milliseconds: 25)),
        isTrue,
        reason: '退避超过上限会拖慢确认后的响应',
      );
      expect(delays.last, greaterThan(delays.first), reason: '应逐次退避');
    });

    test('poll 抛异常时向上传播（不吞成 pending）', () async {
      expect(
        () => pollMiniProgramSession(
          poll: () async => throw StateError('boom'),
          sleep: (_) async {},
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
