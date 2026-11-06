import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// 移动端 OIDC 回调地址。
///
/// 支持**两种形态**，解析侧必须同时认：
///
/// | 形态 | 地址 | 何时使用 |
/// |---|---|---|
/// | 自定义 scheme | `partyb://oidc/callback` | 当前默认；任何 Android/iOS 都能收 |
/// | claimed HTTPS | `https://<IdP host>/idp/app/callback` | 目标形态（RFC 8252 §7.2 首选） |
///
/// ## 为什么自定义 scheme 不够
///
/// 自定义 scheme 没有归属校验：任何装了 `partyb` scheme 的应用都能抢走回调。
/// claimed HTTPS 由操作系统校验域名归属（Android App Links 的
/// `/.well-known/assetlinks.json`、iOS Universal Links 的
/// `apple-app-site-association`），只有域名所有者声明的 App 才能接管。
///
/// ## 为什么解析侧现在就同时支持两种
///
/// 服务端（IdP `redirectUris` 注册 + 网关 `/.well-known` 路由）与客户端发版
/// 不同步：先发客户端、后开服务端开关时，若客户端只认一种形态，用户会看到
/// 「登录后应用毫无反应」而不是报错。两种都认，切换就只是改一行默认值。
///
/// ## 「回调地址」这一串字面量出现在**四个**地方
///
/// 任何一处改错都表现为「登录后应用毫无反应」（而不是报错），极难排查：
///
/// 1. `apps/spb_mobile/android/app/src/main/AndroidManifest.xml` 的
///    `<data>`（自定义 scheme + `autoVerify` 的 https）；
/// 2. `apps/spb_mobile/ios/Runner/Info.plist` 的 `CFBundleURLTypes`
///    与 `Runner.entitlements` 的 Associated Domains；
/// 3. IdP 侧 `oauth_clients.redirectUris`（**已注册** `partyb://oidc/callback`，
///    claimed HTTPS 见 id-provider#8）；
/// 4. 应用内解析回调的代码（本类）。
///
/// 前三处是平台配置文件（无法 import Dart 常量），因此本类把常量集中定义，
/// 并由 `test/android_manifest_applinks_test.dart` 直接读取 manifest 断言两边一致。
///
/// ## claimed HTTPS 的 host 从哪来
///
/// 不硬编码域名：回调地址永远是「IdP issuer + `/app/callback`」，而 issuer
/// 已由 `SPB_OIDC_ISSUER` 注入（[SpbEnv.oidcIssuer]）。硬编码会让 staging/
/// 双栈构建悄悄失配——而且失配的表现正是最难查的那种「毫无反应」。
class OidcCallbackUri {
  const OidcCallbackUri._();

  /// 自定义 scheme。
  ///
  /// 取值 `partyb`（PartyB 的缩写），**不要**用 `http`/`https`：那会与系统
  /// 浏览器的普通链接冲突，需要额外的域名校验（App Links / Universal Links）。
  static const String scheme = 'partyb';

  /// host 段。自定义 scheme 没有真正的域名，这里用 `oidc` 做命名空间，
  /// 便于将来在同一 scheme 下区分其他用途（如 `partyb://share/...`）。
  static const String host = 'oidc';

  /// path 段。
  static const String path = '/callback';

  /// claimed HTTPS 回调在 issuer 之下的路径段（IdP 的落地页，见 id-provider#8）。
  static const String claimedHttpsPath = '/app/callback';

  /// 完整回调地址（用于文档、断言与 IdP 注册）。
  static String get redirectUri => '$scheme://$host$path';

  /// claimed HTTPS 形态的回调地址（`<issuer>/app/callback`）。
  ///
  /// [issuer] 缺省取 [SpbEnv.oidcIssuer]；测试可显式传入，避免依赖编译期常量。
  /// issuer 无法解析时返回 `null`（配置缺失应当表现为「收不到回调」而不是崩溃）。
  static Uri? claimedHttpsRedirectUri({Uri? issuer}) {
    final base = issuer ?? Uri.tryParse(SpbEnv.oidcIssuer);
    if (base == null || base.host.isEmpty) return null;
    // issuer 形如 `https://host/idp`（含 basePath），回调在 `<basePath>/app/callback`。
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$basePath$claimedHttpsPath');
  }

  /// [uri] 是否是本应用的 OIDC 回调（两种形态都认）。
  ///
  /// 判定**必须**比较 scheme + host + path 三要素，只看 scheme 会让
  /// `partyb://share/evil?code=...` 这种伪造地址也走进 token 交换逻辑；
  /// 只看 path 会让任意域名下的 `/idp/app/callback` 都能投喂授权码。
  ///
  /// [issuer] 仅用于测试注入，生产走 [SpbEnv.oidcIssuer]。
  static bool matches(Uri uri, {Uri? issuer}) {
    if (uri.scheme == scheme) {
      if (uri.host != host) return false;
      // 容错一个结尾斜杠：部分平台/工具链会在转发时补上 `/`。
      return _samePath(uri.path, path);
    }

    final claimed = claimedHttpsRedirectUri(issuer: issuer);
    if (claimed == null) return false;
    // 逐个字段比：`Uri ==` 还会比 query/fragment，而回调必然带 query。
    if (uri.scheme != claimed.scheme) return false;
    if (uri.host != claimed.host) return false;
    if (uri.port != claimed.port) return false;
    return _samePath(uri.path, claimed.path);
  }

  /// 路径相等判定，容忍结尾斜杠。
  static bool _samePath(String actual, String expected) =>
      actual == expected || actual == '$expected/';

  /// 从回调 URI 取出 `code` 与 `state`（含 state 防 CSRF 校验）。
  ///
  /// 直接复用 [OidcPkce.parseCallback]：那里的 state 校验、`error` /
  /// `error_description` 处理、缺 `code` 判定都已单测覆盖，重复实现只会引入
  /// 两套不一致的语义。
  ///
  /// 非本应用回调时抛 [AuthError]——宁可显式失败，也不要把一段无关 URL
  /// 当成授权码去请求 token 端点（会把用户的 code 发到错误的地方）。
  static ({String code, String? state}) parse(
    Uri uri, {
    required String expectedState,
    Uri? issuer,
  }) {
    if (!matches(uri, issuer: issuer)) {
      throw AuthError(
        '不是本应用的 OIDC 回调地址：${uri.scheme}://${uri.host}${uri.path}'
        '（期望 $redirectUri 或 ${claimedHttpsRedirectUri()?.toString() ?? "<issuer>/app/callback"}）',
      );
    }
    return OidcPkce.parseCallback(uri, expectedState: expectedState);
  }

  /// 诊断用的安全描述（**不含任何参数值**）。
  @override
  String toString() => 'OidcCallbackUri($redirectUri)';
}
