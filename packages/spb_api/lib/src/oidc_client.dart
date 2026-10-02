import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

import 'auth_interceptor.dart';

/// OIDC 配置。
///
/// ## 生产形态（实测依据见 `docs/oidc-verification.md`）
///
/// 生产链路的 OIDC 由 **api-gateway 托管**：`GET /auth/oidc/authorize` 由网关
/// 生成授权 URL 并**自己持有 `code_verifier`**（存在 `oidc_request_ctx_*`
/// HttpOnly cookie 里），回调固定落在网关的 `redirect_url`。
///
/// 因此本类的两个用途要分清：
///
/// 1. **[authorizeUrl]（生产主路径）**：只拼 URL，**不自造 PKCE 参数**——
///    网关忽略调用方传入的 `redirect_uri`，也不接受外部注入的
///    `code_challenge`。调用方直接打开网关的 `/auth/oidc/authorize` 即可。
/// 2. **[buildAuthorizeUrl] + [exchangeCode]（直连 IdP / 测试）**：当客户端
///    自己直连 IdP 走完整 PKCE 流程时使用。**该路径要求 `redirect_uri` 已被
///    IdP 预注册**（精确匹配），且 token 端点需要 `client_secret`
///    （IdP 侧是 `client_secret_basic`/`post`，非 public client）。
///
/// ⚠️ **不要**把 [redirectUri] 改成自定义 scheme（`partyb://...`）或 loopback
/// （`http://127.0.0.1:<port>/...`）：实测 IdP 对两者都返回
/// `400 invalid_request`（`redirect_uri` 不在预注册列表里）。
class OidcConfig {
  const OidcConfig({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    this.scopes = const ['openid', 'profile', 'email', 'offline_access'],
    this.clientSecret,
  });

  /// 从编译期 `--dart-define` 构造（见 `SpbEnv.oidcIssuer` 等）。
  ///
  /// 便于两端在 `providers.dart` 里一行拿到配置，不必各自重复读环境变量。
  factory OidcConfig.fromEnv({String? clientSecret}) => OidcConfig(
    issuer: SpbEnv.oidcIssuer,
    clientId: SpbEnv.oidcClientId,
    redirectUri: SpbEnv.oidcRedirectUri,
    clientSecret: clientSecret,
  );

  /// IdP 基地址（含 basePath），如 `https://app.example.com/idp`。
  ///
  /// 末尾斜杠会被归一化掉，避免拼出 `.../idp//oauth2/authorize`。
  final String issuer;

  /// OIDC client_id。
  final String clientId;

  /// 已预注册的回调地址（**精确匹配**，见类文档）。
  final String redirectUri;

  final List<String> scopes;

  /// 客户端密钥。仅当走「直连 IdP 自己换 token」时才需要。
  ///
  /// 生产**不应**在客户端内嵌该值（IdP 侧 token 端点要求 `client_secret_basic`
  /// /`post`，而客户端无法安全保存密钥）——生产用网关托管流程即可。
  /// 桌面/移动端保留它只为本地集成测试。
  final String? clientSecret;

  /// 归一化后的 issuer（去掉末尾 `/`）。
  String get normalizedIssuer =>
      issuer.endsWith('/') ? issuer.substring(0, issuer.length - 1) : issuer;

  /// 复制并覆盖 [redirectUri]。
  ///
  /// 移动端需要把编译期默认的（网关）回调换成自定义 scheme 回调，
  /// 但又不想重复枚举 [scopes] 等其他字段——新增字段时容易漏。
  OidcConfig copyWithRedirectUri(String redirectUri) => OidcConfig(
    issuer: issuer,
    clientId: clientId,
    redirectUri: redirectUri,
    scopes: scopes,
    clientSecret: clientSecret,
  );

  /// `{issuer}/oauth2/authorize`。
  String get authorizeEndpoint => '$normalizedIssuer/oauth2/authorize';

  /// `{issuer}/oauth2/token`。
  String get tokenEndpoint => '$normalizedIssuer/oauth2/token';

  /// 网关托管的授权入口（**生产主路径**）。
  ///
  /// 相对 [normalizedIssuer] 的 host；若部署在网关下则为
  /// `https://<gateway>/auth/oidc/authorize`。此处按 [issuer] 的 host 推导，
  /// 可通过 [gatewayBaseUrl] 覆盖。
  Uri authorizeUrl({
    required String state,
    String? postLoginRedirect,
    String? gatewayBaseUrl,
  }) {
    final base = gatewayBaseUrl ?? _deriveGatewayBase();
    return Uri.parse('$base/auth/oidc/authorize').replace(
      queryParameters: {
        'state': state,
        // 仅站内绝对路径（网关侧 isSafeLocalRedirectPath 校验，非站内值会被
        // 静默丢弃）。因此不要传自定义 scheme。
        if (postLoginRedirect != null && postLoginRedirect.isNotEmpty)
          'post_login_redirect': postLoginRedirect,
      },
    );
  }

