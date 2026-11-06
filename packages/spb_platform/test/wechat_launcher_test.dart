import 'package:flutter_test/flutter_test.dart';
import 'package:spb_platform/spb_platform.dart';

/// 微信 OpenSDK 唤起逻辑的测试（不依赖插件：桥接用假实现）。
///
/// ## 这个测试防的是什么
///
/// 这条通道的失败几乎都是**静默**的，而且都在真正调微信之前就能判定：
/// - 配置里把小程序 appid 填进「移动应用 AppID」（两者都 `wx` 开头）；
/// - 把小程序 appid 当成原始 ID（`gh_` 前缀）；
/// - 没装微信却继续发起 → OpenSDK 静默失败，用户只看到「点了没反应」；
/// - `registerApi` 失败后仍发请求 → `bad param`，同样只表现为「唤起失败」。
///
/// 所以这里断言的是**判定顺序与文案**，不是「能唤起」。
class _FakeSdk implements WeChatOpenSdk {
  _FakeSdk({
    this.registerResult = true,
    this.installed = true,
    this.launchResult = true,
    this.registerThrows = false,
  });

  final bool registerResult;
  final bool installed;
  final bool launchResult;
  final bool registerThrows;

  int registerCalls = 0;
  int launchCalls = 0;
  String? lastUserName;
  String? lastPath;
  String? lastAppId;
  String? lastUniversalLink;

  @override
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  }) async {
    registerCalls++;
    lastAppId = appId;
    lastUniversalLink = universalLink;
    if (registerThrows) throw StateError('plugin missing');
    return registerResult;
  }

  @override
  Future<bool> get isWeChatInstalled async => installed;

  @override
  Future<bool> launchMiniProgram({
    required String userName,
    required String path,
  }) async {
    launchCalls++;
    lastUserName = userName;
    lastPath = path;
    return launchResult;
  }
}

const _okConfig = WeChatMiniProgramLaunchConfig(
  openAppId: 'wx1234567890abcdef',
  userName: 'gh_abcdef123456',
  universalLink: 'https://tbcc.atjog.com/app/',
);

void main() {
  group('WeChatMiniProgramLaunchConfig', () {
    test('空配置判为未配置，且指出缺什么', () {
      const c = WeChatMiniProgramLaunchConfig.empty;
      expect(c.isConfigured, isFalse);
      expect(c.problem, contains('未配置'));
    });

    test('只缺一个时指出缺哪个（而不是笼统说未配置）', () {
      const noAppId = WeChatMiniProgramLaunchConfig(
        openAppId: '',
        userName: 'gh_abc',
      );
      expect(noAppId.problem, contains('移动应用 AppID'));

      const noUser = WeChatMiniProgramLaunchConfig(
        openAppId: 'wxabc',
        userName: '',
      );
      expect(noUser.problem, contains('小程序原始 ID'));
    });

    test('把小程序 appid 当成原始 ID → 形态校验拦下', () {
      // 最常见的配置错误：两个都是 wx 开头，但 userName 必须 gh_ 开头。
      const c = WeChatMiniProgramLaunchConfig(
        openAppId: 'wx1234567890abcdef',
        userName: 'wx1234567890abcdef',
      );
      expect(c.isConfigured, isTrue);
      expect(c.problem, contains('gh_'));
    });

    test('移动应用 AppID 不以 wx 开头 → 拦下', () {
      const c = WeChatMiniProgramLaunchConfig(
        openAppId: 'gh_abcdef',
        userName: 'gh_abcdef',
      );
      expect(c.problem, contains('wx'));
    });

    test('合法配置没有问题', () {
      expect(_okConfig.problem, isNull);
      expect(_okConfig.isConfigured, isTrue);
    });

    test('登录路径带 scene（小程序靠 router.params.scene 落地）', () {
      expect(_okConfig.loginPath('abc123'), 'pages/index/index?scene=abc123');
    });
  });

  group('OpenSdkMiniProgramLauncher', () {
    test('未配置时直接给出原因，不碰 SDK', () async {
      final sdk = _FakeSdk();
      final launcher = OpenSdkMiniProgramLauncher(
        config: WeChatMiniProgramLaunchConfig.empty,
        sdk: sdk,
      );
      expect(launcher.isConfigured, isFalse);

      final err = await launcher.launchLogin('s1');
      expect(err, contains('未配置'));
      expect(sdk.registerCalls, 0, reason: '未配置就不该初始化 SDK');
      expect(sdk.launchCalls, 0);
    });

    test('正常路径：注册一次 → 判安装 → 带 scene 唤起', () async {
      final sdk = _FakeSdk();
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);

      expect(await launcher.launchLogin('scene-1'), isNull);
      expect(sdk.lastUserName, 'gh_abcdef123456');
      expect(sdk.lastPath, 'pages/index/index?scene=scene-1');
      expect(sdk.lastAppId, 'wx1234567890abcdef');
      expect(sdk.lastUniversalLink, 'https://tbcc.atjog.com/app/');
    });

    test('注册是幂等的（重复登录不重复 registerApi）', () async {
      final sdk = _FakeSdk();
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);

      await launcher.launchLogin('s1');
      await launcher.launchLogin('s2');
      expect(sdk.registerCalls, 1);
      expect(sdk.launchCalls, 2);
    });

    test('注册失败 → 不发起唤起（否则只会拿到 bad param）', () async {
      final sdk = _FakeSdk(registerResult: false);
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);

      final err = await launcher.launchLogin('s1');
      expect(err, contains('初始化失败'));
      expect(sdk.launchCalls, 0);
    });

    test('注册失败不缓存：下次仍会重试', () async {
      final failing = _FakeSdk(registerResult: false);
      final launcher = OpenSdkMiniProgramLauncher(
        config: _okConfig,
        sdk: failing,
      );
      await launcher.launchLogin('s1');
      await launcher.launchLogin('s2');
      expect(failing.registerCalls, 2, reason: '时序问题不该永久失效');
    });

    test('未安装微信 → 提示安装/改用 SSO，不发起唤起', () async {
      final sdk = _FakeSdk(installed: false);
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);

      final err = await launcher.launchLogin('s1');
      expect(err, contains('未检测到微信'));
      expect(err, contains('SSO'));
      expect(sdk.launchCalls, 0);
    });

    test('唤起返回 false → 给出可重试原因', () async {
      final sdk = _FakeSdk(launchResult: false);
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);

      final err = await launcher.launchLogin('s1');
      expect(err, contains('无法唤起'));
    });

    test('桥接抛异常时向上抛（由上层兜住并展示，不吞成成功）', () async {
      final sdk = _FakeSdk(registerThrows: true);
      final launcher = OpenSdkMiniProgramLauncher(config: _okConfig, sdk: sdk);
      expect(() => launcher.launchLogin('s1'), throwsStateError);
    });
  });

  group('NoopWeChatMiniProgramLauncher', () {
    test('永远不可用，并透传原因', () async {
      const l = NoopWeChatMiniProgramLauncher('桌面端不支持');
      expect(l.isConfigured, isFalse);
      expect(l.problem, '桌面端不支持');
      expect(await l.launchLogin('s'), '桌面端不支持');
    });
  });
}
