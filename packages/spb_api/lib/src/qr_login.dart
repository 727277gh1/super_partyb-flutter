import 'dart:async';

import 'package:dio/dio.dart';
import 'package:spb_core/spb_core.dart';

/// App 扫码登录（浏览器出码 → 本机 App 确认 → 浏览器登录）。
///
/// ## 它解决什么
///
/// 手机上的用户**无法扫自己屏幕上的码**，所以「浏览器登录页显示二维码 + 手机
/// 扫码」在单机场景走不通。这里的链路改成：
///
/// 1. 浏览器（同机或跨机）在 IdP 登录页点「App 扫码」→ 出一张二维码
///    （内容 = `<issuer 前缀>/qr/<scene>`）；
/// 2. 用户点「在本机 App 中打开」→ App Links 唤起本 App
///    （`https://<host>/idp/qr/<scene>`），或另一台手机用系统相机扫码；
/// 3. App 已经登录（持有 IdP access token）→ 调用 [QrLoginClient.preview] 拿
///    「发起端设备 + 当前账号」，展示确认页；
/// 4. 用户确认 → [QrLoginClient.confirm]；拒绝 → [QrLoginClient.deny]；
/// 5. 浏览器轮询到 confirmed，IdP 直接在那条响应里种会话 cookie。
///
/// ## 与服务端的分工（务必别混淆）
///
/// - **scene 是授权句柄，不是凭据**：拿到 scene 换不到任何东西，必须有已登录
///   的账号主人在 [confirm] 这一步点头；
/// - **轮询密钥（poll_secret）只在浏览器手里**，App 从头到尾不接触它——
///   它决定「谁能把确认结果换成登录态」，泄露即等于把别人登进自己的账号；
/// - **App 不接收、不解析、不存储任何 token**：登录态由浏览器与 IdP 之间流转。
///
/// ## 端点（id-provider `internal/qrlogin/http.go`）
///
/// | 方法 | 路径 | 认证 |
/// |---|---|---|
/// | GET | `{issuer}/api/v1/qr-login/sessions/{scene}/preview` | Bearer |
/// | POST | `{issuer}/api/v1/qr-login/sessions/{scene}/confirm` | Bearer |
/// | POST | `{issuer}/api/v1/qr-login/sessions/{scene}/deny` | Bearer |
///
/// 三个都是**直连 IdP**（不是网关的 `/pba/*`）：确认动作需要 IdP 自己验签
/// access token，绕网关没有意义，反而会把 baseUrl 绑到 Go API 上。

/// 扫码会话在 App 侧看到的状态。
enum QrLoginStatus {
  /// 等待确认（App 刚打开确认页时的正常状态）。
  pending,

  /// 已经确认过（重复打开同一条深链、或已点过确认）。
  confirmed,

  /// 已被拒绝。
  denied,
}

/// 确认页需要的全部信息。
class QrLoginPreview {
  const QrLoginPreview({
    required this.status,
    required this.device,
    required this.accountName,
    this.expiresInSeconds,
  });

  /// 会话当前状态。非 [QrLoginStatus.pending] 时确认页应直接展示结果而不是
  /// 再给一次「确认」按钮——重复确认会拿到 409（服务端按账号幂等，换账号拒绝）。
  final QrLoginStatus status;

  /// 发起端描述（`1.2.3.4 · Chrome · Windows`）。
  ///
  /// **必须原样展示**：这是用户判断「是不是我自己那台机器」的唯一依据，
  /// 也就是这条链路唯一的反钓鱼手段（RFC 8628 §5.2）。省略它等于帮攻击者
  /// 完成一次「自己出码、骗受害者确认」的登录。
  final String device;

  /// 当前登录账号的展示名（「你将登录为 …」）。
  final String accountName;

  /// 二维码剩余有效秒数（未知时为 null）。
  final int? expiresInSeconds;

  @override
  String toString() => 'QrLoginPreview($status, $device, $accountName)';
}

/// 扫码登录的 API 客户端。
class QrLoginClient {
  QrLoginClient({
    required this.issuer,
    Future<String?> Function()? tokenProvider,
    Dio? dio,
  }) : _tokenProvider = tokenProvider,
       _dio = dio ?? Dio(BaseOptions(responseType: ResponseType.json));

