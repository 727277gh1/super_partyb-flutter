import 'dart:async';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:spb_api/spb_api.dart';
import 'package:spb_core/spb_core.dart';

/// 深链来源抽象。
///
/// ## 为什么要抽一层
///
/// `app_links` 走平台通道（`MissingPluginException` in unit test），而回调
/// **解析与校验**才是真正容易出错、必须单测覆盖的部分。把「来源」抽象掉之后：
///
/// - 生产注入 [AppLinksDeepLinkSource]（真插件）；
/// - 测试注入假实现，直接喂 URI 序列，无需平台通道。
///
/// 这也是分层规则的要求：`spb_api` 是纯 Dart，插件只能在 app 层。
abstract interface class DeepLinkSource {
  /// 应用**冷启动**时把本应用拉起的那个链接（可能没有）。
  ///
  /// 必须单独取：Android/iOS 在进程未运行时不会往 `uriStream` 推事件，
  /// 只把链接放进启动参数。漏掉这一步会让「先关掉应用再点登录链接」
  /// 这条路径完全失效。
  Future<Uri?> initialUri();

  /// 应用**运行中**收到的链接。
  Stream<Uri> uriStream();
}

/// 基于 `app_links` 的真实实现。
class AppLinksDeepLinkSource implements DeepLinkSource {
  AppLinksDeepLinkSource([AppLinks? links]) : _links = links ?? AppLinks();

  final AppLinks _links;

  @override
  Future<Uri?> initialUri() async {
    try {
      return await _links.getInitialLink();
    } catch (e) {
      // 取初始链接失败不该阻断启动：最坏情况是这次登录收不到回调，
      // 用户可以重试。抛出去会让应用启动即崩。
      SpbLog.warn('读取初始深链失败', {'error': e.toString()});
      return null;
    }
  }

  @override
  Stream<Uri> uriStream() => _links.uriLinkStream;
}

/// OIDC 回调接收器。
///
/// ## 职责
///
/// 1. 从 [DeepLinkSource] 取链接（冷启动 + 运行中两条路径）；
/// 2. 用 [OidcCallbackUri.matches] 过滤出**本应用的** OIDC 回调；
/// 3. 校验 `state`（防 CSRF）并取出 `code`；
/// 4. 把 code 交给 [onCode] 去换 token。
///
/// ## 不做什么
///
/// - 不自己发 HTTP（交换由 [onCode] 内部调 `OidcClient.exchangeCode`）；
/// - 不导航（由上层监听认证状态）；
/// - **不把非 OIDC 链接当成回调**：只看 scheme 会让 `partyb://share/...`
///   这类同 scheme 的链接也走进 token 交换逻辑。
///
/// ## 为什么错误要分「可上报」与「静默忽略」
///
/// - 非本应用回调 → 静默忽略（用户点了别的链接，不该弹错误）；
/// - 本应用回调但 `state` 不匹配 / 缺 code → 通过 [onError] 上报
///   （这可能是 CSRF 攻击，也可能是登录流程真出了问题，用户需要知道）。
class AuthDeepLinkReceiver {
  AuthDeepLinkReceiver({
    required this.source,
    required this.onCode,
    required this.pendingState,
    this.onError,
  });

  final DeepLinkSource source;

  /// 收到合法授权码后的处理（换取并持久化 token）。
  ///
  /// 返回错误文案表示失败（null = 成功）。用返回值而不是抛异常：
  /// 换 token 失败的原因通常需要原样展示给用户（如 `invalid_grant`）。
  final Future<String?> Function(String code, PkcePair pkce) onCode;

  /// 取出当前待验证的登录请求（`state` + `code_verifier`）。
  ///
  /// 返回 null 表示「当前没有进行中的登录」——此时收到的回调应被拒绝：
  /// 没有待验证的 state 就无法排除 CSRF，宁可失败也不要用未知来源的 code
  /// 去请求 token 端点。
  ///
  /// 每次成功取用后应清除（一次性），见 [PendingAuthRequestStore.consume]。
  final PendingAuthRequest? Function() pendingState;

  /// 错误上报（用户可见文案）。
  final void Function(String message)? onError;

  StreamSubscription<Uri>? _sub;

  /// 开始监听。**幂等**：重复调用不会重复订阅。
  Future<void> start() async {
    if (_sub != null) return;

    // 冷启动链接必须先处理：进程未运行时不会有 stream 事件。
    final initial = await source.initialUri();
    if (initial != null) await _handle(initial);

    _sub = source.uriStream().listen(
      _handle,
      onError: (Object e) {
        // 深链流本身出错（插件层）不该让应用崩，只记日志。
        SpbLog.warn('深链流异常', {'error': e.toString()});
      },
    );
  }

  /// 停止监听（测试与登出时调用）。
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _handle(Uri uri) async {
    if (!OidcCallbackUri.matches(uri)) {
      // 不是本应用的 OIDC 回调：静默忽略。
      SpbLog.debug('忽略非 OIDC 深链', {'scheme': uri.scheme, 'host': uri.host});
      return;
    }

    final pending = pendingState();
    if (pending == null) {
      // 没有进行中的登录却收到回调：无法校验 state，拒绝。
      _fail('收到登录回调，但当前没有进行中的登录（请重新发起登录）');
      return;
    }

    final ({String code, String? state}) parsed;
    try {
      parsed = OidcCallbackUri.parse(uri, expectedState: pending.state);
    } on AuthError catch (e) {
      _fail(e.message);
      return;
    }

    String? error;
    try {
      error = await onCode(parsed.code, pending.pkce);
    } catch (e) {
      error = '登录回调处理失败：$e';
    }
    if (error != null) _fail(error);
  }

