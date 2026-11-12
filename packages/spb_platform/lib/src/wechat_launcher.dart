/// 唤起微信小程序登录的能力（微信 OpenSDK `WXLaunchMiniProgram`）。
///
/// ## 为什么需要这条通道
///
/// 微信的**服务端**唤起机制（加密 URL Scheme / URL Link / 明文 Scheme）全部
/// 限定「非个人主体」小程序，个人主体调用会拿到 `85407 no scheme permission`。
/// `WXLaunchMiniProgram` 是**客户端 SDK 调用**，不经过服务端 API，因此不受该
/// 限制——这是个人主体小程序唯一还能「从 App 唤起」的通道。
///
/// ## 分层
///
/// 本文件只定义**契约与纯逻辑**（配置校验、路径拼接、失败原因），不 import 任何
/// 微信插件：插件的具体桥接由移动端 App 注入（`apps/spb_mobile` 的
/// `FluwxOpenSdk`）。这样桌面端构建不会把移动端插件拖进依赖树，本包也能在
/// 无插件环境下跑单测。
library;

import 'package:spb_core/spb_core.dart';

/// 微信 OpenSDK 唤起小程序所需的账号配置。
///
/// 三个值都来自**微信开放平台**，与小程序 appid 不是同一个东西：
/// - [openAppId]：开放平台「移动应用」的 AppID（`wx…`），需审核通过才有；
/// - [userName]：小程序的**原始 ID**（`gh_…`，mp 后台「设置-基本设置」可查）；
/// - [universalLink]：iOS 必需（Android 忽略）。
class WeChatMiniProgramLaunchConfig {
  const WeChatMiniProgramLaunchConfig({
    required this.openAppId,
    required this.userName,
    this.universalLink,
  });

  /// 未配置（桌面端 / 未注入 dart-define 的构建）。
  static const empty = WeChatMiniProgramLaunchConfig(
    openAppId: '',
    userName: '',
  );

  /// 小程序里承接登录的页面路径。
  ///
  /// 必须与小程序端 `pages/index/index` 一致：它靠 query 里的 `scene` 落地
  /// （`router.params.scene`），换页面就会「能打开但拿不到 scene」。
  static const loginPagePath = 'pages/index/index';

  /// 开放平台「移动应用」AppID（`wx…`）。
  final String openAppId;

  /// 小程序原始 ID（`gh_…`）。
  final String userName;

  /// iOS Universal Link（Android 忽略，可空）。
  final String? universalLink;

  /// 从 `--dart-define` 读取（见 [SpbEnv]）。
  factory WeChatMiniProgramLaunchConfig.fromEnv() =>
      const WeChatMiniProgramLaunchConfig(
        openAppId: SpbEnv.wechatOpenAppId,
        userName: SpbEnv.wechatMiniProgramUsername,
        universalLink: SpbEnv.wechatUniversalLink,
      );

  /// 是否配置齐全（两个必填项都非空）。
  bool get isConfigured =>
      openAppId.trim().isNotEmpty && userName.trim().isNotEmpty;

  /// 配置问题（null = 没问题）。
  ///
  /// ## 为什么要做形态校验而不是只看非空
  ///
  /// 这里最容易犯的错是**把小程序 appid 填进 [openAppId]**（两者都 `wx` 开头，
  /// 但完全不是一个东西）。填错时 OpenSDK 返回 `bad param`，界面上只表现为
  /// 「唤起失败」，排查会绕很远。前缀校验能在启动时就把这类错误喊出来。
  String? get problem {
    if (!isConfigured) {
      if (openAppId.trim().isEmpty && userName.trim().isEmpty) {
        return '未配置微信 OpenSDK（缺移动应用 AppID 与小程序原始 ID）';
      }
      if (openAppId.trim().isEmpty) return '未配置微信移动应用 AppID';
      return '未配置小程序原始 ID（gh_ 开头）';
    }
    if (!openAppId.trim().startsWith('wx')) {
      return '移动应用 AppID 形态可疑（应以 wx 开头）';
    }
    if (!userName.trim().startsWith('gh_')) {
      // 常见错误：把小程序 appid（wx…）当成原始 ID。
      return '小程序原始 ID 形态可疑（应以 gh_ 开头，不是小程序 appid）';
    }
    return null;
  }