  /// IdP issuer（含 basePath，例如 `https://dever.atjog.com/idp`）。
  final Uri issuer;

  /// 取当前会话的 IdP access token（Bearer）。
  ///
  /// 用回调而非持有快照：token 会过期并刷新，持有快照会用到陈旧值。
  /// 为 null 时仍可构造（列表/文档场景），但三个端点都会 401。
  final Future<String?> Function()? _tokenProvider;

  final Dio _dio;

  /// 端点根路径：`{issuer}/api/v1/qr-login/sessions`。
  ///
  /// 从 issuer 推导而非写死域名：dever / bcc / 双栈各环境的 issuer 不同，
  /// 写死会让某个构建静默打到错误的环境（症状是「扫码后 App 报请求失败」）。
  Uri get endpointBase {
    final basePath = issuer.path.replaceAll(RegExp(r'/+$'), '');
    return issuer.replace(path: '$basePath/api/v1/qr-login/sessions');
  }

  /// 读取会话预览（不改变任何状态）。
  Future<QrLoginPreview> preview(String scene) async {
    final data = await _send(scene: scene, method: 'GET', action: 'preview');
    return QrLoginPreview(
      status: parseStatus(_str(data['status'])),
      // 服务端「未知设备」是中性占位，客户端不必再判空。
      device: _str(data['source']) ?? '未知设备',
      accountName: _str(_asMap(data['user'])['name']) ?? '当前账号',
      expiresInSeconds: _int(data['expiresIn']),
    );
  }

  /// 确认本次扫码登录：把发起会话的那台浏览器登成本账号。
  Future<QrLoginStatus> confirm(String scene) async {
    final data = await _send(scene: scene, method: 'POST', action: 'confirm');
    return parseStatus(_str(data['status']));
  }

  /// 拒绝本次扫码登录（「不是我」）。
  ///
  /// 服务端会把它标记成终态：另一个账号也不能再确认，浏览器侧看到 denied。
  /// 这是确认页必须提供的第二个按钮——只给「确认」等于逼用户二选一。
  Future<QrLoginStatus> deny(String scene) async {
    final data = await _send(scene: scene, method: 'POST', action: 'deny');
    return parseStatus(_str(data['status']));
  }

  /// 状态字符串 → 枚举。未知值按 pending 处理：宁可让用户再点一次确认，
  /// 也不要把状态错判成 confirmed 而显示「已登录」。
  static QrLoginStatus parseStatus(String? raw) {
    switch (raw) {
      case 'confirmed':
        return QrLoginStatus.confirmed;
      case 'denied':
        return QrLoginStatus.denied;
      default:
        return QrLoginStatus.pending;
    }
  }

  Future<Map<String, dynamic>> _send({
    required String scene,
    required String method,
    String? action,
  }) async {
    if (scene.trim().isEmpty) {
      throw const AuthError('扫码登录链接不完整（缺少 scene）');
    }
    var uri = endpointBase.replace(
      path: '${endpointBase.path}/${Uri.encodeComponent(scene.trim())}',
    );
    if (action != null) {
      uri = uri.replace(path: '${uri.path}/$action');
    }

    final token = await _tokenProvider?.call();
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    try {
      final res = method == 'GET'
          ? await _dio.get<dynamic>(
              uri.toString(),
              options: Options(headers: headers),
            )
          : await _dio.post<dynamic>(
              uri.toString(),
              // 空 body 但必须带 Content-Type：网关对无 Content-Type 的 POST
              // 直接 400（与小程序登录同一条坑）。
              options: Options(
                headers: headers,
                contentType: Headers.jsonContentType,
              ),
            );
      return _asMap(res.data);
    } on DioException catch (e) {
      throw AuthError(_messageFor(e), statusCode: e.response?.statusCode);
    }
  }

