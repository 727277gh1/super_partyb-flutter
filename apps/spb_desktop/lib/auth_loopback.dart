import 'dart:async';

import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

import 'auth_browser.dart';

/// loopback 登录结果。
///
/// ## 为什么不用「返回 String? 错误」的既有约定
///
/// `openGatewaySignIn` 只负责**发起**（浏览器登录的结果本进程看不到），故
/// 「null = 已发起」。loopback 流程是**同步拿到 token** 的，若沿用
/// 「null = 成功」会让调用方分不清「已发起待回调」与「已拿到凭证」——前者
/// 需要等，后者需要立刻落盘。用一个显式结果类型把两种结局分开。
class LoopbackSignInResult {
  const LoopbackSignInResult.success(OidcTokens this.tokens) : error = null;
  const LoopbackSignInResult.failure(String this.error) : tokens = null;

  /// 成功时非空。
  final OidcTokens? tokens;

  /// 失败时非空（**用户可见**的原因）。
  final String? error;

  bool get ok => tokens != null;
}

/// 桌面端 OIDC 登录编排：RFC 8252 §7.3 loopback 授权码流程。
///
/// ## 流程（对照 RFC 8252 §4「Authorization Flow for Native Apps」）
///
/// ```text
/// 1. bind 127.0.0.1:<随机端口>（LoopbackRedirectServer）
/// 2. 生成 state（CSRF）+ PKCE 对（RFC 7636 S256）
/// 3. 拼直连 IdP 的授权 URL（redirect_uri = http://127.0.0.1:<port>/callback）
/// 4. 交给系统默认程序打开授权 URL（`openInBrowser` → `spb_platform` 的
///    `spawnSystemOpen`：Linux `xdg-open` / macOS `open` / Windows `explorer`）
/// 5. 用户登录 → IdP 302 回 loopback 端口 → 浏览器 GET 本地监听器
/// 6. 监听器取出 code（+ state 校验）→ 关停监听
/// 7. POST {issuer}/oauth2/token 换 token（public client：无 secret，带 verifier）
/// 8. 返回 [OidcTokens] 交调用方落盘
/// ```
///
/// ## 为什么直连 IdP 而不是走网关 `/auth/oidc/authorize`
///
/// 网关把 `redirect_uri` **硬编码**为自己的 `redirect_url`
/// （`handlers_oidc_authorize.go` 的 `GetAuthURL` 不读 query），回调永远落在
/// 网关，客户端拿不到 code。RFC 8252 流程必须由客户端自己接收回调，故直连
/// IdP 的 `/oauth2/authorize`（带 PKCE 参数）。这要求 IdP 侧存在一个
/// **public client**（注册 `http://127.0.0.1/callback`、auth method=none、
/// 强制 PKCE），见 `docs/rfc8252-loopback-signin.md`。
///
/// ## 与网关 Cookie 会话的关系
///
/// 换到的 token 是 IdP 签发的 ID Token。网关的 JWT 认证器（优先于 OIDC
/// 认证器）用 IdP 的 JWKS 验 RS256 签名、**不校验 audience**，故
/// `Authorization: Bearer <id_token>` 直接过网关——与浏览器 Cookie 会话并存
/// 且互不干扰（Cookie 在浏览器 jar，token 在本进程安全存储）。
Future<LoopbackSignInResult> loopbackSignIn({
  required OidcConfig config,
  OidcClient? oidcClient,
  String Function()? stateGenerator,
  PkcePair Function()? pkceGenerator,
  Future<void> Function(Uri url)? launchInBrowser,
  Duration callbackTimeout = const Duration(minutes: 5),
}) async {
  if (config.clientId.isEmpty) {
    return const LoopbackSignInResult.failure(
      'OIDC client_id 未配置（构建时需传 --dart-define=SPB_OIDC_CLIENT_ID）',
    );
  }

  // 直连 IdP 换 token 需要 public client：机密客户端要求 client_secret，
  // 而桌面端无法安全保存。配置里带了 secret 说明指向的是机密客户端，
  // 交换必然失败——提前给出可操作的错误而不是等 IdP 打回 invalid_client。
  final secret = config.clientSecret;
  if (secret != null && secret.isNotEmpty) {
    return const LoopbackSignInResult.failure(
      '当前 client 是机密客户端（配置了 client_secret），无法用于桌面端直连登录。'
      '请在 IdP 注册 public client（token_endpoint_auth_method=none + loopback 回调）',
    );
  }

  final gen = stateGenerator ?? generateOidcState;
  final state = gen();
  final nonce = gen();
  final pkce = (pkceGenerator ?? OidcPkce.generatePair)();

  // 1. 先起监听器再开浏览器：浏览器回得来才有意义。
  final LoopbackRedirectServer server;
  try {
    server = await LoopbackRedirectServer.start(timeout: callbackTimeout);
  } catch (e) {
    SpbLog.warn('loopback 监听启动失败', {'error': e.toString()});
    return LoopbackSignInResult.failure('无法启动本地回调监听：$e');
  }

  try {
    // 3. 授权 URL 与后续换 token 必须用**同一个** redirect_uri（含本次随机
    //    端口）：IdP 会比对授权请求与 token 请求的 redirect_uri，不一致即
    //    invalid_grant。故构造一份带动态端口的配置给两者共用。
    final effective = config.copyWithRedirectUri(server.redirectUri());
    final client = oidcClient ?? OidcClient(config: effective);

    final authorizeUrl = OidcPkce.buildAuthorizeUrl(
      config: effective,
      pkce: pkce,
      state: state,
      nonce: nonce,
    );

    // 4. 打开系统浏览器。
    try {
      if (launchInBrowser != null) {
        await launchInBrowser(authorizeUrl);
      } else {
        await openInBrowser(authorizeUrl.toString());
      }
    } catch (e) {
      SpbLog.warn('打开浏览器失败', {'error': e.toString()});
      return LoopbackSignInResult.failure('无法打开浏览器，请手动访问：$authorizeUrl');
    }

    // 5-6. 等回调（监听器一次性，超时自动关停）。
    final callback = await server.wait();
    SpbLog.info('收到 loopback 授权回调', {'host': callback.host});

    // state 防 CSRF + 取 code（error=access_denied 等也在这里变成可读文案）。
    final parsed = OidcPkce.parseCallback(callback, expectedState: state);

    // 7. 换 token：public client 只带 client_id + code_verifier。
    final tokens = await client.exchangeCode(code: parsed.code, pkce: pkce);
    SpbLog.info('桌面端 loopback 登录成功', {
      'canRefresh': tokens.canRefresh,
      'expiresIn': tokens.expiresIn,
    });
    return LoopbackSignInResult.success(tokens);
  } on TimeoutException {
    return LoopbackSignInResult.failure(
      '登录超时：${callbackTimeout.inMinutes} 分钟内未完成授权，请重试',
    );
  } on AuthError catch (e) {
    return LoopbackSignInResult.failure(e.message);
  } on SpbError catch (e) {
    return LoopbackSignInResult.failure(e.message);
  } catch (e) {
    SpbLog.warn('loopback 登录失败', {'error': e.toString()});
    return LoopbackSignInResult.failure('登录失败：$e');
  } finally {
    await server.close();
  }
}