  void _fail(String message) {
    SpbLog.warn('OIDC 回调处理失败', {'reason': message});
    onError?.call(message);
  }
}

/// 一次进行中的登录请求（`state` + PKCE 参数）。
///
/// 二者必须**一起**保存：`state` 用于回调时校验来源，`code_verifier` 用于换
/// token。分开保存会出现「校验通过但换 token 时找不到 verifier」。
class PendingAuthRequest {
  const PendingAuthRequest({required this.state, required this.pkce});

  final String state;
  final PkcePair pkce;

  /// 诊断用（**不含 verifier 值**）。
  @override
  String toString() => 'PendingAuthRequest(state: $state, pkce: $pkce)';
}

/// 待验证登录请求的存放处。
///
/// ## 为什么需要它
///
/// 授权流程会把用户带到**外部浏览器**，应用可能在此期间被系统回收
/// （Android 低内存时很常见）。回调到达时应用可能已经重启，
/// 若 `state`/`verifier` 只存在内存里就会丢失，表现为「登录后应用毫无反应」。
///
/// ## 当前实现：内存
///
/// 内存实现（[InMemoryPendingAuthStore]）足以覆盖「应用存活」这条主路径。
/// 跨进程死亡的重启场景需要把这两个值也持久化（加密存储），
/// 属后续工作——**在文档里明确记录，而不是假装已经支持**。
abstract interface class PendingAuthRequestStore {
  /// 记录一次新发起的登录（覆盖旧的）。
  void put(PendingAuthRequest request);

  /// 取出并**清除**（一次性）。
  ///
  /// 必须一次性：同一个 `state` 若能被重复消费，重放同一个回调链接就能
  /// 反复换 token。
  PendingAuthRequest? consume();
}

/// 内存实现（当前生产使用，见接口文档的说明）。
class InMemoryPendingAuthStore implements PendingAuthRequestStore {
  PendingAuthRequest? _pending;

  @override
  void put(PendingAuthRequest request) => _pending = request;

  @override
  PendingAuthRequest? consume() {
    final p = _pending;
    _pending = null;
    return p;
  }
}

/// 发起移动端登录（打开系统浏览器走 IdP 授权码流程）。
///
/// ## 流程
///
/// 1. 生成 `state`（防 CSRF）与 PKCE 参数对；
/// 2. 两者**一起**存入 [PendingAuthRequestStore]（回调时要用 verifier 换 token）；
/// 3. 拼出直连 IdP 的授权 URL（`redirect_uri = partyb://oidc/callback`）；
/// 4. 用系统浏览器打开；授权完成后 IdP 会把浏览器重定向回本应用，
///    由 [AuthDeepLinkReceiver] 接手。
///
/// ## 为什么不走网关的 `/auth/oidc/authorize`
///
/// 网关把 `redirect_uri` **硬编码**为自己的 `redirect_url`（实测见
/// `docs/oidc-verification.md` §1.2），回调会落在网关而不是本应用，
/// 客户端永远拿不到 code。要拿 code 只能直连 IdP。
///
/// ## ⚠️ 当前无法闭环（两个服务端前提，均在本仓库之外）
///
/// 1. IdP 对 `redirect_uri` 做**精确匹配**，`partyb://oidc/callback` 尚未在
///    `oauth_clients.redirectUris` 里注册 → 授权端点直接 `400 invalid_request`；
/// 2. 该 client 不是 public client（`token_endpoint_auth_methods_supported`
///    只有 `client_secret_basic`/`post`）→ 即使拿到 code，客户端没有
///    `client_secret` 也换不到 token。
///
/// 二者都需要在 IdP 侧新增一个**移动端 public client**（注册自定义 scheme
/// 回调 + 强制 PKCE）。详见 `docs/mobile-oidc-deeplink.md`。
/// 本函数与接收端已按**目标形态**实现，服务端就绪后即可直接工作。
///
/// 返回错误文案（null = 已成功打开浏览器）。
Future<String?> mobileSignIn({
  required OidcConfig config,
  required PendingAuthRequestStore store,
  required Future<bool> Function(Uri url) launch,
  String Function()? stateGenerator,
  PkcePair Function()? pkceGenerator,
}) async {
  if (config.clientId.isEmpty) {
    return 'OIDC client_id 未配置（--dart-define=SPB_OIDC_CLIENT_ID）';
  }

  final state = (stateGenerator ?? _defaultState)();
  final pkce = (pkceGenerator ?? OidcPkce.generatePair)();
  store.put(PendingAuthRequest(state: state, pkce: pkce));

  final url = OidcPkce.buildAuthorizeUrl(
    config: config,
    pkce: pkce,
    state: state,
    // nonce 用于绑定 ID Token；客户端不解析 JWT，但 IdP 仍要求该参数。
    nonce: (stateGenerator ?? _defaultState)(),
  );

  try {
    final ok = await launch(url);
    if (!ok) {
      store.consume();
      return '无法打开浏览器，请手动访问：$url';
    }
    SpbLog.info('已打开移动端 OIDC 授权入口', {
      'issuer': url.host,
      'redirect': config.redirectUri,
    });
    return null;
  } catch (e) {
    // 打不开浏览器时清掉待验证请求：留着它会让下次回调误以为有进行中的登录。
    store.consume();
    SpbLog.warn('打开浏览器失败', {'error': e.toString()});
    return '无法打开浏览器，请手动访问：$url';
  }
}

/// 默认 `state` 生成（32 字符，与网关侧一致）。
String _defaultState() {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 32; i++) {
    buf.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}
