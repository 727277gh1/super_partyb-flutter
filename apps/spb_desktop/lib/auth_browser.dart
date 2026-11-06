import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';
import 'package:spb_platform/spb_platform.dart';

/// 在系统浏览器中打开网关的 OIDC 授权入口。
///
/// ## 为什么不自己拼授权 URL、不走 PKCE 换 token
///
/// 实测结论见 `docs/oidc-verification.md`：
///
/// - **网关忽略调用方传入的 `redirect_uri`**，硬编码为配置里的 `redirect_url`
///   （`handlers_oidc_authorize.go` 的 `GetAuthURL` 只读 `state` 与
///   `post_login_redirect`）；
/// - **IdP 对 `redirect_uri` 做精确匹配**，只认预注册的三个网关回调——
///   自定义 scheme（`partyb://...`）与 loopback（`http://127.0.0.1:<port>/...`）
///   都返回 `400 invalid_request`。
///
/// 因此客户端**不可能**自己完成授权码交换：code 永远只会被投递到网关的回调，
/// 由网关换成 token 并下发 HttpOnly Cookie。本函数只负责把用户送去登录。
///
/// ## 为什么不带 `redirect_uri` 参数
///
/// 带了也会被网关忽略，留着只会让后人误以为它生效。只传 `state`（CSRF）与
/// `post_login_redirect`（站内回跳路径，网关侧有白名单校验）。
///
/// ## 已知缺口（不在本任务范围）
///
/// 用户在系统浏览器里登录后，会话 Cookie 落在**浏览器**里，而 Flutter 进程
/// 无法读取浏览器 Cookie。Linux 桌面端「如何把浏览器里的会话交给客户端」是
/// `docs/oidc-verification.md` §2.3 与 §4 记录的待办（移动/Windows/macOS 可用
/// 内嵌 webview 解决，Linux 无主流 webview 插件）。
///
/// 本任务只负责把登录**发起**出去并把失败原因如实回报给登录页。
///
/// ## 返回值的语义
///
/// 返回 null 表示已成功发起（等待用户在浏览器中完成登录）；返回字符串是
/// **用户可见的**失败原因。
Future<String?> openGatewaySignIn() async {
  final config = OidcConfig.fromEnv();
  if (config.clientId.isEmpty) {
    return 'OIDC client_id 未配置（构建时需传 --dart-define=SPB_OIDC_CLIENT_ID）';
  }

  final url = config.authorizeUrl(
    state: generateOidcState(),
    // 登录后回跳站内路径。传空串让网关用默认（`/`）。
    postLoginRedirect: '',
  );

  try {
    await openInBrowser(url.toString());
    SpbLog.info('已在系统浏览器中打开 OIDC 授权入口', {'host': url.host});
    return null;
  } catch (e) {
    SpbLog.warn('打开浏览器失败', {'error': e.toString()});
    return '无法打开浏览器，请手动访问：$url';
  }
}

/// 生成 CSRF `state`（32 字符，与网关侧生成的长度一致）。
///
/// 用 `Random.secure()`：state 是防 CSRF 的一次性随机值，可预测的伪随机
/// 会让这层防护失效。
String generateOidcState({Random? random}) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = random ?? Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}

/// 用系统默认浏览器打开 URL。
///
/// 三平台分派统一委托给 `spb_platform` 的 [spawnSystemOpen]（`xdg-open` /
/// `open` / `explorer`）——与交付物同步的 `revealPath` / `openFile` 走**同一
/// 份**实现，避免两处平台分支各自漂移（历史上本函数只实现了 Linux，导致
/// Windows/macOS 上 OIDC 登录与 Markdown 链接点击都不可用）。
///
/// 不引入 `url_launcher`：桌面端只需系统命令，少一个插件依赖。
///
/// ## 为什么失败要抛异常（而 `spb_platform` 返回 bool）
///
/// [spawnSystemOpen] 的契约是「静默降级返回 false」，适合「打开一个本地文件」
/// 这类失败只需提示一次的场景。而本函数的调用方需要**用户可见的原因**：
/// [openGatewaySignIn] 把它翻成「无法打开浏览器，请手动访问：`<url>`」，
/// `router.dart` 的 `onOpenLink` 记一条日志。故在此把 `false` 翻成
/// [PlatformError]，保留「谁负责展示」的决定权在调用方。
Future<void> openInBrowser(String url) async {
  final ok = await spawnSystemOpenHere(url);
  if (!ok) {
    throw const PlatformError('无法在当前平台打开链接（已尝试系统默认程序）');
  }
}
