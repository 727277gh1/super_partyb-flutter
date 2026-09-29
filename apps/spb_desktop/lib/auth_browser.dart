import 'dart:io';
import 'dart:math';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

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
/// 不引入 `url_launcher`：当前只需 Linux 桌面（开发平台），`xdg-open` 是
/// Linux 桌面标准入口。将来支持 Windows/macOS 时在此按平台分支即可，
/// **调用方不需要改**。
Future<void> openInBrowser(String url) async {
  if (Platform.isLinux) {
    final result = await Process.run('xdg-open', [url]);
    if (result.exitCode != 0) {
      throw PlatformError('xdg-open 退出码 ${result.exitCode}');
    }
    return;
  }
  // 其余平台尚未验证：明确报错而不是静默什么都不做（静默会让用户
  // 以为「点了没反应」）。
  throw const PlatformError('当前平台暂不支持打开浏览器（仅实现了 Linux）');
}