  /// 从 [issuer] 推导网关根地址（去掉 IdP 的 `/idp` 前缀）。
  ///
  /// `https://app.example.com/idp` → `https://app.example.com`。
  String _deriveGatewayBase() {
    final uri = Uri.parse(normalizedIssuer);
    var path = uri.path;
    if (path.endsWith('/idp')) {
      path = path.substring(0, path.length - 4);
    }
    final origin = uri.replace(path: path, query: null, fragment: null);
    final s = origin.toString();
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  @override
  String toString() =>
      'OidcConfig(issuer: $normalizedIssuer, clientId: $clientId, '
      'redirectUri: $redirectUri)';
}

/// PKCE 参数对（RFC 7636）。
///
/// - `code_verifier`：43–128 个 `[A-Za-z0-9-._~]` 字符的随机串；
/// - `code_challenge`：`BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`，
///   无 padding（`code_challenge_method=S256`）。
class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});

  /// 明文 verifier。**换 token 时提交，不要放进授权 URL，也不要写日志。**
  final String verifier;

  /// S256 challenge（放进授权 URL）。
  final String challenge;

  /// 与 [challenge] 配套的算法名。RFC 7636 只定义了 `plain` 与 `S256`。
  static const String method = 'S256';

  /// 防止 verifier 被日志/toString 意外打印出来。
  @override
  String toString() => 'PkcePair(challenge: $challenge, verifier: <已隐藏>)';
}

/// RFC 7636 §4.1 允许的字符集：`ALPHA / DIGIT / "-" / "." / "_" / "~"`。
final RegExp _verifierAllowed = RegExp(r'^[A-Za-z0-9\-._~]+$');

/// verifier 长度下限（RFC 7636 §4.1）。
const int pkceVerifierMinLength = 43;

/// verifier 长度上限（RFC 7636 §4.1）。
const int pkceVerifierMaxLength = 128;

/// PKCE 与授权 URL 构造（纯函数，便于单测）。
class OidcPkce {
  const OidcPkce._();

  /// 生成 [length] 个字符的 `code_verifier`（默认 64，落在 RFC 允许区间中段）。
  ///
  /// 字符集用 RFC 7636 的 unreserved 集合，且**只取 base64url 安全的那部分**
  /// （`A-Za-z0-9-_`），这样同一串既能当 verifier 也能直接参与 base64 编码，
  /// 不需要额外转义。
  ///
  /// [random] 可注入以便测试（测试应传入确定性随机源）。
  static String generateVerifier({int length = 64, Random? random}) {
    if (length < pkceVerifierMinLength || length > pkceVerifierMaxLength) {
      throw ArgumentError.value(
        length,
        'length',
        'RFC 7636 要求 code_verifier 长度在 '
            '$pkceVerifierMinLength–$pkceVerifierMaxLength 之间',
      );
    }
    // 用 dart:math Random.secure() 而非 Random()：verifier 是安全敏感值，
    // 可预测的伪随机会让 PKCE 的防护失效。
    final rng = random ?? Random.secure();
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final buf = StringBuffer();
    for (var i = 0; i < length; i++) {
      buf.write(alphabet[rng.nextInt(alphabet.length)]);
    }
    return buf.toString();
  }

  /// 计算 `code_challenge = BASE64URL(SHA256(verifier))`（无 padding）。
  static String challengeFor(String verifier) {
    final digest = crypto.sha256.convert(ascii.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// 生成一对 PKCE 参数。
  static PkcePair generatePair({int length = 64, Random? random}) {
    final verifier = generateVerifier(length: length, random: random);
    return PkcePair(verifier: verifier, challenge: challengeFor(verifier));
  }

  /// 校验一个 verifier 是否满足 RFC 7636 §4.1 的格式要求。
  ///
  /// 用于断言「生成的 verifier 合规」以及拒绝外部传入的非法值。
  static bool isValidVerifier(String verifier) =>
      verifier.length >= pkceVerifierMinLength &&
      verifier.length <= pkceVerifierMaxLength &&
      _verifierAllowed.hasMatch(verifier);

  /// 构造**直连 IdP** 的授权 URL（含 PKCE 参数）。
  ///
  /// ⚠️ [OidcConfig.redirectUri] 必须是 IdP 已注册的值，否则 IdP 直接 400
  /// （实测见 `docs/oidc-verification.md`）。
  ///
  /// 生产主路径请用 [OidcConfig.authorizeUrl]（走网关，网关自己管 PKCE）。
  static Uri buildAuthorizeUrl({
    required OidcConfig config,
    required PkcePair pkce,
    required String state,
    required String nonce,
    Map<String, String> extraParams = const {},
  }) {
    if (config.clientId.isEmpty) {
      throw const AuthError(
        'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
      );
    }
    if (config.redirectUri.isEmpty) {
      throw const AuthError('OIDC redirect_uri 未配置');
    }
    return Uri.parse(config.authorizeEndpoint).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': config.clientId,
        'redirect_uri': config.redirectUri,
        'scope': config.scopes.join(' '),
        'state': state,
        'nonce': nonce,
        'code_challenge': pkce.challenge,
        'code_challenge_method': PkcePair.method,
        ...extraParams,
      },
    );
  }

