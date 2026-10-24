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

  /// UFS 文件服务基地址（交付物同步用）。
  ///
  /// 与 [apiBaseUrl] 分开：UFS 有独立的服务端，网关前缀也不同（`/ufs`）。
  static const String ufsBaseUrl = String.fromEnvironment(
    'SPB_UFS_BASE_URL',
    defaultValue: 'http://127.0.0.1:9000/ufs',
  );

  /// IPv6/IPv4 端点别名表（`compiledHost=preferredHost`，`;`/`,` 分隔多个，
  /// 也兼容 JSON 对象）。
  ///
  /// ## 语义：编译期默认用**安全**域名，运行期探测**升级**
  ///
  /// 左值是编译期已注入的 host（[apiBaseUrl] / [ufsBaseUrl] 里那个，通常是
  /// 双栈 CDN 域名，IPv4-only 网络也一定可达）；右值是希望优先使用的 host
  /// （通常是只有 AAAA 的源站域名）。启动时探测右值，**可达才切**，不可达
  /// 就保持左值——所以「配置写错 / 源站挂了」最坏结果是退回 CDN，而不是
  /// 让客户端连不上。
  ///
  /// 这与小程序的 `TARO_APP_HOST_FALLBACKS` 方向相反（那边 primary 是 IPv6
  /// 域名、失败才回退），原因是小程序没有 socket API，只能「先试再切」；
  /// 客户端有 `dart:io`，可以「先探测再决定」。
  ///
  /// 留空 = 不启用（退化为完全使用编译期地址，行为与未引入本机制一致）。
  /// 解析与探测逻辑见 `endpoints.dart` 的 [SpbEndpoints]。
  static const String preferredHostsRaw = String.fromEnvironment(
    'SPB_PREFERRED_HOSTS',
    defaultValue: '',
  );

  /// 环境名（`dev` / `staging` / `prod`），仅用于日志与诊断上报。
  static const String environment = String.fromEnvironment(
    'SPB_ENV',
    defaultValue: 'dev',
  );

  // ==================== OIDC ====================
  //
  // ⚠️ 实测结论见 `docs/oidc-verification.md`：生产链路的 OIDC 由**网关托管**
  // （`GET /auth/oidc/authorize` 生成授权 URL 并持有 code_verifier），
  // 且 IdP 对 `redirect_uri` 做**精确匹配**，只认预注册的三个网关回调。
  // 因此 [oidcRedirectUri] 在生产下必须是网关回调地址，**不能**改成自定义
  // scheme 或 loopback（两者都会被 IdP 以 400 invalid_request 拒绝）。

  /// OIDC issuer（IdP 基地址，含 basePath）。
  ///
  /// 生产：`https://app.example.com/idp`（经网关访问 IdP）。
  static const String oidcIssuer = String.fromEnvironment(
    'SPB_OIDC_ISSUER',
    defaultValue: 'http://127.0.0.1:3000/idp',
  );

  /// OIDC client_id。
  ///
  /// 默认空串表示「未配置」——没有普适的本地默认值，必须由构建方显式注入
  /// （`--dart-define=SPB_OIDC_CLIENT_ID=...`）。client_id 是公开值
  /// （会出现在授权 URL 里），但仍不硬编码，以免与部署侧漂移。
  static const String oidcClientId = String.fromEnvironment(
    'SPB_OIDC_CLIENT_ID',
    defaultValue: '',
  );

  /// OIDC redirect_uri。
  ///
  /// ## 桌面端：由 [OidcConfig.copyWithRedirectUri] 在登录时**覆盖**
  ///
  /// RFC 8252 §7.3 的 loopback 流程用**随机端口**（`port 0` 由内核分配），
  /// 故真正的 redirect_uri 在运行时才知道，不能由编译期常量决定。这里的
  /// 默认值只是「不含端口的注册值」——与 IdP 侧 `oauth_clients.redirectUris`
  /// 里应当注册的值一致。
  ///
  /// 移动端同理：用 `partyb://oidc/callback` 覆盖（见 `oidc_callback.dart`）。
  static const String oidcRedirectUri = String.fromEnvironment(
    'SPB_OIDC_REDIRECT_URI',
    defaultValue: 'http://127.0.0.1/callback',
  );

  /// 是否启用详细日志（含 HTTP 请求体、SSE 原始帧）。
  static const bool verboseLogging = bool.fromEnvironment(
    'SPB_VERBOSE_LOG',
    defaultValue: false,
  );

  /// 是否启用帧耗时观测（`FrameTiming` 汇总进日志）。
  ///
  /// ## 默认关闭：观测本身有成本
  ///
  /// 开启后引擎**每帧**回传耗时数据并在进程内累积，换来的信息只在排障时
  /// 需要。故与 [verboseLogging] 同一取向——编译期开关，默认关，关闭时
  /// 根本不注册回调（零开销，而不是「注册了但不打印」）。
  ///
  /// 用途：用户报「界面卡」时，让「导出诊断日志」里带上慢帧统计（见
  /// `spb_platform` 的 `installFrameTimingReporter`）。
  static const bool frameTiming = bool.fromEnvironment(
    'SPB_FRAME_TIMING',
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

  /// 平台短名（`linux` / `macos` / `windows` / `android` / `ios` / `unknown`）。
  ///
  /// ## 为什么用 `dart:io` 的 `operatingSystem` 而不是拼 [isLinux] 等
  ///
  /// 拼出来的版本漏了「都不匹配」的分支（web、将来的新平台），而那正是
  /// **最需要写进日志**的情形——静默返回空串会让诊断报告里少一行，看起来
  /// 像「没生成出来」。`Platform.operatingSystem` 自带回落值。
  ///
  /// 这也是 `dart:io` 的返回值（`linux`/`macos`/`windows`/`android`/`ios`），
  /// 与 [HostPlatform] 的命名一致，便于与 `spb_platform` 的日志对齐。
  static String get platformName => Platform.operatingSystem;

  /// 是否具备桌面端专有能力（多窗口 / 托盘 / 全局快捷键）。
  ///
  /// 移动端应据此隐藏对应设置项，而不是等到调用时抛 [PlatformError]。
  static bool get isDesktop => isLinux || isWindows || isMacOS;

  /// 是否具备移动端专有能力（分享面板 / 系统相机）。
  static bool get isMobile => isAndroid || isIOS;
}
