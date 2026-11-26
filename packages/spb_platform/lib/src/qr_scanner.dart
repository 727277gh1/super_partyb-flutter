import 'package:flutter/widgets.dart';

/// 相机扫码能力（契约）。
///
/// ## 为什么是接口，而不是让登录页直接调插件
///
/// 登录页在 `spb_features` 里、两端共用；而 `mobile_scanner` 只在
/// Android / iOS / macOS 上有实现。把相机塞进页面会让 `spb_features` 直接依赖
/// 平台插件——与 [DesktopCapabilities] 同一条取向（§6.4：平台差异一律收敛在
/// 本包，桌面端注入空实现）。接口化之后，登录页只知道「能不能扫」和「扫出
/// 什么文本」，相机从哪来由 app 装配层决定。
///
/// ## 为什么 [scan] 要收 `BuildContext`
///
/// 相机预览必须是**整屏页面**（预览、权限提示、关闭按钮都在它上面，见
/// `apps/spb_mobile/lib/qr_scanner_page.dart`），而「打开一个页面」只能由持有
/// 调用点上下文的调用方发起（实现里自己找 Navigator 就得引入全局
/// `navigatorKey`——本仓库没有，也不打算为这一处引）。故由调用方把 context
/// 传进来，实现只负责把它变成一次「进相机页 → 返回扫到的文本」。
///
/// ## 为什么取消/不可用返回 null 而不是抛异常
///
/// 「用户取消」「权限被拒」「这台设备没相机」都是**预期内**结果（与
/// `DirectoryPicker.pick` 的「取消也是正常结果」一致）。异常语义留给真正的
/// 程序错误——调用方拿 null 时一律安静返回登录页，不该弹一个错误横幅。
abstract class QrScanner {
  /// 这台设备能不能打开相机扫码。
  ///
  /// 为 false 时调用方**不渲染入口**（桌面端注入 [NoopQrScanner]，登录页
  /// 因此不长出一个点不动的按钮）。
  bool get isSupported;

  /// 不可用原因（null = 没问题），供日志与诊断报告展示。
  String? get problem;

  /// 打开相机扫一枚二维码，返回**原始文本**。
  ///
  /// 不做语义解释：扫到的是登录深链、反向登录码还是别的产品的二维码，由
  /// 认证域判断（`spb_api` 的 `QrLoginUri.parseScannedText`）。这样本包不必
  /// 知道任何登录协议细节，测试也能拿假实现驱动登录页。
  ///
  /// 用户取消、权限被拒、打开失败都返回 null。
  Future<String?> scan(BuildContext context);
}

/// 不支持相机的平台（桌面端）注入的空实现。
///
/// 与 `NoopWeChatMiniProgramLauncher` 同构：调用方不需要写
/// `if (Platform.isAndroid)`，行为统一是「不可用 + 有明确原因」。
class NoopQrScanner implements QrScanner {
  const NoopQrScanner([this._reason]);

  final String? _reason;

  @override
  bool get isSupported => false;

  @override
  String? get problem => _reason ?? '当前平台不支持相机扫码';

  @override
  Future<String?> scan(BuildContext context) async {
    // 返回 null 而非抛异常：上层把 null 当「没有结果」（与用户取消同义），
    // 不必为「桌面端误点了不该出现的按钮」写一条异常分支。
    return null;
  }
}