  /// 从授权回调 URL 中取出 `code` 与 `state`，并校验 state 防 CSRF。
  ///
  /// [expectedState] 为授权请求时生成的 state；不匹配即抛 [AuthError]
  /// （不匹配说明回调不是本次请求触发的，可能是 CSRF 或串了会话）。
  ///
  /// 若回调带 `error`（如 `access_denied`），抛出 [AuthError] 并带上
  /// `error_description`，避免把「用户点了取消」显示成「网络错误」。
  static ({String code, String? state}) parseCallback(
    Uri callback, {
    required String expectedState,
  }) {
    final params = callback.queryParameters;
    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      final desc = params['error_description'];
      throw AuthError(
        'OIDC 授权被拒绝：$error${desc == null || desc.isEmpty ? '' : '（$desc）'}',
      );
    }

    final state = params['state'];
    if (state != expectedState) {
      throw const AuthError('OIDC 回调 state 不匹配（疑似 CSRF 或会话串扰）');
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const AuthError('OIDC 回调缺少授权码');
    }
    return (code: code, state: state);
  }
}

/// OIDC token 集合。
///
/// ## 只保留「换 token」必需字段
///
/// 刻意**不解析 JWT claims**：客户端不是身份真源，`X-User-ID` 由网关注入
/// （见 `auth_interceptor.dart` 的认证模型说明）。解析 ID Token 只会引入
/// 「claim 结构变化即失效」的脆弱性。
class OidcTokens {
  const OidcTokens({
    required this.accessToken,
    this.tokenType = 'Bearer',
    this.idToken,
    this.refreshToken,
    this.expiresIn,
    this.scope,
  });

  /// `access_token`。
  final String accessToken;

  /// `token_type`（通常 `Bearer`）。
  final String tokenType;

  /// `id_token`（保留原始串，不解析）。
  final String? idToken;

  /// `refresh_token`（仅当 scope 含 `offline_access` 时下发）。
  final String? refreshToken;

  /// `expires_in`（秒）。为 null 表示服务端未给出。
  final int? expiresIn;

  /// `scope`。
  final String? scope;

  factory OidcTokens.fromJson(Map<String, dynamic> json) {
    final accessToken = json['access_token']?.toString() ?? '';
    if (accessToken.isEmpty) {
      // 缺 access_token 说明响应不是 token 端点返回（可能是错误体）。
      // 静默构造空对象会让上层拿着空串去请求，最终表现为莫名 401。
      throw const AuthError('OIDC token 响应缺少 access_token');
    }
    final expires = json['expires_in'];
    return OidcTokens(
      accessToken: accessToken,
      tokenType: json['token_type']?.toString() ?? 'Bearer',
      idToken: _nonEmpty(json['id_token']),
      refreshToken: _nonEmpty(json['refresh_token']),
      expiresIn: expires is num ? expires.toInt() : int.tryParse('$expires'),
      scope: _nonEmpty(json['scope']),
    );
  }

