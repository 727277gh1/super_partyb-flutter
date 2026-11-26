import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_features/spb_features.dart';

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
    this.shortCodeError,
    this.states = const [MiniProgramPollState.done],
    this.exchangeCode = 'ory_ac_test',
    this.exchangeError,
  }) : super(
         issuer: Uri.parse('https://dever.atjog.com/idp'),
         clientId: 'client_test',
         redirectUri: 'partyb://oidc/callback',
       );

  final MiniProgramSession? session;
  final Object? createError;
  final Object? shortCodeError;
  final List<MiniProgramPollState> states;
  final String exchangeCode;
  final Object? exchangeError;

  int pollCount = 0;
  int exchangeCount = 0;
  int shortCodeCount = 0;

  /// 轮询与兑换实际用的 scene（短码回退时必须换成新码，否则会一直等旧场景）。
  final List<String> polledScenes = [];
  final List<String> exchangedScenes = [];

  /// 记录 createSession 收到的 withScheme（OpenSDK 通道下应为 false）。
  bool? lastWithScheme;

  @override
  Future<MiniProgramSession> createSession({bool withScheme = true}) async {
    lastWithScheme = withScheme;
    final err = createError;
    if (err != null) throw err;
    return session!;
  }

  /// 短码会话下发的轮询密钥（模拟服务端行为）。
  String? shortCodePollSecret = 'short-code-secret';

  @override
  Future<MiniProgramSession> createShortCodeSession() async {
    shortCodeCount++;
    final err = shortCodeError;
    if (err != null) throw err;
    return MiniProgramSession(
      scene: 'A3F9K2',
      qrCodeUrl: '',
      shortCode: const MiniProgramShortCode(
        scene: 'A3F9K2',
        displayCode: 'A3F-9K2',
        expiresInSeconds: 300,
      ),
      pollSecret: shortCodePollSecret,
    );
  }

  /// 反向码兑换（#21）：记录收到的码，按需抛错。
  final List<String> redeemedCodes = [];
  final List<String> redeemedStates = [];
  Object? redeemError;
  String handoffAuthCode = 'ory_ac_handoff';

  @override
  Future<String> redeemHandoffCode({
    required String code,
    required PkcePair pkce,
    required String state,
  }) async {
    redeemedCodes.add(code);
    redeemedStates.add(state);
    final err = redeemError;
    if (err != null) throw err;
    return handoffAuthCode;
  }

  /// 收到的轮询密钥（服务端下发后必须一路带到轮询与兑换）。
  final List<String?> pollSecrets = [];
  final List<String?> exchangeSecrets = [];

  @override
  Future<MiniProgramPollState> poll(String scene, {String? pollSecret}) async {
    polledScenes.add(scene);
    pollSecrets.add(pollSecret);
    final i = pollCount < states.length ? pollCount : states.length - 1;
    pollCount++;
    return states[i];
  }

  @override
  Future<String> exchange({
    required String scene,
    required PkcePair pkce,
    required String state,
    String? pollSecret,
  }) async {
    exchangeCount++;
    exchangedScenes.add(scene);
    exchangeSecrets.add(pollSecret);
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
    Future<String?> Function(String scene)? launchViaSdk,
    void Function(MiniProgramShortCode code)? onShortCode,
  }) {
    return miniProgramSignIn(
      client: client,
      store: store,
      launch: (uri) async {
        launched.add(uri);
        return launchOk;
      },
      launchViaSdk: launchViaSdk,
      onShortCode: onShortCode,
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

  group('短码回退（个人主体小程序：唤起通道都不可用）', () {
    test('scheme 不可用 → 发短码、把码交给 UI、轮询/兑换都用新 scene', () async {
      final client = _FakeClient(
        session: sessionWith(schemeError: '暂时无法直接唤起微信，请改用其他登录方式'),
        states: [MiniProgramPollState.pending, MiniProgramPollState.done],
        exchangeCode: 'ory_ac_short_code',
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];
      final shown = <MiniProgramShortCode>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        onShortCode: shown.add,
      );

      expect(error, isNull, reason: '有短码回退时不该再报「无法唤起微信」');
      expect(client.shortCodeCount, 1);
      expect(shown.single.displayCode, 'A3F-9K2');
      expect(shown.single.ttl, const Duration(seconds: 300));
      expect(launched, isEmpty, reason: '没有 schemeUrl 可启动');
      // 关键：轮询与兑换必须换成短码 scene，否则会一直等那个没人能看见的旧场景
      expect(client.polledScenes.toSet(), {'A3F9K2'});
      expect(client.exchangedScenes, ['A3F9K2']);
      expect(persisted.single.code, 'ory_ac_short_code');
    });

    test('OpenSDK 运行期失败（85407）→ 同样回退短码，而不是把错误抛给用户', () async {
      // 这条是现实中最常见的形态：dart-define 配了 AppID，但小程序是个人主体，
      // WXLaunchMiniProgram 运行期才返回 85407。
      final client = _FakeClient(session: sessionWith(schemeError: 'ignored'));
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];
      final shown = <MiniProgramShortCode>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        launchViaSdk: (_) async => '无法唤起微信小程序：85407 没有权限',
        onShortCode: shown.add,
      );

      expect(error, isNull);
      expect(shown.single.displayCode, 'A3F-9K2');
      expect(client.exchangedScenes, ['A3F9K2']);
      expect(persisted.single.code, 'ory_ac_test');
      expect(launched, isEmpty, reason: 'SDK 失败后不该再试 url_launcher');
    });

    test('短码创建失败 → 返回原因并清掉 pending（不留下永不完成的登录）', () async {
      final client = _FakeClient(
        session: sessionWith(schemeError: '暂时无法直接唤起微信'),
        shortCodeError: const AuthError('尝试次数过多，请稍后再试'),
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];
      final shown = <MiniProgramShortCode>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        onShortCode: shown.add,
      );

      expect(error, contains('尝试次数过多'));
      expect(shown, isEmpty, reason: '没拿到码就不该切到「请输码」状态');
      expect(client.pollCount, 0);
      expect(client.exchangeCount, 0);
      expect(await store.consume(), isNull, reason: '失败路径必须清掉 pending');
    });

    test('没有短码 UI 承接时保持旧行为（返回原始错误，不空转）', () async {
      final client = _FakeClient(
        session: sessionWith(schemeError: '暂时无法直接唤起微信，请改用其他登录方式'),
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(client, launched: launched, persisted: persisted);

      expect(error, contains('无法直接唤起微信'));
      expect(client.shortCodeCount, 0, reason: '没有 UI 承接就别浪费一次配额');
      expect(client.pollCount, 0);
    });
  });

  group('OpenSDK 通道（launchViaSdk）', () {
    test('走 OpenSDK 时不请求 schemeUrl，直接用 scene 唤起', () async {
      final client = _FakeClient(
        session: sessionWith(schemeError: '未开通 URL Scheme'),
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];
      final sdkScenes = <String>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        launchViaSdk: (scene) async {
          sdkScenes.add(scene);
          return null;
        },
      );

      expect(error, isNull);
      expect(
        client.lastWithScheme,
        isFalse,
        reason: 'schemeUrl 注定失败（85407），不该再请求',
      );
      expect(sdkScenes, ['scene-1']);
      expect(launched, isEmpty, reason: '不该再走 url_launcher');
      expect(persisted.single.code, 'ory_ac_test');
    });

    test('OpenSDK 失败 → 直接返回原因，不轮询、不兑换', () async {
      final client = _FakeClient(session: sessionWith());
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        launchViaSdk: (_) async => '未检测到微信，请安装微信后重试',
      );

      expect(error, '未检测到微信，请安装微信后重试');
      expect(client.pollCount, 0);
      expect(client.exchangeCount, 0);
    });

    test('OpenSDK 抛异常 → 兜成可展示文案', () async {
      final client = _FakeClient(session: sessionWith());
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(
        client,
        launched: launched,
        persisted: persisted,
        launchViaSdk: (_) async => throw StateError('plugin missing'),
      );

      expect(error, contains('无法唤起微信小程序'));
      expect(client.pollCount, 0);
    });

    test('无 OpenSDK 时仍走 URL Scheme（非个人主体小程序的路径）', () async {
      final client = _FakeClient(
        session: sessionWith(schemeUrl: 'weixin://dl/business/?t=xyz'),
      );
      final launched = <Uri>[];
      final persisted = <({String code, PkcePair pkce})>[];

      final error = await run(client, launched: launched, persisted: persisted);

      expect(error, isNull);
      expect(client.lastWithScheme, isTrue);
      expect(launched.single.toString(), 'weixin://dl/business/?t=xyz');
    });
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

  group('反向登录码（小程序出码 → 本设备输码）', () {
    Future<String?> runHandoff(
      _FakeClient client, {
      required String code,
      required List<({String code, PkcePair pkce})> persisted,
      String Function()? stateGenerator,
    }) {
      return miniProgramHandoffSignIn(
        client: client,
        store: store,
        code: code,
        stateGenerator: stateGenerator,
        onCode: (authCode, pkce) async {
          persisted.add((code: authCode, pkce: pkce));
          return null;
        },
      );
    }

    test('兑换出的授权码交给落盘点（否则拿不到 token，界面毫无变化）', () async {
      final client = _FakeClient();
      final persisted = <({String code, PkcePair pkce})>[];

      final err = await runHandoff(
        client,
        code: 'AB2C-3D4E',
        persisted: persisted,
      );

      expect(err, isNull);
      expect(client.redeemedCodes, ['AB2C3D4E'], reason: '应把归一化后的码发给服务端');
      expect(persisted.single.code, 'ory_ac_handoff');
      // 落盘点的 pkce 必须与兑换时用的是同一个（否则换 token 时 verifier 对不上）。
      expect(persisted.single.pkce.verifier.isNotEmpty, isTrue);
    });

    test('先落盘 state/pkce 再兑换：落盘点要靠它校验 state', () async {
      final client = _FakeClient();
      final persisted = <({String code, PkcePair pkce})>[];

      await runHandoff(
        client,
        code: 'AB2C3D4E',
        persisted: persisted,
        stateGenerator: () => 'fixed-state-1234567890',
      );

      expect(client.redeemedStates, ['fixed-state-1234567890']);
    });

    test('长度不对时不发请求（本地就能判定的错误不该记成服务端失败）', () async {
      final client = _FakeClient();
      final persisted = <({String code, PkcePair pkce})>[];

      final err = await runHandoff(client, code: 'ABC', persisted: persisted);

      expect(err, contains('8 位'));
      expect(client.redeemedCodes, isEmpty);
      expect(persisted, isEmpty);
      // 没有发起就不该留下待完成请求：否则下次回调会误判「有进行中的登录」。
      expect(store.hasPending, isFalse);
    });

    test('兑换失败时清理 pending auth（不留下永远完成不了的请求）', () async {
      final client = _FakeClient()
        ..redeemError = const AuthError('登录码已过期，请在小程序里重新生成');
      final persisted = <({String code, PkcePair pkce})>[];

      final err = await runHandoff(
        client,
        code: 'AB2C3D4E',
        persisted: persisted,
      );

      expect(err, '登录码已过期，请在小程序里重新生成');
      expect(persisted, isEmpty);
      expect(store.hasPending, isFalse);
    });

    test('输入里的横线/空格/小写都能被归一化（用户抄码不会因为格式失败）', () async {
      final client = _FakeClient();
      final persisted = <({String code, PkcePair pkce})>[];

      await runHandoff(client, code: ' ab2c-3d4e ', persisted: persisted);

      expect(client.redeemedCodes, ['AB2C3D4E']);
    });
  });

  group('轮询密钥透传', () {
    test('短码会话下发的 pollSecret 一路带到轮询与兑换', () async {
      final client = _FakeClient(states: [MiniProgramPollState.done])
        ..shortCodePollSecret = 'secret-from-server';

      // 桌面端形态：没有唤起通道 → 直接发短码。
      final err = await miniProgramSignIn(
        client: client,
        store: store,
        onShortCode: (_) {},
        onCode: (_, _) async => null,
        pollInterval: const Duration(milliseconds: 1),
        pollMaxInterval: const Duration(milliseconds: 2),
      );
      expect(err, isNull);
      expect(client.pollSecrets, ['secret-from-server']);
      expect(client.exchangeSecrets, ['secret-from-server']);
    });

    test('短码回退换了 scene，密钥也必须换（旧密钥对新会话无效）', () async {
      final client = _FakeClient(
        session: sessionWith(schemeError: '85407'),
        states: [MiniProgramPollState.done],
      )..shortCodePollSecret = 'fallback-secret';

      final err = await run(
        client,
        launched: <Uri>[],
        persisted: [],
        onShortCode: (_) {},
      );
      expect(err, isNull);
      expect(client.polledScenes, ['A3F9K2']);
      expect(client.pollSecrets, ['fallback-secret']);
      expect(client.exchangeSecrets, ['fallback-secret']);
    });
  });
}
