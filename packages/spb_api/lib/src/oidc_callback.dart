import 'package:spb_core/spb_core.dart';

import 'oidc_client.dart';

/// 移动端自定义 scheme 回调地址（`partyb://oidc/callback`）。
///
/// ## 为什么单独抽一个类
///
/// 「回调地址」这一串字面量同时出现在**四个**地方，任何一处改错都会表现为
/// 「登录后应用毫无反应」（而不是报错），极难排查：
///
/// 1. `apps/spb_mobile/android/app/src/main/AndroidManifest.xml` 的
///    `<data android:scheme android:host android:pathPrefix>`；
/// 2. `apps/spb_mobile/ios/Runner/Info.plist` 的 `CFBundleURLTypes`；
/// 3. IdP 侧 `oauth_clients.redirectUris`（**尚未注册**，见下）；
/// 4. 应用内解析回调的代码（本类）。
///
/// 前三处是平台配置文件（无法 import Dart 常量），因此本类把常量集中定义
/// 并加断言测试，至少保证第 4 处与文档一致。
///
/// ## ⚠️ 当前状态：已注册但**收不到回调**
///
/// 实测（见 `docs/oidc-verification.md` 与 `docs/mobile-oidc-deeplink.md`）：
/// IdP 对 `redirect_uri` 做**精确匹配**，只认三个预注册的网关回调；
/// `partyb://oidc/callback` 与 loopback 都被 `400 invalid_request` 拒绝。
///
/// 因此本类描述的是**目标形态**：一旦 IdP 侧为该 client 注册了本回调地址
/// （跨仓库的生产配置变更），下面的解析逻辑即可直接工作，应用侧无需再改。
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

  /// 完整回调地址（用于文档、断言与 IdP 注册）。
  static String get redirectUri => '$scheme://$host$path';

  /// [uri] 是否是本应用的 OIDC 回调。
  ///
  /// 判定**必须**同时比较 scheme + host + path：只看 scheme 会让
  /// `partyb://share/evil?code=...` 这种伪造地址也走进 token 交换逻辑。
  static bool matches(Uri uri) {
    if (uri.scheme != scheme) return false;
    if (uri.host != host) return false;
    final p = uri.path;
    // 容错一个结尾斜杠：部分平台/工具链会在转发时补上 `/`。
    return p == path || p == '$path/';
  }

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
  }) {
    if (!matches(uri)) {
      throw AuthError(
        '不是本应用的 OIDC 回调地址：${uri.scheme}://${uri.host}${uri.path}',
      );
    }
    return OidcPkce.parseCallback(uri, expectedState: expectedState);
  }

  /// 诊断用的安全描述（**不含任何参数值**）。
  @override
  String toString() => 'OidcCallbackUri($redirectUri)';
}