  String _messageFor(DioException e) {
    // 断网 / 超时与业务错误分开说：用户能采取的下一步完全不同。
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return '无法连接认证服务，请检查网络后重试';
      default:
        break;
    }
    final data = e.response?.data;
    final code = data is Map ? _str(data['error']) : null;
    switch (code) {
      case 'poll_secret_invalid':
      case 'poll_secret_required':
        // 正常流程里 App 不接触 poll_secret；看到它说明请求打到了轮询端点。
        return '这不是有效的扫码确认地址';
      case 'expired':
        return '二维码已过期，请在电脑/浏览器上刷新后重试';
      case 'already_confirmed':
        return '这次登录已被其他账号确认，请重新出码';
      case 'denied':
        return '这次登录已被拒绝，请重新出码';
      case 'not_found':
        return '扫码请求不存在或已失效，请重新出码';
      case 'rate_limited':
        return '操作过于频繁，请稍后再试';
      case 'unauthorized':
        return '登录状态已失效，请重新登录后再确认';
      default:
        break;
    }
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return '登录状态已失效，请重新登录后再确认';
    }
    if (status == 404) {
      return '扫码请求不存在或已失效，请重新出码';
    }
    return '确认失败（${status ?? '网络错误'}）';
  }
}

/// 扫码登录深链的解析。
///
/// 两种形态都要认（与服务端 `internal/qrlogin/page.go` 的落地页一一对应）：
///
/// | 形态 | 例子 | 何时出现 |
/// |---|---|---|
/// | 自定义 scheme | `partyb://qrlogin?scene=<scene>` | 浏览器「在本机打开」按钮、旧客户端兜底 |
/// | claimed HTTPS | `https://<任何 host>/idp/qr/<scene>` | 系统相机扫码、其他应用点链接 |
///
/// ## 为什么 https 形态不校验 host
///
/// scene 是 32 字节随机串，且**光有它什么也换不到**——真正的授权发生在
/// 已登录 App 的确认按钮上。所以「别人的域名把用户引到这个 App」并不构成
/// 提权：最坏情况是用户看到一条「扫码请求不存在」。
///
/// 反过来，如果在这里硬编码 host 白名单，dever / bcc / 内网 IP 各环境就要各
/// 打一份包（与 `OidcCallbackUri` 同一条教训：回调地址永远从 issuer 推导）。
class QrLoginUri {
  const QrLoginUri._();

  /// 自定义 scheme（与 OIDC 回调共用 `partyb`，靠 host 段区分用途）。
  static const String scheme = 'partyb';

  /// 自定义 scheme 下的 host 段。
  static const String host = 'qrlogin';

  /// claimed HTTPS 形态的路径前缀（`<issuer 前缀>/qr/<scene>`）。
  static const String httpsPathPrefix = '/idp/qr/';

  /// 自定义 scheme 形态的完整链接模板。
  static String deepLink(String scene) =>
      '$scheme://$host?scene=${Uri.encodeQueryComponent(scene)}';

  /// 这条链接是不是扫码登录深链。
  static bool matches(Uri uri) {
    if (uri.scheme == scheme && uri.host == host) return true;
    if (uri.scheme == 'https' || uri.scheme == 'http') {
      return uri.path.startsWith(httpsPathPrefix) &&
          uri.path.length > httpsPathPrefix.length;
    }
    return false;
  }

  /// 取出 scene；不是本应用能识别的链接时返回 null（**不抛异常**）。
  ///
  /// 返回 null 的调用方应当静默忽略：用户点了别的链接，不该弹错误。
  static String? parseScene(Uri uri) {
    if (uri.scheme == scheme && uri.host == host) {
      final scene = uri.queryParameters['scene']?.trim();
      return (scene == null || scene.isEmpty) ? null : scene;
    }
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.path.startsWith(httpsPathPrefix)) {
      final scene = uri.path
          .substring(httpsPathPrefix.length)
          .replaceAll('/', '')
          .trim();
      return scene.isEmpty ? null : scene;
    }
    return null;
  }
}

// ---- JSON 小工具（本文件私有；与 miniprogram_login.dart 的同名函数同语义） ----

Map<String, dynamic> _asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) return v.map((k, val) => MapEntry(k.toString(), val));
  return const {};
}

String? _str(Object? v) {
  if (v is String && v.trim().isNotEmpty) return v.trim();
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}
