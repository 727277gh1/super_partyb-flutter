import 'dart:io' show Platform;

/// 运行期环境配置。
///
/// WHY 用 `--dart-define` 而非配置文件：桌面端与移动端的发布包需要内嵌不同的
/// 网关地址（生产 / 测试 / 本地），而配置若走文件就得处理「文件在哪、谁来写」。
/// `--dart-define` 在编译期注入，无运行时文件依赖，也不会被误提交进仓库。
///
/// 用法：
/// ```bash
/// flutter build linux --release \
///   --dart-define=SPB_API_BASE_URL=https://api.example.com/pba \
///   --dart-define=SPB_UFS_BASE_URL=https://api.example.com/ufs
/// ```
class SpbEnv {
  const SpbEnv._();

  /// PartyB Go API 基地址（含网关前缀 `/pba`）。
  ///
  /// 本地开发默认直连 Go API（绕过网关，用 `AUTH_MODE=header` + 手工 X-User-ID）；
  /// 发布包必须通过 `--dart-define` 覆盖为网关地址。
  static const String apiBaseUrl = String.fromEnvironment(
    'SPB_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );

  /// 网关上的 webapp 基地址，用于「用浏览器打开」类跳转。
  static const String webappBaseUrl = String.fromEnvironment(
    'SPB_WEBAPP_BASE_URL',
    defaultValue: 'http://127.0.0.1:3030/pbw',
  );

  /// UFS 文件服务基地址（交付物同步用）。
  ///
  /// 与 [apiBaseUrl] 分开：UFS 有独立的服务端，网关前缀也不同（`/ufs`）。
  static const String ufsBaseUrl = String.fromEnvironment(
    'SPB_UFS_BASE_URL',
    defaultValue: 'http://127.0.0.1:9000/ufs',
  );

  /// 环境名（`dev` / `staging` / `prod`），仅用于日志与诊断上报。
  static const String environment = String.fromEnvironment(
    'SPB_ENV',
    defaultValue: 'dev',
  );

  /// 是否启用详细日志（含 HTTP 请求体、SSE 原始帧）。
  static const bool verboseLogging = bool.fromEnvironment(
    'SPB_VERBOSE_LOG',
    defaultValue: false,
  );

  /// 当前是否为发布构建。发布构建禁用调试入口（如 debug 面板）。
  static const bool isRelease = bool.fromEnvironment('dart.vm.product');

  /// 运行平台判定。用 `dart:io Platform` 而非 `defaultTargetPlatform`：
  /// 后者需要 Flutter 绑定，而本包是纯 Dart，要能在无引擎环境跑测试。
  static bool get isLinux => Platform.isLinux;
  static bool get isWindows => Platform.isWindows;
  static bool get isMacOS => Platform.isMacOS;
  static bool get isAndroid => Platform.isAndroid;
  static bool get isIOS => Platform.isIOS;

  /// 是否具备桌面端专有能力（多窗口 / 托盘 / 全局快捷键）。
  ///
  /// 移动端应据此隐藏对应设置项，而不是等到调用时抛 [PlatformError]。
  static bool get isDesktop => isLinux || isWindows || isMacOS;

  /// 是否具备移动端专有能力（分享面板 / 系统相机）。
  static bool get isMobile => isAndroid || isIOS;
}
