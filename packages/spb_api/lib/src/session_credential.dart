import 'package:spb_api/spb_api.dart';

/// 从用户粘贴的文本中解析出可用的会话凭证。
///
/// ## 为什么需要这个函数（这是桌面端登录闭环的唯一缺口）
///
/// 生产链路由 **api-gateway 托管 OIDC**：`openGatewaySignIn` 把用户送去系统
/// 浏览器完成登录，会话 Cookie 落在**浏览器**里。而 Flutter 进程读不到浏览器
/// 的 Cookie（Linux 无主流 webview 插件，见 `docs/oidc-verification.md` §2.3），
/// 于是 `AuthStateNotifier.restore()` 读 `SecureTokenStore` 永远为空 →
/// 所有 `/pba/*` 请求 401 → 路由守卫把人留在 `/login`。**登录无法闭环。**
///
/// 链路的两端其实都已具备：
///
/// - 网关的 OIDC 认证器从 `Authorization: Bearer` 读 token
///   （`pkg/auth/oidc_auth.go` 的 `extractIDToken`），而 Cookie 路径
///   （`pkg/middleware/auth_cookie.go`）注入的正是 `id_token` cookie；
/// - 客户端 `AuthInterceptor.onRequest` 已经在注入 `Authorization: Bearer`
///   （`auth_interceptor.dart:73`）。
///
/// 缺的只是「用户如何把浏览器里的会话交到客户端」。本函数就是这个入口的
/// **纯解析部分**：把用户从 DevTools 复制来的任意形态归一成 [StoredTokens]。
///
/// ## 接受的输入形态
///
/// | 形态 | 例子 |
/// |---|---|
/// | 完整 `Cookie:` 头 | `Cookie: id_token=eyJ…; refresh_token=v1…` |
/// | 键值对（Set-Cookie 风格） | `access_token=eyJ…; refresh_token=v1…` |
/// | `Authorization` 头 | `authorization: Bearer eyJ…` |
/// | 裸 token | `eyJhbGciOiJSUzI1NiIs…` |
///
/// 前三种是 DevTools 里「复制」按钮能直接给出的形态，第四种是用户从别处
/// 手抄。多一种形态就少一次「粘贴了但没反应」的困惑，而多支持的代价只是
/// 几行前缀剥离。
///
/// ## 为什么优先 `id_token`
///
/// 网关的 OIDC 认证器验证的是 **ID Token**（`extractIDToken` → `verifier.Verify`），
/// 且 Cookie 注入路径读的也是 `id_token` cookie。两者都在时以 `id_token` 为准。
///
/// 裸 `access_token` 同样接受：网关可以同时装配 JWT 与 OIDC 两个认证器
/// （`pkg/auth/manager.go` 逐个尝试直到某个成功），但**那条路径未经实测**——
/// 这里接受它是为了不把用户手里唯一可用的凭证丢掉，而不是断言它一定有效。
/// 真伪由服务端判定：无效会在第一个请求上表现为 401。
///
/// ## 为什么 `expiresAt` 留 null
///
/// [StoredTokens.isExpired] 对 null 返回 `false`（「服务端没给信息，不该由
/// 客户端猜」），故粘贴进来的 token 会被**直接使用**，不做过期预判。等它真的
/// 过期时，网关返回 401，`AuthInterceptor` 用 `refresh_token` 刷新——
/// 这比客户端自己解析 JWT 的 `exp` 更可靠（不依赖 JWT 格式，也适用于不透明
/// 的 access token）。
///
/// ## 安全约束
///
/// 本函数**绝不记录 token 值**（不 `print`、不 `SpbLog`）。凭证只能存在于
/// 内存与 `SecureTokenStore`，进入日志就等于泄漏。
///
/// 返回 null 表示「认不出来」，由调用方给出可操作的提示，**不抛异常**：
/// 粘贴错内容是预期内的用户操作，不是程序错误。
StoredTokens? parseSessionCredential(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  final segments = _splitFields(text);

  // 单段且不含 `=` → 裸 token（或带 `Bearer `/`Authorization:` 前缀的裸 token）。
  //
  // 这个判断必须在键值解析**之前**：裸 JWT 里没有 `=`（base64url 无填充），
  // 故走不到键值分支；反过来若先解析键值，`foo=bar` 这类「有 = 但键不认识」
  // 的输入会被误判成 token。
  if (segments.length == 1) {
    final bare = _stripHeaderPrefix(segments.first);
    if (bare.isNotEmpty && !bare.contains('=')) {
      return StoredTokens(accessToken: bare);
    }
  }

  String? idToken;
  String? accessToken;
  String? refreshToken;

  for (final field in segments) {
    final segment = _stripHeaderPrefix(field);
    if (segment.isEmpty) continue;

    final eq = segment.indexOf('=');
    // `eq <= 0`：没有 `=`（如 `Cookie:` 之后的空段），或键为空（`=value`）。
    if (eq <= 0) continue;

    final key = segment.substring(0, eq).trim().toLowerCase();
    final value = _normalizeValue(segment.substring(eq + 1));
    if (value.isEmpty) continue;

    // `??=`：同名键重复出现时取**第一个**。网关下发的同名 cookie 若有多份
    // （旧域残留），先出现的通常才是当前会话。
    switch (key) {
      case 'id_token':
        idToken ??= value;
      case 'access_token':
        accessToken ??= value;
      case 'refresh_token':
        refreshToken ??= value;
    }
  }

  final bearer = idToken ?? accessToken;
  if (bearer == null || bearer.isEmpty) return null;

  return StoredTokens(accessToken: bearer, refreshToken: refreshToken);
}

/// 按 `;` 与换行切分。
///
/// JWT 与 cookie 值都是 base64url（`A-Za-z0-9-_` 加点号），**不含** `;`、
/// 换行或空格，故这些分隔符不会切坏一个 token。用户从 DevTools 复制时
/// 常带换行（多行 cookie 视图），所以换行也必须当分隔符。
List<String> _splitFields(String text) =>
    text.split(RegExp(r'[;\r\n]')).where((s) => s.trim().isNotEmpty).toList();

/// 剥掉 DevTools 复制时附带的各种前缀。
///
/// 逐个剥离而非一次匹配：`authorization: Bearer eyJ…` 需要连续去掉两层
/// （头名 + 方案名）。循环到不再变化为止，顺序无关。
String _stripHeaderPrefix(String segment) {
  var s = segment.trim();
  var changed = true;
  while (changed) {
    changed = false;
    final lower = s.toLowerCase();
    for (final prefix in const [
      'set-cookie:',
      'cookie:',
      'authorization:',
      'bearer ',
    ]) {
      if (lower.startsWith(prefix)) {
        s = s.substring(prefix.length).trim();
        changed = true;
        break;
      }
    }
  }
  return s;
}

/// 归一化 cookie 值：去引号、必要时百分号解码。
///
/// Cookie 值可能是带引号的（`id_token="eyJ…"`，RFC 6265 允许），也可能被
/// 百分号编码（`Set-Cookie` 里常见）。
String _normalizeValue(String raw) {
  var v = raw.trim();
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    v = v.substring(1, v.length - 1);
  }
  // 只在真的含 `%` 时才解码：JWT 的字符集里没有 `%`，故正常情况下是空操作；
  // 加这个条件是为了避免对不含转义的串做无谓解析。
  if (v.contains('%')) {
    try {
      v = Uri.decodeComponent(v);
    } on FormatException {
      // 形如 `%zz` 的畸形转义：保留原值。认不出就交给服务端判 401，
      // 不该因为一个坏字符把整次粘贴判成失败。
    }
  }
  return v;
}