  static String? _nonEmpty(Object? v) {
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// 是否可用 [refreshToken] 续期。
  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  /// 诊断用的安全描述（**不含 token 值**）。
  @override
  String toString() =>
      'OidcTokens(tokenType: $tokenType, hasIdToken: ${idToken != null}, '
      'canRefresh: $canRefresh, expiresIn: $expiresIn)';
}

/// OIDC 客户端。
///
/// ## 职责边界
///
/// 本类只做「构造 URL / 发 token 请求 / 解析响应」，**不碰存储与导航**
/// （token 持久化与登录页由上层负责）。这样它能作为纯
/// Dart 包被无头单测覆盖。
class OidcClient {
  OidcClient({required this.config, Dio? dio})
    : _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.json));

  final OidcConfig config;
  final Dio _dio;

  /// 网关托管的授权入口 URL（生产主路径）。
  ///
  /// 打开它即可开始登录；网关自己生成并持有 PKCE 参数，客户端不参与。
  Uri authorizeUrl({required String state, String? postLoginRedirect}) =>
      config.authorizeUrl(state: state, postLoginRedirect: postLoginRedirect);

  /// 生成一对 PKCE 参数（仅「直连 IdP」路径需要）。
  PkcePair generatePkce({int length = 64, Random? random}) =>
      OidcPkce.generatePair(length: length, random: random);

  /// 构造直连 IdP 的授权 URL（见 [OidcPkce.buildAuthorizeUrl] 的注意事项）。
  Uri buildAuthorizeUrl({
    required PkcePair pkce,
    required String state,
    required String nonce,
    Map<String, String> extraParams = const {},
  }) => OidcPkce.buildAuthorizeUrl(
    config: config,
    pkce: pkce,
    state: state,
    nonce: nonce,
    extraParams: extraParams,
  );

  /// 用授权码换 token：`POST {issuer}/oauth2/token`（`grant_type=authorization_code`）。
  ///
  /// 同时提交 [PkcePair.verifier] 与 [redirectUri]（必须与授权请求时一致，
  /// 否则 IdP 报 `invalid_grant`）。
  Future<OidcTokens> exchangeCode({
    required String code,
    required PkcePair pkce,
  }) => _tokenRequest({
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': config.redirectUri,
    'client_id': config.clientId,
    'code_verifier': pkce.verifier,
  });

  /// 刷新 token：`grant_type=refresh_token`。
  ///
  /// ⚠️ 生产链路**不应**由客户端主动刷新：会话由网关维护，客户端自行刷新会与
  /// 网关状态分叉（原 Tauri 端同样刻意不做，见
  /// `super_partyb/apps/desktop/src-tauri/src/sync/auth.rs`）。此方法保留给
  /// 直连 IdP 的场景与测试。
  Future<OidcTokens> refresh({required String refreshToken}) => _tokenRequest({
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'client_id': config.clientId,
  });

  Future<OidcTokens> _tokenRequest(Map<String, String> form) async {
    if (config.clientId.isEmpty) {
      throw const AuthError(
        'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）',
      );
    }

    final headers = <String, Object?>{};
    final secret = config.clientSecret;
    if (secret != null && secret.isNotEmpty) {
      // client_secret_basic：IdP 的 discovery 明确列出该方式。
      // 用 base64(client_id:client_secret) 放在 Authorization 头，
      // 避免密钥出现在请求体/日志里。
      final basic = base64.encode(utf8.encode('${config.clientId}:$secret'));
      headers['Authorization'] = 'Basic $basic';
    }

    Response<dynamic> res;
    try {
      res = await _dio.post<dynamic>(
        config.tokenEndpoint,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: headers,
          // 与 createDio 不同：这里需要看到 4xx 的错误体（invalid_grant 等），
          // 由本方法自行映射为 AuthError，而不是让 dio 抛。
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } on DioException catch (e) {
      // 网络层失败（连接超时/DNS/TLS）与 5xx 都会走到这里：
      // `validateStatus` 放行 <500，故 5xx 由 dio 抛异常。
      // 统一交给 mapDioError：连接类 → NetworkError（可重试），
      // 5xx → HttpError（isServerError，同样可重试）。
      //
      // 刻意**不**把它归成 AuthError：「换 token 时服务端 503」不该被显示成
      // 「登录失败，请重新登录」，否则用户会反复重输密码而问题其实在服务端。
      throw mapDioError(e);
    }

    final status = res.statusCode ?? 0;
    final body = res.data;
    if (status < 200 || status >= 300) {
      final message = _errorMessage(body) ?? 'OIDC token 端点返回 HTTP $status';
      throw AuthError(message, cause: HttpError(status, 'HTTP $status'));
    }

    if (body is! Map) {
      throw ParseError('OIDC token 响应不是 JSON 对象', raw: body?.toString());
    }
    return OidcTokens.fromJson(Map<String, dynamic>.from(body));
  }

  /// 从 OAuth 错误体里取可读消息（`{"error":"...","error_description":"..."}`）。
  static String? _errorMessage(Object? body) {
    if (body is! Map) return null;
    final error = body['error']?.toString();
    final desc = body['error_description']?.toString();
    if (error == null && desc == null) return null;
    if (error == null) return desc;
    if (desc == null || desc.isEmpty) return 'OIDC 错误：$error';
    return 'OIDC 错误：$error（$desc）';
  }
}
