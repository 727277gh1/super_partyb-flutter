import 'package:fluwx/fluwx.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 用 fluwx（微信 OpenSDK 的 Flutter 封装）实现 [WeChatOpenSdk]。
///
/// ## 为什么桥接放在 App 而不是 spb_platform
///
/// `spb_platform` 只定义契约与纯逻辑，不声明移动端插件——一旦在那里声明，
/// 桌面端构建也会把插件拖进依赖树（同 issue #36 的教训：声明了却没人 import
/// 的插件仍然要编译）。这里是「谁需要谁声明」。
///
/// ## 回调（`extMsg`）为什么没接
///
/// 小程序确认后回跳时，OpenSDK 会带 `app-parameter`（`extMsg`）。但本仓库的
/// 登录闭环**不依赖它**：scene 在唤起前就已落库，App 回到前台继续轮询
/// `/check/{scene}` 即可确认，再用 `/exchange` 换授权码。少一条通道就少一处
/// 会分叉的实现——若将来要做「回来即完成」的即时反馈，再接 `addSubscriber`
/// 收 `WeChatLaunchMiniProgramResponse.extMsg`。
class FluwxOpenSdk implements WeChatOpenSdk {
  FluwxOpenSdk({Fluwx? fluwx}) : _fluwx = fluwx ?? Fluwx();

  final Fluwx _fluwx;

  @override
  Future<bool> registerApi({
    required String appId,
    required String universalLink,
  }) async {
    try {
      final ok = await _fluwx.registerApi(
        appId: appId,
        universalLink: universalLink,
      );
      if (!ok) {
        SpbLog.warn('微信 OpenSDK 注册失败', {'appId': _mask(appId)});
      }
      return ok;
    } catch (e) {
      // 插件未注册（桌面端/纯 Dart 测试环境）也会走到这里：不能让它把登录
      // 流程炸掉，调用方据 false 走降级提示。
      SpbLog.warn('微信 OpenSDK 注册异常', {'error': e.toString()});
      return false;
    }
  }

  @override
  Future<bool> get isWeChatInstalled async {
    try {
      return await _fluwx.isWeChatInstalled;
    } catch (e) {
      SpbLog.warn('检测微信安装状态异常', {'error': e.toString()});
      return false;
    }
  }

  @override
  Future<bool> launchMiniProgram({
    required String userName,
    required String path,
  }) async {
    try {
      return await _fluwx.open(
        target: MiniProgram(
          username: userName,
          path: path,
          // 正式版：体验版/开发版仅对开发者与体验成员可见，线上用户打不开。
          miniProgramType: WXMiniProgramType.release,
        ),
      );
    } catch (e) {
      SpbLog.warn('唤起微信小程序异常', {'error': e.toString()});
      return false;
    }
  }

  static String _mask(String v) => v.length <= 6 ? v : '${v.substring(0, 6)}…';
}

/// 按编译期配置构造唤起器；未配置时返回空实现（登录页据此隐藏/降级）。
///
/// 用 [SpbEnv.isMobile] 而非 `defaultTargetPlatform`：本仓库的纯逻辑层都用
/// `dart:io`，保持一致；桌面端即使误注入 dart-define 也不会去碰插件。
WeChatMiniProgramLauncher createWeChatMiniProgramLauncher() {
  final config = WeChatMiniProgramLaunchConfig.fromEnv();
  final problem = config.problem;
  if (problem != null) {
    SpbLog.info('微信小程序唤起不可用', {'reason': problem});
    return NoopWeChatMiniProgramLauncher(problem);
  }
  if (!SpbEnv.isMobile) {
    return const NoopWeChatMiniProgramLauncher('桌面端不支持微信小程序唤起');
  }
  return OpenSdkMiniProgramLauncher(config: config, sdk: FluwxOpenSdk());
}