  /// 登录页路径 + scene query。
  String loginPath(String scene) => '$loginPagePath?scene=$scene';

  @override
  String toString() =>
      'WeChatMiniProgramLaunchConfig(appId: ${_mask(openAppId)}, '
      'userName: $userName)';

  static String _mask(String v) => v.length <= 6 ? v : '${v.substring(0, 6)}…';
}

/// OpenSDK 的最小桥接面（由移动端 App 用具体插件实现）。
///
/// 只暴露唤起小程序需要的三件事：注册、是否装了微信、唤起。
/// 做成接口是为了让 [OpenSdkMiniProgramLauncher] 的逻辑可以在无插件环境下单测。
abstract class WeChatOpenSdk {
  /// 注册移动应用（幂等，可重复调用）。
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  });

  /// 设备上是否安装了微信。
  Future<bool> get isWeChatInstalled;

  /// 唤起小程序并打开 [path]（可带 query）。
  Future<bool> launchMiniProgram({
    required String userName,
    required String path,
  });
}

/// 唤起小程序登录的对外契约。
abstract class WeChatMiniProgramLauncher {
  /// 是否配置齐全（未配置时上层应直接走 URL Scheme 或提示）。
  bool get isConfigured;

  /// 配置问题（null = 没问题），供日志与诊断使用。
  String? get problem;

  /// 唤起小程序登录页（带 [scene]）。
  ///
  /// 返回 null 表示已成功交给微信；否则是可直接展示给用户的原因。
  Future<String?> launchLogin(String scene);
}

/// 未配置 / 不支持平台的空实现。
///
/// 桌面端与未注入 dart-define 的构建注入它：调用方不需要写
/// `if (Platform.isAndroid)`，行为统一是「不可用 + 明确原因」。
class NoopWeChatMiniProgramLauncher implements WeChatMiniProgramLauncher {
  const NoopWeChatMiniProgramLauncher([this._reason]);

  final String? _reason;

  @override
  bool get isConfigured => false;

  @override
  String? get problem => _reason ?? '未配置微信 OpenSDK';

  @override
  Future<String?> launchLogin(String scene) async => problem;
}

/// 基于 OpenSDK 桥接的唤起实现（平台无关的逻辑层）。
class OpenSdkMiniProgramLauncher implements WeChatMiniProgramLauncher {
  OpenSdkMiniProgramLauncher({required this.config, required this.sdk});

  final WeChatMiniProgramLaunchConfig config;

  /// OpenSDK 桥接（移动端注入 fluwx 实现，测试注入假实现）。
  final WeChatOpenSdk sdk;

  /// 注册是否已完成。失败不缓存——下次重试（网络/时序问题不该永久失效）。
  bool _registered = false;

  @override
  bool get isConfigured => config.isConfigured && config.problem == null;

  @override
  String? get problem => config.problem;

  @override
  Future<String?> launchLogin(String scene) async {
    final configProblem = config.problem;
    if (configProblem != null) return configProblem;

    if (!await _ensureRegistered()) {
      return '微信 SDK 初始化失败，请改用其他登录方式';
    }

    // 先判是否装了微信：不判的话 OpenSDK 会静默失败或弹「未安装微信」，
    // 而用户看到的是「点了没反应」。
    if (!await sdk.isWeChatInstalled) {
      return '未检测到微信，请安装微信后重试，或改用 SSO 登录';
    }

    final ok = await sdk.launchMiniProgram(
      userName: config.userName.trim(),
      path: config.loginPath(scene),
    );
    if (!ok) return '无法唤起微信小程序，请确认微信为最新版本后重试';
    return null;
  }

  /// 幂等注册：OpenSDK 要求先 `registerApi` 才能发请求。
  Future<bool> _ensureRegistered() async {
    if (_registered) return true;
    final ok = await sdk.registerApi(
      appId: config.openAppId.trim(),
      universalLink: (config.universalLink ?? '').trim(),
    );
    if (ok) _registered = true;
    return ok;
  }
}
