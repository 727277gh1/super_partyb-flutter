import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

import 'package:spb_desktop/providers.dart';

/// 桌面端「微信登录码」接线测试。
///
/// ## 这个测试防的是什么
///
/// 桌面**没有**可唤起的小程序（`WXLaunchMiniProgram` / URL Scheme 都是移动端
/// 概念）。如果哪天有人顺手把 `launch` 或 `launchViaSdk` 传进来，编排层就会先
/// 去建 scheme 会话：个人主体小程序在那条路上必然 85407，于是每次点击都白花
/// 一次微信 API 配额、多等一个网络往返，最后才退回短码——用户看到的是「点了
/// 半天才出现码」。
///
/// 所以这里断言的是**第一条请求就是 `?code=1`**，而不是「能跑通」。
class _FakeMiniProgramClient extends MiniProgramLoginClient {
  _FakeMiniProgramClient({this.createShortCodeError})
    : super(
        issuer: Uri.parse('https://app.example.com/idp'),
        clientId: 'client_desktop',
        redirectUri: 'http://127.0.0.1/callback',
      );

  /// 非空时 `createShortCodeSession` 直接抛这个错（模拟限流/网络失败）。
  final Object? createShortCodeError;

  /// 是否请求过 scheme 会话（桌面端必须始终为 false）。
  bool schemeSessionRequested = false;
  int shortCodeCount = 0;
  int pollCount = 0;
  final List<String> polledScenes = [];
  final List<String> exchangedScenes = [];

  @override
  Future<MiniProgramSession> createSession({bool withScheme = true}) async {
    schemeSessionRequested = true;
    return const MiniProgramSession(scene: 'scheme-scene', qrCodeUrl: '');
  }

  @override
  Future<MiniProgramSession> createShortCodeSession() async {
    shortCodeCount++;
    final err = createShortCodeError;
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

  @override
  Future<MiniProgramPollState> poll(String scene, {String? pollSecret}) async {
    polledScenes.add(scene);
    pollSecrets.add(pollSecret);
    pollCount++;
    return MiniProgramPollState.done;
  }

  @override
  Future<String> exchange({
    required String scene,
    required PkcePair pkce,
    required String state,
    String? pollSecret,
  }) async {
    exchangedScenes.add(scene);
    exchangeSecrets.add(pollSecret);
    return 'ory_ac_desktop';
  }

  /// 短码会话下发的轮询密钥与客户端实际带出去的密钥（服务端按会话存，
  /// 桌面端也必须一路带到轮询与兑换，否则 403）。
  String? shortCodePollSecret = 'desktop-secret';
  final List<String?> pollSecrets = [];
  final List<String?> exchangeSecrets = [];

  /// 反向码兑换（#21）。桌面端的主路径之一：不需要 public client 注册、
  /// 不需要邮件通道，只要手机上的小程序能出一个码。
  final List<String> redeemedCodes = [];
  final List<String> redeemedStates = [];
  Object? redeemError;

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
    return 'ory_ac_handoff';
  }
}

void main() {
  late _FakeMiniProgramClient client;
  late List<({String code, PkcePair pkce})> persisted;
  late List<MiniProgramShortCode> shown;
  late ProviderContainer container;

  setUp(() {
    client = _FakeMiniProgramClient();
    persisted = [];
    shown = [];
    container = ProviderContainer(
      overrides: [
        miniProgramLoginClientProvider.overrideWithValue(client),
        // 用内存实现替换安全存储：桌面端真实实现走 keyring，单测环境不可用。
        pendingAuthStoreProvider.overrideWithValue(InMemoryPendingAuthStore()),
        // 落盘点只关心「兑换出的 code 有没有交上来」，不在这里换 token。
        oidcCallbackHandlerProvider.overrideWithValue((code, pkce) async {
          persisted.add((code: code, pkce: pkce));
          return null;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  test('桌面端直接发短码：不请求 scheme 会话，码交给 UI，轮询/兑换都用码 scene', () async {
    final error = await container.read(wechatSignInActionProvider)(shown.add);

    expect(error, isNull);
    expect(
      client.schemeSessionRequested,
      isFalse,
      reason: '桌面唤不起小程序，请求 scheme 只会白花一次微信 API 配额',
    );
    expect(client.shortCodeCount, 1);
    expect(shown.single.displayCode, 'A3F-9K2');
    expect(client.polledScenes.toSet(), {'A3F9K2'});
    expect(client.exchangedScenes, ['A3F9K2']);
    // 兑换出的授权码必须交给落盘点（与 SSO / magic link 同一个落盘点）
    expect(persisted.single.code, 'ory_ac_desktop');
  });

  test('短码创建失败（限流等）→ 返回可展示文案，且不进入等待态', () async {
    client = _FakeMiniProgramClient(
      createShortCodeError: const AuthError('尝试次数过多，请稍后再试'),
    );
    container = ProviderContainer(
      overrides: [
        miniProgramLoginClientProvider.overrideWithValue(client),
        pendingAuthStoreProvider.overrideWithValue(InMemoryPendingAuthStore()),
        oidcCallbackHandlerProvider.overrideWithValue(
          (code, pkce) async => null,
        ),
      ],
    );
    addTearDown(container.dispose);

    final error = await container.read(wechatSignInActionProvider)(shown.add);

    expect(error, contains('尝试次数过多'));
    expect(shown, isEmpty, reason: '没拿到码就不该切到「请输码」状态');
    expect(client.pollCount, 0);
    expect(client.exchangedScenes, isEmpty);
  });

  test('桌面端反向登录码：只发一次兑换请求，不建任何会话、不轮询', () async {
    final error = await container.read(handoffSignInActionProvider)(
      'AB2C-3D4E',
    );

    expect(error, isNull);
    // 反向路径的全部价值就是「不依赖微信打开能力」：建会话/轮询都不该发生。
    expect(client.schemeSessionRequested, isFalse);
    expect(client.shortCodeCount, 0);
    expect(client.pollCount, 0);
    // 兑换的码要归一化后发（服务端也归一化，但本地先对齐能省一次往返）。
    expect(client.redeemedCodes, ['AB2C3D4E']);
    // 授权码交给与 SSO/magic link 同一个落盘点。
    expect(persisted.single.code, 'ory_ac_handoff');
  });

  test('桌面端反向登录码失败：返回可展示文案且不留 pending auth', () async {
    client.redeemError = const AuthError('登录码已过期，请在小程序里重新生成');
    final store = container.read(pendingAuthStoreProvider);

    final error = await container.read(handoffSignInActionProvider)('AB2C3D4E');

    expect(error, contains('已过期'));
    expect(persisted, isEmpty);
    expect((store as InMemoryPendingAuthStore).hasPending, isFalse);
  });

  test('桌面端把服务端下发的 pollSecret 带到轮询与兑换（否则服务端 403）', () async {
    client.shortCodePollSecret = 'desktop-secret-abc';

    // onShortCode 必须有：没有 UI 承接展示时编排层会保持旧的失败行为。
    final error = await container.read(wechatSignInActionProvider)((_) {});

    expect(error, isNull);
    expect(client.pollSecrets, ['desktop-secret-abc']);
    expect(client.exchangeSecrets, ['desktop-secret-abc']);
  });
}
